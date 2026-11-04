#Requires -Version 7
<#
.SYNOPSIS
    Merge-acceptance gate: a branch that changes a canonical Skills file with a
    vendored manifest row must also carry the matching vendored copy and manifest
    hash, or it does not land.

.DESCRIPTION
    The package under `interactive-qa/` vendors byte-identical copies of
    canonical `Skills/**` helpers. Those copies are a build artefact of the canon,
    but nothing in git couples the two, so a canonical edit used to land alone and
    the package gate went red on the trunk hours later (bead `cl-common-e93`,
    measured 7 of 76 rows DRIFT on dev 8fea2c68).

    This gate closes that seam at merge time. It is deliberately scoped to the
    branch's own diff:

      1. resolve the changed paths of each branch against the merge base with the
         trunk (`git merge-base` + `git diff --name-only`), or take an explicit
         `-Paths` list;
      2. read the manifest at the branch tip - but distinguish the two nulls. A
         manifest ABSENT on the branch (`git cat-file -e` fails) means the branch
         was cut before the mapping existed, which is true of every branch older
         than bead `cl-common-e93`; the BASE/trunk manifest still declares which
         canonicals are vendored, so its rows judge the branch's changed paths.
         A manifest PRESENT but unreadable is a defect on that branch, not a
         predate, and stays CANNOT-EVALUATE (exit 2);
      3. intersect the changed paths with those rows;
      4. when the intersection is empty, pass without opening anything (a branch
         that touches no governed canonical cannot introduce vendored drift);
      5. when it is not empty, check out the branch tip into a throwaway detached
         worktree and run the one owner of the mapping,
         `interactive-qa/tools/Sync-VendoredHelpers.ps1 -Check`, against it.
         A pre-manifest branch that ships no package fails without a check: it
         cannot carry a vendored copy or a recorded hash for anything, so the row
         it changes is MISSING by construction;
      6. fail with the offending ROW and its CANONICAL file named when any row is
         not MATCH. The check is the same one the package gate runs, so this
         cannot disagree with `Test-VendoredHelpers.ps1`.

    A branch that changes a governed canonical AND re-vendors it passes. A branch
    that changes a non-governed canonical (or any other file) passes - including a
    pre-manifest branch, whose changed paths are judged against the trunk rows. A
    repository with no vendored-helper manifest is not governed by this gate and
    says so.

    WHERE THE MANIFEST IS LOOKED FOR
    The package is a repository of its own, so in the owner checkout its `tools/`
    sits at the repo root; it is also vendored into host repositories under
    `vendor/<pkg>/`, which is where `cl-common` carries it. Both layouts are
    probed, package-root first, for both package names:

      interactive-qa/tools/vendored-helpers.manifest.json
      interactive-qa-agent/tools/vendored-helpers.manifest.json
      vendor/interactive-qa/tools/vendored-helpers.manifest.json
      vendor/interactive-qa-agent/tools/vendored-helpers.manifest.json

    A layout that was not probed is not "not governed": it is a false green, so
    the skip message names every layout that was tried. `-ManifestPath` overrides
    the probe entirely and accepts a repo-relative or an absolute value; its
    `tools/` parent becomes the package folder, so the manifest and the vendored
    copies it names are always read from the same place.

    Exit codes
      0  the branch touches no governed canonical, or every vendored row is in
         sync (MATCH)
      1  at least one vendored row is not in sync, with the row and canonical file
         named
      2  CANNOT-EVALUATE - not a git work tree, an unreadable manifest, or a
         checkout/check that could not run. An unevaluable gate is never a pass.

.PARAMETER RepoPath
    Repository checkout to measure. Defaults to the git toplevel of the current
    directory.

.PARAMETER Trunk
    Integration trunk used to find the merge base. Defaults to `dev`.

.PARAMETER Base
    Explicit base ref, overriding the `origin/<Trunk>` -> `<Trunk>` fallback.

.PARAMETER Branch
    Branch names to measure. Defaults to the checked-out branch. Accepts several
    names; every branch is measured against the same base.

.PARAMETER Paths
    Explicit repo-relative changed paths, instead of `git diff`. Use when the
    caller already knows the change set (a brief, a merge-queue row, a patch).

.PARAMETER ManifestPath
    Manifest to read, instead of probing the layouts. Accepts a repo-relative or
    an absolute path; a relative one is resolved against `-RepoPath`. The folder
    above its `tools/` becomes the package folder, so the vendored copies and the
    sync owner are read from the same package the manifest belongs to. Defaults to
    the first matching package-root (`interactive-qa/`, `interactive-qa-agent/`)
    or vendored (`vendor/interactive-qa/`, `vendor/interactive-qa-agent/`)
    manifest under `-RepoPath`.

.PARAMETER SyncScript
    The single owner of the mapping. Defaults to
    `<package>/tools/Sync-VendoredHelpers.ps1` in the package folder resolved
    above.

.PARAMETER Json
    Emit one JSON object instead of the human report.

.EXAMPLE
    pwsh -NoProfile -File tools/Test-VendoredSync.ps1 -RepoPath . -Branch fix/e93-vendor-sync-gate

.EXAMPLE
    pwsh -NoProfile -File tools/Test-VendoredSync.ps1 -Paths Skills/credential-rescue/scripts/Invoke-KeyCheck.ps1

.EXAMPLE
    # A host repository that vendors the package under vendor/<pkg>/ (cl-common).
    pwsh -NoProfile -File tools/Test-VendoredSync.ps1 -RepoPath E:\repos\cl-common -Trunk dev -Branch fix/vendored-sync-ttr

.EXAMPLE
    # Name the manifest explicitly - relative to -RepoPath, or absolute.
    pwsh -NoProfile -File tools/Test-VendoredSync.ps1 -RepoPath . -ManifestPath vendor/interactive-qa/tools/vendored-helpers.manifest.json
#>
[CmdletBinding()]
param(
    [string] $RepoPath = '',
    [string] $Trunk = 'dev',
    [string] $Base = '',
    [string[]] $Branch = @(),
    [string[]] $Paths = @(),
    [string] $ManifestPath = '',
    [string] $SyncScript = '',
    [switch] $Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Where the package folder sits is part of the mapping this gate measures, not a
# constant, for TWO reasons:
#
#   name    it was renamed `interactive-qa-agent` -> `interactive-qa` on
#           2026-11-03, and a hardcoded old name made this gate print SKIP (a
#           false green) on every repository that had already taken the rename.
#   layout  the package is a repository of its own (its `tools/` sits at the repo
#           root) AND it is vendored into host repositories under `vendor/<pkg>/`,
#           which is where `cl-common` carries it. A resolver that only knew the
#           package-root layout printed SKIP on `cl-common` while the manifest sat
#           at `vendor/interactive-qa/tools/vendored-helpers.manifest.json`
#           (bead cl-common-ttr) - a false green, and the exact defect this probe
#           exists to prevent.
#
# Probe name x layout, package-root first so the owner repository keeps winning,
# at whichever root or ref is being measured.
$script:ManifestTail = 'tools/vendored-helpers.manifest.json'
$script:PackageNames = @('interactive-qa', 'interactive-qa-agent')
$script:PackageLayoutPrefixes = @('', 'vendor/')
$script:PackageFolderCandidates = @(
    foreach ($prefix in $script:PackageLayoutPrefixes) {
        foreach ($name in $script:PackageNames) { "$prefix$name" }
    }
)
$script:PackageRelativePath = $script:PackageFolderCandidates[0]
$script:ManifestRelativePath = "$($script:PackageRelativePath)/$($script:ManifestTail)"
$script:SyncRelativePath = "$($script:PackageRelativePath)/tools/Sync-VendoredHelpers.ps1"
# Set only when -ManifestPath names a manifest inside the measured repository.
$script:ExplicitPackageRelativePath = ''

function Get-ProbeFolders {
    # An explicit -ManifestPath names its own package folder, so that folder is
    # probed FIRST - the caller already said which file is being measured.
    if ($script:ExplicitPackageRelativePath) {
        return @($script:ExplicitPackageRelativePath) +
            @($script:PackageFolderCandidates | Where-Object { $_ -ne $script:ExplicitPackageRelativePath })
    }
    return @($script:PackageFolderCandidates)
}

function Resolve-PackageFolder {
    param([Parameter(Mandatory)][string] $Root)

    foreach ($candidate in (Get-ProbeFolders)) {
        $manifest = Join-Path (Join-Path $Root $candidate) $script:ManifestTail
        if (Test-Path -LiteralPath $manifest -PathType Leaf) { return $candidate }
    }
    return $null
}

function Resolve-PackageFolderAtRef {
    param([Parameter(Mandatory)][string] $Ref)

    foreach ($candidate in (Get-ProbeFolders)) {
        $null = & git -C $RepoPath cat-file -e "${Ref}:$candidate/$($script:ManifestTail)" 2>&1
        if ($LASTEXITCODE -eq 0) { return $candidate }
    }
    return $null
}
$script:KnownStatuses = @('MATCH', 'DRIFT', 'MISSING', 'ORPHAN', 'CONFLICT')

function Write-Verdict {
    param([Parameter(Mandatory)][string] $Line, [switch] $AsError)

    Write-Output $Line
    foreach ($extra in $script:ExtraLines) { Write-Output $extra }
    $script:ExtraLines.Clear()
    if ($AsError) { exit 1 }
    exit 0
}

function Stop-CannotEvaluate {
    param([Parameter(Mandatory)][string] $Reason)

    Write-Output "Test-VendoredSync: CANNOT-EVALUATE - $Reason"
    foreach ($extra in $script:ExtraLines) { Write-Output $extra }
    $script:ExtraLines.Clear()
    exit 2
}

$script:ExtraLines = [System.Collections.Generic.List[string]]::new()

function Add-VerdictLine {
    param([Parameter(Mandatory)][string] $Line)
    $script:ExtraLines.Add($Line)
}

function Invoke-Git {
    param([Parameter(ValueFromRemainingArguments)][string[]] $Arguments)

    $output = & git -C $RepoPath @Arguments 2>&1
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output   = @($output | ForEach-Object { "$_" })
    }
}

function Get-RefSha {
    param([Parameter(Mandatory)][string] $Ref)

    $result = Invoke-Git rev-parse --verify --quiet "$Ref^{commit}"
    if ($result.ExitCode -ne 0 -or $result.Output.Count -eq 0) { return $null }
    return $result.Output[0].Trim()
}

function Resolve-BaseRef {
    if ($Base) { return $Base }
    $remote = "origin/$Trunk"
    if (Get-RefSha -Ref $remote) { return $remote }
    return $Trunk
}

function Get-ChangedPaths {
    param([Parameter(Mandatory)][string] $Ref, [Parameter(Mandatory)][string] $BaseRef)

    $mergeBase = (Invoke-Git merge-base $BaseRef $Ref).Output
    $baseForDiff = if ($mergeBase.Count -gt 0 -and $mergeBase[0].Trim()) { $mergeBase[0].Trim() } else { $BaseRef }

    $diff = Invoke-Git diff --name-only --no-renames "$baseForDiff..$Ref"
    if ($diff.ExitCode -ne 0) { return $null }

    return [pscustomobject]@{
        MergeBase = $baseForDiff
        Paths     = @($diff.Output | Where-Object { $_ })
    }
}

function Read-ManifestForRef {
    param([Parameter(Mandatory)][string] $Ref)

    $folder = Resolve-PackageFolderAtRef -Ref $Ref
    if (-not $folder) { return $null }

    $json = (Invoke-Git show "${Ref}:$folder/tools/vendored-helpers.manifest.json").Output
    if ($json.Count -eq 0) { return $null }

    try {
        return (($json -join "`n") | ConvertFrom-Json)
    }
    catch {
        return $null
    }
}

function Test-ManifestPresentForRef {
    param([Parameter(Mandatory)][string] $Ref)

    # `git cat-file -e <ref>:<path>` is the only honest absent/present test: an
    # unparseable manifest still EXISTS in the tree and must not be confused with
    # a branch that predates the mapping (bead cl-common-7cu). Called directly
    # because a single-dash `-e` binds as a parameter name on a splatting wrapper.
    $folder = Resolve-PackageFolderAtRef -Ref $Ref
    return [bool]$folder
}

function Get-RowIndex {
    param([Parameter(Mandatory)][object] $Manifest)

    $byCanonical = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $byVendored = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($row in @($Manifest.vendored)) {
        $canonical = [string]$row.Canonical
        $vendored = [string]$row.Vendored
        if ([string]::IsNullOrWhiteSpace($vendored)) { continue }

        if ($row.Kind -in @('copy', 'patched') -and -not [string]::IsNullOrWhiteSpace($canonical)) {
            $byCanonical[$canonical] = $row
        }
        $byVendored[$vendored] = $row
    }

    [pscustomobject]@{ ByCanonical = $byCanonical; ByVendored = $byVendored }
}

function ConvertTo-CanonicalRelative {
    param([Parameter(Mandatory)][string] $Path)

    $normalized = ($Path.Trim() -replace '\\', '/') -replace '^\./', ''
    if (-not $normalized.StartsWith('Skills/', [System.StringComparison]::OrdinalIgnoreCase)) { return $null }
    return $normalized.Substring('Skills/'.Length)
}

function Read-CheckRows {
    param([Parameter(Mandatory)][string[]] $Output)

    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($line in $Output) {
        $match = [regex]::Match($line, '^(?<status>[A-Z-]+)\s{2,}(?<vendored>\S+)\s*(?<detail>.*)$')
        if (-not $match.Success) { continue }
        $status = $match.Groups['status'].Value
        if ($script:KnownStatuses -notcontains $status) { continue }
        $rows.Add([pscustomobject]@{
                Status   = $status
                Vendored = $match.Groups['vendored'].Value
                Detail   = $match.Groups['detail'].Value.Trim()
            })
    }
    return $rows
}

# --- 1. the checkout ---------------------------------------------------------
if (-not $RepoPath) {
    $RepoPath = (& git rev-parse --show-toplevel 2>$null)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($RepoPath)) {
        Stop-CannotEvaluate 'not inside a git repository; pass -RepoPath'
    }
}

if (-not (Test-Path -LiteralPath $RepoPath -PathType Container)) {
    Stop-CannotEvaluate "repository path not found: $RepoPath"
}
$RepoPath = (Resolve-Path -LiteralPath $RepoPath).Path

$insideWorkTree = Invoke-Git rev-parse --is-inside-work-tree
if ($insideWorkTree.ExitCode -ne 0 -or $insideWorkTree.Output[0].Trim() -ne 'true') {
    Stop-CannotEvaluate "not a git work tree: $RepoPath (a bare repository cannot carry a working manifest)"
}

# --- 2. applicability -------------------------------------------------------
# An explicit -ManifestPath is honoured as given: an absolute value is used as it
# is, a relative one is resolved against -RepoPath (never the caller's cwd, so the
# same value names the same file from any directory). Whichever layout it names
# becomes the package folder for every later path, so an explicit manifest and a
# probed one cannot disagree about where the vendored copies live.
$manifestIsExplicit = [bool]$ManifestPath
if ($manifestIsExplicit) {
    if (-not [System.IO.Path]::IsPathRooted($ManifestPath)) {
        $ManifestPath = Join-Path $RepoPath $ManifestPath
    }
    $ManifestPath = [System.IO.Path]::GetFullPath($ManifestPath)

    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
        Stop-CannotEvaluate "the manifest passed with -ManifestPath does not exist: $ManifestPath"
    }

    $explicitRelative = [System.IO.Path]::GetRelativePath($RepoPath, $ManifestPath) -replace '\\', '/'
    if ($explicitRelative.StartsWith('..')) {
        Stop-CannotEvaluate "the manifest passed with -ManifestPath is outside the measured repository: $ManifestPath (relative '$explicitRelative'), so its vendored paths and branch refs cannot be resolved against $RepoPath"
    }
    if ($explicitRelative -notmatch "^(?<folder>.+)/$([regex]::Escape($script:ManifestTail))$") {
        Stop-CannotEvaluate "the manifest passed with -ManifestPath is not a $($script:ManifestTail) inside $RepoPath (got '$explicitRelative'), so the package folder it belongs to cannot be derived"
    }
    $script:ExplicitPackageRelativePath = $Matches['folder']
}

# Bind the package folder to the repository being measured; every later path is
# derived from it, so a repository on the other side of the rename - or one that
# vendors the package under vendor/<pkg>/ - still measures.
$resolvedFolder = Resolve-PackageFolder -Root $RepoPath
if ($resolvedFolder) {
    $script:PackageRelativePath = $resolvedFolder
    $script:ManifestRelativePath = "$resolvedFolder/$($script:ManifestTail)"
    $script:SyncRelativePath = "$resolvedFolder/tools/Sync-VendoredHelpers.ps1"
}
elseif (-not $manifestIsExplicit) {
    Write-Verdict "Test-VendoredSync: SKIP - no vendored-helper manifest at any probed layout ($((Get-ProbeFolders) -join ', ')), each at $($script:ManifestTail); this repository does not vendor canonical Skills helpers"
}

if (-not $ManifestPath) { $ManifestPath = Join-Path $RepoPath $script:ManifestRelativePath }

if (-not $SyncScript) { $SyncScript = Join-Path $RepoPath $script:SyncRelativePath }

# The sync script is measured as the BRANCH ships it: the branch may be the one
# changing the mapping, and a worktree run must not borrow the caller's copy.
$syncRelative = $script:SyncRelativePath
if (Test-Path -LiteralPath $SyncScript -PathType Leaf) {
    $syncFull = (Resolve-Path -LiteralPath $SyncScript).Path
    if ($syncFull.StartsWith($RepoPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        $syncRelative = [System.IO.Path]::GetRelativePath($RepoPath, $syncFull) -replace '\\', '/'
    }
}

# --- 3. targets and their changed paths -------------------------------------
$baseRef = Resolve-BaseRef
$currentBranch = (Invoke-Git rev-parse --abbrev-ref HEAD).Output
$branchNames = if ($Branch.Count -gt 0) { @($Branch) } else { @($currentBranch[0].Trim()) }

if ($Paths.Count -gt 0) {
    $targets = @([pscustomobject]@{
            Branch       = if ($Branch.Count -gt 0) { $Branch[0] } else { $currentBranch[0].Trim() }
            MergeBase    = $baseRef
            Paths        = @($Paths)
            ManifestRef  = ''
            ManifestFrom = ''
            Manifest     = $null
            WatchedRows  = 0
        })
}
else {
    $targets = @()
    foreach ($name in $branchNames) {
        if (-not (Get-RefSha -Ref $name)) {
            Stop-CannotEvaluate "branch '$name' does not resolve in $RepoPath"
        }
        $change = Get-ChangedPaths -Ref $name -BaseRef $baseRef
        if ($null -eq $change) {
            Stop-CannotEvaluate "git diff failed for '$name' against '$baseRef'"
        }
        $targets += [pscustomobject]@{
            Branch       = $name
            MergeBase    = $change.MergeBase
            Paths        = $change.Paths
            ManifestRef  = ''
            ManifestFrom = ''
            Manifest     = $null
            WatchedRows  = 0
        }
    }
}

# --- 4. intersect the diff with the manifest rows ---------------------------
# Two different nulls, deliberately kept apart (bead cl-common-7cu):
#   ABSENT on the ref   -> the branch predates the mapping; the BASE/trunk
#                          manifest still declares the rows, so use it;
#   PRESENT unreadable  -> a defect on that branch, a named non-verdict (exit 2).
$totalChanged = 0
$touched = [System.Collections.Generic.List[object]]::new()
$sawManifest = $false

foreach ($target in $targets) {
    $manifestRef = if ($Paths.Count -gt 0 -and $Branch.Count -eq 0) { 'HEAD' } else { $target.Branch }

    if (Test-ManifestPresentForRef -Ref $manifestRef) {
        $manifest = Read-ManifestForRef -Ref $manifestRef
        if ($null -eq $manifest) {
            Stop-CannotEvaluate "the vendored-helper manifest is present but unreadable on '$($target.Branch)' ($script:ManifestRelativePath) - a malformed manifest is a defect on that branch, not a pre-manifest predate, so the gate cannot evaluate"
        }
        $target.ManifestRef = $manifestRef
        $target.ManifestFrom = 'branch'
    }
    else {
        # Absent on the branch tip. Before calling that a predate, prove the branch
        # did not DELETE a mapping its own merge base already had - that is a
        # defect on the branch, not an older branch, and must stay unevaluable.
        if ($target.MergeBase -and (Test-ManifestPresentForRef -Ref $target.MergeBase)) {
            Stop-CannotEvaluate "the vendored-helper manifest exists at the merge base '$($target.MergeBase)' but is absent on '$($target.Branch)' ($script:ManifestRelativePath) - the branch deletes the mapping, which is a defect on that branch, not a pre-manifest predate"
        }

        # Genuine predate: the merge base can be older than the manifest too (the
        # Phase 3 gate evidence branch), so the fallback is the TRUNK ref the
        # caller resolved, which is where the mapping actually lives.
        $fallbackRef = $baseRef
        $manifest = $null
        if (Test-ManifestPresentForRef -Ref $fallbackRef) {
            $manifest = Read-ManifestForRef -Ref $fallbackRef
            if ($null -eq $manifest) {
                Stop-CannotEvaluate "the vendored-helper manifest is absent on '$($target.Branch)' but present and unreadable on the trunk '$fallbackRef' ($script:ManifestRelativePath) - the gate cannot evaluate"
            }
        }
        if ($null -eq $manifest) {
            Stop-CannotEvaluate "the vendored-helper manifest is absent on '$($target.Branch)' and absent on the trunk '$fallbackRef' ($script:ManifestRelativePath) - nothing declares which canonicals are vendored, so the gate cannot evaluate"
        }
        $target.ManifestRef = $fallbackRef
        $target.ManifestFrom = 'base'
    }

    $target.Manifest = $manifest
    $target.WatchedRows = @($manifest.vendored).Count
    $sawManifest = $true
    $index = Get-RowIndex -Manifest $manifest

    $target.Paths = @($target.Paths)
    $totalChanged += $target.Paths.Count

    foreach ($path in $target.Paths) {
        $canonical = ConvertTo-CanonicalRelative -Path $path
        if ([string]::IsNullOrWhiteSpace($canonical)) { continue }
        if (-not $index.ByCanonical.ContainsKey($canonical)) { continue }

        $touched.Add([pscustomobject]@{
                Branch    = $target.Branch
                Canonical = $canonical
                Row       = $index.ByCanonical[$canonical]
                MergeBase = $target.MergeBase
            })
    }
}

if (-not $sawManifest) {
    Stop-CannotEvaluate 'no target branch could be read'
}

$rowCount = if ($targets.Count -gt 0) { $targets[0].WatchedRows } else { 0 }
$preManifestBranches = @($targets | Where-Object { $_.ManifestFrom -eq 'base' } | ForEach-Object { $_.Branch })
$preManifestNote = if ($preManifestBranches.Count -gt 0) {
    "; manifest absent on $(($preManifestBranches) -join ', '), so rows were read from the base/trunk (the branch predates the mapping)"
} else { '' }

if ($touched.Count -eq 0) {
    $summary = "Test-VendoredSync: OK - $totalChanged changed path(s) across $(@($targets | ForEach-Object { $_.Branch }) -join ', '); none is a canonical file with a vendored manifest row ($rowCount row(s) watched)$preManifestNote"
    if ($Json) {
        [pscustomobject]@{
            verdict       = 'ok'
            reason        = 'no governed canonical changed'
            repo          = $RepoPath
            base          = $baseRef
            branches      = @($targets | ForEach-Object { $_.Branch })
            changedPaths  = $totalChanged
            watchedRows   = $rowCount
            offendingRows = @()
        } | ConvertTo-Json -Depth 4
        exit 0
    }
    Write-Verdict $summary
}

# --- 5. run the single owner against the branch tip -------------------------
$offending = [System.Collections.Generic.List[object]]::new()
$checkedRows = 0
$checkedBranches = [System.Collections.Generic.List[string]]::new()

foreach ($name in @($touched | ForEach-Object { $_.Branch } | Select-Object -Unique)) {
    $sha = Get-RefSha -Ref $name
    if (-not $sha) { Stop-CannotEvaluate "branch '$name' does not resolve to a commit" }

    $targetForBranch = @($targets | Where-Object { $_.Branch -eq $name }) | Select-Object -First 1
    $touchedForBranch = @($touched | Where-Object { $_.Branch -eq $name })
    $usingBaseManifest = [bool]($targetForBranch -and $targetForBranch.ManifestFrom -eq 'base')

    $worktree = Join-Path ([System.IO.Path]::GetTempPath()) ("vendored-sync-{0}" -f ([guid]::NewGuid().ToString('N').Substring(0, 12)))
    $added = $false
    try {
        $add = Invoke-Git worktree add --detach --quiet $worktree $sha
        if ($add.ExitCode -ne 0) {
            Stop-CannotEvaluate "could not check out '$name' ($sha) into a throwaway worktree: $(($add.Output -join ' ') -replace '\s+', ' ')"
        }
        $added = $true

        $branchSync = Join-Path $worktree $syncRelative
        $branchFolder = Resolve-PackageFolder -Root $worktree
        if (-not $branchFolder) { $branchFolder = $script:PackageRelativePath }
        $branchSyncRelative = "$branchFolder/tools/Sync-VendoredHelpers.ps1"
        $branchSync = Join-Path $worktree $branchSyncRelative
        $packageRoot = Join-Path $worktree $branchFolder
        $shipsMapping = (Test-Path -LiteralPath $branchSync -PathType Leaf) -and
            (Test-Path -LiteralPath $packageRoot -PathType Container)

        if (-not $shipsMapping) {
            if (-not $usingBaseManifest) {
                Stop-CannotEvaluate "the branch '$name' does not ship the mapping owner at $branchSyncRelative"
            }

            # A branch older than the mapping cannot carry a vendored copy or a
            # recorded hash, so every governed canonical it changes is unsynced by
            # construction. Name the row (and the canonical) rather than pretend
            # to measure a package the branch does not ship.
            foreach ($entry in $touchedForBranch) {
                $offending.Add([pscustomobject]@{
                        Branch    = $name
                        Row       = [string]$entry.Row.Canonical
                        Canonical = [string]$entry.Row.Canonical
                        Vendored  = [string]$entry.Row.Vendored
                        Status    = 'MISSING'
                        Detail    = "the branch predates the vendored-helper mapping (rows read from base $($targetForBranch.ManifestRef)) and ships no vendored copy, so this canonical would land unsynced"
                        Touched   = $true
                    })
            }
            $checkedRows += $touchedForBranch.Count
            $checkedBranches.Add($name)
            continue
        }

        if ($usingBaseManifest) {
            # The base/trunk manifest declares the rows; hand the branch's own
            # package a copy of it inside the THROWAWAY worktree so -Check can
            # still prove every copy the branch does ship. Nothing in the branch
            # is modified.
            $branchManifestRelative = 'tools/vendored-helpers.manifest.json'
            $branchManifestPath = Join-Path $packageRoot $branchManifestRelative
            $baseFolder = Resolve-PackageFolderAtRef -Ref $targetForBranch.ManifestRef
            if (-not $baseFolder) { $baseFolder = $script:PackageRelativePath }
            $baseManifestJson = (Invoke-Git show "$($targetForBranch.ManifestRef):$baseFolder/tools/vendored-helpers.manifest.json").Output
            $branchManifestDir = Split-Path -Parent $branchManifestPath
            if (-not (Test-Path -LiteralPath $branchManifestDir -PathType Container)) {
                New-Item -ItemType Directory -Path $branchManifestDir -Force | Out-Null
            }
            Set-Content -LiteralPath $branchManifestPath -Value ($baseManifestJson -join "`n") -Encoding utf8
        }

        $pwsh = (Get-Command pwsh -ErrorAction Stop).Source
        $checkOutput = & $pwsh -NoProfile -NonInteractive -File $branchSync -Check -PackageRoot $packageRoot 2>&1
        $checkExit = $LASTEXITCODE
        $checkLines = @($checkOutput | ForEach-Object { "$_" })

        if ($checkExit -eq 2) {
            Stop-CannotEvaluate "Sync-VendoredHelpers -Check on '$name' could not evaluate: $(($checkLines | Select-Object -Last 2) -join ' ')"
        }

        $rows = Read-CheckRows -Output $checkLines
        $checkedRows += $rows.Count
        $checkedBranches.Add($name)

        $index = Get-RowIndex -Manifest $targetForBranch.Manifest
        $touchedCanonicals = @($touchedForBranch | ForEach-Object { $_.Canonical })

        foreach ($row in $rows) {
            if ($row.Status -eq 'MATCH') { continue }
            $manifestRow = $null
            if ($index.ByVendored.ContainsKey($row.Vendored)) { $manifestRow = $index.ByVendored[$row.Vendored] }

            $canonical = if ($manifestRow) { [string]$manifestRow.Canonical } else { '' }
            $offending.Add([pscustomobject]@{
                    Branch    = $name
                    Row       = if ($canonical) { $canonical } else { $row.Vendored }
                    Canonical = $canonical
                    Vendored  = $row.Vendored
                    Status    = $row.Status
                    Detail    = $row.Detail
                    Touched   = ($canonical -and ($touchedCanonicals -contains $canonical))
                })
        }
    }
    finally {
        if ($added) {
            $null = & git -C $RepoPath worktree remove --force $worktree 2>&1
            if ($LASTEXITCODE -ne 0) { $null = & git -C $RepoPath worktree prune 2>&1 }
        }
    }
}

$branchesMeasured = @($checkedBranches) -join ', '

if ($offending.Count -eq 0) {
    $summary = "Test-VendoredSync: OK - $checkedRows vendored row(s) in sync on $branchesMeasured; $(@($touched | ForEach-Object { $_.Canonical } | Select-Object -Unique).Count) canonical file(s) changed by these branches each carries its vendored copy and manifest hash in step"
    if ($Json) {
        [pscustomobject]@{
            verdict       = 'ok'
            reason        = 'vendored copies are in sync'
            repo          = $RepoPath
            base          = $baseRef
            branches      = @($checkedBranches)
            changedPaths  = $totalChanged
            watchedRows   = $checkedRows
            offendingRows = @()
        } | ConvertTo-Json -Depth 4
        exit 0
    }
    Write-Verdict $summary
}

$failHead = "Test-VendoredSync: FAIL - $($offending.Count) of $checkedRows vendored row(s) are not in sync; $(@($offending | Where-Object { $_.Touched }).Count) belong to canonical file(s) these branches change ($branchesMeasured vs $baseRef)"
$failLines = @()
foreach ($row in $offending) {
    $failLines += "  ROW       $($row.Row)"
    if ($row.Canonical) { $failLines += "  CANONICAL Skills/$($row.Canonical)" } else { $failLines += '  CANONICAL (no manifest row - orphan copy)' }
    $failLines += "  VENDORED  $($row.Vendored)"
    $failLines += "  STATUS    $($row.Status)  $($row.Detail)"
    $failLines += "  TOUCHED   $(if ($row.Touched) { "yes - changed on $($row.Branch)" } else { 'no - not this branch''s change (trunk debt; still a hard failure)' })"
}
$failLines += "  FIX       pwsh -NoProfile -File $script:SyncRelativePath   # then git add the vendored copies and the manifest, and commit both sides"

if ($Json) {
    [pscustomobject]@{
        verdict       = 'fail'
        reason        = 'vendored copies are not in sync'
        repo          = $RepoPath
        base          = $baseRef
        branches      = @($checkedBranches)
        changedPaths  = $totalChanged
        watchedRows   = $checkedRows
        message       = $failHead
        offendingRows = @($offending)
    } | ConvertTo-Json -Depth 6
    exit 1
}

Write-Output $failHead
$failLines | ForEach-Object { Write-Output $_ }
exit 1
