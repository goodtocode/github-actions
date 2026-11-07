<#
.SYNOPSIS
Prepares a local clone or cloud installation and resumes after operator-run IaC.
.DESCRIPTION
Run through Initialize-Installation.ps1 at the product root. Credentials are prompted privately,
kept in .NET user-secrets, and sent to GitHub through the existing secret helper.
No commits, pushes, resource deletion, or authentication-mode conversion are performed.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RepositoryRoot,
    [ValidateSet('Local', 'Cloud', 'Both')][string]$Mode = 'Local',
    [ValidateSet('Prepare', 'Complete', 'Check')][string]$Stage = 'Prepare',
    [ValidateSet('development', 'production')][string]$Environment = 'development',
    [string]$Instance = '101',
    [string]$SignInTenantId,
    [string]$SignInInstanceUrl,
    [string]$WorkloadTenantId,
    [string]$SubscriptionId,
    [string]$GitHubOwner,
    [string]$GitHubRepository,
    [string]$ResourceGroupName,
    [ValidateSet('EntraOnly', 'SqlAuth')][string]$SqlAuthentication = 'EntraOnly',
    [string]$SqlAdministratorGroupObjectId,
    [string]$AzureOpenAIEndpoint,
    [switch]$CreateRepository,
    [switch]$SkipDatabase,
    [switch]$RotateSecrets,
    [switch]$InstallPrerequisites
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$RepositoryRoot = (Resolve-Path -LiteralPath $RepositoryRoot).Path
if ($Mode -eq 'Local' -and $Stage -eq 'Complete') { throw 'Local mode uses Prepare or Check, not Complete.' }
$product = if (Test-Path "$RepositoryRoot/Censic.Crucible.slnx") { 'crucible' }
    elseif (Test-Path "$RepositoryRoot/Censic.Compass.Web.slnx") { 'compass' }
    elseif (Test-Path "$RepositoryRoot/Goodtocode.AgentFramework.Web.slnx") { 'agent' }
    else { throw 'No supported product solution found at RepositoryRoot.' }
$apiProject = "$RepositoryRoot/src/Presentation.Api/Presentation.Api.csproj"
$webProject = "$RepositoryRoot/src/Presentation.Web/Presentation.Web.csproj"
$e2eProject = "$RepositoryRoot/src/Tests.Endtoend.Api/Tests.Endtoend.Api.csproj"
if (-not (Test-Path $e2eProject)) { $e2eProject = '' }
foreach ($path in @($apiProject, $webProject, "$RepositoryRoot/.azure/scripts/New-EntraDotnetSolution.ps1", "$RepositoryRoot/.github/scripts/cd/New-Github-Azure-Federation.ps1")) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Required setup file is missing: $path" }
}
$short = if ($Environment -eq 'production') { 'prod' } else { 'dev' }
$setupPrefix = "Setup:${Environment}:${Instance}"
$tools = @{ dotnet = 'Microsoft.DotNet.SDK.10'; git = 'Git.Git' }
if ($Mode -ne 'Local') { $tools.az = 'Microsoft.AzureCLI'; $tools.gh = 'GitHub.cli' }
foreach ($tool in $tools.Keys) {
    if (Get-Command $tool -ErrorAction SilentlyContinue) { continue }
    if ($Stage -eq 'Check' -or -not $InstallPrerequisites -or -not (Get-Command winget -ErrorAction SilentlyContinue)) { throw "Install $tool, or rerun Prepare with -InstallPrerequisites on Windows." }
    & winget install --id $tools[$tool] --exact --silent --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) { throw "Installation failed: $tool" }
    $env:PATH = [Environment]::GetEnvironmentVariable('PATH', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('PATH', 'User') + ';' + $env:PATH
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "Restart PowerShell after installing $tool, then rerun the same command." }
}
if ($Stage -eq 'Check') {
    Write-Host "Setup files and tools verified for $product ($Mode). No configuration or resources changed."
    return
}

. "$RepositoryRoot/.azure/scripts/lib/Dotnet.Common.ps1"
$apiValues = Get-DotnetUserSecrets -ProjectPath $apiProject
function Read-Setting([string]$Name, [string]$Value, [string]$Default = '') {
    if ($Value) { return $Value }
    if ($apiValues["${setupPrefix}:$Name"]) { return [string]$apiValues["${setupPrefix}:$Name"] }
    $answer = Read-Host "$Name$(if ($Default) { " [$Default]" })"
    if (-not $answer) { $answer = $Default }
    if (-not $answer) { throw "$Name is required." }
    return $answer
}
function Read-PrivateSetting([string]$Name, [hashtable]$Values, [string]$Key) {
    if ($Values[$Key]) { return [string]$Values[$Key] }
    $value = [System.Net.NetworkCredential]::new('', (Read-Host $Name -AsSecureString)).Password
    if (-not $value) { throw "$Name is required; an empty value will not replace an existing credential." }
    return $value
}
function Save-Settings([string]$Project, [hashtable]$Values) {
    if (-not (Set-DotnetUserSecrets -ProjectPath $Project -Secrets $Values)) { throw 'Setup could not persist configuration. No credentials will be printed.' }
}
function Get-LocalUrl([string]$Project) {
    $launch = Get-Content (Join-Path (Split-Path $Project) 'Properties/launchSettings.json') -Raw | ConvertFrom-Json
    $profile = if ($launch.profiles.PSObject.Properties['SelfHost']) { $launch.profiles.SelfHost } else { $launch.profiles.PSObject.Properties.Value | Select-Object -First 1 }
    $url = $profile.applicationUrl -split ';' | Where-Object { $_ -like 'https://*' } | Select-Object -First 1
    if (-not $url) { throw 'A local HTTPS application URL is required.' }
    return $url.TrimEnd('/')
}

$SignInTenantId = Read-Setting 'SignInTenantId' $SignInTenantId $apiValues['EntraExternalId:TenantId']
$SignInInstanceUrl = Read-Setting 'SignInInstanceUrl' $SignInInstanceUrl $apiValues['EntraExternalId:Instance']
$parsedTenant = [guid]::Empty
if (-not [guid]::TryParse($SignInTenantId, [ref]$parsedTenant) -or $parsedTenant -eq [guid]::Empty) { throw 'SignInTenantId must be a nonempty GUID.' }
$signInUri = $null
if (-not [uri]::TryCreate($SignInInstanceUrl, [UriKind]::Absolute, [ref]$signInUri) -or $signInUri.Scheme -ne 'https') { throw 'SignInInstanceUrl must be an absolute HTTPS URL.' }
$webUrl = Get-LocalUrl $webProject
$apiUrl = Get-LocalUrl $apiProject
$registrationArguments = @{
    EntraInstanceUrl = $SignInInstanceUrl
    TenantId = $SignInTenantId
    ApiAppRegistrationName = "$product-api-$short-$Instance"
    WebAppRegistrationName = "$product-web-$short-$Instance"
    ApiProjectPath = $apiProject
    WebProjectPath = $webProject
    WebRedirectUri = "$webUrl/signin-oidc"
    WebLogoutUri = "$webUrl/signout-callback-oidc"
    GenerateSecrets = $true
    AutoConsent = $true
    RotateSecrets = $RotateSecrets
}
if ($e2eProject) {
    $registrationArguments.IncludeE2E = $true
    $registrationArguments.E2EAppRegistrationName = "$product-e2e-$short-$Instance"
    $registrationArguments.E2EProjectPath = $e2eProject
}

Push-Location $RepositoryRoot
try {
    if ($Stage -eq 'Prepare') {
        Write-Host 'Preparing sign-in registrations and local configuration.'
        $previousWebValues = Get-DotnetUserSecrets $webProject
        if ($previousWebValues['EntraExternalId:ClientSecret'] -and -not $previousWebValues['Setup:SecretClientId']) {
            Save-Settings $webProject @{ 'Setup:SecretClientId' = $previousWebValues['EntraExternalId:ClientId'] }
        }
        $previousE2eValues = @{}
        if ($e2eProject) {
            $previousE2eValues = Get-DotnetUserSecrets $e2eProject
            if ($previousE2eValues['EntraExternalId:ClientSecret'] -and -not $previousE2eValues['Setup:SecretClientId']) {
                Save-Settings $e2eProject @{ 'Setup:SecretClientId' = $previousE2eValues['EntraExternalId:ClientId'] }
            }
        }
        & "$RepositoryRoot/.azure/scripts/New-EntraDotnetSolution.ps1" @registrationArguments | Out-Null
        $apiValues = Get-DotnetUserSecrets $apiProject
        $webValues = Get-DotnetUserSecrets $webProject
        if ($webValues['Setup:SecretClientId'] -ne $webValues['EntraExternalId:ClientId'] -and $webValues['EntraExternalId:ClientSecret'] -eq $previousWebValues['EntraExternalId:ClientSecret']) {
            $webValues.Remove('EntraExternalId:ClientSecret')
        }
        Save-Settings $webProject @{ 'EntraExternalId:ClientSecret' = (Read-PrivateSetting 'Web client secret (only if missing or for a different registration)' $webValues 'EntraExternalId:ClientSecret'); 'Setup:SecretClientId' = $webValues['EntraExternalId:ClientId'] }
        Save-Settings $webProject @{ 'BackendApi:BaseUrl' = $apiUrl }
        if ($e2eProject) {
            $e2eValues = Get-DotnetUserSecrets $e2eProject
            if ($e2eValues['Setup:SecretClientId'] -ne $e2eValues['EntraExternalId:ClientId'] -and $e2eValues['EntraExternalId:ClientSecret'] -eq $previousE2eValues['EntraExternalId:ClientSecret']) {
                $e2eValues.Remove('EntraExternalId:ClientSecret')
            }
            Save-Settings $e2eProject @{ 'EntraExternalId:ClientSecret' = (Read-PrivateSetting 'E2E client secret (only if missing or for a different registration)' $e2eValues 'EntraExternalId:ClientSecret'); 'Setup:SecretClientId' = $e2eValues['EntraExternalId:ClientId']; 'BackendApi:BaseUrl' = $apiUrl; 'EntraExternalId:ValidateAuthority' = 'true' }
            foreach ($project in Get-ChildItem "$RepositoryRoot/src/Setup.*/Setup.*.csproj" -ErrorAction SilentlyContinue) {
                Save-Settings $project.FullName (Get-DotnetUserSecrets $e2eProject)
            }
        }
        $AzureOpenAIEndpoint = Read-Setting 'AzureOpenAIEndpoint' $AzureOpenAIEndpoint $apiValues['AzureOpenAI:Endpoint']
        Save-Settings $apiProject @{ 'AzureOpenAI:Endpoint' = $AzureOpenAIEndpoint; 'AzureOpenAI:ApiKey' = (Read-PrivateSetting 'Azure OpenAI API key' $apiValues 'AzureOpenAI:ApiKey') }
        $apiValues = Get-DotnetUserSecrets $apiProject
        foreach ($project in Get-ChildItem "$RepositoryRoot/src/Tests.Integration*/Tests.Integration*.csproj" -ErrorAction SilentlyContinue) {
            Save-Settings $project.FullName @{ 'AzureOpenAI:Endpoint' = $apiValues['AzureOpenAI:Endpoint']; 'AzureOpenAI:ApiKey' = $apiValues['AzureOpenAI:ApiKey'] }
        }

        if ($Mode -ne 'Cloud') {
            $database = if ($product -eq 'crucible') { 'Crucible' } else { 'AgentFramework' }
            $localConnection = "Server=(localdb)\MSSQLLocalDB;Database=$database;Integrated Security=True;Encrypt=True;TrustServerCertificate=True"
            Save-Settings $apiProject @{ 'ConnectionStrings:DefaultConnection' = $localConnection }
            if (-not $SkipDatabase) {
                if (-not (Get-Command sqllocaldb -ErrorAction SilentlyContinue)) { throw 'Install SQL Server Express LocalDB, or use -SkipDatabase.' }
                & sqllocaldb start MSSQLLocalDB | Out-Null
                if ($LASTEXITCODE -ne 0) { throw 'LocalDB could not be started.' }
                dotnet dev-certs https --trust
                if ($LASTEXITCODE -ne 0) { throw 'Local HTTPS certificate setup failed.' }
                Push-Location "$RepositoryRoot/src"
                $previousEnvironment = $env:ASPNETCORE_ENVIRONMENT
                try {
                    $env:ASPNETCORE_ENVIRONMENT = 'Local'
                    dotnet tool restore --tool-manifest dotnet-tools.json
                    if ($LASTEXITCODE -ne 0) { throw 'Local EF tooling restore failed.' }
                    foreach ($project in Get-ChildItem . -Filter Infrastructure.SqlServer.csproj -Recurse -File) {
                        $ownerRoot = Split-Path (Split-Path $project.FullName)
                        $startup = if (Test-Path "$ownerRoot/Presentation.Capability/Presentation.Capability.csproj") { "$ownerRoot/Presentation.Capability/Presentation.Capability.csproj" } else { $apiProject }
                        dotnet ef database update --project $project.FullName --startup-project $startup --connection $localConnection
                        if ($LASTEXITCODE -ne 0) { throw "Existing migrations failed for $($project.Directory.Name). No reset or baseline regeneration was attempted." }
                    }
                }
                finally { $env:ASPNETCORE_ENVIRONMENT = $previousEnvironment; Pop-Location }
            }
        }
    }
    if ($Mode -eq 'Local') {
        if ($Stage -ne 'Prepare') { throw 'Local mode uses Prepare or Check, not Complete.' }
        Write-Host "Local setup complete. API: $apiUrl; Web: $webUrl."
        return
    }

    $WorkloadTenantId = Read-Setting 'WorkloadTenantId' $WorkloadTenantId
    $SubscriptionId = Read-Setting 'SubscriptionId' $SubscriptionId
    $GitHubOwner = Read-Setting 'GitHubOwner' $GitHubOwner
    $GitHubRepository = Read-Setting 'GitHubRepository' $GitHubRepository $product
    $ResourceGroupName = Read-Setting 'ResourceGroupName' $ResourceGroupName "$product-$short-wus2-$Instance-rg"
    Save-Settings $apiProject @{ "${setupPrefix}:SignInTenantId" = $SignInTenantId; "${setupPrefix}:SignInInstanceUrl" = $SignInInstanceUrl; "${setupPrefix}:WorkloadTenantId" = $WorkloadTenantId; "${setupPrefix}:SubscriptionId" = $SubscriptionId; "${setupPrefix}:GitHubOwner" = $GitHubOwner; "${setupPrefix}:GitHubRepository" = $GitHubRepository; "${setupPrefix}:ResourceGroupName" = $ResourceGroupName }
    gh auth status | Out-Null
    if ($LASTEXITCODE -ne 0) { gh auth login; if ($LASTEXITCODE -ne 0) { throw 'GitHub authentication failed.' } }
    $repository = "$GitHubOwner/$GitHubRepository"
    gh repo view $repository --json name | Out-Null
    if ($LASTEXITCODE -ne 0) {
        if (-not $CreateRepository) { throw 'Repository is missing or inaccessible. Create it, fix permissions, or explicitly use -CreateRepository.' }
        gh repo create $repository --private
        if ($LASTEXITCODE -ne 0) { throw 'GitHub repository creation failed.' }
        Write-Host 'Repository created. Publish the reviewed source and workflows yourself; setup never commits or pushes.'
    }
    if ($Stage -eq 'Prepare') {
        $environmentLookup = gh api "repos/$repository/environments/$Environment" 2>&1
        if ($LASTEXITCODE -ne 0) {
            if (($environmentLookup -join ' ') -notmatch 'HTTP 404') { throw 'GitHub environment lookup failed. Existing protection settings were not changed.' }
            gh api --method PUT "repos/$repository/environments/$Environment" | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'GitHub environment creation failed.' }
        }
        $federation = @(& "$RepositoryRoot/.github/scripts/cd/New-Github-Azure-Federation.ps1" -TenantId $WorkloadTenantId -SubscriptionId $SubscriptionId -PrincipalName "github-$product-$short-$Instance" -Organization $GitHubOwner -Repository $GitHubRepository -Environment $Environment -PassThru) | Where-Object { $_ -and $_.PSObject.Properties['ClientId'] } | Select-Object -Last 1
        if (-not $federation) { throw 'Federation setup did not return its structured client ID.' }
        Save-Settings $apiProject @{ "${setupPrefix}:DeploymentClientId" = [string]$federation.ClientId }
        $apiValues = Get-DotnetUserSecrets $apiProject
        $webValues = Get-DotnetUserSecrets $webProject
        $secrets = @{
            AZURE_CLIENT_ID = $federation.ClientId; AZURE_TENANT_ID = $WorkloadTenantId; AZURE_SUBSCRIPTION_ID = $SubscriptionId
            EEID_INSTANCE = $SignInInstanceUrl; EEID_TENANT_ID = $SignInTenantId
            API_CLIENT_ID = $apiValues['EntraExternalId:ClientId']; WEB_CLIENT_ID = $webValues['EntraExternalId:ClientId']; WEB_CLIENT_SECRET = $webValues['EntraExternalId:ClientSecret']
            AZURE_OPENAI_ENDPOINT = $apiValues['AzureOpenAI:Endpoint']; AZURE_OPENAI_APIKEY = $apiValues['AzureOpenAI:ApiKey']
            SQL_SERVER_AUTHENTICATION = $SqlAuthentication
        }
        if ($e2eProject) {
            $e2eValues = Get-DotnetUserSecrets $e2eProject
            $secrets.E2E_CLIENT_ID = $e2eValues['EntraExternalId:ClientId']; $secrets.E2E_CLIENT_SECRET = $e2eValues['EntraExternalId:ClientSecret']
        }
        if ($SqlAuthentication -eq 'SqlAuth') {
            foreach ($name in @('SQL_ADMIN_USER', 'SQL_MIGRATION_USER')) { $secrets[$name] = Read-Setting $name '' }
            foreach ($name in @('SQL_ADMIN_PASSWORD', 'SQL_MIGRATION_PASSWORD')) { $secrets[$name] = Read-PrivateSetting $name $apiValues "${setupPrefix}:$name" }
            Save-Settings $apiProject @{ "${setupPrefix}:SQL_ADMIN_USER" = $secrets.SQL_ADMIN_USER; "${setupPrefix}:SQL_MIGRATION_USER" = $secrets.SQL_MIGRATION_USER; "${setupPrefix}:SQL_ADMIN_PASSWORD" = $secrets.SQL_ADMIN_PASSWORD; "${setupPrefix}:SQL_MIGRATION_PASSWORD" = $secrets.SQL_MIGRATION_PASSWORD }
        }
        else { $secrets.SQL_ENTRA_ADMIN_GROUP_OBJECT_ID = Read-Setting 'SqlAdministratorGroupObjectId' $SqlAdministratorGroupObjectId }
        & "$RepositoryRoot/.github/scripts/repo/New-GithubSecret.ps1" -Owner $GitHubOwner -Repo $GitHubRepository -Environment $Environment -Secrets $secrets
        if ($LASTEXITCODE -ne 0) { throw 'GitHub secret preparation did not complete successfully. Fix access and rerun Prepare.' }
        Write-Host "Preparation complete. Review $product-iac.yml naming, parameter-file authentication and shared dependencies; run that workflow with environment=$Environment and runcd=true."
        Write-Host "After IaC succeeds, run: ./Initialize-Installation.ps1 -Mode Cloud -Stage Complete -Environment $Environment -Instance $Instance"
        return
    }

    az login --tenant $WorkloadTenantId --output none
    if ($LASTEXITCODE -ne 0) { throw 'Workload tenant authentication failed.' }
    az account set --subscription $SubscriptionId
    if ($LASTEXITCODE -ne 0) { throw 'Workload subscription selection failed.' }
    $targets = & "$RepositoryRoot/.github/scripts/cd/Get-WorkloadDeployment.ps1" -ResourceGroupName $ResourceGroupName -DeploymentName workload-digitalproduct
    if (-not $targets.apiEndpoint -or -not $targets.webEndpoint) { throw 'Successful API and Web IaC outputs are required before continuing.' }
    if ($targets.applicationInsightsResourceId) {
        $telemetry = az resource show --ids $targets.applicationInsightsResourceId --api-version 2020-02-02 --query properties.ConnectionString --output tsv
        if ($LASTEXITCODE -ne 0 -or -not $telemetry) { throw 'Unable to read deployment telemetry configuration.' }
        foreach ($project in @($apiProject, $webProject)) { Save-Settings $project @{ 'ApplicationInsights:ConnectionString' = $telemetry } }
    }
    $registrationArguments.WebRedirectUri = "$($targets.webEndpoint.TrimEnd('/'))/signin-oidc"
    $registrationArguments.WebLogoutUri = "$($targets.webEndpoint.TrimEnd('/'))/signout-callback-oidc"
    $registrationArguments.GenerateSecrets = $false
    $registrationArguments.RotateSecrets = $false
    & "$RepositoryRoot/.azure/scripts/New-EntraDotnetSolution.ps1" @registrationArguments | Out-Null
    Save-Settings $webProject @{ 'BackendApi:BaseUrl' = $apiUrl }
    if ($e2eProject) { Save-Settings $e2eProject @{ 'BackendApi:BaseUrl' = $apiUrl } }
    if ($targets.sqlServerKind -eq 'EntraOnly') {
        $apiValues = Get-DotnetUserSecrets $apiProject
        $migrationClientId = $apiValues["${setupPrefix}:DeploymentClientId"]
        if (-not $migrationClientId) {
            $appsJson = az ad app list --display-name "github-$product-$short-$Instance" --output json
            if ($LASTEXITCODE -ne 0) { throw 'Unable to resolve the deployment application in the workload tenant.' }
            $apps = @($appsJson | ConvertFrom-Json | Where-Object { $_.displayName -eq "github-$product-$short-$Instance" })
            if ($apps.Count -ne 1) { throw 'Exactly one matching deployment application is required. Run Prepare with the original environment and instance.' }
            $migrationClientId = $apps[0].appId
        }
        if (-not (Get-Module -ListAvailable SqlServer | Where-Object { $_.Version -ge [version]'22.0' })) { Install-Module SqlServer -MinimumVersion 22.0 -Scope CurrentUser -Force }
        Write-Host 'Provisioning Entra SQL access with the signed-in workload identity. That identity must be in the configured SQL administrator group.'
        & "$RepositoryRoot/.azure/scripts/sql/Set-AzureSqlManagedIdentityUsers.ps1" -ServerHost $targets.sqlServerHost -DatabaseName $targets.sqlDatabaseName -RuntimeName $targets.apiAppName -RuntimeClientId $targets.apiManagedIdentityClientId -MigrationName "github-$product-$short-$Instance" -MigrationClientId $migrationClientId
    }
    Write-Host "IaC verified and hosted redirects reconciled. Run $product-app.yml with environment=$Environment and runcd=true. SQL-auth users are provisioned automatically by the pipelines."
}
finally { Pop-Location }