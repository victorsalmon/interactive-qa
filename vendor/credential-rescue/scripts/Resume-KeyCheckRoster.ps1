#Requires -Version 7.0
<#
.SYNOPSIS
    Nudge the agents a key cutover stranded - lanes AND Hubs - and record one
    logged decision per agent.

.DESCRIPTION
    A cutover restarts Paseo. Lanes lose their turn; Hubs lose their turn AND
    their view of the children they were supervising. Restarting a Hub is not
    recovery: the Hub has to be told to look at its own subagents.

    So this script reads the roster `Capture-KeyCheckRoster.ps1` wrote and makes
    one decision per agent, appended to `Tasks/Logs/keycheck.jsonl` as

        { kind: "roster-resume", runId, agentId, decision, reason, at, variant }

    | decision                 | when                                                |
    |--------------------------|-----------------------------------------------------|
    | skipped-self             | this process, or a `merge-*` worker                 |
    | skipped-finished         | the agent status is explicit `closed`, or a non-Hub lane's OWN done evidence sits in its worktree |
    | skipped-missing-cwd      | the agent's cwd no longer exists (swept) - no send, no failure |
    | skipped-already-nudged   | the audit already holds a sent nudge for this run/agent |
    | skipped-missing          | the agent no longer exists                          |
    | skipped-over-cap         | beyond -MaxAgents                                   |
    | resumed                  | otherwise - the nudge was sent                      |

    An `isHub` entry is resumable by DEFAULT: only an explicit `closed` status
    may skip it, and the decision carries the status. A repository-root cwd
    (one holding `.git`) never counts as the occupant's completion evidence -
    a shared trunk accumulates its merge workers' `.iqa-report.md` and
    `.iqa-done-merge-*` files, and trusting that skipped the `cl-common` Hub
    during the 2026-11-03 rescue. The ownership test for a done file lives in
    `Capture-KeyCheckRoster.ps1`; this pass re-applies the repo-root guard so a
    roster written by an older capture cannot resurrect the defect.

    Two message variants, one decision path:

      lane   Continue working - a key cutover just occurred (GO<from> -> GO<to>)
             and your session may have been restarted. Re-read your brief and
             carry on; report to your parent as usual.

      hub    the cutover text, plus: you are a Hub - enumerate YOUR child
             agents, resume every non-terminal one with its exact missing
             artifacts, and do not re-dispatch work that already has commits.
             Then a ROLE-RESTORE block: HubRegistry.ps1 -Mode Register,
             Invoke-WorktreeLease.ps1 -Mode Acquire and the label re-assert,
             filled in for this agent and run from a FRESH persistent shell,
             because the pid the old lease records died with the cutover.

    A send is retried three times with backoff, then interrupt-then-prompted
    (`paseo stop`), and only then recorded as `roster-resume-failed` with
    `unhandled: true` - one attempt must never become a silent omission.

    The nudge is sent by whichever process survives, so two call sites are
    safe: the second pass sees the first pass's audit lines and skips
    (`skipped-already-nudged`).

    After the pass (and unless -DryRun) it writes the durable discovery marker
    `<StateDir>\last-cutover.json` = `{runId, at, from, to, rosterPath,
    witnessPath, verdict}`, so a Hub that wakes up late learns a cutover
    happened without knowing the runId.

    SECURITY: no key value is read, compared, or written. Only GO<n> labels.

.PARAMETER RosterPath
    The roster written by Capture-KeyCheckRoster.ps1. Required.

.PARAMETER LogOnly
    Decide and log, send nothing. Log-only lines are marked `logOnly: true` and
    never count as an idempotency hit, so a later real pass still sends.

.PARAMETER MaxAgents
    Maximum agents nudged in one pass. Default 10. The cap shares its slots
    between Hubs and lanes in roster order.

.PARAMETER DryRun
    Decide nothing durable: no audit line, no send, no marker. Prints the
    decisions it would make.

.PARAMETER SendScript
    Test seam: a script invoked as `-AgentId <id> -Variant <lane|hub>
    -MessageFile <path>` instead of `paseo send`.

.PARAMETER StateDir
    Where `last-cutover.json` lives. Default `~/.machine/state/key-check`.

.PARAMETER AuditPath
    Default `~/.machine/logs/keycheck.jsonl`.

.PARAMETER AgentListFile
    Test seam for the existence check (same shape as Capture's).

.PARAMETER AgentsDir
    Test seam for the daemon state folder.

.PARAMETER PaseoCommand
    Explicit Paseo CLI path.

.PARAMETER SelfAgentId
    Default `$env:PASEO_AGENT_ID`.

.PARAMETER RetryBackoffSeconds
    Comma-separated backoff between send attempts. Default `2,5,10`: a send that
    fails with "active run cancellation was not acknowledged" is retried three
    times, then interrupted (`paseo stop`) and prompted once more. Tests pass
    `0,0,0`. A send that never succeeds is recorded as an `unhandled: true`
    gap - never silently omitted.

.PARAMETER InterruptScript
    Test seam: a script invoked as `-AgentId <id>` instead of `paseo stop`,
    used by the interrupt-then-prompt fallback.

.PARAMETER SkillRoot
    The Skills root used to build the Hub role-restore block's copy-pasteable
    paths. Default: this skill's parent.

.OUTPUTS
    Exit 0 pass completed (including partial send failures, which are audited
    as `roster-resume-failed`) - 1 the roster could not be read.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$RosterPath,
    [switch]$LogOnly,
    [ValidateRange(0, 100)]
    [int]$MaxAgents = 10,
    [switch]$DryRun,
    [switch]$Json,
    [string]$SendScript = '',
    [string]$StateDir = '',
    [string]$AuditPath = '',
    [string]$AgentListFile = '',
    [string]$AgentsDir = '',
    [string]$PaseoCommand = '',
    [string]$SelfAgentId = '',
    [string]$RetryBackoffSeconds = '2,5,10',
    [string]$InterruptScript = '',
    [string]$SkillRoot = ''
)

$ErrorActionPreference = 'Stop'

$scriptRoot = $PSScriptRoot
. (Join-Path $scriptRoot 'lib\PaseoCommon.ps1')

if ([string]::IsNullOrWhiteSpace($StateDir)) { $StateDir = Join-Path $env:USERPROFILE '.machine\state\key-check' }
if ([string]::IsNullOrWhiteSpace($AuditPath)) { $AuditPath = Join-Path $env:USERPROFILE '.machine\logs\keycheck.jsonl' }
if ([string]::IsNullOrWhiteSpace($AgentsDir)) { $AgentsDir = Join-Path $env:USERPROFILE '.paseo\agents' }
if ([string]::IsNullOrWhiteSpace($SelfAgentId)) { $SelfAgentId = [string]$env:PASEO_AGENT_ID }
if ([string]::IsNullOrWhiteSpace($SkillRoot)) { $SkillRoot = [System.IO.Path]::GetFullPath((Join-Path $scriptRoot '..\..')) }

$backoff = @()
foreach ($part in ($RetryBackoffSeconds -split ',')) {
    $n = 0
    if ([int]::TryParse($part.Trim(), [ref]$n) -and $n -ge 0) { $backoff += $n }
}
if ($backoff.Count -eq 0) { $backoff = @(2, 5, 10) }

function Write-RosterAudit {
    param($Entry)
    if ($DryRun) { return }
    $dir = Split-Path -Parent $AuditPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
    Add-Content -LiteralPath $AuditPath -Value ($Entry | ConvertTo-Json -Compress) -Encoding utf8NoBOM
}

function Get-RosterAuditLines {
    if (-not (Test-Path -LiteralPath $AuditPath)) { return @() }
    $rows = @()
    foreach ($line in @(Get-Content -LiteralPath $AuditPath -ErrorAction SilentlyContinue)) {
        if (-not $line.Trim()) { continue }
        try { $rows += ($line | ConvertFrom-Json) } catch { }
    }
    return $rows
}

function Get-RosterLiveAgentIds {
    <#
    .SYNOPSIS
        Which agents still exist. $null means "could not tell" - an unprovable
        absence is never reported as `skipped-missing`.
    #>
    if ($AgentListFile) {
        if (-not (Test-Path -LiteralPath $AgentListFile)) { return $null }
        $parsed = Get-Content -LiteralPath $AgentListFile -Raw | ConvertFrom-Json
        return @(@($parsed) | ForEach-Object { [string]$_.id })
    }
    $cli = if ($PaseoCommand) { $PaseoCommand } else { Resolve-PaseoCli }
    if ([string]::IsNullOrWhiteSpace($cli)) { return $null }
    $raw = & $cli ls --json --background 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($raw)) { return $null }
    try { $parsed = $raw | ConvertFrom-Json } catch { return $null }
    return @(@($parsed) | ForEach-Object { [string]$_.id })
}

function Get-NudgeMessage {
    <#
    .SYNOPSIS
        The exact text for one variant. Hubs get the child-recovery duty AND the
        role-restore block; lanes get the plain continue.
    .DESCRIPTION
        A cutover kills the persistent shells a Hub's worktree lease names and
        can lose its registry row, so "restart the Hub" is not recovery: it has
        to be handed the three commands that put the role back, copy-pasteable,
        in the order that works.
    #>
    param([string]$Variant, [string]$From, [string]$To, $Agent = $null, [string]$RunId = '')
    $fromLabel = if ($From) { $From } else { 'unknown' }
    $toLabel = if ($To) { $To } else { 'unknown' }
    if ($Variant -eq 'hub') {
        $headline = ("A key cutover just occurred ({0} → {1}) and your session may have been restarted. " +
            "You are a Hub: enumerate YOUR child agents, resume every non-terminal one with its exact missing artifacts " +
            "(report, done file, gate lines), and do not re-dispatch work that already has commits on its branch. " +
            "Then continue your own queue.") -f $fromLabel, $toLabel

        $agentId = if ($null -ne $Agent -and $Agent.PSObject.Properties['id']) { [string]$Agent.id } else { '<your-agent-id>' }
        $cwd = if ($null -ne $Agent -and $Agent.PSObject.Properties['cwd']) { [string]$Agent.cwd } else { '<repo-root>' }
        $repo = if ($cwd -and $cwd -notlike '<*') { (Split-Path -Leaf ($cwd.TrimEnd('\', '/'))) } else { '<repo>' }
        $taskId = if ($RunId) { $RunId } else { '<cutover-runId>' }
        $hubRegistry = Join-Path $SkillRoot 'iqa-merge\HubRegistry.ps1'
        $leaseScript = Join-Path $SkillRoot 'git-operations\Invoke-WorktreeLease.ps1'

        $block = @"

Role re-assert — your old lease records a pid that is dead and your registry row may be gone. Run these in order from a FRESH persistent shell (a terminal the cutover did not kill), then continue:
  1) pwsh -NoProfile -File "$hubRegistry" -Mode Register -Repo "$repo" -RepoPath "$cwd" -AgentId "$agentId" -Trunk dev
  2) pwsh -NoProfile -File "$leaseScript" -Mode Acquire -Path "$cwd" -TaskId "$taskId"
  3) re-assert your Hub label: paseo update "$agentId" --label "hub-$repo=$repo"   (or your iqa-role=merge label)
Do not merge, land, or re-dispatch until step 1 shows you as primary and step 2 reports Acquired.
"@
        return ($headline + $block)
    }
    return ("Continue working — a key cutover just occurred ({0} → {1}) and your session may have been restarted. " +
        "Re-read your brief and carry on; report to your parent as usual.") -f $fromLabel, $toLabel
}

function Invoke-RosterSendAttempt {
    <#
    .SYNOPSIS
        One send attempt. Returns @{ Ok; Detail }; never throws.
    #>
    param([string]$AgentId, [string]$Variant, [string]$MessageFile)
    try {
        if ($SendScript) {
            $out = & (Join-Path $PSHOME 'pwsh.exe') -NoProfile -File $SendScript `
                -AgentId $AgentId -Variant $Variant -MessageFile $MessageFile 2>&1 | Out-String
        } else {
            $cli = if ($PaseoCommand) { $PaseoCommand } else { Resolve-PaseoCli }
            if ([string]::IsNullOrWhiteSpace($cli)) { return @{ Ok = $false; Detail = 'paseo CLI not found' } }
            $out = & $cli send $AgentId --prompt-file $MessageFile --no-wait 2>&1 | Out-String
        }
        $code = $LASTEXITCODE
        if ($code -ne 0) { return @{ Ok = $false; Detail = "send exit $code`: $(([string]$out).Trim())" } }
        return @{ Ok = $true; Detail = '' }
    } catch {
        return @{ Ok = $false; Detail = $_.Exception.Message }
    }
}

function Invoke-RosterInterrupt {
    <#
    .SYNOPSIS
        Interrupt the agent (`paseo stop`) so the next prompt starts a fresh turn
        instead of colliding with a run the daemon never acknowledged cancelling.
    #>
    param([string]$AgentId)
    try {
        if ($InterruptScript) {
            $out = & (Join-Path $PSHOME 'pwsh.exe') -NoProfile -File $InterruptScript -AgentId $AgentId 2>&1 | Out-String
        } else {
            $cli = if ($PaseoCommand) { $PaseoCommand } else { Resolve-PaseoCli }
            if ([string]::IsNullOrWhiteSpace($cli)) { return @{ Ok = $false; Detail = 'paseo CLI not found' } }
            $out = & $cli stop $AgentId 2>&1 | Out-String
        }
        return @{ Ok = ($LASTEXITCODE -eq 0); Detail = ([string]$out).Trim() }
    } catch {
        return @{ Ok = $false; Detail = $_.Exception.Message }
    }
}

function Send-RosterNudge {
    <#
    .SYNOPSIS
        Send one nudge, with the retry policy a cutover needs. Returns
        @{ Ok; Detail; Attempts }. Never throws: a send that never lands is
        audited as an unhandled gap and never fails the cutover.
    .DESCRIPTION
        `active run cancellation was not acknowledged` is the daemon telling the
        caller that its previous turn is still being cancelled. One attempt used
        to leave the agent silently unresumed (runId 20261102-172700). Three
        attempts with backoff, then interrupt-then-prompt, is the minimum that
        distinguishes "busy for a moment" from "cannot be resumed".
    #>
    param([string]$AgentId, [string]$Variant, [string]$Message)
    $stamp = [guid]::NewGuid().ToString('N')
    $messageFile = Join-Path ([System.IO.Path]::GetTempPath()) "kc-nudge-$stamp.txt"
    $attempts = 0
    $detail = ''
    try {
        Set-Content -LiteralPath $messageFile -Value $Message -Encoding utf8NoBOM -NoNewline
        for ($i = 0; $i -lt 3; $i++) {
            $attempts++
            $attempt = Invoke-RosterSendAttempt -AgentId $AgentId -Variant $Variant -MessageFile $messageFile
            if ($attempt.Ok) { return @{ Ok = $true; Detail = ''; Attempts = $attempts } }
            $detail = [string]$attempt.Detail
            $wait = if ($i -lt $backoff.Count) { [int]$backoff[$i] } else { 10 }
            if ($i -lt 2 -and $wait -gt 0) { Start-Sleep -Seconds $wait }
        }

        $interrupt = Invoke-RosterInterrupt -AgentId $AgentId
        if (-not $interrupt.Ok -and $interrupt.Detail) { $detail = "$detail; interrupt: $($interrupt.Detail)" }
        if ($interrupt.Ok -or -not $InterruptScript) {
            $attempts++
            $attempt = Invoke-RosterSendAttempt -AgentId $AgentId -Variant $Variant -MessageFile $messageFile
            if ($attempt.Ok) { return @{ Ok = $true; Detail = ''; Attempts = $attempts } }
            $detail = [string]$attempt.Detail
        }
        return @{ Ok = $false; Detail = $detail; Attempts = $attempts }
    } catch {
        return @{ Ok = $false; Detail = $_.Exception.Message; Attempts = $attempts }
    } finally {
        Remove-Item -LiteralPath $messageFile -Force -ErrorAction SilentlyContinue
    }
}

# --- read the roster ---------------------------------------------------------
if (-not (Test-Path -LiteralPath $RosterPath)) {
    Write-RosterAudit -Entry ([ordered]@{
            ts = (Get-Date).ToString('s'); kind = 'roster-resume-failed'; runId = ''
            reason = "roster not found: $RosterPath"; at = (Get-Date).ToString('o')
        })
    [Console]::Error.WriteLine("roster-resume-failed: roster not found at $RosterPath")
    exit 1
}
try {
    $roster = Get-Content -LiteralPath $RosterPath -Raw | ConvertFrom-Json
} catch {
    Write-RosterAudit -Entry ([ordered]@{
            ts = (Get-Date).ToString('s'); kind = 'roster-resume-failed'; runId = ''
            reason = "roster unreadable: $($_.Exception.Message)"; at = (Get-Date).ToString('o')
        })
    [Console]::Error.WriteLine("roster-resume-failed: roster unreadable at $RosterPath")
    exit 1
}

$runId = [string]$roster.runId
$from = [string]$roster.from
$to = [string]$roster.to
$liveIds = Get-RosterLiveAgentIds
$prior = @(Get-RosterAuditLines)

$counts = [ordered]@{
    resumed          = 0
    hubsNudged       = 0
    lanesNudged      = 0
    skippedFinished  = 0
    skippedSelf      = 0
    skippedAlready   = 0
    skippedMissing   = 0
    skippedMissingCwd = 0
    skippedOverCap   = 0
    failed           = 0
}
$decisions = @()

foreach ($agent in @($roster.agents)) {
    if ($null -eq $agent) { continue }
    $agentId = [string]$agent.id
    if ([string]::IsNullOrWhiteSpace($agentId)) { continue }
    $isHub = [bool]$agent.isHub
    $variant = if ($isHub) { 'hub' } else { 'lane' }

    $alreadySent = @($prior | Where-Object {
            $null -ne $_ -and
            $_.PSObject.Properties['kind'] -and $_.kind -eq 'roster-resume' -and
            $_.PSObject.Properties['runId'] -and [string]$_.runId -eq $runId -and
            $_.PSObject.Properties['agentId'] -and [string]$_.agentId -eq $agentId -and
            (-not $_.PSObject.Properties['logOnly'] -or -not [bool]$_.logOnly) -and
            $_.PSObject.Properties['decision'] -and $_.decision -eq 'resumed'
        }).Count -gt 0

    $decision = ''
    $reason = ''
    # A cwd that is gone is a SKIP, not a failure: the worktree was swept
    # between capture and recovery, so there is nothing to nudge and no send is
    # attempted (the old pass tried anyway and recorded roster-resume-failed).
    $cwd = [string]$agent.cwd
    $cwdMissing = (-not [string]::IsNullOrWhiteSpace($cwd)) -and -not (Test-Path -LiteralPath $cwd)
    # A repository root is a shared trunk, never one agent's checkout, so its
    # contents are not this agent's completion evidence (the cl-common Hub).
    $cwdIsRepoRoot = (-not $cwdMissing -and -not [string]::IsNullOrWhiteSpace($cwd) -and
        (Test-Path -LiteralPath (Join-Path $cwd '.git')))
    $status = ([string]$agent.status).Trim()

    $finished = $false
    $finishedReason = ''
    if ($status -ieq 'closed') {
        $finished = $true
        $finishedReason = "agent status '$status'"
    } elseif (-not $isHub -and [bool]$agent.hasDoneFile -and -not $cwdIsRepoRoot) {
        $finished = $true
        $finishedReason = 'its own done file in a worktree cwd'
    }

    if (($SelfAgentId -and $agentId -eq $SelfAgentId) -or ([string]$agent.title -match '^merge-')) {
        $decision = 'skipped-self'; $reason = 'this process or a merge worker'
    } elseif ($finished) {
        $decision = 'skipped-finished'; $reason = $finishedReason
    } elseif ($cwdMissing) {
        $decision = 'skipped-missing-cwd'; $reason = "cwd no longer exists: $cwd"
    } elseif ($alreadySent) {
        $decision = 'skipped-already-nudged'; $reason = "audit already holds roster-resume for run $runId"
    } elseif ($null -ne $liveIds -and @($liveIds) -notcontains $agentId) {
        $decision = 'skipped-missing'; $reason = 'agent no longer exists'
    } elseif ($counts.resumed -ge $MaxAgents) {
        $decision = 'skipped-over-cap'; $reason = "cap of $MaxAgents reached"
    } else {
        $decision = 'resumed'
        $reason = if ($null -eq $liveIds) { 'existence-unverified' } else { 'live' }
    }

    switch ($decision) {
        'skipped-finished' { $counts.skippedFinished++ }
        'skipped-self' { $counts.skippedSelf++ }
        'skipped-already-nudged' { $counts.skippedAlready++ }
        'skipped-missing' { $counts.skippedMissing++ }
        'skipped-missing-cwd' { $counts.skippedMissingCwd++ }
        'skipped-over-cap' { $counts.skippedOverCap++ }
    }

    $sendOk = $true
    $sendDetail = ''
    $sendAttempts = 0
    if ($decision -eq 'resumed' -and -not $LogOnly -and -not $DryRun) {
        $message = Get-NudgeMessage -Variant $variant -From $from -To $to -Agent $agent -RunId $runId
        $send = Send-RosterNudge -AgentId $agentId -Variant $variant -Message $message
        $sendOk = [bool]$send.Ok
        $sendDetail = [string]$send.Detail
        $sendAttempts = [int]$send.Attempts
    }

    if (-not $DryRun) {
        if ($decision -eq 'resumed' -and -not $sendOk) {
            $counts.failed++
            # Never silently omit the agent: the recovery report turns this into
            # an explicit `unhandled` gap with the reason and the attempt count.
            Write-RosterAudit -Entry ([ordered]@{
                    ts = (Get-Date).ToString('s'); kind = 'roster-resume-failed'; runId = $runId
                    agentId = $agentId; variant = $variant; isHub = $isHub
                    attempts = $sendAttempts; unhandled = $true
                    reason = "send failed: $sendDetail"; at = (Get-Date).ToString('o')
                })
        } else {
            if ($decision -eq 'resumed') {
                $counts.resumed++
                if ($isHub) { $counts.hubsNudged++ } else { $counts.lanesNudged++ }
            }
            Write-RosterAudit -Entry ([ordered]@{
                    ts = (Get-Date).ToString('s'); kind = 'roster-resume'; runId = $runId
                    agentId = $agentId; decision = $decision; reason = $reason
                    variant = $variant; isHub = $isHub; logOnly = [bool]$LogOnly
                    at = (Get-Date).ToString('o')
                })
        }
    } elseif ($decision -eq 'resumed') {
        $counts.resumed++
        if ($isHub) { $counts.hubsNudged++ } else { $counts.lanesNudged++ }
    }

    $decisions += [ordered]@{
        agentId  = $agentId
        title    = [string]$agent.title
        variant  = $variant
        decision = $decision
        reason   = $reason
        sent     = [bool]($decision -eq 'resumed' -and -not $LogOnly -and -not $DryRun -and $sendOk)
    }
}

# --- the durable discovery marker -------------------------------------------
$witnessPath = Join-Path $StateDir "witness-$runId.json"
$verdict = ''
if (Test-Path -LiteralPath $witnessPath) {
    try {
        $witness = Get-Content -LiteralPath $witnessPath -Raw | ConvertFrom-Json
        $verdict = [string]$witness.verdict
    } catch { }
}
$markerPath = Join-Path $StateDir 'last-cutover.json'
if (-not $DryRun) {
    $at = (Get-Date).ToString('o')
    if (Test-Path -LiteralPath $markerPath) {
        try {
            $existing = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
            if ([string]$existing.runId -eq $runId -and $existing.PSObject.Properties['at'] -and $existing.at) {
                $at = [string]$existing.at
            }
        } catch { }
    }
    $marker = [ordered]@{
        runId       = $runId
        at          = $at
        from        = $from
        to          = $to
        rosterPath  = (Resolve-Path -LiteralPath $RosterPath).Path
        witnessPath = $(if (Test-Path -LiteralPath $witnessPath) { $witnessPath } else { '' })
        verdict     = $verdict
        updatedAt   = (Get-Date).ToString('o')
    }
    $markerDir = Split-Path -Parent $markerPath
    if ($markerDir -and -not (Test-Path -LiteralPath $markerDir)) { $null = New-Item -ItemType Directory -Path $markerDir -Force }
    Set-Content -LiteralPath $markerPath -Value ($marker | ConvertTo-Json -Depth 6) -Encoding utf8NoBOM
}

$summary = [ordered]@{
    runId     = $runId
    from      = $from
    to        = $to
    logOnly   = [bool]$LogOnly
    dryRun    = [bool]$DryRun
    counts    = $counts
    decisions = @($decisions)
    marker    = $markerPath
}
if ($Json) {
    $summary | ConvertTo-Json -Depth 8
} else {
    Write-Output ("roster-resume {0}: resumed {1} (hub {2}, lane {3}); skipped finished {4}, already {5}, missing {6}, missing-cwd {7}, over-cap {8}, failed {9}" -f `
            $runId, $counts.resumed, $counts.hubsNudged, $counts.lanesNudged, $counts.skippedFinished, `
            $counts.skippedAlready, $counts.skippedMissing, $counts.skippedMissingCwd, $counts.skippedOverCap, $counts.failed)
}
exit 0
