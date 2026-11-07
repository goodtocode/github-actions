<#
.SYNOPSIS
Reads the non-secret deployment targets emitted by workload-digitalproduct.
.DESCRIPTION
Requires an Azure CLI login and the exact resource group/deployment name. Missing contract fields
are errors, not inferred resource names. Empty component values mean that component was omitted.
.EXAMPLE
$targets = .\scripts\cd\Get-WorkloadDeployment.ps1 -ResourceGroupName product-rg -DeploymentName workload-digitalproduct
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ResourceGroupName,
    [Parameter(Mandatory)][string]$DeploymentName
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$json = az deployment group show --resource-group $ResourceGroupName --name $DeploymentName --query properties --output json
if ($LASTEXITCODE -ne 0) { throw 'Unable to read the selected workload deployment. Deploy infrastructure first.' }
$deployment = $json | ConvertFrom-Json
if ($deployment.provisioningState -ne 'Succeeded') { throw 'Selected workload deployment has not succeeded. Complete IaC before app CD.' }
$outputs = $deployment.outputs
$targets = [ordered]@{ ResourceGroupName = $ResourceGroupName }
foreach ($field in @('apiAppName', 'webAppName', 'apiEndpoint', 'webEndpoint', 'applicationInsightsResourceId', 'sqlServerHost', 'sqlDatabaseName', 'sqlServerKind', 'apiPrincipalId', 'apiManagedIdentityClientId')) {
    $property = $outputs.PSObject.Properties[$field]
    if ($null -eq $property -or $property.Value.type -ne 'String' -or $property.Value.value -isnot [string]) {
        throw "Deployment output '$field' is missing or is not a string. Update the workload contract before app CD."
    }
    if ($property.Value.value.Contains("`n") -or $property.Value.value.Contains("`r")) {
        throw "Deployment output '$field' must be a single line."
    }
    if ($field -in @('apiEndpoint', 'webEndpoint') -and $property.Value.value) {
        $endpoint = $null
        if (-not [uri]::TryCreate($property.Value.value, [UriKind]::Absolute, [ref]$endpoint) -or $endpoint.Scheme -ne 'https') {
            throw "Deployment output '$field' must be an absolute HTTPS endpoint."
        }
    }
    $targets[$field] = $property.Value.value
}
[pscustomobject]$targets
