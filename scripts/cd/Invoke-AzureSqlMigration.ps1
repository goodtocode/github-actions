<#
.SYNOPSIS
Applies a reviewed SQL migration script using the current Azure CLI identity or an explicit SQL migration credential.
.DESCRIPTION
The migration principal must already have a contained database user and approved permissions.
This script never bootstraps permissions or changes server authentication.
Requires Azure CLI login and SqlServer PowerShell module 22 or later.
.EXAMPLE
.\scripts\cd\Invoke-AzureSqlMigration.ps1 -ServerHost product.database.windows.net -DatabaseName product -ScriptPath .\ef-migrations.sql
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9.-]+$')][string]$ServerHost,
    [Parameter(Mandatory)][ValidateLength(1, 128)][string]$DatabaseName,
    [Parameter(Mandatory)][string]$ScriptPath,
    [pscredential]$SqlCredential
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) { throw "Migration script does not exist: $ScriptPath" }
if (-not (Get-Module -ListAvailable SqlServer | Where-Object { $_.Version -ge [version]'22.0' })) {
    throw 'SqlServer PowerShell module 22 or later is required. Install-Module SqlServer -Scope CurrentUser.'
}
Import-Module SqlServer -MinimumVersion 22.0

$authentication = @{}
if ($SqlCredential) {
    $authentication.Credential = $SqlCredential
}
else {
    $tokenJson = az account get-access-token --resource https://database.windows.net/ --output json
    if ($LASTEXITCODE -ne 0) { throw 'Azure CLI could not acquire the SQL migration token.' }
    $token = ($tokenJson | ConvertFrom-Json).accessToken
    if ([string]::IsNullOrWhiteSpace($token)) { throw 'Azure CLI returned no SQL migration access token.' }
    $authentication.AccessToken = $token
}
Invoke-Sqlcmd -ServerInstance "tcp:$ServerHost,1433" -Database $DatabaseName @authentication `
    -Query "IF IS_ROLEMEMBER('db_owner') = 1 OR COALESCE(IS_ROLEMEMBER('db_ddladmin'), 0) <> 1 THROW 51000, 'Use the separately bootstrapped migration principal, not a SQL administrator or runtime identity.', 1;" `
    -Encrypt Mandatory -AbortOnError -ErrorAction Stop
Invoke-Sqlcmd -ServerInstance "tcp:$ServerHost,1433" -Database $DatabaseName @authentication `
    -InputFile (Resolve-Path -LiteralPath $ScriptPath).Path -Encrypt Mandatory -AbortOnError -QueryTimeout 600 -ErrorAction Stop
Write-Host "Migration applied to database '$DatabaseName'."
