#Requires -Version 7
<#
.SYNOPSIS
    Hub Probe - one fast, read-only pass that says which grooming parts are
    needed right now, and the standalone command that fixes each one.

.DESCRIPTION
    IQA-Merge used to start every session with the full Repo Clean groom: the
    right tool when something needs grooming, pure overhead when nothing does.
    This probe is the cheap gate in front of it - git plumbing plus one queue
    file read, no node, no helper scripts, no writes.

    Each part reports NEEDED / SKIP / INFO / BLOCKED with the reason and, when
    it is NEEDED, the exact existing command to run. The probe orchestrates
    nothing and duplicates nothing: it points at the canonical helper per part.

    The repository identity (and therefore the queue slug) is resolved from the
    repository, NEVER from the checkout directory name alone: the remote origin
    first (it is the only source that describes the repository rather than this
    copy of it), then the git common dir (which is the MAIN checkout even when
    the probe runs inside a linked worktree), and only then the directory name,
    with a warning. A remote that disagrees with the common dir is reported as a
    finding rather than resolved silently - the probe does not know which one
    the operator meant.

      commit      tracked dirt -> Invoke-SafeCommit.ps1
      rungs       more than one ACTIVE MERGE-TICK schedule for this repo ->
                  Test-SingleHubRung.ps1 (keep one active rung, retire the rest)
      sync        trunk behind a remote -> Invoke-GitPullSafe.ps1 (guarded
                  trunk sync; BLOCKED when no guarded copy can be resolved)
      helpers     Skills/ differs from the trunk -> sync the checkout before
                  invoking any skill helper from it: a stale helper serves, and
                  writes, the record shape it knows rather than the current one
      push        trunk ahead of a remote -> git push <remote> <trunk>
      reconcile   queue rows already landed -> merge-queue.mjs prune
      shared-deps dependency manifests in play -> Test-SharedDepAgreement.mjs
      merge       branches carrying work not on the trunk -> Invoke-TrunkPrep.ps1
      hygiene     merged/patch-equivalent branches or extra worktrees ->
                  Invoke-BranchWorktreeHygiene.ps1
      verify      re-run this probe and expect READY

    Fire only the commands the probe flags, in the order printed; when every
    part reads SKIP, advertise the Hub immediately.

.PARAMETER RepoRoot
    Canonical checkout to probe. Defaults to the git toplevel of the current
    directory.

.PARAMETER Slug
    Merge-queue slug, overriding identity resolution. Only needed for a repo
    whose remote and checkout both fail to name it.

.PARAMETER Trunk
    Integration trunk. Defaults to `dev` (the Hub repos' trunk).

.PARAMETER NoFetch
    Use cached remote-tracking refs instead of fetching. Faster offline, but a
    stale `origin/<trunk>` makes `sync` lie - fetching is the default for that
    reason.

.PARAMETER Json
    Emit one JSON object instead of the report table.

.EXAMPLE
    pwsh -NoProfile -File $env:CL_REPOS_ROOT\cl-common\Skills\iqa-merge\Invoke-HubProbe.ps1 -RepoRoot $env:CL_REPOS_ROOT\cl-common

.EXAMPLE
    pwsh -NoProfile -File $env:CL_REPOS_ROOT\cl-common\Skills\iqa-merge\Invoke-HubProbe.ps1 -Json -NoFetch
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = '',
    [string]$Slug = '',
    [string]$Trunk = 'dev',
    [switch]$NoFetch,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'

function Resolve-RepoSlug {
    <#
    .SYNOPSIS
        Map a checkout directory name to its merge-queue slug.
    #>
    param([Parameter(Mandatory)][string]$Name)

    $slugs = @{
        'cl-common'            = 'cl-common'
        'currents-bookkeeping' = 'cbk'
        'upscale-havens'       = 'uh'
    }
    if ($slugs.ContainsKey($Name)) { $slugs[$Name] } else { $Name }
}

function Get-RemoteName {
    <#
    .SYNOPSIS
        Repository name from a remote URL, or $null when it carries none.

    .DESCRIPTION
        Handles every form git stores: git@host:owner/repo.git,
        https://host/owner/repo, ssh://host/owner/repo, and a local path.
        A URL whose last segment is not a plain name is refused rather than
        guessed at - a guess is what put a lane name where a repo name belongs.
    #>
    param([string]$Url)

    if ([string]::IsNullOrWhiteSpace($Url)) { return $null }
    $clean = ($Url.Trim() -replace '\.git$', '') -replace '[\\/]+$', ''
    $segments = @($clean -split '[\\/:]' | Where-Object { $_ })
    if ($segments.Count -eq 0) { return $null }
    $name = $segments[-1]
    if ($name -cmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { return $name }
    return $null
}

function Resolve-RepoIdentity {
    <#
    .SYNOPSIS
        Name the REPOSITORY behind a checkout, and say which source said so.

    .DESCRIPTION
        A directory name describes a checkout, not a repository: inside
        `<repo>/.worktrees/<lane>` the leaf is the lane, and a plain clone may be
        called anything at all (`git clone tmp-xyz`). Reading the leaf as the repo
        name made the probe look for `<lane>.jsonl`, find nothing, and report
        reconcile as SKIP - which reads as "nothing to do here" at the exact
        moment a Hub is doing the work those rows are about.

        Order: explicit -Slug, then the remote origin, then the git common dir
        (the MAIN checkout, even from a linked worktree), then the directory name
        with a warning that it may not be the identity.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [string]$ExplicitSlug = ''
    )

    $findings = [System.Collections.Generic.List[string]]::new()

    if ($ExplicitSlug) {
        return [pscustomobject]@{
            Name     = $ExplicitSlug
            Slug     = $ExplicitSlug
            Source   = 'explicit'
            Findings = @($findings)
        }
    }

    $remoteUrl = (& git -C $RepoRoot config --get remote.origin.url 2>$null)
    $remoteName = if ($LASTEXITCODE -eq 0) { Get-RemoteName -Url "$remoteUrl" } else { $null }

    $commonDir = (& git -C $RepoRoot rev-parse --path-format=absolute --git-common-dir 2>$null)
    $commonName = $null
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($commonDir)) {
        # .NET path calls, not Split-Path: `Split-Path -LiteralPath X -Parent` is an
        # ambiguous parameter set (Split-Path takes -Path for -Parent/-Leaf), and the
        # binder error surfaces as AmbiguousParameterSet on THIS function's call site.
        $commonParent = [System.IO.Path]::GetDirectoryName($commonDir.Trim())
        if ($commonParent) {
            $commonName = [System.IO.Path]::GetFileName($commonParent.TrimEnd('\', '/'))
        }
    }

    if ($remoteName -and $commonName -and $remoteName -cne $commonName) {
        # Two sources, two answers. Report it: a Hub that silently picked one
        # would read the wrong queue and call the result a fact.
        $findings.Add("remote origin says '$remoteName' but this checkout says '$commonName'; using the remote, because it names the repository rather than the copy")
    }

    $name = $remoteName
    $source = 'remote'
    if (-not $name) { $name = $commonName; $source = 'common-dir' }
    if (-not $name) {
        $name = [System.IO.Path]::GetFileName($RepoRoot.TrimEnd('\', '/'))
        $source = 'directory'
        $findings.Add("no remote origin and no git common dir: fell back to the directory name '$name', which describes this checkout and may not be the repository")
    }

    [pscustomobject]@{
        Name     = $name
        Slug     = (Resolve-RepoSlug -Name $name)
        Source   = $source
        Findings = @($findings)
    }
}

function Resolve-QueueFile {
    <#
    .SYNOPSIS
        Locate the merge-queue file for a slug, mirroring merge-queue.mjs.
    #>
    param([Parameter(Mandatory)][string]$Slug)

    $runtimeHome = if ($env:MACHINE_STATE_HOME) { $env:MACHINE_STATE_HOME } else { Join-Path $HOME '.machine' }
    $candidates = @(
        $env:MERGE_QUEUE_DIR
        (Join-Path $runtimeHome 'Tasks\MergeQueue')
        (Join-Path $HOME '.salmon\Tasks\MergeQueue')
    ) | Where-Object { $_ }
    foreach ($dir in $candidates) {
        $file = Join-Path $dir "$Slug.jsonl"
        if (Test-Path -LiteralPath $file) { return $file }
    }
    return $null
}

function Get-QueueRows {
    <#
    .SYNOPSIS
        Last status per branch from the append-only queue file.
    #>
    param([string]$Path)

    if (-not $Path) { return @() }
    $byBranch = [ordered]@{}
    foreach ($line in Get-Content -LiteralPath $Path) {
        if (-not $line.Trim()) { continue }
        try { $row = $line | ConvertFrom-Json } catch { continue }
        if (-not $row.branch) { continue }
        $byBranch[$row.branch] = $row
    }
    @($byBranch.Values)
}

$fleetRoot = if ($env:CL_REPOS_ROOT) { $env:CL_REPOS_ROOT } else { Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent }
if (-not $RepoRoot) {
    $RepoRoot = (& git rev-parse --show-toplevel 2>$null)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($RepoRoot)) {
        throw 'Not inside a git repository; pass -RepoRoot.'
    }
}
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$identity = Resolve-RepoIdentity -RepoRoot $RepoRoot -ExplicitSlug $Slug
$repoName = $identity.Name
$slug = $identity.Slug
$identityNote = if ($identity.Findings.Count -gt 0) { $identity.Findings -join '; ' } else { '' }
$permanent = @($Trunk, 'prod', 'main', 'master') | Select-Object -Unique

# Canonical helper locations - one per part, never reimplemented here.
$safeCommit = Join-Path $fleetRoot 'cl-common\Skills\git-operations\Invoke-SafeCommit.ps1'
$queueHelper = Join-Path $fleetRoot 'currents-bookkeeping\scripts\merge-queue.mjs'
$sharedDeps = Join-Path $fleetRoot 'cl-common\saas-modules\scripts\Test-SharedDepAgreement.mjs'
$trunkPrep = Join-Path $fleetRoot 'Public\salmon-run\skills\operator-git-operations\Invoke-TrunkPrep.ps1'
$hygiene = Join-Path $fleetRoot 'cl-common\Skills\branch-worktree-hygiene\Invoke-BranchWorktreeHygiene.ps1'

# The trunk sync must be the GUARDED helper: it classifies the trunk
# (ahead / behind / diverged), fast-forwards a behind-only trunk, and refuses a
# diverged one with an exact recovery. A copy without the guard marker - the
# retired salmon-run fork, for instance - rebases blind, so it is treated as
# absent and the sync part reports BLOCKED instead of advertising a rebase.
function Resolve-GuardedHelper {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Marker
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    if (-not (Select-String -LiteralPath $Path -Pattern $Marker -Quiet)) { return $null }
    return $Path
}

$pullSafePath = Join-Path $fleetRoot 'cl-common\Skills\git-operations\Invoke-GitPullSafe.ps1'
$pullSafe = Resolve-GuardedHelper -Path $pullSafePath -Marker 'TRUNK-DIVERGENCE-GUARD'

$parts = [System.Collections.Generic.List[object]]::new()
function Add-Part {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Status,
        [Parameter(Mandatory)][string]$Detail,
        [string]$Command = ''
    )
    $parts.Add([pscustomobject]@{ Part = $Name; Status = $Status; Detail = $Detail; Command = $Command })
}

# ---- Precondition --------------------------------------------------------
$branch = (& git -C $RepoRoot rev-parse --abbrev-ref HEAD).Trim()
if ($branch -ne $Trunk) {
    Add-Part -Name 'precondition' -Status 'BLOCKED' `
        -Detail "checkout is on '$branch', expected trunk '$Trunk'" `
        -Command "git -C $RepoRoot switch $Trunk"
}

# ---- Single MERGE-TICK rung ---------------------------------------------
# Two ACTIVE rungs for one repo are two writers on one trunk (2026-11-03,
# cl-common-3tv: one tick landed a branch, advanced the trunk and removed a
# worktree while the other tick's merge worker was still running in it). The
# guard is the one owner of that decision; this probe only routes its exit code.
# No schedule store on this machine is SKIP with the reason, so the probe stays
# satisfiable on a clean checkout; an unreadable store is BLOCKED, never a pass.
$rungGuard = Join-Path $PSScriptRoot 'Test-SingleHubRung.ps1'
$scheduleStore = if ($env:PASEO_SCHEDULES_DIR) { $env:PASEO_SCHEDULES_DIR } else { Join-Path $HOME '.paseo\schedules' }
if (-not (Test-Path -LiteralPath $scheduleStore)) {
    Add-Part -Name 'rungs' -Status 'SKIP' -Detail ("no Paseo schedule store at '{0}' on this machine; rung duplication is not judged here" -f $scheduleStore)
}
elseif (-not (Test-Path -LiteralPath $rungGuard -PathType Leaf)) {
    Add-Part -Name 'rungs' -Status 'BLOCKED' `
        -Detail ("rung guard missing at {0} - exactly one ACTIVE MERGE-TICK rung cannot be proven" -f $rungGuard) `
        -Command ("# restore the canonical guard: {0}" -f $rungGuard)
}
else {
    $rungPwsh = Join-Path $PSHOME 'pwsh.exe'
    $rungOutput = & $rungPwsh -NoProfile -File $rungGuard -Repo $repoName -Json 2>&1 | Out-String
    $rungExit = $LASTEXITCODE
    $rungRecord = $null
    try { $rungRecord = ($rungOutput | ConvertFrom-Json) } catch { }
    $rungDetail = if ($rungRecord -and $rungRecord.reason) { [string]$rungRecord.reason } else { $rungOutput.Trim() }
    $rungCommand = "pwsh -NoProfile -File `"$rungGuard`" -Repo $repoName"
    switch ($rungExit) {
        0 { Add-Part -Name 'rungs' -Status 'SKIP' -Detail $rungDetail }
        1 { Add-Part -Name 'rungs' -Status 'BLOCKED' -Detail $rungDetail -Command ("{0}  # keep ONE rung active (pause or delete the other), then re-run" -f $rungCommand) }
        2 { Add-Part -Name 'rungs' -Status 'BLOCKED' -Detail $rungDetail -Command $rungCommand }
        3 { Add-Part -Name 'rungs' -Status 'INFO' -Detail $rungDetail }
        default { Add-Part -Name 'rungs' -Status 'BLOCKED' -Detail ("rung guard returned unexpected exit {0}: {1}" -f $rungExit, $rungDetail) }
    }
}

# ---- Working tree --------------------------------------------------------
$status = @(& git -C $RepoRoot status --porcelain | Where-Object { $_ })
$trackedDirty = @($status | Where-Object { $_ -notmatch '^\?\?' })
$untracked = @($status | Where-Object { $_ -match '^\?\?' })
if ($trackedDirty.Count -gt 0) {
    $paths = @($trackedDirty | ForEach-Object { ($_ -replace '^..\s+', '').Trim() } | Where-Object { $_ })
    $shown = if ($paths.Count -gt 5) { (@($paths[0..4]) -join ',') + ',…' } else { $paths -join ',' }
    Add-Part -Name 'commit' -Status 'NEEDED' `
        -Detail ("{0} tracked path(s) modified; commit them before grooming" -f $trackedDirty.Count) `
        -Command ("pwsh -NoProfile -File `"{0}`" -RepoRoot `"{1}`" -Paths '{2}' -Message '<why this work exists>'" -f $safeCommit, $RepoRoot, $shown)
}
else {
    Add-Part -Name 'commit' -Status 'SKIP' -Detail 'no tracked modifications'
}
if ($untracked.Count -gt 0) {
    Add-Part -Name 'untracked' -Status 'INFO' -Detail ("{0} untracked path(s) left alone (never swept into a commit)" -f $untracked.Count)
}

# ---- Remote sync ---------------------------------------------------------
$remotes = @(& git -C $RepoRoot remote)
if (-not $NoFetch -and $remotes.Count -gt 0) {
    foreach ($remote in $remotes) { $null = & git -C $RepoRoot fetch --quiet $remote 2>&1 }
}
$syncParts = @()
$pushNeeded = @()
$pullNeeded = @()
foreach ($remote in $remotes) {
    $counts = @(& git -C $RepoRoot rev-list --left-right --count "$remote/$Trunk...$Trunk" 2>$null)
    if ($LASTEXITCODE -ne 0 -or $counts.Count -eq 0) {
        $syncParts += "$remote=no-track"
        continue
    }
    $nums = (($counts -join ' ') -split '\s+') | Where-Object { $_ -ne '' }
    $behind = [int]$nums[0]
    $ahead = [int]$nums[1]
    $syncParts += "$remote=$ahead/$behind"
    if ($ahead -gt 0) { $pushNeeded += $remote }
    if ($behind -gt 0) { $pullNeeded += $remote }
}
$syncDetail = if ($syncParts.Count -gt 0) { ($syncParts -join ', ') } else { 'no remotes configured' }
$pushCommand = @($pushNeeded | ForEach-Object { "git -C `"$RepoRoot`" push $_ $Trunk" }) -join '; '
if ($pullNeeded.Count -gt 0 -and $pullSafe) {
    Add-Part -Name 'sync' -Status 'NEEDED' `
        -Detail ("$syncDetail | trunk behind $($pullNeeded -join ', '); fast-forward first") `
        -Command ("pwsh -NoProfile -File `"{0}`" -RepoRoot `"{1}`" -Trunk {2}" -f $pullSafe, $RepoRoot, $Trunk)
}
elseif ($pullNeeded.Count -gt 0) {
    Add-Part -Name 'sync' -Status 'BLOCKED' `
        -Detail ("$syncDetail | trunk behind $($pullNeeded -join ', ') but no guarded trunk-sync helper at $pullSafePath - refusing to advertise a blind rebase; restore the canonical helper before syncing") `
        -Command ("# restore the canonical guarded helper: {0}" -f $pullSafePath)
}
elseif ($pushNeeded.Count -gt 0) {
    Add-Part -Name 'sync' -Status 'NEEDED' -Detail ("$syncDetail | trunk ahead of $($pushNeeded -join ', ')") -Command $pushCommand
}
else {
    Add-Part -Name 'sync' -Status 'SKIP' -Detail $syncDetail
}

# ---- Helper freshness ----------------------------------------------------
# A helper invoked by ABSOLUTE PATH from a checkout nobody updated serves OLD
# semantics. On 2026-11-01 a Hub ran the v1 HubRegistry.ps1 out of the cl-common
# main checkout and it silently wrote a v1 record - which, once v2 records exist,
# collapses a set of hubs back to a single slot. That is data loss, not
# staleness, and it is invisible from the caller's side: the path looked
# canonical. The checkout that hosts the skill is the only place that can answer
# "is this the shipped code", so it compares its own Skills/ to the trunk.
$skillsDir = Join-Path $RepoRoot 'Skills'
$helperDrift = @()
if (Test-Path -LiteralPath $skillsDir) {
    foreach ($remote in $remotes) {
        $drift = @(& git -C $RepoRoot diff --name-only "$remote/$Trunk" -- Skills 2>$null)
        if ($LASTEXITCODE -ne 0) { continue }
        if ($drift.Count -gt 0) { $helperDrift += "$remote=$($drift.Count)" }
    }
}
if (-not (Test-Path -LiteralPath $skillsDir)) {
    Add-Part -Name 'helpers' -Status 'SKIP' -Detail 'no Skills/ in this checkout'
}
elseif ($helperDrift.Count -gt 0) {
    Add-Part -Name 'helpers' -Status 'NEEDED' `
        -Detail ("Skills/ differs from the trunk ($($helperDrift -join ', ') file(s)) - helpers invoked from this checkout are NOT the shipped semantics, and a stale helper writes the record shape it knows rather than the current one. Sync this checkout (see the sync part) before running any skill helper from it") `
        -Command ("git -C `"$RepoRoot`" diff --stat origin/$Trunk -- Skills  # review, then sync; do not invoke helpers here until this is empty")
}
else {
    Add-Part -Name 'helpers' -Status 'SKIP' -Detail 'Skills/ matches the trunk'
}

# ---- Merge queue rows ----------------------------------------------------
$queueFile = Resolve-QueueFile -Slug $slug
$rows = @(Get-QueueRows -Path $queueFile)
$activeRows = @($rows | Where-Object { $_.status -in @('queued', 'merging') })
$landedRows = @($activeRows | Where-Object { $_.sha -and $(git -C $RepoRoot merge-base --is-ancestor $_.sha $Trunk 2>$null; $LASTEXITCODE -eq 0) })
$pendingRows = @($activeRows | Where-Object { $landedRows -notcontains $_ })
# The identity source is printed even when the part SKIPs: an empty queue is only
# honest when the reader can see WHICH repo was looked up. 'no queue file' plus a
# lane name is how a Hub came to believe a busy repo had nothing queued.
$identityDetail = "identity: $($identity.Source) '$repoName'"
if ($identityNote) { $identityDetail += " | $identityNote" }
if (-not $queueFile) {
    Add-Part -Name 'reconcile' -Status 'SKIP' -Detail ("no queue file for '{0}' ({1})" -f $slug, $identityDetail)
}
elseif ($landedRows.Count -gt 0) {
    Add-Part -Name 'reconcile' -Status 'NEEDED' `
        -Detail ("{0} active row(s) already on the trunk ({1}); {2} row(s) still to drain" -f $landedRows.Count, (($landedRows | ForEach-Object { $_.branch }) -join ', '), $pendingRows.Count) `
        -Command ("node `"{0}`" prune --repo {1} --repo-root `"{2}`" --base {3}" -f $queueHelper, $slug, $RepoRoot, $Trunk)
}
else {
    Add-Part -Name 'reconcile' -Status $(if ($pendingRows.Count -gt 0) { 'INFO' } else { 'SKIP' }) `
        -Detail ("{0} active row(s), {1} already landed" -f $activeRows.Count, $landedRows.Count)
}

# ---- Branches: fold vs retire -------------------------------------------
$localBranches = @(& git -C $RepoRoot for-each-ref --format='%(refname:short)' refs/heads |
    Where-Object { $_ -and $permanent -notcontains $_ })
$toMerge = @()
$toRetire = @()
$manifestTouchers = @()
foreach ($name in $localBranches) {
    $counts = @(& git -C $RepoRoot rev-list --left-right --count "$Trunk...$name" 2>$null)
    if ($LASTEXITCODE -ne 0 -or $counts.Count -eq 0) { continue }
    $nums = (($counts -join ' ') -split '\s+') | Where-Object { $_ -ne '' }
    $branchOnly = [int]$nums[1]
    if ($branchOnly -eq 0) { $toRetire += $name; continue }
    # Commits already on the trunk by patch id (cherry-picked branch).
    $cherry = @(& git -C $RepoRoot cherry $Trunk $name 2>$null)
    if ($LASTEXITCODE -eq 0 -and @($cherry | Where-Object { $_ -match '^\+' }).Count -eq 0) {
        $toRetire += $name
        continue
    }
    $toMerge += $name
    $touched = @(& git -C $RepoRoot diff --name-only "$Trunk...$name" -- '*package.json' '*pnpm-workspace.yaml' '*pnpm-lock.yaml' 2>$null)
    if ($touched.Count -gt 0) { $manifestTouchers += $name }
}

if ($toMerge.Count -gt 0) {
    Add-Part -Name 'merge' -Status 'NEEDED' `
        -Detail ("{0} branch(es) carry work not on the trunk: {1}" -f $toMerge.Count, ($toMerge -join ', ')) `
        -Command ("pwsh -NoProfile -File `"{0}`" -RepoRoot `"{1}`" -OnConflict CherryPick" -f $trunkPrep, $RepoRoot)
}
else {
    Add-Part -Name 'merge' -Status 'SKIP' -Detail 'no local branch carries work outside the trunk'
}

$extraWorktrees = 0
$wts = @(& git -C $RepoRoot worktree list --porcelain | Where-Object { $_ -match '^worktree ' })
$extraWorktrees = [Math]::Max(0, $wts.Count - 1)
if ($toRetire.Count -gt 0 -or $extraWorktrees -gt 0) {
    $bits = @()
    if ($toRetire.Count -gt 0) { $bits += ("merged/equivalent branch(es): " + ($toRetire -join ', ')) }
    if ($extraWorktrees -gt 0) { $bits += ("{0} extra worktree(s)" -f $extraWorktrees) }
    Add-Part -Name 'hygiene' -Status 'NEEDED' -Detail ($bits -join '; ') `
        -Command ("pwsh -NoProfile -File `"{0}`" -RepoRoot `"{1}`" -IncludeRoot -BranchDays 0 -WorktreeDays 0 -Apply -IncludePatchEquivalent" -f $hygiene, $RepoRoot)
}
else {
    Add-Part -Name 'hygiene' -Status 'SKIP' -Detail 'no merged branches or extra worktrees to retire'
}

# ---- Shared-dependency gate ---------------------------------------------
if ($manifestTouchers.Count -gt 0) {
    Add-Part -Name 'shared-deps' -Status 'NEEDED' `
        -Detail ("dependency manifests touched by: {0}" -f ($manifestTouchers -join ', ')) `
        -Command ("node `"{0}`" --root `"{1}`" --ref origin/{2}" -f $sharedDeps, $fleetRoot, $Trunk)
}
else {
    Add-Part -Name 'shared-deps' -Status 'SKIP' -Detail 'no pending branch touches a dependency manifest'
}

# ---- Verdict -------------------------------------------------------------
$needed = @($parts | Where-Object { $_.Status -eq 'NEEDED' })
$blocked = @($parts | Where-Object { $_.Status -eq 'BLOCKED' }).Count -gt 0
$verdict = if ($blocked) { 'BLOCKED' } elseif ($needed.Count -gt 0) { 'GROOM NEEDED' } else { 'READY' }
$results = [ordered]@{
    schemaVersion = 1
    repo          = $repoName
    slug          = $slug
    identity      = $identity.Source
    identityNotes = $identityNote
    repoRoot      = $RepoRoot
    trunk         = $Trunk
    branch        = $branch
    fetched       = (-not $NoFetch)
    verdict       = $verdict
    commands      = @($needed | ForEach-Object { $_.Command })
    parts         = @($parts)
    counts        = [ordered]@{
        trackedDirty = $trackedDirty.Count
        untracked    = $untracked.Count
        fold         = $toMerge.Count
        retire       = $toRetire.Count
        worktrees    = $extraWorktrees
        queueActive  = $activeRows.Count
        queueLanded  = $landedRows.Count
    }
}

if ($Json) {
    Write-Output ($results | ConvertTo-Json -Depth 6)
}
else {
    Write-Host ''
    Write-Host ("Hub probe - {0} ({1}, identity {2}) trunk={3} -> {4}" -f $repoName, $slug, $identity.Source, $Trunk, $verdict)
    if ($identityNote) { Write-Host ("identity note: {0}" -f $identityNote) -ForegroundColor Yellow }
    Write-Host ''
    $parts | Format-Table -AutoSize -Property Part, Status, Detail | Out-String | Write-Host
    if ($needed.Count -gt 0) {
        Write-Host 'Run only what is flagged, in this order:'
        $i = 1
        foreach ($part in $needed) {
            Write-Host ("  {0}. {1}" -f $i, $part.Command)
            $i++
        }
        Write-Host '  then re-run this probe; READY means the groom is done.' -ForegroundColor DarkGray
    }
    else {
        Write-Host 'Nothing to groom: advertise the Hub.' -ForegroundColor Green
    }
}
if ($blocked) { exit 1 }
exit 0
