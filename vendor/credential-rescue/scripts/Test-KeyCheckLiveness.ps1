#Requires -Version 7.0
<#
.SYNOPSIS
    Key Check liveness - the standing supervisor that asserts a watch exists and,
    with -Restart, starts one.

.DESCRIPTION
    The armed successor (Invoke-KeyCheck.ps1 at its deadline) covers the ordinary
    handover, but it cannot survive a reboot, a logoff, or a host that blocks the
    CIM escape. This is the other half of the same fix (cl-common-0ai): any
    standing tick - a Paseo cron, a Hub tick, a nightly battery - can call this in
    one line and learn, from evidence, whether the opencode-go active key is being
    watched at all.

    Read-only by default. It reads the run state and the lock and prints ONE
    verdict:

        live             a LIVE lock exists - a run is watching. Nothing to do.
        lapsed           nothing live: no run state (`no-state`), the state says
                         the run ENDED (`run-ended`, the measured 2026-11-03
                         lapse), or the state says a run is in flight with no live
                         lock (`run-not-live`, which resumes on its deadline).
        cannot-evaluate  the state file exists and cannot be read, or it is a
                         `-DryRun` probe artefact (`<state dir>\dryrun\`,
                         `dryRun: true`). Never a pass, and never a verdict
                         about a rehearsal.

    With -Restart, a `lapsed` verdict is acted on instead of reported: the SAME
    entry point is created outside this process tree (Win32_Process.Create, the
    same escape the cutover helper uses), told `-TriggeredBy supervisor`, and the
    decision is written to the key-check audit with that trigger source - so
    "successor-arm" and "supervisor" are distinguishable in the record.

    It never takes `-Force`: the lock is the single liveness signal, and a
    supervisor that stole a live lock would be the duplicate watcher this exists
    to prevent.

    Residual risk, stated rather than hidden: a successor process dies with the
    host. That is exactly why this supervisor exists - schedule it (hourly is
    enough: a lapsed watch costs nothing while the key is quiet) and the chain
    recovers even after a reboot.

.PARAMETER StatePath
    Run-state file to read. Default ~/.salmon/State/key-check/state.json (the
    same fixed path the run writes, which is what makes the question answerable).

.PARAMETER AuditPath
    Per-check JSONL audit. Default ~/.salmon/Tasks/Logs/keycheck.jsonl.

.PARAMETER IntervalMinutes
    Base gear handed to the watch this starts. Default 15.

.PARAMETER DurationHours
    Window handed to the watch this starts. Default 8 - the size of the run this
    supervisor is expected to be restarting.

.PARAMETER Restart
    Act on a `lapsed` verdict instead of only reporting it.

.PARAMETER Json
    Emit the verdict as JSON (one object, no progress lines).

.PARAMETER SuccessorScript
    Test seam: the script the restart launches, instead of Invoke-KeyCheck.ps1.

.EXAMPLE
    pwsh -File Test-KeyCheckLiveness.ps1
    # one line, exit 0 live / 3 lapsed - a cron line with no side effects

.EXAMPLE
    pwsh -File Test-KeyCheckLiveness.ps1 -Restart -Json
    # assert, and start the watch if nothing is watching

.OUTPUTS
    Exit 0 live, or restarted · 3 lapsed and not restarted · 4 restart failed ·
    2 cannot-evaluate (the state file exists and cannot be read).
#>
[CmdletBinding()]
param(
    [string]$StatePath,
    [string]$AuditPath,
    [int]$IntervalMinutes = 15,
    [double]$DurationHours = 8,
    [switch]$Restart,
    [switch]$Json,
    [string]$SuccessorScript,
    [int]$TimeoutSeconds = 20
)

$ErrorActionPreference = 'Stop'

$scriptRoot = $PSScriptRoot
. (Join-Path $scriptRoot 'lib\KeyCheck.Decision.ps1')
. (Join-Path $scriptRoot 'lib\KeyCheck.State.ps1')

$stateRoot = Join-Path $env:USERPROFILE '.salmon'
$stateDir = if ($StatePath) {
    $parent = Split-Path -Parent $StatePath
    if ([string]::IsNullOrWhiteSpace($parent)) { (Get-Location).Path } else { $parent }
} else {
    Join-Path $stateRoot 'State\key-check'
}
if (-not $StatePath) { $StatePath = Join-Path $stateDir 'state.json' }
if (-not $AuditPath) { $AuditPath = Join-Path (Join-Path $stateRoot 'Tasks\Logs') 'keycheck.jsonl' }
$lockPath = Join-Path $stateDir 'lock.json'
$lockStaleSeconds = [int]([Math]::Max(60, 3 * $IntervalMinutes * 60))

function Write-LivenessAudit {
    param($Entry)
    $dir = Split-Path -Parent $AuditPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
    Add-Content -LiteralPath $AuditPath -Value ($Entry | ConvertTo-Json -Compress) -Encoding utf8NoBOM
}

$now = Get-Date
$stateFileExists = Test-Path -LiteralPath $StatePath
$state = Read-KeyCheckState -Path $StatePath
$lock = Get-KeyCheckLockState -Path $lockPath -Now $now -StaleSeconds $lockStaleSeconds
$decision = Get-KeyCheckSuccessorDecision -State $state -Lock $lock -Now $now

# A state file that exists but cannot be parsed is CANNOT-EVALUATE, never
# "lapsed": starting a watch on top of an unreadable run is how two watchers
# happen. An absent file is a real answer (`no-state`).
#
# A DRY-RUN artefact is not a live state either (cl-common-jqm): a probe writes
# `<state dir>\dryrun\state.json` with `dryRun: true`. A default invocation can
# never reach it, but a caller that points -StatePath at one gets
# cannot-evaluate - never a liveness verdict about a rehearsal.
$cannotEvaluate = ($stateFileExists -and $null -eq $state)
$dryRunArtefact = ($null -ne $state -and $state.PSObject.Properties['dryRun'] -and [bool]$state.dryRun)
$status = if ($cannotEvaluate -or $dryRunArtefact) { 'cannot-evaluate' }
          elseif ($decision.Action -eq 'skip') { 'live' }
          else { 'lapsed' }

$scriptPath = if ($SuccessorScript) { $SuccessorScript } else { Join-Path $scriptRoot 'Invoke-KeyCheck.ps1' }
$restartCommand = 'pwsh -NoProfile -File "{0}" -IntervalMinutes {1} -DurationHours {2}' -f `
    $scriptPath, $IntervalMinutes, ([double]$DurationHours).ToString('R', [System.Globalization.CultureInfo]::InvariantCulture)

$report = [ordered]@{
    status       = $status
    action       = 'none'
    reason       = $(if ($dryRunArtefact) { 'dry-run-state' } elseif ($cannotEvaluate) { 'state-unreadable' } else { $decision.Reason })
    detail       = $(if ($dryRunArtefact) { "the state at $StatePath is a -DryRun probe artefact (dryRun: true), not a live run; refusing to judge liveness from a rehearsal" }
                     elseif ($cannotEvaluate) { "the run state at $StatePath exists and cannot be read; refusing to judge liveness" }
                     else { $decision.Detail })
    runId        = $(if ($null -ne $state -and $state.PSObject.Properties['runId']) { [string]$state.runId } else { '' })
    phase        = $(if ($null -ne $state -and $state.PSObject.Properties['phase']) { [string]$state.phase } else { '' })
    endReason    = $(if ($null -ne $state -and $state.PSObject.Properties['endReason']) { [string]$state.endReason } else { '' })
    deadlineAt   = $(if ($decision.PSObject.Properties['DeadlineAt'] -and $null -ne $decision.DeadlineAt) { ([datetime]$decision.DeadlineAt).ToString('o') } else { '' })
    lastCheckAt  = $(if ($null -ne $state -and $state.PSObject.Properties['lastCheckAt']) { Format-KeyCheckStateTimestamp $state.lastCheckAt } else { '' })
    checks       = $(if ($null -ne $state -and $state.PSObject.Properties['checks']) { [int]$state.checks } else { 0 })
    lock         = [ordered]@{
        path                = $lockPath
        exists              = [bool]$lock.Exists
        stale               = [bool]$lock.Stale
        reason              = [string]$lock.Reason
        pid                 = $(if ($null -ne $lock.Lock -and $lock.Lock.PSObject.Properties['pid']) { [int]$lock.Lock.pid } else { 0 })
        runId               = $(if ($null -ne $lock.Lock -and $lock.Lock.PSObject.Properties['runId']) { [string]$lock.Lock.runId } else { '' })
        ageSeconds          = [int]$lock.AgeSeconds
        heartbeatAgeSeconds = [int]$lock.HeartbeatAgeSeconds
    }
    restartCommand = $restartCommand
    checkedAt    = $now.ToString('o')
}

$exitCode = 0
switch ($status) {
    'cannot-evaluate' { $exitCode = 2 }
    'live' { $exitCode = 0 }
    'lapsed' {
        if (-not $Restart) {
            $exitCode = 3
        } else {
            $delaySeconds = 0
            $commandLine = Get-KeyCheckSuccessorCommandLine -PowerShellPath (Join-Path $PSHOME 'pwsh.exe') `
                -ScriptPath $scriptPath -DelaySeconds $delaySeconds -ParentRunId $report.runId `
                -IntervalMinutes $IntervalMinutes -DurationHours $DurationHours `
                -TriggeredBy 'supervisor' `
                -Options ([ordered]@{
                    '-StatePath' = $StatePath
                    '-AuditPath' = $AuditPath
                    '-TimeoutSeconds' = $(if ($TimeoutSeconds -ne 20) { [string]$TimeoutSeconds } else { '' })
                })
            $launch = Start-KeyCheckDetachedProcess -CommandLine $commandLine
            $report.action = $(if ($launch.Spawned) { 'restarted' } else { 'restart-failed' })
            $report.pid = [int]$launch.ProcessId
            $report.method = [string]$launch.Method
            $report.detail = [string]$launch.Detail
            Write-LivenessAudit -Entry ([ordered]@{
                    ts = $now.ToString('s'); runId = $(if ($report.runId) { $report.runId } else { $now.ToString('yyyyMMdd-HHmmss') })
                    kind = 'successor'; trigger = 'supervisor'
                    action = $(if ($launch.Spawned) { 'armed' } else { 'failed' })
                    reason = $report.reason; detail = [string]$launch.Detail
                    at = $now.ToString('o'); pid = [int]$launch.ProcessId; method = [string]$launch.Method
                    phase = $report.phase; deadlineAt = $report.deadlineAt
                    intervalMinutes = $IntervalMinutes; durationHours = $DurationHours
                    statePath = $StatePath
                })
            $exitCode = $(if ($launch.Spawned) { 0 } else { 4 })
        }
    }
}

if ($Json) {
    ($report | ConvertTo-Json -Depth 8)
} else {
    $lockText = if ($report.lock.exists) { "lock pid $($report.lock.pid) run $($report.lock.runId) ($($report.lock.reason))" } else { 'no lock' }
    Write-Output ("key-check liveness: {0} - {1}{2}" -f `
            $status, $report.detail, $(if ($status -eq 'live') { " [$lockText]" } else { '' }))
    if ($status -eq 'lapsed' -and -not $Restart) { Write-Output "  restart with: $restartCommand" }
    if ($report.action -eq 'restarted') { Write-Output "  started pid $($report.pid) via $($report.method) (trigger: supervisor)" }
}

exit $exitCode
