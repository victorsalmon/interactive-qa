#Requires -Version 7.0
<#
.SYNOPSIS
    Deterministic beads-graph monitor: compact snapshots, stall findings, and an
    on-demand completion-rate vs token-burn report. No model, no tokens.

.DESCRIPTION
    Runs as a plain script (Windows Task Scheduler). Reading the graph and writing
    a snapshot costs nothing but CPU; the only token spend in this design is a Hub
    turn that a *finding* causes, and that turn receives one compact line.

    WHAT IT STORES
      <state>/monitor/<repo>.jsonl   one compact line per snapshot (~150 B)
      <state>/monitor/<repo>.latest.json   last signature/timestamps (tier state)
      <state>/monitor/findings.json  latest stall findings (named, with evidence)

    ADAPTIVE CADENCE (snapshot only when worth it)
      a state CHANGE always writes.
      otherwise the interval follows activity age:
        <= 1 h activity  -> 15 min
        <= 6 h           -> 60 min
        <= 24 h          -> 360 min
        older            -> 720 min
      An idle repo therefore writes ~1-4 lines/day instead of 24.

    MEASURED vs ASSUMED
      counts, trunk sha, worktree count and the weekly-quota reading are MEASURED.
      estimate-minutes are NOT exposed by `bd list --json` (and no bead carries
      one today), so they are derived from a declared priority table and every
      line records which basis produced them. Reports say "assumed" out loud.

.PARAMETER Mode
    Snapshot (default) write-if-due; Check stall findings; Report rate vs burn;
    Rollup collapse old lines; Status last state without writing.

.PARAMETER Repo
    Restrict to these primary-repo names. Default: every repo in the registry.

.PARAMETER ReportHours
    Window for -Mode Report. Default 24.

.PARAMETER RetainDays
    -Mode Rollup keeps raw lines this long, collapsing older ones to daily. Default 7.

.EXAMPLE
    pwsh -NoProfile -File Invoke-IqaMonitor.ps1 -Mode Snapshot
.EXAMPLE
    pwsh -NoProfile -File Invoke-IqaMonitor.ps1 -Mode Report -ReportHours 48
#>
[CmdletBinding()]
param(
    [ValidateSet('Snapshot', 'Check', 'Report', 'Rollup', 'Status')]
    [string]$Mode = 'Snapshot',
    [string[]]$Repo,
    [int]$ReportHours = 24,
    [int]$RetainDays = 7,

    # Waking is a real delivery: the monitor finds the repo's live Hub in the
    # registry and sends it ONE compact line through the Paseo CLI. Without a live
    # hub there is nobody to wake, and spawning a new agent here would be a
    # dispatch decision, not a supervisor's - so that case is a named finding.
    [switch]$Wake,

    # Resolve and print the exact wake command without sending it. Use this to
    # verify the transport on a machine before arming the scheduled task.
    [switch]$WakeDryRun,

    [switch]$Json
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Declared assumptions - one place, printed by every report that uses them.
# ---------------------------------------------------------------------------
$EstimateBasis = 'priority-table'
$EstimateMinutes = @{ 1 = 120; 2 = 60; 3 = 30; 4 = 15 }

function Get-StateRoot {
    if (-not [string]::IsNullOrWhiteSpace($env:MACHINE_STATE_HOME)) { return $env:MACHINE_STATE_HOME }
    return (Join-Path (Join-Path $HOME '.machine') 'state')
}

function Get-PrimaryRepos {
    $resolver = Join-Path (Split-Path $PSScriptRoot -Parent) 'lib/Resolve-PrimaryRepos.ps1'
    if (-not (Test-Path -LiteralPath $resolver)) {
        throw "Resolve-PrimaryRepos.ps1 not found beside this script (looked in $resolver); the monitor cannot guess which repos are primary."
    }
    $resolved = & $resolver
    if (-not $resolved.Available) { throw $resolved.Reason }
    return $resolved.Repos
}

# -Repo accepts the canonical name, the slug, or any alias the registry records,
# because the operator says "uh" and the label says "hub-cbk". An unknown name is a
# named failure: silently supervising nothing looks exactly like a healthy fleet.
function Select-PrimaryRepos {
    param([object[]]$Primary, [string[]]$Names)

    if (-not $Names) { return @($Primary) }

    $wanted = @($Names | ForEach-Object { $_.Trim() })
    $selected = @($Primary | Where-Object {
            $row = $_
            $wanted -contains $row.name -or $wanted -contains $row.slug -or
            (@($row.aliases) | Where-Object { $wanted -contains $_ }) -or
            (@($wanted | Where-Object { $row.name -like "*$_*" })).Count -gt 0
        })

    if ($selected.Count -eq 0) {
        $known = ($Primary | ForEach-Object { "$($_.name) ($(@($_.aliases) -join '/'))" }) -join ', '
        throw "no primary repo matches '$($Names -join ', ')'; the registry knows: $known"
    }
    return $selected
}

function Resolve-PaseoCli {
    # Explicit override, then PATH, then the two documented install locations. The
    # locations are built from environment variables, never written as an absolute
    # path, so the publish gate stays honest and a different install still works.
    if (-not [string]::IsNullOrWhiteSpace($env:PASEO_CLI)) { return $env:PASEO_CLI }

    $onPath = Get-Command paseo -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }

    foreach ($candidate in @(
            # Paseo's own launcher first: it is the entry point its CLI documents and
            # the one lane-watch.mjs uses. paseo.exe beside it answers --help but is
            # not the daemon-aware wrapper.
            (Join-Path $env:ProgramFiles 'Paseo\resources\bin\paseo.cmd'),
            (Join-Path $env:ProgramFiles 'Paseo\paseo.exe'),
            (Join-Path $env:LOCALAPPDATA 'Programs\Paseo\paseo.exe')
        )) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) { return $candidate }
    }
    return $null
}

function Get-LiveHub {
    param([string]$Repo, [string]$HubRegistry)

    if (-not (Test-Path -LiteralPath $HubRegistry -PathType Leaf)) {
        return [pscustomobject]@{ Live = $false; AgentId = $null; Reason = "hub registry helper missing: $HubRegistry" }
    }
    try {
        $raw = & $HubRegistry -Mode Find -Repo $Repo -Json 2>$null | Out-String
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return [pscustomobject]@{ Live = $false; AgentId = $null; Reason = 'hub registry returned nothing' }
        }
        $record = $raw | ConvertFrom-Json
        $live = [bool]$record.live
        $agentId = if ($record.agentId) { [string]$record.agentId } else { $null }
        return [pscustomobject]@{
            Live    = $live
            AgentId = $agentId
            Reason  = if ($live) { "live hub as of $(($record.hubs | Select-Object -First 1).heartbeatAt)" } else { [string]$record.reason }
        }
    }
    catch {
        return [pscustomobject]@{ Live = $false; AgentId = $null; Reason = "hub registry could not be read: $($_.Exception.Message)" }
    }
}

function Send-MonitorWake {
    param([string]$Repo, [object[]]$Findings, [string]$MonitorDir, [switch]$DryRun)

    $packageRoot = Split-Path $PSScriptRoot -Parent
    $hubRegistry = Join-Path $packageRoot 'vendor/iqa-merge/HubRegistry.ps1'
    $hub = Get-LiveHub -Repo $Repo -HubRegistry $hubRegistry

    if (-not $hub.Live) {
        return [pscustomobject]@{
            repo      = $Repo
            delivered = $false
            agentId   = $null
            code      = 'WAKE-NO-HUB'
            detail    = "no live hub to wake: $($hub.Reason)"
        }
    }

    $paseoCli = Resolve-PaseoCli
    if (-not $paseoCli) {
        return [pscustomobject]@{
            repo      = $Repo
            delivered = $false
            agentId   = $hub.AgentId
            code      = 'WAKE-NO-TRANSPORT'
            detail    = 'Paseo CLI not found (set PASEO_CLI or put paseo on PATH); findings are on disk only'
        }
    }

    # One compact line per repo. A monitor that pastes its whole history into the
    # wake spends exactly the tokens it exists to save.
    $summary = ($Findings | ForEach-Object { "$($_.code): $($_.detail)" }) -join ' | '
    $promptPath = Join-Path $MonitorDir "wake-$Repo.txt"
    $prompt = "IQA MONITOR - $Repo needs a decision. $summary. Findings: $(Join-Path $MonitorDir 'findings.json'). Act on it or record why not; do not re-read the graph to rediscover this."
    Set-Content -LiteralPath $promptPath -Value $prompt -Encoding utf8

    $arguments = @('send', $hub.AgentId, '--prompt-file', $promptPath, '--behavior', 'steer', '--no-wait', '--json')

    if ($DryRun) {
        return [pscustomobject]@{
            repo      = $Repo
            delivered = $false
            dryRun    = $true
            agentId   = $hub.AgentId
            code      = 'WAKE-DRY-RUN'
            detail    = "would run: $paseoCli $($arguments -join ' ')"
        }
    }

    try {
        $output = & $paseoCli @arguments 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            return [pscustomobject]@{
                repo      = $Repo
                delivered = $false
                agentId   = $hub.AgentId
                code      = 'WAKE-FAILED'
                detail    = "paseo send exited $LASTEXITCODE`: $(($output -split "`n" | Select-Object -First 1))"
            }
        }
        return [pscustomobject]@{
            repo      = $Repo
            delivered = $true
            agentId   = $hub.AgentId
            code      = 'WAKE-SENT'
            detail    = "queued one monitor line to $($hub.AgentId)"
        }
    }
    catch {
        return [pscustomobject]@{
            repo      = $Repo
            delivered = $false
            agentId   = $hub.AgentId
            code      = 'WAKE-FAILED'
            detail    = $_.Exception.Message
        }
    }
}

function Get-LastWeeklyPercent {
    $log = Join-Path (Join-Path $HOME '.machine') 'logs/keycheck.jsonl'
    if (-not (Test-Path -LiteralPath $log)) { return $null }
    $last = Get-Content -LiteralPath $log -Tail 200 | Where-Object { $_ -match '"wk"\s*:' } | Select-Object -Last 1
    if (-not $last) { return $null }
    try { return [int](($last | ConvertFrom-Json).wk) } catch { return $null }
}

function Get-RepoState {
    param([pscustomobject]$Primary)

    $path = $Primary.path
    if (-not (Test-Path -LiteralPath (Join-Path $path '.beads'))) {
        return [pscustomobject]@{ Name = $Primary.name; Available = $false; Reason = "no beads graph at $path/.beads" }
    }

    # --all: the default filter hides closed beads, so a "closed" count of 0 would
    #        make the completion rate unable to move (caught in the first live run).
    # --brief: omits description/notes/acceptance text, 2.8x smaller; we only need
    #        id/status/priority/dates.
    $raw = & bd -C $path list --all --brief --json 2>$null | Out-String
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return [pscustomobject]@{ Name = $Primary.name; Available = $false; Reason = "bd list returned nothing for $path" }
    }
    $items = @($raw | ConvertFrom-Json)

    $counts = @{ open = 0; blocked = 0; in_progress = 0; deferred = 0; closed = 0 }
    $estOpen = 0; $estClosed = 0
    foreach ($i in $items) {
        $status = [string]$i.status
        if ($counts.ContainsKey($status)) { $counts[$status]++ } else { $counts[$status] = 1 }
        $p = [int]$i.priority
        $minutes = if ($EstimateMinutes.ContainsKey($p)) { $EstimateMinutes[$p] } else { 30 }
        if ($status -eq 'closed') { $estClosed += $minutes } else { $estOpen += $minutes }
    }

    $trunk = if ($Primary.trunk) { $Primary.trunk } else { 'dev' }
    $sha = (& git -C $path rev-parse --short $trunk 2>$null | Select-Object -First 1)
    if ([string]::IsNullOrWhiteSpace($sha)) { $sha = 'unknown' }

    $worktrees = 0
    $wtPath = Join-Path $path '.worktrees'
    if (Test-Path -LiteralPath $wtPath) { $worktrees = @(Get-ChildItem -LiteralPath $wtPath -Directory -Force -ErrorAction SilentlyContinue).Count }

    return [pscustomobject]@{
        Name        = $Primary.name
        Available   = $true
        Reason      = $null
        Open        = $counts['open']
        Blocked     = $counts['blocked']
        InProgress  = $counts['in_progress']
        Closed      = $counts['closed']
        EstOpen     = $estOpen
        EstClosed   = $estClosed
        Trunk       = $sha
        Worktrees   = $worktrees
        Signature   = "$($counts['open'])|$($counts['blocked'])|$($counts['in_progress'])|$($counts['closed'])|$sha"
    }
}

function Get-IntervalMinutes {
    param([TimeSpan]$ActivityAgeHours)
    if ($ActivityAgeHours.TotalHours -le 1) { return 15 }
    if ($ActivityAgeHours.TotalHours -le 6) { return 60 }
    if ($ActivityAgeHours.TotalHours -le 24) { return 360 }
    return 720
}

function Write-CompactJson {
    param([pscustomobject]$Object, [string]$Path)
    $line = ($Object | ConvertTo-Json -Compress -Depth 4)
    Add-Content -LiteralPath $Path -Value $line -Encoding UTF8
}

function Invoke-Snapshot {
    $stateRoot = Get-StateRoot
    $monitorDir = Join-Path $stateRoot 'monitor'
    New-Item -ItemType Directory -Force -Path $monitorDir | Out-Null

    $primary = Get-PrimaryRepos
    $primary = Select-PrimaryRepos -Primary $primary -Names $Repo

    $wk = Get-LastWeeklyPercent
    $now = Get-Date
    $written = @()

    foreach ($p in $primary) {
        $latestPath = Join-Path $monitorDir "$($p.name).latest.json"
        $historyPath = Join-Path $monitorDir "$($p.name).jsonl"

        $latest = $null
        if (Test-Path -LiteralPath $latestPath) {
            try { $latest = Get-Content -LiteralPath $latestPath -Raw | ConvertFrom-Json } catch { $latest = $null }
        }

        try {
            $state = Get-RepoState -Primary $p
        }
        catch {
            Write-Warning "$($p.name): $($_.Exception.Message)"
            continue
        }
        if (-not $state.Available) {
            Write-Warning "$($p.name): $($state.Reason)"
            continue
        }

        $changed = (-not $latest) -or ($latest.signature -ne $state.Signature)
        $lastChangeTs = if ($changed -or -not $latest.lastChangeTs) { $now } else { [datetime]$latest.lastChangeTs }
        $lastWriteTs = if ($latest.lastWriteTs) { [datetime]$latest.lastWriteTs } else { [datetime]::MinValue }

        $activityAge = $now - $lastChangeTs
        $interval = Get-IntervalMinutes -ActivityAgeHours $activityAge
        $dueByTime = ($now - $lastWriteTs).TotalMinutes -ge $interval

        if (-not ($changed -or $dueByTime)) {
            if (-not $Json) { Write-Verbose "$($p.name): skipped (unchanged, next write in $([math]::Round($interval - ($now - $lastWriteTs).TotalMinutes)) min)" }
            continue
        }

        $record = [pscustomobject]@{
            ts         = $now.ToString('yyyy-MM-ddTHH:mm')
            repo       = $p.name
            open       = $state.Open
            blocked    = $state.Blocked
            inprog     = $state.InProgress
            closed     = $state.Closed
            estOpen    = $state.EstOpen
            estClosed  = $state.EstClosed
            basis      = $EstimateBasis
            trunk      = $state.Trunk
            wt         = $state.Worktrees
            wk         = $wk
            interval   = $interval
            changed    = [bool]$changed
        }
        Write-CompactJson -Object $record -Path $historyPath
        $written += $record

        [pscustomobject]@{
            version      = 1
            signature    = $state.Signature
            lastChangeTs = $lastChangeTs.ToString('o')
            lastWriteTs  = $now.ToString('o')
            interval     = $interval
            last         = $record
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $latestPath -Encoding UTF8
    }

    if ($Json) { $written | ConvertTo-Json -Depth 4 } else { "snapshots_written=$(@($written).Count)" }
}

function Get-History {
    param([string]$Name, [string]$MonitorDir)
    $p = Join-Path $MonitorDir "$Name.jsonl"
    if (-not (Test-Path -LiteralPath $p)) { return @() }
    @(Get-Content -LiteralPath $p | Where-Object { $_ } | ForEach-Object { try { $_ | ConvertFrom-Json } catch {} })
}

function Invoke-Check {
    $stateRoot = Get-StateRoot
    $monitorDir = Join-Path $stateRoot 'monitor'
    if (-not (Test-Path -LiteralPath $monitorDir)) { throw "no monitor history at $monitorDir; run -Mode Snapshot first" }

    $primary = Get-PrimaryRepos
    $primary = Select-PrimaryRepos -Primary $primary -Names $Repo

    $now = Get-Date
    $findings = @()

    foreach ($p in $primary) {
        $history = Get-History -Name $p.name -MonitorDir $monitorDir
        if ($history.Count -eq 0) { continue }
        $last = $history[-1]

        # last time the graph actually moved
        $lastChange = $history | Where-Object { $_.changed } | Select-Object -Last 1
        if (-not $lastChange) { $lastChange = $history[0] }
        $idleHours = ($now - [datetime]$lastChange.ts).TotalHours

        $unfinished = [int]$last.open + [int]$last.blocked
        if ($unfinished -gt 0 -and $idleHours -ge 6) {
            $findings += [pscustomobject]@{
                code     = 'STALL-GRAPH'
                repo     = $p.name
                detail   = "$unfinished unfinished bead(s), graph unchanged for $([math]::Round($idleHours,1)) h"
                evidence = @{ open = $last.open; blocked = $last.blocked; idleHours = [math]::Round($idleHours, 1) }
            }
        }
        if ([int]$last.wt -gt 0 -and $idleHours -ge 2) {
            $findings += [pscustomobject]@{
                code     = 'STALL-MERGE'
                repo     = $p.name
                detail   = "$($last.wt) lane worktree(s) present, trunk $($last.trunk) unchanged for $([math]::Round($idleHours,1)) h"
                evidence = @{ worktrees = $last.wt; trunk = $last.trunk; idleHours = [math]::Round($idleHours, 1) }
            }
        }
    }

    $findingsPath = Join-Path $monitorDir 'findings.json'

    # Wake attempts are recorded BESIDE the findings, never instead of them: the
    # file is the truth whether or not a message got through, and a failed wake is
    # itself a finding a reader can act on.
    $wakeResults = @()
    if ($Wake -and $findings.Count -gt 0) {
        $repoNames = @($findings | ForEach-Object { $_.repo } | Sort-Object -Unique)
        foreach ($repoName in $repoNames) {
            $repoFindings = @($findings | Where-Object { $_.repo -eq $repoName })
            $wakeResults += Send-MonitorWake -Repo $repoName -Findings $repoFindings -MonitorDir $monitorDir -DryRun:$WakeDryRun
        }
        foreach ($result in $wakeResults) {
            if ($result.code -ne 'WAKE-SENT' -and $result.code -ne 'WAKE-DRY-RUN') {
                $findings += [pscustomobject]@{
                    code     = $result.code
                    repo     = $result.repo
                    detail   = $result.detail
                    evidence = @{ agentId = $result.agentId }
                }
            }
        }
    }

    @{ ts = $now.ToString('o'); count = $findings.Count; findings = $findings; wake = @($wakeResults) } |
        ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $findingsPath -Encoding UTF8

    if ($Json) { $findings | ConvertTo-Json -Depth 5 }
    else {
        if ($findings.Count -eq 0) { "NO FINDINGS" }
        else { $findings | ForEach-Object { "$($_.code) $($_.repo): $($_.detail)" } }
        foreach ($result in $wakeResults) { "wake $($result.repo): $($result.code) - $($result.detail)" }
    }
    if ($findings.Count -gt 0) { exit 1 }
}

function Invoke-Report {
    $stateRoot = Get-StateRoot
    $monitorDir = Join-Path $stateRoot 'monitor'
    $primary = Get-PrimaryRepos
    $primary = Select-PrimaryRepos -Primary $primary -Names $Repo

    $now = Get-Date
    $since = $now.AddHours(-$ReportHours)
    $rows = @()

    foreach ($p in $primary) {
        $history = Get-History -Name $p.name -MonitorDir $monitorDir
        $window = @($history | Where-Object { [datetime]$_.ts -ge $since })
        if ($window.Count -lt 2) {
            $rows += [pscustomobject]@{ repo = $p.name; state = 'insufficient-history'; snapshots = $window.Count }
            continue
        }
        $first = $window[0]; $last = $window[-1]
        $elapsedHours = (([datetime]$last.ts) - ([datetime]$first.ts)).TotalHours
        if ($elapsedHours -le 0) { continue }

        $closedDelta = [int]$last.closed - [int]$first.closed
        $estClosedDelta = [int]$last.estClosed - [int]$first.estClosed
        $ratePerHour = [math]::Round($estClosedDelta / $elapsedHours, 1)
        $remaining = [int]$last.estOpen
        $etaHours = if ($ratePerHour -gt 0) { [math]::Round($remaining / $ratePerHour, 1) } else { $null }

        $burnPerHour = if ($null -ne $first.wk -and $null -ne $last.wk) {
            [math]::Round(([double]$last.wk - [double]$first.wk) / $elapsedHours, 2)
        } else { $null }

        $rows += [pscustomobject]@{
            repo           = $p.name
            snapshots      = $window.Count
            elapsedHours   = [math]::Round($elapsedHours, 1)
            closedDelta    = $closedDelta
            estClosedMin   = $estClosedDelta
            estRatePerHour = $ratePerHour
            estRemaining   = $remaining
            etaHours       = $etaHours
            wkPerHour      = $burnPerHour
            estMinPerWkPct = if ($burnPerHour -and $burnPerHour -gt 0) { [math]::Round($ratePerHour / $burnPerHour, 1) } else { $null }
            basis          = $EstimateBasis
        }
    }

    if ($Json) { $rows | ConvertTo-Json -Depth 4; return }
    $rows | Format-Table -AutoSize | Out-String -Width 160
    "estimate basis: $EstimateBasis (ASSUMED - bd does not expose estimates; counts and wk are measured)"
}

function Invoke-Rollup {
    param([int]$KeepDays)
    $stateRoot = Get-StateRoot
    $monitorDir = Join-Path $stateRoot 'monitor'
    $cutoff = (Get-Date).AddDays(-$KeepDays)
    $folded = 0
    foreach ($file in Get-ChildItem -LiteralPath $monitorDir -Filter '*.jsonl' -ErrorAction SilentlyContinue) {
        $lines = Get-Content -LiteralPath $file.FullName | Where-Object { $_ }
        $keep = @(); $old = @()
        foreach ($line in $lines) {
            try { $o = $line | ConvertFrom-Json } catch { continue }
            if ([datetime]$o.ts -ge $cutoff) { $keep += $line } else { $old += $o }
        }
        if ($old.Count -eq 0) { continue }
        $daily = $old | Group-Object { ([datetime]$_.ts).ToString('yyyy-MM-dd') } | ForEach-Object {
            $lastOfDay = $_.Group | Select-Object -Last 1
            [pscustomobject]@{
                ts = "$($_.Name)T23:59"; repo = $lastOfDay.repo; kind = 'daily-rollup'
                open = $lastOfDay.open; blocked = $lastOfDay.blocked; inprog = $lastOfDay.inprog
                closed = $lastOfDay.closed; estOpen = $lastOfDay.estOpen; estClosed = $lastOfDay.estClosed
                basis = $lastOfDay.basis; trunk = $lastOfDay.trunk; wt = $lastOfDay.wt; wk = $lastOfDay.wk
                samples = $_.Count
            } | ConvertTo-Json -Compress
        }
        Set-Content -LiteralPath $file.FullName -Value (@($daily) + $keep) -Encoding UTF8
        $folded += $old.Count
    }
    "rolled_up_lines=$folded (kept $KeepDays days raw)"
}

function Invoke-Status {
    $stateRoot = Get-StateRoot
    $monitorDir = Join-Path $stateRoot 'monitor'
    $primary = Select-PrimaryRepos -Primary (Get-PrimaryRepos) -Names $Repo
    $rows = @()

    # Enumerate the SELECTED repos, not whatever files happen to exist: listing the
    # directory made -Repo silently do nothing, so a typo'd or aliased name looked
    # exactly like a healthy repo.
    foreach ($p in $primary) {
        $file = Join-Path $monitorDir "$($p.name).latest.json"
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
            $rows += [pscustomobject]@{
                repo = $p.name; lastWrite = '(none)'; lastChange = '(none)'
                intervalMin = $null; open = $null; closed = $null; trunk = $p.trunk
            }
            continue
        }
        $l = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
        $rows += [pscustomobject]@{
            repo         = $l.last.repo
            lastWrite    = ([datetime]$l.lastWriteTs).ToString('MM-dd HH:mm')
            lastChange   = ([datetime]$l.lastChangeTs).ToString('MM-dd HH:mm')
            intervalMin  = $l.interval
            open         = $l.last.open
            closed       = $l.last.closed
            trunk        = $l.last.trunk
        }
    }
    if ($Json) { $rows | ConvertTo-Json -Depth 4 } else { $rows | Format-Table -AutoSize | Out-String -Width 120 }
}

switch ($Mode) {
    'Snapshot' { Invoke-Snapshot }
    'Check' { Invoke-Check }
    'Report' { Invoke-Report }
    'Rollup' { Invoke-Rollup -KeepDays $RetainDays }
    'Status' { Invoke-Status }
}
