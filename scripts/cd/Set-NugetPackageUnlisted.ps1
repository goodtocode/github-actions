<#
.SYNOPSIS
Unlists (hides) all versions of a specified NuGet package from a NuGet feed.
.DESCRIPTION
This script queries the NuGet API for all versions of a given package and unlists (hides) each version using nuget.exe delete. If nuget.exe is not found, it will attempt to install it using winget. Requires PowerShell 7+ and winget to be installed. You must provide a valid NuGet API key with permission to unlist (hide) the package.

IMPORTANT:
- nuget.exe delete will UNLIST (hide) a package version on nuget.org (it does NOT permanently delete).
- dotnet nuget delete will PERMANENTLY DELETE a package version from nuget.org.
.PARAMETER PackageName
The name of the NuGet package to unlist (hide).
.PARAMETER ApiKey
The NuGet API key with permission to unlist (hide) the package.
.PARAMETER Source
The NuGet source/feed URL. Defaults to https://api.nuget.org/v3/index.json
.EXAMPLE
pwsh ./Set-NugetPackageUnlisted.ps1 -PackageName My.Package -ApiKey <NUGET_API_KEY>
.EXAMPLE
pwsh ./Set-NugetPackageUnlisted.ps1 -PackageName My.Package -ApiKey <NUGET_API_KEY> -Source "https://my.custom.nuget/feed/v3/index.json"
#>


param(
    [Parameter(Mandatory)]
    [string]$PackageName, 
    [Parameter(Mandatory)]
    [string]$ApiKey,
    [string]$Source = "https://api.nuget.org/v3/index.json"
)

$ErrorActionPreference = 'Stop'

# Check for nuget.exe, install with winget if missing
function Ensure-NugetExe {
    $nugetCmd = "nuget.exe"
    $nugetPath = (Get-Command $nugetCmd -ErrorAction SilentlyContinue)?.Source
    if (-not $nugetPath) {
        Write-Host "nuget.exe not found. Attempting to install via winget..." -ForegroundColor Yellow
        try {
            winget install --id Microsoft.NuGet -e --accept-source-agreements --accept-package-agreements
        } catch {
            Write-Error "Failed to install nuget.exe using winget. Please install it manually and ensure it's in your PATH. $_"
            exit 1
        }
        $nugetPath = (Get-Command $nugetCmd -ErrorAction SilentlyContinue)?.Source
        if (-not $nugetPath) {
            Write-Error "nuget.exe still not found after installation. Please restart your console or PowerShell session to reload your PATH, then try again. If the problem persists, ensure nuget.exe is in your PATH."
            exit 1
        }
    }
    return $nugetPath
}

# Ensure nuget.exe is available
$NugetExe = Ensure-NugetExe

$flatApiUrl = "https://api.nuget.org/v3-flatcontainer/$($PackageName.ToLowerInvariant())/index.json"

Write-Host "Querying all versions for package: $PackageName" -ForegroundColor Cyan
try {
    $response = Invoke-RestMethod -Uri $flatApiUrl
    $versions = $response.versions
} catch {
    Write-Error "Failed to query package versions. Ensure the package exists and the name is correct. $_"
    exit 1
}

if (-not $versions) {
    Write-Warning "No versions found for package $PackageName."
    exit 0
}

foreach ($version in $versions) {
    Write-Host "Unlisting (hiding) $PackageName $version..." -ForegroundColor Yellow
    try {
        # nuget.exe delete will UNLIST (hide) the package version on nuget.org
        & $NugetExe delete $PackageName $version -Source $Source -ApiKey $ApiKey -NonInteractive
        Write-Host "Successfully unlisted (hidden) $PackageName $version" -ForegroundColor Green
    } catch {
        Write-Warning "Failed to unlist (hide) $PackageName $version"
    }
}

Write-Host "Completed unlisting (hiding) all versions of $PackageName." -ForegroundColor Cyan