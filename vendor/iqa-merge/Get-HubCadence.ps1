#Requires -Version 7
<#
.SYNOPSIS
    Hub cadence gate - decides the next heartbeat gear at the END of every Hub
    turn, and says whether the rung currently held is still acceptable.

.DESCRIPTION
    The Hub's adaptive heartbeat is only as good as its worst gap. A user or
    operator prompt is fresh evidence that work may have arrived, yet the rung
    created by the previous fire may be an hour out - so the turn must re-derive
    the required gear and, when the held rung fires later than that, recreate it
    NOW instead of waiting for the far fire to happen and rescheduling after.

    This helper is the deterministic half of that check. Given the state the
    turn just observed it returns the required gear, the cron to create, and
    one action:

      CREATE    no rung is known for this turn (no -NextFireAt supplied)
      RECREATE  the held rung fires later than the required gear, is late by a
                full cron interval or more, is armed at a cron that cannot meet
                the satisfiable gear, or expires too soon to cover two fires
      HOLD      the held rung fires inside the required gear (or sits at the
                satisfiable gear) and covers two fires - leave it alone
      LAPSE     stand-down: zero actionable work, no rung is created

    EVERY RECREATE IS CLEARABLE (cl-common-leb). A RECREATE names the gear that
    can actually satisfy the next evaluation, and a rung already armed at that
    gear returns HOLD - so obeying the verdict once ends it instead of
    re-arming the schedule on every tick. Pass -HeldCron (the cron the rung is
    armed at) and the helper compares the ARMED interval against the
    satisfiable gear (the larger of the state gear and the measured effective
    cadence). Armed at the satisfiable gear => HOLD. Armed coarser => RECREATE
    at the satisfiable gear, unless -AcceptEffectiveCadence says the coarser
    rung is deliberate (a slower gear chosen because no finer fire is
    deliverable), in which case it is HOLD. Armed finer than the daemon can
    deliver (a */2 cron measuring one fire per 8 min) => RECREATE at the
    measured gear, unless -AcceptEffectiveCadence says the finer cron is
    deliberate. The switch therefore accepts a deliberate divergence in EITHER
    direction. Without
    -HeldCron the effective-cadence RECREATE keeps its old behaviour and the
    reason names both ways to clear it (-HeldCron, or -AcceptEffectiveCadence).

    A DEFERRAL BEHIND A LIVE RUN IS HOLD, NOT A DEAD RUNG (cl-common-jt2). When
    the run history shows a `running` fire of this schedule that started at or
    before the held fire, the daemon is deferring the next fire behind that run
    and the rung is healthy however late it reads. That was measured on
    2026-11-03: a healthy */2 rung read "overdue by 3.5 min" only because the
    previous turn was still running. With the in-flight evidence the verdict is
    HOLD, `Deferred = true`, `DeferredReason = 'in-flight'`, and the reason
    names the in-flight run's `scheduledFor` and how long it has been running.
    Without that evidence a rung late by more than one interval is the stale
    record it looks like, and stays RECREATE.

    Deferred fires are healthy, and that is the point of this helper. When a run
    of the same schedule is still in flight the daemon pushes nextRunAt behind
    that run, so the held fire reads as being in the past by a fraction of the
    schedule's interval (measured live 2026-11-03: a */2 rung 1.4 min "late"
    while the 12:30 run was still running). A next fire at most ONE cron
    interval - the required gear - in the past is therefore HOLD, reported as
    `deferred` with `Deferred = true`, never RECREATE: recreating it re-arms or
    delete+creates a live rung and historically manufactured a duplicate. The
    genuine-lateness signal is kept: overdue by more than one interval, or an
    expiry that has already passed / cannot cover two fires, is RECREATE.

    NOMINAL vs EFFECTIVE CADENCE (the assurance the rung line used to overstate).
    A cron interval is a NOMINAL gear: it is what was asked for, not what the
    daemon delivers. When every fire spawns an agent that outlives the interval,
    the daemon drops the overlapping fires instead of queueing them, so a */2
    rung measured one verdict per 4-10 minutes (schedule b3fdf56a, 2026-11-03:
    scheduledFor 07:36, 07:46, 07:52, 07:58, 08:02, 08:04, 08:08, 08:12). The
    line still said "required 2 min - HOLD", which reads as a promise that a
    stalled lane is noticed inside 2 minutes. It is not.

    Pass the schedule's run history (-RunHistoryPath, -RunHistoryJson, or
    -RunHistory) and the helper measures the EFFECTIVE cadence: the median gap
    between consecutive `scheduledFor` values whose status is `succeeded` or
    `running` (failed/skipped fires are excluded, so one failed fire neither
    widens nor narrows the chain). Then:

      - the Rung line states BOTH when they disagree beyond -ToleranceMinutes,
        e.g. `- HOLD (nominal 2 min, effective 6 min): ...`;
      - the cadence verdict is driven by the EFFECTIVE cadence only: RECREATE
        when the median exceeds the required gear, HOLD when it does not, so a
        nominal held-fire distance can no longer manufacture a recreate on a
        rung that is demonstrably firing;
      - a RECREATE names the satisfiable gear (`SuggestedMinutes`, the measured
        median rounded up) because recreating into the same unsatisfiable gear
        is churn, not healing.

    THE MEASUREMENT IS ERA-WINDOWED (cl-common-q64). A schedule's history holds
    every regime it has ever run, so an all-history median never converges: a
    rung re-armed from `*/2` to `*/10` kept reading the old 4-minute median over
    139 gaps while the last 25-40 fires delivered 10 minutes, and every tick
    therefore demanded a `*/4` gear that run durations make undeliverable
    (measured 2026-11-03, `hub-tick-runs.json`: 141 fires, all-history median
    4 min, last-40 median 10 min, median run 6.4 min). Both the effective
    cadence and the run-duration floor are therefore measured over the ERA
    WINDOW: the most recent 40 qualifying fires (fewer when the history is
    shorter). That is wide enough to outlast a single slow turn (one 20-minute
    run cannot move a 39-gap median) and narrow enough that the previous
    regime stops voting; a shorter window starts measuring the noise of one
    turn, a longer one re-admits the retired regime. The winner is named on
    the `EffectiveCadenceNote` (`the last N of M fires`) so the era is visible
    in the verdict rather than assumed.

    THE SATISFIABLE GEAR ALSO RESPECTS RUN DURATION (cl-common-q64). Gap median
    alone can under-state what the daemon can deliver, because a fire whose run
    is in flight is dropped and a `*/4` cron is unobservable by construction
    when runs last 7 minutes. When the history rows carry `startedAt` and
    `endedAt`, the helper also medians the RUN DURATION over the same era
    window, and `SatisfiableMinutes` is never below `ceil(median run duration)`.
    Rows without both timestamps (older histories, or a still-`running` fire)
    contribute no duration sample; the count is reported as
    `RunDurationSamples`, and with no samples the floor is simply absent rather
    than guessed.

    An ABSENT history is never a silent pass. Measured-but-unreadable history
    (-RunHistoryPath naming no file, malformed JSON, rows without a
    `scheduledFor`, fewer than two qualifying fires) is a named non-zero
    CANNOT-EVALUATE (exit 2) - the caller asked for the effective cadence and it
    could not be derived. A caller that did not ask at all keeps today's
    behaviour exactly (the holding behaviour must not change under it), and the
    helper says so in two places rather than pretending: `EffectiveCadenceStatus
    = cannot-evaluate` in JSON and `effective=cannot-evaluate` on the host
    `Cadence:` line. A Hub that needs the assurance passes -RequireEffectiveCadence,
    which makes that absence exit 2 as well.

    INPUT SHAPES ARE COERCED EXPLICITLY, never through a culture string. An
    offset-carrying ISO STRING bound correctly, but the SAME instant passed as a
    [datetime] (Kind=Utc) was re-read through the current culture with no
    offset, so 13:00:00Z became 20:00Z on a -07:00 host: a 420-minute phantom
    future that manufactured a false RECREATE (measured 2026-11-03 12:58Z).
    Every instant parameter therefore goes through one converter: a
    [DateTimeOffset] is taken as-is, a [DateTime] carries its Kind (Utc/Local
    keep their offset), and a string must carry its own offset (a `Z` or an
    explicit `+hh:mm`). Same instant, same verdict, whatever the shape.

    AN INSTANT WITH NO OFFSET IS REFUSED, never assumed UTC. The converter used
    to pad a missing offset with `AssumeUniversal`, so the exact call this
    heartbeat contract prescribes - the schedule record's `nextRunAt` formatted
    without its offset - read a LOCAL wall clock as UTC and reported a confident
    ~420-minute phantom. Measured back to back on 2026-11-03 at 09:04 local,
    against one rung: `'2026-11-03T16:02:00Z'` HOLD (fires in -0.1 min),
    `'2026-11-03T09:02:00-07:00'` HOLD (fires in -0.1 min), and
    `'2026-11-03T09:02:00'` RECREATE (overdue by 420.1 min). A value that
    carries no offset is now a NAMED terminating error - `NextFireAt has no
    offset; pass a Z or an explicit offset` - so a guessed instant can never be
    printed as a verdict. A [datetime] whose Kind is Unspecified is refused for
    the same reason; Kind Utc and Kind Local are taken as stated.

    It performs no I/O beyond the one run-history file it is told to read, and
    reads no clock beyond -Now: the Hub passes what it knows and prints the
    returned RungLine as its closing line.

    Gear ladder (unchanged from REFERENCE.md -> `## Hub heartbeat (self-wake)`):

      prompt / inside the prompt window                1 min
      dispatched                                       2 min
      healthy (every lane running, none needs attention) 2 min
      blocked, 0-1 quiet rounds                        5 min
      blocked, 2 quiet rounds                         15 min
      blocked, 3+ quiet rounds                        60 min
      peer-hub (a live peer Hub owns this repo's drain) 15 min
      stand-down                                      none

    A prompt FLOORS the gear at 1 minute for -ResetWindowMinutes afterwards, so
    a minute-level reset always beats a stale hourly rung. It does NOT floor
    `peer-hub`: an operator prompt is not a licence to drain a repo another Hub
    owns, so that state keeps its 15-minute liveness re-check.

    `peer-hub` is a liveness re-check, never a drain tick: 15 minutes is the
    registry's own freshness window (-MaxAgeMinutes 15, the number the discovery
    read uses), which bounds how long a dead peer can go unnoticed to one window,
    and it is 7.5x the peer's 2-minute healthy gear so it cannot duplicate the
    peer's own ticks. It is NOT a stand-down: the work is owned elsewhere, not
    absent, so a rung is still created and the standing heartbeat is not deleted.

    Dispatched shares the healthy gear on purpose: a lane/worker completion is
    delivered to the Hub as a push ping, so the rung only has to be a backstop
    for a MISSED ping. Racing at 1 minute bought nothing and cost a model turn
    every minute (operator decision 2026-11-03: the 1-minute default was a
    mistake).

.PARAMETER State
    What the turn observed:
      prompt      a user/operator prompt or worker completion just arrived
      dispatched  a lane/worker was dispatched and may need attention
      healthy     every lane is running and none needs attention
      blocked     nothing is running and every open bead is operator-blocked
      peer-hub    a live peer Hub is advertised for this repo and holds its
                  drain; re-check liveness, never drain
      stand-down  zero actionable work; the rung lapses deliberately

.PARAMETER SincePromptMinutes
    Minutes since the last user/operator prompt. Inside -ResetWindowMinutes the
    gear is floored at 1 minute.

.PARAMETER ResetWindowMinutes
    How long a prompt keeps the gear at 1 minute. Default 10.

.PARAMETER QuietRounds
    Consecutive probes that found nothing actionable (blocked ladder only).

.PARAMETER NextFireAt
    When the rung currently held will next fire, as an instant. Omit when no
    rung is known. A fire at most one cron interval in the past is read as the
    daemon deferring behind an in-flight run (HOLD, `deferred`), not as a dead
    rung; past that it is RECREATE. Accepts an offset-carrying ISO string (the
    caller rule: quote it and keep the offset, e.g. '2026-11-03T16:02:00Z' or
    '2026-11-03T09:02:00-07:00' - never a bare [datetime]), a [DateTimeOffset],
    or a [DateTime] whose Kind is Utc/Local. An instant with no offset at all -
    a string without a `Z` or an offset, or a Kind=Unspecified [datetime] - is
    refused by name rather than read as UTC: a wrong-side-of-a-time-zone
    instant is indistinguishable from a real verdict once it is printed.

.PARAMETER ExpiresAt
    Expiry of the rung currently held (heartbeat `expiresAt`). When it cannot
    cover two fires at the required gear, the action becomes RECREATE. Same
    input shapes as -NextFireAt.

.PARAMETER RunHistoryPath
    Path to a JSON file holding the schedule's run history - an array (or an
    object with a `runs` array) of `{ scheduledFor, status }`. The EFFECTIVE
    cadence is the median gap between consecutive `succeeded`/`running` fires.
    Mutually exclusive with -RunHistoryJson and -RunHistory.

.PARAMETER RunHistoryJson
    The same run history as an inline JSON string, for a caller that already
    holds `paseo_schedule_logs` output. Mutually exclusive with the other two.

.PARAMETER RunHistory
    The same run history as objects already in memory. Mutually exclusive with
    the other two.

.PARAMETER HeldCron
    The cron expression the tracked rung is currently armed at (the schedule
    record's `expression`, e.g. '*/4 * * * *'). Supplying it makes the verdict
    satisfiable: a rung already armed at the satisfiable gear returns HOLD
    instead of a RECREATE into the cron it already holds. Mutually exclusive
    with -HeldIntervalMinutes; delete+create at the returned `SatisfiableCron`
    clears the condition on the very next evaluation.

.PARAMETER HeldIntervalMinutes
    The same armed interval as a number, for a caller that already parsed the
    cron. Must be greater than zero. Mutually exclusive with -HeldCron.

.PARAMETER AcceptEffectiveCadence
    Accept the measured effective cadence as the assurance. Without a
    -HeldCron, a measured cadence wider than the state gear makes the nominal
    gear undeliverable; this switch expresses the operator decision the reason
    offers ("accept the effective cadence") so the verdict is expressible
    rather than prose. With a -HeldCron it accepts a deliberate divergence in
    either direction: a rung armed finer than the measured cadence is left
    alone instead of being recreated at the coarser gear, and a rung armed
    COARSER than the satisfiable gear (a */10 rung while runs last 7 minutes)
    is left alone instead of being recreated at the finer, undeliverable gear.

.PARAMETER RequireEffectiveCadence
    Make an absent effective cadence a named non-zero CANNOT-EVALUATE (exit 2)
    instead of a note. Use when the turn claims the effective cadence as the
    assurance; a Hub that is only holding a rung does not need it.

.PARAMETER Name
    Heartbeat name used in the returned RungLine. Default `<name>`.

.PARAMETER Now
    Injectable clock. Defaults to the current time. Same input shapes as
    -NextFireAt.

.PARAMETER ToleranceMinutes
    Slack for cron boundary jitter. Default 0.25.

.PARAMETER Json
    Emit the verdict as JSON instead of the host line.

.EXAMPLE
    pwsh Get-HubCadence.ps1 -State prompt -SincePromptMinutes 2

.EXAMPLE
    pwsh Get-HubCadence.ps1 -State healthy -NextFireAt '2026-10-31T09:00:00Z' -ExpiresAt '2026-10-31T12:00:00Z' -Json

.EXAMPLE
    pwsh Get-HubCadence.ps1 -State healthy -NextFireAt '2026-11-03T13:00:00Z' `
        -ExpiresAt '2026-11-03T15:00:00Z' -RunHistoryPath .\hub-watch-cl-common-runs.json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('prompt', 'dispatched', 'healthy', 'blocked', 'peer-hub', 'stand-down')]
    [string]$State,

    [ValidateRange(0, 100000)]
    [Nullable[double]]$SincePromptMinutes = $null,

    [ValidateRange(0, 100000)]
    [double]$ResetWindowMinutes = 10,

    [ValidateRange(0, 100000)]
    [int]$QuietRounds = 0,

    [AllowNull()]
    [object]$NextFireAt = $null,

    [AllowNull()]
    [object]$ExpiresAt = $null,

    [AllowNull()]
    [object]$RunHistory = $null,

    [string]$RunHistoryPath,

    [string]$RunHistoryJson,

    [AllowNull()]
    [string]$HeldCron = $null,

    [AllowNull()]
    [Nullable[double]]$HeldIntervalMinutes = $null,

    [switch]$AcceptEffectiveCadence,

    [switch]$RequireEffectiveCadence,

    [string]$Name = '<name>',

    [AllowNull()]
    [object]$Now = $null,

    [ValidateRange(0, 600)]
    [double]$ToleranceMinutes = 0.25,

    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-RequiredMinutes {
    param([string]$State, [Nullable[double]]$SincePromptMinutes, [double]$ResetWindowMinutes, [int]$QuietRounds)

    if ($State -eq 'stand-down') { return $null }
    # A prompt always resets the gear - except for peer-hub, where a prompt
    # addressed to this session is not a licence to drain a repo another Hub owns.
    if ($State -ne 'peer-hub' -and $null -ne $SincePromptMinutes -and $SincePromptMinutes -le $ResetWindowMinutes) { return 1 }   # a prompt always resets the gear
    switch ($State) {
        'prompt'     { return 1 }
        'dispatched' { return 2 }
        'healthy'    { return 2 }
        'blocked' {
            if ($QuietRounds -le 1) { return 5 }
            if ($QuietRounds -eq 2) { return 15 }
            return 60
        }
        'peer-hub'   { return 15 }
    }
    throw "Unhandled state '$State' - refusing to guess a cadence."
}

function Get-CronForMinutes {
    param([int]$Minutes)
    switch ($Minutes) {
        1 { return '* * * * *' }
        2 { return '*/2 * * * *' }
        5 { return '*/5 * * * *' }
        15 { return '*/15 * * * *' }
        60 { return '0 * * * *' }
        default { return "*/$Minutes * * * *" }
    }
}

# One converter for every instant parameter. Two defects are closed here, both
# measured on this box:
#   1. a [datetime] coerced into [Nullable[DateTimeOffset]] by the binder went
#      through a culture string with no offset, so a UTC 13:00 came back as 13:00
#      local (20:00Z on a -07:00 host) and manufactured a 420-minute phantom;
#   2. a STRING with no offset was padded with AssumeUniversal, so the local
#      wall clock the heartbeat contract's own caller produces ('09:02:00' for a
#      16:02Z rung) was read as 09:02Z and reported as overdue by 420.1 min.
# The shape is handled explicitly here, and a value that does not carry its own
# offset is REFUSED by name: an instant that had to be guessed is not evidence
# about a rung.
function ConvertTo-Instant {
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory)][string]$ParameterName
    )

    if ($null -eq $Value) { return $null }

    if ($Value -is [DateTimeOffset]) { return [DateTimeOffset]$Value }

    if ($Value -is [DateTime]) {
        # Kind is the caller's statement about the instant: Utc and Local carry
        # an offset, so they are taken as stated. Unspecified says "no zone
        # known", which is exactly the guess this helper refuses to make.
        $instant = [DateTime]$Value
        if ($instant.Kind -eq [DateTimeKind]::Unspecified) {
            throw ("-$ParameterName received a [datetime] whose Kind is Unspecified, so it carries no " +
                "offset; pass a Z or an explicit offset (e.g. '2026-11-03T09:02:00-07:00'), or a [datetime] " +
                'with Kind Utc/Local.')
        }
        return [DateTimeOffset]::new($instant)
    }

    if ($Value -is [string]) {
        $text = ([string]$Value).Trim()
        if ([string]::IsNullOrWhiteSpace($text)) {
            throw "-$ParameterName was an empty string; pass an offset-carrying instant such as '2026-11-03T13:00:00Z'."
        }

        $culture = [System.Globalization.CultureInfo]::InvariantCulture

        # RoundtripKind is the offset DETECTOR, not the converter: a value that
        # carries a Z or an explicit +hh:mm comes back Utc/Local, and one that
        # carries neither comes back Unspecified.
        $probe = [datetime]::MinValue
        if (-not [datetime]::TryParse($text, $culture, [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$probe)) {
            throw "-$ParameterName '$text' is not a parseable instant; pass an offset-carrying ISO 8601 value such as '2026-11-03T13:00:00Z' - never a bare local wall clock."
        }

        if ($probe.Kind -eq [DateTimeKind]::Unspecified) {
            throw ("-$ParameterName '$text' has no offset; pass a Z or an explicit offset " +
                "(e.g. '2026-11-03T16:02:00Z' or '2026-11-03T09:02:00-07:00'). A bare wall clock used to be " +
                'read as UTC, which turns a time-zone gap into a confident wrong verdict.')
        }

        # Offset-carrying: parse again so the caller's own offset is preserved
        # for the printed line instead of being normalised to this host.
        $parsed = [DateTimeOffset]::MinValue
        if ([DateTimeOffset]::TryParse($text, $culture, [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)) { return $parsed }

        throw "-$ParameterName '$text' is not a parseable instant; pass an offset-carrying ISO 8601 value such as '2026-11-03T13:00:00Z' - never a bare local wall clock."
    }

    throw "-$ParameterName received a $($Value.GetType().FullName); pass an offset-carrying ISO 8601 string, a [DateTimeOffset], or a [DateTime] (Kind Utc/Local carry their offset; an offset-less string and Kind Unspecified are refused)."
}

# The armed rung's own interval, derived from its cron. This is the evidence a
# RECREATE must be judged against: a verdict that names a cron the rung already
# holds can never be cleared by acting on it (cl-common-leb). A cron whose
# interval is not minute-derivable is a named error, never a guess - the caller
# can pass -HeldIntervalMinutes instead.
function Get-CronIntervalMinutes {
    param([Parameter(Mandatory)][string]$Cron)

    $fields = @($Cron.Trim() -split '\s+')
    if ($fields.Count -ne 5) {
        throw "-HeldCron '$Cron' is not a five-field cron expression; pass the schedule record's expression (e.g. '*/4 * * * *') or -HeldIntervalMinutes."
    }

    $minuteField = $fields[0]
    $hourField = $fields[1]

    if ($minuteField -eq '*') { return [double]1 }

    if ($minuteField -match '^\*/(\d+)$') {
        $step = [int]$Matches[1]
        if ($step -lt 1) { throw "-HeldCron '$Cron' has a zero minute step." }
        return [double]$step
    }

    if ($minuteField -match '^\d+$' -and $hourField -eq '*') { return [double]60 }

    if ($minuteField -match '^\d+$' -and $hourField -match '^\*/(\d+)$') {
        $hours = [int]$Matches[1]
        if ($hours -lt 1) { throw "-HeldCron '$Cron' has a zero hour step." }
        return [double]($hours * 60)
    }

    throw "-HeldCron '$Cron' does not describe a minute-level interval; pass -HeldIntervalMinutes with the armed interval."
}

# The in-flight fire, if any: the newest run row whose status is `running`.
# This is the evidence that separates "the daemon deferred the next fire behind
# a live run" (HOLD) from "the record is stale and the rung is dead"
# (RECREATE) - the distinction cl-common-jt2 measured as a false RECREATE.
function Get-InFlightRun {
    param([AllowNull()][object[]]$Rows)

    $newest = $null
    $index = 0

    foreach ($row in @($Rows)) {
        $index++
        if ($null -eq $row) { continue }

        $statusProperty = $row.PSObject.Properties['status']
        $status = if ($null -ne $statusProperty) { ([string]$statusProperty.Value).Trim().ToLowerInvariant() } else { '' }
        if ($status -ne 'running') { continue }

        $fireProperty = $row.PSObject.Properties['scheduledFor']
        if ($null -eq $fireProperty -or $null -eq $fireProperty.Value) { continue }

        $instant = ConvertTo-Instant -Value $fireProperty.Value -ParameterName "RunHistory row ${index} scheduledFor"
        if ($null -eq $instant) { continue }

        if ($null -eq $newest -or $instant -gt $newest.ScheduledFor) {
            $newest = [pscustomobject]@{ ScheduledFor = [DateTimeOffset]$instant; Row = $index }
        }
    }

    return $newest
}

# Accepts the three shapes the Hub can have in hand: a JSON array, the Paseo
# schedule-log wrapper ({ runs: [...] }), or objects already in memory.
function Get-RunHistoryRows {
    param([Parameter(Mandatory)][string]$Json)

    $parsed = ConvertFrom-Json -InputObject $Json -Depth 8
    if ($null -eq $parsed) { return @() }

    $runsProperty = $parsed.PSObject.Properties['runs']
    if ($null -ne $runsProperty) { return @($runsProperty.Value) }
    return @($parsed)
}

# Effective cadence = median gap between consecutive QUALIFYING fires, where a
# qualifying fire is one the daemon actually started (succeeded/running). A
# failed or skipped fire is not evidence about delivery, so it is not a node in
# the chain.
#
# BOTH measurements are ERA-WINDOWED (cl-common-q64). A schedule's history holds
# every regime it has ever run, so an all-history median never converges: the
# */2 era (median 4 min) dominated the */10 era (median 10 min) forever, and the
# helper demanded a gear the current run durations make undeliverable. Only the
# most recent $EraWindowFires qualifying fires are measured. 40 fires is ~39
# gaps: wide enough that one 20-minute run cannot swing the median, narrow
# enough that the retired regime stops voting. A shorter window (the last 12)
# starts measuring the noise of a single turn; a longer one re-admits the
# previous regime. The window actually used is named in the Note.
$EraWindowFires = 40

# One median implementation for both the gap list and the run-duration list, so
# the two measurements cannot drift apart.
function Get-MedianValue {
    param([AllowNull()][double[]]$Values)

    $ordered = @($Values | Where-Object { $null -ne $_ } | Sort-Object)
    if ($ordered.Count -eq 0) { return $null }

    $middle = [int][math]::Floor($ordered.Count / 2)
    if ($ordered.Count % 2 -eq 1) { return [double]$ordered[$middle] }
    return (([double]$ordered[$middle - 1] + [double]$ordered[$middle]) / 2)
}

# A run duration needs BOTH timestamps. A still-`running` fire has no `endedAt`
# and an older history may carry neither, so those rows simply supply no sample:
# the absence is reported as RunDurationSamples rather than guessed, and the
# duration floor is then absent instead of invented.
function Get-RunDurationMinutes {
    param([Parameter(Mandatory)][object]$Row)

    $startedProperty = $Row.PSObject.Properties['startedAt']
    $endedProperty = $Row.PSObject.Properties['endedAt']
    if ($null -eq $startedProperty -or $null -eq $endedProperty) { return $null }
    if ($null -eq $startedProperty.Value -or $null -eq $endedProperty.Value) { return $null }

    try {
        $started = ConvertTo-Instant -Value $startedProperty.Value -ParameterName 'RunHistory row startedAt'
        $ended = ConvertTo-Instant -Value $endedProperty.Value -ParameterName 'RunHistory row endedAt'
    }
    catch {
        # An unreadable optional duration must not discard a cadence the
        # scheduledFor column still proves: skip the sample, keep the measure.
        return $null
    }

    if ($null -eq $started -or $null -eq $ended) { return $null }
    $minutes = ($ended - $started).TotalMinutes
    if ($minutes -lt 0) { return $null }
    return [double]$minutes
}

function Measure-EffectiveCadence {
    param([AllowNull()][object[]]$Rows)

    $fires = [System.Collections.Generic.List[object]]::new()
    $index = 0

    foreach ($row in @($Rows)) {
        $index++
        if ($null -eq $row) { continue }

        $statusProperty = $row.PSObject.Properties['status']
        $status = if ($null -ne $statusProperty) { ([string]$statusProperty.Value).Trim().ToLowerInvariant() } else { '' }
        if ($status -ne 'succeeded' -and $status -ne 'running') { continue }

        $fireProperty = $row.PSObject.Properties['scheduledFor']
        if ($null -eq $fireProperty) {
            throw "run history row $index is status '$status' but carries no scheduledFor"
        }

        $instant = ConvertTo-Instant -Value $fireProperty.Value -ParameterName "RunHistory row ${index} scheduledFor"
        if ($null -eq $instant) {
            throw "run history row $index has a null scheduledFor"
        }
        $fires.Add([pscustomobject]@{
            ScheduledFor = [DateTimeOffset]$instant
            RunMinutes   = Get-RunDurationMinutes -Row $row
        })
    }

    if ($fires.Count -lt 2) {
        return [pscustomobject]@{
            Status   = 'cannot-evaluate'
            Minutes  = $null
            GapCount = 0
            Note     = "run history supplies $($fires.Count) succeeded/running fire(s); two are needed for a gap"
        }
    }

    $orderedFires = @($fires | Sort-Object -Property ScheduledFor)

    # Era window: the most recent $EraWindowFires fires, all of them when the
    # history is shorter. The retired regime must not vote in the current one.
    $windowFires = if ($orderedFires.Count -gt $EraWindowFires) {
        @($orderedFires[($orderedFires.Count - $EraWindowFires)..($orderedFires.Count - 1)])
    }
    else { $orderedFires }

    $gaps = [System.Collections.Generic.List[double]]::new()
    for ($i = 1; $i -lt $windowFires.Count; $i++) {
        $gaps.Add(($windowFires[$i].ScheduledFor - $windowFires[$i - 1].ScheduledFor).TotalMinutes)
    }

    $orderedGaps = @($gaps | Sort-Object)
    $median = Get-MedianValue -Values $orderedGaps
    $durations = @($windowFires | ForEach-Object { $_.RunMinutes })
    $medianRun = Get-MedianValue -Values $durations
    $durationCount = @($durations | Where-Object { $null -ne $_ }).Count
    $windowText = if ($windowFires.Count -lt $orderedFires.Count) {
        "the last $($windowFires.Count) of $($orderedFires.Count) succeeded/running fires (era window $EraWindowFires)"
    }
    else {
        "all $($orderedFires.Count) succeeded/running fires (era window $EraWindowFires)"
    }

    [pscustomobject]@{
        Status             = 'evaluated'
        Minutes            = [double]$median
        GapCount           = $orderedGaps.Count
        Note               = "median of $($orderedGaps.Count) gap(s) over $windowText, $($windowFires[0].ScheduledFor.ToString('o')) .. $($windowFires[-1].ScheduledFor.ToString('o'))"
        FirstFire          = $windowFires[0].ScheduledFor
        LastFire           = $windowFires[-1].ScheduledFor
        WindowFires        = $windowFires.Count
        TotalFires         = $orderedFires.Count
        MedianRunMinutes   = $medianRun
        RunDurationSamples = $durationCount
    }
}

$now = ConvertTo-Instant -Value $Now -ParameterName 'Now'
if ($null -eq $now) { $now = [DateTimeOffset]::Now }

$heldFire = ConvertTo-Instant -Value $NextFireAt -ParameterName 'NextFireAt'
$heldExpiry = ConvertTo-Instant -Value $ExpiresAt -ParameterName 'ExpiresAt'

# The armed cron, when the caller knows it. Two owners is an error, the same way
# two run histories are: one rung, one statement of what it is armed at.
$heldInterval = $null
if ($PSBoundParameters.ContainsKey('HeldCron') -and $PSBoundParameters.ContainsKey('HeldIntervalMinutes')) {
    throw 'Pass at most one of -HeldCron and -HeldIntervalMinutes: one armed rung, one interval.'
}
if ($PSBoundParameters.ContainsKey('HeldCron')) {
    if ([string]::IsNullOrWhiteSpace($HeldCron)) {
        throw "-HeldCron was an empty string; pass the schedule record's expression (e.g. '*/4 * * * *') or -HeldIntervalMinutes."
    }
    $heldInterval = Get-CronIntervalMinutes -Cron $HeldCron
}
elseif ($null -ne $HeldIntervalMinutes) {
    if ($HeldIntervalMinutes -le 0) {
        throw '-HeldIntervalMinutes must be greater than zero; omit it when the armed interval is unknown.'
    }
    $heldInterval = [double]$HeldIntervalMinutes
}

$required = Get-RequiredMinutes -State $State -SincePromptMinutes $SincePromptMinutes -ResetWindowMinutes $ResetWindowMinutes -QuietRounds $QuietRounds

# --- run history: one owner, and an unreadable history is a named non-verdict --
$historyInputs = @(
    $PSBoundParameters.ContainsKey('RunHistory')
    $PSBoundParameters.ContainsKey('RunHistoryPath')
    $PSBoundParameters.ContainsKey('RunHistoryJson')
) | Where-Object { $_ }

if (@($historyInputs).Count -gt 1) {
    throw 'Pass at most one of -RunHistory, -RunHistoryPath and -RunHistoryJson: one run history, one owner.'
}

$historySupplied = @($historyInputs).Count -eq 1
$historyText = $null
$historyRows = $null
$historyProblem = $null

if ($PSBoundParameters.ContainsKey('RunHistoryPath')) {
    if ([string]::IsNullOrWhiteSpace($RunHistoryPath)) {
        $historyProblem = '-RunHistoryPath was empty'
    }
    elseif (-not (Test-Path -LiteralPath $RunHistoryPath -PathType Leaf)) {
        $historyProblem = "-RunHistoryPath '$RunHistoryPath' is not a readable file"
    }
    else {
        $historyText = Get-Content -LiteralPath $RunHistoryPath -Raw -Encoding utf8
    }
}
elseif ($PSBoundParameters.ContainsKey('RunHistoryJson')) {
    $historyText = $RunHistoryJson
}
elseif ($PSBoundParameters.ContainsKey('RunHistory')) {
    $historyRows = @($RunHistory)
}

if ($null -ne $historyText) {
    try { $historyRows = Get-RunHistoryRows -Json $historyText }
    catch { $historyProblem = "run history JSON is unreadable: $($_.Exception.Message)" }
}

$effectiveCadence = [pscustomobject]@{
    Status   = 'cannot-evaluate'
    Minutes  = $null
    GapCount = 0
    Note     = 'no run history supplied - effective cadence cannot be evaluated, and the nominal gear is not an assurance of delivery'
}

if ($historySupplied -and -not $historyProblem) {
    if ($null -eq $required) {
        $effectiveCadence = [pscustomobject]@{
            Status   = 'cannot-evaluate'
            Minutes  = $null
            GapCount = 0
            Note     = 'stand-down: no gear to compare the effective cadence against'
        }
    }
    else {
        try { $effectiveCadence = Measure-EffectiveCadence -Rows $historyRows }
        catch { $historyProblem = "run history could not be measured: $($_.Exception.Message)" }
    }
}

# Fire-in-flight evidence, read from the same history. A live `running` fire at
# or before the held fire is proof the daemon is deferring the next fire behind
# it, which is the difference between a healthy rung and a stale record.
$inFlightRun = $null
if ($historySupplied -and -not $historyProblem -and $null -ne $historyRows) {
    try { $inFlightRun = Get-InFlightRun -Rows $historyRows }
    catch { $historyProblem = "run history in-flight evidence is unreadable: $($_.Exception.Message)" }
}

if ($historyProblem) {
    Write-Output "Get-HubCadence: CANNOT-EVALUATE - $historyProblem. The effective cadence is unproven; the nominal gear is not an assurance."
    exit 2
}

$effectiveMinutes = $effectiveCadence.Minutes
$effectiveEvaluated = ($effectiveCadence.Status -eq 'evaluated')
$effectiveRounded = if ($effectiveEvaluated) { [math]::Round([double]$effectiveMinutes, 1) } else { $null }
$effectiveExceedsGear = if ($effectiveEvaluated -and $null -ne $required) {
    [double]$effectiveMinutes -gt ($required + $ToleranceMinutes)
}
else { $null }

$cadenceAgrees = if ($effectiveEvaluated -and $null -ne $required) {
    [math]::Abs([double]$effectiveMinutes - $required) -le $ToleranceMinutes
}
else { $null }

# The satisfiable gear: the larger of the state gear (what the turn wants), the
# measured cadence (the fastest the daemon can actually deliver), and the
# measured RUN DURATION (a cron finer than a run's own duration is dropped by
# the daemon by construction - cl-common-q64). A RECREATE must name a gear that
# this comparison can satisfy on the next evaluation, or the verdict is an
# instruction that cannot be obeyed (cl-common-leb).
$satisfiableMinutes = $required
$suggestedMinutes = if ($effectiveEvaluated) {
    [int][math]::Max(1, [math]::Ceiling([double]$effectiveMinutes))
}
else { $null }

# The run-duration floor: ceil(median run duration over the same era window).
# Absent (null) when no row carried both startedAt and endedAt, so a history
# without durations keeps its previous behaviour instead of guessing one.
$durationFloorMinutes = if ($effectiveEvaluated -and $null -ne $effectiveCadence.MedianRunMinutes) {
    [int][math]::Max(1, [math]::Ceiling([double]$effectiveCadence.MedianRunMinutes))
}
else { $null }
$suggestedCron = $null

if ($effectiveEvaluated -and $null -ne $suggestedMinutes -and $suggestedMinutes -gt $satisfiableMinutes) {
    $satisfiableMinutes = $suggestedMinutes
}
if ($null -ne $durationFloorMinutes -and $durationFloorMinutes -gt $satisfiableMinutes) {
    $satisfiableMinutes = $durationFloorMinutes
}
$satisfiableCron = if ($null -ne $satisfiableMinutes) { Get-CronForMinutes -Minutes ([int]$satisfiableMinutes) } else { $null }

# How the armed rung is named in a reason: the cron when the caller passed one,
# the interval otherwise.
$heldGearText = if ($null -eq $heldInterval) { $null }
elseif ($PSBoundParameters.ContainsKey('HeldCron')) { $HeldCron }
else { "$heldInterval min" }

# Re-express SuggestedMinutes as the gear a recreate should actually arm: the
# satisfiable gear, which is never below the state gear (a peer-hub rung
# measuring 5 min still recreates at its 15 min liveness gear, not at 5). With
# no measured cadence there is nothing to suggest beyond the state gear, so the
# field stays null as before.
if ($effectiveEvaluated) {
    $suggestedMinutes = [int]$satisfiableMinutes
    $suggestedCron = $satisfiableCron
}

$action = $null
$reason = $null
$effectiveNextFire = $heldFire
$deferred = $false
$deferredReason = $null
$inFlightAt = $null
$inFlightMinutes = $null
$overdue = 0
$nominalGap = $null

if ($null -eq $required) {
    $action = 'LAPSE'
    $reason = 'stand-down: zero actionable work, no rung is created'
    $effectiveNextFire = $null
}
elseif ($null -eq $heldFire) {
    $action = 'CREATE'
    $reason = "no rung is known for this turn; create at $required min"
    $effectiveNextFire = $now.AddMinutes($required)
}
else {
    $gap = ($heldFire - $now).TotalMinutes
    $nominalGap = $gap
    $overdue = if ($gap -lt 0) { 0 - $gap } else { 0 }

    # A next fire up to one cron interval in the past is the daemon DEFERRING the
    # phase-adjacent fire because the previous run of the same schedule is still
    # in flight - not a rung that has stopped firing. Measured live 2026-11-03:
    # */2 schedule held nextRunAt 1.4 min in the past, evaluated mid-run. That is
    # a HOLD; only a deferral wider than the gear (or an expired rung) is late.
    $nominalDeferred = (
        $gap -lt (0 - $ToleranceMinutes) -and
        $overdue -le ($required + $ToleranceMinutes)
    )

    # The same deferral, proven by the run history rather than bounded by the
    # gear: a `running` fire of this schedule that started at or before the held
    # fire is a live run the daemon is deferring behind. Its deferral may be far
    # wider than the gear when a turn outlives it (measured 3.5 min on a 2 min
    # rung, 2026-11-03), and recreating then re-arms a rung that is working.
    $inFlightBeforeHeld = $false
    if ($null -ne $inFlightRun) {
        $inFlightAt = $inFlightRun.ScheduledFor
        $inFlightMinutes = [math]::Round(($now - $inFlightAt).TotalMinutes, 1)
        $inFlightBeforeHeld = ($inFlightAt -le $heldFire.AddMinutes($ToleranceMinutes))
    }
    $evidenceDeferred = ($gap -lt (0 - $ToleranceMinutes) -and $inFlightBeforeHeld)

    if ($nominalDeferred -or $evidenceDeferred) {
        $deferred = $true
        $action = 'HOLD'
        if ($evidenceDeferred) {
            $deferredReason = 'in-flight'
            $reason = ("held rung is deferred by {0} min behind the in-flight run of this schedule scheduledFor {1} (running for {2} min); " +
                'a deferral behind a live run is not a dead rung, and recreating it would arm a duplicate') -f `
                [math]::Round($overdue, 1), $inFlightAt.ToString('o'), $inFlightMinutes
        }
        else {
            $deferredReason = 'nominal'
            $reason = "held rung is deferred by $([math]::Round($overdue, 1)) min behind an in-flight run, inside the $required min gear"
        }
    }
    elseif ($gap -lt (0 - $ToleranceMinutes)) {
        $action = 'RECREATE'
        $reason = "held rung is overdue by $([math]::Round($overdue, 1)) min and no run of this schedule is in flight, so the record is stale"
    }
    elseif ($gap -gt ($required + $ToleranceMinutes)) {
        $action = 'RECREATE'
        $reason = "held rung fires in $([math]::Round($gap, 1)) min, required gear is $required min"
    }
    else {
        $action = 'HOLD'
        $reason = "held rung fires in $([math]::Round($gap, 1)) min, inside the $required min gear"
    }

    # The cadence verdict belongs to the EFFECTIVE cadence when it is known. A
    # cron interval the daemon cannot deliver is not a measurement of lateness,
    # and a measured cadence that meets the gear is proof the rung is firing. A
    # proven deferral is never re-judged here: the rung is holding while its own
    # run is live, whatever the measured median says.
    if ($effectiveEvaluated -and -not $deferred) {
        if ($null -ne $heldInterval) {
            if ($heldInterval -gt ($satisfiableMinutes + $ToleranceMinutes) -and -not $AcceptEffectiveCadence) {
                # Armed slower than the gear needs (or than the daemon delivers).
                $action = 'RECREATE'
                $reason = ("held rung is armed at {0} min ({1}) but the satisfiable gear is {2} min ({3}); " +
                    'recreating at {2} min ({3}) clears this on the next evaluation') -f `
                    $heldInterval, $heldGearText, $satisfiableMinutes, $satisfiableCron
            }
            elseif ($heldInterval -gt ($satisfiableMinutes + $ToleranceMinutes)) {
                # A deliberately slower rung, accepted by the operator. The
                # switch used to be consulted only on the armed-FASTER branch,
                # so a rung armed at */10 for a repo whose runs are 7 minutes
                # long could only be cleared by overriding a false RECREATE by
                # hand (measured 2026-11-03, cl-common-q64). Accepting the
                # slower gear is the same operator decision in the other
                # direction, and it is HOLD here for the same reason.
                $action = 'HOLD'
                $reason = ("held rung is armed at {0} min ({1}), deliberately coarser than the satisfiable gear {2} min ({3}); " +
                    '-AcceptEffectiveCadence accepts the slower rung as the assurance, so there is nothing to recreate') -f `
                    $heldInterval, $heldGearText, $satisfiableMinutes, $satisfiableCron
            }
            elseif ($effectiveExceedsGear -and $heldInterval -lt ($satisfiableMinutes - $ToleranceMinutes) -and -not $AcceptEffectiveCadence) {
                # Armed faster than the daemon can deliver: the cron states a
                # promise the daemon does not keep.
                $action = 'RECREATE'
                $reason = ("held rung is armed at {0} min ({1}), finer than the daemon delivers ({2} min, median of {3} gap(s)); " +
                    'recreate at {2} min ({4}) so the armed cron states the delivered gear, or pass -AcceptEffectiveCadence to keep the finer cron') -f `
                    $heldInterval, $heldGearText, $satisfiableMinutes, $effectiveCadence.GapCount, $satisfiableCron
            }
            elseif ($effectiveExceedsGear) {
                # Armed at (or accepted as) the satisfiable gear. Recreating into
                # the cron already held was the unsatisfiable loop (cl-common-leb).
                $action = 'HOLD'
                $reason = ("held rung is armed at {0} min ({1}), matching the measured effective cadence ({2} min, median of {3} gap(s)); " +
                    'the satisfiable gear is the gear already held, so there is nothing to recreate') -f `
                    $heldInterval, $heldGearText, $effectiveRounded, $effectiveCadence.GapCount
            }
            elseif ($action -eq 'RECREATE') {
                $action = 'HOLD'
                $reason = ("effective cadence {0} min satisfies the required {1} min gear, so the nominal held-fire " +
                    'reading ({2}) is not a recreate signal') -f `
                    $effectiveRounded, $required, $reason
            }
        }
        elseif ($effectiveExceedsGear) {
            if ($AcceptEffectiveCadence) {
                $action = 'HOLD'
                $reason = ("effective cadence {0} min (median of {1} gap(s)) accepted as the assurance: the nominal {2} min gear is not " +
                    'deliverable while a fire''s run is in flight, so the measured cadence is the gear') -f `
                    $effectiveRounded, $effectiveCadence.GapCount, $required
            }
            else {
                $action = 'RECREATE'
                $reason = ("effective cadence {0} min (median of {1} gap(s)) exceeds the required {2} min gear; " +
                    "the nominal cron is not deliverable while a fire's run is in flight - recreate at {3} min ({4}) " +
                    'to match the measured cadence, and pass -HeldCron {4} next turn (or -AcceptEffectiveCadence) so the ' +
                    'verdict clears instead of recreating again') -f `
                    $effectiveRounded, $effectiveCadence.GapCount, $required, $suggestedMinutes, $suggestedCron
            }
        }
        elseif ($action -eq 'RECREATE') {
            $action = 'HOLD'
            $reason = ("effective cadence {0} min satisfies the required {1} min gear, so the nominal held-fire " +
                'reading ({2}) is not a recreate signal') -f `
                $effectiveRounded, $required, $reason
        }
    }

    # Without a measured cadence the held cron is still evidence: a rung armed
    # coarser than the gear has to be recreated even when the one fire in front
    # of it happens to be close.
    if (-not $effectiveEvaluated -and -not $deferred -and $action -eq 'HOLD' -and
        $null -ne $heldInterval -and $heldInterval -gt ($satisfiableMinutes + $ToleranceMinutes)) {
        $action = 'RECREATE'
        $reason = ("held rung is armed at {0} min ({1}), coarser than the required {2} min gear; " +
            'recreate at {2} min ({3})') -f $heldInterval, $heldGearText, $satisfiableMinutes, $satisfiableCron
    }

    # Expiry must cover two fires at the required gear, or the rung lapses mid-drain.
    if ($action -eq 'HOLD' -and $null -ne $heldExpiry) {
        $cover = ($heldExpiry - $now).TotalMinutes
        if ($cover -lt (2 * $required)) {
            $action = 'RECREATE'
            $reason = "expiry in $([math]::Round($cover, 1)) min cannot cover two $required min fires"
        }
    }

    if ($action -eq 'RECREATE') { $effectiveNextFire = $now.AddMinutes($satisfiableMinutes) }
}

# A caller that claims the effective cadence as its assurance gets a named
# non-zero when it is absent; a caller that only holds a rung keeps today's
# behaviour and the honest note on the Cadence line.
if ($RequireEffectiveCadence -and -not $effectiveEvaluated -and $null -ne $required) {
    Write-Output ("Get-HubCadence: CANNOT-EVALUATE - -RequireEffectiveCadence was passed but the effective cadence is unknown ({0}). The nominal {1} min gear is not an assurance of delivery." -f $effectiveCadence.Note, $required)
    exit 2
}

$cron = if ($null -eq $required) { $null } else { Get-CronForMinutes -Minutes $required }
$nextText = if ($null -eq $effectiveNextFire) { 'none' } else { $effectiveNextFire.ToString('yyyy-MM-dd HH:mm zzz') }

# The cron printed on the Rung line is the rung the next evaluation will judge:
# the armed cron while holding, the satisfiable cron while recreating. Printing
# the state gear there read as "next 16:37 (*/2)" on a rung actually armed at
# */4 (measured 2026-11-03) and hid the gear the action names.
$displayCron = if ($action -eq 'HOLD' -and $null -ne $heldGearText) { $heldGearText }
elseif ($action -eq 'RECREATE' -and $null -ne $satisfiableCron) { $satisfiableCron }
else { $cron }

# State BOTH cadences whenever they disagree: "required 2 min - HOLD" alone was
# read as a 2-minute detection promise the daemon did not keep.
$cadenceClause = if ($effectiveEvaluated -and $cadenceAgrees -eq $false) {
    ' (nominal {0} min, effective {1} min)' -f $required, $effectiveRounded
}
else { '' }

$rungLine = if ($null -eq $required) {
    "Rung: none (stand-down) - $action`: $reason"
}
else {
    "Rung: $Name next $nextText ($displayCron) - required $required min - $action$cadenceClause`: $reason"
}

$effectiveText = if ($effectiveEvaluated) { "${effectiveRounded}min" }
elseif ($null -eq $required) { 'cannot-evaluate (stand-down)' }
else { 'cannot-evaluate' }

$result = [ordered]@{
    State                   = $State
    SincePromptMinutes      = if ($null -ne $SincePromptMinutes) { $SincePromptMinutes } else { $null }
    SincePromptKnown        = ($null -ne $SincePromptMinutes)
    QuietRounds             = $QuietRounds
    RequiredMinutes         = $required
    NominalMinutes          = $required
    Cron                    = $cron
    Action                  = $action
    Reason                  = $reason
    Deferred                = $deferred
    DeferredReason          = $deferredReason
    InFlightRunAt           = if ($null -ne $inFlightAt) { $inFlightAt.ToString('o') } else { $null }
    InFlightRunMinutes      = $inFlightMinutes
    OverdueMinutes          = [math]::Round($overdue, 2)
    NominalGapMinutes       = if ($null -ne $nominalGap) { [math]::Round([double]$nominalGap, 2) } else { $null }
    HeldIntervalMinutes     = $heldInterval
    SatisfiableMinutes      = $satisfiableMinutes
    SatisfiableCron         = $satisfiableCron
    AcceptedEffectiveCadence = [bool]$AcceptEffectiveCadence
    EffectiveMinutes        = if ($effectiveEvaluated) { $effectiveRounded } else { $null }
    EffectiveCadenceStatus  = $effectiveCadence.Status
    EffectiveCadenceNote    = $effectiveCadence.Note
    EffectiveGapCount       = $effectiveCadence.GapCount
    EffectiveWindowFires    = if ($effectiveEvaluated) { $effectiveCadence.WindowFires } else { $null }
    EffectiveTotalFires     = if ($effectiveEvaluated) { $effectiveCadence.TotalFires } else { $null }
    MedianRunMinutes        = if ($effectiveEvaluated -and $null -ne $effectiveCadence.MedianRunMinutes) { [math]::Round([double]$effectiveCadence.MedianRunMinutes, 2) } else { $null }
    RunDurationSamples      = if ($effectiveEvaluated) { $effectiveCadence.RunDurationSamples } else { $null }
    RunDurationFloorMinutes = $durationFloorMinutes
    EffectiveExceedsGear    = $effectiveExceedsGear
    CadenceAgreement        = if ($null -eq $cadenceAgrees) { 'cannot-evaluate' } elseif ($cadenceAgrees) { 'agrees' } else { 'differs' }
    SuggestedMinutes        = $suggestedMinutes
    SuggestedCron           = $suggestedCron
    NextFireAt              = if ($null -ne $effectiveNextFire) { $effectiveNextFire.ToString('o') } else { $null }
    NextFireAtWasHeld       = ($null -ne $heldFire)
    ExpiresAt               = if ($null -ne $heldExpiry) { $heldExpiry.ToString('o') } else { $null }
    Now                     = $now.ToString('o')
    RungLine                = $rungLine
}

if ($Json) {
    $result | ConvertTo-Json -Depth 4
}
else {
    Write-Output $rungLine
    Write-Output ("Cadence: state={0} action={1} required={2}min cron={3} effective={4}" -f $State, $action, $required, $cron, $effectiveText)
}

exit 0
