$provides = "SQL"
function Collect-Data {

##############
##############
Function Get-Instances{
  
    Try { 
                $Computer = $ENV:COMPUTERNAME
                $reg = [Microsoft.Win32.RegistryKey]::OpenRemoteBaseKey('LocalMachine', $Computer) 
                $baseKeys = "SOFTWARE\\Microsoft\\Microsoft SQL Server",
                "SOFTWARE\\Wow6432Node\\Microsoft\\Microsoft SQL Server"
                If ($reg.OpenSubKey($basekeys[0])) {
                    $regPath = $basekeys[0]
                } ElseIf ($reg.OpenSubKey($basekeys[1])) {
                    $regPath = $basekeys[1]
                } Else {
                    Continue
                }
                $regKey= $reg.OpenSubKey("$regPath")
                If ($regKey.GetSubKeyNames() -contains "Instance Names") {
                    $regKey= $reg.OpenSubKey("$regpath\\Instance Names\\SQL" ) 
                    $instances = @($regkey.GetValueNames())
                } ElseIf ($regKey.GetValueNames() -contains 'InstalledInstances') {
                    $isCluster = $False
                    $instances = $regKey.GetValue('InstalledInstances')
                } Else {
                    Continue
                }
                $instance_array = @()
                If ($instances.count -gt 0) { 
                    ForEach ($instance in $instances) {
                        $nodes = New-Object System.Collections.Arraylist
                        $clusterName = $Null
                        $isCluster = $False
                        $instanceValue = $regKey.GetValue($instance)
                        $instanceReg = $reg.OpenSubKey("$regpath\\$instanceValue")
                        If ($instanceReg.GetSubKeyNames() -contains "Cluster") {
                            $isCluster = $True
                            $instanceRegCluster = $instanceReg.OpenSubKey('Cluster')
                            $clusterName = $instanceRegCluster.GetValue('ClusterName')
                            $clusterReg = $reg.OpenSubKey("Cluster\\Nodes")                            
                            $clusterReg.GetSubKeyNames() | ForEach {
                                $null = $nodes.Add($clusterReg.OpenSubKey($_).GetValue('NodeName'))
                            }
                        }
                        $instanceRegSetup = $instanceReg.OpenSubKey("Setup")
                        Try {
                            $edition = $instanceRegSetup.GetValue('Edition')
                        } Catch {
                            $edition = $Null
                        }
                        Try {
                            $ErrorActionPreference = 'Stop'
                            #Get from filename to determine version
                            $servicesReg = $reg.OpenSubKey("SYSTEM\\CurrentControlSet\\Services")
                            $serviceKey = $servicesReg.GetSubKeyNames() | Where {
                                $_ -match "$instance"
                            } | Select -First 1
                            $service = $servicesReg.OpenSubKey($serviceKey).GetValue('ImagePath')
                            $file = $service -replace '^.*(\w:\\.*\\sqlservr.exe).*','$1'
                            $version = (Get-Item ("\\$Computer\$($file -replace ":","$")")).VersionInfo.ProductVersion
                        } Catch {
                            #Use potentially less accurate version from registry
                            $Version = $instanceRegSetup.GetValue('Version')
                        } Finally {
                            $ErrorActionPreference = 'Continue'
                        }
                        $temp = New-Object PSObject -Property @{
                            Computername = $Computer
                            SQLInstance = $instance
                            isCluster = $isCluster
                            isClusterNode = ($nodes -contains $Computer)
                            ClusterName = $clusterName
                            ClusterNodes = ($nodes -ne $Computer)
                            FullName = {
                                If ($isCluster)
                                {
                                    If ($Instance -eq 'MSSQLSERVER') {
                                        $ClusterName
                                    } Else {
                                        "$($ClusterName)\$($instance)"
                                    }
                                }
                                ELSE
                                {
                                    If ($Instance -eq 'MSSQLSERVER') {
                                        $Computer
                                    } Else {
                                        "$($Computer)\$($instance)"
                                    }
                                }


                            }.InvokeReturnAsIs()
                        } #end of psobject
                    $instance_array += $temp

                    }#end of foreach instance...
                }
            } Catch { 
                Write-Warning ("{0}: {1}" -f $Computer,$_.Exception.Message)
            }  

            return  $instance_array
        }

Function Invoke-TSQL {
Param(
     [Parameter(Mandatory=$True)][string] $TSQL,    
     [Parameter(Mandatory=$True)][array] $SQLServInst,
     [Parameter(Mandatory=$False)][switch] $TSQLVerbose
     )
    
$invokedebug = @"
Invoke-SqlCmd -Query "$TSQL" -ServerInstance "$SQLServInst"
"@
Write-Verbose $invokedebug`n

If ($TSQLVerbose) 
    {
    #If true this command uses the -verbos switch at end of the line. Usefull if TSQL uses print command or T-SQL is erroring.
    $SQLOutput = Invoke-SqlCmd -Query "$TSQL" -ServerInstance "$SQLServInst"  -Verbose
    }
Else 
    {
    #Default is to use this one currently
    $SQLOutput = Invoke-SqlCmd -Query "$TSQL" -ServerInstance "$SQLServInst" 
    }

Return $SQLOutput

Write-Debug "Invoke-Function"
}

Function Get-DBRecoveryModel{
Param(
     [Parameter(Mandatory=$False)] [String] $Database
     )

$TSQL = ""
$TSQL = @"
--Recovery model of the $Database database.
SELECT '$Database' AS [Database Name],
DATABASEPROPERTYEX('model', 'RECOVERY')
AS [Recovery model]
GO
"@

Write-Debug "Get-TSQL-ModelDBtoSimple"

Return $TSQL
}

Function Get-SQLMaxMemory{
$TSQL = ""
$TSQL = @"
SELECT name, value, value_in_use, [description]
FROM sys.configurations WHERE name = 'max server memory (MB)'
GO
"@

Write-Debug "Get-TSQL-MaxMemory"

Return $TSQL
}

Function Get-SQLVersion{
$TSQL = ""
$TSQL = @"
SELECT
@@version AS [SQL Server Version],
SERVERPROPERTY('ProductLevel') AS ProductLevel,
SERVERPROPERTY('Edition') AS Edition,
SERVERPROPERTY('EngineEdition') AS EngineEdition,
SERVERPROPERTY('ProductVersion') AS ProductVersion;
GO
"@

Write-Debug "Get-SQLVersion"

Return $TSQL
}

Function Get-SQLInstanceName{

$TSQL = ""
$TSQL = @"
SELECT
SERVERPROPERTY ('InstanceName') AS InstanceName;
GO
"@

Write-Debug "Get-SQLInstanceName"

Return $TSQL
}

Function Get-SQLCollation{

$TSQL = ""
$TSQL = @"
SELECT
SERVERPROPERTY ('Collation') AS Collation;
GO
"@

Write-Debug "Get-SQLCollation"

Return $TSQL
}

Function Get-SQLDataLocation{

$TSQL = ""
$TSQL = @"
--Default file locations.
declare @datadir nvarchar(4000)
,@logdir nvarchar(4000);
EXEC master.dbo.xp_instance_regread
N'HKEY_LOCAL_MACHINE'
, N'Software\Microsoft\MSSQLServer\MSSQLServer'
, N'DefaultData'
, @datadir output;
IF @datadir IS NULL
BEGIN
EXEC master.dbo.xp_instance_regread
N'HKEY_LOCAL_MACHINE'
, N'Software\Microsoft\MSSQLServer\Setup'
, N'SQLDataRoot'
, @datadir output;
END
SELECT @datadir AS 'Data location';
"@

Write-Debug "Get-SQLCollation"

Return $TSQL
}

Function Get-SQLLogLocation{

$TSQL = ""
$TSQL = @"
declare @logdir nvarchar(4000);
EXEC master.dbo.xp_instance_regread
N'HKEY_LOCAL_MACHINE'
, N'Software\Microsoft\MSSQLServer\MSSQLServer'
, N'DefaultLog'
, @logdir output;
SELECT @logdir AS 'Log location'
"@
Write-Debug "Get-SQLCollation"

Return $TSQL
}

Function Get-TempDBFiles{

$TSQL = ""
$TSQL = @"
USE tempdb
SELECT
physical_name AS [TempDB File Path] FROM sys.database_files
GO
"@

Write-Debug "Get-TempDBFiles"

Return $TSQL
}

Function Get-SQLPort{

$TSQL = ""
$TSQL = @"
--Get SQL TCP/IP port used from registry.
DECLARE @TcpPort VARCHAR(5)
,@RegKey VARCHAR(100)
IF @@SERVICENAME !='MSSQLSERVER'
BEGIN
SET @RegKey = 'SOFTWARE\Microsoft\Microsoft SQL Server\' + @@SERVICENAME + '\MSSQLServer\SuperSocketNetLib\Tcp'
END
ELSE
BEGIN
SET @RegKey = 'SOFTWARE\MICROSOFT\MSSQLSERVER\MSSQLSERVER\SUPERSOCKETNETLIB\TCP'
END
EXEC master..xp_regread
@rootkey = 'HKEY_LOCAL_MACHINE'
,@key = @RegKey
,@value_name = 'TcpPort'
,@value = @TcpPort OUTPUT
SELECT @TcpPort AS [Port]
GO
"@

Write-Debug "Get-TempDBFiles"

Return $TSQL
}

Function Get-SQLAdmins{

$TSQL = ""
$TSQL = @"
SELECT NAME FROM SYSLOGINS
WHERE sysadmin = 1 and hasaccess = 1 
GO
"@

Write-Debug "Get-TempDBFiles"

Return $TSQL
}

Function Get-SQLAudit{
Param(
[Parameter()]$Instance
)

# $name = $($ENV:COMPUTERNAME)

$TSQL = Get-DBRecoveryModel -Database "model"
$DBRecoveryModel = Invoke-TSQL -TSQL $TSQL -SQLServInst $Instance

$TSQL = Get-SQLMaxMemory
$MaxMemory = Invoke-TSQL -TSQL $TSQL -SQLServInst $Instance

$TSQL = Get-SQLVersion
$Version = Invoke-TSQL -TSQL $TSQL -SQLServInst $Instance

$TSQL = Get-SQLInstanceName
$InstanceName = Invoke-TSQL -TSQL $TSQL -SQLServInst $Instance 
If ($InstanceName = ""){$InstanceName = "MSSQLSERVER"}

$TSQL = Get-SQLCollation
$Collation = Invoke-TSQL -TSQL $TSQL -SQLServInst $Instance

$TSQL = Get-SQLDataLocation
$DataLocation = Invoke-TSQL -TSQL $TSQL -SQLServInst $Instance

$TSQL = Get-SQLLogLocation
$LogLocation = Invoke-TSQL -TSQL $TSQL -SQLServInst $Instance

$TSQL = Get-TempDBFiles
$TempDBFiles = Invoke-TSQL -TSQL $TSQL -SQLServInst $Instance

$TSQL = Get-SQLPort
$Port = Invoke-TSQL -TSQL $TSQL -SQLServInst $Instance

$TSQL = Get-SQLAdmins
$SQLAdmins = Invoke-TSQL -TSQL $TSQL -SQLServInst $Instance

#$BackCompatInstalled = Get-SQLBackCompatInstalled

$SQLAudit = @{  
    DBRecoveryModel = $DBRecoveryModel."Recovery model"
    MaxMemory = $MaxMemory.value
    MaxMemoryInUse = $MaxMemory.value_in_use 
    Version = $Version."SQL Server Version" 
    ProductLevel = $Version.ProductLevel
    Edition = $Version.Edition  
    InstanceName = $InstanceName.InstanceName 
    Collation = $Collation.Collation 
    DataLocation = $DataLocation."Data Location" 
    LogLocation = $LogLocation."Log location" 
    TempDBFiles = $TempDBFiles."TempDB File Path" 
    Port = $Port.Port 
    SQLAdmins = $($SQLAdmins.Name)
    #BackCompatInstalled = $BackCompatInstalled
    Productversion = $Version.productversion
}

return $SQLAudit

}
##############
##############
#Get OS version
$OSVersion = [System.Environment]::OSVersion.Version.Major + ([System.Environment]::OSVersion.Version.Minor/10)

#Initialise SQLCMD
If ($OSVersion -gt 6.1)
{
    Import-Module sqlps -disableNameChecking
}
ELSE
{
    Add-pssnapin SqlServerCmdletSnapin100
}



$Instances = Get-Instances

$SQL = @()
ForEach ($instance in $instances)
{


        $SQLAudit = Get-SQLAudit -Instance $instance.fullname
  
        $SQL += $SQLAudit


} # end of for each loop

return $SQL


}