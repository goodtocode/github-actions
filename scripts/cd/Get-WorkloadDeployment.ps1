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
if ($LASTEXITCODE -ne 0) { throw "Unable to read deployment '$DeploymentName' in resource group '$ResourceGroupName' (Azure CLI exit code $LASTEXITCODE). See the Azure CLI error above." }
$deployment = $json | ConvertFrom-Json
$stateProperty = $deployment.PSObject.Properties['provisioningState']
$state = if ($stateProperty -and $stateProperty.Value) { [string]$stateProperty.Value } else { 'Unknown' }
if ($state -ne 'Succeeded') {
    $diagnostics = [System.Collections.Generic.List[string]]::new()
    if ($state -eq 'Failed') {
        $operationsJson = az deployment operation group list --resource-group $ResourceGroupName --name $DeploymentName --query "[?properties.provisioningState=='Failed'].{target:properties.targetResource.id,error:properties.statusMessage.error}" --output json
        if ($LASTEXITCODE -eq 0 -and $operationsJson) {
            function Add-ArmErrorDetail($detail) {
                if (-not $detail) { return }
                $codeProperty = $detail.PSObject.Properties['code']
                $targetProperty = $detail.PSObject.Properties['target']
                $messageProperty = $detail.PSObject.Properties['message']
                $parts = @()
                if ($codeProperty -and $codeProperty.Value) { $parts += "Code: $($codeProperty.Value)" }
                if ($targetProperty -and $targetProperty.Value) { $parts += "Resource: $($targetProperty.Value)" }
                if ($messageProperty -and $messageProperty.Value) {
                    $message = [string]$messageProperty.Value
                    if ($message -match '(?i)password|secret|token|credential|connection.?string|authorization|bearer|signature') { $message = '[potentially sensitive Azure error detail omitted]' }
                    $parts += "Reason: $message"
                }
                if ($parts.Count) { $diagnostics.Add(($parts -join '; ')) }
                $detailsProperty = $detail.PSObject.Properties['details']
                if ($detailsProperty) { foreach ($child in @($detailsProperty.Value)) { Add-ArmErrorDetail $child } }
            }
            foreach ($operation in @($operationsJson | ConvertFrom-Json)) {
                if ($operation.target) { $diagnostics.Add("Resource: $($operation.target)") }
                Add-ArmErrorDetail $operation.error
            }
        }
    }
    $reason = if ($diagnostics.Count) { "`n" + ($diagnostics -join "`n") } else { '' }
    throw "Deployment '$DeploymentName' in resource group '$ResourceGroupName' has not succeeded (state: $state).$reason"
}
$outputs = $deployment.outputs
$targets = [ordered]@{ ResourceGroupName = $ResourceGroupName }
foreach ($field in @('apiAppName', 'webAppName', 'apiEndpoint', 'webEndpoint', 'applicationInsightsResourceId', 'sqlServerHost', 'sqlDatabaseName', 'sqlServerKind', 'apiPrincipalId', 'apiManagedIdentityClientId')) {
    $property = $outputs.PSObject.Properties[$field]
    if ($null -eq $property -or $property.Value.type -ne 'String' -or $property.Value.value -isnot [string]) {
        throw "Deployment '$DeploymentName' in resource group '$ResourceGroupName' output '$field' is missing or is not a string. Update the workload contract before app CD."
    }
    if ($property.Value.value.Contains("`n") -or $property.Value.value.Contains("`r")) {
        throw "Deployment '$DeploymentName' in resource group '$ResourceGroupName' output '$field' must be a single line."
    }
    if ($field -in @('apiEndpoint', 'webEndpoint') -and $property.Value.value) {
        $endpoint = $null
        if (-not [uri]::TryCreate($property.Value.value, [UriKind]::Absolute, [ref]$endpoint) -or $endpoint.Scheme -ne 'https') {
            throw "Deployment '$DeploymentName' in resource group '$ResourceGroupName' output '$field' must be an absolute HTTPS endpoint."
        }
    }
    $targets[$field] = $property.Value.value
}
[pscustomobject]$targets
