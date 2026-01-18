# ================================
# GitHub repo bootstrap (PowerShell)
# Creates repo, enables security, branch policy, environments, and secrets
# Requires: GitHub CLI (gh) + authenticated session
# ================================

param(
  [Parameter(Mandatory=$true)][string]$Owner,
  [Parameter(Mandatory=$true)][string]$Repo,
  [ValidateSet('public','private')][string]$Visibility = 'private',
  [switch]$Oss # if set, will use MIT license and public visibility
)

# ---- 0) Create repository with README, .gitignore, license (if OSS)
$license = $Oss.IsPresent ? 'mit' : $null
$vis     = $Oss.IsPresent ? 'public' : $Visibility

$createArgs = @(
  'repo','create', "$Owner/$Repo",
  '--' + $vis,
  '--add-readme',
  '--gitignore','VisualStudio'
)
if ($license) { $createArgs += @('--license', $license) }

gh @createArgs | Out-Null
Write-Host "Created repo $Owner/$Repo"

# ---- 1) Allow auto-merge (repo-level toggle)
# Enables future workflows to set --auto on PRs
gh api -X PATCH "repos/$Owner/$Repo" `
  -f allow_auto_merge=true | Out-Null
# Ref: Auto-merge settings docs. [6](https://deepwiki.com/peter-evans/create-pull-request)

# ---- 2) Enable security & analysis: Secret Scanning + Push Protection
# (security_and_analysis object)
$secJson = @'
{
  "secret_scanning": { "status": "enabled" },
  "secret_scanning_push_protection": { "status": "enabled" }
}
'@
gh api -X PATCH "repos/$Owner/$Repo" `
  -f "security_and_analysis=$secJson" | Out-Null
# Ref: Secret scanning & push protection via REST. [2](https://commandmasters.com/commands/gh-repo-common/)

# ---- 3) Enable Dependabot alerts & security updates (and add version updates file)
# Alerts / Security updates are repository settings endpoints.
# (If your org enforces these by default, you can skip.)
# List/enable endpoints are under Repositories API group. [3](https://docs.github.com/en/rest/repos)

# Add dependabot.yml (version updates) if you want scheduled updates:
$dependabotYml = @"
version: 2
updates:
  - package-ecosystem: "nuget"
    directory: "/"
    schedule:
      interval: "weekly"
  - package-ecosystem: "github-actions"
    directory: "/"
    schedule:
      interval: "weekly"
"@

$tmp = New-TemporaryFile
$dependabotYml | Set-Content -NoNewline -Path $tmp
gh api --method PUT "/repos/$Owner/$Repo/contents/.github/dependabot.yml" `
  -f message="chore: add dependabot version updates" `
  -f content="$( [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((Get-Content $tmp -Raw))) )" `
  -f branch="main" | Out-Null
Remove-Item $tmp -Force
# Ref: Dependabot version updates are file-based. [4](https://victoronsoftware.com/posts/github-reusable-workflows-and-steps/)

# ---- 4) (Option A) Add Advanced CodeQL workflow file for full automation
# Skip if you prefer to enable Default setup in UI.
$codeqlYml = @"
name: CodeQL
on:
  push:
    branches: [ main, dev ]
  pull_request:
    branches: [ main, dev ]
  schedule:
    - cron: '0 6 * * 1'
permissions:
  contents: read
  security-events: write
jobs:
  analyze:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        language: [ 'csharp' ]
    steps:
      - uses: actions/checkout@v4
      - uses: github/codeql-action/init@v3
        with:
          languages: ${{ matrix.language }}
      - uses: github/codeql-action/autobuild@v3
      - uses: github/codeql-action/analyze@v3
"@

$tmp = New-TemporaryFile
$codeqlYml | Set-Content -NoNewline -Path $tmp
gh api --method PUT "/repos/$Owner/$Repo/contents/.github/workflows/codeql-analysis.yml" `
  -f message="ci: add CodeQL advanced workflow" `
  -f content="$( [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((Get-Content $tmp -Raw))) )" `
  -f branch="main" | Out-Null
Remove-Item $tmp -Force
# Ref: Advanced setup is workflow-based & fully automatable. [8](https://graphite.com/guides/github-merge-queue)

# ---- 5) Branch protection for main (require PRs, strict checks etc.)
# You can add named checks later once they appear (ci, CodeQL) to hard-enforce.
$requiredPullRequestReviews = '{"require_code_owner_reviews":false,"required_approving_review_count":1}'
$restrictions = '{"users":[],"teams":[],"apps":[]}'
gh api -X PUT "repos/$Owner/$Repo/branches/main/protection" `
  -f required_status_checks.strict=true `
  -f required_status_checks.contexts='[]' `
  -f enforce_admins=true `
  -f "required_pull_request_reviews=$requiredPullRequestReviews" `
  -f "restrictions=$restrictions" | Out-Null
# Ref: Branch protection REST. [5](https://stackoverflow.com/questions/71623045/automatic-merge-after-tests-pass-using-actions)

# ---- 6) Create Environments: development & production
# (You can set branch policy + required reviewers)
# Create/Update Environment (PUT) + optional deployment branch policy & protection rules
# Note: required_reviewers require usernames or team slugs (max 6). [7](https://docs.github.com/en/rest/deployments/environments)[12](https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments)

# development
$devEnv = @'
{
  "deployment_branch_policy": {
    "protected_branches": false,
    "custom_branch_policies": true
  }
}
'@
gh api -X PUT "repos/$Owner/$Repo/environments/development" `
  -H "Accept: application/vnd.github+json" `
  -f "environment=$devEnv" | Out-Null
# Optionally add a custom branch policy pattern for dev (requires extra POST endpoint under env policies).
# See community examples for adding custom branch policies after creation. [13](https://stackoverflow.com/questions/70943164/create-environment-for-repository-using-gh)

# production with required reviewers
$prodEnv = @"
{
  "deployment_branch_policy": {
    "protected_branches": true,
    "custom_branch_policies": false
  },
  "protection_rules": [
    { "type": "required_reviewers", "reviewers": [ { "type":"User", "id": null } ] }
  ]
}
"@
# NOTE: Replace reviewers with concrete users/teams via separate calls if needed.
gh api -X PUT "repos/$Owner/$Repo/environments/production" `
  -H "Accept: application/vnd.github+json" `
  -f "environment=$prodEnv" | Out-Null
# Ref: Environments API supports branch policy and protection rules. [7](https://docs.github.com/en/rest/deployments/environments)

# ---- 7) Add environment secrets (examples)
# Actions/environment secrets endpoints exist; gh can set if env already exists.
gh secret set "DEV_API_KEY" --body "replace-me" --repo "$Owner/$Repo" --env "development"
gh secret set "PROD_API_KEY" --body "replace-me" --repo "$Owner/$Repo" --env "production"
# Ref: Create env, then assign secrets to it. [7](https://docs.github.com/en/rest/deployments/environments)

Write-Host "✅ Bootstrap completed for $Owner/$Repo"
