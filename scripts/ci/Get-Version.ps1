<#
.SYNOPSIS
Builds a version string from date/time defaults or explicit version parts.

.DESCRIPTION
Syntax: Get-Version [-VersionToReplace <String>] [-Major <String>] [-Minor <String>] [-Revision <String>] [-Build <String>] [-Patch <String>] [-PreRelease <String>] [-CommitHash <String>]

.EXAMPLE
# Default (auto date/time for revision/build/patch):
# Defaults: Major=1, Minor=0, Revision=(day of year), Build=(hour+minute), Patch=(month)
.\Get-Version.ps1

.EXAMPLE
# Set explicit major/minor (auto rest):
# Defaults: Revision=(day of year), Build=(hour+minute), Patch=(month)
.\Get-Version.ps1 -Major 2 -Minor 5

.EXAMPLE
# Full explicit version (no auto):
# No defaults: all values are explicit
.\Get-Version.ps1 -Major 1 -Minor 2 -Revision 3 -Build 4 -Patch 5

.EXAMPLE
# Pre-release and commit hash:
# Defaults: Revision=(day of year), Build=(hour+minute)
.\Get-Version.ps1 -Major 1 -Minor 0 -Patch 1 -PreRelease -beta -CommitHash +abc123
#>

# ***
# *** Parameters
# ***
param(
    [string] $VersionToReplace = '1.0.0',
    [string] $Major = '-1',
    [string] $Minor = '-1',
    [string] $Revision = '-1',
    [string] $Build = '-1',
    [string] $Patch = '-1',
    [string] $PreRelease = '-1',
    [string] $CommitHash = '-1'
)

# ***
# *** Initialize
# ***


# ***
# *** Locals
# ***

# ***
# *** Execute
# ***

# Calculate version parts with defaults and protect against blank/null
function Use-ValueOrDefault {
    param($Value, $Default)
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -eq '-1') { return $Default }
    return $Value
}

$Major = Use-ValueOrDefault $Major (($VersionToReplace -split '\.')[0])
if ([string]::IsNullOrWhiteSpace($Major)) { $Major = '0' }

$Minor = Use-ValueOrDefault $Minor (($VersionToReplace -split '\.')[1])
if ([string]::IsNullOrWhiteSpace($Minor)) { $Minor = '0' }

$Revision = Use-ValueOrDefault $Revision ((Get-Date -UFormat '%j').ToString())
if ([string]::IsNullOrWhiteSpace($Revision)) { $Revision = '0' }

$Build = Use-ValueOrDefault $Build ((Get-Date -UFormat '%H%M').ToString())
if ([string]::IsNullOrWhiteSpace($Build)) { $Build = '0' }

$Patch = Use-ValueOrDefault $Patch ((Get-Date -UFormat '%m').ToString())
if ([string]::IsNullOrWhiteSpace($Patch)) { $Patch = '0' }

$PreRelease = Use-ValueOrDefault $PreRelease ''
$CommitHash = Use-ValueOrDefault $CommitHash ''


# Remove leading zeros for all numeric identifiers
$vMajor = [int]$Major
$vMinor = [int]$Minor
$vRevision = [int]$Revision
$vBuild = [int]$Build
$vPatch = [int]$Patch

# Version Formats
$FileVersion = "$vMajor.$vMinor.$vRevision.$vBuild" # e.g. 1.0.0.0
$AssemblyVersion = "$vMajor.$vMinor.0.0"
$InformationalVersion = "$vMajor.$vMinor.$vRevision$PreRelease$CommitHash"
$SemanticVersion = "$vMajor.$vMinor.$vPatch$PreRelease"

$result = [PSCustomObject]@{
	FileVersion = $FileVersion
	AssemblyVersion = $AssemblyVersion
	InformationalVersion = $InformationalVersion
	SemanticVersion = $SemanticVersion
}

$result | ConvertTo-Json -Compress
