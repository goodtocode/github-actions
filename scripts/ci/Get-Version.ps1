#-----------------------------------------------------------------------
<#
Get-Version [-VersionToReplace <String>] [-Major <String>] [-Minor <String>] [-Revision <String>] [-Build <String>] [-Patch <String>] [-PreRelease <String>] [-CommitHash <String>]

Example: .\Get-Version.ps1 -Major 1 -Minor 0
#>
#-----------------------------------------------------------------------

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

# Version Formats
$FileVersion = "$Major.$Minor.$Revision.$Build" # e.g. 1.0.0.0
$AssemblyVersion = "$Major.$Minor.0.0"
$InformationalVersion = "$Major.$Minor.$Revision$PreRelease$CommitHash"
$SemanticVersion = "$Major.$Minor.$Patch$PreRelease"

$result = [PSCustomObject]@{
	FileVersion = $FileVersion
	AssemblyVersion = $AssemblyVersion
	InformationalVersion = $InformationalVersion
	SemanticVersion = $SemanticVersion
}

$result | ConvertTo-Json -Compress
