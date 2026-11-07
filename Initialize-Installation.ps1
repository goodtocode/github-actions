<#
.SYNOPSIS
Initializes local development, CI/CD configuration, and Azure identity dependencies.
.DESCRIPTION
Copy this launcher to the consuming product root and scripts/setup to .github/scripts/setup.
.EXAMPLE
./Initialize-Installation.ps1 -Mode Local
.EXAMPLE
./Initialize-Installation.ps1 -Mode Cloud -SqlAuthentication SqlAuth
.EXAMPLE
./Initialize-Installation.ps1 -Mode Cloud -Stage Complete
#>
[CmdletBinding()]
param(
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
    [string]$ResourceGroupName,
    [ValidateSet('EntraOnly', 'SqlAuth')][string]$SqlAuthentication = 'EntraOnly',
    [string]$SqlAdministratorGroupObjectId,
    [string]$AzureOpenAIEndpoint,
    [switch]$CreateRepository,
    [switch]$SkipDatabase,
    [switch]$RotateSecrets,
    [switch]$InstallPrerequisites
)
& "$PSScriptRoot/.github/scripts/setup/Initialize-Product.ps1" -RepositoryRoot $PSScriptRoot @PSBoundParameters