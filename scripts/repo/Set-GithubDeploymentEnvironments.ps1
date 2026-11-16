<#
.SYNOPSIS
Ensures development exists and production has a required GitHub reviewer.
.DESCRIPTION
Preserves existing production reviewers and protection settings. When production has no
reviewer, the authenticated GitHub user becomes the reviewer. Private repositories need
an eligible GitHub Enterprise plan for required reviewers to be enforced.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Owner,
    [Parameter(Mandatory)][string]$Repo
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$repository = "$Owner/$Repo"

$repositoryJson = gh api "repos/$repository" 2>&1
if ($LASTEXITCODE -ne 0) { throw "Cannot inspect GitHub repository $repository." }
$repositoryInfo = $repositoryJson | ConvertFrom-Json

if ($repositoryInfo.private) {
    if ($repositoryInfo.owner.type -eq 'Organization') {
        $accountJson = gh api "orgs/$Owner" 2>&1
    }
    else {
        $accountJson = gh api user 2>&1
    }
    if ($LASTEXITCODE -ne 0) { throw "Cannot verify the GitHub plan for $Owner; production approval may not be enforced." }
    $account = $accountJson | ConvertFrom-Json
    if ($repositoryInfo.owner.type -ne 'Organization' -and $account.login -ne $Owner) {
        throw "Cannot verify the GitHub plan for $Owner using the authenticated account."
    }
    if (-not $account.PSObject.Properties['plan'] -or -not $account.plan -or -not $account.plan.PSObject.Properties['name']) {
        throw "Cannot verify the GitHub plan for $Owner; production approval may not be enforced."
    }
    if ($account.plan.name -notin @('enterprise', 'business_plus')) {
        throw "Private repository $repository requires a GitHub Enterprise plan for production required reviewers."
    }
}

$pagesJson = gh api "repos/$repository/environments?per_page=100" --paginate --slurp 2>&1
if ($LASTEXITCODE -ne 0) { throw "Cannot list GitHub environments for $repository; existing protection settings were not changed." }
$environments = @(($pagesJson | ConvertFrom-Json) | ForEach-Object { $_.environments })
$development = $environments | Where-Object { $_.name -eq 'development' } | Select-Object -First 1
$production = $environments | Where-Object { $_.name -eq 'production' } | Select-Object -First 1

if (-not $development) {
    gh api --method PUT "repos/$repository/environments/development" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Cannot create the development environment for $repository." }
    Write-Host "Created development environment for $repository."
}
else {
    Write-Host "Development environment already exists for $repository."
}

$reviewerRule = @(if ($production) { $production.protection_rules | Where-Object { $_.type -eq 'required_reviewers' -and @($_.reviewers | Where-Object { $_ }).Count -gt 0 } })
if ($reviewerRule.Count -gt 0) {
    Write-Host "Production already has required reviewers for $repository; existing protection settings were not changed."
    return
}

if ($production) {
    $unsupportedRules = @($production.protection_rules | Where-Object { $_.type -notin @('wait_timer', 'required_reviewers') })
    if ($unsupportedRules.Count -gt 0) {
        throw "Production has additional protection rules; configure required reviewers in GitHub without changing those rules."
    }
}

$userJson = gh api user 2>&1
if ($LASTEXITCODE -ne 0) { throw 'Cannot identify the authenticated GitHub reviewer.' }
$user = $userJson | ConvertFrom-Json
if (-not $user.PSObject.Properties['id'] -or -not $user.PSObject.Properties['login'] -or -not $user.id -or -not $user.login) {
    throw 'GitHub did not return an authenticated reviewer ID and login.'
}

$body = @{
    reviewers = @(@{ type = 'User'; id = $user.id })
    prevent_self_review = $false
}
if ($production) {
    $timer = $production.protection_rules | Where-Object { $_.type -eq 'wait_timer' } | Select-Object -First 1
    if ($timer) { $body.wait_timer = $timer.wait_timer }
    if ($production.deployment_branch_policy) { $body.deployment_branch_policy = $production.deployment_branch_policy }
}
$resultJson = ($body | ConvertTo-Json -Depth 10 -Compress) | gh api --method PUT "repos/$repository/environments/production" --input - 2>&1
if ($LASTEXITCODE -ne 0) { throw "Cannot configure required production reviewers for $repository." }
$result = $resultJson | ConvertFrom-Json
$configured = @($result.protection_rules | Where-Object { $_.type -eq 'required_reviewers' -and @($_.reviewers | Where-Object { $_.type -eq 'User' -and $_.reviewer.id -eq $user.id }).Count -gt 0 })
if ($configured.Count -eq 0) { throw "GitHub did not confirm the required production reviewer for $repository." }
if ($production) {
    $resultTimer = $result.protection_rules | Where-Object { $_.type -eq 'wait_timer' } | Select-Object -First 1
    if ($timer -and (-not $resultTimer -or $resultTimer.wait_timer -ne $timer.wait_timer)) {
        throw 'GitHub did not preserve the production wait timer; review environment settings.'
    }
    $previousPolicy = $production.deployment_branch_policy
    $resultPolicy = $result.deployment_branch_policy
    if (($null -eq $previousPolicy) -ne ($null -eq $resultPolicy) -or
        ($previousPolicy -and ($previousPolicy.protected_branches -ne $resultPolicy.protected_branches -or $previousPolicy.custom_branch_policies -ne $resultPolicy.custom_branch_policies))) {
        throw 'GitHub did not preserve the production deployment branch policy; review environment settings.'
    }
    if ($production.PSObject.Properties['can_admins_bypass'] -and
        (-not $result.PSObject.Properties['can_admins_bypass'] -or $result.can_admins_bypass -ne $production.can_admins_bypass)) {
        throw 'GitHub did not preserve the production administrator bypass setting; review environment settings.'
    }
}
Write-Host "Production requires approval from $($user.login) for $repository. GitHub administrators may bypass protection if that environment permits it."
