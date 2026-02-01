####################################################################################
# To execute
#   1. Run Powershell as ADMINistrator
#   2. In powershell, set security polilcy for this script: 
#      Set-ExecutionPolicy Unrestricted -Scope Process -Force
#   3. Change directory to the script folder:
#      CD C:\Scripts (wherever your script is)
#   4. In powershell, run script: 
#      .\New-Github-Azure-Federation.ps1  -TenantId 12343dac-0e69-436a-866b-456727dd3579 -SubscriptionId 12343dac-0e69-436a-866b-456727dd3579 -PrincipalName myco-github-devtest-001 -Organization mygithuborg -Repository mygithubrepo -Environment development
####################################################################################

param (
   [Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true)]
   [guid]$TenantId = $(throw '-TenantId is a required parameter.'), #12343dac-0e69-436a-866b-456727dd3579
   [Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true)]
   [guid]$SubscriptionId = $(throw '-SubscriptionId is a required parameter.'), #12343dac-0e69-436a-866b-456727dd3579
   [Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true)]
   [string]$PrincipalName = $(throw '-PrincipalName is a required parameter.'), #Example: COMPANY-SUB_OR_PRODUCTLINE-github-001
   [Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true)]
   [string]$Organization = $(throw '-Organization is a required parameter.'), #GitHub Organization Name
   [Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true)]
   [string]$Repository = $(throw '-Repository is a required parameter.'), #GitHub Repository Name
   [Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true)]
   [string]$Environment = $(throw '-Environment is a required parameter.') #GitHub Repository Environment: development, production
)
####################################################################################
Set-ExecutionPolicy Unrestricted -Scope Process -Force
$VerbosePreference = 'SilentlyContinue' # 'SilentlyContinue' # 'Continue'
[String]$ThisScript = $MyInvocation.MyCommand.Path
[String]$ThisDir = Split-Path $ThisScript
Set-Location $ThisDir # Ensure our location is correct, so we can use relative paths
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

if ($null -eq $currentContext -or $currentContext.Subscription.Id -ne $SubscriptionId) {
   Write-Host "Logging in to Azure with SubscriptionId: $SubscriptionId"
   Connect-AzAccount -TenantId $TenantId -SubscriptionId $SubscriptionId 
} else {
   Write-Host "Already logged in to the correct Azure subscription."
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

# Idempotent Role Assignment
$roleAssignment = Get-AzRoleAssignment -ObjectId $spObjectId -RoleDefinitionName Contributor -Scope "/subscriptions/$SubscriptionId" -ErrorAction SilentlyContinue
if (-not $roleAssignment) {
   New-AzRoleAssignment -ObjectId $spObjectId -RoleDefinitionName Contributor -Scope "/subscriptions/$SubscriptionId"
}
else {
   Write-Host "Role assignment already exists."
}

$tenantId = (Get-AzContext).Subscription.TenantId

# Create new App Registration Federated Credentials for the GitHub operations
$subjectRepo = "repo:" + $Organization + "/" + $Repository + ":environment:" + $Environment
$existingCredRepo = Get-AzADAppFederatedCredential -ApplicationObjectId $appObjectId -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq "$PrincipalName-repo" }
if (-not $existingCredRepo) {
   New-AzADAppFederatedCredential -ApplicationObjectId $appObjectId -Audience api://AzureADTokenExchange -Issuer 'https://token.actions.githubusercontent.com' -Name "$PrincipalName-repo" -Subject "$subjectRepo"
}
else {
   Write-Host "Federated credential $PrincipalName-repo already exists."
}
$subjectRepoMain = "repo:" + $Organization + "/" + $Repository + ":ref:refs/heads/main"
$existingCredMain = Get-AzADAppFederatedCredential -ApplicationObjectId $appObjectId -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq "$PrincipalName-main" }
if (-not $existingCredMain) {
   New-AzADAppFederatedCredential -ApplicationObjectId $appObjectId -Audience api://AzureADTokenExchange -Issuer 'https://token.actions.githubusercontent.com' -Name "$PrincipalName-main" -Subject "$subjectRepoMain"
}
else {
   Write-Host "Federated credential $PrincipalName-main already exists."
}
$subjectRepoPR = "repo:" + $Organization + "/" + $Repository + ":pull_request"
$existingCredPR = Get-AzADAppFederatedCredential -ApplicationObjectId $appObjectId -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq "$PrincipalName-PR" }
if (-not $existingCredPR) {
   New-AzADAppFederatedCredential -ApplicationObjectId $appObjectId -Audience api://AzureADTokenExchange -Issuer 'https://token.actions.githubusercontent.com' -Name "$PrincipalName-PR" -Subject "$subjectRepoPR"
}
else {
   Write-Host "Federated credential $PrincipalName-PR already exists."
}

Write-Host "AZURE_TENANT_ID: $tenantId"
Write-Host "AZURE_SUBSCRIPTION_ID: $SubscriptionId"
Write-Host "AZURE_CLIENT_ID: $clientId"