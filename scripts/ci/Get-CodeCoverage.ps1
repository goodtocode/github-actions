####################################################################################
# Native .NET code coverage summary (plain stats)
#
# Usage:
#   .\.github\scripts\ci\Get-CodeCoverage.ps1
#   .\.github\scripts\ci\Get-CodeCoverage.ps1 -TestRootPath .\src
#   .\.github\scripts\ci\Get-CodeCoverage.ps1 -IncludeTests
#   .\.github\scripts\ci\Get-CodeCoverage.ps1 -TestProjectFilter "*Tests.Integration.csproj" -Configuration Debug
####################################################################################

Param(
    [string]$TestRootPath = (Join-Path $PSScriptRoot '..\..\..\src'),
    [string]$TestProjectFilter = '*Tests*.csproj',
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Debug',
    [switch]$IncludeTests
)

if ($IsWindows) {
    Set-ExecutionPolicy Unrestricted -Scope Process -Force
}

$ErrorActionPreference = 'Stop'

function Install-DotnetCoverageTool {
    $tool = Get-Command dotnet-coverage -ErrorAction SilentlyContinue
    if ($null -eq $tool) {
        Write-Host "Installing dotnet-coverage global tool..."
        dotnet tool install -g dotnet-coverage | Out-Null
    }
}

function Get-Bar {
    param(
        [Parameter(Mandatory = $true)]
        [double]$Percent,
        [int]$Width = 30
    )

    $clamped = [math]::Max(0, [math]::Min(100, $Percent))
    $filled = [int][math]::Round(($clamped / 100) * $Width)
    $empty = $Width - $filled
    return ('[' + ('#' * $filled) + ('-' * $empty) + ']')
}

function Get-CoverageColor {
    param(
        [Parameter(Mandatory = $true)]
        [double]$Percent
    )

    if ($Percent -ge 85) { return 'Green' }
    if ($Percent -ge 70) { return 'Yellow' }
    return 'Red'
}

function Get-ModuleDisplayName {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Module
    )

    $name = [string]$Module.module_name
    if ([string]::IsNullOrWhiteSpace($name)) {
        $name = [string]$Module.name
    }

    if ([string]::IsNullOrWhiteSpace($name)) {
        $name = [string]$Module.path
    }

    if ([string]::IsNullOrWhiteSpace($name)) {
        $name = [string]$Module.id
    }

    if ([string]::IsNullOrWhiteSpace($name)) {
        return '<unknown-module>'
    }

    return [System.IO.Path]::GetFileNameWithoutExtension($name)
}

function Test-IsTestArtifact {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }

    return ($Value -match '(?i)(^|[.\\/_-])tests?([.\\/_-]|$)|integrationtests?')
}

function Get-FileCoverageFromModules {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Modules,
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot
    )

    $fileStats = @{}

    foreach ($module in $Modules) {
        $moduleName = Get-ModuleDisplayName -Module $module
        $sourceFileById = @{}

        $sourceFiles = @($module.source_files.source_file)
        if ($sourceFiles.Count -eq 0) {
            $sourceFiles = @($module.source_file_names.source_file)
        }

        foreach ($sourceFile in $sourceFiles) {
            $sourceFileById[[string]$sourceFile.id] = [string]$sourceFile.path
        }

        foreach ($function in @($module.functions.function)) {
            foreach ($range in @($function.ranges.range)) {
                $sourceId = [string]$range.source_id
                if ([string]::IsNullOrWhiteSpace($sourceId)) {
                    continue
                }

                $sourcePath = $sourceFileById[$sourceId]
                if ([string]::IsNullOrWhiteSpace($sourcePath)) {
                    continue
                }

                if (-not $fileStats.ContainsKey($sourcePath)) {
                    $fileStats[$sourcePath] = @{
                        CoveredLines = @{}
                        TotalLines = @{}
                        Modules = @{}
                    }
                }

                $startLine = [int]$range.start_line
                $endLine = [int]$range.end_line
                $isCovered = ([string]$range.covered -eq 'yes')

                for ($line = $startLine; $line -le $endLine; $line++) {
                    $fileStats[$sourcePath].TotalLines[$line] = $true
                    if ($isCovered) {
                        $fileStats[$sourcePath].CoveredLines[$line] = $true
                    }
                }

                $fileStats[$sourcePath].Modules[$moduleName] = $true
            }
        }
    }

    $result = foreach ($path in $fileStats.Keys) {
        $coveredCount = $fileStats[$path].CoveredLines.Count
        $totalCount = $fileStats[$path].TotalLines.Count
        $percent = if ($totalCount -eq 0) { 0 } else { [math]::Round(($coveredCount / [double]$totalCount) * 100, 2) }

        $displayPath = $path
        if ($path.StartsWith($RepoRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            $displayPath = $path.Substring($RepoRoot.Length).TrimStart('\')
        }

        [PSCustomObject]@{
            Path = $displayPath
            Covered = $coveredCount
            Total = $totalCount
            Percent = $percent
            Modules = ($fileStats[$path].Modules.Keys | Sort-Object) -join ', '
        }
    }

    return @($result)
}

function Resolve-TestRootPath {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.DirectoryInfo]$ScriptDir,
        [Parameter(Mandatory = $false)]
        [string]$OverridePath
    )

    if (-not [string]::IsNullOrWhiteSpace($OverridePath)) {
        $resolvedOverride = Resolve-Path -Path $OverridePath -ErrorAction SilentlyContinue
        if ($null -ne $resolvedOverride) {
            return $resolvedOverride.Path
        }

        throw "The test root path '$OverridePath' could not be resolved."
    }

    $current = $ScriptDir
    while ($null -ne $current) {
        $srcCandidate = Join-Path $current.FullName 'src'
        if (Test-Path -Path $srcCandidate) {
            return (Resolve-Path -Path $srcCandidate).Path
        }

        $current = $current.Parent
    }

    throw "Could not resolve test root path. Pass -TestRootPath explicitly."
}

$scriptDir = Get-Item -Path $PSScriptRoot
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$resolvedRoot = Resolve-TestRootPath -ScriptDir $scriptDir -OverridePath $TestRootPath
$resultsRoot = Join-Path $resolvedRoot 'TestResults\Coverage'
New-Item -ItemType Directory -Force -Path $resultsRoot | Out-Null

$runStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$combinedXml = Join-Path $resultsRoot "coverage-$runStamp.xml"
$runStart = Get-Date

$testProjects = Get-ChildItem -Path $resolvedRoot -Filter $TestProjectFilter -Recurse
if ($testProjects.Count -eq 0) {
    Write-Error "No test projects found under '$resolvedRoot' matching '$TestProjectFilter'."
}

Write-Host "Found $($testProjects.Count) test project(s)."
Write-Host ''
Write-Host 'Test Projects' -ForegroundColor Cyan
Write-Host '-------------' -ForegroundColor Cyan
foreach ($project in $testProjects) {
    Write-Host "- $($project.Name)"
}
Write-Host ''

foreach ($project in $testProjects) {
    Write-Host "Running: $($project.FullName)"
    dotnet test $project.FullName --configuration $Configuration --collect:"Code Coverage" -v minimal
}

$coverageFiles = Get-ChildItem -Path $resolvedRoot -Filter '*.coverage' -Recurse |
    Where-Object { $_.LastWriteTime -ge $runStart.AddSeconds(-3) } |
    Select-Object -ExpandProperty FullName

if ($coverageFiles.Count -eq 0) {
    Write-Error "No .coverage files found after test execution."
}

Install-DotnetCoverageTool

Write-Host "Merging $($coverageFiles.Count) coverage file(s)..."
dotnet-coverage merge $coverageFiles --output $combinedXml --output-format xml | Out-Null

if (-not (Test-Path -Path $combinedXml)) {
    Write-Error "Coverage XML was not generated at '$combinedXml'."
}

[xml]$xml = Get-Content -Path $combinedXml
$modules = @($xml.results.modules.module)

if ($modules.Count -eq 0) {
    Write-Error "Coverage XML does not contain module data."
}

$lineCovered = [int](($modules | Measure-Object -Property lines_covered -Sum).Sum)
$lineNotCovered = [int](($modules | Measure-Object -Property lines_not_covered -Sum).Sum)
$linePartial = [int](($modules | Measure-Object -Property lines_partially_covered -Sum).Sum)
$lineTotal = $lineCovered + $lineNotCovered + $linePartial
$linePct = if ($lineTotal -eq 0) { 0 } else { [math]::Round((($lineCovered + $linePartial) / [double]$lineTotal) * 100, 2) }

$blockCovered = [int](($modules | Measure-Object -Property blocks_covered -Sum).Sum)
$blockNotCovered = [int](($modules | Measure-Object -Property blocks_not_covered -Sum).Sum)
$blockTotal = $blockCovered + $blockNotCovered
$blockPct = if ($blockTotal -eq 0) { 0 } else { [math]::Round(($blockCovered / [double]$blockTotal) * 100, 2) }

$moduleCoverage = foreach ($module in $modules) {
    $moduleLineCovered = [int]$module.lines_covered
    $moduleLineNotCovered = [int]$module.lines_not_covered
    $moduleLinePartial = [int]$module.lines_partially_covered
    $moduleLineTotal = $moduleLineCovered + $moduleLineNotCovered + $moduleLinePartial
    $moduleLinePct = if ($moduleLineTotal -eq 0) { 0 } else { [math]::Round((($moduleLineCovered + $moduleLinePartial) / [double]$moduleLineTotal) * 100, 2) }

    [PSCustomObject]@{
        Name = Get-ModuleDisplayName -Module $module
        Covered = $moduleLineCovered + $moduleLinePartial
        Total = $moduleLineTotal
        Percent = $moduleLinePct
    }
}

$moduleCoverageSorted = $moduleCoverage | Sort-Object -Property Percent, Name

$fileCoverage = Get-FileCoverageFromModules -Modules $modules -RepoRoot $repoRoot

$moduleCoverageDisplay = if ($IncludeTests) {
    $moduleCoverage
} else {
    $moduleCoverage | Where-Object { -not (Test-IsTestArtifact -Value $_.Name) }
}

$fileCoverageDisplay = if ($IncludeTests) {
    $fileCoverage
} else {
    $fileCoverage | Where-Object {
        (-not (Test-IsTestArtifact -Value $_.Path)) -and
        (-not (Test-IsTestArtifact -Value $_.Modules))
    }
}

$moduleCoverageSorted = $moduleCoverageDisplay | Sort-Object -Property Percent, Name
$moduleCoverageTop = $moduleCoverageSorted | Select-Object -Last 5
$moduleCoverageBottom = $moduleCoverageSorted | Select-Object -First 5

$fileCoverageSorted = $fileCoverageDisplay | Sort-Object -Property Percent, Path
$fileCoverageBottom = $fileCoverageSorted | Select-Object -First 10

Write-Host ''
Write-Host 'Coverage Summary' -ForegroundColor Cyan
Write-Host '----------------' -ForegroundColor Cyan
if ($IncludeTests) {
    Write-Host 'Scope         : Including test projects and files' -ForegroundColor DarkGray
} else {
    Write-Host 'Scope         : Excluding test projects and files (use -IncludeTests to include)' -ForegroundColor DarkGray
}

$lineBar = Get-Bar -Percent $linePct
$lineColor = Get-CoverageColor -Percent $linePct
Write-Host ("Line coverage : {0} {1}% ({2}/{3})" -f $lineBar, $linePct, $lineCovered, $lineTotal) -ForegroundColor $lineColor

$blockBar = Get-Bar -Percent $blockPct
$blockColor = Get-CoverageColor -Percent $blockPct
Write-Host ("Block coverage: {0} {1}% ({2}/{3})" -f $blockBar, $blockPct, $blockCovered, $blockTotal) -ForegroundColor $blockColor

Write-Host ''
Write-Host 'Lowest Coverage Projects/Assemblies' -ForegroundColor Yellow
Write-Host '-----------------------------------' -ForegroundColor Yellow
if ($moduleCoverageBottom.Count -gt 0) {
    foreach ($item in $moduleCoverageBottom) {
        $itemBar = Get-Bar -Percent $item.Percent -Width 20
        $itemColor = Get-CoverageColor -Percent $item.Percent
        Write-Host ("{0,-40} {1} {2,6}% ({3}/{4})" -f $item.Name, $itemBar, $item.Percent, $item.Covered, $item.Total) -ForegroundColor $itemColor
    }
} else {
    Write-Host 'No projects/assemblies available after filtering.' -ForegroundColor Yellow
}

Write-Host ''
Write-Host 'Highest Coverage Projects/Assemblies' -ForegroundColor Green
Write-Host '------------------------------------' -ForegroundColor Green
if ($moduleCoverageTop.Count -gt 0) {
    foreach ($item in ($moduleCoverageTop | Sort-Object -Property Percent, Name -Descending)) {
        $itemBar = Get-Bar -Percent $item.Percent -Width 20
        $itemColor = Get-CoverageColor -Percent $item.Percent
        Write-Host ("{0,-40} {1} {2,6}% ({3}/{4})" -f $item.Name, $itemBar, $item.Percent, $item.Covered, $item.Total) -ForegroundColor $itemColor
    }
} else {
    Write-Host 'No projects/assemblies available after filtering.' -ForegroundColor Yellow
}

if ($fileCoverageBottom.Count -gt 0) {
    Write-Host ''
    Write-Host 'Lowest Coverage Files (Top 10 To Improve)' -ForegroundColor Magenta
    Write-Host '-----------------------------------------' -ForegroundColor Magenta
    foreach ($item in $fileCoverageBottom) {
        $itemBar = Get-Bar -Percent $item.Percent -Width 16
        $itemColor = Get-CoverageColor -Percent $item.Percent
        Write-Host ("{0,-60} {1} {2,6}% ({3}/{4})" -f $item.Path, $itemBar, $item.Percent, $item.Covered, $item.Total) -ForegroundColor $itemColor
    }
} else {
    Write-Host ''
    Write-Host 'File-level coverage details were not available in this XML format.' -ForegroundColor Yellow
}

Write-Host ''
Write-Host "Coverage xml  : $combinedXml" -ForegroundColor DarkGray
