#Requires -Version 7.0
<#
.SYNOPSIS
    The merge queue: an append-only record of branches waiting to land, owned by
    this package.

.DESCRIPTION
    A Sub parks finished work here; a Hub claims one row at a time and merges it.
    The queue is the TRUTH about what is waiting; a doorbell ping is only an
    attempt to attract attention, so a lost ping costs time and a lost row costs
    work.

    WHY THIS EXISTS IN THE PACKAGE
    The queue used to be `node <fleet>/currents-bookkeeping/scripts/merge-queue.mjs`.
    That made the Sub contract depend on a checkout of a DIFFERENT product repo, so
    a machine with this plugin and `bd` could not park anything - the one thing the
    plugin promises to do standalone. The row format is therefore identical to that
    tool's (version 1, append-only, collapse-to-latest), so an existing queue file
    keeps working and either tool can read the other's rows.

    WHERE THE QUEUE LIVES
      <repo>/.iqa/merge-queue/<repo>.jsonl     default: repo-scoped state
      $env:MERGE_QUEUE_DIR/<repo>.jsonl        override (a fleet-wide queue)
      -QueueDir <dir>                          explicit override

    The repo root is resolved from -RepoRoot, else the current checkout, and a
    linked worktree resolves to the MAIN checkout (worktrees share one `.git`), so
    a lane enqueues into the repo it belongs to rather than into its own scratch
    directory. Queue state is never written beside the package: a published
    package must not accumulate runtime files.

    ROW FORMAT (one compact JSON object per line, `v` first)
      { "v":1, "ts":..., "repo":..., "branch":..., "base":..., "sha":...,
        "worktree":..., "owner":..., "status":..., "note":..., "urgent":bool }
      plus "claimedBy"/"claimedAt" on a claimed row.

    STATUS VALUES
      queued    waiting for a Hub to take it
      merging   claimed by exactly one Hub (the single-pusher rule)
      merged    landed, proven by Test-Landed.ps1
      dropped   deliberately not landing, with the reason in `note`
      pruned    branch gone on origin, or already an ancestor of the base
      superseded  re-enqueued as a newer branch shape (kept for history)

    A new row for a branch SUPERSEDES its earlier rows: List collapses to the
    latest row per branch, urgent-first then newest-first. Nothing is ever
    deleted, so the queue is also its own audit trail.

.PARAMETER Mode
    Enqueue | List | Mark | Claim | Prune | Status.

.PARAMETER Repo
    Repo slug this queue belongs to (for example `currents-bookkeeping`). It names
    the queue file, so it must be a plain name - a path separator is refused rather
    than silently creating a nested file.

.PARAMETER Branch
    Branch name for Enqueue/Mark.

.PARAMETER Sha
    The FROZEN tip SHA being parked. Required on Enqueue: a queue row without a
    SHA cannot be merged reproducibly.

.PARAMETER Worktree
    Absolute path of the worktree the branch was built in, so a Hub can inspect it.

.PARAMETER Owner
    Who parked it (agent id, lane name, or person).

.PARAMETER Base
    Trunk the branch lands on. Default `dev`.

.PARAMETER Note
    Free text. On a re-enqueue it carries the COMPLETE hand-off packet - a doorbell
    ping is never the payload.

.PARAMETER Urgent
    Per-enqueue priority, never inherited: a later Enqueue without it returns the
    branch to normal. Urgent rows sort first.

.PARAMETER Status
    New status for Mark, or a filter for List.

.PARAMETER ClaimedBy
    Identity recorded on a Claim. Defaults to the current user.

.PARAMETER Force
    Claim even though another row is already `merging`. Only for recovering from a
    dead Hub - the single-pusher rule exists to keep two hubs off one trunk.

.PARAMETER RepoRoot
    Checkout to resolve the queue directory from, and the checkout `Prune` probes.
    Defaults to the current directory's checkout.

.PARAMETER QueueDir
    Explicit queue directory. Overrides $env:MERGE_QUEUE_DIR and the repo default.

.EXAMPLE
    # Sub: park a frozen branch
    pwsh -NoProfile -File tools/Invoke-IqaQueue.ps1 -Mode Enqueue -Repo upscale-havens `
      -Branch lane/fix-lease -Sha 4f2a1c9 -Worktree <repo>/.worktrees/fix-lease -Owner lane-7

.EXAMPLE
    # Hub: take the next row, refusing to double-merge
    pwsh -NoProfile -File tools/Invoke-IqaQueue.ps1 -Mode Claim -Repo upscale-havens -Json

.EXAMPLE
    # Hub: prove the landing, then close the row
    pwsh -NoProfile -File tools/Invoke-IqaQueue.ps1 -Mode Mark -Repo upscale-havens `
      -Branch lane/fix-lease -Status merged -Note 'landed by Test-Landed.ps1'

.EXAMPLE
    # Reconcile against origin: branches gone or already on the trunk
    pwsh -NoProfile -File tools/Invoke-IqaQueue.ps1 -Mode Prune -Repo upscale-havens -RepoRoot <repo>

.OUTPUTS
    JSON (with -Json) or a compact human line. Exit 0 on success.
    Exit 1 when a row cannot be claimed (nothing to claim, or a merge is live).
    Exit 2 on usage or operational failure - fail-closed, never a silent no-op.
#>
[CmdletBinding()]
param(
    [ValidateSet('Enqueue', 'List', 'Mark', 'Claim', 'Prune', 'Status')]
    [string]$Mode = 'Status',

    [string]$Repo,

    [string]$Branch,
    [string]$Sha,
    [string]$Worktree,
    [string]$Owner,
    [string]$Base = 'dev',
    [string]$Note = '',

    [switch]$Urgent,

    [ValidateSet('queued', 'merging', 'merged', 'dropped', 'pruned', 'superseded')]
    [string]$Status,

    [string]$ClaimedBy,

    [switch]$Force,

    [string]$RepoRoot,

    [string]$QueueDir,

    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RecordVersion = 1
$Statuses = @('queued', 'merging', 'merged', 'dropped', 'pruned', 'superseded')
$LiveStatuses = @('queued', 'merging')

# StrictMode is on, so an optional field that a row does not carry is a THROW, not
# $null. Optional fields are exactly what makes this format forward-compatible (a
# row may carry `urgent`, `claimedBy`, `claimedAt`, or none of them), so every read
# goes through one accessor and a missing field is a value, not a crash.
function Get-Field {
    param([object]$Row, [Parameter(Mandatory)][string]$Name)

    if ($null -eq $Row) { return $null }
    $property = $Row.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

function Stop-Usage {
    param([Parameter(Mandatory)][string]$Message, [int]$Code = 2)
    if ($Json) {
        [pscustomobject]@{ ok = $false; error = $Message } | ConvertTo-Json -Compress
    }
    else {
        Write-Host "Invoke-IqaQueue: $Message" -ForegroundColor Red
    }
    exit $Code
}

function Resolve-CheckoutRoot {
    param([string]$Explicit)

    if ($Explicit) {
        if (-not (Test-Path -LiteralPath $Explicit -PathType Container)) {
            Stop-Usage "RepoRoot not found: $Explicit"
        }
        return (Resolve-Path -LiteralPath $Explicit).Path
    }

    $probe = (Get-Location).Path
    $commonDir = & git -C $probe rev-parse --git-common-dir 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($commonDir)) {
        return $probe
    }

    # A linked worktree reports the MAIN checkout's `.git` here. That is the
    # point: a lane parks into the repo it belongs to, not into its scratch tree.
    $commonDir = $commonDir.Trim()
    if (-not [System.IO.Path]::IsPathRooted($commonDir)) {
        $commonDir = Join-Path $probe $commonDir
    }
    $commonDir = (Resolve-Path -LiteralPath $commonDir).Path
    if ((Split-Path -Leaf $commonDir) -eq '.git') { return (Split-Path -Parent $commonDir) }
    return $probe
}

function Resolve-QueueDirectory {
    param([string]$Explicit, [string]$RepoRootPath)

    if ($Explicit) { return $Explicit }
    if (-not [string]::IsNullOrWhiteSpace($env:MERGE_QUEUE_DIR)) { return $env:MERGE_QUEUE_DIR }
    return (Join-Path (Join-Path $RepoRootPath '.iqa') 'merge-queue')
}

function Assert-RepoSlug {
    param([string]$Value, [string]$Command)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        Stop-Usage "$Command requires -Repo <slug> (it names the queue file)"
    }
    if ($Value -match '[\\/:*?"<>|]' -or $Value -eq '.' -or $Value -eq '..') {
        Stop-Usage "-Repo '$Value' is not a plain repo slug - it names a queue file, so a path separator would write somewhere else"
    }
    return $Value
}

# Append one line under mutual exclusion. Opening for append with FileShare.Read
# means a second writer fails fast instead of interleaving, and the retry loop
# turns that contention into a short wait rather than a lost row.
function Add-QueueRecord {
    param([string]$Path, [object]$Record)

    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }

    $line = ($Record | ConvertTo-Json -Compress -Depth 6) + "`n"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($line)

    $attempt = 0
    while ($true) {
        $attempt++
        try {
            $stream = [System.IO.FileStream]::new(
                $Path,
                [System.IO.FileMode]::Append,
                [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::Read
            )
            try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
            return
        }
        catch [System.IO.IOException] {
            if ($attempt -ge 20) {
                Stop-Usage "could not append to $Path after $attempt attempts: $($_.Exception.Message)"
            }
            Start-Sleep -Milliseconds (50 * $attempt)
        }
    }
}

function Read-QueueRecords {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    $records = [System.Collections.Generic.List[object]]::new()
    $lineNumber = 0
    foreach ($line in (Get-Content -LiteralPath $Path -Encoding utf8)) {
        $lineNumber++
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $records.Add(($line | ConvertFrom-Json -ErrorAction Stop))
        }
        catch {
            # Fail closed on a corrupt line: a partially read queue silently
            # forgetting a branch is how work disappears.
            Stop-Usage "$Path line $lineNumber is not valid JSON ($($_.Exception.Message)); fix it by hand - the queue is never auto-rewritten"
        }
    }
    return $records
}

function Get-LatestRows {
    param([object[]]$Records)

    $byBranch = [ordered]@{}
    foreach ($record in $Records) {
        $key = [string](Get-Field $record 'branch')
        if (-not $key) { continue }
        $byBranch[$key] = $record
    }

    # Urgent first, then newest: a deploy-blocking parking is taken before a
    # routine one regardless of when it arrived.
    $rows = @($byBranch.Values)
    return @($rows | Sort-Object -Property @{ Expression = { if ((Get-Field $_ 'urgent') -eq $true) { 0 } else { 1 } } }, @{ Expression = { [string](Get-Field $_ 'ts') }; Descending = $true })
}

function Write-Row {
    param([object]$Row)

    if ($Json) { $Row | ConvertTo-Json -Compress -Depth 6; return }
    $urgentFlag = if ((Get-Field $Row 'urgent') -eq $true) { ' URGENT' } else { '' }
    "{0,-10} {1}{2} @ {3}  base={4}  by {5}" -f (Get-Field $Row 'status'), (Get-Field $Row 'branch'), $urgentFlag, (Get-Field $Row 'sha'), (Get-Field $Row 'base'), (Get-Field $Row 'owner')
}

# ---------------------------------------------------------------------------
$repoRootPath = Resolve-CheckoutRoot -Explicit $RepoRoot

if ($Mode -eq 'Prune' -or $Mode -eq 'Status') {
    # Status can summarise the whole queue directory; the other modes need a repo.
    if ($Mode -eq 'Prune') { [void](Assert-RepoSlug -Value $Repo -Command $Mode) }
}
else {
    [void](Assert-RepoSlug -Value $Repo -Command $Mode)
}

$queueDirectory = Resolve-QueueDirectory -Explicit $QueueDir -RepoRootPath $repoRootPath

if ($Mode -eq 'Status' -and [string]::IsNullOrWhiteSpace($Repo)) {
    $queues = @(Get-ChildItem -LiteralPath $queueDirectory -Filter '*.jsonl' -ErrorAction SilentlyContinue)
    $summary = foreach ($file in $queues) {
        $name = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
        $latest = Get-LatestRows -Records (Read-QueueRecords -Path $file.FullName)
        $counts = @{}
        foreach ($s in $Statuses) { $counts[$s] = 0 }
        foreach ($row in $latest) { $k = [string](Get-Field $row 'status'); if ($counts.ContainsKey($k)) { $counts[$k]++ } }
        [pscustomobject]@{
            repo    = $name
            queued  = $counts['queued']
            merging = $counts['merging']
            merged  = $counts['merged']
            held    = $counts['dropped'] + $counts['pruned'] + $counts['superseded']
            next    = @($latest | Where-Object { (Get-Field $_ 'status') -eq 'queued' } | Select-Object -First 1).Count
            file    = $file.FullName
        }
    }
    if ($Json) { @($summary) | ConvertTo-Json -Depth 4; exit 0 }
    if (-not $summary) { "no queues under $queueDirectory"; exit 0 }
    $summary | Format-Table -AutoSize | Out-String -Width 140
    exit 0
}

$queueFile = Join-Path $queueDirectory "$Repo.jsonl"
$records = @(Read-QueueRecords -Path $queueFile)
$latest = @(Get-LatestRows -Records $records)

switch ($Mode) {

    'Enqueue' {
        if ([string]::IsNullOrWhiteSpace($Branch)) { Stop-Usage 'Enqueue requires -Branch' }
        if ([string]::IsNullOrWhiteSpace($Sha)) { Stop-Usage 'Enqueue requires -Sha (the frozen tip being parked)' }
        if ([string]::IsNullOrWhiteSpace($Worktree)) { Stop-Usage 'Enqueue requires -Worktree (where a Hub inspects the branch)' }
        if ([string]::IsNullOrWhiteSpace($Owner)) { Stop-Usage 'Enqueue requires -Owner' }

        $record = [ordered]@{
            v        = $RecordVersion
            ts       = (Get-Date).ToUniversalTime().ToString('o')
            repo     = $Repo
            branch   = $Branch
            base     = $Base
            sha      = $Sha
            worktree = $Worktree
            owner    = $Owner
            status   = 'queued'
            note     = $Note
        }
        if ($Urgent) { $record['urgent'] = $true }

        Add-QueueRecord -Path $queueFile -Record $record
        Write-Row -Row ([pscustomobject]$record)
        exit 0
    }

    'List' {
        $rows = $latest
        if ($Status) { $rows = @($rows | Where-Object { (Get-Field $_ 'status') -eq $Status }) }
        if ($Json) { @($rows) | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 6 }; exit 0 }
        if (-not $rows) { "queue empty for $Repo ($queueFile)"; exit 0 }
        $rows | ForEach-Object { Write-Row -Row $_ }
        exit 0
    }

    'Mark' {
        if ([string]::IsNullOrWhiteSpace($Branch)) { Stop-Usage 'Mark requires -Branch' }
        if (-not $Status) { Stop-Usage "Mark requires -Status ($($Statuses -join '|'))" }

        $current = $latest | Where-Object { (Get-Field $_ 'branch') -eq $Branch } | Select-Object -First 1
        if (-not $current) { Stop-Usage "Mark: no queue row for branch '$Branch' (enqueue it first)" }

        if (-not $PSBoundParameters.ContainsKey('Note')) { $Note = [string](Get-Field $current 'note') }

        $record = [ordered]@{
            v        = $RecordVersion
            ts       = (Get-Date).ToUniversalTime().ToString('o')
            repo     = $Repo
            branch   = $Branch
            base     = [string](Get-Field $current 'base')
            sha      = [string](Get-Field $current 'sha')
            worktree = [string](Get-Field $current 'worktree')
            owner    = [string](Get-Field $current 'owner')
            status   = $Status
            note     = $Note
        }
        if ((Get-Field $current 'urgent') -eq $true) { $record['urgent'] = $true }
        if (Get-Field $current 'claimedBy') { $record['claimedBy'] = [string](Get-Field $current 'claimedBy') }
        if (Get-Field $current 'claimedAt') { $record['claimedAt'] = [string](Get-Field $current 'claimedAt') }

        Add-QueueRecord -Path $queueFile -Record $record
        Write-Row -Row ([pscustomobject]$record)
        exit 0
    }

    'Claim' {
        $liveMerge = $latest | Where-Object { (Get-Field $_ 'status') -eq 'merging' } | Select-Object -First 1
        if ($liveMerge -and -not $Force) {
            if ($Json) {
                [pscustomobject]@{
                    ok     = $false
                    error  = "a merge is already live: $(Get-Field $liveMerge 'branch') claimed by $(Get-Field $liveMerge 'claimedBy')"
                    branch = (Get-Field $liveMerge 'branch')
                } | ConvertTo-Json -Compress
            }
            else {
                Write-Host "Claim refused: '$(Get-Field $liveMerge 'branch')' is already merging (claimed by $(Get-Field $liveMerge 'claimedBy')). One pusher per trunk." -ForegroundColor Yellow
            }
            exit 1
        }

        $next = $latest | Where-Object { (Get-Field $_ 'status') -eq 'queued' } | Select-Object -First 1
        if (-not $next) {
            if ($Json) { [pscustomobject]@{ ok = $false; error = 'nothing queued' } | ConvertTo-Json -Compress }
            else { "nothing queued for $Repo" }
            exit 1
        }

        $identity = if ($ClaimedBy) { $ClaimedBy } else { "$env:USERNAME@$env:COMPUTERNAME" }
        $record = [ordered]@{
            v         = $RecordVersion
            ts        = (Get-Date).ToUniversalTime().ToString('o')
            repo      = $Repo
            branch    = [string](Get-Field $next 'branch')
            base      = [string](Get-Field $next 'base')
            sha       = [string](Get-Field $next 'sha')
            worktree  = [string](Get-Field $next 'worktree')
            owner     = [string](Get-Field $next 'owner')
            status    = 'merging'
            note      = [string](Get-Field $next 'note')
            claimedBy = $identity
            claimedAt = (Get-Date).ToUniversalTime().ToString('o')
        }
        if ((Get-Field $next 'urgent') -eq $true) { $record['urgent'] = $true }

        Add-QueueRecord -Path $queueFile -Record $record
        Write-Row -Row ([pscustomobject]$record)
        exit 0
    }

    'Prune' {
        $candidates = @($latest | Where-Object { $LiveStatuses -contains (Get-Field $_ 'status') })
        if (-not $candidates) { "nothing live to prune for $Repo"; exit 0 }

        $gitVersion = & git --version 2>$null
        if ($LASTEXITCODE -ne 0) { Stop-Usage 'Prune needs git on PATH' }

        $pruned = 0
        $merged = 0
        foreach ($row in $candidates) {
            $remote = & git -C $repoRootPath ls-remote --heads origin ([string](Get-Field $row 'branch')) 2>$null
            if ($LASTEXITCODE -ne 0) {
                Stop-Usage "Prune: git ls-remote failed for '$(Get-Field $row 'branch')' - is $repoRootPath a checkout with an origin remote?"
            }

            if ([string]::IsNullOrWhiteSpace(($remote | Out-String).Trim())) {
                $record = [ordered]@{
                    v = $RecordVersion; ts = (Get-Date).ToUniversalTime().ToString('o'); repo = $Repo
                    branch = [string](Get-Field $row 'branch'); base = [string](Get-Field $row 'base'); sha = [string](Get-Field $row 'sha')
                    worktree = [string](Get-Field $row 'worktree'); owner = [string](Get-Field $row 'owner')
                    status = 'pruned'; note = 'branch gone on origin'
                }
                Add-QueueRecord -Path $queueFile -Record $record
                $pruned++
                continue
            }

            $base = if (Get-Field $row 'base') { [string](Get-Field $row 'base') } else { $Base }
            & git -C $repoRootPath merge-base --is-ancestor ([string](Get-Field $row 'branch')) $base 2>$null
            if ($LASTEXITCODE -eq 0) {
                $record = [ordered]@{
                    v = $RecordVersion; ts = (Get-Date).ToUniversalTime().ToString('o'); repo = $Repo
                    branch = [string]$row.branch; base = $base; sha = [string]$row.sha
                    worktree = [string](Get-Field $row 'worktree'); owner = [string](Get-Field $row 'owner')
                    status = 'merged'; note = "already an ancestor of $base"
                }
                Add-QueueRecord -Path $queueFile -Record $record
                $merged++
            }
            # A non-ancestor (exit 1) or unresolvable ref (exit 128) is KEPT:
            # absence of proof is not proof of absence.
        }

        $result = "prune: $pruned pruned, $merged merged, $($candidates.Count - $pruned - $merged) kept"
        if ($Json) { [pscustomobject]@{ ok = $true; repo = $Repo; pruned = $pruned; merged = $merged; kept = ($candidates.Count - $pruned - $merged) } | ConvertTo-Json -Compress }
        else { $result }
        exit 0
    }

    'Status' {
        $counts = [ordered]@{}
        foreach ($s in $Statuses) { $counts[$s] = 0 }
        foreach ($row in $latest) {
            $key = [string](Get-Field $row 'status')
            if ($counts.Contains($key)) { $counts[$key]++ } else { $counts[$key] = 1 }
        }
        $nextRow = $latest | Where-Object { (Get-Field $_ 'status') -eq 'queued' } | Select-Object -First 1

        $payload = [pscustomobject]@{
            ok      = $true
            repo    = $Repo
            file    = $queueFile
            queued  = $counts['queued']
            merging = $counts['merging']
            merged  = $counts['merged']
            held    = $counts['dropped'] + $counts['pruned'] + $counts['superseded']
            next    = if ($nextRow) { [string](Get-Field $nextRow 'branch') } else { $null }
        }
        if ($Json) { $payload | ConvertTo-Json -Compress; exit 0 }
        "Status: $($payload.queued) queued - $($payload.merging) merging - $($payload.merged) merged - $($payload.held) held"
        if ($payload.next) { "next: $($payload.next)" } else { 'next: (empty)' }
        exit 0
    }
}
