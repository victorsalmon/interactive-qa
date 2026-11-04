#Requires -Version 7.0
<#
.SYNOPSIS
    Orchestration and IO for Invoke-KeyCheck.ps1 (Key Check).

.DESCRIPTION
    Dot-source this file. Everything here touches the machine - the run lock,
    the resumable state file, the detached cutover helper - so none of it
    belongs in lib/KeyCheck.Decision.ps1, which stays pure and IO-free.
    Dot-source lib/KeyCheck.Decision.ps1 FIRST: the reset-time parser lives
    there and this file uses it to read timestamps back out of JSON.

    Three facts shape this file:

      1. ONE live run per machine. Two watches that read the same state both see
         the same threshold crossing and both cut over; the second repair then
         restarts Paseo underneath the first. The lock is the guard.

      2. A interrupted run must resume, not restart. The deadline is fixed and is
         never extended, so a reboot, an operator Ctrl-C, or the restart the
         cutover itself causes may not silently begin a fresh window.

      3. A helper launched from an agent-hosted shell MAY die with it. Windows
         does not cascade kills by itself, but an agent host can wrap its process
         tree in a Job Object, and `paseo restart` kills that tree. Measured
         2026-11-02 on this host: BOTH mechanisms (Start-Process and
         Win32_Process.Create) survived a force-killed launcher, in the plain
         shell and in the agent chain alike; survival across a real
         `paseo restart` is UNPROVEN. So survivability is environment-dependent,
         and the cutover does not rely on it:
           - the helper is created with Win32_Process.Create because that child is
             outside the caller's job object BY CONSTRUCTION (a design argument,
             not a measurement), and
           - the helper writes its outcome BEFORE the restart, so a helper that
             dies is finished by the next invocation.
         Start-Process is only reachable through the explicit
         -AllowProcessFallback opt-in, which is still safe because of that
         outcome - slower to prove, not wrong. `scripts/Test-KeyCheckDetachment.ps1`
         measures one chain on one host; it is not a universal claim.

    SECURITY: nothing here reads or prints a key value. Lock and state files hold
    key NUMBERS and counters only.
#>

# ------------------------------------------------------------------- paths ---

function Get-KeyCheckCutoverOutcomePath {
    <#
    .SYNOPSIS
        Where the detached helper writes its outcome for one run.
    #>
    param([Parameter(Mandatory)][string]$Dir, [Parameter(Mandatory)][string]$RunId)

    return (Join-Path $Dir "$RunId-cutover.json")
}

# -------------------------------------------------------------------- lock ---

function Read-KeyCheckLock {
    <#
    .SYNOPSIS
        The lock file as an object, or $null when absent/unparsable.
    #>
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $raw = Get-Content -LiteralPath $Path -Raw
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return ($raw | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Test-KeyCheckProcessAlive {
    <#
    .SYNOPSIS
        True when a pid names a live process on this machine.
    .DESCRIPTION
        A recycled pid is indistinguishable from the original holder, which is
        why the heartbeat age is checked as well - a live-looking pid with a
        stale heartbeat is a crash, not a holder.
    #>
    param([int]$ProcessId = 0)

    if ($ProcessId -le 0) { return $false }
    try {
        $p = Get-Process -Id $ProcessId -ErrorAction Stop
        return ($null -ne $p)
    } catch {
        return $false
    }
}

function New-KeyCheckLockObject {
    param(
        [Parameter(Mandatory)][string]$RunId,
        [int]$ProcessId = $PID,
        [string]$HostName = $env:COMPUTERNAME,
        [datetime]$Now = (Get-Date)
    )
    return [pscustomobject]@{
        pid         = $ProcessId
        host        = $HostName
        runId       = $RunId
        startedAt   = $Now.ToString('o')
        heartbeatAt = $Now.ToString('o')
    }
}

function Write-KeyCheckLockFile {
    <#
    .SYNOPSIS
        Atomically create the lock file. False when another process won the race.
    .DESCRIPTION
        FileMode.CreateNew is the atomic test-and-set: the loser gets an
        IOException instead of a silently overwritten lock.
    #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Lock)

    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
    $json = $Lock | ConvertTo-Json -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
    } catch {
        return $false
    }
    try {
        $stream.Write($bytes, 0, $bytes.Length)
    } finally {
        $stream.Dispose()
    }
    return $true
}

function Get-KeyCheckLockState {
    <#
    .SYNOPSIS
        Is the lock held, and is that holder still alive?
    .DESCRIPTION
        A lock is STALE when its pid is dead or its heartbeat is older than
        `StaleSeconds` (three poll intervals). Staleness is what makes a crashed
        run recoverable without a `-Force` and without a human.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [datetime]$Now = (Get-Date),
        [int]$StaleSeconds = 180
    )

    $lock = Read-KeyCheckLock -Path $Path
    if ($null -eq $lock) {
        return [pscustomobject]@{
            Exists = $false; Stale = $false; Reason = 'free'; Lock = $null
            AgeSeconds = 0; HeartbeatAgeSeconds = 0; ProcessAlive = $false
        }
    }

    $pidValue = 0
    if ($lock.PSObject.Properties['pid']) {
        $null = [int]::TryParse([string]$lock.pid, [ref]$pidValue)
    }
    $alive = Test-KeyCheckProcessAlive -ProcessId $pidValue

    $startedAt = ConvertTo-KeyCheckResetTime -Text $(if ($lock.PSObject.Properties['startedAt']) { $lock.startedAt } else { '' })
    $heartbeatAt = ConvertTo-KeyCheckResetTime -Text $(if ($lock.PSObject.Properties['heartbeatAt']) { $lock.heartbeatAt } else { '' })
    $age = if ($null -ne $startedAt) { [int]([Math]::Max(0, ($Now - $startedAt).TotalSeconds)) } else { -1 }
    $beatAge = if ($null -ne $heartbeatAt) { [int]([Math]::Max(0, ($Now - $heartbeatAt).TotalSeconds)) } else { -1 }

    $stale = (-not $alive) -or ($beatAge -lt 0) -or ($beatAge -gt $StaleSeconds)
    $reason = if (-not $alive) { 'pid-dead' }
              elseif ($beatAge -lt 0) { 'heartbeat-unreadable' }
              elseif ($beatAge -gt $StaleSeconds) { 'heartbeat-stale' }
              else { 'held' }

    return [pscustomobject]@{
        Exists = $true; Stale = $stale; Reason = $reason; Lock = $lock
        AgeSeconds = $age; HeartbeatAgeSeconds = $beatAge; ProcessAlive = $alive
    }
}

function Enter-KeyCheckLock {
    <#
    .SYNOPSIS
        Take the run lock, or report the live holder so the caller can exit 2.
    .DESCRIPTION
        Order: a free lock is created; a STALE lock (dead pid, or a heartbeat
        older than three intervals) is taken over and the takeover is reported
        for the audit; a live lock is respected unless -Force is given, which
        steals it deliberately and says so.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$RunId,
        [int]$StaleSeconds = 180,
        [datetime]$Now = (Get-Date),
        [int]$ProcessId = $PID,
        [string]$HostName = $env:COMPUTERNAME,
        [switch]$Force
    )

    $newLock = New-KeyCheckLockObject -RunId $RunId -ProcessId $ProcessId -HostName $HostName -Now $Now
    $existing = Get-KeyCheckLockState -Path $Path -Now $Now -StaleSeconds $StaleSeconds

    if (-not $existing.Exists) {
        if (Write-KeyCheckLockFile -Path $Path -Lock $newLock) {
            return [pscustomobject]@{
                Acquired = $true; Reason = 'acquired'; TakenOver = $false
                Holder = $null; HolderAgeSeconds = 0; PriorReason = 'free'
            }
        }
        # Lost the creation race: re-read and report the winner.
        $existing = Get-KeyCheckLockState -Path $Path -Now $Now -StaleSeconds $StaleSeconds
        return [pscustomobject]@{
            Acquired = $false; Reason = 'locked-by-run'; TakenOver = $false
            Holder = $existing.Lock; HolderAgeSeconds = $existing.AgeSeconds
            PriorReason = 'creation-race'
        }
    }

    if ($existing.Stale -or $Force) {
        $priorReason = if ($Force -and -not $existing.Stale) { 'forced' } else { $existing.Reason }
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        if (Write-KeyCheckLockFile -Path $Path -Lock $newLock) {
            return [pscustomobject]@{
                Acquired = $true
                Reason = $(if ($Force) { 'force-stolen' } else { 'stale-lock-taken-over' })
                TakenOver = $true
                Holder = $existing.Lock
                HolderAgeSeconds = $existing.AgeSeconds
                PriorReason = $priorReason
            }
        }
        return [pscustomobject]@{
            Acquired = $false; Reason = 'locked-by-run'; TakenOver = $false
            Holder = (Read-KeyCheckLock -Path $Path); HolderAgeSeconds = $existing.AgeSeconds
            PriorReason = 'takeover-race'
        }
    }

    return [pscustomobject]@{
        Acquired = $false; Reason = 'locked-by-run'; TakenOver = $false
        Holder = $existing.Lock; HolderAgeSeconds = $existing.AgeSeconds
        PriorReason = $existing.Reason
    }
}

function Update-KeyCheckLockHeartbeat {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$RunId,
        [datetime]$Now = (Get-Date)
    )

    $lock = Read-KeyCheckLock -Path $Path
    if ($null -eq $lock) { return $false }
    if ($lock.PSObject.Properties['runId'] -and [string]$lock.runId -ne $RunId) { return $false }
    $lock | Add-Member -NotePropertyName heartbeatAt -NotePropertyValue ($Now.ToString('o')) -Force
    Set-Content -LiteralPath $Path -Value ($lock | ConvertTo-Json -Compress) -Encoding utf8NoBOM
    return $true
}

function Exit-KeyCheckLock {
    <#
    .SYNOPSIS
        Release the lock - but only when this run still owns it.
    #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$RunId)

    $lock = Read-KeyCheckLock -Path $Path
    if ($null -eq $lock) { return $false }
    if ($lock.PSObject.Properties['runId'] -and [string]$lock.runId -ne $RunId) { return $false }
    Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    return $true
}

# ------------------------------------------------------------------- state ---

function Read-KeyCheckState {
    <#
    .SYNOPSIS
        The persisted run state, or $null when absent/unparsable.
    #>
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $raw = Get-Content -LiteralPath $Path -Raw
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return ($raw | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Complete-KeyCheckState {
    <#
    .SYNOPSIS
        Backfill fields a resumed (older, or partially written) state is missing.
    #>
    param($State, [hashtable]$Defaults = @{})

    if ($null -eq $State) { return $null }
    # Legacy unit shim, read once: an older state persists the trigger distance in
    # HOURS (`hoursToTrigger`); the run now carries ETT in MINUTES. Convert in
    # place so a resumed run keeps the cadence it earned, then drop the old field
    # - no second unit may survive the read.
    if ($State.PSObject.Properties['hoursToTrigger'] -and -not $State.PSObject.Properties['ettMinutes']) {
        $legacy = $State.hoursToTrigger
        $converted = if ($null -eq $legacy) { $null } else { [double]$legacy * 60 }
        $State | Add-Member -NotePropertyName ettMinutes -NotePropertyValue $converted
    }
    if ($State.PSObject.Properties['hoursToTrigger']) {
        $State.PSObject.Properties.Remove('hoursToTrigger')
    }
    # A state carrying only the brief's alias names is adopted, not zeroed.
    if (-not $State.PSObject.Properties['replacementKeyNumber'] -and $State.PSObject.Properties['replacementKey']) {
        $State | Add-Member -NotePropertyName replacementKeyNumber -NotePropertyValue ([int]$State.replacementKey)
    }
    if (-not $State.PSObject.Properties['deadlineAt'] -and $State.PSObject.Properties['deadline']) {
        $State | Add-Member -NotePropertyName deadlineAt -NotePropertyValue (Format-KeyCheckStateTimestamp $State.deadline)
    }
    foreach ($name in $Defaults.Keys) {
        if (-not $State.PSObject.Properties[$name]) {
            $State | Add-Member -NotePropertyName $name -NotePropertyValue $Defaults[$name]
        }
    }
    # JSON collapses a one-element array to a scalar; restore the shapes the
    # writer appends to, or a resumed run would concatenate strings.
    foreach ($name in @('evidence', 'cutovers', 'cadenceSamples')) {
        if ($State.PSObject.Properties[$name]) {
            $State | Add-Member -NotePropertyName $name -NotePropertyValue @($State.$name) -Force
        }
    }
    return $State
}

function Format-KeyCheckStateTimestamp {
    <#
    .SYNOPSIS
        Render a state timestamp as ISO-8601 without changing an instant.
    .DESCRIPTION
        A JSON round-trip re-types an ISO string as [datetime]. Casting that back
        with [string] would use the MACHINE culture and silently drop the
        fractional second and offset - so a re-saved deadline no longer equals the
        deadline it was created with. Dates are formatted explicitly; strings are
        left exactly as written.
    #>
    param($Value)

    if ($null -eq $Value) { return '' }
    if ($Value -is [datetime]) { return ([datetime]$Value).ToString('o') }
    if ($Value -is [datetimeoffset]) { return ([datetimeoffset]$Value).ToString('o') }
    return [string]$Value
}

function Write-KeyCheckState {
    <#
    .SYNOPSIS
        Persist the run state, with the brief's field aliases kept in step.
    .DESCRIPTION
        `deadlineAt` and `replacementKey` are the resumable names; `deadline` and
        `replacementKeyNumber` are kept because the decision lib and the older
        readers use them. One writer keeps them from diverging, and the
        `*Number` field is authoritative because it is the one the run mutates.
    #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$State)

    $deadline = Format-KeyCheckStateTimestamp $(if ($State.PSObject.Properties['deadlineAt'] -and $State.deadlineAt) { $State.deadlineAt }
            elseif ($State.PSObject.Properties['deadline']) { $State.deadline } else { '' })
    $replacement = if ($State.PSObject.Properties['replacementKeyNumber']) { [int]$State.replacementKeyNumber }
                   elseif ($State.PSObject.Properties['replacementKey']) { [int]$State.replacementKey } else { 0 }

    $State | Add-Member -NotePropertyName deadlineAt -NotePropertyValue $deadline -Force
    $State | Add-Member -NotePropertyName deadline -NotePropertyValue $deadline -Force
    $State | Add-Member -NotePropertyName replacementKey -NotePropertyValue $replacement -Force
    $State | Add-Member -NotePropertyName replacementKeyNumber -NotePropertyValue $replacement -Force
    # The pre-rename unit (`hoursToTrigger`) is dropped here too, so a state that
    # reached this writer without the read-time shim cannot persist two units.
    if ($State.PSObject.Properties['hoursToTrigger']) { $State.PSObject.Properties.Remove('hoursToTrigger') }

    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
    Set-Content -LiteralPath $Path -Value ($State | ConvertTo-Json -Depth 16) -Encoding utf8NoBOM
}

function Update-KeyCheckCadence {
    <#
    .SYNOPSIS
        Fold a cadence decision into the run state and return the audit line it
        earns - exactly one per gear CHANGE, $null when the gear did not move.
    .DESCRIPTION
        The audit trail is a reviewer's view of transitions, not of ticks: a run
        that holds 60 minutes for six hours writes nothing, and each change writes
        one line with the numbers that justified it (from/to seconds, the measured
        burn, the points left to the trigger, the reason). The same transition is
        appended to `cadenceChanges[]` in the state file so a resumed run - and a
        human reading state.json - keeps the whole cadence history.

        The run's own values are updated on EVERY call (they describe the latest
        evaluation), while the counters carry the hysteresis: `cadenceLoosenStreak`
        for the two-tick loosen rule and `cadenceFloorTicks` for the 1-minute cap.
    .PARAMETER State
        The live run state (mutated in place).
    .PARAMETER Decision
        The object returned by Get-KeyCheckCadenceGear.
    .PARAMETER RunId
        Stamped into the audit line.
    .PARAMETER Samples
        The per-meter sample ring to persist with this tick (may be omitted by a
        caller that only wants the decision folded in).
    .PARAMETER SampleSignature
        The reset-window signature the ring was recorded under.
    .PARAMETER SampleGeneration
        The run generation the ring was recorded under.
    .PARAMETER Phase
        The polling phase; stamped on the audit line so a reader can see which
        ceiling bounded the choice.
    #>
    param(
        $State,
        $Decision,
        [datetime]$Now = (Get-Date),
        [string]$RunId = '',
        $Samples = $null,
        [string]$SampleSignature = $null,
        $SampleGeneration = $null,
        [string]$Phase = ''
    )

    if ($null -eq $State -or $null -eq $Decision) { return $null }

    $previousSeconds = if ($State.PSObject.Properties['cadenceSeconds']) { [int]$State.cadenceSeconds } else { 0 }
    $seconds = [int]$Decision.Seconds

    $State | Add-Member -NotePropertyName cadenceSeconds -NotePropertyValue $seconds -Force
    $State | Add-Member -NotePropertyName cadenceGear -NotePropertyValue ([string]$Decision.Gear) -Force
    $State | Add-Member -NotePropertyName cadenceReason -NotePropertyValue ([string]$Decision.Reason) -Force
    $State | Add-Member -NotePropertyName burnPerMinute -NotePropertyValue $Decision.BurnPerMinute -Force
    $State | Add-Member -NotePropertyName ettMinutes -NotePropertyValue $Decision.EttMinutes -Force
    $State | Add-Member -NotePropertyName cadenceLoosenStreak -NotePropertyValue ([int]$Decision.LoosenStreak) -Force
    $State | Add-Member -NotePropertyName sampleAt -NotePropertyValue ($Now.ToString('o')) -Force
    # The ring is written on EVERY tick: it is the history the next tick's burn
    # window is measured from, so it may not wait for a gear change.
    if ($null -ne $Samples) {
        $State | Add-Member -NotePropertyName cadenceSamples -NotePropertyValue @($Samples) -Force
    }
    if ($null -ne $SampleSignature) {
        $State | Add-Member -NotePropertyName cadenceSampleSignature -NotePropertyValue ([string]$SampleSignature) -Force
    }
    if ($null -ne $SampleGeneration) {
        $State | Add-Member -NotePropertyName cadenceSampleGeneration -NotePropertyValue ([int]$SampleGeneration) -Force
    }

    $floorTicks = if ($State.PSObject.Properties['cadenceFloorTicks']) { [int]$State.cadenceFloorTicks } else { 0 }
    if ($Decision.PSObject.Properties['FloorTick'] -and [bool]$Decision.FloorTick) { $floorTicks++ }
    $State | Add-Member -NotePropertyName cadenceFloorTicks -NotePropertyValue $floorTicks -Force

    # Establishing the first gear is not a transition, and neither is holding one.
    if ($previousSeconds -le 0 -or $previousSeconds -eq $seconds) { return $null }

    $entry = [ordered]@{
        ts            = $Now.ToString('s')
        runId         = $RunId
        kind          = 'cadence'
        at            = $Now.ToString('o')
        phase         = $Phase
        fromSeconds   = $previousSeconds
        toSeconds     = $seconds
        burnPerMinute = $Decision.BurnPerMinute
        ettMinutes    = $Decision.EttMinutes
        remaining     = $Decision.Remaining
        reason        = [string]$Decision.Reason
    }

    # The @() must wrap the WHOLE if-expression: an if that emits a single-element
    # array is unrolled by PowerShell to a bare PSCustomObject, and the += below
    # then fails with "PSObject does not contain a method named 'op_Addition'".
    # That only bites when state holds exactly ONE prior change (cl-common-79y).
    $changes = @(if ($State.PSObject.Properties['cadenceChanges']) { $State.cadenceChanges | Where-Object { $null -ne $_ } })
    $changes += @([pscustomobject]@{
            at            = $Now.ToString('o')
            phase         = $Phase
            from          = $previousSeconds
            to            = $seconds
            reason        = [string]$Decision.Reason
            burnPerMinute = $Decision.BurnPerMinute
            ettMinutes    = $Decision.EttMinutes
            remaining     = $Decision.Remaining
        })
    $State | Add-Member -NotePropertyName cadenceChanges -NotePropertyValue @($changes) -Force

    return $entry
}

function Set-KeyCheckCutoverOutcomeVerified {
    <#
    .SYNOPSIS
        Upgrade a `restartPending` outcome to verified, on disk.
    .DESCRIPTION
        A resumed run that re-verified the Paseo pin turns the pending fact into
        a durable one, so a third invocation is not asked to verify it again.
        Never invents a pass: the caller only calls this after its own check.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Detail = '',
        [datetime]$Now = (Get-Date)
    )

    $outcome = $null
    try { $outcome = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json } catch { return $false }
    if ($null -eq $outcome) { return $false }
    $outcome | Add-Member -NotePropertyName verified -NotePropertyValue $true -Force
    $outcome | Add-Member -NotePropertyName restartPending -NotePropertyValue $false -Force
    $outcome | Add-Member -NotePropertyName reason -NotePropertyValue 'verified-after-restart' -Force
    $outcome | Add-Member -NotePropertyName reverifiedAt -NotePropertyValue ($Now.ToString('o')) -Force
    $outcome | Add-Member -NotePropertyName reverifiedDetail -NotePropertyValue $Detail -Force
    Set-Content -LiteralPath $Path -Value ($outcome | ConvertTo-Json -Depth 8) -Encoding utf8NoBOM
    return $true
}

function Get-KeyCheckResumeDecision {
    <#
    .SYNOPSIS
        What a new invocation must do with the state a previous one left behind.
    .DESCRIPTION
        Actions:
          fresh     - nothing live to resume (absent, terminal, or unreadable).
          resume    - same runId, ORIGINAL deadlineAt, counters carried forward.
          expired   - the deadline passed while nothing ran: end the run as
                      `window-expired-while-down`; never invent a new window.
          cutover-failed / cutover-unproven - the outcome file the helper wrote
                      while this run was dead says the rescue did not land.

        A verified outcome left by the helper is consumed: the run continues in
        `near` at generation + 1, on the key the helper proved.

        A `restartPending` / `verified: 'pending'` outcome is NEVER success: it
        says the switch landed and the Paseo repair had not been proven when the
        helper last wrote. `-VerifyOutcome` is then called (the caller re-reads
        the Paseo pin and the seam/User surfaces); a pass upgrades the run to
        verified and continues, a failure ends `cutover-failed` (4).

        A run caught at `trigger` with NO outcome file may have been killed
        mid-flight with a PARTIAL switch (seam moved, repair never ran). That is
        not a clean state: it resumes into `initial` so the active key is
        re-resolved from the machine instead of assumed from the file.
    .PARAMETER VerifyOutcome
        Optional scriptblock taking the outcome object and returning
        `@{ Verified = [bool]; Detail = '<surface summary>' }`. Used only for a
        pending outcome; without it a pending outcome is treated as failed.
    #>
    param($State, $Outcome = $null, [datetime]$Now = (Get-Date), [scriptblock]$VerifyOutcome = $null)

    $fresh = { param($reason) [pscustomobject]@{
            Action = 'fresh'; Reason = $reason; RunId = ''; State = $null
            Deadline = $null; StartedAt = $null; Phase = 'initial'; Generation = 0
        } }

    if ($null -eq $State) { return (& $fresh 'no-state') }

    $runId = if ($State.PSObject.Properties['runId']) { [string]$State.runId } else { '' }
    if ([string]::IsNullOrWhiteSpace($runId)) { return (& $fresh 'state-without-runId') }

    $terminal = $false
    if ($State.PSObject.Properties['endReason'] -and -not [string]::IsNullOrWhiteSpace([string]$State.endReason)) { $terminal = $true }
    if ($State.PSObject.Properties['endedAt'] -and -not [string]::IsNullOrWhiteSpace([string]$State.endedAt)) { $terminal = $true }
    if ($State.PSObject.Properties['phase'] -and [string]$State.phase -eq 'end') { $terminal = $true }
    if ($terminal) { return (& $fresh 'previous-run-terminal') }

    $deadlineText = if ($State.PSObject.Properties['deadlineAt'] -and $State.deadlineAt) { $State.deadlineAt }
                    elseif ($State.PSObject.Properties['deadline']) { $State.deadline } else { '' }
    $deadline = ConvertTo-KeyCheckResetTime -Text $deadlineText
    if ($null -eq $deadline) { return (& $fresh 'state-deadline-unreadable') }

    $started = ConvertTo-KeyCheckResetTime -Text $(if ($State.PSObject.Properties['startedAt']) { $State.startedAt } else { $deadlineText })
    $generation = if ($State.PSObject.Properties['generation']) { [int]$State.generation } else { 0 }
    $phase = if ($State.PSObject.Properties['phase'] -and $State.phase) { [string]$State.phase } else { 'initial' }
    $reason = 'resumed'

    # A cutover outcome is consumed first: it is the only fact about the machine
    # that survived the parent, so it outranks the file's phase.
    if ($null -ne $Outcome) {
        $applied = [bool]$Outcome.applied
        $verifiedText = if ($Outcome.PSObject.Properties['verified']) { [string]$Outcome.verified } else { '' }
        $restartPending = ($Outcome.PSObject.Properties['restartPending'] -and [bool]$Outcome.restartPending) -or ($verifiedText -eq 'pending')

        if ($restartPending -and $applied) {
            # Applied-but-not-yet-proven. Finish the verification here; a pending
            # outcome is never treated as success on its own.
            $verification = $null
            if ($null -ne $VerifyOutcome) {
                try { $verification = & $VerifyOutcome $Outcome } catch { $verification = $null }
            }
            $detail = if ($null -ne $verification -and $verification.PSObject.Properties['Detail']) { [string]$verification.Detail } else { 'no verifier available' }
            $ok = ($null -ne $verification -and [bool]$verification.Verified)
            if (-not $ok) {
                return [pscustomobject]@{
                    Action = 'cutover-failed'
                    Reason = "cutover-failed: restart-pending outcome could not be verified ($detail)"
                    RunId = $runId; State = $State; Deadline = $deadline; StartedAt = $started
                    Phase = 'end'; Generation = $generation; ActiveKeyNumber = [int]$State.activeKeyNumber
                    Outcome = $Outcome
                }
            }
            $to = if ($Outcome.PSObject.Properties['keyNumber']) { [int]$Outcome.keyNumber } else { [int]$State.replacementKeyNumber }
            return [pscustomobject]@{
                Action = 'resume'
                Reason = "resumed-cutover-verified-after-restart GO$($State.activeKeyNumber) -> GO$to ($detail)"
                RunId = $runId; State = $State; Deadline = $deadline; StartedAt = $started
                Phase = 'near'; Generation = ($generation + 1)
                ActiveKeyNumber = $to; ReplacementKeyNumber = 0
                Outcome = $Outcome; ResetCounters = $true; UpgradeOutcome = $true
            }
        }

        if (-not $applied) {
            return [pscustomobject]@{
                Action = 'cutover-failed'; Reason = "cutover-failed: $(if ($Outcome.PSObject.Properties['reason']) { $Outcome.reason } else { 'helper reported applied=false while the watch was down' })"
                RunId = $runId; State = $State; Deadline = $deadline; StartedAt = $started
                Phase = 'end'; Generation = $generation; ActiveKeyNumber = [int]$State.activeKeyNumber
                Outcome = $Outcome
            }
        }
        # Past this point the outcome is final (pending was handled above), so
        # `verified` is a plain boolean again.
        $verifiedFlag = [bool]$Outcome.verified
        if (-not $verifiedFlag) {
            return [pscustomobject]@{
                Action = 'cutover-unproven'; Reason = "cutover-unproven: $(if ($Outcome.PSObject.Properties['reason']) { $Outcome.reason } else { 'helper applied the switch but a surface disagreed while the watch was down' })"
                RunId = $runId; State = $State; Deadline = $deadline; StartedAt = $started
                Phase = 'end'; Generation = $generation; ActiveKeyNumber = [int]$State.activeKeyNumber
                Outcome = $Outcome
            }
        }
        $to = if ($Outcome.PSObject.Properties['keyNumber']) { [int]$Outcome.keyNumber } else { [int]$State.replacementKeyNumber }
        $phase = 'near'
        $generation = $generation + 1
        $reason = "resumed-cutover-verified GO$($State.activeKeyNumber) -> GO$to"
        return [pscustomobject]@{
            Action = 'resume'; Reason = $reason; RunId = $runId; State = $State
            Deadline = $deadline; StartedAt = $started; Phase = $phase
            Generation = $generation; ActiveKeyNumber = $to; ReplacementKeyNumber = 0
            Outcome = $Outcome; ResetCounters = $true
        }
    }

    if ($Now -ge $deadline) {
        return [pscustomobject]@{
            Action = 'expired'; Reason = 'window-expired-while-down'
            RunId = $runId; State = $State; Deadline = $deadline; StartedAt = $started
            Phase = 'end'; Generation = $generation; Outcome = $null
        }
    }

    # No outcome at all while the file says `trigger`: the helper may have died
    # mid-flight with a partial switch. Re-resolve from the machine.
    if ($phase -eq 'trigger') {
        $phase = 'initial'
        $reason = 'resumed-unverified-cutover: no outcome file; re-resolving the active key instead of assuming the switch landed'
    }

    if ($phase -notin @('initial', 'heartbeat', 'discover', 'near')) { $phase = 'initial' }

    return [pscustomobject]@{
        Action = 'resume'; Reason = $reason; RunId = $runId; State = $State
        Deadline = $deadline; StartedAt = $started; Phase = $phase
        Generation = $generation; Outcome = $null; ResetCounters = $false
    }
}

# -------------------------------------------------- detached helper launch ---

function ConvertTo-KeyCheckCommandLineArg {
    <#
    .SYNOPSIS
        Quote one argument for a Win32 command line.
    #>
    param([AllowEmptyString()][string]$Value)

    if ($null -eq $Value) { return '""' }
    return '"' + ($Value -replace '"', '\"') + '"'
}

function Get-KeyCheckHelperCommandLine {
    <#
    .SYNOPSIS
        The exact argv the detached cutover helper is started with.
    .DESCRIPTION
        Built as one string because Win32_Process.Create takes a command line,
        not an argv array. Every path is quoted, so a workspace path with a
        space cannot split an argument.
    #>
    param(
        [Parameter(Mandatory)][string]$PowerShellPath,
        [Parameter(Mandatory)][string]$HelperPath,
        [Parameter(Mandatory)][int]$KeyNumber,
        [Parameter(Mandatory)][string]$OutcomePath,
        [Parameter(Mandatory)][string]$RunId,
        [int]$TimeoutSeconds = 300,
        [string]$SwitchScript = '',
        [string]$RepairScript = ''
    )

    $parts = @(
        (ConvertTo-KeyCheckCommandLineArg $PowerShellPath)
        (ConvertTo-KeyCheckCommandLineArg '-NoProfile')
        (ConvertTo-KeyCheckCommandLineArg '-File')
        (ConvertTo-KeyCheckCommandLineArg $HelperPath)
        (ConvertTo-KeyCheckCommandLineArg '-KeyNumber')
        (ConvertTo-KeyCheckCommandLineArg ([string]$KeyNumber))
        (ConvertTo-KeyCheckCommandLineArg '-OutcomePath')
        (ConvertTo-KeyCheckCommandLineArg $OutcomePath)
        (ConvertTo-KeyCheckCommandLineArg '-RunId')
        (ConvertTo-KeyCheckCommandLineArg $RunId)
        (ConvertTo-KeyCheckCommandLineArg '-TimeoutSeconds')
        (ConvertTo-KeyCheckCommandLineArg ([string]$TimeoutSeconds))
    )
    if ($SwitchScript) { $parts += @((ConvertTo-KeyCheckCommandLineArg '-SwitchScript'), (ConvertTo-KeyCheckCommandLineArg $SwitchScript)) }
    if ($RepairScript) { $parts += @((ConvertTo-KeyCheckCommandLineArg '-RepairScript'), (ConvertTo-KeyCheckCommandLineArg $RepairScript)) }
    return ($parts -join ' ')
}

function Get-KeyCheckSuccessorCommandLine {
    <#
    .SYNOPSIS
        The exact argv the armed one-shot successor is started with.
    .DESCRIPTION
        A successor is the SAME Key Check entry point, told to wait, and told who
        armed it (`-TriggeredBy successor-arm`, `-SuccessorOf <parent runId>`) so
        the audit line that records the eventual start names its trigger source
        (cl-common-0ai acceptance 2).

        Only the world the parent ran in is passed through (`Options`): fixture
        paths, the seam, the canary helpers, the timeout. Behaviour switches are
        deliberately NOT inherited - `-DryRun`, `-NoWait`, `-SkipCanary` and
        `-NoRecovery` are one run's decisions, and a successor that quietly
        inherited them would rehearse instead of watch, or skip the proof the
        fresh run needs.

        Built as one string because Win32_Process.Create takes a command line,
        not an argv array. Every value is quoted, and numbers are formatted with
        the invariant culture so a comma-decimal machine cannot hand pwsh a
        duration it reads as two arguments.
    #>
    param(
        [Parameter(Mandatory)][string]$PowerShellPath,
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][int]$DelaySeconds,
        [string]$ParentRunId = '',
        [int]$IntervalMinutes = 15,
        [double]$DurationHours = 2,
        [string]$TriggeredBy = 'successor-arm',
        [System.Collections.IDictionary]$Options = @{}
    )

    $invariant = [System.Globalization.CultureInfo]::InvariantCulture
    $pairs = [ordered]@{
        # The wait is what makes it a ONE-SHOT successor rather than a second
        # watcher: it cannot start before the parent's deadline has passed.
        '-StartAfterSeconds' = [string]$DelaySeconds
        '-TriggeredBy'       = $TriggeredBy
        '-IntervalMinutes'   = [string]$IntervalMinutes
        '-DurationHours'     = $DurationHours.ToString('R', $invariant)
    }
    if (-not [string]::IsNullOrWhiteSpace($ParentRunId)) { $pairs['-SuccessorOf'] = $ParentRunId }
    foreach ($name in $Options.Keys) {
        $value = $Options[$name]
        if ($null -eq $value -or [string]::IsNullOrWhiteSpace([string]$value)) { continue }
        $pairs[[string]$name] = [string]$value
    }

    $parts = @(
        (ConvertTo-KeyCheckCommandLineArg $PowerShellPath)
        (ConvertTo-KeyCheckCommandLineArg '-NoProfile')
        (ConvertTo-KeyCheckCommandLineArg '-File')
        (ConvertTo-KeyCheckCommandLineArg $ScriptPath)
    )
    foreach ($name in $pairs.Keys) {
        $parts += @((ConvertTo-KeyCheckCommandLineArg $name), (ConvertTo-KeyCheckCommandLineArg $pairs[$name]))
    }
    return ($parts -join ' ')
}

function Start-KeyCheckDetachedProcess {
    <#
    .SYNOPSIS
        Create a process outside this agent's job object, by construction.
    .DESCRIPTION
        Win32_Process.Create creates the child under the WMI provider host, so it
        is not a member of THIS process's job object by construction - unlike a
        Start-Process child, which may inherit membership. That is a design
        argument, not a measurement: on 2026-11-02 both mechanisms survived a
        force-killed launcher on this host, and survival across a real
        `paseo restart` is unproven. The cutover therefore does not rely on
        survival - the helper writes its outcome before the restart and the next
        invocation finishes the verification.

        There is still NO silent fallback. A CIM failure returns Spawned=false
        with the reason, so the caller ends the run honestly (exit 4 + audit
        line) instead of quietly choosing a mechanism the operator did not ask
        for. `-AllowProcessFallback` opts in explicitly and says so in Detail;
        it is safe because of the pre-restart outcome, not because the child is
        expected to live.

        No Process object exists for the CIM path; liveness is a pid lookup.
    #>
    param(
        [Parameter(Mandatory)][string]$CommandLine,
        [string[]]$FallbackArgumentList = @(),
        [switch]$AllowProcessFallback
    )

    $cimError = ''
    try {
        $created = Invoke-CimMethod -ClassName Win32_Process -MethodName Create `
            -Arguments @{ CommandLine = $CommandLine } -ErrorAction Stop
        $returnValue = if ($null -ne $created -and $created.PSObject.Properties['ReturnValue']) { [int]$created.ReturnValue } else { -1 }
        if ($returnValue -eq 0) {
            return [pscustomobject]@{
                Spawned = $true; Method = 'Win32_Process.Create'; ProcessId = [int]$created.ProcessId
                Detail = 'created outside the caller job object by construction (WMI provider)'
            }
        }
        $cimError = "Win32_Process.Create returned $returnValue"
    } catch {
        $cimError = $_.Exception.Message
    }

    if (-not $AllowProcessFallback) {
        return [pscustomobject]@{
            Spawned = $false; Method = 'none'; ProcessId = 0
            Detail = "cim-launch-failed: $cimError; refusing the Start-Process fallback by default (it may inherit this agent's job object; the pre-restart outcome is what keeps the cutover recoverable) - pass -AllowProcessFallback to override deliberately"
        }
    }

    try {
        $proc = Start-Process -FilePath (Join-Path $PSHOME 'pwsh.exe') -ArgumentList $FallbackArgumentList `
            -PassThru -WindowStyle Hidden
        return [pscustomobject]@{
            Spawned = $true; Method = 'Start-Process'; ProcessId = [int]$proc.Id
            Detail = "cim-launch-failed: $cimError; -AllowProcessFallback used: this child may inherit the agent job object, so the pre-restart outcome (not the launch) is what keeps a restart recoverable"
        }
    } catch {
        return [pscustomobject]@{
            Spawned = $false; Method = 'none'; ProcessId = 0
            Detail = "spawn-failed: CIM launch failed ($cimError); Start-Process failed ($($_.Exception.Message))"
        }
    }
}
