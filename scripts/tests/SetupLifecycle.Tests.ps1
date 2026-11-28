Describe 'Cloud setup session lifecycle' {
    It 'resumes Prepare through Complete without prompting or touching older application entries' {
        $initializer = Join-Path $PSScriptRoot '..\setup\Initialize-Product.ps1'
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        foreach ($directory in @('src/Presentation.Api/Properties', 'src/Presentation.Web/Properties', '.azure/scripts/lib', '.github/scripts/cd', '.github/scripts/repo')) {
            New-Item -ItemType Directory -Force (Join-Path $root $directory) | Out-Null
        }
        foreach ($file in @('Contoso.Product.slnx', 'src/Presentation.Api/Presentation.Api.csproj', 'src/Presentation.Web/Presentation.Web.csproj')) {
            Set-Content (Join-Path $root $file) 'synthetic fixture'
        }
        $launch = '{"profiles":{"SelfHost":{"applicationUrl":"https://localhost:7443"}}}'
        Set-Content (Join-Path $root 'src/Presentation.Api/Properties/launchSettings.json') $launch
        Set-Content (Join-Path $root 'src/Presentation.Web/Properties/launchSettings.json') $launch
        Set-Content (Join-Path $root '.azure/scripts/lib/Dotnet.Common.ps1') @'
function Get-DotnetUserSecrets { param($ProjectPath) return $global:SetupLifecycleStores[$ProjectPath].Clone() }
function Set-DotnetUserSecrets { param($ProjectPath, $Secrets) foreach ($key in $Secrets.Keys) { $global:SetupLifecycleStores[$ProjectPath][$key] = $Secrets[$key] }; return $true }
function Get-DotnetProjectName { param($ProjectPath) return 'synthetic' }
'@
        Set-Content (Join-Path $root '.azure/scripts/New-EntraDotnetSolution.ps1') ''
        Set-Content (Join-Path $root '.github/scripts/repo/Set-GithubDeploymentEnvironments.ps1') ''
        Set-Content (Join-Path $root '.github/scripts/repo/New-GithubSecret.ps1') 'throw "No existing secret should be uploaded."'
        Set-Content (Join-Path $root '.github/scripts/cd/New-Github-Azure-Federation.ps1') '[pscustomobject]@{ ClientId = "synthetic-federation" }'
        Set-Content (Join-Path $root '.github/scripts/cd/Get-WorkloadDeployment.ps1') @'
[pscustomobject]@{ apiEndpoint = 'https://api.example.test'; webEndpoint = 'https://web.example.test'; applicationInsightsResourceId = $null; sqlServerKind = 'SqlAuth' }
'@
        $api = "$root/src/Presentation.Api/Presentation.Api.csproj"
        $web = "$root/src/Presentation.Web/Presentation.Web.csproj"
        $global:SetupLifecycleStores = @{
            $api = @{ 'EntraExternalId:ClientId' = 'synthetic-api'; 'EntraExternalId:TenantId' = '11111111-1111-1111-1111-111111111111'; 'EntraExternalId:Instance' = 'https://signin.example.test'; 'AzureOpenAI:Endpoint' = 'https://ai.example.test'; 'AzureOpenAI:ApiKey' = 'synthetic-ai'; 'Setup:development:101:WorkloadTenantId' = 'legacy-value' }
            $web = @{ 'EntraExternalId:ClientId' = 'synthetic-web'; 'EntraExternalId:ClientSecret' = 'synthetic-web-secret' }
        }
        function gh { }
        function az { }
        Mock gh {
            $global:LASTEXITCODE = 0
            if ($args[0] -eq 'secret' -and $args[1] -eq 'list') {
                return @('AZURE_CLIENT_ID', 'AZURE_TENANT_ID', 'AZURE_SUBSCRIPTION_ID', 'EEID_INSTANCE', 'EEID_TENANT_ID', 'API_CLIENT_ID', 'WEB_CLIENT_ID', 'WEB_CLIENT_SECRET', 'AZURE_OPENAI_ENDPOINT', 'AZURE_OPENAI_APIKEY', 'SQL_SERVER_AUTHENTICATION', 'SQL_ENTRA_ADMIN_GROUP_OBJECT_ID')
            }
        }
        Mock az { $global:LASTEXITCODE = 0 }
        Mock Read-Host { throw 'Resume must not prompt.' }
        Mock Get-Command { [pscustomobject]@{ Name = 'Available' } } -ParameterFilter { ($Name -join ',') -in @('dotnet', 'git', 'az', 'gh') }
        $identity = "$root|Contoso|Product|development|101"
        if ($IsWindows) { $identity = $identity.ToLowerInvariant() }
        $hash = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($identity))).ToLowerInvariant()
        $base = if ($IsWindows) { Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'Microsoft/UserSecrets' } else { Join-Path $HOME '.microsoft/usersecrets' }
        $folder = Join-Path $base "product-setup-$hash"
        $file = Join-Path $folder 'secrets.json'
        try {
            & $initializer -RepositoryRoot $root -CompanyName Contoso -ProductName Product -Mode Cloud -Stage Prepare -Environment development -Instance 101 -SignInTenantId '11111111-1111-1111-1111-111111111111' -SignInInstanceUrl 'https://signin.example.test' -WorkloadTenantId 'synthetic-workload' -SubscriptionId 'synthetic-subscription' -GitHubOwner 'synthetic-owner' -GitHubRepository 'synthetic-repo' -ResourceGroupName 'synthetic-group' -AzureOpenAIEndpoint 'https://ai.example.test'
            $saved = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json -AsHashtable
            $saved.ContainsKey('ActiveSession') | Should -BeTrue
            & $initializer -RepositoryRoot $root -CompanyName Contoso -ProductName Product -Mode Cloud -Stage Complete -Environment development -Instance 101
            $remaining = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json -AsHashtable
            $remaining.Count | Should -Be 0
            $global:SetupLifecycleStores[$api]['Setup:development:101:WorkloadTenantId'] | Should -Be 'legacy-value'
            Should -Invoke Read-Host -Times 0 -Exactly
        }
        finally {
            if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file }
            if (Test-Path -LiteralPath $folder) { Remove-Item -LiteralPath $folder }
            Remove-Variable -Name SetupLifecycleStores -Scope Global
        }
    }
}
