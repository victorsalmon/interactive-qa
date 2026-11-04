#Requires -Version 7
<#
.SYNOPSIS
    Bounded retry-with-backoff around a Paseo schedule record write
    (create / update / re-arm), so a momentary EPERM is retried instead of
    surfacing as a dead cadence.

.DESCRIPTION
    The daemon writes a schedule record by renaming a temporary file over
    `C:\Users\<user>\.paseo\schedules\<id>.json`. That rename races the daemon's
    own readers/writers and can fail `EPERM: operation not permitted`. Measured
    twice on 2026-11-03 (bead cl-common-q8k):

      FIRE path   a one-shot's only run ended `status=failed, agentId=null` on the
                  EPERM; `maxRuns: 1` spent the whole budget and no agent existed.
      UPDATE path `paseo_update_schedule` failed hard while a Hub re-armed its own
                  rung. Four seconds later an exclusive open of the same file
                  succeeded and no `.tmp` remained - momentary write contention,
                  not a leaked handle. The identical update then succeeded.

    A transient failure must therefore be retried, not surfaced. This wrapper
    bounds that retry: it runs one write callable, classifies each failure
    (transient schedule-state contention vs a permanent rejection), waits an
    exponential backoff, and - when a verify step is supplied - re-reads the
    record and treats "the call returned but the record does not show it" as a
    retry too. That last case is the silent one: an update that returns OK while
    `nextRunAt` stays null has not re-armed anything.

    It never writes the record itself. The write is the caller's callable; this
    script owns only the callable surface and the final error, so it is safe
    beside a live daemon.

    The retry POLICY itself - the transient classifier, the exponential backoff
    and the atomic publish - is not implemented here. It is owned once by
    `AtomicRecordWrite.ps1`, the single implementation of "publish a JSON record
    atomically under contention" (bead cl-common-2jz). That file also serves
    `HubRegistry.ps1`, so a schedule write and a registry write can never drift
    into two different retry behaviours.

    TWO SURFACES, because a Hub has two kinds of write:

      scripted      `-Invoke { ... }` or `-InvokeScriptPath <file.ps1>` - any
                    callable. Retried here, each attempt receiving the attempt
                    number as `$args[0]` / `-Attempt <n>`, with `-Verify` /
                    `-VerifyScriptPath` read-back when the record can be read.
      agent-driven  a Hub's schedule writes are MCP tool calls
                    (`paseo_create_schedule`, `paseo_update_schedule`), which no
                    PowerShell process can invoke. For those, pass the tool's
                    error text and the attempt number (`-ErrorText ... -Attempt n`)
                    and the same classifier answers `RETRY <n> delayMs=<m>`
                    (exit 0) or `STOP ...` (exit 1), so the agent's retry loop is
                    mechanical and the final error names the schedule id and the
                    operation.

    Exit codes
      0  the write landed (attempt N/attempts), or `RETRY` in classify mode
      1  FAILED - attempts exhausted, a permanent rejection, or a write that the
         read-back never confirmed. The message names the schedule id, the
         operation and the last error; never report the cadence as armed on it.
      2  CANNOT-EVALUATE - the call was not supplied correctly (more than one, or
         none, of the three write surfaces; a missing -ScheduleId). An
         unevaluable retry is never a pass.

.PARAMETER Operation
    The write being attempted: `create`, `update`, `rearm`, `delete` or `verify`.
    Named verbatim in every message so a log line says what failed. `rearm` is an
    `update` whose intent is a future fire; pass a verify step that proves
    `nextRunAt` is no longer null, because a completed `maxRuns`-exhausted record
    is NOT re-armed by a bare update (measured 2026-11-03, bead cl-common-q8k) -
    recreate it instead.

.PARAMETER ScheduleId
    The schedule id the write is about. Required for `update`, `rearm`, `delete`
    and `verify`; optional for `create` (whose id does not exist yet) - pass
    `<new>` there if the id is only known after the call.

.PARAMETER Invoke
    The write callable. Receives the attempt number as `$args[0]`. Throw on
    failure.

.PARAMETER InvokeScriptPath
    The same write, as a script file. Run as
    `pwsh -NoProfile -File <path> -Attempt <n>`; a non-zero exit is a failure and
    its output is the error text.

.PARAMETER Verify
    Optional read-back assertion run after a successful write and before the
    attempt is accepted. Receives the attempt number as `$args[0]` and must return
    a truthy value (not `$false`, `$null`, `0` or `''`). A falsy result is
    treated as transient-not-yet-landed and retried.

.PARAMETER VerifyScriptPath
    The same read-back, as a script file: exit 0 means confirmed, non-zero means
    not yet landed.

.PARAMETER ErrorText
    Classify-only mode: the error text a write returned (typically an MCP tool
    error). Prints the retry instruction, writes nothing, calls nothing.

.PARAMETER Attempt
    In classify-only mode, which attempt just failed (1-based). Default 1.

.PARAMETER Attempts
    Bounded attempt count, including the first. Default 4. Nothing retries
    forever: a cadence that cannot be armed must be reported, not looped on.

.PARAMETER InitialDelayMilliseconds
    Backoff for the first retry. Default 250 ms.

.PARAMETER MaxDelayMilliseconds
    Cap for the exponential backoff. Default 4000 ms. The second live occurrence
    cleared in under 4 seconds, so the default cap covers it inside four attempts.

.PARAMETER TransientPattern
    Regex that overrides the transient classification. Defaults to the shared
    owner's set (EPERM, EACCES, EBUSY, ETXTBSY, `operation not permitted`,
    `resource busy`, `text file busy`, a Windows sharing violation, a
    `.tmp`/`rename` signature) - see `Get-AtomicWriteTransientPattern`.

.PARAMETER Json
    Emit the outcome as JSON (schemaVersion 1).

.EXAMPLE
    # Scripted path: retry the write, then prove the record was re-armed.
    pwsh Invoke-ScheduleRecordWrite.ps1 -Operation rearm -ScheduleId b3fdf56a `
        -InvokeScriptPath .\rearm-b3fdf56a.ps1 `
        -VerifyScriptPath .\assert-b3fdf56a-armed.ps1

.EXAMPLE
    # Agent-driven MCP retry: the tool failed with EPERM on attempt 2 of 4.
    pwsh Invoke-ScheduleRecordWrite.ps1 -Operation update -ScheduleId b3fdf56a `
        -ErrorText "EPERM: operation not permitted, rename '...\b3fdf56a.json.51220.tmp' -> '...\b3fdf56a.json'" -Attempt 2
    # -> RETRY (exit 0)

.EXAMPLE
    # After the write, assert the dispatch produced an agent (bead cl-common-q8k).
    pwsh Test-ScheduleDispatch.ps1 -ScheduleId b3fdf56a
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('create', 'update', 'rearm', 'delete', 'verify')]
    [string]$Operation,

    [string]$ScheduleId,

    [scriptblock]$Invoke,

    [string]$InvokeScriptPath,

    [scriptblock]$Verify,

    [string]$VerifyScriptPath,

    [string]$ErrorText,

    [ValidateRange(1, 1000)]
    [int]$Attempt = 1,

    [ValidateRange(1, 50)]
    [int]$Attempts = 4,

    [ValidateRange(0, 60000)]
    [int]$InitialDelayMilliseconds = 250,

    [ValidateRange(0, 600000)]
    [int]$MaxDelayMilliseconds = 4000,

    [string]$TransientPattern,

    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:PwshPath = (Get-Command pwsh -ErrorAction Stop).Source

function Stop-CannotEvaluate {
    param([Parameter(Mandatory)][string]$Reason)

    $message = "CANNOT-EVALUATE - $Reason"
    if ($Json) {
        [ordered]@{
            schemaVersion = 1
            verdict       = 'cannot-evaluate'
            operation     = $Operation
            scheduleId    = if ([string]::IsNullOrWhiteSpace($ScheduleId)) { $null } else { $ScheduleId }
            exitCode      = 2
            reason        = $message
        } | ConvertTo-Json -Depth 6
    }
    else {
        Write-Output ("Invoke-ScheduleRecordWrite: {0}" -f $message)
    }
    exit 2
}

# The retry policy and the atomic publish live in ONE place (bead cl-common-2jz):
# `AtomicRecordWrite.ps1`, which HubRegistry.ps1 also publishes through. A missing
# owner is unevaluable, never a licence to fall back to a local copy of the loop.
$script:AtomicWriteOwnerPath = Join-Path $PSScriptRoot 'AtomicRecordWrite.ps1'
if (-not (Test-Path -LiteralPath $script:AtomicWriteOwnerPath -PathType Leaf)) {
    Stop-CannotEvaluate ("the shared atomic-write owner is missing: {0} - the retry policy must not be re-implemented here" -f $script:AtomicWriteOwnerPath)
}
. $script:AtomicWriteOwnerPath

function Test-TransientError {
    <#
        Delegates to the shared owner (AtomicRecordWrite.ps1): one classifier for
        schedule records and registry records, so the two surfaces cannot drift.
    #>
    param([AllowNull()][string]$Text)

    return Test-AtomicWriteTransientError -Text $Text -Pattern $TransientPattern
}

function Test-Truthy {
    <#
        A read-back assertion is satisfied only by a real value: `$false`, `$null`,
        0 and the empty string all mean "the record does not show it", so the
        attempt is not accepted. An empty collection is the same non-answer.
    #>
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return $false }
    if ($Value -is [bool]) { return [bool]$Value }
    if ($Value -is [string]) { return -not [string]::IsNullOrWhiteSpace($Value) }
    if ($Value -is [System.Collections.IEnumerable]) {
        foreach ($item in $Value) { return $true }
        return $false
    }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) { return ([double]$Value -ne 0) }
    return $true
}

function Get-BackoffMilliseconds {
    # Delegates to the shared owner's backoff (same curve, same cap).
    param([Parameter(Mandatory)][int]$RetryIndex)

    return Get-AtomicWriteBackoffMilliseconds -RetryIndex $RetryIndex `
        -InitialDelayMilliseconds $InitialDelayMilliseconds -MaxDelayMilliseconds $MaxDelayMilliseconds
}

function Get-Signature {
    # Classified by the shared owner; LABELLED for this surface's existing output
    # contract, which names a schedule-state write in every retry line and JSON
    # verdict. The label is this script's API, not the owner's classification.
    param([AllowNull()][string]$Text)

    if ((Get-AtomicWriteSignature -Text $Text) -eq 'record-write-contention') { return 'schedule-state-write' }
    return 'other'
}

function Format-ShortError {
    # Delegates to the shared owner's short-error formatter.
    param([AllowNull()][string]$Text)

    return Format-AtomicWriteError -Text $Text
}

function Invoke-ChildStep {
    <#
        Run one step as a child process. A non-zero exit is the failure; the
        captured output (stdout and stderr) is the error text the classifier
        reads, so a fixture or a CLI reports exactly the way the daemon does.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][int]$AttemptNumber
    )

    $output = & $script:PwshPath -NoProfile -File $Path -Attempt $AttemptNumber 2>&1 | Out-String
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output   = $output.Trim()
    }
}

# --- surface validation -------------------------------------------------------
$invokeSurfaces = @(
    @(
        @{ Name = '-Invoke'; Present = ($null -ne $Invoke) }
        @{ Name = '-InvokeScriptPath'; Present = (-not [string]::IsNullOrWhiteSpace($InvokeScriptPath)) }
        @{ Name = '-ErrorText'; Present = (-not [string]::IsNullOrWhiteSpace($ErrorText)) }
    ) | Where-Object { $_.Present }
)

if ($invokeSurfaces.Count -ne 1) {
    Stop-CannotEvaluate ('pass exactly one write surface (-Invoke, -InvokeScriptPath or -ErrorText); got {0}' -f `
        $(if ($invokeSurfaces.Count -eq 0) { 'none' } else { ($invokeSurfaces | ForEach-Object { $_.Name }) -join ', ' }))
}
if ($null -ne $Verify -and -not [string]::IsNullOrWhiteSpace($VerifyScriptPath)) {
    Stop-CannotEvaluate 'pass at most one read-back (-Verify or -VerifyScriptPath)'
}
if ([string]::IsNullOrWhiteSpace($ScheduleId) -and $Operation -ne 'create') {
    Stop-CannotEvaluate ("-ScheduleId is required for operation '{0}': the final error must name the record it is about" -f $Operation)
}
if ((-not [string]::IsNullOrWhiteSpace($InvokeScriptPath)) -and -not (Test-Path -LiteralPath $InvokeScriptPath -PathType Leaf)) {
    Stop-CannotEvaluate ("the write script does not exist: {0}" -f $InvokeScriptPath)
}
if ((-not [string]::IsNullOrWhiteSpace($VerifyScriptPath)) -and -not (Test-Path -LiteralPath $VerifyScriptPath -PathType Leaf)) {
    Stop-CannotEvaluate ("the read-back script does not exist: {0}" -f $VerifyScriptPath)
}

$subject = if ([string]::IsNullOrWhiteSpace($ScheduleId)) { '<new>' } else { $ScheduleId }

# --- classify-only surface ---------------------------------------------------
if (-not [string]::IsNullOrWhiteSpace($ErrorText)) {
    $transient = Test-TransientError -Text $ErrorText

    if ($transient -and $Attempt -lt $Attempts) {
        $delay = Get-BackoffMilliseconds -RetryIndex $Attempt
        if ($Json) {
            [ordered]@{
                schemaVersion = 1
                verdict       = 'retry'
                exitCode      = 0
                operation     = $Operation
                scheduleId    = $subject
                attempt       = $Attempt
                maxAttempts   = $Attempts
                delayMs       = $delay
                transient     = $true
                signature     = Get-Signature -Text $ErrorText
                reason        = 'the failure is schedule-state write contention; retry after the delay'
            } | ConvertTo-Json -Depth 6
        }
        else {
            Write-Output ("Invoke-ScheduleRecordWrite: RETRY operation={0} schedule={1} attempt={2}/{3} delayMs={4} - transient schedule-state contention ({5})" -f `
                    $Operation, $subject, $Attempt, $Attempts, $delay, (Get-Signature -Text $ErrorText))
        }
        exit 0
    }

    $reason = if ($transient) {
        "attempts exhausted ({0}/{1}) on a transient schedule-state write failure" -f $Attempt, $Attempts
    }
    else {
        'the failure is not transient (no schedule-state contention signature), so retrying cannot clear it'
    }

    if ($Json) {
        [ordered]@{
            schemaVersion = 1
            verdict       = 'stop'
            exitCode      = 1
            operation     = $Operation
            scheduleId    = $subject
            attempt       = $Attempt
            maxAttempts   = $Attempts
            delayMs       = 0
            transient     = $transient
            lastError     = $ErrorText
            reason        = $reason
        } | ConvertTo-Json -Depth 6
    }
    else {
        Write-Output ("Invoke-ScheduleRecordWrite: STOP operation={0} schedule={1} attempt={2}/{3} - {4}. lastError={5}" -f `
                $Operation, $subject, $Attempt, $Attempts, $reason, (Format-ShortError -Text $ErrorText))
        Write-Output ("  action: {0}" -f $(if ($transient) {
                    'do not report the cadence as armed; recreate the record and write the failure on the bead'
                }
                else { 'fix the rejection; a retry loop cannot clear it' }))
    }
    exit 1
}

# --- scripted write surface --------------------------------------------------
$entries = [System.Collections.Generic.List[object]]::new()
$lastError = $null
$cause = $null
$success = $false
$successAttempt = 0
$hasVerify = ($null -ne $Verify) -or (-not [string]::IsNullOrWhiteSpace($VerifyScriptPath))

for ($attemptNumber = 1; $attemptNumber -le $Attempts; $attemptNumber++) {
    $outcome = 'succeeded'
    $failure = $null
    $transient = $false

    try {
        if ($null -ne $Invoke) {
            $null = & $Invoke $attemptNumber
        }
        else {
            $step = Invoke-ChildStep -Path $InvokeScriptPath -AttemptNumber $attemptNumber
            if ($step.ExitCode -ne 0) { throw $step.Output }
        }
    }
    catch {
        $failure = $_.Exception.Message
        $outcome = 'failed'
        $transient = Test-TransientError -Text $failure
    }

    if ($outcome -eq 'succeeded' -and $hasVerify) {
        try {
            $verified = if ($null -ne $Verify) {
                & $Verify $attemptNumber
            }
            else {
                $step = Invoke-ChildStep -Path $VerifyScriptPath -AttemptNumber $attemptNumber
                if ($step.ExitCode -ne 0) { throw $step.Output }
                $true
            }
            if (-not (Test-Truthy -Value $verified)) {
                $outcome = 'unconfirmed'
                $failure = 'the write returned but the record read-back did not confirm it'
                $transient = $true
            }
        }
        catch {
            $outcome = 'unconfirmed'
            $failure = "the record read-back threw: $($_.Exception.Message)"
            $transient = $true
        }
    }

    if ($outcome -eq 'succeeded') {
        $success = $true
        $successAttempt = $attemptNumber
        $entries.Add([pscustomobject]@{ Attempt = $attemptNumber; Outcome = 'succeeded'; Error = $null; DelayMs = 0 })
        break
    }

    $lastError = $failure
    $delay = 0
    if ($transient -and $attemptNumber -lt $Attempts) { $delay = Get-BackoffMilliseconds -RetryIndex $attemptNumber }
    $entries.Add([pscustomobject]@{ Attempt = $attemptNumber; Outcome = $outcome; Error = $failure; DelayMs = $delay })

    if (-not $transient) {
        $cause = 'permanent'
        break
    }
    if ($attemptNumber -ge $Attempts) {
        $cause = 'attempts-exhausted'
        break
    }

    if (-not $Json) {
        Write-Output ("Invoke-ScheduleRecordWrite: retry operation={0} schedule={1} attempt={2}/{3} delayMs={4} - {5} ({6})" -f `
                $Operation, $subject, $attemptNumber, $Attempts, $delay, (Get-Signature -Text $lastError), (Format-ShortError -Text $lastError))
    }
    if ($delay -gt 0) { Start-Sleep -Milliseconds $delay }
}

if ($success) {
    if ($Json) {
        [ordered]@{
            schemaVersion = 1
            verdict       = 'ok'
            exitCode      = 0
            operation     = $Operation
            scheduleId    = $subject
            attempt       = $successAttempt
            maxAttempts   = $Attempts
            verified      = $hasVerify
            attempts      = @($entries | ForEach-Object { [ordered]@{ attempt = $_.Attempt; outcome = $_.Outcome; error = $_.Error; delayMs = $_.DelayMs } })
        } | ConvertTo-Json -Depth 6
    }
    else {
        Write-Output ("Invoke-ScheduleRecordWrite: OK operation={0} schedule={1} attempt={2}/{3}{4}" -f `
                $Operation, $subject, $successAttempt, $Attempts, $(if ($hasVerify) { ' (read-back confirmed)' } else { '' }))
    }
    exit 0
}

$reasonText = switch ($cause) {
    'permanent' { 'the failure is not transient, so retrying cannot clear it' }
    'attempts-exhausted' { "attempts exhausted ($Attempts/$Attempts) on transient schedule-state write failures" }
    default { 'the write did not land' }
}

if ($Json) {
    [ordered]@{
        schemaVersion = 1
        verdict       = 'failed'
        exitCode      = 1
        operation     = $Operation
        scheduleId    = $subject
        attempt       = $entries.Count
        maxAttempts   = $Attempts
        cause         = $cause
        lastError     = $lastError
        reason        = $reasonText
        attempts      = @($entries | ForEach-Object { [ordered]@{ attempt = $_.Attempt; outcome = $_.Outcome; error = $_.Error; delayMs = $_.DelayMs } })
    } | ConvertTo-Json -Depth 6
}
else {
    Write-Output ("Invoke-ScheduleRecordWrite: FAILED operation={0} schedule={1} attempt={2}/{3} cause={4} - {5}. lastError={6}" -f `
            $Operation, $subject, $entries.Count, $Attempts, $cause, $reasonText, (Format-ShortError -Text $lastError))
    Write-Output ("  action: {0}" -f $(if ($cause -eq 'attempts-exhausted') {
                'do not report the cadence as armed; recreate the record and record the failure on the bead'
            }
            else { 'fix the rejection; a retry loop cannot clear it' }))
}
exit 1
