<#
.SYNOPSIS
Creates or updates (upserts) GitHub Actions secrets in one repo, several repos, or every repo of an owner.

.DESCRIPTION
Requires GitHub CLI (gh) and an authenticated session. Installs GitHub CLI if it is not present and prompts for GitHub authentication if not already authenticated.
A secret that already exists is overwritten, so rerunning is safe and rotates the value.
Without -Environment the secrets are repository secrets. With -Environment they are environment secrets. Inaccessible targets and failed uploads fail the script.
-AllRepos targets every non-archived, non-fork repo of -Owner. Use -WhatIf to list what would be set without changing anything.
Secret values are sent to gh on stdin, never on the command line.

.EXAMPLE
# One secret in one repo environment (single line, safe to paste):
.\New-GithubSecret.ps1 -Owner goodtocode -Repo my-repo -Environment development -SecretName MY_SECRET -SecretValue "secret-value"

.EXAMPLE
# Upsert one secret in every repo of an owner, in the development and production environments (preview first with -WhatIf):
.\New-GithubSecret.ps1 -Owner goodtocode -AllRepos -Environment development,production -SecretName AZURE_OPENAI_APIKEY -SecretValue "secret-value" -WhatIf

.EXAMPLE
# Upsert one secret in a list of repos, as repository secrets:
.\New-GithubSecret.ps1 -Owner censicai -Repo crucible,compass -SecretName AZURE_OPENAI_ENDPOINT -SecretValue "https://ai-dev-wus2-100-aif.openai.azure.com/"

.EXAMPLE
# Set many secrets at once in one repo environment:
.\New-GithubSecret.ps1 -Owner your-github-handle -Repo your-repo -Environment development -Secrets @{API_CLIENT_ID="your-api-client-id";AZURE_CLIENT_ID="your-azure-client-id";AZURE_OPENAI_APIKEY="your-azure-openai-apikey";AZURE_OPENAI_ENDPOINT="your-azure-openai-endpoint";AZURE_SUBSCRIPTION_ID="your-azure-subscription-id";AZURE_TENANT_ID="your-azure-tenant-id";E2E_CLIENT_ID="your-e2e-client-id";E2E_CLIENT_SECRET="your-e2e-client-secret";EEID_INSTANCE="your-eeid-instance-url";EEID_TENANT_ID="your-eeid-tenant-id";WEB_CLIENT_ID="your-web-client-id";WEB_CLIENT_SECRET="your-web-client-secret"}
#>
[CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = 'Single')]
param(
  [Parameter(Mandatory = $true)][string]$Owner,
  [string[]]$Repo,
  [switch]$AllRepos,
  [string[]]$Environment,
  [Parameter(Mandatory = $true, ParameterSetName = 'Single')][string]$SecretName,
  [Parameter(Mandatory = $true, ParameterSetName = 'Single')][string]$SecretValue,
  [Parameter(Mandatory = $true, ParameterSetName = 'Many')][hashtable]$Secrets
)

$ErrorActionPreference = 'Stop'

if (-not $AllRepos -and -not $Repo) { throw 'Specify -Repo <name,...> or -AllRepos.' }
if ($AllRepos -and $Repo) { throw 'Use either -Repo or -AllRepos, not both.' }

if ($PSCmdlet.ParameterSetName -eq 'Single') { $Secrets = @{ $SecretName = $SecretValue } }
if ($Secrets.Count -eq 0) { throw 'Specify at least one secret to upload.' }
foreach ($name in $Secrets.Keys) {
  if ([string]::IsNullOrWhiteSpace([string]$name) -or [string]::IsNullOrWhiteSpace([string]$Secrets[$name])) {
    throw 'Secret names and values must be nonempty. No secrets were uploaded.'
  }
}

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
  Write-Host "GitHub CLI not found. Installing via winget..." -ForegroundColor Red
  winget install --id GitHub.cli -e --silent
  Write-Host "GitHub CLI installed. Please restart your terminal or PowerShell session, then re-run this script." -ForegroundColor Red
  exit 1
}

gh auth status 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
  Write-Host "GitHub CLI not authenticated. Please login." -ForegroundColor Red
  gh auth login
  if ($LASTEXITCODE -ne 0) { throw 'GitHub authentication failed. No secrets were uploaded.' }
}

if ($AllRepos) {
  Write-Host "Listing repos of $Owner..."
  $Repo = @(gh repo list $Owner --source --no-archived --limit 1000 --json name --jq '.[].name')
  if ($LASTEXITCODE -ne 0 -or $Repo.Count -eq 0) { throw "No repos found for $Owner." }
}

$targets = if ($Environment) { $Environment } else { @('') }
$set = 0
$skipped = 0
$failed = 0

foreach ($r in $Repo) {
  $full = "$Owner/$r"
  gh repo view $full --json name 2>$null | Out-Null
  if ($LASTEXITCODE -ne 0) {
    Write-Warning "Repo $full does not exist or is not accessible. Skipping."
    $skipped++
    continue
  }

  foreach ($envName in $targets) {
    $scope = if ($envName) { "$full ($envName)" } else { "$full (repository)" }

    if ($envName) {
      gh api "repos/$full/environments/$envName" 2>$null | Out-Null
      if ($LASTEXITCODE -ne 0) {
        Write-Warning "Environment $envName does not exist in $full. Skipping."
        $skipped++
        continue
      }
    }

    foreach ($name in $Secrets.Keys | Sort-Object) {
      if (-not $PSCmdlet.ShouldProcess($scope, "Upsert secret $name")) { continue }
      $ghArgs = @('secret', 'set', $name, '--repo', $full)
      if ($envName) { $ghArgs += @('--env', $envName) }
      [string]$Secrets[$name] | & gh @ghArgs | Out-Null
      if ($LASTEXITCODE -eq 0) {
        Write-Host "Set $name in $scope"
        $set++
      }
      else {
        Write-Warning "Failed to set $name in $scope"
        $failed++
      }
    }
  }
}

Write-Host "Done. Set: $set, skipped: $skipped, failed: $failed."
if ($failed -gt 0 -or $skipped -gt 0) {
  throw "GitHub secret upload incomplete. Set: $set, skipped: $skipped, failed: $failed."
}
