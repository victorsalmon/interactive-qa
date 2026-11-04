#Requires -Version 7
<#
.SYNOPSIS
    The single owner of "publish a JSON record atomically under contention".

.DESCRIPTION
    Every durable JSON record on this machine is published the same way: write a
    temporary file beside the target, then rename it over the target, so a reader
    sees either the whole old record or the whole new one - never a half-written
    file. On Windows that rename is the contended step. A rename needs DELETE
    access on the destination, so if ANY other process holds the destination open
    (a reader mid-`Get-Content`, another writer's rename in flight) the move fails
    with `EPERM` or a sharing violation (`ERROR_SHARING_VIOLATION`, 32), even
    though nothing is wrong with the record or the disk.

    Measured twice on 2026-11-03 for schedule records (bead cl-common-q8k):

      FIRE path    a one-shot's only run ended `status=failed, agentId=null` on
                   the EPERM; `maxRuns: 1` spent the whole budget.
      UPDATE path  `paseo_update_schedule` failed hard while a Hub re-armed its
                   own rung; four seconds later an exclusive open of the same
                   file succeeded and no `.tmp` remained - momentary contention,
                   not a leaked handle.

    and once for the hub registry (bead cl-common-2jz): `HubRegistry.ps1`
    published `~/.salmon/State/hubs/<repo>.json` with a bare rename and no retry,
    so one unlucky overlap between a heartbeat write and a `Find` read could fail
    the heartbeat - and a stale entry makes a LIVE hub look `dead`, which is what
    licenses a takeover.

    So the policy lives here, ONCE:

      - transient classification (EPERM / EACCES / EBUSY / ETXTBSY / a Windows
        sharing violation / a `.tmp`-rename signature) versus a permanent
        rejection a retry cannot clear;
      - exponential backoff with a bounded attempt count and a delay cap;
      - the atomic publish itself (`Write-JsonRecordAtomic`): one temp file, a
        replace-rename, retried within that budget, and a NAMED
        `ATOMIC-WRITE-FAILED ...` error when the budget is spent - never a
        silent success and never a silently missing record.

    Consumers dot-source this file; they never re-implement the loop:

      HubRegistry.ps1                registry record (Register / Heartbeat / Clear)
      Invoke-ScheduleRecordWrite.ps1 retry policy for the daemon's schedule writes
                                     (an MCP tool call cannot be made from
                                     PowerShell, so that script owns only the
                                     callable surface and reuses this policy)

    The publish is a single replace-rename, never delete-then-write: a failed
    publish therefore leaves the PREVIOUS valid record byte-for-byte in place.
    That is what makes "retried and succeeded" and "failed and changed nothing"
    the only two outcomes.

.EXAMPLE
    # Publish a record with the default budget (4 attempts, 250 ms -> 4 s cap).
    . ./AtomicRecordWrite.ps1
    Write-JsonRecordAtomic -Path "$HOME/.salmon/State/hubs/cl-common.json" -Value $record

.EXAMPLE
    # Judge a failure someone else reported (an MCP tool error) with the same classifier.
    . ./AtomicRecordWrite.ps1
    Test-AtomicWriteTransientError -Text "EPERM: operation not permitted, rename '...tmp' -> '...json'"
    # -> True
#>

Set-StrictMode -Version Latest

# The default transient set. It covers the Node/daemon wording (`EPERM: operation
# not permitted, rename '<x>.tmp' -> '<y>'`), the .NET wording on Windows ("The
# process cannot access the file because it is being used by another process"),
# and the raw HResult/errno names, so the same classifier answers for a schedule
# record and for a registry record.
$script:AtomicWriteDefaultTransientPattern = @(
    'EPERM'
    'EACCES'
    'EBUSY'
    'ETXTBSY'
    'operation not permitted'
    'resource busy'
    'text file busy'
    'sharing violation'
    'ERROR_SHARING_VIOLATION'
    'ERROR_LOCK_VIOLATION'
    '0x80070020'
    '0x80070021'
    # Windows reports a rename over a file another process holds open as
    # ERROR_ACCESS_DENIED (5) as often as ERROR_SHARING_VIOLATION (32); .NET
    # surfaces the first as UnauthorizedAccessException. Measured 2026-11-03 with
    # a reader holding the registry record: `File.Move(overwrite)` threw
    # "Access to the path is denied." (0x80070005), not a sharing violation.
    '0x80070005'
    'UnauthorizedAccessException'
    'Access to the path .* is denied'
    'cannot access the file'
    'being used by another process'
    "rename\s+'[^']*\.tmp'"
    'schedules[\\/][0-9a-fA-F]{6,}\.json\.[^\s'']*\.tmp'
) -join '|'

function Get-AtomicWriteTransientPattern {
    <#
    .SYNOPSIS
        The default transient-failure regex this owner classifies with.
    #>
    $script:AtomicWriteDefaultTransientPattern
}

function Test-AtomicWriteTransientError {
    <#
    .SYNOPSIS
        Is this failure transient write contention (retry) or a permanent
        rejection (stop)?

    .DESCRIPTION
        Fail-closed on the side of not retrying forever: an empty or unmatched
        text is NOT transient. A transient verdict is only ever granted to a
        text that carries a contention signature, so a validation error can
        never be looped on.
    #>
    param(
        [AllowNull()][string]$Text,
        [string]$Pattern
    )

    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    $effective = if ([string]::IsNullOrWhiteSpace($Pattern)) { $script:AtomicWriteDefaultTransientPattern } else { $Pattern }
    return [bool]([regex]::IsMatch($Text, $effective, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase))
}

function Get-AtomicWriteSignature {
    <#
    .SYNOPSIS
        A short, stable label for a failure, so a log line says what class of
        failure was retried instead of repeating the whole OS message.
    #>
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return 'unknown' }
    if (Test-AtomicWriteTransientError -Text $Text) { return 'record-write-contention' }
    return 'other'
}

function Get-AtomicWriteBackoffMilliseconds {
    <#
    .SYNOPSIS
        Exponential backoff for retry N (1-based), capped.

    .DESCRIPTION
        Retry 1 waits InitialDelayMilliseconds, retry 2 doubles it, and so on,
        never above MaxDelayMilliseconds. The measured contention cleared in
        under four seconds, so the default cap covers it inside four attempts.
    #>
    param(
        [Parameter(Mandatory)][int]$RetryIndex,
        [int]$InitialDelayMilliseconds = 250,
        [int]$MaxDelayMilliseconds = 4000
    )

    if ($RetryIndex -le 0) { return 0 }
    $delay = [double]$InitialDelayMilliseconds * [math]::Pow(2, $RetryIndex - 1)
    if ($delay -gt $MaxDelayMilliseconds) { $delay = $MaxDelayMilliseconds }
    return [int][math]::Round($delay)
}

function Format-AtomicWriteError {
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return '<none>' }
    $single = ($Text -replace '\s+', ' ').Trim()
    if ($single.Length -gt 240) { return $single.Substring(0, 240) + '...' }
    return $single
}

function Write-JsonRecordAtomic {
    <#
    .SYNOPSIS
        Publish a JSON record atomically, retrying the contended rename.

    .DESCRIPTION
        Writes `$Value` as JSON to `<Path>.tmp-<pid>` once, then renames it over
        `$Path` with `[System.IO.File]::Move(..., overwrite: true)` - a single
        replace-rename, so the destination is never truncated and never removed
        before the replacement is in place. A failed attempt is classified and
        retried with exponential backoff; the temp file survives between attempts
        (the source of a failed rename is untouched) and is removed on final
        failure.

        On success returns a result object (Ok/Path/Attempt/Attempts/AttemptLog).
        On failure throws `System.InvalidOperationException` whose message begins
        `ATOMIC-WRITE-FAILED` and names the path, the cause and the last error.
        Callers must surface that as a failure: the record was NOT published.

    .PARAMETER Path
        The destination record. Its directory is created when missing.

    .PARAMETER Value
        The record to serialize. Any object `ConvertTo-Json` can render.

    .PARAMETER Depth
        Serialization depth. Default 8 (the registry's nested-entry shape).

    .PARAMETER Attempts
        Bounded attempt count, including the first. Default 4.

    .PARAMETER InitialDelayMilliseconds
        Backoff for the first retry. Default 250 ms.

    .PARAMETER MaxDelayMilliseconds
        Cap for the exponential backoff. Default 4000 ms.

    .PARAMETER TransientPattern
        Regex overriding the transient classification.

    .PARAMETER OnRetry
        Optional callback, invoked as `& $OnRetry $attempt $delayMs $errorText`
        before each backoff wait. Diagnostics only; it must not write records.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowNull()]$Value,
        [ValidateRange(1, 100)][int]$Depth = 8,
        [ValidateRange(1, 50)][int]$Attempts = 4,
        [ValidateRange(0, 60000)][int]$InitialDelayMilliseconds = 250,
        [ValidateRange(0, 600000)][int]$MaxDelayMilliseconds = 4000,
        [string]$TransientPattern,
        [scriptblock]$OnRetry
    )

    $target = [System.IO.Path]::GetFullPath($Path)
    $dir = Split-Path -Parent $target
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        $null = New-Item -ItemType Directory -Path $dir -Force
    }

    $json = $Value | ConvertTo-Json -Depth $Depth
    $tempPath = '{0}.tmp-{1}' -f $target, $PID
    $attemptLog = [System.Collections.Generic.List[object]]::new()

    try {
        Set-Content -LiteralPath $tempPath -Value $json -Encoding utf8NoBOM -ErrorAction Stop
    }
    catch {
        Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        throw [System.InvalidOperationException]::new(
            ('ATOMIC-WRITE-FAILED path={0} cause=temp-write lastError={1}' -f $target, (Format-AtomicWriteError -Text $_.Exception.Message)))
    }

    $lastError = $null
    $cause = 'did-not-run'

    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        try {
            [System.IO.File]::Move($tempPath, $target, $true)
            $attemptLog.Add([pscustomobject]@{ Attempt = $attempt; Outcome = 'succeeded'; Error = $null; DelayMs = 0 })
            return [pscustomobject]@{
                Ok         = $true
                Path       = $target
                TempPath   = $tempPath
                Attempt    = $attempt
                Attempts   = $Attempts
                AttemptLog = @($attemptLog)
                LastError  = $null
                Cause      = $null
            }
        }
        catch {
            # Classify on the MACHINE-READABLE signature, not only the prose: the
            # type name and HResult survive localization and survive PowerShell's
            # MethodInvocationException wrapper, while "Access to the path is
            # denied." is exactly what a denied delete-share looks like.
            $base = $_.Exception.GetBaseException()
            $lastError = '{0} (0x{1:X8}): {2}' -f $base.GetType().Name, $base.HResult, $base.Message
            $transient = Test-AtomicWriteTransientError -Text $lastError -Pattern $TransientPattern
            $delay = 0
            if ($transient -and $attempt -lt $Attempts) {
                $delay = Get-AtomicWriteBackoffMilliseconds -RetryIndex $attempt `
                    -InitialDelayMilliseconds $InitialDelayMilliseconds -MaxDelayMilliseconds $MaxDelayMilliseconds
            }
            $attemptLog.Add([pscustomobject]@{
                    Attempt = $attempt
                    Outcome = $(if ($transient) { 'contended' } else { 'rejected' })
                    Error   = $lastError
                    DelayMs = $delay
                })

            if (-not $transient) { $cause = 'permanent'; break }
            if ($attempt -ge $Attempts) { $cause = 'attempts-exhausted'; break }

            if ($null -ne $OnRetry) { & $OnRetry $attempt $delay $lastError }
            if ($delay -gt 0) { Start-Sleep -Milliseconds $delay }
        }
    }

    # Nothing was published, so do not leave the temp file behind as debris.
    Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue

    throw [System.InvalidOperationException]::new(
        ('ATOMIC-WRITE-FAILED path={0} cause={1} attempt={2}/{3} lastError={4}' -f `
                $target, $cause, $attemptLog.Count, $Attempts, (Format-AtomicWriteError -Text $lastError)))
}
