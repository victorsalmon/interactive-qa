#Requires -Version 7
<#
.SYNOPSIS
    Package gate: every helper the members name is either vendored into this
    package or explicitly excused with a reason, and every vendored file is the
    file the manifest says it is.

.DESCRIPTION
    This is the gate that stops the package silently growing a new
    out-of-package dependency again. It proves eight things and exits 1 with a
    named reason for each one that fails:

      1. The manifest has an owner and rows; no vendored path is listed twice.
      2. Every excused row carries a reason, no name is excused twice, and no
         name is both vendored and excused. A patched row (a deliberate fork of
         its canonical source) carries its patch id, its reason and BOTH hashes,
         so the fork is provable and its upstream is watched.
      3. Every manifest row exists at its vendored path.
      4. Every file under vendor/ and references/vendored/ has a
         manifest row - no orphan copy rides along unmeasured.
      5. Every vendored script parses, so a truncated copy cannot ride a hash
         claim.
      6. tools/Sync-VendoredHelpers.ps1 -Check exits 0: the vendored files match
         their recorded hashes and (when the canonical tree is reachable) their
         canonical sources. An archived row must carry its provenance (old source
         path, archived path, archived date and hash), so a hand-written
         "archived" stamp cannot excuse a row from ever being verified. A -Check
         CANNOT-EVALUATE (exit 2) is a failure here, because an absent input is a
         named non-verdict, never a pass.
      7. Every <name>.ps1 token named anywhere in the package's Markdown
         resolves: it is vendored, it is one of the package's own tools/, or it
         is named in the not-vendored manifest with a reason. A helper the
         members prescribe but the package does not ship is exactly the defect
         this gate exists for.
      8. No vendored file still names a fleet CL_REPOS_ROOT without a declared
         residual, and every declared residual still matches. A stale excusal is
         a failure, so the residual list can only shrink deliberately.

    Reads the manifest from tools/Sync-VendoredHelpers.ps1 -ListManifest, so the
    mapping has one owner and this gate cannot drift from the files it measures.

    Exit codes
      0  every check passed
      1  at least one named failure

.PARAMETER PackageRoot
    Package root to measure. Defaults to the parent directory of this script, so
    the gate works on a copy of the package anywhere on disk.

.EXAMPLE
    pwsh -NoProfile -File interactive-qa/tools/Test-VendoredHelpers.ps1

.EXAMPLE
    # prove an isolated copy, with nothing else of the repository in reach
    pwsh -NoProfile -File "$env:TEMP\iqa-pkg-isolation\tools\Test-VendoredHelpers.ps1"
#>
[CmdletBinding()]
param(
    [string] $PackageRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $PackageRoot) {
    $PackageRoot = Split-Path -Parent $PSScriptRoot
}

if (-not (Test-Path -LiteralPath $PackageRoot -PathType Container)) {
    Write-Host "Test-VendoredHelpers: package root not found: $PackageRoot" -ForegroundColor Red
    exit 1
}

$packageFull = (Resolve-Path -LiteralPath $PackageRoot).Path
$toolsDir = Join-Path $packageFull 'tools'
$syncScript = Join-Path $toolsDir 'Sync-VendoredHelpers.ps1'
$pwshPath = (Get-Command pwsh -ErrorAction Stop).Source

# Vendored files are the manifest's rows; these are the directories the manifest
# alone owns, so a file in one of them without a row is an orphan.
$ownedDirectories = @('vendor', 'references/vendored')

$failures = [System.Collections.Generic.List[string]]::new()

function Add-Failure {
    param([Parameter(Mandatory)][string] $Reason)
    $failures.Add($Reason)
}

function Invoke-ChildScript {
    param(
        [Parameter(Mandatory)][string] $Path,
        [string[]] $Arguments = @()
    )

    $output = & $pwshPath -NoProfile -NonInteractive -File $Path @Arguments 2>&1
    [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output   = @($output | ForEach-Object { "$_" })
    }
}

function Get-RelativeFiles {
    param([Parameter(Mandatory)][string] $Relative)

    $directory = Join-Path $packageFull $Relative
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { return @() }

    Get-ChildItem -LiteralPath $directory -Recurse -File | Sort-Object FullName | ForEach-Object {
        $_.FullName.Substring($packageFull.Length).TrimStart('\', '/') -replace '\\', '/'
    }
}

# --- 0. the manifest owner must be present before anything can be measured ----
if (-not (Test-Path -LiteralPath $syncScript -PathType Leaf)) {
    Write-Host "Test-VendoredHelpers: FAILED - 1 reason(s)" -ForegroundColor Red
    Write-Host "  - tools/Sync-VendoredHelpers.ps1 is missing, so the manifest has no owner: $syncScript"
    exit 1
}

$manifestRun = Invoke-ChildScript -Path $syncScript -Arguments @('-ListManifest', '-PackageRoot', $packageFull)

if ($manifestRun.ExitCode -ne 0) {
    Write-Host "Test-VendoredHelpers: FAILED - 1 reason(s)" -ForegroundColor Red
    Write-Host "  - Sync-VendoredHelpers.ps1 -ListManifest exited $($manifestRun.ExitCode):"
    foreach ($line in $manifestRun.Output) { Write-Host "      $line" }
    exit 1
}

try {
    $manifest = ($manifestRun.Output -join "`n") | ConvertFrom-Json
}
catch {
    Write-Host "Test-VendoredHelpers: FAILED - 1 reason(s)" -ForegroundColor Red
    Write-Host "  - Sync-VendoredHelpers.ps1 -ListManifest did not return readable JSON: $($_.Exception.Message)"
    exit 1
}

$vendoredRows = @($manifest.vendored)
$excusedRows = @($manifest.notVendored)
$residualRows = @($manifest.residuals)

if ($vendoredRows.Count -eq 0) {
    Add-Failure 'the vendored manifest is empty - a package with no scripts_root has no helper to run'
}

# --- 1. identity: one row per vendored path, one row per name -----------------
$vendoredIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$vendoredNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$vendoredByBasename = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$canonicalIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

foreach ($row in $vendoredRows) {
    if (-not $vendoredIds.Add([string]$row.Vendored)) {
        Add-Failure "vendored manifest lists '$($row.Vendored)' twice"
    }

    # One owner per helper: one canonical file, one vendored copy. A second copy
    # of the same canonical source is two places to drift and only one can be
    # proven, so it fails instead of being counted.
    if ($row.Kind -eq 'copy' -and -not [string]::IsNullOrWhiteSpace([string]$row.Canonical)) {
        if (-not $canonicalIds.Add([string]$row.Canonical)) {
            Add-Failure "the canonical file '$($row.Canonical)' is vendored more than once - pick one location and remove the other copy"
        }
    }

    # The Markdown token check resolves a helper by basename, so two copies of the
    # same canonical file (each placed where a different consumer's relative path
    # points) are legitimate; a duplicate *path* is not.
    #
    # BOTH extensions register here. Registering only .ps1 is what let a cross-repo
    # `.mjs` dependency (the fleet merge queue) sit in the members' prescribed
    # commands while this gate reported every helper resolved.
    if ([System.IO.Path]::GetExtension([string]$row.Vendored) -in @('.ps1', '.mjs')) {
        [void]$vendoredNames.Add([string]$row.Name)
        $vendoredByBasename[[string]$row.Name] = [string]$row.Vendored
    }

    # An archived row is exempt from a canonical comparison, so its provenance is
    # what makes it verifiable at all. A row that says "archived" without naming
    # where the body went and what it hashed to is a waiver wearing a row.
    if ([string]$row.Kind -eq 'archived') {
        foreach ($field in @('ArchivedFrom', 'Archived', 'Sha256', 'ArchivedAt')) {
            $property = $row.PSObject.Properties[$field]
            if (-not $property -or [string]::IsNullOrWhiteSpace([string]$property.Value)) {
                Add-Failure "archived row for '$($row.Vendored)' records no $field - an archived row carries its provenance, it is never waived"
            }
        }
    }

    # A patched row is a deliberate fork, so it is only acceptable while it can
    # say what the patch is and which canonical bytes it was taken from. Both
    # hashes are required: the vendored one proves the shipped file, the canonical
    # one lets -Check report a source change instead of silently accepting it.
    if ([string]$row.Kind -eq 'patched') {
        foreach ($field in @('Canonical', 'Patch', 'Why', 'Sha256', 'CanonicalSha256')) {
            $property = $row.PSObject.Properties[$field]
            if (-not $property -or [string]::IsNullOrWhiteSpace([string]$property.Value)) {
                Add-Failure "patched row for '$($row.Vendored)' records no $field - a patched copy carries its patch and both hashes, it is never an unrecorded fork"
            }
        }
    }
}

# --- 2. excusals are decisions, not silence ----------------------------------
$excusedByName = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($row in $excusedRows) {
    if ([string]::IsNullOrWhiteSpace($row.Reason)) {
        Add-Failure "'$($row.Name)' is listed as deliberately not vendored with no reason - an excusal needs one"
        continue
    }
    if ($excusedByName.ContainsKey($row.Name)) {
        Add-Failure "'$($row.Name)' is listed twice in the not-vendored manifest"
        continue
    }
    $excusedByName[$row.Name] = $row.Reason
}

foreach ($name in $vendoredNames) {
    if ($excusedByName.ContainsKey($name)) {
        Add-Failure "'$name' is both vendored and excused - one of the two rows is wrong"
    }
}

# --- 3. every row exists at its vendored path --------------------------------
$parsedScripts = 0
foreach ($row in $vendoredRows) {
    $path = Join-Path $packageFull ([string]$row.Vendored)
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Add-Failure "vendored file missing: $($row.Vendored) (manifest row $($row.Canonical))"
        continue
    }

    # --- 5. every vendored script parses ------------------------------------
    if ([System.IO.Path]::GetExtension($path) -eq '.ps1') {
        $parseErrors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$parseErrors)
        if ($parseErrors -and $parseErrors.Count -gt 0) {
            Add-Failure "vendored script does not parse: $($row.Vendored) - $($parseErrors[0].Message)"
        }
        else {
            $parsedScripts++
        }
    }
}

# --- 4. no orphan copies ------------------------------------------------------
$orphans = 0
foreach ($relative in $ownedDirectories) {
    foreach ($file in (Get-RelativeFiles -Relative $relative)) {
        if (-not $vendoredIds.Contains($file)) {
            $orphans++
            Add-Failure "orphan copy not in the manifest: $file - every file under vendor/ and references/vendored/ is vendored and must be listed"
        }
    }
}

# --- 6. the drift gate --------------------------------------------------------
Write-Output '--- Sync-VendoredHelpers.ps1 -Check'
$checkRun = Invoke-ChildScript -Path $syncScript -Arguments @('-Check', '-PackageRoot', $packageFull)
foreach ($line in $checkRun.Output) { Write-Output $line }

switch ($checkRun.ExitCode) {
    0 { }
    2 {
        Add-Failure 'drift cannot be evaluated: Sync-VendoredHelpers.ps1 -Check found no readable manifest (a named non-verdict, not a pass)'
    }
    default {
        Add-Failure "Sync-VendoredHelpers.ps1 -Check exited $($checkRun.ExitCode): at least one vendored file is DRIFT, MISSING, ORPHAN or CONFLICT"
    }
}

# --- 7. every helper named in the Markdown resolves ---------------------------
$tokenPattern = [regex]'(?<![A-Za-z0-9_.-])(?<name>[A-Za-z0-9_.-]+\.(?:ps1|mjs))'
$mdFiles = Get-ChildItem -LiteralPath $packageFull -Recurse -File -Filter '*.md' | Where-Object {
    $relative = $_.FullName.Substring($packageFull.Length)
    -not ($relative -split '[\\/]' | Where-Object { $_ -in @('.git', 'node_modules') })
}

$namedFiles = [System.Collections.Generic.SortedDictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($file in $mdFiles) {
    $relative = $file.FullName.Substring($packageFull.Length).TrimStart('\', '/')
    foreach ($line in (Get-Content -LiteralPath $file.FullName -Encoding utf8)) {
        foreach ($match in $tokenPattern.Matches($line)) {
            $name = $match.Groups['name'].Value
            if (-not $namedFiles.ContainsKey($name)) {
                $namedFiles[$name] = $relative
            }
        }
    }
}

$inVendor = 0
$inTools = 0
$excused = 0
$staleReferences = 0

foreach ($pair in $namedFiles.GetEnumerator()) {
    $name = $pair.Key

    if ($vendoredNames.Contains($name)) {
        $inVendor++
        continue
    }

    if (Test-Path -LiteralPath (Join-Path $toolsDir $name) -PathType Leaf) {
        $inTools++
        continue
    }

    if ($excusedByName.ContainsKey($name)) {
        $excused++
        if ($excusedByName[$name].StartsWith('STALE REFERENCE', [System.StringComparison]::OrdinalIgnoreCase)) {
            $staleReferences++
        }
        continue
    }

    Add-Failure "$($pair.Value) names $name, but the package neither ships it nor lists it in the not-vendored manifest - either vendor it or excuse it with a reason"
}

# --- 8. declared residuals: no silent fleet path, no stale excuse ------------
$declaredResiduals = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($row in $residualRows) {
    if ([string]::IsNullOrWhiteSpace($row.Reason)) {
        Add-Failure "residual '$($row.Path)' is declared without a reason - a residual is an admission, not a waiver"
        continue
    }
    $declaredResiduals[[string]$row.Path] = [string]$row.Reason
}

$matchedResiduals = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$textExtensions = @('.ps1', '.mjs', '.md', '.json')
foreach ($relative in $vendoredIds) {
    if ($textExtensions -notcontains [System.IO.Path]::GetExtension($relative)) { continue }

    $path = Join-Path $packageFull $relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }

    $hit = $null
    foreach ($line in (Get-Content -LiteralPath $path -Encoding utf8)) {
        if ($line.Contains('CL_REPOS_ROOT')) { $hit = $line.Trim(); break }
    }

    if (-not $hit) { continue }

    if (-not $declaredResiduals.ContainsKey($relative)) {
        Add-Failure "vendored file names a fleet CL_REPOS_ROOT and no residual row declares it: $relative - declare it with a reason, or make it resolve in-package"
        continue
    }

    [void]$matchedResiduals.Add($relative)
    Write-Output ('RESIDUAL {0}  {1}  declared: {2}' -f $relative, ($declaredResiduals[$relative].Substring(0, [Math]::Min(96, $declaredResiduals[$relative].Length))), 'CL_REPOS_ROOT')
}

foreach ($path in $declaredResiduals.Keys) {
    if (-not $matchedResiduals.Contains($path)) {
        Add-Failure "residual '$path' is declared but the file no longer names CL_REPOS_ROOT - remove the stale excuse"
    }
}

# --- verdict ------------------------------------------------------------------
if ($failures.Count -gt 0) {
    Write-Host "Test-VendoredHelpers: FAILED - $($failures.Count) reason(s)" -ForegroundColor Red
    foreach ($reason in $failures) { Write-Host "  - $reason" }
    exit 1
}

$copyRows = @($vendoredRows | Where-Object { $_.Kind -eq 'copy' }).Count
$patchedRows = @($vendoredRows | Where-Object { $_.Kind -eq 'patched' }).Count
$snapshotRows = @($vendoredRows | Where-Object { $_.Kind -eq 'snapshot' }).Count
$archivedRows = @($vendoredRows | Where-Object { $_.Kind -eq 'archived' }).Count
$treeRows = @($manifest.trees).Count

$summary = 'Test-VendoredHelpers: OK - {0} vendored file(s) present, covered and byte-identical ' +
    '({1} copy row(s) across {2} tree(s) + single files, {3} patched row(s) with both hashes recorded, {4} snapshot row(s), {5} archived row(s)); {6} script(s) parsed; ' +
    '{7} orphan(s); {8} declared residual(s) still matching; {9} helper name(s) in {10} markdown file(s) ' +
    'resolved ({11} in vendor/, {12} in tools/, {13} deliberately not vendored, {14} of those a stale reference)'
$summary = $summary -f $vendoredRows.Count, $copyRows, $treeRows, $patchedRows, $snapshotRows, $archivedRows, $parsedScripts,
    $orphans, $matchedResiduals.Count, $namedFiles.Count, $mdFiles.Count, $inVendor, $inTools, $excused, $staleReferences

Write-Host $summary -ForegroundColor Green
exit 0
