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
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*$')][string]$CompanyName,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z_][A-Za-z0-9_]*$')][string]$ProductName,
    [ValidateSet('Local', 'Cloud', 'Both')][string]$Mode = 'Local',
    [ValidateSet('Prepare', 'Complete', 'Check')][string]$Stage = 'Prepare',
    [ValidateSet('development', 'production')][string]$Environment = 'development',
    [string]$Instance = '100',
    [string]$SignInTenantId,
    [string]$SignInInstanceUrl,
    [string]$WorkloadTenantId,
    [string]$SubscriptionId,
    [string]$GitHubOwner,
    [string]$GitHubRepository,
    [string]$GitHubPrincipalName,
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
$product = $ProductName.ToLowerInvariant()
$solutionPrefix = "$CompanyName.$ProductName"
if (-not (Get-ChildItem -LiteralPath $RepositoryRoot -Filter '*.slnx' -File | Where-Object {
    $_.BaseName -eq $solutionPrefix -or $_.BaseName.StartsWith("$solutionPrefix.", [StringComparison]::OrdinalIgnoreCase)
})) { throw "No solution found for $solutionPrefix at RepositoryRoot." }
$apiProject = "$RepositoryRoot/src/Presentation.Api/Presentation.Api.csproj"
$webProject = "$RepositoryRoot/src/Presentation.Web/Presentation.Web.csproj"
$e2eProject = "$RepositoryRoot/src/Tests.Endtoend.Api/Tests.Endtoend.Api.csproj"
if (-not (Test-Path $e2eProject)) { $e2eProject = '' }
foreach ($path in @($apiProject, $webProject, "$PSScriptRoot/Setup-Session.ps1", "$RepositoryRoot/.azure/scripts/New-EntraDotnetSolution.ps1", "$RepositoryRoot/.github/scripts/cd/New-Github-Azure-Federation.ps1")) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Required setup file is missing: $path" }
}
if ($Mode -ne 'Local' -and -not (Test-Path -LiteralPath "$RepositoryRoot/.github/scripts/repo/Set-GithubDeploymentEnvironments.ps1")) {
    throw 'Required GitHub deployment environment helper is missing.'
}
$short = if ($Environment -eq 'production') { 'prod' } else { 'dev' }
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
. "$PSScriptRoot/Setup-Session.ps1"
Start-SetupSession -RepositoryRoot $RepositoryRoot -CompanyName $CompanyName -ProductName $ProductName -Environment $Environment -Instance $Instance
if (-not $PSBoundParameters.ContainsKey('SqlAuthentication') -and $setupState['SqlAuthentication']) {
    $SqlAuthentication = [string]$setupState['SqlAuthentication']
}
Save-SetupValue 'SqlAuthentication' $SqlAuthentication
$apiValues = Get-DotnetUserSecrets -ProjectPath $apiProject
function Read-Setting([string]$Name, [string]$Value, [string]$Default = '') {
    if (-not $Value) { $Value = [string]$setupState[$Name] }
    if (-not $Value) {
        $Value = Read-Host "$Name$(if ($Default) { " [$Default]" })"
        if (-not $Value) { $Value = $Default }
    }
    if (-not $Value) { throw "$Name is required." }
    Save-SetupValue $Name $Value
    return $Value
}
function Read-PrivateSetting([string]$Name, [hashtable]$Values, [string]$Key) {
    if ($Values[$Key]) { return [string]$Values[$Key] }
    $value = [System.Net.NetworkCredential]::new('', (Read-Host $Name -AsSecureString)).Password
    if (-not $value) { throw "$Name is required; an empty value will not replace an existing credential." }
    return $value
}
function Confirm-SqlAdministratorGroup([string]$ObjectId, [string]$TenantId) {
    $groupId = [guid]::Empty
    if (-not [guid]::TryParse($ObjectId, [ref]$groupId) -or $groupId -eq [guid]::Empty) { throw 'SQL administrator group object ID must be a nonempty GUID.' }
    $context = Get-AzContext -ErrorAction Stop
    if (-not $context -or -not $context.Tenant -or [string]$context.Tenant.Id -ne $TenantId) { throw "Sign in to workload tenant '$TenantId' before validating the SQL administrator group." }
    try { $groups = @(Get-AzADGroup -ObjectId $groupId -DefaultProfile $context -ErrorAction Stop) }
    catch { throw "Unable to read SQL administrator group '$ObjectId' in workload tenant '$TenantId'. Verify the group and directory read permissions." }
    if ($groups.Count -ne 1 -or $groups[0].SecurityEnabled -ne $true) {
        throw "SQL administrator group '$ObjectId' must be an existing security group in workload tenant '$TenantId'."
    }
}
function Save-Settings([string]$Project, [hashtable]$Values) {
    if (-not (Set-DotnetUserSecrets -ProjectPath $Project -Secrets $Values)) { throw 'Setup could not persist configuration. No credentials will be printed.' }
}
function Invoke-SetupRegistrations {
    $previousApi = Get-DotnetUserSecrets $apiProject
    $previous = @{}
    foreach ($project in @($webProject, $e2eProject) | Where-Object { $_ }) {
        $previous[$project] = Get-DotnetUserSecrets $project
    }
    try {
        & "$RepositoryRoot/.azure/scripts/New-EntraDotnetSolution.ps1" @registrationArguments | Out-Null
    }
    finally {
      $currentApi = Get-DotnetUserSecrets $apiProject
      if ($currentApi['EntraExternalId:ClientId'] -and $currentApi['EntraExternalId:ClientId'] -ne $previousApi['EntraExternalId:ClientId']) {
          Save-SetupValue 'ApiRegistrationChanged' 'true'
      }
      if (($currentApi['EntraExternalId:TenantId'] -and $currentApi['EntraExternalId:TenantId'] -ne $previousApi['EntraExternalId:TenantId']) -or
          ($currentApi['EntraExternalId:Instance'] -and $currentApi['EntraExternalId:Instance'] -ne $previousApi['EntraExternalId:Instance'])) {
          Save-SetupValue 'SignInConfigurationChanged' 'true'
      }
      foreach ($project in $previous.Keys) {
        $current = Get-DotnetUserSecrets $project
        $old = $previous[$project]
        $clientId = [string]$current['EntraExternalId:ClientId']
        if (-not $clientId) { throw 'Registration did not persist its client ID.' }
        $kind = if ($project -eq $webProject) { 'Web' } else { 'E2E' }
        $changed = $clientId -ne $old['EntraExternalId:ClientId'] -or
            ($old['EntraExternalId:TenantId'] -and $current['EntraExternalId:TenantId'] -ne $old['EntraExternalId:TenantId'])
        $stale = $changed -and $current['EntraExternalId:ClientSecret'] -and
            $current['EntraExternalId:ClientSecret'] -ceq $old['EntraExternalId:ClientSecret']
        $repairKey = "${kind}RepairClientId"
        if ($stale -or -not $current['EntraExternalId:ClientSecret'] -or $setupState[$repairKey] -eq $clientId) {
            Save-SetupValue $repairKey $clientId
            Save-SetupValue "${kind}CredentialsChanged" 'true'
            $credentialKey = "${kind}Credential:$clientId"
            $credential = [string]$setupState[$credentialKey]
            if (-not $credential) {
                $arguments = @{
                    Type = $kind
                    TenantId = $SignInTenantId
                    AppRegistrationName = $registrationArguments["${kind}AppRegistrationName"]
                    SecretOnly = $true
                    SkipPrerequisites = $true
                    ProjectName = (Get-DotnetProjectName $project)
                }
                if ($kind -eq 'E2E') { $arguments.ApiAppId = (Get-DotnetUserSecrets $apiProject)['EntraExternalId:ClientId'] }
                $result = @(& "$RepositoryRoot/.azure/scripts/entra/New-EntraAppRegistration.ps1" @arguments) |
                    Where-Object { $_ -and $_.PSObject.Properties['AppId'] } | Select-Object -Last 1
                if (-not $result -or $result.AppId -ne $clientId -or -not $result.Secret) {
                    throw "Unable to generate a credential for the reconciled $kind registration."
                }
                $credential = [string]$result.Secret
                Save-SetupValue $credentialKey $credential
            }
            Save-Settings $project @{ 'EntraExternalId:ClientSecret' = $credential }
            $current['EntraExternalId:ClientSecret'] = $credential
            Save-SetupValue $repairKey 'none'
        }
        if ($changed -or $current['EntraExternalId:ClientSecret'] -cne $old['EntraExternalId:ClientSecret']) {
            Save-SetupValue "${kind}CredentialsChanged" 'true'
        }
      }
    }
}
function Get-GitHubSecretNames([string]$Repository, [string]$TargetEnvironment) {
    $names = @(gh secret list --repo $Repository --env $TargetEnvironment --json name --jq '.[].name')
    if ($LASTEXITCODE -ne 0) { throw 'Unable to list existing GitHub environment secrets.' }
    return $names
}
function Publish-SetupSecrets([hashtable]$Values, [string[]]$Existing, [string[]]$Changed) {
    $pending = @{}
    foreach ($name in $Values.Keys) {
        if ($name -notin $Existing -or $name -in $Changed) { $pending[$name] = $Values[$name] }
    }
    if ($pending.Count -gt 0) {
        & "$RepositoryRoot/.github/scripts/repo/New-GithubSecret.ps1" -Owner $GitHubOwner -Repo $GitHubRepository -Environment $Environment -Secrets $pending
    }
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
        Invoke-SetupRegistrations
        $apiValues = Get-DotnetUserSecrets $apiProject
        $webValues = Get-DotnetUserSecrets $webProject
        Save-Settings $webProject @{ 'EntraExternalId:ClientSecret' = (Read-PrivateSetting 'Web client secret (only if missing or for a different registration)' $webValues 'EntraExternalId:ClientSecret') }
        Save-Settings $webProject @{ 'BackendApi:BaseUrl' = $apiUrl }
        if ($e2eProject) {
            $e2eValues = Get-DotnetUserSecrets $e2eProject
            Save-Settings $e2eProject @{ 'EntraExternalId:ClientSecret' = (Read-PrivateSetting 'E2E client secret (only if missing or for a different registration)' $e2eValues 'EntraExternalId:ClientSecret'); 'BackendApi:BaseUrl' = $apiUrl; 'EntraExternalId:ValidateAuthority' = 'true' }
        }
        $AzureOpenAIEndpoint = Read-Setting 'AzureOpenAIEndpoint' $AzureOpenAIEndpoint $apiValues['AzureOpenAI:Endpoint']
        Save-Settings $apiProject @{ 'AzureOpenAI:Endpoint' = $AzureOpenAIEndpoint; 'AzureOpenAI:ApiKey' = (Read-PrivateSetting 'Azure OpenAI API key' $apiValues 'AzureOpenAI:ApiKey') }
        $apiValues = Get-DotnetUserSecrets $apiProject
        foreach ($project in Get-ChildItem "$RepositoryRoot/src/Tests.Integration*/Tests.Integration*.csproj" -ErrorAction SilentlyContinue) {
            Save-Settings $project.FullName @{ 'AzureOpenAI:Endpoint' = $apiValues['AzureOpenAI:Endpoint']; 'AzureOpenAI:ApiKey' = $apiValues['AzureOpenAI:ApiKey'] }
        }

        if ($Mode -ne 'Cloud') {
            $database = $ProductName
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
        Complete-SetupSession
        Write-Host "Local setup complete. API: $apiUrl; Web: $webUrl."
        return
    }

    $WorkloadTenantId = Read-Setting 'WorkloadTenantId' $WorkloadTenantId
    $SubscriptionId = Read-Setting 'SubscriptionId' $SubscriptionId
    $GitHubOwner = Read-Setting 'GitHubOwner' $GitHubOwner
    $GitHubRepository = Read-Setting 'GitHubRepository' $GitHubRepository $product
    if (-not $GitHubPrincipalName) {
        $GitHubPrincipalName = if ($setupState['GitHubPrincipalName']) { [string]$setupState['GitHubPrincipalName'] } else { "github-$product" }
    }
    Save-SetupValue 'GitHubPrincipalName' $GitHubPrincipalName
    $ResourceGroupName = Read-Setting 'ResourceGroupName' $ResourceGroupName "$product-$short-wus2-$Instance-rg"
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
        & "$RepositoryRoot/.github/scripts/repo/Set-GithubDeploymentEnvironments.ps1" -Owner $GitHubOwner -Repo $GitHubRepository
        $federation = @(& "$RepositoryRoot/.github/scripts/cd/New-Github-Azure-Federation.ps1" -TenantId $WorkloadTenantId -SubscriptionId $SubscriptionId -PrincipalName $GitHubPrincipalName -Organization $GitHubOwner -Repository $GitHubRepository -Environment $Environment -PassThru) | Where-Object { $_ -and $_.PSObject.Properties['ClientId'] } | Select-Object -Last 1
        if (-not $federation) { throw 'Federation setup did not return its structured client ID.' }
        $existingSecrets = @(Get-GitHubSecretNames $repository $Environment)
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
            foreach ($name in @('SQL_ADMIN_USER', 'SQL_MIGRATION_USER')) {
                if ($name -notin $existingSecrets) { $secrets[$name] = Read-Setting $name '' }
            }
            foreach ($name in @('SQL_ADMIN_PASSWORD', 'SQL_MIGRATION_PASSWORD')) {
                if ($name -notin $existingSecrets) {
                    $secrets[$name] = Read-PrivateSetting $name $setupState $name
                    Save-SetupValue $name $secrets[$name]
                }
            }
        }
        else {
            if ('SQL_ENTRA_ADMIN_GROUP_OBJECT_ID' -notin $existingSecrets -or $SqlAdministratorGroupObjectId) {
                $groupObjectId = Read-Setting 'SqlAdministratorGroupObjectId' $SqlAdministratorGroupObjectId
                Confirm-SqlAdministratorGroup -ObjectId $groupObjectId -TenantId $WorkloadTenantId
                $secrets.SQL_ENTRA_ADMIN_GROUP_OBJECT_ID = $groupObjectId
            }
        }
        $changed = @()
        if ($setupState['WebCredentialsChanged'] -eq 'true') { $changed += @('WEB_CLIENT_ID', 'WEB_CLIENT_SECRET') }
        if ($setupState['E2ECredentialsChanged'] -eq 'true') { $changed += @('E2E_CLIENT_ID', 'E2E_CLIENT_SECRET') }
        if ($setupState['ApiRegistrationChanged'] -eq 'true') { $changed += 'API_CLIENT_ID' }
        if ($setupState['SignInConfigurationChanged'] -eq 'true') { $changed += @('EEID_INSTANCE', 'EEID_TENANT_ID') }
        if ($SqlAdministratorGroupObjectId) { $changed += 'SQL_ENTRA_ADMIN_GROUP_OBJECT_ID' }
        if ($PSBoundParameters.ContainsKey('SqlAuthentication')) { $changed += 'SQL_SERVER_AUTHENTICATION' }
        Publish-SetupSecrets $secrets $existingSecrets $changed
        Save-SetupValue 'WebCredentialsChanged' 'false'
        if ($e2eProject) { Save-SetupValue 'E2ECredentialsChanged' 'false' }
        Save-SetupValue 'ApiRegistrationChanged' 'false'
        Save-SetupValue 'SignInConfigurationChanged' 'false'
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
    Invoke-SetupRegistrations
    foreach ($project in @($webProject, $e2eProject) | Where-Object { $_ }) {
        $values = Get-DotnetUserSecrets $project
        Save-Settings $project @{ 'EntraExternalId:ClientSecret' = (Read-PrivateSetting 'Client secret (only if missing or for a different registration)' $values 'EntraExternalId:ClientSecret') }
    }
    Save-Settings $webProject @{ 'BackendApi:BaseUrl' = $apiUrl }
    if ($e2eProject) { Save-Settings $e2eProject @{ 'BackendApi:BaseUrl' = $apiUrl } }
    $changedSecrets = @{}
    if ($setupState['WebCredentialsChanged'] -eq 'true') {
        $webValues = Get-DotnetUserSecrets $webProject
        $changedSecrets.WEB_CLIENT_ID = $webValues['EntraExternalId:ClientId']
        $changedSecrets.WEB_CLIENT_SECRET = $webValues['EntraExternalId:ClientSecret']
    }
    if ($e2eProject -and $setupState['E2ECredentialsChanged'] -eq 'true') {
        $e2eValues = Get-DotnetUserSecrets $e2eProject
        $changedSecrets.E2E_CLIENT_ID = $e2eValues['EntraExternalId:ClientId']
        $changedSecrets.E2E_CLIENT_SECRET = $e2eValues['EntraExternalId:ClientSecret']
    }
    if ($setupState['ApiRegistrationChanged'] -eq 'true') {
        $apiValues = Get-DotnetUserSecrets $apiProject
        $changedSecrets.API_CLIENT_ID = $apiValues['EntraExternalId:ClientId']
    }
    if ($setupState['SignInConfigurationChanged'] -eq 'true') {
        $changedSecrets.EEID_INSTANCE = $SignInInstanceUrl
        $changedSecrets.EEID_TENANT_ID = $SignInTenantId
    }
    if ($changedSecrets.Count -gt 0) {
        Publish-SetupSecrets $changedSecrets @() @($changedSecrets.Keys)
    }
    if ($targets.sqlServerKind -eq 'EntraOnly') {
        $apiValues = Get-DotnetUserSecrets $apiProject
        $appsJson = az ad app list --display-name $GitHubPrincipalName --output json
        if ($LASTEXITCODE -ne 0) { throw 'Unable to resolve the deployment application in the workload tenant.' }
        $apps = @($appsJson | ConvertFrom-Json | Where-Object { $_.displayName -eq $GitHubPrincipalName })
        if ($apps.Count -ne 1) { throw 'Exactly one matching deployment application is required. Run Prepare with the same GitHub principal name.' }
        $migrationClientId = $apps[0].appId
        if (-not (Get-Module -ListAvailable SqlServer | Where-Object { $_.Version -ge [version]'22.0' })) { Install-Module SqlServer -MinimumVersion 22.0 -Scope CurrentUser -Force }
        Write-Host 'Provisioning Entra SQL access with the signed-in workload identity. That identity must be in the configured SQL administrator group.'
        & "$RepositoryRoot/.azure/scripts/sql/Set-AzureSqlManagedIdentityUsers.ps1" -ServerHost $targets.sqlServerHost -DatabaseName $targets.sqlDatabaseName -RuntimeName $targets.apiAppName -RuntimeClientId $targets.apiManagedIdentityClientId -MigrationName "github-$product-$short-$Instance" -MigrationClientId $migrationClientId
    }
    Complete-SetupSession
    Write-Host "IaC verified and hosted redirects reconciled. Run $product-app.yml with environment=$Environment and runcd=true. SQL-auth users are provisioned automatically by the pipelines."
}
finally { Pop-Location }