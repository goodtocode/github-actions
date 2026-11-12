<#
.SYNOPSIS
Sets up a fresh clone for localhost: Entra app registrations, and the .NET user-secrets for every project.

.DESCRIPTION
Run from any folder in PowerShell (not 'pwsh -File', so a splatted hashtable works). The script resolves the repo root from its own location.
1. Entra: calls .azure/scripts/New-EntraDotnetSolution.ps1 to create the API and Web registrations, grant consent, and write their user-secrets.
2. User-secrets: sets Azure OpenAI and Application Insights values for Presentation.Api, Presentation.Web and Tests.Integration.
3. Database: applies the EF migrations to the local SQL Server (LocalDB by default).
Local only: it does not touch GitHub, Azure Pipelines or Azure resources. CI/CD secrets and federation are set up separately.
Safe to re-run: existing registrations are reused, and the Web client secret is only regenerated with -RotateSecrets.
Leave -ApplicationInsightsConnectionString empty until the infrastructure is deployed; the apps start without it, with no Azure telemetry. Deployment names are only stored when you pass them, because the appsettings files already carry the template defaults (chat-fast, tool-standard, tool-reasoning, embedding-standard).

.EXAMPLE
# Omit -AzureOpenAIApiKey to be prompted without echo:
$install = @{
    EntraInstanceUrl    = "https://<your-tenant-name>.ciamlogin.com"
    EntraTenantId       = "<entra-tenant-id>"
    AzureOpenAIEndpoint = "https://<resource>.openai.azure.com/openai/v1"
}
./.github/scripts/setup/Initialize-Development.ps1 @install

.EXAMPLE
# Existing Entra registrations: skip Entra and only (re)write the Azure OpenAI and Application Insights secrets:
./.github/scripts/setup/Initialize-Development.ps1 -SkipEntra -AzureOpenAIEndpoint "https://<resource>.openai.azure.com/openai/v1" -ApplicationInsightsConnectionString "<connection-string>"
#>
[CmdletBinding()]
param(
    [string]$EntraInstanceUrl,
    [string]$EntraTenantId,
    [Parameter(Mandatory)][string]$AzureOpenAIEndpoint,
    [string]$AzureOpenAIApiKey,
    [string]$ChatDeploymentName,
    [string]$ToolDeploymentName,
    [string]$ToolReasoningDeploymentName,
    [string]$EmbeddingDeploymentName,
    [string]$ApplicationInsightsConnectionString = "",

    # Registration names: {ProductName}-api-{EnvironmentShort}-{Instance} and {ProductName}-web-...
    [string]$ProductName = "agent",
    [string]$EnvironmentShort = "dev",
    [string]$Instance = "001",
    [string]$WebRedirectUri,
    [string]$WebLogoutUri,
    [switch]$RotateSecrets,
    [switch]$SkipEntra,

    # Local SQL database (LocalDB by default); the EF migrations are applied to it
    [string]$DatabaseConnectionString = "Data Source=(localdb)\MSSQLLocalDB;Initial Catalog=AgentFramework;Min Pool Size=3;MultipleActiveResultSets=True;Trusted_Connection=Yes;TrustServerCertificate=True;MultipleActiveResultSets=False;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30",
    [switch]$SkipDatabase
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
. "$repoRoot\.azure\scripts\lib\Dotnet.Common.ps1"

$apiProject = Join-Path $repoRoot 'src\Presentation.Api'
$webProject = Join-Path $repoRoot 'src\Presentation.Web'
$testProject = Join-Path $repoRoot 'src\Tests.Integration'

if (-not $SkipEntra -and (-not $EntraInstanceUrl -or -not $EntraTenantId)) {
    throw "-EntraInstanceUrl and -EntraTenantId are required unless -SkipEntra is used."
}

if (-not $AzureOpenAIApiKey) {
    $secureKey = Read-Host -Prompt 'Azure OpenAI API key' -AsSecureString
    $AzureOpenAIApiKey = [System.Net.NetworkCredential]::new('', $secureKey).Password
}

# The Web redirect URIs must match the HTTPS URL in Presentation.Web launchSettings.
if (-not $SkipEntra -and (-not $WebRedirectUri -or -not $WebLogoutUri)) {
    $launch = Get-Content (Join-Path $webProject 'Properties\launchSettings.json') -Raw | ConvertFrom-Json
    $httpsUrl = $launch.profiles.PSObject.Properties.Value | ForEach-Object { $_.applicationUrl -split ';' } | Where-Object { $_ -like 'https://*' } | Select-Object -First 1
    if (-not $httpsUrl) { throw "No HTTPS applicationUrl found in Presentation.Web launchSettings.json. Pass -WebRedirectUri and -WebLogoutUri." }
    if (-not $WebRedirectUri) { $WebRedirectUri = "$($httpsUrl.TrimEnd('/'))/signin-oidc" }
    if (-not $WebLogoutUri) { $WebLogoutUri = "$($httpsUrl.TrimEnd('/'))/signout-callback-oidc" }
}

function Write-Step([string]$Text) {
    Write-Host ""
    Write-Host "══ $Text" -ForegroundColor Cyan
}

# ── 1. Entra ──────────────────────────────────────────────────────────────────
if ($SkipEntra) {
    Write-Step "1. Entra: skipped (-SkipEntra)"
}
else {
    Write-Step "1. Entra app registrations and consent"
    $entraArgs = @{
        EntraInstanceUrl       = $EntraInstanceUrl
        TenantId               = $EntraTenantId
        ApiAppRegistrationName = "$ProductName-api-$EnvironmentShort-$Instance"
        WebAppRegistrationName = "$ProductName-web-$EnvironmentShort-$Instance"
        ApiProjectPath         = $apiProject
        WebProjectPath         = $webProject
        WebRedirectUri         = $WebRedirectUri
        WebLogoutUri           = $WebLogoutUri
        GenerateSecrets        = $true
        AutoConsent            = $true
    }
    if ($RotateSecrets) { $entraArgs.RotateSecrets = $true }
    & "$repoRoot\.azure\scripts\New-EntraDotnetSolution.ps1" @entraArgs
}

# ── 2. User-secrets ───────────────────────────────────────────────────────────
Write-Step "2. User-secrets for Presentation.Api, Presentation.Web and Tests.Integration"
$openAi = @{
    "AzureOpenAI:Endpoint" = $AzureOpenAIEndpoint
    "AzureOpenAI:ApiKey"   = $AzureOpenAIApiKey
}
if ($ChatDeploymentName) { $openAi["AzureOpenAI:ChatDeploymentName"] = $ChatDeploymentName }
if ($ToolDeploymentName) { $openAi["AzureOpenAI:ToolDeploymentName"] = $ToolDeploymentName }
if ($ToolReasoningDeploymentName) { $openAi["AzureOpenAI:ToolReasoningDeploymentName"] = $ToolReasoningDeploymentName }
if ($EmbeddingDeploymentName) { $openAi["AzureOpenAI:EmbeddingDeploymentName"] = $EmbeddingDeploymentName }
$appInsights = @{ "ApplicationInsights:ConnectionString" = $ApplicationInsightsConnectionString }

Save-DotnetUserSecrets -Label 'API' -ProjectPath $apiProject -Secrets ($openAi + $appInsights) | Out-Null
Save-DotnetUserSecrets -Label 'Web' -ProjectPath $webProject -Secrets $appInsights | Out-Null
Save-DotnetUserSecrets -Label 'Tests' -ProjectPath $testProject -Secrets $openAi | Out-Null

# ── 3. Local database ─────────────────────────────────────────────────────────
if ($SkipDatabase) {
    Write-Step "3. Local database: skipped (-SkipDatabase)"
}
else {
    Write-Step "3. Local database: apply EF migrations"
    if (-not (Get-Command dotnet-ef -ErrorAction SilentlyContinue) -and -not (dotnet tool list --global | Select-String '^dotnet-ef\s')) {
        dotnet tool install --global dotnet-ef
    }
    dotnet ef database update --project "$repoRoot\src\Infrastructure.SqlServer\Infrastructure.SqlServer.csproj" --startup-project "$apiProject\Presentation.Api.csproj" --context AgentFrameworkContext --connection $DatabaseConnectionString
    if ($LASTEXITCODE -ne 0) { throw "dotnet ef database update failed. Stop any running Presentation.Api or Presentation.Web (they lock the build output), check that SQL Server LocalDB (or the server in -DatabaseConnectionString) is running, or re-run with -SkipDatabase." }
}

Write-Host ""
Write-Host "Local install complete." -ForegroundColor Green
if (-not $ApplicationInsightsConnectionString) {
    Write-Host "Application Insights: after the IaC deploys, re-run with -SkipEntra -SkipDatabase and -ApplicationInsightsConnectionString '<value>' (the Azure OpenAI values are rewritten with the same input)." -ForegroundColor DarkGray
}
