<#
.SYNOPSIS
Creates a federated identity so GitHub Actions can sign in to Azure.

.DESCRIPTION
Run PowerShell as ADMINistrator.
If script execution is blocked, set the policy for this process first: Set-ExecutionPolicy Unrestricted -Scope Process -Force. Then change to the script folder and run the example below.

.EXAMPLE
# From the script folder:
.\New-Github-Azure-Federation.ps1  -TenantId 12343dac-0e69-436a-866b-456727dd3579 -SubscriptionId 12343dac-0e69-436a-866b-456727dd3579 -PrincipalName myco-github-development-100 -Organization mygithuborg -Repository mygithubrepo -Environment development,production

.EXAMPLE
# Personal account repo (the owner can be a user or an organization), different Azure tenant:
.\New-Github-Azure-Federation.ps1  -TenantId <personal-tenant-id> -SubscriptionId <personal-subscription-id> -PrincipalName github-myrepo -Organization mygithubhandle -Repository myrepo -Environment development

.NOTES
Switching between accounts: the GitHub side uses the active 'gh' account (see 'gh auth status'; switch with 'gh auth switch'). The Azure side reuses a saved context for the tenant and subscription when one exists, otherwise it signs in to the -TenantId you pass.
#>

param (
   [Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true)]
   [guid]$TenantId = $(throw '-TenantId is a required parameter.'), #12343dac-0e69-436a-866b-456727dd3579
   [Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true)]
   [guid]$SubscriptionId = $(throw '-SubscriptionId is a required parameter.'), #12343dac-0e69-436a-866b-456727dd3579
   [Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true)]
   [string]$PrincipalName = $(throw '-PrincipalName is a required parameter.'), #Example: can-SUB_OR_PRODUCTLINE-github-100
   [Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true)]
   [string]$Organization = $(throw '-Organization is a required parameter.'), #GitHub Organization Name
   [Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true)]
   [string]$Repository = $(throw '-Repository is a required parameter.'), #GitHub Repository Name
   [Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true)]
   [string[]]$Environment = $(throw    '-Environment is a required parameter.') #GitHub Repository Environment(s): development, production
   )
####################################################################################
Set-ExecutionPolicy Unrestricted -Scope Process -Force
$VerbosePreference = 'SilentlyContinue' # 'SilentlyContinue' # 'Continue'
[String]$ThisScript = $MyInvocation.MyCommand.Path
[String]$ThisDir = Split-Path $ThisScript
Push-Location $ThisDir # Ensure our location is correct, so we can use relative paths; restored on exit
trap { Pop-Location -ErrorAction SilentlyContinue; break }
Write-Host "*****************************"
Write-Host "*** Starting: $ThisScript On: $(Get-Date)"
Write-Host "*****************************"
####################################################################################
# Install required modules idempotently
$modules = @('Az.Accounts', 'Az.Resources')
foreach ($module in $modules) {
   if (-not (Get-Module -ListAvailable -Name $module)) {
      Write-Host "Installing module: $module"
      Install-Module $module -Scope CurrentUser -Force
   } else {
      Write-Host "Module $module already installed."
   }
}

# Login to Azure idempotently
$currentContext = $null
try {
   $currentContext = Get-AzContext -ErrorAction Stop
} catch {}

if ($currentContext -and $currentContext.Subscription.Id -eq $SubscriptionId -and $currentContext.Tenant.Id -eq $TenantId) {
   Write-Host "Already logged in to the correct Azure tenant and subscription."
}
else {
   $savedContext = Get-AzContext -ListAvailable -ErrorAction SilentlyContinue | Where-Object { $_.Subscription.Id -eq $SubscriptionId -and $_.Tenant.Id -eq $TenantId } | Select-Object -First 1
   if ($savedContext) {
      Write-Host "Switching to saved Azure context for tenant $TenantId, subscription $SubscriptionId"
      Set-AzContext -Context $savedContext | Out-Null
   }
   else {
      Write-Host "Logging in to Azure with TenantId: $TenantId, SubscriptionId: $SubscriptionId"
      Connect-AzAccount -TenantId $TenantId -SubscriptionId $SubscriptionId
   }
}

# Get App Registration object (Application object)
$app = Get-AzADApplication -DisplayName $PrincipalName
if (-not $app) {
   $app = New-AzADApplication -DisplayName $PrincipalName
}
Write-Host "App Registration (Client) Id: $($app.AppId)"
$clientId = $app.AppId
$appObjectId = $app.Id

# Create Service Principal and assign role
$sp = Get-AzADServicePrincipal -DisplayName $PrincipalName
if (-not $sp) {
   $sp = New-AzADServicePrincipal -ApplicationId $clientId
}
Write-Host "Service Principal Id: $($sp.Id)"
$spObjectId = $sp.Id

# Idempotent Role Assignment with retry to handle Entra ID propagation delay.
$roleName = 'Contributor'
$roleScope = "/subscriptions/$SubscriptionId"
$maxAttempts = 6
$retryDelaySeconds = 10

$roleAssignment = Get-AzRoleAssignment -ObjectId $spObjectId -RoleDefinitionName $roleName -Scope $roleScope -ErrorAction SilentlyContinue
if (-not $roleAssignment) {
   for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
      try {
         Write-Host "Assigning role '$roleName' on '$roleScope' (attempt $attempt of $maxAttempts)..."
         New-AzRoleAssignment -ObjectId $spObjectId -RoleDefinitionName $roleName -Scope $roleScope -ErrorAction Stop | Out-Null
         break
      }
      catch {
         if ($attempt -eq $maxAttempts) {
            throw
         }
         Write-Host "Role assignment attempt $attempt failed. Retrying in $retryDelaySeconds seconds..."
         Start-Sleep -Seconds $retryDelaySeconds
      }
   }
}
else {
   Write-Host "Role assignment already exists."
}

# Verify role assignment exists after create/retry path.
$roleAssignment = Get-AzRoleAssignment -ObjectId $spObjectId -RoleDefinitionName $roleName -Scope $roleScope -ErrorAction SilentlyContinue
if (-not $roleAssignment) {
   throw "Failed to verify role assignment '$roleName' for service principal '$PrincipalName' at scope '$roleScope'."
}
Write-Host "Verified role assignment '$roleName' at '$roleScope'."

$tenantId = (Get-AzContext).Subscription.TenantId

# Create new App Registration Federated Credentials for the GitHub operations
# GitHub decides per repository whether the subject is 'repo:owner/repo' or the immutable 'repo:owner@ownerId/repo@repoId' form,
# so ask the repo for its subject prefix instead of building it (requires 'gh auth login' with access to the repo).
$subjectJson = gh api "repos/$Organization/$Repository/actions/oidc/customization/sub" 2>&1
if ($LASTEXITCODE -ne 0) { throw "Could not read the OIDC subject settings of $Organization/$Repository. Check 'gh auth status' (switch accounts with 'gh auth switch'). $subjectJson" }
$subjectInfo = $subjectJson | ConvertFrom-Json
$subjectPrefix = [string]$subjectInfo.sub_claim_prefix
if ($subjectPrefix -notmatch '^repo:\S+$') { throw "Unexpected OIDC subject prefix for $Organization/$Repository ('$subjectPrefix')." }
if (-not $subjectInfo.use_default) { Write-Warning "$Organization/$Repository customizes its OIDC subject claim; the credentials below assume the default claim keys." }
Write-Host "Subject prefix: $subjectPrefix (immutable: $($subjectInfo.use_immutable_subject))"

# Creates the credential, or recreates it when a credential of the same name has a different subject or issuer.
function Set-FederatedCredential([string]$Name, [string]$Subject) {
   $issuer = 'https://token.actions.githubusercontent.com'
   $existing = Get-AzADAppFederatedCredential -ApplicationObjectId $appObjectId -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $Name }
   if ($existing -and $existing.Subject -eq $Subject -and $existing.Issuer -eq $issuer) {
      Write-Host "Federated credential $Name already exists."
      return
   }
   if ($existing) {
      Write-Host "Federated credential $Name has a different subject or issuer. Recreating."
      Remove-AzADAppFederatedCredential -ApplicationObjectId $appObjectId -FederatedCredentialId $existing.Id
   }
   New-AzADAppFederatedCredential -ApplicationObjectId $appObjectId -Audience api://AzureADTokenExchange -Issuer $issuer -Name $Name -Subject $Subject | Out-Null
   Write-Host "Created federated credential $Name ($Subject)"
}

foreach ($envName in $Environment) {
   Set-FederatedCredential -Name "$PrincipalName-env-$envName" -Subject "${subjectPrefix}:environment:$envName"
}
Set-FederatedCredential -Name "$PrincipalName-main" -Subject "${subjectPrefix}:ref:refs/heads/main"
Set-FederatedCredential -Name "$PrincipalName-PR" -Subject "${subjectPrefix}:pull_request"

Write-Host "AZURE_TENANT_ID: $tenantId"
Write-Host "AZURE_SUBSCRIPTION_ID: $SubscriptionId"
Write-Host "AZURE_CLIENT_ID: $clientId"
Pop-Location