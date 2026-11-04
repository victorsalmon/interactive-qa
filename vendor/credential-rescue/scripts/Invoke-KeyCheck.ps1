#Requires -Version 7.0
<#
.SYNOPSIS
    Key Check - deadline-bounded, hysteresis-driven opencode-go key rescue.

.DESCRIPTION
    Watches the ACTIVE opencode-go pool key against its live usage meters and
    moves the machine onto a better key BEFORE the active one dies, on a fixed
    wall-clock budget that no phase may extend.

        Key Check [minutes] [hours]        defaults 15 minutes / 2 hours
        Key Check 30                      = 30 minutes / 2 hours
        Key Check 30 4                    = 30 minutes / 4 hours

    Phases (all decisions live in lib/KeyCheck.Decision.ps1):

        initial    once  poll ALL keys, write wk+mo into the freshness ledger,
                         resolve the in-use key by hashing every pool key against
                         the in-use value, report provider-lock drift (never act
                         on it), canary the active key, fix the deadline, then
                         evaluate imminent -> near-exhaustion -> heartbeat.
                         An in-use value NO pool key and no seam activeKey can
                         resolve ends the run immediately (exit 1,
                         `active-key-unresolved`) instead of polling blindly.
        heartbeat  adaptive  poll the ACTIVE key only, on the burn-derived gear with
                         an hourly ceiling. wk >= 80 OR mo >= 90 -> discover.
                         A quiet key is checked hourly; the gear tightens as the
                         measured burn brings the trigger closer. The FIRST
                         reading of a process is taken immediately (t ~ 0): only
                         the readings after it wait a gear, so a watch restarted
                         more often than its cadence still records checks.
        discover   once  one census read (the same reader as initial), then each
                         eligible key is canaried until one is proven; the armed
                         key is logged by id with both meters and the monthly
                         reset that ranked it. When nothing qualifies, every
                         candidate is logged with the rule that excluded it. A
                         read that yields no reading is `cannot-evaluate`, never
                         "no eligible replacement". Then near.
        near       adaptive  poll the ACTIVE key only, on the SAME gear but capped
                         at 15 minutes (and floored at one): a key inside the band
                         is never left unlooked-at for a quarter hour, and a key
                         minutes from the trigger is read every minute.
                         wk > 96 OR
                         mo > 98 -> trigger; a rate-limited read triggers only on
                         the SECOND consecutive one. Two consecutive readings
                         with wk < 70 AND mo < 80 disarm back to heartbeat, so a
                         misread cannot keep a hot loop running for hours.
                         Deadline -> end.
        trigger    once  active == replacement is a no-op; otherwise re-prove the
                         replacement, create the cutover helper through
                         Win32_Process.Create (outside the caller's job object by
                         construction) and poll its outcome
                         file, then record the exhausted key's final reading,
                         reset the thresholds, KEEP the deadline, generation++
                         and return to near.

    One live run per machine. The run takes a lock
    (~/.salmon/State/key-check/lock.json); a second live run exits 2 with
    `locked-by-run` and prints the holder's runId and age. A stale lock (dead
    pid, or a heartbeat older than three intervals) is taken over and audited;
    -Force steals deliberately; -DryRun never takes it.

    The run is resumable. state.json is rewritten after every check, so an
    interruption (a reboot, a Ctrl-C, or the restart the cutover itself causes)
    resumes the SAME runId and the ORIGINAL deadline. A deadline that passed
    while nothing ran ends the run as `window-expired-while-down` - never with a
    fresh window, because the deadline is never extended.

    On EVERY start - fresh or resumed - the live in-use key is re-resolved and
    reconciled with state.activeKeyNumber. When they differ (an operator moved
    the fleet to another key under a running watch), generation + 1,
    activeKeyNumber follows the LIVE key, the old key's sample ring and meters
    are discarded, and one `active-key-changed GO<n> -> GO<m>` line is audited.
    A resume never re-asserts a key the machine has left (cl-common-o1t).

    The cutover is delegated, never performed in-process: the Paseo repair runs
    `paseo restart`, which ends every session the daemon hosts - including the
    Key Check session that asked for the rescue. The helper is created through
    Win32_Process.Create because that child is outside the caller's job object by
    construction (a design argument, not a measurement: on 2026-11-02 both
    mechanisms survived a force-killed launcher on this host, and survival across
    a real restart is unproven). Survival is not what the rescue depends on - the
    helper writes its outcome BEFORE the restart, so a helper that dies is
    finished by the next invocation.

    Weekly (wk) is a 7-day slice = 50 % of the monthly allowance; monthly (mo) is
    the account term = 100 %; the rolling 5 h window (20 %) is not a trigger.
    Meter abbreviations are always wk/mo - never w/m, because m means minutes.

    SECURITY: key VALUES are never printed, logged, or written. Keys are named by
    number; comparisons are SHA-256 fingerprints. A cutover appends one line to
    the audit trail naming from/to key numbers and the canary result only.

.PARAMETER IntervalMinutes
    The BASE gear of the adaptive cadence in minutes: the interval a quiet key is
    polled at, and the slowest the heartbeat may run (capped at 60). Default 15.
    Must be >= 1. The faster gears come from the measured burn, not from this
    argument; `near` uses the same gears with a 15-minute ceiling.

.PARAMETER DurationHours
    Run budget in wall-clock hours. Default 2. Must be > 0.

.PARAMETER DryRun
    A PROBE, not a watch: make every decision and write the full audit trail,
    but perform NO cutover, NO ledger write, and NO write to the live run's
    files. A dry run reads the live state as CONTEXT (so the decisions it
    rehearses are the ones the live run would make) and then writes ONLY under
    `<state dir>\dryrun\`, under its own `<runId>-dryrun` identity. The live
    state.json, lock.json and keycheck.jsonl are unreachable from a dry run, so
    a probe can never end, rewrite or impersonate the live run (cl-common-jqm).
    The run continues as if the cutover had happened.

.PARAMETER Json
    Emit the final run state as JSON (suppresses progress lines).

.PARAMETER StatePath
    Run-state file. Default ~/.salmon/State/key-check/state.json - ONE fixed
    path, because that is what makes a run resumable. The lock and the cutover
    outcome live beside it. Under -DryRun the probe NEVER writes this file: it
    reads it as context and writes `<parent>\dryrun\<name>` instead.

.PARAMETER AuditPath
    Per-check JSONL audit. Default ~/.salmon/Tasks/Logs/keycheck.jsonl. Under
    -DryRun the probe writes `<parent>\dryrun\<name>` instead, so no rehearsal
    row ever lands in the live ledger.

.PARAMETER Force
    Steal a live lock deliberately (audited). Use when a previous run is known
    to be gone but its pid still looks alive.

.PARAMETER AllowProcessFallback
    Permit the cutover helper to be created with Start-Process when
    Win32_Process.Create is unavailable. OFF by default: such a child may inherit
    this agent's job object, and the run should not quietly choose a mechanism
    nobody asked for. It is still SAFE when enabled - the helper writes its
    outcome before the restart, so a helper that dies is finished by the next
    invocation - just slower to prove. When off, a CIM failure ends the run as
    cutover-failed (4) with an audit line instead of pretending.

.PARAMETER PaseoConfig
    Test seam: the Paseo config whose provider pin is re-verified when a resumed
    run finds a `restartPending` cutover outcome. Default ~/.paseo/config.json.

.PARAMETER UsageFile
    Test/fixture seam: read usage rows from a file instead of the endpoint. The
    file is either an array of Get-GoKeyUsage.ps1 -Json rows, or a map of
    { "GO1": { "weekly": {...}, "monthly": {...} } }.

.PARAMETER BaseUrl
    Test seam: read usage from an alternative endpoint (the URL, or a base with
    /usage appended) instead of Get-GoKeyUsage.ps1.

.PARAMETER KeyValuesFile
    Test seam: { "inUse": "<value>", "keys": { "GO1": "<value>" } } instead of
    the Machine/User OPENCODE_GO<n>_KEY environment. Values are never printed.

.PARAMETER SeamPath
    Test seam: the cutover seam file whose `activeKey` is the fallback active
    key. Default assets/opencode-go-cutover.json. Point it at a temp file to
    exercise `active-key-unresolved` without touching the real seam.

.PARAMETER CanaryScript
    Override the canary (default Test-GoKey.ps1). Test seam.

.PARAMETER RepairScript
    Override the Paseo cutover (default Repair-Paseo.ps1). Test seam. Passed
    through to the detached cutover helper.

.PARAMETER SwitchScript
    Override the Salmon switch (default Switch-OpencodeGoKey.ps1). Test seam.
    Passed through to the detached cutover helper.

.PARAMETER CutoverScript
    Override the detached cutover helper (default Invoke-KeyCheckCutover.ps1).
    Test seam.

.PARAMETER ResumeScript
    Override the roster resume (default Resume-KeyCheckRoster.ps1). Test seam.

.PARAMETER WitnessScript
    Override the cutover witness (default Invoke-KeyCheckWitness.ps1). Test seam.

.PARAMETER NoRecovery
    Skip the post-cutover roster recovery pass entirely (test seam for suites
    that must not touch the roster machinery).

.PARAMETER AgentListFile
    Test seam: pass a fixed agent list to the roster pass instead of `paseo ls`.

.PARAMETER AgentsDir
    Test seam: the daemon's per-agent state folder the roster reads labels from.

.PARAMETER SendScript
    Test seam: the roster pass's send stub instead of `paseo send`.

.PARAMETER CutoverOutcomePath
    The outcome file the detached helper writes and this watch polls. Default
    `<state file dir>\<runId>-cutover.json`.

.PARAMETER CutoverTimeoutMinutes
    How long the watch waits for the helper's outcome before ending the run
    honestly. Default 5. The helper survives the Paseo restart the watch cannot.

.PARAMETER CutoverPollSeconds
    Outcome poll cadence while waiting for the detached helper. Default 2.

.PARAMETER StartAfterSeconds
    Wait this long before the first check, then run normally. This is how an
    armed successor is a ONE-SHOT later run rather than a second watcher: it
    cannot start before the parent's deadline has passed. Default 0.

.PARAMETER TriggeredBy
    Who started this process - `successor-arm` (the run that ended at its
    deadline armed it) or `supervisor` (a standing liveness check restarted it).
    Empty means an operator or the Hub typed the command. A triggered start first
    asserts liveness: with a live lock it records `skipped` and exits 0 instead of
    becoming a duplicate watcher.

.PARAMETER SuccessorOf
    The runId that armed this process, recorded in the audit line so the chain is
    readable end to end. Empty for a fresh operator run.

.PARAMETER SuccessorGraceSeconds
    The beat between the parent's deadline and the successor's first check.
    Default 30: the parent needs a moment to write its terminal state and release
    the lock, and a successor that fires early would meet a live lock and skip.

.PARAMETER NoSuccessor
    Do not arm a successor at the deadline (a bounded window, a maintenance host,
    or a test that must not leave a process behind).

.PARAMETER SuccessorScript
    Override the script the armed successor runs (default: this script). Test
    seam, and how a suite proves the arm path without starting a real watch.

.PARAMETER SkipCanary
    Skip canaries. A skipped canary is recorded as `skipped`, never as `OK`.

.PARAMETER SkipDrift
    Skip the Invoke-ProviderLock -Mode Status drift report.

.PARAMETER NoLedger
    Do not write the freshness ledger (test seam; -DryRun implies it).

.PARAMETER NoWait
    Do not sleep between checks (test seam; pair with -MaxChecks). Without a
    delay the loop spins as fast as the endpoint answers, so when -MaxChecks is
    omitted the run is bounded at 240 checks and the bound is audited
    (`nowait-bounded`).

.PARAMETER MaxChecks
    Stop after this many checks (0 = no limit; test seam).

.PARAMETER TimeoutSeconds
    Usage-endpoint timeout. Default 20.

.EXAMPLE
    pwsh -File Invoke-KeyCheck.ps1 -IntervalMinutes 15 -DurationHours 2

.EXAMPLE
    pwsh -File Invoke-KeyCheck.ps1 -DryRun -IntervalMinutes 1 -DurationHours 0.02 -Json

.OUTPUTS
    Exit 0 completed (deadline, max-checks, or a deadline that expired while the
    run was down: `window-expired-while-down`) - 1 fatal (including a usage read
    that produced no reading: `cannot-evaluate`; an unresolvable active key:
    `active-key-unresolved`; three unreadable reads in a row:
    `meter-unreadable`) - 2 invalid grammar, or another live run holds the lock
    (`locked-by-run`) - 3 no eligible replacement when a rescue was needed -
    4 cutover failed (the helper reported `applied=false`, or it never spawned) -
    5 cutover unproven (`applied=true` but a surface disagrees, or the helper
    wrote no outcome inside -CutoverTimeoutMinutes).
#>
[CmdletBinding()]
param(
    [int]$IntervalMinutes = 15,
    [double]$DurationHours = 2,
    [switch]$DryRun,
    [switch]$Json,
    [switch]$Force,
    [switch]$AllowProcessFallback,
    [string]$StatePath,
    [string]$AuditPath,
    [string]$UsageFile,
    [string]$BaseUrl = '',
    [string]$KeyValuesFile,
    [string]$SeamPath,
    [string]$PaseoConfig,
    [string]$CanaryScript,
    [string]$RepairScript,
    [string]$SwitchScript,
    [string]$CutoverScript,
    [string]$ResumeScript,
    [string]$WitnessScript,
    [switch]$NoRecovery,
    [string]$AgentListFile,
    [string]$AgentsDir,
    [string]$SendScript,
    [string]$CutoverOutcomePath,
    [double]$CutoverTimeoutMinutes = 5,
    [double]$CutoverPollSeconds = 2,
    [double]$StartAfterSeconds = 0,
    [string]$TriggeredBy = '',
    [string]$SuccessorOf = '',
    [double]$SuccessorGraceSeconds = 30,
    [switch]$NoSuccessor,
    [string]$SuccessorScript,
    [switch]$SkipCanary,
    [switch]$SkipDrift,
    [switch]$NoLedger,
    [switch]$NoWait,
    [int]$MaxChecks = 0,
    [int]$TimeoutSeconds = 20
)

$ErrorActionPreference = 'Stop'

$scriptRoot = $PSScriptRoot
. (Join-Path $scriptRoot 'lib\KeyCheck.Decision.ps1')
. (Join-Path $scriptRoot 'lib\KeyCheck.State.ps1')
. (Join-Path $scriptRoot 'lib\PaseoCommon.ps1')
. (Join-Path $scriptRoot '..\..\aws\scripts\SecretFingerprint.ps1')

if (-not (Test-KeyCheckGrammar -IntervalMinutes $IntervalMinutes -DurationHours $DurationHours)) {
    [Console]::Error.WriteLine((Get-KeyCheckGrammar))
    [Console]::Error.WriteLine('minutes must be an integer >= 1 and hours a number > 0.')
    exit 2
}

$stateRoot = Join-Path $env:USERPROFILE '.salmon'
$stateDir = if ($StatePath) {
    $parent = Split-Path -Parent $StatePath
    if ([string]::IsNullOrWhiteSpace($parent)) { (Get-Location).Path } else { $parent }
} else {
    Join-Path $stateRoot 'State\key-check'
}
# ONE fixed state path: a run is only resumable if the next invocation looks in
# the same place the last one wrote.
if (-not $StatePath) { $StatePath = Join-Path $stateDir 'state.json' }
if (-not $AuditPath) { $AuditPath = Join-Path (Join-Path $stateRoot 'Tasks\Logs') 'keycheck.jsonl' }

# ---- -DryRun is a PROBE: it never shares the live run's identity or files ---
# Measured defect (cl-common-jqm, 2026-11-03 11:09:10 PT): a dry run resumed the
# LIVE runId 20261103-080748, appended a `resume` row and a terminal `end` row
# (decision=end, reason=max-checks, dryRun=true) to the live ledger as that run,
# and rewrote the live state.json with endedAt/endReason/exitCode - while the real
# watch (pid 47628, no -DryRun) was alive and beating. Every reader of state.json
# then saw `ended` for a watch that had not ended, which is how a duplicate
# watcher gets started on top of a live one.
#
# The fix is structural, not a guard that some future code path can skip: the
# live file paths are replaced BEFORE any write, so this process cannot reach
# them. A dry run keeps reading the live state as CONTEXT (that is what makes the
# rehearsal faithful) and writes its state, audit, cutover outcome and witness
# files under `<state dir>\dryrun\`, under its own `<runId>-dryrun` identity.
$liveStatePath = $StatePath
if ($DryRun) {
    $stateDir = Join-Path $stateDir 'dryrun'
    $StatePath = Join-Path $stateDir (Split-Path -Leaf $liveStatePath)
    $auditDir = Split-Path -Parent $AuditPath
    if ([string]::IsNullOrWhiteSpace($auditDir)) { $auditDir = (Get-Location).Path }
    $AuditPath = Join-Path (Join-Path $auditDir 'dryrun') (Split-Path -Leaf $AuditPath)
}
$lockPath = Join-Path $stateDir 'lock.json'
# A lock is stale after three poll intervals: long enough that a slow census is
# not mistaken for a crash, short enough that a crashed run is recoverable.
$lockStaleSeconds = [int]([Math]::Max(60, 3 * $IntervalMinutes * 60))
# The adaptive cadence's BASE gear is this run's interval and, exactly as the
# operator asked, it is never stretched past an hour. It is the STARTING gear
# (before any measured burn) and the flat-window loosening target - NOT the
# ladder's cap: the ladder is bounded by the PHASE ceiling, so a quiet key on a
# 15-minute run can still reach 60 minutes once its measured ETT says hours
# (cl-common-8yq).
$cadenceBaseSeconds = [Math]::Max($script:KeyCheckCadenceMinimumSeconds, [Math]::Min($IntervalMinutes * 60, $script:KeyCheckCadenceBaseSeconds))
$script:LockHeld = $false
$script:LockRunId = ''
$script:LastLaunch = $null
# One recovery pass per cutover run, however many call sites fire in this run.
$script:RecoveredRunIds = @()

function Write-KeyCheckAudit {
    param($Entry)
    $dir = Split-Path -Parent $AuditPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
    Add-Content -LiteralPath $AuditPath -Value ($Entry | ConvertTo-Json -Compress) -Encoding utf8NoBOM
}

function Exit-KeyCheckRun {
    # Release before leaving, so the next invocation is not forced to wait out
    # the staleness window. A hard kill skips this; the stale-lock takeover is
    # the safety net for that case.
    param([int]$Code)
    if ($script:LockHeld) {
        $null = Exit-KeyCheckLock -Path $lockPath -RunId $script:LockRunId
        $script:LockHeld = $false
    }
    exit $Code
}

# ---- triggered start: assert liveness BEFORE becoming a watcher ------------
# Both ways a run comes back to life without a human - the successor the previous
# run armed (`successor-arm`) and a standing supervisor (`supervisor`) - ask the
# same question here: is something already watching? A live lock answers yes, and
# then this process records `skipped` and exits 0 rather than becoming a duplicate
# watcher (cl-common-0ai acceptance 3). The lock is the single liveness signal, so
# the answer cannot disagree with `Enter-KeyCheckLock` below.
if ($StartAfterSeconds -gt 0) {
    $waitSeconds = [Math]::Min($StartAfterSeconds, 86400)
    if (-not $Json) { Write-Output ("[successor] waiting {0}s before the first check (armed by run {1})" -f $waitSeconds, $(if ($SuccessorOf) { $SuccessorOf } else { 'unknown' })) }
    Start-Sleep -Milliseconds ([int]($waitSeconds * 1000))
}
if ($TriggeredBy) {
    $preflightNow = Get-Date
    $preflightState = Read-KeyCheckState -Path $StatePath
    $preflightLock = Get-KeyCheckLockState -Path $lockPath -Now $preflightNow -StaleSeconds $lockStaleSeconds
    $preflight = Get-KeyCheckSuccessorDecision -State $preflightState -Lock $preflightLock -Now $preflightNow
    $attemptId = $preflightNow.ToString('yyyyMMdd-HHmmss')
    $preflightAction = if ($preflight.Action -eq 'skip') { 'skipped' } else { 'started' }
    Write-KeyCheckAudit -Entry ([ordered]@{
            ts = $preflightNow.ToString('s'); runId = $attemptId; kind = 'successor'
            trigger = $TriggeredBy; action = $preflightAction; reason = $preflight.Reason
            detail = $preflight.Detail; parentRunId = $SuccessorOf
            holderRunId = $preflight.HolderRunId; priorRunId = $preflight.RunId
            priorPhase = $preflight.Phase; dryRun = [bool]$DryRun
        })
    if ($preflight.Action -eq 'skip') {
        if ($Json) {
            ([ordered]@{
                    successor = 'skipped'; trigger = $TriggeredBy; reason = $preflight.Reason
                    detail = $preflight.Detail; parentRunId = $SuccessorOf
                } | ConvertTo-Json -Compress)
        } else {
            Write-Output ("key-check: {0} start skipped - {1}" -f $TriggeredBy, $preflight.Detail)
        }
        Exit-KeyCheckRun -Code 0
    }
    if (-not $Json) {
        Write-Output ("[{0}] starting: {1} (run {2})" -f $TriggeredBy, $preflight.Detail, $(if ($SuccessorOf) { "after $SuccessorOf" } else { 'none' }))
    }
}

# --- fixture key values (test seam); the live path reads Machine -> User env ---
$script:KeyMap = $null
$script:InUseValue = ''
# Why the last usage read produced nothing. Empty on a healthy read; a named
# reason otherwise, so an empty census is never mistaken for "no key qualifies".
$script:UsageReadError = ''
if ($KeyValuesFile) {
    $kv = Get-Content -LiteralPath $KeyValuesFile -Raw | ConvertFrom-Json
    $script:KeyMap = @{}
    foreach ($p in $kv.keys.PSObject.Properties) { $script:KeyMap[$p.Name] = [string]$p.Value }
    if ($kv.PSObject.Properties['inUse']) { $script:InUseValue = [string]$kv.inUse }
}

function Invoke-KeyCheckRosterRecovery {
    <#
    .SYNOPSIS
        The post-cutover recovery pass: nudge the roster, then witness the
        machine. Safe to call from more than one survivor - the resume is
        idempotent per runId+agentId, so a second call sends nothing.
    #>
    param([string]$RosterPath, [string]$RecoveryRunId, [string]$Reason, [switch]$LogOnly)

    $result = [ordered]@{
        Ran = $false; ResumeOk = $false; WitnessOk = $false
        HubsNudged = 0; LanesNudged = 0; Resumed = 0; SkippedFinished = 0; SkippedAlready = 0
        WitnessVerdict = ''; Detail = ''
    }
    if ([string]::IsNullOrWhiteSpace($RosterPath) -or -not (Test-Path -LiteralPath $RosterPath)) {
        $result.Detail = 'roster-missing'
        return [pscustomobject]$result
    }
    $result.Ran = $true
    $resumePath = if ($ResumeScript) { $ResumeScript } else { Join-Path $scriptRoot 'Resume-KeyCheckRoster.ps1' }
    $witnessPath = if ($WitnessScript) { $WitnessScript } else { Join-Path $scriptRoot 'Invoke-KeyCheckWitness.ps1' }

    $resumeArgs = @('-NoProfile', '-File', $resumePath, '-RosterPath', $RosterPath,
        '-StateDir', $stateDir, '-AuditPath', $AuditPath, '-Json')
    if ($LogOnly) { $resumeArgs += '-LogOnly' }
    if ($AgentListFile) { $resumeArgs += @('-AgentListFile', $AgentListFile) }
    if ($AgentsDir) { $resumeArgs += @('-AgentsDir', $AgentsDir) }
    if ($SendScript) { $resumeArgs += @('-SendScript', $SendScript) }
    $raw = & pwsh @resumeArgs 2>&1 | Out-String
    $resumeCode = $LASTEXITCODE
    $result.ResumeOk = ($resumeCode -eq 0)
    if ($result.ResumeOk) {
        try {
            $summary = $raw | ConvertFrom-Json
            $result.HubsNudged = [int]$summary.counts.hubsNudged
            $result.LanesNudged = [int]$summary.counts.lanesNudged
            $result.Resumed = [int]$summary.counts.resumed
            $result.SkippedFinished = [int]$summary.counts.skippedFinished
            $result.SkippedAlready = [int]$summary.counts.skippedAlready
        } catch {
            $result.Detail = 'resume summary unparsable'
        }
    } else {
        Write-KeyCheckAudit -Entry ([ordered]@{
                ts = (Get-Date).ToString('s'); runId = $RecoveryRunId; kind = 'roster-resume-failed'
                reason = "resume exit $resumeCode`: $(([string]$raw).Trim())"; rosterPath = $RosterPath
                dryRun = [bool]$DryRun
            })
    }

    $outcomePath = if ($CutoverOutcomePath) { $CutoverOutcomePath }
                   else { Get-KeyCheckCutoverOutcomePath -Dir $stateDir -RunId $RecoveryRunId }
    $witnessArgs = @('-NoProfile', '-File', $witnessPath, '-RunId', $RecoveryRunId,
        '-OutcomePath', $outcomePath, '-StateDir', $stateDir, '-AuditPath', $AuditPath, '-Json')
    $witnessRaw = & pwsh @witnessArgs 2>&1 | Out-String
    $witnessCode = $LASTEXITCODE
    $witnessFile = Join-Path $stateDir "witness-$RecoveryRunId.json"
    if (Test-Path -LiteralPath $witnessFile) {
        try {
            $report = Get-Content -LiteralPath $witnessFile -Raw | ConvertFrom-Json
            $result.WitnessVerdict = [string]$report.verdict
            $result.WitnessOk = $true
        } catch { }
    }
    if (-not $result.WitnessOk -and $witnessCode -notin @(0, 1)) {
        Write-KeyCheckAudit -Entry ([ordered]@{
                ts = (Get-Date).ToString('s'); runId = $RecoveryRunId; kind = 'witness-failed'
                reason = "witness exit $witnessCode`: $(([string]$witnessRaw).Trim())"; dryRun = [bool]$DryRun
            })
    }

    Write-KeyCheckAudit -Entry ([ordered]@{
            ts = (Get-Date).ToString('s'); runId = $RecoveryRunId; kind = 'cutover-recovery'
            phase = 'initial'; reason = $Reason
            hubsNudged = $result.HubsNudged; lanesNudged = $result.LanesNudged
            resumed = $result.Resumed; skippedFinished = $result.SkippedFinished
            skippedAlready = $result.SkippedAlready
            witnessVerdict = $result.WitnessVerdict; rosterPath = $RosterPath
            dryRun = [bool]$DryRun
        })
    if (-not $Json) {
        Write-Output ("[recovery] {0}: resumed {1} (hub {2}, lane {3}); witness {4}" -f `
                $Reason, $result.Resumed, $result.HubsNudged, $result.LanesNudged,
                $(if ($result.WitnessVerdict) { $result.WitnessVerdict } else { 'unavailable' }))
    }
    return [pscustomobject]$result
}

function Invoke-KeyCheckRecoveryOnce {
    <#
    .SYNOPSIS
        Run the roster recovery for a cutover run at most once in this process.
    #>
    param([string]$RosterPath, [string]$RecoveryRunId, [string]$Reason, [switch]$LogOnly)
    if ($NoRecovery) { return $null }
    if ($script:RecoveredRunIds -contains $RecoveryRunId) { return $null }
    $script:RecoveredRunIds += $RecoveryRunId
    return (Invoke-KeyCheckRosterRecovery -RosterPath $RosterPath -RecoveryRunId $RecoveryRunId -Reason $Reason -LogOnly:$LogOnly)
}

function Get-KeyCheckPoolNumbers {
    if ($script:KeyMap) {
        return @($script:KeyMap.Keys | ForEach-Object { if ($_ -match '^GO(\d+)$') { [int]$Matches[1] } } | Sort-Object)
    }
    $numbers = [System.Collections.Generic.SortedSet[int]]::new()
    foreach ($scope in @('Machine', 'User')) {
        $bag = [Environment]::GetEnvironmentVariables($scope)
        foreach ($name in $bag.Keys) {
            if ($name -match '^OPENCODE_GO(\d+)_KEY$' -and -not [string]::IsNullOrWhiteSpace($bag[$name])) {
                [void]$numbers.Add([int]$Matches[1])
            }
        }
    }
    return @($numbers)
}

function Get-KeyCheckKeyValue {
    param([int]$Number)
    if ($script:KeyMap) {
        $name = "GO$Number"
        if ($script:KeyMap.ContainsKey($name)) { return [string]$script:KeyMap[$name] }
        return ''
    }
    return Get-PoolKeyValue -Number $Number
}

function Get-KeyCheckInUseValue {
    if (-not [string]::IsNullOrWhiteSpace($script:InUseValue)) { return $script:InUseValue }
    foreach ($scope in @('User', 'Process')) {
        $v = [Environment]::GetEnvironmentVariable('OPENCODE_GO_KEY', $scope)
        if (-not [string]::IsNullOrWhiteSpace($v)) { return $v }
    }
    return ''
}

function Get-KeyCheckSeamActiveNumber {
    # The seam's `activeKey` is a NAME (OPENCODE_GO3_KEY), not a value.
    $seamPath = if ($SeamPath) { $SeamPath } else { Join-Path $scriptRoot '..\assets\opencode-go-cutover.json' }
    if (-not (Test-Path -LiteralPath $seamPath)) { return 0 }
    try {
        $seam = Get-Content -LiteralPath $seamPath -Raw | ConvertFrom-Json
        if ([string]$seam.activeKey -match '^OPENCODE_GO(\d+)_KEY$') { return [int]$Matches[1] }
    } catch { }
    return 0
}

function Get-KeyCheckSeamActiveName {
    $seamPath = if ($SeamPath) { $SeamPath } else { Join-Path $scriptRoot '..\assets\opencode-go-cutover.json' }
    if (-not (Test-Path -LiteralPath $seamPath)) { return '<seam-missing>' }
    try {
        $seam = Get-Content -LiteralPath $seamPath -Raw | ConvertFrom-Json
        return [string]$seam.activeKey
    } catch {
        return '<seam-unreadable>'
    }
}

function Get-KeyCheckPoolLabel {
    <#
    .SYNOPSIS
        GO<n> for a key value, by fingerprint. Never returns or prints the value.
    #>
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return 'no-value' }
    foreach ($entry in (Get-KeyCheckKeyEntries)) {
        if (Test-SecretEqual -A $entry.Value -B $Value) { return "GO$($entry.KeyNumber)" }
    }
    return 'no-pool-match'
}

function Get-KeyCheckPaseoPinLabel {
    <#
    .SYNOPSIS
        The pool label the Paseo provider pin points at, or no-pin.
    #>
    $configPath = if ($PaseoConfig) { $PaseoConfig } else { Join-Path $env:USERPROFILE '.paseo\config.json' }
    foreach ($provider in @('opencode', 'opencode-go')) {
        try {
            $value = Get-PaseoProviderEnvValue -Provider $provider -EnvName 'OPENCODE_GO_KEY' -ConfigPath $configPath
        } catch { $value = '' }
        if (-not [string]::IsNullOrWhiteSpace($value)) { return (Get-KeyCheckPoolLabel -Value $value) }
    }
    return 'no-pin'
}

function Get-KeyCheckKeyEntries {
    # Every (key number, scope, value) the in-use value can be matched against.
    # Machine and User are BOTH checked per key: a staged User copy must not be
    # shadowed by an older Machine value, or hash resolution silently fails.
    if ($script:KeyMap) {
        foreach ($n in (Get-KeyCheckPoolNumbers)) {
            [pscustomobject]@{ KeyNumber = $n; Scope = 'fixture'; Value = (Get-KeyCheckKeyValue -Number $n) }
        }
        return
    }
    foreach ($n in (Get-KeyCheckPoolNumbers)) {
        foreach ($scope in @('Machine', 'User')) {
            $value = [Environment]::GetEnvironmentVariable("OPENCODE_GO${n}_KEY", $scope)
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                [pscustomobject]@{ KeyNumber = $n; Scope = $scope; Value = $value }
            }
        }
    }
}

function Resolve-KeyCheckActive {
    $inUse = Get-KeyCheckInUseValue
    if (-not [string]::IsNullOrWhiteSpace($inUse)) {
        foreach ($entry in (Get-KeyCheckKeyEntries)) {
            if (Test-SecretEqual -A $entry.Value -B $inUse) {
                return [pscustomobject]@{ KeyNumber = $entry.KeyNumber; How = "hash-match ($($entry.Scope))" }
            }
        }
    }
    $seamNumber = Get-KeyCheckSeamActiveNumber
    if ($seamNumber -gt 0) {
        return [pscustomobject]@{ KeyNumber = $seamNumber; How = 'seam-activeKey' }
    }
    return [pscustomobject]@{ KeyNumber = 0; How = 'unresolved' }
}

# ------------------------------------------------------------ resume + lock ---
$now = Get-Date
# A dry run rehearses the LIVE run, so it reads the live state; it resolves its
# own write path above and can never write back to it.
$previousState = Read-KeyCheckState -Path $liveStatePath
$previousOutcome = $null
if ($null -ne $previousState -and $previousState.PSObject.Properties['runId'] -and $previousState.runId) {
    $resumeOutcomePath = if ($CutoverOutcomePath) { $CutoverOutcomePath }
                         else { Get-KeyCheckCutoverOutcomePath -Dir $stateDir -RunId ([string]$previousState.runId) }
    if (Test-Path -LiteralPath $resumeOutcomePath) {
        try { $previousOutcome = Get-Content -LiteralPath $resumeOutcomePath -Raw | ConvertFrom-Json } catch { $previousOutcome = $null }
    }
}
$verifyCutoverOutcome = {
    # Re-derive every surface from the machine. A pending outcome is a request
    # to finish the check, never a result.
    param($Outcome)
    $number = if ($null -ne $Outcome -and $Outcome.PSObject.Properties['keyNumber']) { [int]$Outcome.keyNumber } else { 0 }
    $expected = if ($number -gt 0) { "GO$number" } else { 'GO?' }
    $seam = Get-KeyCheckSeamActiveName
    $resolved = Resolve-KeyCheckActive
    $user = if ($resolved.KeyNumber -gt 0) { "GO$($resolved.KeyNumber)" } else { 'unresolved' }
    $pin = Get-KeyCheckPaseoPinLabel
    $ok = ($number -gt 0 -and
        $seam -eq "OPENCODE_GO${number}_KEY" -and
        $user -eq $expected -and
        $pin -eq $expected)
    [pscustomobject]@{ Verified = $ok; Detail = "seam=$seam user=$user pin=$pin expected=$expected" }
}
$resume = Get-KeyCheckResumeDecision -State $previousState -Outcome $previousOutcome -Now $now `
    -VerifyOutcome $verifyCutoverOutcome

# ---- the LIVE in-use key is the only truth about which key this machine runs ---
# Resolution is a MEASUREMENT, taken on EVERY start - never inherited from the
# state file. Measured defect (cl-common-o1t): after an operator switched the
# fleet from GO3 to GO1 the resumed watch re-verified the OLD key, kept
# state.activeKeyNumber = 3, audited `resumed: resumed-cutover-verified GO3 ->
# GO3` against a seam that says GO1, and measured GO3's 42wk/74mo. The fleet ran
# on GO1 while the watch measured GO3, so a real GO1 cap would never have
# triggered a cutover - silent blindness in the component whose job is to see.
$liveActive = Resolve-KeyCheckActive

# A cutover outcome describes the machine at the moment the helper wrote it. If
# the in-use key has moved since, repeating its verdict is a lie; name the live
# change instead and let the live sync (below) move the state.
$priorActiveKey = if ($null -ne $previousState -and $previousState.PSObject.Properties['activeKeyNumber']) {
    [int]$previousState.activeKeyNumber
} else { 0 }
# Captured BEFORE the state object is mutated below: $resume.State IS
# $previousState, so reading it later would read the value this run just wrote.
$priorGeneration = if ($null -ne $previousState -and $previousState.PSObject.Properties['generation']) {
    [int]$previousState.generation
} else { 0 }
$resumeOutcomeKey = if ($resume.PSObject.Properties['ActiveKeyNumber'] -and $null -ne $resume.ActiveKeyNumber) {
    [int]$resume.ActiveKeyNumber
} else { 0 }
$resumeOutcomeStale = ($resume.Action -eq 'resume' -and $resumeOutcomeKey -gt 0 -and
    $liveActive.KeyNumber -gt 0 -and $liveActive.KeyNumber -ne $resumeOutcomeKey)
if ($resumeOutcomeStale) {
    $changeText = if ($priorActiveKey -gt 0 -and $priorActiveKey -ne $liveActive.KeyNumber) {
        "active-key-changed GO$priorActiveKey -> GO$($liveActive.KeyNumber)"
    } else {
        "active-key-unchanged GO$($liveActive.KeyNumber)"
    }
    $resume | Add-Member -NotePropertyName Reason -NotePropertyValue ("{0}: the live in-use key resolved via {1}; the verified outcome for GO{2} no longer describes this machine" -f `
            $changeText, $liveActive.How, $resumeOutcomeKey) -Force
    $resume | Add-Member -NotePropertyName OutcomeStale -NotePropertyValue $true -Force
}

$start = $now
$deadline = Get-KeyCheckDeadline -Start $start -DurationHours $DurationHours
$runId = $start.ToString('yyyyMMdd-HHmmss')
if ($resume.Action -eq 'resume') {
    # Original start and ORIGINAL deadline. A resume may never add time.
    $runId = $resume.RunId
    $start = $resume.StartedAt
    $deadline = $resume.Deadline
}
# A dry run is never the run it rehearses: its identity is stamped so neither a
# human reading the audit nor a script matching runIds can confuse the two.
if ($DryRun) { $runId = "$runId-dryrun" }
$script:DryRunRehearsedRunId = if ($DryRun -and $resume.Action -eq 'resume') { [string]$resume.RunId } else { '' }

# -NoWait is a TEST SEAM, not a production mode: with no per-check delay it
# spins as fast as the usage endpoint answers (measured: 731 checks in ~15
# minutes). Bound it, so a forgotten -MaxChecks cannot burn a key's quota in a
# tight loop - and say so in the audit instead of pretending a watch ran.
if ($NoWait -and $MaxChecks -le 0) {
    $MaxChecks = 240
    Write-KeyCheckAudit -Entry ([ordered]@{
            ts = (Get-Date).ToString('s'); runId = $runId; kind = 'note'; phase = 'initial'
            reason = "nowait-bounded: -NoWait has no inter-check delay; the run is capped at $MaxChecks checks instead of spinning until the deadline"
            dryRun = [bool]$DryRun
        })
    if (-not $Json) { Write-Warning "key-check: -NoWait without -MaxChecks spins; capped at $MaxChecks checks" }
}

$script:LockRunId = $runId
if (-not $DryRun) {
    $lock = Enter-KeyCheckLock -Path $lockPath -RunId $runId -StaleSeconds $lockStaleSeconds -Now $now -Force:$Force
    if (-not $lock.Acquired) {
        $holderRun = if ($null -ne $lock.Holder -and $lock.Holder.PSObject.Properties['runId']) { [string]$lock.Holder.runId } else { 'unknown' }
        $holderPid = if ($null -ne $lock.Holder -and $lock.Holder.PSObject.Properties['pid']) { [string]$lock.Holder.pid } else { '?' }
        $message = "key-check: locked-by-run - run $holderRun (pid $holderPid) has held the lock for $($lock.HolderAgeSeconds)s; if that run is gone, re-run with -Force"
        [Console]::Error.WriteLine($message)
        Write-KeyCheckAudit -Entry ([ordered]@{
                ts = (Get-Date).ToString('s'); runId = $runId; kind = 'lock'; phase = 'initial'
                decision = 'end'; reason = 'locked-by-run'
                holderRunId = $holderRun; holderPid = $holderPid; holderAgeSeconds = $lock.HolderAgeSeconds
                dryRun = [bool]$DryRun
            })
        $script:LockHeld = $false
        exit 2
    }
    $script:LockHeld = $true
    if ($lock.TakenOver) {
        $prior = if ($null -ne $lock.Holder -and $lock.Holder.PSObject.Properties['runId']) { [string]$lock.Holder.runId } else { 'unknown' }
        $reason = if ($Force) { 'lock-forced: a live lock was stolen deliberately (-Force)' }
                  else { "lock-stale-taken-over: $($lock.PriorReason) (holder run $prior, age $($lock.HolderAgeSeconds)s)" }
        Write-KeyCheckAudit -Entry ([ordered]@{
                ts = (Get-Date).ToString('s'); runId = $runId; kind = 'lock'; phase = 'initial'
                decision = 'acquired'; reason = $reason
                holderRunId = $prior; holderAgeSeconds = $lock.HolderAgeSeconds; dryRun = [bool]$DryRun
            })
        if (-not $Json) { Write-Output "[lock] $reason" }
    }
}

# A pending outcome that this run just finished verifying is upgraded on disk,
# so a third invocation is not asked to prove the same cutover again.
if ($resume.Action -eq 'resume' -and $resume.PSObject.Properties['UpgradeOutcome'] -and $resume.UpgradeOutcome) {
    $upgradePath = if ($CutoverOutcomePath) { $CutoverOutcomePath }
                   else { Get-KeyCheckCutoverOutcomePath -Dir $stateDir -RunId $resume.RunId }
    $upgraded = Set-KeyCheckCutoverOutcomeVerified -Path $upgradePath -Detail $resume.Reason
    Write-KeyCheckAudit -Entry ([ordered]@{
            ts = (Get-Date).ToString('s'); runId = $resume.RunId; kind = 'cutover'; phase = 'trigger'
            verified = 'verified-after-restart'; restartPending = $false
            upgraded = [bool]$upgraded; detail = $resume.Reason; dryRun = [bool]$DryRun
        })
    if (-not $Json) { Write-Output "[resume] cutover outcome upgraded to verified: $($resume.Reason)" }

    # The watch survived (or finished) a cutover: whoever is here now nudges the
    # roster the helper captured, then witnesses the machine.
    $rosterFile = ''
    if ($null -ne $previousOutcome -and $previousOutcome.PSObject.Properties['rosterPath']) {
        $rosterFile = [string]$previousOutcome.rosterPath
    }
    if ($rosterFile) {
        $null = Invoke-KeyCheckRecoveryOnce -RosterPath $rosterFile -RecoveryRunId $resume.RunId `
            -Reason 'verified-after-restart' -LogOnly:$DryRun
    }
}

# ---- hub self-check: a cutover that happened while this run was down -------
# Any process can read last-cutover.json without knowing a runId. A marker
# newer than this run's start means children may be stranded: recover before
# any further checks. The pass is idempotent, so a second reader sends nothing.
if (-not $NoRecovery) {
    $markerPath = Join-Path $stateDir 'last-cutover.json'
    if (Test-Path -LiteralPath $markerPath) {
        $marker = $null
        try { $marker = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json } catch { $marker = $null }
        if ($null -ne $marker) {
            $markerAt = $null
            try { $markerAt = [datetime]::Parse([string]$marker.at) } catch { $markerAt = $null }
            $markerRoster = if ($marker.PSObject.Properties['rosterPath']) { [string]$marker.rosterPath } else { '' }
            $markerRunId = if ($marker.PSObject.Properties['runId'] -and $marker.runId) { [string]$marker.runId } else { $runId }
            if ($null -ne $markerAt -and $markerAt -gt $start -and $markerRoster -and (Test-Path -LiteralPath $markerRoster)) {
                $null = Invoke-KeyCheckRecoveryOnce -RosterPath $markerRoster -RecoveryRunId $markerRunId `
                    -Reason 'cutover-marker' -LogOnly:$DryRun
            }
        }
    }
}

# ---- endings that a resumed state already decides, before any polling ----
if ($resume.Action -in @('expired', 'cutover-failed', 'cutover-unproven')) {
    $prior = $resume.State
    $prior | Add-Member -NotePropertyName phase -NotePropertyValue 'end' -Force
    $prior | Add-Member -NotePropertyName endedAt -NotePropertyValue ((Get-Date).ToString('o')) -Force
    $prior | Add-Member -NotePropertyName endReason -NotePropertyValue ($(if ($resume.Action -eq 'expired') { 'window-expired-while-down' } else { $resume.Action })) -Force
    $code = switch ($resume.Action) { 'cutover-failed' { 4 } 'cutover-unproven' { 5 } default { 0 } }
    $prior | Add-Member -NotePropertyName exitCode -NotePropertyValue $code -Force
    $prior | Add-Member -NotePropertyName evidence -NotePropertyValue (@($prior.evidence) + @($resume.Reason)) -Force
    # A window that closed while nothing ran is ALSO a handover, not a finish:
    # this process is the last one that knows the watch lapsed, so it arms the
    # successor rather than leaving the gap for a human to notice (cl-common-0ai).
    $successor = $null
    if ($resume.Action -eq 'expired' -and
        (Test-KeyCheckShouldArmSuccessor -EndReason 'deadline' -DryRun:$DryRun -NoWait:$NoWait -NoSuccessor:$NoSuccessor)) {
        $successor = Start-KeyCheckSuccessor -GraceSeconds $SuccessorGraceSeconds
        $prior | Add-Member -NotePropertyName evidence -NotePropertyValue (@($prior.evidence) + @(
                "successor: $($successor.trigger) $(if ($successor.armed) { "armed pid $($successor.pid) for $($successor.fireAt)" } else { "NOT armed ($($successor.detail))" })"
            )) -Force
    }
    $prior | Add-Member -NotePropertyName successor -NotePropertyValue $successor -Force
    Write-KeyCheckState -Path $StatePath -State $prior
    Write-KeyCheckAudit -Entry ([ordered]@{
            ts = (Get-Date).ToString('s'); runId = $runId; kind = 'end'; phase = 'end'
            decision = 'end'; reason = $resume.Reason; generation = [int]$resume.Generation
            dryRun = [bool]$DryRun
        })
    if (-not $Json) { Write-Output "key-check $runId`: $($resume.Reason) (the run was down when this happened)" }
    else { $prior | ConvertTo-Json -Depth 16 }
    Exit-KeyCheckRun -Code $code
}


function Read-UsageFixture {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        $script:UsageReadError = "usage fixture not found: $Path"
        return @()
    }
    $parsed = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    # Plain array, not List[object]: @(<generic list>) throws "Argument types do
    # not match" on this PowerShell.
    $rows = @()
    foreach ($item in @($parsed)) {
        if ($null -eq $item) { continue }
        if ($item.PSObject.Properties['Key'] -or $item.PSObject.Properties['KeyNumber']) { $rows += $item; continue }
        foreach ($p in $item.PSObject.Properties) {
            if ($p.Name -match '^(?:GO)?(\d+)$') {
                $rows += [pscustomobject]@{
                    Key = "GO$($Matches[1])"; Http = 200; Verdict = ''
                    Weekly = $p.Value.weekly; Monthly = $p.Value.monthly
                }
            }
        }
    }
    return $rows
}

function Get-UsageRowsViaHttp {
    param([int[]]$KeyNumbers = @())
    $numbers = if ($KeyNumbers.Count -gt 0) { $KeyNumbers } else { @(Get-KeyCheckPoolNumbers) }
    $url = if ($BaseUrl -match '/usage') { $BaseUrl } else { $BaseUrl.TrimEnd('/') + '/usage' }
    $rows = @()
    foreach ($n in $numbers) {
        $value = Get-KeyCheckKeyValue -Number $n
        if ([string]::IsNullOrWhiteSpace($value)) { continue }
        try {
            $response = Invoke-WebRequest -Uri $url -Method GET -SkipHttpErrorCheck -TimeoutSec $TimeoutSeconds -Headers @{
                Authorization        = "Bearer $value"
                'User-Agent'         = 'cl-fleet-keycheck/1.0'
                'x-opencode-session' = 'cl-fleet-keycheck'
            }
            $http = [int]$response.StatusCode
            if ($http -eq 200) {
                $body = [string]$response.Content | ConvertFrom-Json
                $rows += [pscustomobject]@{
                    Key = "GO$n"; Http = $http; Verdict = ''
                    Weekly = $body.usage.weekly; Monthly = $body.usage.monthly
                }
            } else {
                $rows += [pscustomobject]@{
                    Key = "GO$n"; Http = $http; Verdict = "HTTP $http"
                    Weekly = $null; Monthly = $null
                }
            }
        } catch {
            $rows += [pscustomobject]@{
                Key = "GO$n"; Http = 0; Verdict = 'ERROR'
                Weekly = $null; Monthly = $null
            }
        }
    }
    return $rows
}

function Get-UsageRows {
    param([int[]]$KeyNumbers = @())
    $script:UsageReadError = ''
    if ($UsageFile) {
        $all = @(Read-UsageFixture -Path $UsageFile)
        if ($KeyNumbers.Count -eq 0) { return $all }
        return @($all | Where-Object {
                $reading = ConvertTo-KeyCheckReading -Row $_
                $null -ne $reading -and $KeyNumbers -contains $reading.KeyNumber
            })
    }
    if ($BaseUrl) { return @(Get-UsageRowsViaHttp -KeyNumbers $KeyNumbers) }
    if ($KeyNumbers.Count -gt 1) {
        $all = @(Get-UsageRows)
        return @($all | Where-Object {
                $reading = ConvertTo-KeyCheckReading -Row $_
                $null -ne $reading -and $KeyNumbers -contains $reading.KeyNumber
            })
    }
    $cliArgs = @('-NoProfile', '-File', (Join-Path $scriptRoot 'Get-GoKeyUsage.ps1'), '-Json', '-TimeoutSeconds', "$TimeoutSeconds")
    if ($KeyNumbers.Count -eq 1 -and $KeyNumbers[0] -gt 0) { $cliArgs += @('-KeyNumber', "$($KeyNumbers[0])") }
    $raw = & pwsh @cliArgs 2>&1 | Out-String
    if ([string]::IsNullOrWhiteSpace($raw)) {
        $script:UsageReadError = 'Get-GoKeyUsage.ps1 returned no output'
        return @()
    }
    try { return @($raw | ConvertFrom-Json) } catch {
        # Named, not swallowed: the census reports this instead of an empty list
        # that reads as "no key was eligible".
        $script:UsageReadError = "Get-GoKeyUsage.ps1 output unparsable: $($_.Exception.Message)"
        return @()
    }
}

function Format-KeyCheckExclusionLine {
    <#
    .SYNOPSIS
        One line naming every excluded candidate and the rule that excluded it.
    #>
    param([object[]]$Rejected = @(), [object[]]$Unreadable = @())
    $parts = @()
    foreach ($r in @($Rejected)) { $parts += "$($r.Label)=$($r.Rule)" }
    foreach ($u in @($Unreadable)) { $parts += "$($u.Label)=$($u.Rule)" }
    if ($parts.Count -eq 0) { return 'none' }
    return ($parts -join ', ')
}

function Get-KeyCheckCensus {
    <#
    .SYNOPSIS
        The ONE live census read: `initial` and `discover` both consume this.
    .DESCRIPTION
        Returns the normalised readings plus a per-key cannot-evaluate list for
        rows the reader answered but could not measure, and for a read that
        produced nothing at all (with the named read error). Never a second code
        path and never a silent catch: an absent input becomes a named reason.
    #>
    $rows = @(Get-UsageRows)
    $readings = @(ConvertTo-Readings -Rows $rows)
    $unreadable = @()
    foreach ($row in $rows) {
        if ($null -eq (ConvertTo-KeyCheckReading -Row $row)) {
            $label = if ($null -ne $row -and $row.PSObject.Properties['Key'] -and $row.Key) { [string]$row.Key } else { '?' }
            $why = if ($null -ne $row -and $row.PSObject.Properties['Verdict'] -and $row.Verdict) { [string]$row.Verdict } else { 'unreadable-row' }
            $unreadable += [pscustomobject]@{ Label = $label; Rule = "cannot-evaluate:$why" }
        }
    }
    if ($rows.Count -eq 0) {
        $why = if ($script:UsageReadError) { $script:UsageReadError } else { 'usage-read-returned-nothing' }
        $unreadable += [pscustomobject]@{ Label = '*'; Rule = "cannot-evaluate:$why" }
    }
    return [pscustomobject]@{ Readings = $readings; Unreadable = $unreadable }
}

function ConvertTo-Readings {
    param($Rows)
    $out = @()
    foreach ($row in @($Rows)) {
        $reading = ConvertTo-KeyCheckReading -Row $row
        if ($null -ne $reading) { $out += $reading }
    }
    return $out
}

function Get-KeyCheckReadingByNumber {
    param([object[]]$Readings, [int]$KeyNumber)
    return (@($Readings) | Where-Object { $null -ne $_ -and $_.KeyNumber -eq $KeyNumber } | Select-Object -First 1)
}

function Get-KeyCheckActiveReading {
    # In a dry run nothing actually moves, so polling follows the key the cutover
    # WOULD have chosen; the real in-use key stays in activeKeyNumber.
    $number = if ($DryRun -and [int]$state.simulatedActiveKeyNumber -gt 0) {
        [int]$state.simulatedActiveKeyNumber
    } else {
        [int]$state.activeKeyNumber
    }
    if ($number -le 0) { return $null }
    $rows = Get-UsageRows -KeyNumbers @($number)
    return (Get-KeyCheckReadingByNumber -Readings @(ConvertTo-Readings -Rows $rows) -KeyNumber $number)
}

function Get-KeyCheckCannotEvaluateReason {
    <#
    .SYNOPSIS
        The named reason a poll produced no reading for the active key.
    .DESCRIPTION
        An absent input is a named reason, never the shrug `no-reading`: it says
        whether the reader failed (and how) or whether the active key was simply
        absent from an otherwise healthy census.
    #>
    param([int]$KeyNumber = 0)
    if ($script:UsageReadError) { return "cannot-evaluate: $($script:UsageReadError)" }
    if ($KeyNumber -gt 0) { return "cannot-evaluate: active key GO$KeyNumber not in the census" }
    return 'cannot-evaluate: no reading for the active key'
}

function Get-KeyCheckDecisionReason {
    <#
    .SYNOPSIS
        The audit reason for a decision, naming a failed read instead of a shrug.
    #>
    param($Decision, [int]$KeyNumber = 0)
    if ($Decision.Reason -eq 'no-reading') { return (Get-KeyCheckCannotEvaluateReason -KeyNumber $KeyNumber) }
    return $Decision.Reason
}

function Get-KeyCheckSleepSeconds {
    param([double]$Seconds, [datetime]$Deadline)
    $remaining = ($Deadline - (Get-Date)).TotalSeconds
    if ($remaining -le 0) { return 0 }
    return [Math]::Min($Seconds, $remaining)
}

function Update-KeyCheckReadCounters {
    <#
    .SYNOPSIS
        Fold one poll's outcome into the tolerances that gate the next decision.
    .DESCRIPTION
        - A read that produced NO reading is a cannot-evaluate: it neither
          proves the key healthy nor resets a streak.
        - A rate-limited read (429, or a 429 window) increments its own streak;
          any other readable check resets it (E2: only the second consecutive
          429 is a trigger).
        - A reading inside the disarm band increments the below-threshold
          streak; anything else resets it (E1: two in a row to disarm).
    #>
    param($Reading)

    if ($null -eq $Reading) {
        $state.consecutiveCannotEvaluate = [int]$state.consecutiveCannotEvaluate + 1
        return
    }
    $state.consecutiveCannotEvaluate = 0

    if (Test-KeyCheckRateLimited -Reading $Reading) {
        $state.consecutiveRateLimited = [int]$state.consecutiveRateLimited + 1
    } else {
        $state.consecutiveRateLimited = 0
    }

    if (Test-KeyCheckDisarm -Reading $Reading) {
        $state.consecutiveBelowThreshold = [int]$state.consecutiveBelowThreshold + 1
    } else {
        $state.consecutiveBelowThreshold = 0
    }
}

function Save-KeyCheckState {
    Write-KeyCheckState -Path $StatePath -State $state
    if ($script:LockHeld) { $null = Update-KeyCheckLockHeartbeat -Path $lockPath -RunId $script:LockRunId }
}

function Update-KeyCheckCadenceForReading {
    <#
    .SYNOPSIS
        Re-derive the poll gear from this tick's reading and audit a change.
    .DESCRIPTION
        The history lives in the STATE FILE (`lastReading` + `lastCheckAt` +
        `cadenceSamples`), not in a local, so a resumed run keeps the burn it
        measured before it died. Call this BEFORE Write-KeyCheckCheck, which
        overwrites both fields.

        Two facts come from the persisted state, never from a guess:
          - a GENERATION the ring was not recorded under is a rescue: the gear
            returns to the phase ceiling and the change is audited
            (`generation-reset`), so a fresh key never inherits a 1-minute gear;
          - the last MEASURED ETT (`ettMinutes`) is passed through so a tick that
            cannot measure fresh burn cannot hold a gear faster than it implies.

        A gear change is audited exactly once, here; an unchanged gear writes
        nothing, which is what keeps the audit trail readable.
    #>
    param($Reading, [string]$Phase = 'heartbeat')

    if ($null -eq $Reading) { return }
    $now = Get-Date
    $generationReset = ([int]$state.generation -ne [int]$state.cadenceSampleGeneration)
    $priorEtt = if ($state.PSObject.Properties['ettMinutes'] -and $null -ne $state.ettMinutes) { [double]$state.ettMinutes } else { $null }
    # Append this tick to the per-meter HISTORY first, then measure the burn over
    # the oldest sample that clears the guard window. "The previous poll" alone
    # cannot do that once the gear is faster than 15 minutes (cl-common-6yr).
    $step = Add-KeyCheckCadenceSample -Samples $state.cadenceSamples -Reading $Reading -Now $now `
        -Generation ([int]$state.generation) -PreviousGeneration ([int]$state.cadenceSampleGeneration) `
        -PreviousSignature ([string]$state.cadenceSampleSignature) `
        -Previous $state.lastReading -PreviousAt $state.lastCheckAt
    $decision = Get-KeyCheckCadenceGear -Samples $step.Samples -Previous $state.lastReading -Current $Reading `
        -LastCheckAt $state.lastCheckAt -Now $now `
        -PreviousGear ([string]$state.cadenceGear) -PreviousSeconds ([int]$state.cadenceSeconds) `
        -BaseSeconds $cadenceBaseSeconds `
        -LoosenStreak ([int]$state.cadenceLoosenStreak) -FloorTicks ([int]$state.cadenceFloorTicks) `
        -Phase $Phase -GenerationReset:$generationReset -PriorEttMinutes $priorEtt

    $entry = Update-KeyCheckCadence -State $state -Decision $decision -Now $now -RunId $runId `
        -Samples $step.Samples -SampleSignature $step.Signature -SampleGeneration $step.Generation `
        -Phase $Phase
    if ($null -eq $entry) { return }
    Write-KeyCheckAudit -Entry $entry
    if (-not $Json) {
        Write-Output ("[cadence] {0} {1}s -> {2}s: {3} (burn {4}/min, ETT {5} min, {6} points left)" -f `
                $Phase, $entry.fromSeconds, $entry.toSeconds, $entry.reason, $entry.burnPerMinute, $entry.ettMinutes, $entry.remaining)
    }
}

function Write-KeyCheckCheck {
    param([string]$Phase, $Reading, [string]$Decision, [string]$Reason, [switch]$KeepLastReading)
    $state.checks = [int]$state.checks + 1
    $state.phase = $Phase
    $state.lastCheckAt = (Get-Date).ToString('o')
    $state.lastResult = "$Decision ($Reason)"
    # Discovery reports the ARMED replacement's reading; that must not overwrite
    # "last reading of the active key".
    if ($null -ne $Reading -and -not $KeepLastReading) { $state.lastReading = $Reading }
    $entry = [ordered]@{
        ts         = (Get-Date).ToString('s')
        runId      = $runId
        kind       = 'check'
        phase      = $Phase
        generation = $state.generation
        key        = $(if ($null -ne $Reading) { $Reading.Label } else { '-' })
        wk         = $(if ($null -ne $Reading -and $null -ne $Reading.Weekly.Percent) { [int]$Reading.Weekly.Percent } else { $null })
        mo         = $(if ($null -ne $Reading -and $null -ne $Reading.Monthly.Percent) { [int]$Reading.Monthly.Percent } else { $null })
        decision   = $Decision
        reason     = $Reason
        rateLimitedStreak       = [int]$state.consecutiveRateLimited
        cannotEvaluateStreak    = [int]$state.consecutiveCannotEvaluate
        belowThresholdStreak    = [int]$state.consecutiveBelowThreshold
        dryRun     = [bool]$DryRun
    }
    Write-KeyCheckAudit -Entry $entry
    if (-not $Json) {
        $tag = if ($null -ne $Reading -and $state.activeKeyNumber -eq $Reading.KeyNumber) { 'active' } else { '' }
        Write-Output ("[{0}] {1} -> {2} ({3})" -f $Phase, (Format-KeyCheckReading -Reading $Reading -Tag $tag), $Decision, $Reason)
    }
    Save-KeyCheckState
}

function Get-KeyCheckDrift {
    if ($SkipDrift) { return [pscustomobject]@{ Checked = $false; ExitCode = $null; Detail = 'skipped' } }
    try {
        $out = & pwsh -NoProfile -File (Join-Path $scriptRoot 'Invoke-ProviderLock.ps1') -Mode Status 2>&1 | Out-String
        $code = $LASTEXITCODE
        $line = ($out -split "`n" | Where-Object { $_ -match 'Summary:' } | Select-Object -Last 1)
        if (-not $line) { $line = ($out -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 1) }
        return [pscustomobject]@{ Checked = $true; ExitCode = $code; Detail = ([string]$line).Trim() }
    } catch {
        return [pscustomobject]@{ Checked = $true; ExitCode = -1; Detail = $_.Exception.Message }
    }
}

function Invoke-KeyCheckCanary {
    param([int]$KeyNumber)
    # Ok means "not disproven". A skipped or unknown key is never recorded as OK,
    # and a skipped canary arms the replacement without proof (that is what
    # -SkipCanary asks for).
    if ($SkipCanary -or $KeyNumber -le 0) {
        return [pscustomobject]@{ Ran = $false; Ok = $true; Verdict = 'skipped'; ExitCode = $null }
    }
    $canary = if ($CanaryScript) { $CanaryScript } else { Join-Path $scriptRoot 'Test-GoKey.ps1' }
    $out = & pwsh -NoProfile -File $canary -KeyNumber $KeyNumber 2>&1 | Out-String
    $code = $LASTEXITCODE
    $verdict = ([string](($out -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 1))).Trim()
    return [pscustomobject]@{
        Ran = $true; Ok = ($code -eq 0 -and $verdict -match '^OK'); Verdict = $verdict; ExitCode = $code
    }
}

function Invoke-KeyCheckCutover {
    <#
    .SYNOPSIS
        Delegate the cutover to a helper created OUTSIDE this process tree, and
        read the outcome file it writes.
    .DESCRIPTION
        The helper should outlive the watch: the Paseo repair ends every
        Paseo-hosted session, this one included. It is created with
        Win32_Process.Create because that child is outside this process's job
        object by construction, and the watch polls the outcome file it writes.

        Survival is not the load-bearing property. The helper writes its outcome
        BEFORE the restart, so a helper that dies is finished by the next
        invocation (a `restartPending` outcome is re-verified, never accepted).
        That is why a CIM failure is a LOUD failure (cutover-failed, 4, audited)
        rather than a silent mechanism swap, and why -AllowProcessFallback is
        still safe when given: slower to prove, not wrong.

        A stale outcome from an earlier attempt is removed first, so a previous
        success can never be read as this attempt's. A `restartPending` outcome
        is not final: it is the helper's pre-restart evidence and the watch keeps
        waiting for the verified rewrite.

        Returns Applied / Verified / ExitCode / Detail / Outcome / OutcomePath /
        Spawned / TimedOut. `Applied` is true only when BOTH steps exited 0.
    #>
    param([int]$ToKeyNumber)
    if ($DryRun) {
        return [pscustomobject]@{
            Applied = $false; Verified = $false; ExitCode = 0
            Detail = 'dry-run: cutover not performed'; Outcome = $null
            OutcomePath = ''; Spawned = $false; TimedOut = $false
        }
    }

    $helper = if ($CutoverScript) { $CutoverScript } else { Join-Path $scriptRoot 'Invoke-KeyCheckCutover.ps1' }
    $outcomePath = if ($CutoverOutcomePath) {
        $CutoverOutcomePath
    } else {
        Join-Path (Split-Path -Parent $StatePath) "$runId-cutover.json"
    }
    if (Test-Path -LiteralPath $outcomePath) { Remove-Item -LiteralPath $outcomePath -Force -ErrorAction SilentlyContinue }

    $fail = {
        param([string]$Detail, [int]$Code, [bool]$TimedOut)
        [pscustomobject]@{
            Applied = $false; Verified = $false; ExitCode = $Code
            Detail = $Detail; Outcome = $null; OutcomePath = $outcomePath
            Spawned = $false; TimedOut = $TimedOut
        }
    }

    if (-not (Test-Path -LiteralPath $helper)) {
        return (& $fail -Detail "spawn-failed: cutover helper not found ($helper)" -Code -1 -TimedOut $false)
    }

    $helperArgs = @(
        '-NoProfile', '-File', $helper,
        '-KeyNumber', "$ToKeyNumber",
        '-OutcomePath', $outcomePath,
        '-RunId', $runId,
        '-TimeoutSeconds', "$([int]([Math]::Max(1, $CutoverTimeoutMinutes) * 60))"
    )
    if ($SwitchScript) { $helperArgs += @('-SwitchScript', $SwitchScript) }
    if ($RepairScript) { $helperArgs += @('-RepairScript', $RepairScript) }

    # Created via Win32_Process.Create, NOT Start-Process: the WMI provider makes
    # the child a non-member of this job object by construction, whereas a
    # Start-Process child may inherit membership. That is a design argument, not
    # a measurement - on 2026-11-02 both mechanisms survived a force-killed
    # launcher here, and survival across a real restart is unproven. What makes a
    # dead helper recoverable is the pre-restart outcome, not the launch.
    $commandLine = Get-KeyCheckHelperCommandLine -PowerShellPath (Join-Path $PSHOME 'pwsh.exe') `
        -HelperPath $helper -KeyNumber $ToKeyNumber -OutcomePath $outcomePath -RunId $runId `
        -TimeoutSeconds ([int]([Math]::Max(1, $CutoverTimeoutMinutes) * 60)) `
        -SwitchScript $SwitchScript -RepairScript $RepairScript
    $launch = Start-KeyCheckDetachedProcess -CommandLine $commandLine -FallbackArgumentList $helperArgs -AllowProcessFallback:$AllowProcessFallback

    Write-KeyCheckAudit -Entry ([ordered]@{
            ts = (Get-Date).ToString('s'); runId = $runId; kind = 'launch'; phase = 'trigger'
            method = [string]$launch.Method; pid = [int]$launch.ProcessId
            spawned = [bool]$launch.Spawned; detail = [string]$launch.Detail; dryRun = [bool]$DryRun
        })
    $script:LastLaunch = $launch
    if (-not $launch.Spawned) {
        return (& $fail -Detail ([string]$launch.Detail) -Code -1 -TimedOut $false)
    }
    if ($launch.Method -ne 'Win32_Process.Create') {
        # Loud, never silent: the survivability property is degraded and the
        # operator has to know, because this helper can die with the restart.
        Write-Warning "key-check: cutover helper launched via $($launch.Method) - $($launch.Detail)"
    }
    if (-not $Json) {
        Write-Output ("[trigger] cutover helper spawned via {0} (pid {1}); waiting up to {2} min for {3}" -f `
                $launch.Method, $launch.ProcessId, $CutoverTimeoutMinutes, $outcomePath)
    }

    # Poll the outcome file. There is no Process object on the CIM path, so the
    # outcome file is the only proof; no outcome inside the wait is
    # `cutover-unproven` (5), never success.
    #
    # A `restartPending: true` outcome is NOT an outcome: it is the helper
    # saying "the switch landed, the restart is still coming". Waiting past it
    # is the whole point - if the helper dies during the restart, this watch
    # times out as unproven and the NEXT invocation finishes the verification
    # from the same file.
    $waitUntil = (Get-Date).AddMinutes([Math]::Max(0.01, $CutoverTimeoutMinutes))
    $outcome = $null
    $pendingSeen = $false
    while ($true) {
        if (Test-Path -LiteralPath $outcomePath) {
            try {
                $outcome = Get-Content -LiteralPath $outcomePath -Raw | ConvertFrom-Json
            } catch {
                # A half-written file is not evidence yet; keep polling.
                $outcome = $null
            }
            if ($null -ne $outcome) {
                $restartPending = ($outcome.PSObject.Properties['restartPending'] -and [bool]$outcome.restartPending)
                if (-not $restartPending) { break }
                if (-not $pendingSeen) {
                    $pendingSeen = $true
                    if (-not $Json) {
                        Write-Output '[trigger] outcome is verified=pending (restart pending); waiting for the helper to finish verifying'
                    }
                    Write-KeyCheckAudit -Entry ([ordered]@{
                            ts = (Get-Date).ToString('s'); runId = $runId; kind = 'cutover'; phase = 'trigger'
                            applied = [bool]$outcome.applied; verified = 'pending'; restartPending = $true
                            from = "GO$($state.activeKeyNumber)"; to = $(if ($outcome.PSObject.Properties['keyNumber']) { "GO$([int]$outcome.keyNumber)" } else { '-' })
                            dryRun = [bool]$DryRun; detail = 'pre-restart outcome observed; verification still pending'
                        })
                }
                $outcome = $null
            }
        }
        if (-not (Test-KeyCheckProcessAlive -ProcessId ([int]$launch.ProcessId)) -and -not (Test-Path -LiteralPath $outcomePath)) {
            return (& $fail -Detail "cutover-helper-exited: pid $($launch.ProcessId) is gone, no outcome written" -Code 1 -TimedOut $false)
        }
        if ((Get-Date) -ge $waitUntil) {
            $why = if ($pendingSeen) { 'cutover-timeout: the helper wrote a pending outcome and never finished verifying' }
                   else { 'cutover-timeout: no outcome written before the wait expired' }
            return (& $fail -Detail $why -Code 124 -TimedOut $true)
        }
        Start-Sleep -Milliseconds ([int]([Math]::Max(0.05, $CutoverPollSeconds) * 1000))
    }

    $applied = [bool]$outcome.applied
    $verified = [bool]$outcome.verified
    $surfaceText = @($outcome.surfaces | ForEach-Object { "$($_.name)=$($_.actual)" }) -join ' '
    $detail = if ($outcome.reason) { [string]$outcome.reason } else { '' }
    return [pscustomobject]@{
        Applied = $applied; Verified = $verified; ExitCode = $(if ($verified) { 0 } elseif ($applied) { 5 } else { 4 })
        Detail = $detail; Outcome = $outcome; OutcomePath = $outcomePath
        Spawned = $true; TimedOut = $false; SurfaceText = $surfaceText
    }
}

function Start-KeyCheckSuccessor {
    <#
    .SYNOPSIS
        Leave ONE one-shot successor behind, created outside this process tree.
    .DESCRIPTION
        The lapse this exists to prevent (cl-common-0ai): run 20261102-235920 hit
        its 8 h deadline at 14:59:20Z and simply exited, so the active key was
        unwatched until a human (or a Hub tick that happened to look) started the
        next run ~9 minutes later. A watch that lapses silently is
        indistinguishable from a healthy watch until a key exhausts.

        So the deadline ending arms a successor: the SAME entry point, told to
        wait until the deadline plus a grace beat, then to assert liveness and
        start. It is created through Win32_Process.Create for the same reason the
        cutover helper is - that child is outside this agent's job object by
        construction - so a `paseo restart` does not silently end the chain.

        What this does NOT survive: a reboot, a logoff, or a host that blocks the
        CIM escape. That is what the standing supervisor
        (`Test-KeyCheckLiveness.ps1 -Restart`) is for, and it records the other
        trigger source. Neither mechanism is allowed to invent a second watcher:
        the successor starts by asserting liveness against the lock.

        Returns the record persisted on `state.successor` and audited.
    #>
    param([double]$GraceSeconds = 30)

    $now = Get-Date
    $delaySeconds = Get-KeyCheckSuccessorDelaySeconds -Deadline $deadline -Now $now -GraceSeconds $GraceSeconds
    $fireAt = $now.AddSeconds($delaySeconds)
    $scriptPath = if ($SuccessorScript) { $SuccessorScript } else { $PSCommandPath }

    # Forward only the WORLD this run was told to work in (fixture paths, seam,
    # helper overrides, timeout). Behaviour switches are not inherited: a
    # successor that inherited -DryRun would rehearse, and one that inherited
    # -NoRecovery would lose the post-cutover pass.
    $options = [ordered]@{}
    foreach ($pair in @(
            @{ Name = '-StatePath'; Value = $StatePath }
            @{ Name = '-AuditPath'; Value = $AuditPath }
            @{ Name = '-UsageFile'; Value = $UsageFile }
            @{ Name = '-BaseUrl'; Value = $BaseUrl }
            @{ Name = '-KeyValuesFile'; Value = $KeyValuesFile }
            @{ Name = '-SeamPath'; Value = $SeamPath }
            @{ Name = '-PaseoConfig'; Value = $PaseoConfig }
            @{ Name = '-CanaryScript'; Value = $CanaryScript }
            @{ Name = '-RepairScript'; Value = $RepairScript }
            @{ Name = '-SwitchScript'; Value = $SwitchScript }
            @{ Name = '-CutoverScript'; Value = $CutoverScript }
            @{ Name = '-ResumeScript'; Value = $ResumeScript }
            @{ Name = '-WitnessScript'; Value = $WitnessScript }
            @{ Name = '-AgentListFile'; Value = $AgentListFile }
            @{ Name = '-AgentsDir'; Value = $AgentsDir }
            @{ Name = '-SendScript'; Value = $SendScript }
            @{ Name = '-CutoverOutcomePath'; Value = $CutoverOutcomePath }
            @{ Name = '-TimeoutSeconds'; Value = $(if ($TimeoutSeconds -ne 20) { [string]$TimeoutSeconds } else { '' }) }
        )) {
        if ([string]::IsNullOrWhiteSpace([string]$pair.Value)) { continue }
        $options[$pair.Name] = [string]$pair.Value
    }

    $commandLine = Get-KeyCheckSuccessorCommandLine -PowerShellPath (Join-Path $PSHOME 'pwsh.exe') `
        -ScriptPath $scriptPath -DelaySeconds $delaySeconds -ParentRunId $runId `
        -IntervalMinutes $IntervalMinutes -DurationHours $DurationHours `
        -TriggeredBy 'successor-arm' -Options $options
    $launch = Start-KeyCheckDetachedProcess -CommandLine $commandLine

    $record = [ordered]@{
        trigger         = 'successor-arm'
        armed           = [bool]$launch.Spawned
        at              = $now.ToString('o')
        fireAt          = $fireAt.ToString('o')
        delaySeconds    = $delaySeconds
        pid             = [int]$launch.ProcessId
        method          = [string]$launch.Method
        detail          = [string]$launch.Detail
        parentRunId     = $runId
        intervalMinutes = $IntervalMinutes
        durationHours   = $DurationHours
    }
    Write-KeyCheckAudit -Entry ([ordered]@{
            ts = $now.ToString('s'); runId = $runId; kind = 'successor'
            trigger = 'successor-arm'
            action = $(if ($launch.Spawned) { 'armed' } else { 'failed' })
            at = $record.at; fireAt = $record.fireAt; delaySeconds = $delaySeconds
            pid = [int]$launch.ProcessId; method = [string]$launch.Method
            detail = [string]$launch.Detail; intervalMinutes = $IntervalMinutes
            durationHours = $DurationHours; statePath = $StatePath
            dryRun = [bool]$DryRun
        })
    if ($Json) {
        # -Json owns stdout, so the arm result travels in the state JSON only.
    } elseif ($launch.Spawned) {
        Write-Output ("[successor] armed pid {0} to fire at {1} (deadline + {2}s); trigger: successor-arm" -f `
                $launch.ProcessId, $fireAt.ToString('s'), $GraceSeconds)
    } else {
        Write-Warning "key-check: successor NOT armed at the deadline - $($launch.Detail)"
        Write-Output ("[successor] NOT armed: {0}; a standing supervisor must restart the watch (trigger: supervisor)" -f $launch.Detail)
    }
    return ([pscustomobject]$record)
}

function Write-KeyCheckLedger {
    param($Reading, [string]$Why)
    if ($DryRun -or $NoLedger -or $null -eq $Reading) { return $false }
    if ($null -eq $Reading.Weekly.Percent -and $null -eq $Reading.Monthly.Percent) { return $false }
    $ledgerArgs = @('-NoProfile', '-File', (Join-Path $scriptRoot 'Set-OpencodeGoFreshness.ps1'), '-KeyNumber', "$($Reading.KeyNumber)")
    # Point the writer at the same seam this run read, so a test/fixture seam
    # writes its observations beside itself and never into the live profile.
    if ($SeamPath) { $ledgerArgs += @('-SeamPath', $SeamPath) }
    if ($null -ne $Reading.Weekly.Percent) { $ledgerArgs += @('-WeeklyUsed', "$([int]$Reading.Weekly.Percent)") }
    if ($Reading.Weekly.ResetsAt) { $ledgerArgs += @('-WeeklyResets', $Reading.Weekly.ResetsAt) }
    if ($null -ne $Reading.Monthly.Percent) { $ledgerArgs += @('-MonthlyUsed', "$([int]$Reading.Monthly.Percent)") }
    if ($Reading.Monthly.ResetsAt) { $ledgerArgs += @('-MonthlyResets', $Reading.Monthly.ResetsAt) }
    $ledgerArgs += @('-Evidence', "KeyCheck $runId ($Why) live usage read")
    $null = & pwsh @ledgerArgs 2>&1
    return ($LASTEXITCODE -eq 0)
}

$stateDefaults = [ordered]@{
    runId                    = $runId
    startedAt                = $start.ToString('o')
    deadline                 = $deadline.ToString('o')
    deadlineAt               = $deadline.ToString('o')
    intervalMinutes          = $IntervalMinutes
    durationHours            = $DurationHours
    phase                    = 'initial'
    activeKeyNumber          = 0
    replacementKeyNumber     = 0
    replacementKey           = 0
    simulatedActiveKeyNumber = 0
    generation               = 0
    checks                   = 0
    lastReading              = $null
    lastCheckAt              = $null
    lastResult               = ''
    # Adaptive cadence: what this run is doing and why, and the history behind it.
    cadenceSeconds           = 0
    cadenceGear              = ''
    cadenceReason            = ''
    burnPerMinute            = $null
    ettMinutes               = $null
    sampleAt                 = $null
    cadenceChanges           = @()
    cadenceLoosenStreak      = 0
    cadenceFloorTicks        = 0
    # The burn window is measured from this bounded per-meter HISTORY, so the
    # gear can still derive ETT after it tightens below the 15-minute guard.
    cadenceSamples           = @()
    cadenceSampleSignature   = ''
    cadenceSampleGeneration  = 0
    # Tolerances, persisted so a resume does not silently forgive a streak.
    consecutiveRateLimited       = 0
    consecutiveCannotEvaluate    = 0
    consecutiveBelowThreshold    = 0
    armed                    = $false
    evidence                 = @()
    dryRun                   = [bool]$DryRun
    # Which live run this probe rehearsed (empty for a live run). The dry state
    # names its subject so a reader can never mistake it for that run's state.
    rehearsedRunId           = [string]$script:DryRunRehearsedRunId
    cutovers                 = @()
    drift                    = $null
    canary                   = $null
    usageSource              = ''
    endedAt                  = $null
    endReason                = ''
    exitCode                 = 0
}

$resuming = ($resume.Action -eq 'resume')
if ($resuming) {
    $state = Complete-KeyCheckState -State $resume.State -Defaults $stateDefaults
    $state.phase = $resume.Phase
    $state.generation = [int]$resume.Generation
    if ($resumeOutcomeStale) {
        # The outcome's +1 belongs to the move it proved. The live change is its
        # own generation and is applied - once, and audited - by the live sync.
        $state.generation = $priorGeneration
    }
    if (-not $resumeOutcomeStale -and
        $resume.PSObject.Properties['ActiveKeyNumber'] -and $null -ne $resume.ActiveKeyNumber) {
        $from = [int]$state.activeKeyNumber
        $to = [int]$resume.ActiveKeyNumber
        $state.cutovers = @($state.cutovers) + @([pscustomobject]@{
                from        = $from
                to          = $to
                applied     = $true
                verified    = $true
                dryRun      = [bool]$DryRun
                canary      = 'unknown (verified by the detached helper while the watch was down)'
                exitCode    = 0
                outcomePath = if ($CutoverOutcomePath) { $CutoverOutcomePath } else { Get-KeyCheckCutoverOutcomePath -Dir $stateDir -RunId $runId }
                at          = (Get-Date).ToString('o')
            })
        $state.activeKeyNumber = $to
        $state.replacementKeyNumber = 0
        $state.replacementKey = 0
    }
    if ($resume.ResetCounters) {
        $state.consecutiveRateLimited = 0
        $state.consecutiveCannotEvaluate = 0
        $state.consecutiveBelowThreshold = 0
        $state.armed = $false
    }
    $state.evidence += "resumed: $($resume.Reason)"
    $resumeEntry = [ordered]@{
        ts = (Get-Date).ToString('s'); runId = $runId; kind = 'resume'; phase = $state.phase
        reason = $resume.Reason; generation = [int]$state.generation
        deadlineKept = $deadline.ToString('o')
        rateLimitedStreak = [int]$state.consecutiveRateLimited
        cannotEvaluateStreak = [int]$state.consecutiveCannotEvaluate
        belowThresholdStreak = [int]$state.consecutiveBelowThreshold
        dryRun = [bool]$DryRun
    }
    if ($DryRun) { $resumeEntry.rehearsedRunId = [string]$resume.RunId }
    Write-KeyCheckAudit -Entry $resumeEntry
    if (-not $Json) {
        Write-Output ("[resume] continuing run {0} at phase {1}; deadline {2} is unchanged ({3})" -f `
                $runId, $state.phase, $deadline.ToString('s'), $resume.Reason)
    }
} else {
    $state = [pscustomobject]$stateDefaults
}

# The artefact describes THIS process, never the state it rehearsed or resumed:
# a dry run that resumed a live state whose own flag says `dryRun: false` (and
# whose runId is the live one) must still be unmistakable, and a live resume must
# not inherit a rehearsal flag.
$state | Add-Member -NotePropertyName runId -NotePropertyValue $runId -Force
$state | Add-Member -NotePropertyName dryRun -NotePropertyValue ([bool]$DryRun) -Force
$state | Add-Member -NotePropertyName rehearsedRunId -NotePropertyValue ([string]$script:DryRunRehearsedRunId) -Force

# ---- the persisted active key follows the LIVE in-use key, on EVERY start ---
# One state write: generation + 1, activeKeyNumber = the live key, the armed
# replacement and the old key's sample ring/meters/tolerances discarded, and one
# CLEAR audit line - never a resumed verdict about a key the machine left.
$activeSync = Update-KeyCheckActiveKeyState -State $state -LiveKeyNumber $liveActive.KeyNumber -How $liveActive.How
if ($activeSync.Changed) {
    $state = $activeSync.State
    $state.evidence += "active key follows the live in-use value: $($activeSync.Reason) (resolved via $($liveActive.How))"
    Write-KeyCheckAudit -Entry ([ordered]@{
            ts = (Get-Date).ToString('s'); runId = $runId; kind = 'note'; phase = [string]$state.phase
            reason = $activeSync.Reason
            from = "GO$($activeSync.FromKeyNumber)"; to = "GO$($activeSync.ToKeyNumber)"
            generation = [int]$state.generation; resolvedVia = [string]$liveActive.How
            dryRun = [bool]$DryRun
        })
    if (-not $Json) {
        Write-Output ("[active] {0} (live in-use key, {1}); generation {2}" -f `
                $activeSync.Reason, $liveActive.How, $state.generation)
    }
} elseif ($liveActive.KeyNumber -le 0 -and [int]$state.activeKeyNumber -gt 0) {
    # An absent measurement is a NAMED reason, never a silent pass: the watch
    # keeps the key the state remembers, and says that it could not re-prove it.
    Write-KeyCheckAudit -Entry ([ordered]@{
            ts = (Get-Date).ToString('s'); runId = $runId; kind = 'note'; phase = [string]$state.phase
            reason = "active-key-unverified: the live in-use value matched no pool key and the seam named none; still watching GO$([int]$state.activeKeyNumber)"
            dryRun = [bool]$DryRun
        })
}

# ------------------------------------------------------------------- loop ---
$exitCode = 0
$endReason = ''
$phase = [string]$state.phase

# The FIRST metered reading of a process is never delayed (cl-common-79y). A
# fresh start already reads in `initial`; a RESUMED run has read nothing yet, so
# its first polling iteration must read at t ~ 0 instead of sleeping a full
# cadence first. Measured defect: the heartbeat loop slept a whole gear before
# its first reading, so a watch restarted more often than its cadence (11 min
# restart against a 15 min gear) produced ZERO checks - alive, healthy, and
# blind. Only the readings AFTER the first one are spaced by the cadence.
$readBeforeSleep = ($phase -ne 'initial')

# ---------------------------------------------------------------- initial ---
if ($phase -eq 'initial') {
    $state.usageSource = if ($UsageFile) { "fixture:$UsageFile" }
                         elseif ($BaseUrl) { "http:$BaseUrl" }
                         else { 'Get-GoKeyUsage.ps1' }

    # A budget that cannot hold one full interval performs exactly one check. Say it
    # out loud (console + audit + evidence) instead of implying a watch that never
    # actually re-polls before the deadline.
    if ($IntervalMinutes * 60 -ge $DurationHours * 3600) {
        $budgetNote = "budget-note: interval ${IntervalMinutes}m >= duration ${DurationHours}h - the run performs effectively one check, not a watch"
        Write-Warning $budgetNote
        Write-Output $budgetNote
        $state.evidence += $budgetNote
        Write-KeyCheckAudit -Entry ([ordered]@{
                ts = (Get-Date).ToString('s'); runId = $runId; kind = 'note'; phase = 'initial'
                reason = $budgetNote; dryRun = [bool]$DryRun
            })
    }

    $census = Get-KeyCheckCensus
    $readings = @($census.Readings)
    if ($census.Unreadable.Count -gt 0) {
        $state.evidence += "cannot-evaluate: $(Format-KeyCheckExclusionLine -Unreadable $census.Unreadable)"
    }
    $recorded = @()
    foreach ($reading in $readings) {
        if (Write-KeyCheckLedger -Reading $reading -Why 'initial') { $recorded += $reading.Label }
    }
    if ($recorded.Count -gt 0) { $state.evidence += "ledger recorded: $($recorded -join ', ')" }

    $resolved = Resolve-KeyCheckActive
    $state.activeKeyNumber = $resolved.KeyNumber
    $state.evidence += "active key: $(if ($resolved.KeyNumber -gt 0) { "GO$($resolved.KeyNumber)" } else { 'unresolved' }) via $($resolved.How)"

    if ($state.activeKeyNumber -le 0) {
        # D5: watching a key we cannot even name is not a watch. Fail immediately
        # with the reason instead of polling for the whole duration.
        $reason = 'active-key-unresolved: no pool key and no seam activeKey resolved the in-use value'
        $state.evidence += $reason
        $state.consecutiveCannotEvaluate = [int]$state.consecutiveCannotEvaluate + 1
        Write-KeyCheckCheck -Phase 'initial' -Reading $null -Decision 'end' -Reason $reason
        $exitCode = 1
        $endReason = 'active-key-unresolved'
    } else {
        $state.drift = Get-KeyCheckDrift
        $state.evidence += "provider lock: $($state.drift.Detail)"

        $activeReading = Get-KeyCheckReadingByNumber -Readings $readings -KeyNumber $state.activeKeyNumber
        $canary = Invoke-KeyCheckCanary -KeyNumber $state.activeKeyNumber
        $state.canary = $canary
        $state.evidence += "active canary: $($canary.Verdict)"

        Update-KeyCheckReadCounters -Reading $activeReading
        Update-KeyCheckCadenceForReading -Reading $activeReading -Phase 'heartbeat'
        $decision = Get-KeyCheckNextPhase -Phase 'initial' -Now (Get-Date) -Deadline $deadline `
            -Reading $activeReading -ReplacementKeyNumber $state.replacementKeyNumber `
            -ConsecutiveRateLimited $state.consecutiveRateLimited `
            -ConsecutiveBelowThreshold $state.consecutiveBelowThreshold
        $initialReason = Get-KeyCheckDecisionReason -Decision $decision -KeyNumber $state.activeKeyNumber
        Write-KeyCheckCheck -Phase 'initial' -Reading $activeReading -Decision $decision.Phase -Reason $initialReason
        $phase = $decision.Phase
    }
} elseif (-not $Json) {
    Write-Output ("[resume] run {0} continues at phase {1}" -f $runId, $phase)
}

while (-not $endReason) {
    if ((Get-Date) -ge $deadline) { $endReason = 'deadline'; break }
    if ($MaxChecks -gt 0 -and $state.checks -ge $MaxChecks) { $endReason = 'max-checks'; break }

    if ($phase -eq 'heartbeat') {
        $sleep = Get-KeyCheckSleepSeconds -Seconds (Get-KeyCheckCadenceSeconds -Phase 'heartbeat' -IntervalMinutes $IntervalMinutes -CadenceSeconds ([int]$state.cadenceSeconds)) -Deadline $deadline
        if ($readBeforeSleep) { $sleep = 0 }   # first reading of this process: no pre-read wait
        if ($sleep -gt 0 -and -not $NoWait) { Start-Sleep -Milliseconds ([int]($sleep * 1000)) }
        $readBeforeSleep = $false
        if ((Get-Date) -ge $deadline) { $endReason = 'deadline'; break }
        $reading = Get-KeyCheckActiveReading
        Update-KeyCheckReadCounters -Reading $reading
        if (Test-KeyCheckMeterUnreadable -ConsecutiveCannotEvaluate $state.consecutiveCannotEvaluate) {
            $reason = "meter-unreadable: $($state.consecutiveCannotEvaluate) consecutive usage reads produced no reading for GO$($state.activeKeyNumber)"
            $state.evidence += $reason
            Write-KeyCheckCheck -Phase 'heartbeat' -Reading $null -Decision 'end' -Reason $reason
            $exitCode = 1
            $endReason = 'meter-unreadable'
            break
        }
        Update-KeyCheckCadenceForReading -Reading $reading -Phase 'heartbeat'
        $decision = Get-KeyCheckNextPhase -Phase 'heartbeat' -Now (Get-Date) -Deadline $deadline `
            -Reading $reading -ReplacementKeyNumber $state.replacementKeyNumber `
            -ConsecutiveRateLimited $state.consecutiveRateLimited `
            -ConsecutiveBelowThreshold $state.consecutiveBelowThreshold
        Write-KeyCheckCheck -Phase 'heartbeat' -Reading $reading -Decision $decision.Phase `
            -Reason (Get-KeyCheckDecisionReason -Decision $decision -KeyNumber $state.activeKeyNumber)
        $phase = $decision.Phase
        continue
    }

    if ($phase -eq 'discover') {
        # ONE reader: the same census `initial` used. No second code path, and no
        # silent catch - a read that yields nothing is named, not shrugged.
        $census = Get-KeyCheckCensus
        $all = @($census.Readings)
        $report = Get-KeyCheckCandidateReport -Readings $all -ExcludeKeyNumber $state.activeKeyNumber
        $candidates = @($report.Eligible)
        $rejected = @($report.Rejected)
        $unreadable = @($census.Unreadable)

        if ($all.Count -eq 0) {
            # An absent input is a named non-zero, never a pass and never
            # "no eligible replacement" (which would be a different claim).
            $reason = "cannot-evaluate: $(Format-KeyCheckExclusionLine -Unreadable $unreadable)"
            $state.evidence += $reason
            Write-KeyCheckCheck -Phase 'discover' -Reading $null -Decision 'end' -Reason $reason
            $exitCode = 1
            $endReason = 'cannot-evaluate'
            break
        }

        $armed = $null
        # The whole ranked field is named, so the report shows what was eligible
        # even when the first candidate is proven and armed immediately.
        $considered = @($candidates | ForEach-Object { "GO$($_.KeyNumber)" })
        foreach ($candidate in $candidates) {
            $proof = Invoke-KeyCheckCanary -KeyNumber $candidate.KeyNumber
            if ($proof.Ok) { $armed = $candidate; break }
            $rejected += [pscustomobject]@{ KeyNumber = $candidate.KeyNumber; Label = $candidate.Label; Rule = "canary-failed:$($proof.Verdict)" }
            $state.evidence += "replacement GO$($candidate.KeyNumber) failed canary: $($proof.Verdict)"
        }

        if ($null -eq $armed) {
            $reason = "no-eligible-replacement: $(Format-KeyCheckExclusionLine -Rejected $rejected -Unreadable $unreadable)"
            $state.evidence += $reason
            Write-KeyCheckCheck -Phase 'discover' -Reading $null -Decision 'end' -Reason $reason
            $exitCode = 3
            $endReason = 'no-eligible-replacement'
            break
        }

        $state.replacementKeyNumber = $armed.KeyNumber
        $state.armed = $true
        $wkText = if ($null -ne $armed.Weekly.Percent) { "$([int]$armed.Weekly.Percent)wk" } else { '?wk' }
        $moText = if ($null -ne $armed.Monthly.Percent) { "$([int]$armed.Monthly.Percent)mo" } else { '?mo' }
        $resets = if (-not [string]::IsNullOrWhiteSpace([string]$armed.Monthly.ResetsAt)) { [string]$armed.Monthly.ResetsAt } else { 'not reported' }
        # An unparsable reset is not fatal: the raw string is recorded and the
        # ranking falls back to the rolling value (E3).
        $windowNote = Get-KeyCheckWindowUnknownNote -Reading $armed
        if ($windowNote) {
            $state.evidence += $windowNote
            Write-KeyCheckAudit -Entry ([ordered]@{
                    ts = (Get-Date).ToString('s'); runId = $runId; kind = 'note'; phase = 'discover'
                    key = $armed.Label; reason = $windowNote
                    rawResetsAt = [string]$armed.Monthly.ResetsAt; dryRun = [bool]$DryRun
                })
        }
        $reason = "replacement-armed GO$($armed.KeyNumber) $wkText/$moText monthly resets $resets (eligible: $($considered -join ', '))"
        if ($windowNote) { $reason += "; $windowNote" }
        $state.evidence += $reason
        $decision = Get-KeyCheckNextPhase -Phase 'discover' -Now (Get-Date) -Deadline $deadline `
            -Reading $armed -ReplacementKeyNumber $state.replacementKeyNumber
        Write-KeyCheckCheck -Phase 'discover' -Reading $armed -Decision $decision.Phase -Reason $reason -KeepLastReading
        $phase = $decision.Phase
        continue
    }

    if ($phase -eq 'near') {
        # The same burn-derived gear as heartbeat, capped at 15 min and floored
        # at 1 min: the old fixed 120 s was a guess that spent ~30 reads an hour
        # on a number that moves once an hour.
        $sleep = Get-KeyCheckSleepSeconds -Seconds (Get-KeyCheckCadenceSeconds -Phase 'near' -CadenceSeconds ([int]$state.cadenceSeconds)) -Deadline $deadline
        if ($readBeforeSleep) { $sleep = 0 }   # same rule for a resumed `near` run
        if ($sleep -gt 0 -and -not $NoWait) { Start-Sleep -Milliseconds ([int]($sleep * 1000)) }
        $readBeforeSleep = $false
        if ((Get-Date) -ge $deadline) { $endReason = 'deadline'; break }
        $reading = Get-KeyCheckActiveReading
        Update-KeyCheckReadCounters -Reading $reading
        if (Test-KeyCheckMeterUnreadable -ConsecutiveCannotEvaluate $state.consecutiveCannotEvaluate) {
            $reason = "meter-unreadable: $($state.consecutiveCannotEvaluate) consecutive usage reads produced no reading for GO$($state.activeKeyNumber)"
            $state.evidence += $reason
            Write-KeyCheckCheck -Phase 'near' -Reading $null -Decision 'end' -Reason $reason
            $exitCode = 1
            $endReason = 'meter-unreadable'
            break
        }
        Update-KeyCheckCadenceForReading -Reading $reading -Phase 'near'
        $decision = Get-KeyCheckNextPhase -Phase 'near' -Now (Get-Date) -Deadline $deadline `
            -Reading $reading -ReplacementKeyNumber $state.replacementKeyNumber `
            -ConsecutiveRateLimited $state.consecutiveRateLimited `
            -ConsecutiveBelowThreshold $state.consecutiveBelowThreshold
        if ($decision.Reason -eq 'disarmed') {
            $state.consecutiveBelowThreshold = 0
            $state.evidence += "disarmed: weekly < 70 and monthly < 80 for the disarm band; back to the heartbeat cadence"
            Write-KeyCheckCheck -Phase 'near' -Reading $reading -Decision 'heartbeat' -Reason 'disarmed'
        } else {
            Write-KeyCheckCheck -Phase 'near' -Reading $reading -Decision $decision.Phase `
                -Reason (Get-KeyCheckDecisionReason -Decision $decision -KeyNumber $state.activeKeyNumber)
        }
        $phase = $decision.Phase
        continue
    }

    if ($phase -eq 'trigger') {
        $trigger = Get-KeyCheckTriggerDecision -ActiveKeyNumber $state.activeKeyNumber `
            -ReplacementKeyNumber $state.replacementKeyNumber
        if ($trigger.Action -eq 'none') {
            Write-KeyCheckCheck -Phase 'trigger' -Reading $state.lastReading -Decision 'near' -Reason $trigger.Reason
            $phase = 'near'
            continue
        }

        $from = [int]$state.activeKeyNumber
        $to = [int]$state.replacementKeyNumber
        $finalReading = Get-KeyCheckActiveReading
        if ($finalReading) { $null = Write-KeyCheckLedger -Reading $finalReading -Why 'final-reading-before-cutover' }

        $proof = Invoke-KeyCheckCanary -KeyNumber $to
        if (-not $proof.Ok) {
            $state.evidence += "replacement GO$to failed re-proof: $($proof.Verdict)"
            $state.replacementKeyNumber = 0
            Write-KeyCheckCheck -Phase 'trigger' -Reading $finalReading -Decision 'discover' -Reason 'replacement-unproven'
            $phase = 'discover'
            continue
        }

        $cut = Invoke-KeyCheckCutover -ToKeyNumber $to
        $state.cutovers = @($state.cutovers) + @([pscustomobject]@{
                from        = $from
                to          = $to
                applied     = [bool]$cut.Applied
                verified    = [bool]$cut.Verified
                dryRun      = [bool]$DryRun
                canary      = $proof.Verdict
                exitCode    = $cut.ExitCode
                outcomePath = [string]$cut.OutcomePath
                launchMethod = $(if ($script:LastLaunch) { [string]$script:LastLaunch.Method } else { 'none' })
                launchPid    = $(if ($script:LastLaunch) { [int]$script:LastLaunch.ProcessId } else { 0 })
                at          = (Get-Date).ToString('o')
            })
        Write-KeyCheckAudit -Entry ([ordered]@{
                ts          = (Get-Date).ToString('s'); runId = $runId; kind = 'cutover'
                from        = "GO$from"; to = "GO$to"; applied = [bool]$cut.Applied
                verified    = [bool]$cut.Verified
                dryRun      = [bool]$DryRun; canary = $proof.Verdict; detail = $cut.Detail
                outcomePath = [string]$cut.OutcomePath
                launchMethod = $(if ($script:LastLaunch) { [string]$script:LastLaunch.Method } else { 'none' })
                launchPid    = $(if ($script:LastLaunch) { [int]$script:LastLaunch.ProcessId } else { 0 })
            })

        if ($DryRun) {
            # Nothing moved: keep the real in-use key, and continue the run
            # against the key the cutover would have chosen.
            $state = Update-KeyCheckAfterCutover -State $state -FromKeyNumber $from -ToKeyNumber $to -Reading $finalReading
            $state | Add-Member -NotePropertyName activeKeyNumber -NotePropertyValue $from -Force
            $state | Add-Member -NotePropertyName simulatedActiveKeyNumber -NotePropertyValue $to -Force
            $state.evidence += "dry-run: cutover GO$from -> GO$to not performed; run continues as if it had"
            Write-KeyCheckCheck -Phase 'trigger' -Reading $finalReading -Decision 'near' -Reason 'dry-run-cutover'
            $phase = 'near'
            continue
        }

        # The helper's outcome is the proof, not a second single-surface re-read
        # here: the helper verifies seam + User env + Paseo pin AFTER the restart,
        # in a process the restart does not kill. Re-deriving it here would
        # reintroduce the one-surface check that made every rescue "unproven".
        if (-not $cut.Applied) {
            Write-KeyCheckCheck -Phase 'trigger' -Reading $finalReading -Decision 'end' -Reason "cutover-failed: $($cut.Detail)"
            $exitCode = 4
            $endReason = 'cutover-failed'
            break
        }
        if (-not $cut.Verified) {
            $why = if ($cut.TimedOut) { 'cutover-timeout' } else { 'cutover-unproven' }
            Write-KeyCheckCheck -Phase 'trigger' -Reading $finalReading -Decision 'end' -Reason ("{0}: {1} {2}" -f $why, $cut.Detail, $cut.SurfaceText)
            $exitCode = 5
            $endReason = $why
            break
        }

        $state = Update-KeyCheckAfterCutover -State $state -FromKeyNumber $from -ToKeyNumber $to -Reading $finalReading
        $state.evidence += "cutover verified GO$from -> GO$to ($($cut.SurfaceText)); evidence: $($cut.OutcomePath)"
        Write-KeyCheckCheck -Phase 'trigger' -Reading $finalReading -Decision 'near' -Reason 'rescue-complete'
        $phase = 'near'
        continue
    }

    $endReason = 'deadline'
    break
}

# ---- arm the successor BEFORE this run ends (cl-common-0ai) ----------------
# A deadline ending is not a finish, it is a handover: the window is over but the
# key still needs watching. Arm it here, while this process still owns the lock,
# so the chain never depends on a human reading state.json - and record the
# trigger source next to the runId, because "who restarted the watch" is the
# question this bead exists to answer.
$successor = $null
if (Test-KeyCheckShouldArmSuccessor -EndReason $endReason -DryRun:$DryRun -NoWait:$NoWait -NoSuccessor:$NoSuccessor) {
    $successor = Start-KeyCheckSuccessor -GraceSeconds $SuccessorGraceSeconds
    $state.evidence += "successor: $($successor.trigger) $(if ($successor.armed) { "armed pid $($successor.pid) for $($successor.fireAt)" } else { "NOT armed ($($successor.detail))" })"
}
$state | Add-Member -NotePropertyName successor -NotePropertyValue $successor -Force

$state.endedAt = (Get-Date).ToString('o')
$state.endReason = $endReason
$state.exitCode = $exitCode
if ($endReason -eq 'deadline') { $state.phase = 'end' }
Save-KeyCheckState
Write-KeyCheckAudit -Entry ([ordered]@{
        ts = (Get-Date).ToString('s'); runId = $runId; kind = 'end'; phase = [string]$state.phase
        decision = 'end'; reason = $endReason; exitCode = $exitCode
        checks = [int]$state.checks; generation = [int]$state.generation
        dryRun = [bool]$DryRun
    })

if ($Json) {
    $state | ConvertTo-Json -Depth 16
} else {
    Write-Output ("key-check {0}: {1} (checks={2}, generation={3}, active=GO{4}, dryRun={5})" -f `
            $runId, $endReason, $state.checks, $state.generation, $state.activeKeyNumber, [bool]$DryRun)
}

Exit-KeyCheckRun -Code $exitCode

