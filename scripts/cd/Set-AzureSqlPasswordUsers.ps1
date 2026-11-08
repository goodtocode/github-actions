<#
.SYNOPSIS
Ensures restricted migration and runtime database users using a SQL administrator.
.DESCRIPTION
Uses supplied migration credentials and reuses or generates runtime credentials stored
in the API App Service connection string. Never changes server authentication or prints credentials.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9.-]+$')][string]$ServerHost,
    [Parameter(Mandatory)][ValidateLength(1, 128)][string]$DatabaseName,
    [Parameter(Mandatory)][pscredential]$Administrator,
    [Parameter(Mandatory)][pscredential]$Migration,
    [string]$ApiAppName = '',
    [string]$ResourceGroupName = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function New-AzureSqlRuntimePassword {
    $characters = @(
        [char][System.Security.Cryptography.RandomNumberGenerator]::GetInt32(65, 91)
        [char][System.Security.Cryptography.RandomNumberGenerator]::GetInt32(97, 123)
        [char][System.Security.Cryptography.RandomNumberGenerator]::GetInt32(48, 58)
        [char][System.Security.Cryptography.RandomNumberGenerator]::GetInt32(33, 48)
    )
    return (-join $characters) + [Convert]::ToBase64String([System.Security.Cryptography.RandomNumberGenerator]::GetBytes(48))
}

if ($Administrator.UserName -eq $Migration.UserName -or $Migration.UserName.Length -gt 128 -or [string]::IsNullOrWhiteSpace($Migration.UserName)) {
    throw 'Migration must use a distinct database user name of 1-128 characters.'
}
if ($Migration.Password.Length -lt 1 -or $Migration.Password.Length -gt 128) { throw 'Migration password must contain 1-128 characters.' }
if (-not (Get-Module -ListAvailable SqlServer | Where-Object { $_.Version -ge [version]'22.0' })) {
    throw 'SqlServer PowerShell module 22 or later is required.'
}
Import-Module SqlServer -MinimumVersion 22.0

$runtimeName = ''
$runtimePassword = ''
$runtimeConnection = [Microsoft.Data.SqlClient.SqlConnectionStringBuilder]::new()
if ($ApiAppName) {
    if (-not $ResourceGroupName) { throw 'ResourceGroupName is required for runtime credential storage.' }
    $runtimeName = "$ApiAppName-runtime"
    if ($runtimeName.Length -gt 128 -or $runtimeName -eq $Migration.UserName -or $runtimeName -eq $Administrator.UserName) {
        throw 'Runtime, migration and administrator users must be distinct.'
    }
    $settingsJson = az webapp config connection-string list --resource-group $ResourceGroupName --name $ApiAppName --output json
    if ($LASTEXITCODE -ne 0) { throw 'Unable to read runtime credential storage. No users were changed.' }
    $setting = @($settingsJson | ConvertFrom-Json) | Where-Object { $_.name -eq 'DefaultConnection' } | Select-Object -First 1
    if ($setting -and $setting.connectionString) {
        try { $runtimeConnection.set_ConnectionString($setting.connectionString) }
        catch { throw 'Existing runtime connection configuration is invalid. No users were changed.' }
        if ($runtimeConnection.get_UserID() -ne $runtimeName -or $runtimeConnection.get_InitialCatalog() -ne $DatabaseName -or $runtimeConnection.get_DataSource() -ne "tcp:$ServerHost,1433" -or -not $runtimeConnection.get_Password()) {
            throw 'Existing runtime connection does not match this SQL-auth deployment. Replace the workload or explicitly reconcile its configuration.'
        }
        $runtimePassword = $runtimeConnection.get_Password()
    }
    else {
        $runtimePassword = New-AzureSqlRuntimePassword
        $runtimeConnection.set_DataSource("tcp:$ServerHost,1433")
        $runtimeConnection.set_InitialCatalog($DatabaseName)
        $runtimeConnection.set_UserID($runtimeName)
        $runtimeConnection.set_Password($runtimePassword)
    }
    $runtimeConnection.set_Encrypt([Microsoft.Data.SqlClient.SqlConnectionEncryptOption]::Mandatory)
    $runtimeConnection.set_TrustServerCertificate($false)
    if ($env:GITHUB_ACTIONS -eq 'true') {
        $maskedPassword = $runtimePassword.Replace('%', '%25').Replace("`r", '%0D').Replace("`n", '%0A')
        Write-Host "::add-mask::$maskedPassword"
    }
}

$connectionSettings = [Microsoft.Data.SqlClient.SqlConnectionStringBuilder]::new()
$connectionSettings.set_DataSource("tcp:$ServerHost,1433")
$connectionSettings.set_InitialCatalog($DatabaseName)
$connectionSettings.set_Encrypt([Microsoft.Data.SqlClient.SqlConnectionEncryptOption]::Mandatory)
$connectionSettings.set_TrustServerCertificate($false)
$connection = [Microsoft.Data.SqlClient.SqlConnection]::new($connectionSettings.get_ConnectionString())
$Administrator.Password.MakeReadOnly()
$connection.Credential = [Microsoft.Data.SqlClient.SqlCredential]::new($Administrator.UserName, $Administrator.Password)
$command = $connection.CreateCommand()
$command.CommandText = @'
SET XACT_ABORT ON;
BEGIN TRANSACTION;
DECLARE @Users TABLE (Name nvarchar(128), Password nvarchar(128), IsMigration bit);
INSERT INTO @Users VALUES (@MigrationName, @MigrationPassword, 1);
IF @RuntimeName <> N'' INSERT INTO @Users VALUES (@RuntimeName, @RuntimePassword, 0);
DECLARE @Name nvarchar(128), @Password nvarchar(128), @IsMigration bit, @Statement nvarchar(max);
DECLARE UsersToEnsure CURSOR LOCAL FAST_FORWARD FOR SELECT Name, Password, IsMigration FROM @Users;
OPEN UsersToEnsure;
FETCH NEXT FROM UsersToEnsure INTO @Name, @Password, @IsMigration;
WHILE @@FETCH_STATUS = 0
BEGIN
    IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name = @Name AND (type <> 'S' OR authentication_type <> 2))
        THROW 51000, 'Existing user has a conflicting authentication type.', 1;
    IF EXISTS (
        SELECT 1 FROM sys.database_role_members m
        JOIN sys.database_principals r ON r.principal_id = m.role_principal_id
        WHERE m.member_principal_id = DATABASE_PRINCIPAL_ID(@Name)
          AND r.name NOT IN ('db_datareader', 'db_datawriter')
          AND NOT (@IsMigration = 1 AND r.name = 'db_ddladmin')
    ) OR EXISTS (
        SELECT 1 FROM sys.database_permissions WHERE grantee_principal_id = DATABASE_PRINCIPAL_ID(@Name)
          AND (state = 'W' OR (state = 'G' AND permission_name NOT IN ('CONNECT', 'SELECT', 'INSERT', 'UPDATE', 'DELETE', 'EXECUTE')))
    )
        THROW 51000, 'Existing user has permissions outside the selected role.', 1;
    SET @Statement = CASE WHEN DATABASE_PRINCIPAL_ID(@Name) IS NULL THEN N'CREATE USER ' ELSE N'ALTER USER ' END
        + QUOTENAME(@Name) + N' WITH PASSWORD = N''' + REPLACE(@Password, N'''', N'''''') + N''';';
    EXEC sys.sp_executesql @Statement;
    IF COALESCE(IS_ROLEMEMBER(N'db_datareader', @Name), 0) <> 1
    BEGIN
        SET @Statement = N'ALTER ROLE [db_datareader] ADD MEMBER ' + QUOTENAME(@Name);
        EXEC sys.sp_executesql @Statement;
    END;
    IF COALESCE(IS_ROLEMEMBER(N'db_datawriter', @Name), 0) <> 1
    BEGIN
        SET @Statement = N'ALTER ROLE [db_datawriter] ADD MEMBER ' + QUOTENAME(@Name);
        EXEC sys.sp_executesql @Statement;
    END;
    IF @IsMigration = 1 AND COALESCE(IS_ROLEMEMBER(N'db_ddladmin', @Name), 0) <> 1
    BEGIN
        SET @Statement = N'ALTER ROLE [db_ddladmin] ADD MEMBER ' + QUOTENAME(@Name);
        EXEC sys.sp_executesql @Statement;
    END;
    FETCH NEXT FROM UsersToEnsure INTO @Name, @Password, @IsMigration;
END;
CLOSE UsersToEnsure;
DEALLOCATE UsersToEnsure;
COMMIT TRANSACTION;
'@
foreach ($parameter in @(
    @{ Name = '@MigrationName'; Value = $Migration.UserName },
    @{ Name = '@MigrationPassword'; Value = $Migration.GetNetworkCredential().Password },
    @{ Name = '@RuntimeName'; Value = $runtimeName },
    @{ Name = '@RuntimePassword'; Value = $runtimePassword }
)) {
    $command.Parameters.Add($parameter.Name, [System.Data.SqlDbType]::NVarChar, 128).Value = $parameter.Value
}
try {
    $connection.Open()
    [void]$command.ExecuteNonQuery()
}
catch { throw 'SQL user provisioning failed. Verify administrator access, password requirements and existing user permissions. No SQL error text is logged because it may contain credentials.' }
finally { $command.Dispose(); $connection.Dispose() }

if ($ApiAppName) {
    az webapp config connection-string set --resource-group $ResourceGroupName --name $ApiAppName --connection-string-type SQLServer --settings "DefaultConnection=$($runtimeConnection.get_ConnectionString())" --output none | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'SQL users were provisioned but runtime credential storage failed. Rerun provisioning before deploying the application.' }
}
Write-Host 'SQL migration and runtime access provisioned.'