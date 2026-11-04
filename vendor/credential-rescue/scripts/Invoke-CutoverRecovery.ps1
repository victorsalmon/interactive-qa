#Requires -Version 7.0
<#
.SYNOPSIS
    Reconcile the machine after a key cutover: stand down a backstop, restore
    the original Hub's role, release the leases the cutover killed, stamp the
    gates it interrupted, and write the report that makes all of it auditable.

.DESCRIPTION
    A cutover closes agents twice (the switch's helper, then the restart), kills
    the persistent shells their worktree leases name, and can lose a Hub's
    registry row. Recovery has to put the role back in the SAME hands - not let
    a scheduled backstop inherit it.

    The 2026-11-02 UH incident (runId 20261102-172700) is the shape:

      - 56 minutes after the cutover, a scheduled backstop registered a Hub row
        and ACQUIRED the worktree lease;
      - the recovery phase resumed the Hub WITHOUT reconciling the backstop;
      - one Hub could not resume ("active run cancellation was not
        acknowledged") and was silently omitted;
      - result: two live Hubs, the lease in the wrong hands, and gate
        batteries killed mid-run that looked like red gates.

    So this pass, keyed by runId:

      1. detects any agent that registered a Hub row or acquired a lease INSIDE
         the cutover window, sends it a stand-down naming the runId and the
         original Hub, and records it;
      2. never seizes a live lease on its own - a stand-down is a request, and
         the run is done only when the lease is released. `-ForceRevoke` is the
         explicit operator override, and it logs owner + generation;
      3. releases leases whose recorded pid is DEAD and whose checkout was in
         the window, with `reason: cutover`, preserving owner and generation.
         A live holder is never touched;
      4. re-registers the original Hub itself (safe: an upsert of its own row)
         and records that the lease must be re-acquired from a fresh persistent
         shell, because the pid the old lease names is dead;
      5. stamps gate runs modified inside the kill window via
         `Stamp-InterruptedGates.ps1`;
      6. writes `cutover-report-<runId>.json` and `.md`: every agent closed,
         resumed, unresumed (with reason), every worktree with uncommitted work
         or a missing report/done file, and every unhandled gap.

    Idempotence is by runId: a second run for the same id is a no-op (one
    report, one stand-down set), and a stand-down is deduped per
    repo+runId+agent even under -Force.

.PARAMETER RunId
    The cutover run to reconcile. Required.

.PARAMETER RosterPath
    The roster the cutover captured. Default `<StateDir>/<runId>-roster.json`.

.PARAMETER OriginalHubId
    The Hub that owned the role before the cutover. Default: the first `isHub`
    entry in the roster.

.PARAMETER ForceRevoke
    Operator override: release a LEASE held by another (live) agent when it was
    acquired inside the window. Logged with owner and generation.

.PARAMETER Force
    Re-run even when a report for this runId already exists.

.OUTPUTS
    Exit 0 reconciled (or already reconciled); 1 the roster could not be read
    and there is nothing to report.

.EXAMPLE
    pwsh -File Invoke-CutoverRecovery.ps1 -RunId 20261102-172700
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$RunId,
    [string]$StateDir = '',
    [string]$RosterPath = '',
    [string]$KillWindowPath = '',
    [string]$MarkerPath = '',
    [string]$WindowStart = '',
    [string]$WindowEnd = '',
    [string]$HubRegistryRoot = '',
    [string]$LeaseRoot = '',
    [string]$HubRegistryScript = '',
    [string]$StampScript = '',
    [string]$SendScript = '',
    [string]$AuditPath = '',
    [string]$OriginalHubId = '',
    [string]$ReportPath = '',
    [switch]$ForceRevoke,
    [switch]$Force,
    [switch]$NoStandDown,
    [switch]$NoRelease,
    [switch]$NoRegister,
    [switch]$NoStamp,
    [switch]$NoReport,
    [datetime]$Now = (Get-Date),
    [switch]$Json
)

$ErrorActionPreference = 'Stop'

$scriptRoot = $PSScriptRoot
. (Join-Path $scriptRoot 'lib\CutoverRecovery.ps1')

$StateDir = Get-CutoverStateDir -Override $StateDir
if ([string]::IsNullOrWhiteSpace($RosterPath)) { $RosterPath = Join-Path $StateDir "$RunId-roster.json" }
if ([string]::IsNullOrWhiteSpace($AuditPath)) { $AuditPath = Join-Path $env:USERPROFILE '.salmon\Tasks\Logs\keycheck.jsonl' }
if ([string]::IsNullOrWhiteSpace($HubRegistryRoot)) { $HubRegistryRoot = Get-CutoverDefaultHubRoot }
if ([string]::IsNullOrWhiteSpace($LeaseRoot)) { $LeaseRoot = Get-CutoverDefaultLeaseRoot }
if ([string]::IsNullOrWhiteSpace($HubRegistryScript)) {
    $HubRegistryScript = Join-Path $scriptRoot '..\..\iqa-merge\HubRegistry.ps1'
}
$HubRegistryScript = [System.IO.Path]::GetFullPath($HubRegistryScript)
if ([string]::IsNullOrWhiteSpace($StampScript)) { $StampScript = Join-Path $scriptRoot 'Stamp-InterruptedGates.ps1' }
if ([string]::IsNullOrWhiteSpace($ReportPath)) { $ReportPath = Join-Path $StateDir "cutover-report-$RunId.json" }
if ([string]::IsNullOrWhiteSpace($MarkerPath)) { $MarkerPath = Get-CutoverMarkerPath -StateDir $StateDir }
if ([string]::IsNullOrWhiteSpace($KillWindowPath)) { $KillWindowPath = Get-CutoverKillWindowPath -StateDir $StateDir }

function Write-RecoveryAudit {
    param($Entry)
    Write-CutoverAuditLine -Path $AuditPath -Entry $Entry
}

# --- idempotence: one recovery per runId ------------------------------------
$existing = Read-CutoverJsonFile -Path $ReportPath
if (-not $Force -and $null -ne $existing -and
    $existing.PSObject.Properties['runId'] -and [string]$existing.runId -eq $RunId) {
    $line = "cutover-recovery: already-recovered runId=$RunId report=$ReportPath"
    if ($Json) { [ordered]@{ runId = $RunId; status = 'already-recovered'; reportPath = $ReportPath } | ConvertTo-Json -Compress }
    else { Write-Output $line }
    exit 0
}

# --- the window -------------------------------------------------------------
$window = if ($WindowStart) {
    $s = [datetime]::Parse($WindowStart, [Globalization.CultureInfo]::InvariantCulture)
    $e = if ($WindowEnd) { [datetime]::Parse($WindowEnd, [Globalization.CultureInfo]::InvariantCulture) } else { $Now }
    [pscustomobject]@{ RunId = $RunId; StartedAt = $s; EndedAt = $e; Source = 'explicit'; HasKillWindow = [bool]$WindowStart }
} else {
    Get-CutoverWindowInfo -StateDir $StateDir -RunId $RunId -RosterPath $RosterPath `
        -KillWindowPath $KillWindowPath -MarkerPath $MarkerPath -Now $Now
}

# --- the roster -------------------------------------------------------------
$roster = Read-CutoverJsonFile -Path $RosterPath
$rosterAgents = @()
if ($null -ne $roster -and $roster.PSObject.Properties['agents']) { $rosterAgents = @($roster.agents) }
if ($null -eq $roster) {
    Write-RecoveryAudit -Entry ([ordered]@{
            ts = (Get-Date).ToString('s'); runId = $RunId; kind = 'cutover-recovery-failed'
            reason = "roster unreadable or missing: $RosterPath"; at = (Get-Date).ToString('o')
        })
    if (-not $Json) { [Console]::Error.WriteLine("cutover-recovery: roster unreadable or missing at $RosterPath") }
    else { [ordered]@{ runId = $RunId; status = 'roster-missing'; rosterPath = $RosterPath } | ConvertTo-Json -Compress }
    exit 1
}

if (-not $OriginalHubId) {
    $hub = @($rosterAgents | Where-Object { $null -ne $_ -and [bool]$_.isHub })[0]
    if ($null -ne $hub) { $OriginalHubId = [string]$hub.id }
}

$priorAudit = @(Get-CutoverAuditRows -Path $AuditPath)
$standDowns = @()
$released = @()
$revoked = @()
$register = $null
$stamped = @()

# --- 1+2. reconcile a backstop that took the role ---------------------------
if (-not $NoStandDown) {
    $candidates = @()

    # Hub registry rows registered inside the window (a backstop registering).
    if (Test-Path -LiteralPath $HubRegistryRoot) {
        foreach ($file in @(Get-ChildItem -LiteralPath $HubRegistryRoot -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
            $record = Read-CutoverJsonFile -Path $file.FullName
            if ($null -eq $record -or -not $record.PSObject.Properties['hubs']) { continue }
            $repo = $file.BaseName
            foreach ($entry in @($record.hubs)) {
                if ($null -eq $entry) { continue }
                $agentId = if ($entry.PSObject.Properties['agentId']) { [string]$entry.agentId } else { '' }
                if ([string]::IsNullOrWhiteSpace($agentId)) { continue }
                if ($OriginalHubId -and $agentId -eq $OriginalHubId) { continue }
                $stamp = ''
                if ($entry.PSObject.Properties['registeredAt']) { $stamp = [string]$entry.registeredAt }
                if (-not $stamp -and $entry.PSObject.Properties['heartbeatAt']) { $stamp = [string]$entry.heartbeatAt }
                if (-not (Test-CutoverInWindow -Stamp $stamp -Window $window)) { continue }
                $candidates += [ordered]@{ kind = 'registry'; repo = $repo; agentId = $agentId; path = $file.FullName; org = $entry }
            }
        }
    }

    # Leases acquired inside the window (a backstop taking the checkout).
    $leaseRecords = @()
    if (Test-Path -LiteralPath $LeaseRoot) {
        $leaseRecords = @(Get-ChildItem -LiteralPath $LeaseRoot -Filter '*.json' -File -ErrorAction SilentlyContinue)
    }
    foreach ($file in $leaseRecords) {
        $lease = Read-CutoverJsonFile -Path $file.FullName
        if ($null -eq $lease) { continue }
        $owner = if ($lease.PSObject.Properties['owner']) { [string]$lease.owner } else { '' }
        if ([string]::IsNullOrWhiteSpace($owner)) { continue }
        if ($OriginalHubId -and $owner -eq $OriginalHubId) { continue }
        $stamp = if ($lease.PSObject.Properties['acquiredAt']) { [string]$lease.acquiredAt } else { '' }
        if (-not (Test-CutoverInWindow -Stamp $stamp -Window $window)) { continue }
        $repo = if ($lease.PSObject.Properties['repoRoot'] -and -not [string]::IsNullOrWhiteSpace([string]$lease.repoRoot)) {
            (Get-CutoverRepoIdentity -Path ([string]$lease.repoRoot)).Name
        } elseif ($lease.PSObject.Properties['path']) {
            (Get-CutoverRepoIdentity -Path ([string]$lease.path)).Name
        } else { '' }
        $candidates += [ordered]@{ kind = 'lease'; repo = $repo; agentId = $owner; path = $file.FullName; org = $lease }
    }

    # Dedupe by repo+agentId, and against stand-downs already recorded.
    $seen = @{}
    foreach ($candidate in $candidates) {
        $key = ('{0}|{1}' -f $candidate.repo, $candidate.agentId).ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $already = @($priorAudit | Where-Object {
                $null -ne $_ -and $_.PSObject.Properties['kind'] -and $_.kind -eq 'cutover-standdown' -and
                $_.PSObject.Properties['runId'] -and [string]$_.runId -eq $RunId -and
                $_.PSObject.Properties['repo'] -and ([string]$_.repo).ToLowerInvariant() -eq ([string]$candidate.repo).ToLowerInvariant() -and
                $_.PSObject.Properties['agentId'] -and [string]$_.agentId -eq $candidate.agentId
            })
        if ($already.Count -gt 0) {
            $standDowns += [ordered]@{ repo = $candidate.repo; agentId = $candidate.agentId; kind = $candidate.kind; sent = $false; reason = 'already-recorded' }
            continue
        }

        $message = ("Stand down - the key cutover {0} is complete and the original Hub for {1} is {2}. " + `
                "You registered or leased this role INSIDE the cutover window ({3}), so you are a backstop, not the owner. " + `
                "Release any worktree lease you hold, do not merge or land work, and report to {2} for reassignment.") -f `
            $RunId, $(if ($candidate.repo) { $candidate.repo } else { 'this repo' }), `
            $(if ($OriginalHubId) { $OriginalHubId } else { 'unresolved' }), $window.Source

        $sent = $false
        $detail = ''
        if ($SendScript) {
            $stamp = [guid]::NewGuid().ToString('N')
            $messageFile = Join-Path ([System.IO.Path]::GetTempPath()) "cutover-standdown-$stamp.txt"
            try {
                Set-Content -LiteralPath $messageFile -Value $message -Encoding utf8NoBOM -NoNewline
                $out = & (Join-Path $PSHOME 'pwsh.exe') -NoProfile -File $SendScript `
                    -AgentId $candidate.agentId -Variant 'standdown' -MessageFile $messageFile 2>&1 | Out-String
                $sent = ($LASTEXITCODE -eq 0)
                if (-not $sent) { $detail = ([string]$out).Trim() }
            } catch {
                $detail = $_.Exception.Message
            } finally {
                Remove-Item -LiteralPath $messageFile -Force -ErrorAction SilentlyContinue
            }
        }

        Write-RecoveryAudit -Entry ([ordered]@{
                ts = (Get-Date).ToString('s'); runId = $RunId; kind = 'cutover-standdown'
                repo = $candidate.repo; agentId = $candidate.agentId; via = $candidate.kind
                originalHub = $OriginalHubId; sent = $sent; acknowledged = $false
                reason = $(if ($sent) { 'stand-down sent' } else { "send unavailable or failed: $detail" })
                at = (Get-Date).ToString('o')
            })
        $standDowns += [ordered]@{
            repo = $candidate.repo; agentId = $candidate.agentId; kind = $candidate.kind
            sent = $sent; reason = $(if ($sent) { 'stand-down sent' } else { "send unavailable or failed: $detail" })
        }
    }
}

# --- 4 (and -ForceRevoke). leases the cutover killed, or that must be freed --
$leaseFiles = @()
if (Test-Path -LiteralPath $LeaseRoot) {
    $leaseFiles = @(Get-ChildItem -LiteralPath $LeaseRoot -Filter '*.json' -File -ErrorAction SilentlyContinue)
}
foreach ($file in $leaseFiles) {
    $lease = Read-CutoverJsonFile -Path $file.FullName
    if ($null -eq $lease) { continue }
    $owner = if ($lease.PSObject.Properties['owner']) { [string]$lease.owner } else { '' }
    $generation = if ($lease.PSObject.Properties['generation']) { [int]$lease.generation } else { 0 }
    $leasePid = if ($lease.PSObject.Properties['pid']) { [int]$lease.pid } else { 0 }
    $leaseHost = if ($lease.PSObject.Properties['host']) { [string]$lease.host } else { '' }
    $leasePath = if ($lease.PSObject.Properties['path']) { [string]$lease.path } else { '' }
    $stamp = if ($lease.PSObject.Properties['acquiredAt']) { [string]$lease.acquiredAt } else { '' }
    $inWindow = Test-CutoverInWindow -Stamp $stamp -Window $window

    $record = [ordered]@{
        owner = $owner; generation = $generation; pid = $leasePid
        path = $leasePath; leasePath = $file.FullName
    }

    # Explicit operator override: release another live agent's in-window lease.
    if ($ForceRevoke -and $inWindow) {
        Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
        Write-RecoveryAudit -Entry ([ordered]@{
                ts = (Get-Date).ToString('s'); runId = $RunId; kind = 'cutover-lease-revoked'
                owner = $owner; generation = $generation; pid = $leasePid; path = $leasePath
                reason = 'force-revoke'; at = (Get-Date).ToString('o')
            })
        $revoked += $record
        continue
    }

    if ($NoRelease) { continue }
    # Never touch a lease whose holder is alive - in this window or any other.
    if (-not $inWindow) { continue }
    if ($leaseHost -and -not [string]::Equals($leaseHost, $env:COMPUTERNAME, [StringComparison]::OrdinalIgnoreCase)) { continue }
    if (Test-CutoverProcessAlive -ProcessId $leasePid) { continue }

    # Preserve the identity before removing the file: the release record is the
    # only surviving statement of who held it and at which generation.
    Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
    Write-RecoveryAudit -Entry ([ordered]@{
            ts = (Get-Date).ToString('s'); runId = $RunId; kind = 'cutover-lease-released'
            owner = $owner; generation = $generation; pid = $leasePid; path = $leasePath
            reason = 'cutover'; at = (Get-Date).ToString('o')
        })
    $released += $record
}

# --- 3. put the role back in the same hands ---------------------------------
if (-not $NoRegister -and $OriginalHubId) {
    $hubAgent = @($rosterAgents | Where-Object { $null -ne $_ -and [string]$_.id -eq $OriginalHubId })[0]
    $hubCwd = if ($null -ne $hubAgent -and $hubAgent.PSObject.Properties['cwd']) { [string]$hubAgent.cwd } else { '' }
    if (-not $hubCwd -or -not (Test-Path -LiteralPath $hubCwd)) {
        $register = [ordered]@{ ok = $false; agentId = $OriginalHubId; repo = ''; note = "the Hub cwd is gone ($hubCwd); the resumed Hub must re-register and re-lease from a fresh persistent shell" }
        Write-RecoveryAudit -Entry ([ordered]@{
                ts = (Get-Date).ToString('s'); runId = $RunId; kind = 'cutover-role-register'
                ok = $false; agentId = $OriginalHubId; repo = ''; reason = $register.note; at = (Get-Date).ToString('o')
            })
    } elseif (-not (Test-Path -LiteralPath $HubRegistryScript)) {
        $register = [ordered]@{ ok = $false; agentId = $OriginalHubId; repo = ''; note = "HubRegistry.ps1 not found at $HubRegistryScript" }
        Write-RecoveryAudit -Entry ([ordered]@{
                ts = (Get-Date).ToString('s'); runId = $RunId; kind = 'cutover-role-register'
                ok = $false; agentId = $OriginalHubId; repo = ''; reason = $register.note; at = (Get-Date).ToString('o')
            })
    } else {
        $repo = (Get-CutoverRepoIdentity -Path $hubCwd).Name
        $note = 'the worktree lease must be re-acquired by the resumed agent from a fresh persistent shell: the pid the old lease records is dead'
        $raw = ''
        $code = -1
        try {
            $raw = & (Join-Path $PSHOME 'pwsh.exe') -NoProfile -File $HubRegistryScript `
                -Mode Register -Repo $repo -RepoPath $hubCwd -AgentId $OriginalHubId -Trunk dev `
                -Root $HubRegistryRoot -Json 2>&1 | Out-String
            $code = $LASTEXITCODE
        } catch {
            $raw = $_.Exception.Message
            $code = -1
        }
        $register = [ordered]@{
            ok = ($code -eq 0); agentId = $OriginalHubId; repo = $repo
            reason = $(if ($code -eq 0) { 'registered' } else { "hub-register exit $code`: $(([string]$raw).Trim())" })
            note = $note
        }
        Write-RecoveryAudit -Entry ([ordered]@{
                ts = (Get-Date).ToString('s'); runId = $RunId; kind = 'cutover-role-register'
                ok = $register.ok; agentId = $OriginalHubId; repo = $repo
                reason = $register.reason; note = $note; at = (Get-Date).ToString('o')
            })
    }
}

# --- 5. stamp the gates the cutover killed ----------------------------------
if (-not $NoStamp -and $null -ne $window.StartedAt) {
    $repoRoots = @{}
    foreach ($agent in $rosterAgents) {
        if ($null -eq $agent -or -not $agent.PSObject.Properties['cwd']) { continue }
        $cwd = [string]$agent.cwd
        if ([string]::IsNullOrWhiteSpace($cwd) -or -not (Test-Path -LiteralPath $cwd)) { continue }
        $identity = Get-CutoverRepoIdentity -Path $cwd
        if ($identity.MainRoot) { $repoRoots[$identity.MainRoot] = $true }
    }
    foreach ($root in @($repoRoots.Keys)) {
        if (-not (Test-Path -LiteralPath (Join-Path $root '.gate-runs'))) { continue }
        try {
            $out = & (Join-Path $PSHOME 'pwsh.exe') -NoProfile -File $StampScript `
                -Root $root -RunId $RunId `
                -WindowStart ([datetime]$window.StartedAt).ToString('o') `
                -WindowEnd ([datetime]$window.EndedAt).ToString('o') `
                -Json 2>&1 | Out-String
            $parsed = $null
            try { $parsed = $out | ConvertFrom-Json } catch { }
            if ($null -ne $parsed -and $parsed.PSObject.Properties['stamped']) {
                foreach ($hit in @($parsed.stamped)) { $stamped += $hit }
            }
        } catch { }
    }
    if (@($stamped).Count -gt 0) {
        Write-RecoveryAudit -Entry ([ordered]@{
                ts = (Get-Date).ToString('s'); runId = $RunId; kind = 'cutover-gates-stamped'
                count = @($stamped).Count; at = (Get-Date).ToString('o')
            })
    }
}

# --- 6. the report ----------------------------------------------------------
$report = [ordered]@{
    version     = 1
    runId       = $RunId
    generatedAt = (Get-Date).ToString('o')
    window      = [ordered]@{
        startedAt = $(if ($null -ne $window.StartedAt) { ([datetime]$window.StartedAt).ToString('o') } else { '' })
        endedAt   = $(if ($null -ne $window.EndedAt) { ([datetime]$window.EndedAt).ToString('o') } else { '' })
        source    = $window.Source
    }
    originalHubId = $OriginalHubId
    closed        = @()
    resumed       = @()
    unresumed     = @()
    worktrees     = @()
    standdowns    = @($standDowns)
    leases        = @($released)
    leaseRecords  = [ordered]@{ released = @($released); revoked = @($revoked) }
    gates         = [ordered]@{ stamped = @($stamped) }
    roleRegister  = $register
    unhandled     = @()
}

$resumeRows = @($priorAudit | Where-Object {
        $null -ne $_ -and $_.PSObject.Properties['kind'] -and $_.kind -eq 'roster-resume' -and
        $_.PSObject.Properties['runId'] -and [string]$_.runId -eq $RunId
    })
$failedRows = @($priorAudit | Where-Object {
        $null -ne $_ -and $_.PSObject.Properties['kind'] -and $_.kind -eq 'roster-resume-failed' -and
        $_.PSObject.Properties['runId'] -and [string]$_.runId -eq $RunId
    })

$seenWorktrees = @{}
foreach ($agent in $rosterAgents) {
    if ($null -eq $agent) { continue }
    $agentId = if ($agent.PSObject.Properties['id']) { [string]$agent.id } else { '' }
    if ([string]::IsNullOrWhiteSpace($agentId)) { continue }
    $title = if ($agent.PSObject.Properties['title']) { [string]$agent.title } else { '' }
    $cwd = if ($agent.PSObject.Properties['cwd']) { [string]$agent.cwd } else { '' }
    $facts = Get-CutoverGitFacts -Path $cwd

    $report.closed += [ordered]@{
        id     = $agentId
        title  = $title
        repo   = $facts.repo
        cwd    = $cwd
        branch = $facts.branch
        head   = $facts.head
    }

    $row = @($resumeRows | Where-Object { $_.PSObject.Properties['agentId'] -and [string]$_.agentId -eq $agentId })
    if ($row.Count -gt 0) {
        $last = $row[-1]
        $decision = if ($last.PSObject.Properties['decision']) { [string]$last.decision } else { '' }
        $reason = if ($last.PSObject.Properties['reason']) { [string]$last.reason } else { '' }
        if ($decision -eq 'resumed') {
            $report.resumed += [ordered]@{ id = $agentId; title = $title; repo = $facts.repo; decision = $decision }
        } else {
            $report.unresumed += [ordered]@{ id = $agentId; title = $title; repo = $facts.repo; decision = $decision; reason = $reason }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($cwd) -and -not $seenWorktrees.ContainsKey($cwd.ToLowerInvariant())) {
        $seenWorktrees[$cwd.ToLowerInvariant()] = $true
        $report.worktrees += [ordered]@{
            path          = $cwd
            repo          = $facts.repo
            branch        = $facts.branch
            head          = $facts.head
            uncommitted   = [bool]$facts.uncommitted
            missingReport = (-not (Test-Path -LiteralPath (Join-Path $cwd '.iqa-report.md')))
            missingDone   = (@(Get-ChildItem -LiteralPath $cwd -Filter '.iqa-done-*.json' -File -ErrorAction SilentlyContinue).Count -eq 0)
        }
    }
}

foreach ($row in $failedRows) {
    $report.unhandled += [ordered]@{
        agentId = if ($row.PSObject.Properties['agentId']) { [string]$row.agentId } else { '' }
        reason  = if ($row.PSObject.Properties['reason']) { [string]$row.reason } else { '' }
        at      = if ($row.PSObject.Properties['at']) { [string]$row.at } else { '' }
    }
}

if (-not $NoReport) {
    $dir = Split-Path -Parent $ReportPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
    Set-Content -LiteralPath $ReportPath -Value ($report | ConvertTo-Json -Depth 12) -Encoding utf8NoBOM
    $mdPath = [System.IO.Path]::ChangeExtension($ReportPath, '.md')
    $md = [System.Collections.Generic.List[string]]::new()
    $md.Add("# Cutover report - $RunId")
    $md.Add('')
    $md.Add(("- Window: {0} -> {1} ({2})" -f $report.window.startedAt, $report.window.endedAt, $report.window.source))
    $md.Add(("- Original Hub: {0}" -f $(if ($OriginalHubId) { $OriginalHubId } else { 'unresolved' })))
    $md.Add(("- Closed by the cutover: {0}; resumed: {1}; unresumed: {2}; unhandled: {3}" -f `
                @($report.closed).Count, @($report.resumed).Count, @($report.unresumed).Count, @($report.unhandled).Count))
    $md.Add('')
    $md.Add('## Closed')
    foreach ($a in @($report.closed)) { $md.Add(("- {0} `"{1}`" repo={2} cwd={3} branch={4} head={5}" -f $a.id, $a.title, $a.repo, $a.cwd, $a.branch, $a.head)) }
    $md.Add('')
    $md.Add('## Resumed')
    if (@($report.resumed).Count -eq 0) { $md.Add('- none') }
    foreach ($a in @($report.resumed)) { $md.Add(("- {0} `"{1}`" repo={2}" -f $a.id, $a.title, $a.repo)) }
    $md.Add('')
    $md.Add('## Unresumed')
    if (@($report.unresumed).Count -eq 0) { $md.Add('- none') }
    foreach ($a in @($report.unresumed)) { $md.Add(("- {0} `"{1}`" decision={2} reason={3}" -f $a.id, $a.title, $a.decision, $a.reason)) }
    $md.Add('')
    $md.Add('## Worktrees')
    if (@($report.worktrees).Count -eq 0) { $md.Add('- none') }
    foreach ($w in @($report.worktrees)) {
        $flags = @()
        if ($w.uncommitted) { $flags += 'UNCOMMITTED' }
        if ($w.missingReport) { $flags += 'no-report' }
        if ($w.missingDone) { $flags += 'no-done-file' }
        $md.Add(("- {0} branch={1} head={2} {3}" -f $w.path, $w.branch, $w.head, $(if ($flags.Count -gt 0) { $flags -join ' ' } else { 'clean' })))
    }
    $md.Add('')
    $md.Add('## Leases')
    foreach ($l in @($released)) { $md.Add(("- released {0} (owner={1}, generation={2}, reason=cutover)" -f $l.path, $l.owner, $l.generation)) }
    foreach ($l in @($revoked)) { $md.Add(("- revoked {0} (owner={1}, generation={2}, reason=force-revoke)" -f $l.path, $l.owner, $l.generation)) }
    if (@($released).Count -eq 0 -and @($revoked).Count -eq 0) { $md.Add('- none') }
    $md.Add('')
    $md.Add('## Stand-downs')
    if (@($standDowns).Count -eq 0) { $md.Add('- none') }
    foreach ($s in @($standDowns)) { $md.Add(("- {0} repo={1} via={2} sent={3} {4}" -f $s.agentId, $s.repo, $s.kind, $s.sent, $s.reason)) }
    if ($null -ne $register) {
        $md.Add('')
        $md.Add('## Role register')
        $md.Add(("- ok={0} repo={1} agent={2}: {3}" -f $register.ok, $register.repo, $register.agentId, $register.reason))
        if ($register.PSObject.Properties['note'] -and $register.note) { $md.Add("- $($register.note)") }
    }
    if (@($report.unhandled).Count -gt 0) {
        $md.Add('')
        $md.Add('## Unhandled gaps (never silently omitted)')
        foreach ($u in @($report.unhandled)) { $md.Add(("- {0}: {1}" -f $u.agentId, $u.reason)) }
    }
    Set-Content -LiteralPath $mdPath -Value ($md -join "`n") -Encoding utf8NoBOM
}

# --- 7. a killed helper's marker is adopted and cleared ---------------------
$marker = Read-CutoverJsonFile -Path $MarkerPath
if ($null -ne $marker -and $marker.PSObject.Properties['runId'] -and [string]$marker.runId -eq $RunId) {
    $null = Remove-CutoverMarkerFile -Path $MarkerPath
    Write-RecoveryAudit -Entry ([ordered]@{
            ts = (Get-Date).ToString('s'); runId = $RunId; kind = 'cutover-marker-cleared'
            reason = 'recovery adopted a marker left by a killed helper'; at = (Get-Date).ToString('o')
        })
}

Write-RecoveryAudit -Entry ([ordered]@{
        ts = (Get-Date).ToString('s'); runId = $RunId; kind = 'cutover-recovery'
        phase = 'reconcile'; standdowns = @($standDowns).Count; released = @($released).Count
        revoked = @($revoked).Count; gatesStamped = @($stamped).Count
        unhandled = @($report.unhandled).Count
        registerOk = $(if ($null -ne $register) { [bool]$register.ok } else { $false })
        reportPath = $ReportPath; dryRun = $false; at = (Get-Date).ToString('o')
    })

if ($Json) {
    $summary = [ordered]@{
        runId         = $RunId
        status        = 'reconciled'
        reportPath    = $ReportPath
        originalHubId = $OriginalHubId
        standdowns    = @($standDowns).Count
        released      = @($released).Count
        revoked       = @($revoked).Count
        gatesStamped  = @($stamped).Count
        unhandled     = @($report.unhandled).Count
        registerOk    = $(if ($null -ne $register) { [bool]$register.ok } else { $false })
    }
    $summary | ConvertTo-Json -Depth 6 -Compress
} else {
    Write-Output ("cutover-recovery {0}: stand-downs {1}, leases released {2}, revoked {3}, gates stamped {4}, unhandled {5} -> {6}" -f `
            $RunId, @($standDowns).Count, @($released).Count, @($revoked).Count,
            @($stamped).Count, @($report.unhandled).Count, $ReportPath)
}
exit 0
