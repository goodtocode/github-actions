<#
.SYNOPSIS
Selects SQL creation or ordinary updates without changing server authentication.
.DESCRIPTION
Requires Azure CLI login. Lookup failures stop deployment. Existing servers must
already match the selected authentication and immutable SQL administrator login.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][object]$SqlConfiguration,
    [Parameter(Mandatory)][string]$ResourceGroupName,
    [Parameter(Mandatory)][string]$SubscriptionId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$sql = $SqlConfiguration
$referenced = $sql.server.kind -eq 'Existing'
$group = if ($referenced) { $sql.server.resourceGroupName } else { $ResourceGroupName }
$subscription = if ($referenced -and $sql.server.PSObject.Properties['subscriptionId'] -and $sql.server.subscriptionId) { $sql.server.subscriptionId } else { $SubscriptionId }
$authentication = if ($referenced) {
    if ($sql.server.PSObject.Properties['authentication'] -and $sql.server.authentication) { $sql.server.authentication } else { 'EntraOnly' }
} else { if ($env:SQL_SERVER_AUTHENTICATION) { $env:SQL_SERVER_AUTHENTICATION } else { $sql.server.kind } }
if ($authentication -notin @('EntraOnly', 'SqlAuth')) { throw 'Unsupported SQL authentication choice.' }

$groupExists = az group exists --name $group --subscription $subscription --output tsv
if ($LASTEXITCODE -ne 0) { throw 'Resource group lookup failed.' }
if ($groupExists -eq 'false') {
    if ($referenced) { throw 'The independently owned SQL resource group must already exist.' }
    if ($authentication -eq 'SqlAuth' -and [string]::IsNullOrWhiteSpace($env:SQL_ADMIN_PASSWORD)) { throw 'Configure SQL_ADMIN_PASSWORD before creating a SqlAuth server.' }
    return $true
}
$serverJson = az sql server list --resource-group $group --subscription $subscription --output json
if ($LASTEXITCODE -ne 0) { throw 'SQL server lookup failed. Creation will not be assumed.' }
$server = @($serverJson | ConvertFrom-Json) | Where-Object { $_.name -eq $sql.serverName } | Select-Object -First 1
if (-not $server) {
    if ($referenced) { throw 'The independently owned SQL server must already exist.' }
    if ($authentication -eq 'SqlAuth' -and [string]::IsNullOrWhiteSpace($env:SQL_ADMIN_PASSWORD)) { throw 'Configure SQL_ADMIN_PASSWORD before creating a SqlAuth server.' }
    return $true
}

$detailsJson = az sql server show --resource-group $group --name $sql.serverName --subscription $subscription --expand-ad-admin --output json
if ($LASTEXITCODE -ne 0) { throw 'SQL authentication lookup failed.' }
$details = $detailsJson | ConvertFrom-Json
$entraOnly = $details.PSObject.Properties['administrators'] -and $details.administrators -and $details.administrators.azureADOnlyAuthentication -eq $true
if (($authentication -eq 'EntraOnly') -ne [bool]$entraOnly) {
    throw 'SQL authentication differs from the selected mode. Replace the server; this pipeline never changes authentication modes.'
}
if (-not $referenced -and $authentication -eq 'SqlAuth' -and $details.administratorLogin -ne $(if ($env:SQL_ADMIN_USER) { $env:SQL_ADMIN_USER } else { $sql.server.administratorLogin })) {
    throw 'The SQL administrator login is immutable. Replace the server to select a different login.'
}
return $false