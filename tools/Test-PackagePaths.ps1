#Requires -Version 7
<#
.SYNOPSIS
    Publish gate: no unexplained absolute path reaches a shipped file of this
    package.

.DESCRIPTION
    A package that names a machine path only works on the machine it was written
    on. Phase 6 removed the last two owned hits (a provider log path and a
    provenance table) and this gate keeps them out.

    The decision of what ships is one machine-readable file,
    tools/publish-manifest.json: `ship` roots, `exclude` paths with a reason, and
    a path allowlist whose every row carries a class and a reason. This gate:

      1. classifies every file as shipped or excluded from that manifest;
      2. scans every shipped text file for an absolute path - a Windows drive
         path (optionally quoted/escaped), a POSIX home directory, or a
         users-directory form; a URL scheme is not a path and does not match;
      3. fails on any hit in a shipped file that the allowlist does not name;
      4. fails when an allowlisted file no longer has a hit (a stale excuse) or
         is not shipped at all (an excuse for something nobody gets);
      5. reports the excluded files by name, so "not shipped" is visible instead
         of silent.

    The allowlist is file-level on purpose: the entries are vendored,
    byte-identical mirrors of canonical machine defaults and documentation whose
    line numbers move on every re-sync. A file-level declaration is honest for
    that class (every hit in the file is the same kind of fact) and stable; an
    undeclared file, however small, fails.

    Exit codes
      0  every shipped file is clean or allowlisted, no stale excuse
      1  an undeclared absolute path, a stale allowlist row, or a manifest defect
      2  CANNOT-EVALUATE - the publish manifest is absent or unreadable

.PARAMETER PackageRoot
    Package root to measure. Defaults to the parent directory of this script, so
    the gate runs unchanged on a copy anywhere on disk.

.EXAMPLE
    pwsh -NoProfile -File interactive-qa/tools/Test-PackagePaths.ps1
#>
[CmdletBinding()]
param(
    [string] $PackageRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $PackageRoot) { $PackageRoot = Split-Path -Parent $PSScriptRoot }

if (-not (Test-Path -LiteralPath $PackageRoot -PathType Container)) {
    Write-Host "Test-PackagePaths: package root not found: $PackageRoot" -ForegroundColor Red
    exit 1
}

$packageFull = (Resolve-Path -LiteralPath $PackageRoot).Path
$manifestPath = Join-Path $packageFull 'tools/publish-manifest.json'

if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    Write-Host "Test-PackagePaths: CANNOT-EVALUATE - no publish manifest at $manifestPath" -ForegroundColor Yellow
    exit 2
}

try {
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding utf8 | ConvertFrom-Json
}
catch {
    Write-Host "Test-PackagePaths: CANNOT-EVALUATE - the publish manifest is unreadable: $($_.Exception.Message)" -ForegroundColor Yellow
    exit 2
}

$failures = [System.Collections.Generic.List[string]]::new()

$shipRoots = @($manifest.ship)
$excludes = @($manifest.exclude)
$allowRows = @($manifest.pathAllowlist)

if ($shipRoots.Count -eq 0) { $failures.Add('the publish manifest ships nothing - a package with no ship root has no artifact') }
foreach ($row in $excludes) {
    if ([string]::IsNullOrWhiteSpace([string]$row.path) -or [string]::IsNullOrWhiteSpace([string]$row.reason)) {
        $failures.Add('an exclude row has no path or no reason - an exclusion is a decision, not a silence')
    }
}
foreach ($row in $allowRows) {
    if ([string]::IsNullOrWhiteSpace([string]$row.path) -or [string]::IsNullOrWhiteSpace([string]$row.class) -or [string]::IsNullOrWhiteSpace([string]$row.reason)) {
        $failures.Add('a path-allowlist row has no path, class or reason - a justification needs all three')
    }
}

function Test-UnderPath {
    param([string] $Relative, [string] $Prefix)

    $normalized = $Prefix.TrimEnd('/')
    if ($normalized.EndsWith('/')) { $normalized = $normalized.Substring(0, $normalized.Length - 1) }
    return ($Relative -eq $normalized) -or $Relative.StartsWith("$normalized/", [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-UnderAny {
    param([string] $Relative, [string[]] $Prefixes)

    foreach ($prefix in $Prefixes) {
        if (Test-UnderPath -Relative $Relative -Prefix $prefix) { return $true }
    }
    return $false
}

# Text files only: a binary cannot carry a readable path, and decoding one is noise.
$textExtensions = @('.md', '.ps1', '.mjs', '.js', '.json', '.txt', '.yml', '.yaml', '.csv', '.xml')
$allFiles = Get-ChildItem -LiteralPath $packageFull -Recurse -File | ForEach-Object {
    $_.FullName.Substring($packageFull.Length).TrimStart('\', '/') -replace '\\', '/'
}

$shipped = [System.Collections.Generic.List[string]]::new()
$excluded = [System.Collections.Generic.List[string]]::new()
foreach ($relative in $allFiles) {
    if (Test-UnderAny -Relative $relative -Prefixes @($excludes | ForEach-Object { [string]$_.path })) {
        $excluded.Add($relative)
    }
    elseif (Test-UnderAny -Relative $relative -Prefixes $shipRoots) {
        $shipped.Add($relative)
    }
    else {
        $failures.Add("$relative is neither under a ship root nor a declared exclusion - the publish manifest does not decide it")
    }
}

# An absolute drive path, but not a URL scheme (https://, file:///).
$drivePattern = [regex]'(?<![A-Za-z0-9_-])[A-Za-z]:[\\/]'
# Assembled from parts so this gate does not flag its own pattern definitions.
$homePatterns = @([regex]('C:' + '/Users'), [regex]('/hom' + 'e/'), [regex]('/Use' + 'rs/'))

$allowByPath = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($row in $allowRows) { $allowByPath[[string]$row.path] = $row }

$hitsByFile = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
$scanned = 0

foreach ($relative in $shipped) {
    $extension = [System.IO.Path]::GetExtension($relative)
    if ($textExtensions -notcontains $extension) { continue }

    $path = Join-Path $packageFull $relative
    $scanned++
    $lineNumber = 0
    foreach ($line in (Get-Content -LiteralPath $path -Encoding utf8)) {
        $lineNumber++
        $hit = $drivePattern.IsMatch($line)
        if (-not $hit) {
            foreach ($homePattern in $homePatterns) {
                if ($homePattern.IsMatch($line)) { $hit = $true; break }
            }
        }
        if (-not $hit) { continue }

        if (-not $hitsByFile.ContainsKey($relative)) {
            $hitsByFile[$relative] = [pscustomobject]@{ Count = 0; Lines = [System.Collections.Generic.List[int]]::new() }
        }
        $hitsByFile[$relative].Count++
        $hitsByFile[$relative].Lines.Add($lineNumber)

        if (-not $allowByPath.ContainsKey($relative)) {
            $failures.Add("${relative}:${lineNumber}: absolute path in a shipped file, with no allowlist row - move it to an adapter or declare it with a reason")
        }
    }
}

# A declared justification for a file that is clean or absent is a stale excuse.
foreach ($relative in $allowByPath.Keys) {
    if (-not $hitsByFile.ContainsKey($relative)) {
        $failures.Add("allowlist row '$relative' has no hit - remove the stale justification")
    }
    if (-not $shipped.Contains($relative)) {
        $failures.Add("allowlist row '$relative' is not a shipped file - a justification for an unshipped file proves nothing")
    }
}

$justified = 0
foreach ($relative in ($hitsByFile.Keys | Sort-Object)) {
    if ($allowByPath.ContainsKey($relative)) {
        $justified++
        $row = $allowByPath[$relative]
        $lines = ($hitsByFile[$relative].Lines -join ',')
        Write-Output ('JUSTIFIED {0}  hits={1}  class={2}  lines={3}' -f $relative, $hitsByFile[$relative].Count, $row.class, $lines)
    }
}

Write-Output ('Test-PackagePaths: shipped {0} file(s), {1} text file(s) scanned, {2} absolute-path hit(s) across {3} file(s), {4} justified by the allowlist' -f
    $shipped.Count, $scanned, (@($hitsByFile.Values | ForEach-Object { $_.Count }) | Measure-Object -Sum).Sum, $hitsByFile.Count, $justified)
foreach ($row in $excludes) {
    $count = @($excluded | Where-Object { Test-UnderPath -Relative $_ -Prefix ([string]$row.path) }).Count
    Write-Output ('EXCLUDED  {0}  ({1} file(s))  {2}' -f $row.path, $count, $row.reason)
}

if ($failures.Count -gt 0) {
    Write-Host "Test-PackagePaths: FAILED - $($failures.Count) reason(s)" -ForegroundColor Red
    foreach ($reason in $failures) { Write-Host "  - $reason" }
    exit 1
}

Write-Host 'Test-PackagePaths: OK - every shipped file is free of unexplained absolute paths' -ForegroundColor Green
exit 0
