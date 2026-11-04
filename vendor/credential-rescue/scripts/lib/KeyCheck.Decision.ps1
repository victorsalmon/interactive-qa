#Requires -Version 7.0
<#
.SYNOPSIS
    Pure decision functions for Invoke-KeyCheck.ps1 (Key Check).

.DESCRIPTION
    Dot-source this file; it defines functions only and performs no I/O. Every
    decision the Key Check run makes - eligibility, ranking, imminent /
    near-exhaustion, the next phase, the trigger decision, and the post-rescue
    bookkeeping - lives here so the runbook's invariants can be tested without
    a clock, a network, or a credential.

    Reading shape (one pool key as observed):
        [pscustomobject]@{
            KeyNumber = [int]
            Label     = 'GO3'
            Weekly    = @{ Percent = [double]|$null; Status = ''; ResetsAt = '' }
            Monthly   = @{ Percent = [double]|$null; Status = ''; ResetsAt = '' }
        }

    `Percent = $null` means the meter was not reported (never treat it as 0).
    `Status` is the endpoint's window status (`ok`, `rate-limited`, ...);
    `rate-limited` on either meter makes a key ineligible and imminent
    regardless of the percentage it printed.

    SECURITY: nothing in this file reads or prints a key value.
#>

# Meter thresholds. Weekly is a 7-day slice (50 % of the monthly allowance),
# monthly is the account term (100 %), the rolling 5 h window is 20 % and is
# deliberately NOT a Key Check trigger.
$script:KeyCheckWeeklyIneligible = 80    # heartbeat escalates at >= 80 wk
$script:KeyCheckMonthlyIneligible = 90   # heartbeat escalates at >= 90 mo
$script:KeyCheckWeeklyImminent = 96      # near escalates at > 96 wk
$script:KeyCheckMonthlyImminent = 98     # near escalates at > 98 mo

# Hysteresis: arming is one-sided by design, so a misread (or a key that cools
# because a burst ended) would otherwise keep the fast loop hot for hours. The
# disarm band sits clear of the arm band (80/90) so a key hovering at the
# threshold cannot flip phase on every check.
$script:KeyCheckDisarmWeekly = 70        # disarm needs wk < 70 AND mo < 80
$script:KeyCheckDisarmMonthly = 80
$script:KeyCheckDisarmConsecutive = 2    # ... for 2 consecutive checks

# Cadence: the phases differ only by a CEILING. Both are driven by the same
# adaptive gear (measured burn); `heartbeat` may stretch to an hour, while `near`
# - a key already inside the escalation band - is never left unlooked-at for more
# than 15 minutes. The old fixed 120 s near poll was a guess that cost ~30 reads
# an hour for information that changes once an hour; nothing polls faster than a
# minute either way.
$script:KeyCheckNearCeilingSeconds = 900
$script:KeyCheckHeartbeatCeilingSeconds = 3600

# Adaptive cadence (operator, 2026-11-02): the heartbeat ticks slowly while the
# key is quiet and speeds up only as the measured burn rate brings the trigger
# closer. The ladder is derived from ETT (Estimated Time to Trigger, in MINUTES);
# the base gear is the run's interval (never slower than an hour), and nothing
# ever polls faster than a minute.
$script:KeyCheckCadenceBaseSeconds = 3600
$script:KeyCheckCadenceMinimumSeconds = 60
$script:KeyCheckCadenceMinimumSampleMinutes = 15   # a burn window narrower than this proves nothing
$script:KeyCheckCadenceSampleLimit = 12            # per-meter history bound (5-min gear x 12 = an hour)
$script:KeyCheckCadenceBetterTicks = 2             # a LOOSER gear needs two consecutive ticks
$script:KeyCheckCadenceFloorTicks = 20             # 1-minute ticks before the floor cap holds at 5 min
$script:KeyCheckCadenceFloorHoldSeconds = 300

# Tolerance: one 429 is noise (a concurrent burst, a shared egress), two in a
# row is the key. Three unreadable reads in a row is a broken meter, not a
# healthy key.
$script:KeyCheckRateLimitTriggerStreak = 2
$script:KeyCheckCannotEvaluateLimit = 3

# Explicit reset-time shapes. The producer prints a LOCAL short date
# (`11/23/2026 23:43:24`); the order of day and month depends on the producer's
# culture, so both orders are listed and tried under InvariantCulture - never
# under the machine's culture, which is what made the window math silently wrong.
$script:KeyCheckResetFormats = @(
    'yyyy-MM-ddTHH:mm:ss'
    'yyyy-MM-ddTHH:mm:ss.FFFFFFF'
    'yyyy-MM-ddTHH:mm:sszzz'
    'yyyy-MM-ddTHH:mm:ss.FFFFFFFzzz'
    'yyyy-MM-ddTHH:mm:ss.FFFFFFFZ'
    'yyyy-MM-dd HH:mm:ss'
    'yyyy-MM-dd'
    'M/d/yyyy H:mm:ss'
    'M/d/yyyy h:mm:ss tt'
    'M/d/yyyy H:mm'
    'd/M/yyyy H:mm:ss'
    'd/M/yyyy h:mm:ss tt'
    'd/M/yyyy H:mm'
)

function Get-KeyCheckGrammar {
    <#
    .SYNOPSIS
        The command grammar string, printed on invalid input.
    #>
    return 'Key Check [minutes] [hours]   (defaults: 15 minutes / 2 hours; e.g. "Key Check 30" = 30 min / 2 h)'
}

function Test-KeyCheckGrammar {
    <#
    .SYNOPSIS
        True when the interval and duration are usable (minutes >= 1, hours > 0).
    #>
    param([int]$IntervalMinutes, [double]$DurationHours)
    return ($IntervalMinutes -ge 1 -and $DurationHours -gt 0)
}

function Get-KeyCheckDeadline {
    <#
    .SYNOPSIS
        The run deadline: wall clock from start, fixed once and never extended.
    #>
    param([datetime]$Start, [double]$DurationHours)
    return $Start.AddHours($DurationHours)
}

function ConvertTo-KeyCheckReading {
    <#
    .SYNOPSIS
        Normalize one usage row (Get-GoKeyUsage -Json shape) into a reading.
    .DESCRIPTION
        Accepts `Key` ('GO3') or `KeyNumber` (3) and tolerates a missing window:
        an absent/`-1` percent becomes $null so "not reported" can never be
        mistaken for "0 % used".
    #>
    param($Row)

    if ($null -eq $Row) { return $null }

    $number = 0
    if ($Row.PSObject.Properties['KeyNumber'] -and $null -ne $Row.KeyNumber) {
        $number = [int]$Row.KeyNumber
    } elseif ($Row.PSObject.Properties['Key'] -and ([string]$Row.Key -match '^GO?(\d+)$')) {
        $number = [int]$Matches[1]
    }
    if ($number -le 0) { return $null }

    $window = {
        param($w)
        if ($null -eq $w) { return $null }
        $percent = $null
        if ($w.PSObject.Properties['percent'] -and $null -ne $w.percent) {
            $p = [double]$w.percent
            if ($p -ge 0) { $percent = $p }
        } elseif ($w.PSObject.Properties['Percent'] -and $null -ne $w.Percent) {
            $p = [double]$w.Percent
            if ($p -ge 0) { $percent = $p }
        }
        $status = if ($w.PSObject.Properties['status']) { [string]$w.status }
                  elseif ($w.PSObject.Properties['Status']) { [string]$w.Status } else { '' }
        $raw = if ($w.PSObject.Properties['resetsAt']) { $w.resetsAt }
               elseif ($w.PSObject.Properties['ResetsAt']) { $w.ResetsAt } else { '' }
        # ConvertFrom-Json re-types an ISO timestamp as [datetime]; stringify it
        # back to ISO so the ledger never receives a locale-formatted date.
        $resets = if ($raw -is [datetime]) { $raw.ToString('yyyy-MM-ddTHH:mm:ss') }
                  elseif ($raw -is [datetimeoffset]) { $raw.ToString('yyyy-MM-ddTHH:mm:ss') }
                  else { [string]$raw }
        if ($resets -eq '0001-01-01T00:00:00') { $resets = '' }
        return [pscustomobject]@{ Percent = $percent; Status = $status; ResetsAt = $resets }
    }

    return [pscustomobject]@{
        KeyNumber = $number
        Label     = "GO$number"
        Weekly    = (& $window $Row.Weekly)
        Monthly   = (& $window $Row.Monthly)
        Http      = if ($Row.PSObject.Properties['Http']) { [int]$Row.Http } else { 200 }
        Verdict   = if ($Row.PSObject.Properties['Verdict']) { [string]$Row.Verdict } else { '' }
    }
}

function Get-KeyCheckPercent {
    param($Window)
    if ($null -eq $Window) { return $null }
    return $Window.Percent
}

function ConvertTo-KeyCheckResetTime {
    <#
    .SYNOPSIS
        Parse a meter's `resetsAt` into a [datetime], or $null when the shape is
        not one we know.
    .DESCRIPTION
        The producer emits a LOCAL short date (`11/23/2026 23:43:24`) whose day
        and month order follows ITS culture, plus ISO-8601 from other paths.
        Parsing with the machine's culture is the E3 defect: on an en-GB box
        `11/23/2026` is not even a date. So every accepted shape is listed
        explicitly and tried under InvariantCulture, and a miss returns $null
        instead of throwing.

        Day-first is tried after month-first, so an ambiguous `5/6/2026` reads
        as May 6 (the producer's documented US shape). An unambiguous
        `23/11/2026` still parses because month-first rejects 23 as a month.
    .PARAMETER Text
        The raw string (or a [datetime] the JSON reader already re-typed).
    #>
    param($Text)

    if ($null -eq $Text) { return $null }
    if ($Text -is [datetime]) { return [datetime]$Text }
    if ($Text -is [datetimeoffset]) { return ([datetimeoffset]$Text).LocalDateTime }

    $value = [string]$Text
    if ([string]::IsNullOrWhiteSpace($value)) { return $null }
    $value = $value.Trim()

    $parsed = [datetime]::MinValue
    foreach ($format in $script:KeyCheckResetFormats) {
        $ok = [datetime]::TryParseExact(
            $value,
            $format,
            [cultureinfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AllowWhiteSpaces,
            [ref]$parsed)
        if ($ok) { return $parsed }
    }
    return $null
}

function Get-KeyCheckWindowUnknownNote {
    <#
    .SYNOPSIS
        A note naming an unparsable reset time, or '' when the window is known.
    .DESCRIPTION
        An unknown window is never fatal: the raw string is recorded so the
        operator can see what the producer actually sent, and ranking falls back
        to the rolling value (an unknown monthly reset sorts last, so it can
        never outrank a key with a known-sooner reset).
    #>
    param($Reading)

    if ($null -eq $Reading -or $null -eq $Reading.Monthly) { return '' }
    $raw = [string]$Reading.Monthly.ResetsAt
    if ([string]::IsNullOrWhiteSpace($raw)) { return '' }
    if ($null -ne (ConvertTo-KeyCheckResetTime -Text $raw)) { return '' }
    return "window-unknown: monthly resetsAt '$raw' is not a recognised shape (ranking fell back to the rolling value)"
}

function Test-KeyCheckRateLimited {
    <#
    .SYNOPSIS
        True when the read itself was rate-limited (HTTP 429 or a 429 window).
    .DESCRIPTION
        A rate-limited read is not a measurement, so it must not be read as
        "the key is at 0 %". It is also NOT a trigger on its own (E2) - the
        caller counts consecutive rate-limited reads.
    #>
    param($Reading)

    if ($null -eq $Reading) { return $false }
    if ($Reading.PSObject.Properties['Http'] -and [int]$Reading.Http -eq 429) { return $true }
    foreach ($w in @($Reading.Weekly, $Reading.Monthly)) {
        if ($null -ne $w -and $w.Status -eq 'rate-limited') { return $true }
    }
    return $false
}

function Test-KeyCheckPercentImminent {
    <#
    .SYNOPSIS
        The percentage-only trigger: weekly > 96 OR monthly > 98.
    .DESCRIPTION
        Split out from Test-KeyCheckImminent so the trigger can distinguish a
        meter that says the key is spent from a single rate-limited response.
    #>
    param($Reading)

    if ($null -eq $Reading) { return $false }
    $wk = Get-KeyCheckPercent $Reading.Weekly
    $mo = Get-KeyCheckPercent $Reading.Monthly
    if ($null -ne $wk -and $wk -gt $script:KeyCheckWeeklyImminent) { return $true }
    if ($null -ne $mo -and $mo -gt $script:KeyCheckMonthlyImminent) { return $true }
    return $false
}

function Test-KeyCheckDisarm {
    <#
    .SYNOPSIS
        True when a reading is inside the disarm band: weekly < 70 AND monthly < 80.
    .DESCRIPTION
        Both meters must clear, never one: an unknown meter ($null) is not
        evidence of cooling. Two consecutive such readings disarm (see
        Get-KeyCheckNextPhase), so one healthy-looking sample is not enough.
    #>
    param($Reading)

    if ($null -eq $Reading) { return $false }
    $wk = Get-KeyCheckPercent $Reading.Weekly
    $mo = Get-KeyCheckPercent $Reading.Monthly
    if ($null -eq $wk -or $null -eq $mo) { return $false }
    return ($wk -lt $script:KeyCheckDisarmWeekly -and $mo -lt $script:KeyCheckDisarmMonthly)
}

function Test-KeyCheckMeterUnreadable {
    <#
    .SYNOPSIS
        True when the meter has produced no reading for too many checks in a row.
    #>
    param([int]$ConsecutiveCannotEvaluate = 0)

    return ($ConsecutiveCannotEvaluate -ge $script:KeyCheckCannotEvaluateLimit)
}

function Get-KeyCheckCadenceSeconds {
    <#
    .SYNOPSIS
        The poll cadence for a phase: the adaptive gear, clamped by the phase's
        ceiling.
    .DESCRIPTION
        Both polling phases use the same burn-derived gear and differ only by how
        stale a reading may get:

          heartbeat  clamp(gear, 1 min, 60 min)   - a quiet key is checked hourly
          near       clamp(gear, 1 min, 15 min)   - a key inside the band is never
                                                    left unlooked-at for 15 min

        The old fixed 120 s near poll is gone: it was a guess that spent ~30 reads
        an hour on a number that moves once an hour. The 1-minute floor is the
        hard limit - nothing polls faster than a minute, in any phase.
    #>
    param([string]$Phase, [int]$IntervalMinutes = 15, [int]$CadenceSeconds = 0)

    $minimum = $script:KeyCheckCadenceMinimumSeconds
    $ceiling = if ($Phase -eq 'near') { $script:KeyCheckNearCeilingSeconds }
               else { $script:KeyCheckHeartbeatCeilingSeconds }
    $gear = if ($CadenceSeconds -gt 0) { [int]$CadenceSeconds } else { [int]$IntervalMinutes * 60 }
    $clamped = [Math]::Max($minimum, [Math]::Min($gear, $ceiling))
    return [double]$clamped
}

function Get-KeyCheckCadenceLabel {
    <#
    .SYNOPSIS
        The gear name for an interval: '60m', '30m', '15m', '5m', '1m'.
    #>
    param([int]$Seconds)

    if ($Seconds -lt 60) { return "$($Seconds)s" }
    return "$([int]([Math]::Round($Seconds / 60)))m"
}

function Get-KeyCheckCadenceResetsSignature {
    <#
    .SYNOPSIS
        The reset-window identity of a reading, as a comparable string.
    .DESCRIPTION
        A window that reset between two samples is a NEW measurement window, so
        the burn history from before the reset is not comparable and the ring is
        discarded. Comparing the parsed reset instants (not the raw strings)
        keeps the `11/9/2026` and ISO-8601 shapes of the same instant equal.
    #>
    param($Reading)

    $parts = @()
    foreach ($window in @($Reading.Weekly, $Reading.Monthly)) {
        $raw = if ($null -ne $window -and $window.PSObject.Properties['ResetsAt']) { $window.ResetsAt } else { $null }
        $at = ConvertTo-KeyCheckResetTime -Text $raw
        # An unparsable shape still compares by its raw text: a DIFFERENT reset
        # is a different window even when this parser does not know the shape.
        $parts += $(if ($null -ne $at) { $at.ToString('o') } elseif ([string]::IsNullOrWhiteSpace([string]$raw)) { '' } else { "raw:$([string]$raw)" })
    }
    return ($parts -join '|')
}

function ConvertTo-KeyCheckCadenceSamplePercent {
    <#
    .SYNOPSIS
        A sample's meter value as a number, or $null when the meter was not
        reported (absent, or the producer's -1 sentinel).
    #>
    param($Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [bool] -or -not ($Value -is [ValueType])) { return $null }
    $number = [double]$Value
    if ($number -lt 0) { return $null }
    return $number
}

function Add-KeyCheckCadenceSample {
    <#
    .SYNOPSIS
        Append this tick's reading to the bounded per-run sample ring.
    .DESCRIPTION
        PURE - the caller supplies the clock, the reading and the ring it has so
        far, and gets the ring to persist. The ring is what makes a burn window
        possible once the gear is faster than the 15-minute guard: with only
        "the previous poll" a 5-minute gear can never form a qualifying pair and
        ETT stays null forever (cl-common-6yr).

          - each entry is `{ at, wk, mo }` in PERCENT POINTS, never a raw row;
          - `at` is a culture-free ISO-8601 shape the reset parser accepts;
          - the ring is bounded (oldest pruned first), so a long run cannot grow
            the state file without limit;
          - a GENERATION change (a cutover: different key) or a reset-window
            change discards the ring, so no delta is ever measured across keys
            or across a reset - and the one-time seed from `Previous` is skipped
            when that reading belongs to a different key (cl-common-8yq).
    .PARAMETER Samples
        The ring as persisted so far (may be $null on the first tick).
    .PARAMETER Reading
        This tick's reading.
    .PARAMETER Now
        The fixed clock for this tick.
    .PARAMETER Generation
        The run's generation (incremented by a cutover).
    .PARAMETER PreviousGeneration
        The generation the persisted ring was recorded under.
    .PARAMETER PreviousSignature
        The ring's reset-window signature (Get-KeyCheckCadenceResetsSignature).
    .PARAMETER Previous
        The reading the persisted `PreviousAt` belonged to. Used ONCE, to seed the
        ring on the first tick after a resume (or after this fix landed on a run
        already in flight), so a qualifying window is not lost.
    .PARAMETER PreviousAt
        When `Previous` was sampled.
    .PARAMETER Limit
        The ring bound; the oldest entries beyond it are pruned.
    #>
    param(
        $Samples = $null,
        $Reading = $null,
        [datetime]$Now = (Get-Date),
        [int]$Generation = 0,
        [int]$PreviousGeneration = 0,
        [string]$PreviousSignature = '',
        $Previous = $null,
        $PreviousAt = $null,
        [int]$Limit = $script:KeyCheckCadenceSampleLimit
    )

    $ring = @($Samples | Where-Object { $null -ne $_ })
    $signature = Get-KeyCheckCadenceResetsSignature -Reading $Reading
    $cleared = $false
    $clearReason = ''
    if ($ring.Count -gt 0 -and $Generation -ne $PreviousGeneration) {
        $ring = @()
        $cleared = $true
        $clearReason = 'generation'
    } elseif ($ring.Count -gt 0 -and $PreviousSignature -and $signature -ne $PreviousSignature) {
        $ring = @()
        $cleared = $true
        $clearReason = 'window-reset'
    }

    # Seeding from `Previous` is only legitimate while it is the SAME key: after a
    # rescue the persisted `lastReading` still belongs to the exhausted key, and a
    # delta across keys (5 % -> 97 %) would read as a huge burn on the fresh key.
    $sameKey = ($null -eq $Previous -or -not $Previous.PSObject.Properties['KeyNumber'] -or
        -not $Reading.PSObject.Properties['KeyNumber'] -or
        [int]$Previous.KeyNumber -eq [int]$Reading.KeyNumber)
    if ($ring.Count -eq 0 -and $null -ne $Previous -and $sameKey) {
        $seedAt = ConvertTo-KeyCheckResetTime -Text $PreviousAt
        if ($null -ne $seedAt) {
            $ring += [pscustomobject]@{
                at = $seedAt.ToString('yyyy-MM-ddTHH:mm:ss')
                wk = ConvertTo-KeyCheckCadenceSamplePercent (Get-KeyCheckPercent $Previous.Weekly)
                mo = ConvertTo-KeyCheckCadenceSamplePercent (Get-KeyCheckPercent $Previous.Monthly)
            }
        }
    }

    if ($null -ne $Reading) {
        $ring += [pscustomobject]@{
            at = $Now.ToString('yyyy-MM-ddTHH:mm:ss')
            wk = ConvertTo-KeyCheckCadenceSamplePercent (Get-KeyCheckPercent $Reading.Weekly)
            mo = ConvertTo-KeyCheckCadenceSamplePercent (Get-KeyCheckPercent $Reading.Monthly)
        }
    }
    if ($Limit -gt 0 -and $ring.Count -gt $Limit) {
        $ring = @($ring | Select-Object -Last $Limit)
    }

    return [pscustomobject]@{
        Samples     = $ring
        Signature   = $signature
        Generation  = $Generation
        Cleared     = $cleared
        ClearReason = $clearReason
    }
}

function Get-KeyCheckCadenceGear {
    <#
    .SYNOPSIS
        The adaptive poll gear: how fast to tick, derived from measured burn.
    .DESCRIPTION
        PURE - the caller supplies the clock and the persisted history, so every
        rule is testable without a network read or clock mocking.

        shape:
          remaining      = min(96 - wk, 98 - mo) over the meters that are
                           actually REPORTED, CLAMPED at zero per meter. An
                           unreported meter is not 0 %; a CROSSED trigger leaves
                           zero headroom, never a negative one (cl-common-8yq:
                           ETT -8.1 min used to be audited as a real number).
          burnPerMinute  = per-meter (current - previous) / minutes between samples
          ettMinutes     = Estimated Time to Trigger: remaining / burn, per meter;
                           the binding meter (the smallest) sets the gear, so a
                           quiet weekly cannot hide a fast-burning monthly.
                           NULL - never infinity, never a sentinel - when there is
                           no second sample or the measured burn is not positive.
                           Never negative: 0 means "the trigger is here now".

        One concept, one unit: everything below is MINUTES.

        | ettMinutes  | interval |
        | > 240       | base (60 min max) |
        | 120-240     | 30 min |
        | 60-120      | 15 min |
        | 20-60       | 5 min |
        | < 20        | 1 min |

        The ladder is clamped to the PHASE CEILING (`heartbeat` 60 min, `near`
        15 min), not to the run's base interval: a quiet key is checked hourly
        even when the run was started with `-IntervalMinutes 15`. The base gear
        is the STARTING gear (before any measured burn) and the flat-window
        loosening target only.

        Guards, because the meters are integer percentages:
          - a GENERATION change (a rescue: the key was replaced) is a NEW meter:
            the ring is discarded and the gear returns to the phase ceiling, then
            the ladder re-tightens from measured burn (`generation-reset`). A
            fresh key at 5 % must not inherit the 1-minute gear the exhausted
            key had earned (cl-common-8yq);
          - the burn window is the OLDEST sample in the ring that is at least 15
            minutes old (`window-15m`); with a shorter history the oldest sample
            available is used and the reason says `window-short`;
          - fewer than two samples: keep the gear - but never keep an unsafely
            fast one while the last measured ETT implies a slower gear
            (`/ett-held`);
          - a flat window (no meter moved): keep the gear on the first tick and
            loosen only after two consecutive flat ticks - never tighten;
          - a reset crossed between the samples, or a meter that went DOWN:
            discard the burn for this tick and keep the gear once;
          - `heartbeat` ALWAYS re-derives from ETT: a measured ETT applies in both
            directions on the same tick, because the phase's contract is "a quiet
            key is checked hourly" and a stale fast gear is what burns a read an
            hour times sixty. `near` keeps tighten-now / loosen-after-two-ticks;
          - cap the 1-minute ticks per run and hold at 5 min when the cap is hit.
    .PARAMETER Samples
        The per-meter history persisted by the run (`{ at, wk, mo }` entries),
        oldest first. This - not "the previous poll" - is what the burn window is
        measured from, so a 5- or 1-minute gear can still form a qualifying pair.
    .PARAMETER Previous
        The previous reading (same shape as `Current`), or $null for the first.
    .PARAMETER Current
        This tick's reading.
    .PARAMETER LastCheckAt
        When `Previous` was sampled. Its age is the burn denominator.
    .PARAMETER Now
        The fixed clock for this evaluation.
    .PARAMETER PreviousGear
        The gear the run is on ('60m', '30m', '15m', '5m', '1m'), '' at initial.
    .PARAMETER PreviousSeconds
        The seconds the run is on; 0 means "use the base gear".
    .PARAMETER BaseSeconds
        The base gear (the run's interval), clamped to [1 min, 60 min].
    .PARAMETER LoosenStreak
        Consecutive better-gear ticks already observed (hysteresis counter).
    .PARAMETER FloorTicks
        How many 1-minute ticks this run has already spent.
    .PARAMETER FloorCap
        The 1-minute tick budget before the floor cap holds.
    .PARAMETER Phase
        The polling phase (`heartbeat` or `near`): it owns the ceiling that bounds
        the ladder, and whether a looser gear applies immediately (`heartbeat`) or
        only after two consecutive better ticks (`near`).
    .PARAMETER GenerationReset
        True when the key changed since the ring was recorded (a rescue). The
        history is void, so the gear returns to the phase ceiling and the ladder
        re-tightens from measured burn.
    .PARAMETER PriorEttMinutes
        The last MEASURED ETT (state `ettMinutes`). Used only on a keep path, to
        refuse to hold a gear faster than that ETT implies; never used to speed up.
    #>
    param(
        $Samples = $null,
        $Previous = $null,
        $Current = $null,
        $LastCheckAt = $null,
        [datetime]$Now = (Get-Date),
        [string]$PreviousGear = '',
        [int]$PreviousSeconds = 0,
        [int]$BaseSeconds = $script:KeyCheckCadenceBaseSeconds,
        [int]$LoosenStreak = 0,
        [int]$FloorTicks = 0,
        [int]$FloorCap = $script:KeyCheckCadenceFloorTicks,
        [int]$MinimumSeconds = $script:KeyCheckCadenceMinimumSeconds,
        [string]$Phase = 'heartbeat',
        [switch]$GenerationReset,
        $PriorEttMinutes = $null
    )

    $minimum = [Math]::Max(1, [int]$MinimumSeconds)
    $base = [Math]::Min($script:KeyCheckCadenceBaseSeconds, [Math]::Max($minimum, [int]$BaseSeconds))
    $heldSeconds = if ($PreviousSeconds -gt 0) { [Math]::Max($minimum, [int]$PreviousSeconds) } else { $base }
    $heldGear = if ($PreviousGear) { [string]$PreviousGear } else { Get-KeyCheckCadenceLabel $base }

    # The phase owns the ceiling. Reaching it through the phase clamp keeps one
    # expression of "how stale may a reading get" for both the sleep and the gear.
    $ceiling = Get-KeyCheckCadenceSeconds -Phase $Phase -CadenceSeconds $script:KeyCheckHeartbeatCeilingSeconds

    # The ETT ladder, in SECONDS - one place, so a units slip cannot pass a test
    # that asserts a label. Bounded by the floor and the phase ceiling.
    $ladderFor = {
        param($Ett)
        $value = [double]$Ett
        $seconds = if ($value -gt 240) { 3600 }
                   elseif ($value -ge 120) { 1800 }
                   elseif ($value -ge 60) { 900 }
                   elseif ($value -ge 20) { 300 }
                   else { $minimum }
        return [int][Math]::Max($minimum, [Math]::Min([int]$seconds, [int]$ceiling))
    }

    # A rescue is a NEW meter: the ring the caller discarded measured the old key,
    # so the gear goes back to the phase ceiling and the ladder re-tightens. This
    # is the reset that the "keep the previous gear" rule used to swallow
    # (cl-common-8yq: generation 1, GO3 at 5 %, gear still 60 s).
    if ($GenerationReset) {
        $reset = [int][Math]::Max($minimum, [int]$ceiling)
        return [pscustomobject]@{
            Seconds       = $reset
            Gear          = (Get-KeyCheckCadenceLabel $reset)
            Reason        = "generation-reset/phase-$Phase-ceiling"
            BurnPerMinute = $null
            EttMinutes    = $null
            Remaining     = $null
            LoosenStreak  = 0
            FloorTick     = $false
        }
    }

    $keep = {
        param([string]$Reason, $Burn, $Ett, $Remaining, [int]$Streak = $LoosenStreak)
        $ett = if ($null -ne $Ett) { [double]$Ett }
               elseif ($null -ne $PriorEttMinutes) { [double]$PriorEttMinutes } else { $null }
        $seconds = $heldSeconds
        $gear = $heldGear
        $why = $Reason
        # A keep path must not hold a gear FASTER than the last measured ETT
        # implies. It only ever loosens here - a stale ETT is not evidence for
        # polling faster - and `near` keeps its own hysteresis.
        if ($null -ne $ett -and $Phase -ne 'near') {
            $implied = & $ladderFor $ett
            if ($implied -gt $seconds) {
                $seconds = [int]$implied
                $gear = Get-KeyCheckCadenceLabel $seconds
                $why = "$Reason/ett-held"
            }
        }
        [pscustomobject]@{
            Seconds       = $seconds
            Gear          = $gear
            Reason        = $why
            BurnPerMinute = $Burn
            EttMinutes    = $ett
            Remaining     = $Remaining
            LoosenStreak  = $Streak
            FloorTick     = $false
        }
    }

    # A measured outcome: the gear the ladder (or the flat-window rule) chose.
    $result = {
        param([int]$Seconds, [string]$Reason, [int]$Streak, [bool]$OnFloor)
        [pscustomobject]@{
            Seconds        = $Seconds
            Gear           = (Get-KeyCheckCadenceLabel $Seconds)
            Reason         = $Reason
            BurnPerMinute  = $bindingBurn
            EttMinutes     = $bindingEtt
            Remaining      = $remaining
            LoosenStreak   = $Streak
            FloorTick      = $OnFloor
        }
    }

    if ($null -eq $Current) { return (& $keep 'no-reading' $null $null $null) }

    # --- remaining: only meters that are actually reported count -------------
    # Clamped per meter: a CROSSED trigger leaves ZERO headroom, never a negative
    # one. Before this, a reading at 97 wk produced remaining -1 and ETT -8.1 min,
    # which the ladder read as "infinitely urgent" on a key that had just been
    # replaced (cl-common-8yq).
    $remainingCandidates = @()
    $weeklyNow = Get-KeyCheckPercent $Current.Weekly
    $monthlyNow = Get-KeyCheckPercent $Current.Monthly
    if ($null -ne $weeklyNow) { $remainingCandidates += [Math]::Max(0.0, ($script:KeyCheckWeeklyImminent - $weeklyNow)) }
    if ($null -ne $monthlyNow) { $remainingCandidates += [Math]::Max(0.0, ($script:KeyCheckMonthlyImminent - $monthlyNow)) }
    if ($remainingCandidates.Count -eq 0) { return (& $keep 'meter-not-reported' $null $null $null) }
    $remaining = ($remainingCandidates | Measure-Object -Minimum).Minimum

    # --- history -------------------------------------------------------------
    # The burn window comes from a HISTORY, not from "the previous poll". Once
    # the ladder tightens to a 5-minute (or 1-minute) gear, consecutive polls
    # are CLOSER than the 15-minute guard, so a previous-poll pair could never
    # measure burn: ETT stayed null for the rest of the run and the gear froze -
    # it could neither tighten toward the trigger nor loosen when the burn
    # stopped (cl-common-6yr).
    $guard = [double]$script:KeyCheckCadenceMinimumSampleMinutes
    $window = $null
    $ring = @($Samples | Where-Object { $null -ne $_ })
    # The caller appends THIS tick to the ring before deriving the gear, so the
    # newest entry is the current sample and everything before it is history.
    # One entry means one sample: no burn, no ETT, previous gear.
    if ($ring.Count -ge 2) {
        $history = @($ring[0..($ring.Count - 2)])
        $candidates = @()
        foreach ($entry in $history) {
            $at = ConvertTo-KeyCheckResetTime -Text $entry.at
            if ($null -eq $at) { continue }
            $age = ($Now - $at).TotalMinutes
            if ($age -le 0) { continue }
            $candidates += [pscustomobject]@{
                Age = $age
                Wk  = ConvertTo-KeyCheckCadenceSamplePercent $entry.wk
                Mo  = ConvertTo-KeyCheckCadenceSamplePercent $entry.mo
            }
        }
        if ($candidates.Count -gt 0) {
            # The OLDEST sample at least the guard window old measures the most
            # stable burn; if the history is younger, the oldest we have still
            # says something - it is just labelled `window-short`.
            $eligible = @($candidates | Where-Object { $_.Age -ge ($guard - 0.0001) })
            $reason = 'window-15m'
            if ($eligible.Count -eq 0) { $eligible = $candidates; $reason = 'window-short' }
            $reference = ($eligible | Sort-Object Age -Descending | Select-Object -First 1)
            $window = [pscustomobject]@{
                Minutes = [double]$reference.Age
                Wk      = $reference.Wk
                Mo      = $reference.Mo
                Reason  = $reason
            }
        }
    }
    if ($null -eq $window) {
        # A resumed/legacy run carries only `lastReading` + `lastCheckAt`; treat
        # that pair as a one-entry history so the same rules apply to it - but
        # only while it is the SAME key: after a rescue the persisted reading
        # belongs to the exhausted key, and a delta across keys is not a burn.
        $sameKey = ($null -ne $Previous -and $null -ne $Current -and
            (-not $Previous.PSObject.Properties['KeyNumber'] -or -not $Current.PSObject.Properties['KeyNumber'] -or
                [int]$Previous.KeyNumber -eq [int]$Current.KeyNumber))
        if (-not $sameKey) { return (& $keep 'first-sample' $null $null $remaining) }
        $since = ConvertTo-KeyCheckResetTime -Text $LastCheckAt
        if ($null -eq $since) { return (& $keep 'first-sample' $null $null $remaining) }
        $elapsedMinutes = ($Now - $since).TotalMinutes
        if ($elapsedMinutes -le 0) { return (& $keep 'clock-non-monotonic' $null $null $remaining) }
        $window = [pscustomobject]@{
            Minutes = $elapsedMinutes
            Wk      = (Get-KeyCheckPercent $Previous.Weekly)
            Mo      = (Get-KeyCheckPercent $Previous.Monthly)
            Reason  = $(if ($elapsedMinutes -ge ($guard - 0.0001)) { 'window-15m' } else { 'window-short' })
        }
    }
    $windowMinutes = [double]$window.Minutes
    $windowTag = [string]$window.Reason
    $windowed = { param([string]$Name) "$Name/$windowTag" }
    $since = $Now.AddMinutes(-1 * $windowMinutes)

    # --- per-meter burn, reset-aware ----------------------------------------
    $meters = @(
        [pscustomobject]@{
            Cap      = [double]$script:KeyCheckWeeklyImminent
            Was      = (ConvertTo-KeyCheckCadenceSamplePercent $window.Wk)
            Now      = $weeklyNow
            ResetsAt = $(if ($null -ne $Current.Weekly) { $Current.Weekly.ResetsAt } else { $null })
        }
        [pscustomobject]@{
            Cap      = [double]$script:KeyCheckMonthlyImminent
            Was      = (ConvertTo-KeyCheckCadenceSamplePercent $window.Mo)
            Now      = $monthlyNow
            ResetsAt = $(if ($null -ne $Current.Monthly) { $Current.Monthly.ResetsAt } else { $null })
        }
    )
    $compared = 0
    $moved = $false
    $resetCrossed = $false
    $bindingBurn = $null
    $bindingEtt = $null

    foreach ($meter in $meters) {
        if ($null -eq $meter.Now -or $null -eq $meter.Was) { continue }
        $nowPercent = $meter.Now
        $wasPercent = $meter.Was
        $compared++

        # A window that reset BETWEEN the two samples (or a meter that went
        # backwards) invalidates the delta: it measures a new window, not burn.
        $resetAt = ConvertTo-KeyCheckResetTime -Text $meter.ResetsAt
        $crossed = ($null -ne $resetAt -and $resetAt -gt $since -and $resetAt -le $Now)
        $delta = $nowPercent - $wasPercent
        if ($crossed -or $delta -lt 0) { $resetCrossed = $true; continue }
        if ($delta -eq 0) { continue }

        $moved = $true
        $burn = $delta / $windowMinutes          # percentage points per MINUTE
        if ($burn -le 0) { continue }
        $meterRemaining = [Math]::Max(0.0, ($meter.Cap - $nowPercent))
        $meterEtt = $meterRemaining / $burn      # minutes to that meter's trigger, never < 0
        if ($null -eq $bindingEtt -or $meterEtt -lt $bindingEtt) {
            $bindingEtt = $meterEtt
            $bindingBurn = $burn
        }
    }

    if ($resetCrossed) { return (& $keep 'window-reset' $null $null $remaining) }
    if ($compared -eq 0) { return (& $keep 'no-burn-history' $null $null $remaining) }
    if (-not $moved) {
        # A flat window is a MEASURED "the trigger is not approaching". It may
        # loosen, but never on one reading and never past the base gear: the
        # two-tick rule below owns the transition.
        if ($base -le $heldSeconds) { return (& $keep (& $windowed 'no-change') $null $null $remaining) }
        $flatStreak = $LoosenStreak + 1
        if ($flatStreak -ge $script:KeyCheckCadenceBetterTicks) {
            return (& $result $base (& $windowed 'loosened') 0 $false)
        }
        return (& $keep (& $windowed 'loosen-pending') $null $null $remaining $flatStreak)
    }
    if ($null -eq $bindingEtt) { return (& $keep (& $windowed 'no-burn') $null $null $remaining) }

    # --- the ladder (minutes in, SECONDS out) --------------------------------
    $candidate = & $ladderFor $bindingEtt
    $floorTick = ($candidate -le $minimum)

    # A stuck reading must not spin at a minute: after the cap, hold at 5 min.
    # The cap is not a "loosening", so it takes effect immediately.
    if ($floorTick -and $FloorTicks -ge $FloorCap) {
        $holdSeconds = [Math]::Min($script:KeyCheckCadenceFloorHoldSeconds, $base)
        if ($holdSeconds -le $minimum) { return (& $keep (& $windowed 'cadence-floor-cap') $bindingBurn $bindingEtt $remaining) }
        return (& $result $holdSeconds (& $windowed 'cadence-floor-cap') 0 $false)
    }

    # `heartbeat` RE-DERIVES from ETT on every tick, in both directions: the phase
    # already promises "a quiet key is checked hourly", so a measured ETT of hours
    # must reach the top gear on the same tick that measured it. Keeping the fast
    # gear for a two-tick "loosen-pending" wait is what turned one rescue into 60x
    # the intended reads (cl-common-8yq).
    if ($Phase -ne 'near') {
        $why = if ($candidate -lt $heldSeconds) { 'tightened' }
               elseif ($candidate -gt $heldSeconds) { 'loosened' }
               else { 'gear-unchanged' }
        return (& $result $candidate (& $windowed $why) 0 $floorTick)
    }

    # `near` keeps the anti-flap hysteresis: a key inside the escalation band is
    # watched closely, and one quiet reading must not stretch it to its ceiling.
    if ($candidate -lt $heldSeconds) { return (& $result $candidate (& $windowed 'tightened') 0 $floorTick) }
    if ($candidate -eq $heldSeconds) {
        # Already at the right gear: nothing is pending.
        return (& $result $candidate (& $windowed 'gear-unchanged') 0 $floorTick)
    }
    $streak = $LoosenStreak + 1
    if ($streak -ge $script:KeyCheckCadenceBetterTicks) { return (& $result $candidate (& $windowed 'loosened') 0 $floorTick) }
    return (& $result $heldSeconds (& $windowed 'loosen-pending') $streak $floorTick)
}

function Get-KeyCheckExclusionReason {
    <#
    .SYNOPSIS
        Why a reading cannot be a rescue target - '' when it can.
    .DESCRIPTION
        The ONE place the eligibility rule is expressed; Test-KeyCheckEligible
        is a thin wrapper over it, so "is this key eligible?" and "why not?"
        can never diverge. The reason is reported verbatim, so an operator sees
        the rule that excluded each candidate instead of a bare "none".

        A key at 0 wk / 100 mo is NOT eligible (GO5 on 2026-11-02): the weekly
        slice is irrelevant when the term is spent. An unreported meter is not
        eligible either - an unknown allowance is never a safe target.
    .PARAMETER ExcludeKeyNumber
        The active key. 0 disables the active-key exclusion (plain eligibility).
    #>
    param($Reading, [int]$ExcludeKeyNumber = 0)

    if ($null -eq $Reading) { return 'unreadable' }
    if ($ExcludeKeyNumber -gt 0 -and [int]$Reading.KeyNumber -eq $ExcludeKeyNumber) { return 'active-key' }

    # A row the reader answered but could not measure is a named
    # cannot-evaluate, never a silent ineligible - and the name must be the HTTP
    # fact, because "meter-not-reported" hides whether the key was rate-limited,
    # forbidden, or the endpoint broke. Reserved for a 200 whose meters are absent.
    $verdict = if ($Reading.PSObject.Properties['Verdict']) { [string]$Reading.Verdict } else { '' }
    $http = if ($Reading.PSObject.Properties['Http']) { [int]$Reading.Http } else { 200 }
    if ($verdict -eq 'ERROR' -or $http -eq 0) { return 'usage-ERROR' }
    if ($http -ne 200) {
        if ($http -eq 429) { return 'rate-limited' }
        if ($http -eq 401 -or $http -eq 403) { return 'usage-FORBIDDEN' }
        return "usage-HTTP$http"
    }
    if ($verdict -match '^(REVOKED|FORBIDDEN|UNKNOWN)$') { return "usage-$verdict" }

    $wk = $Reading.Weekly
    $mo = $Reading.Monthly
    if ($null -eq $wk -or $null -eq $mo) { return 'meter-not-reported' }

    $spent = @($wk.Status, $mo.Status) | Where-Object { $_ -eq 'rate-limited' }
    if ($spent) { return 'rate-limited' }

    if ($null -eq $wk.Percent -or $null -eq $mo.Percent) { return 'meter-not-reported' }
    if ($wk.Percent -ge $script:KeyCheckWeeklyIneligible) { return "weekly>=$($script:KeyCheckWeeklyIneligible)" }
    if ($mo.Percent -ge $script:KeyCheckMonthlyIneligible) { return "monthly>=$($script:KeyCheckMonthlyIneligible)" }
    return ''
}

function Test-KeyCheckEligible {
    <#
    .SYNOPSIS
        A rescue TARGET must be under both meters: weekly < 80 AND monthly < 90.
    .DESCRIPTION
        Thin wrapper over Get-KeyCheckExclusionReason so the rule lives once.
    #>
    param($Reading)

    if ($null -eq $Reading) { return $false }
    return ([string]::IsNullOrEmpty((Get-KeyCheckExclusionReason -Reading $Reading)))
}

function Test-KeyCheckNearExhaustion {
    <#
    .SYNOPSIS
        Heartbeat threshold: weekly >= 80 OR monthly >= 90.
    #>
    param($Reading)

    if ($null -eq $Reading) { return $false }
    $wk = Get-KeyCheckPercent $Reading.Weekly
    $mo = Get-KeyCheckPercent $Reading.Monthly
    if ($null -ne $wk -and $wk -ge $script:KeyCheckWeeklyIneligible) { return $true }
    if ($null -ne $mo -and $mo -ge $script:KeyCheckMonthlyIneligible) { return $true }
    return $false
}

function Test-KeyCheckImminent {
    <#
    .SYNOPSIS
        Trigger threshold: weekly > 96 OR monthly > 98 OR any meter rate-limited.
    #>
    param($Reading)

    if ($null -eq $Reading) { return $false }
    $wk = Get-KeyCheckPercent $Reading.Weekly
    $mo = Get-KeyCheckPercent $Reading.Monthly
    if ($null -ne $wk -and $wk -gt $script:KeyCheckWeeklyImminent) { return $true }
    if ($null -ne $mo -and $mo -gt $script:KeyCheckMonthlyImminent) { return $true }
    foreach ($w in @($Reading.Weekly, $Reading.Monthly)) {
        if ($null -ne $w -and $w.Status -eq 'rate-limited') { return $true }
    }
    return $false
}

function Get-KeyCheckMonthlyResetTicks {
    <#
    .SYNOPSIS
        Sortable monthly reset instant; unreported/unparsable sorts last.
    .DESCRIPTION
        The weekly window is ALWAYS aligned to one shared Sunday boundary, so it
        carries no ranking information. Only the monthly term resets on each
        key's own anniversary, which is what makes one target last longer.
    #>
    param($Reading)

    if ($null -eq $Reading -or $null -eq $Reading.Monthly) { return [long]::MaxValue }
    $text = [string]$Reading.Monthly.ResetsAt
    if ([string]::IsNullOrWhiteSpace($text)) { return [long]::MaxValue }
    $parsed = ConvertTo-KeyCheckResetTime -Text $text
    if ($null -ne $parsed) { return $parsed.Ticks }
    return [long]::MaxValue
}

function Get-KeyCheckCandidateReport {
    <#
    .SYNOPSIS
        Every candidate with its verdict: the eligible ranked, and the rest with
        the rule that excluded them.
    .DESCRIPTION
        Discovery reports from this one structure, so it can never say "no
        eligible replacement" without naming, per key, which rule applied. The
        ranking is unchanged: soonest monthly reset, then the lowest key number.
    .PARAMETER Readings
        All observed readings (normally every pool key).
    .PARAMETER ExcludeKeyNumber
        The active key, excluded so a rescue never "moves" onto itself.
    #>
    param([object[]]$Readings, [int]$ExcludeKeyNumber = 0)

    $eligible = @()
    $rejected = @()
    foreach ($reading in @($Readings)) {
        if ($null -eq $reading) {
            $rejected += [pscustomobject]@{ KeyNumber = 0; Label = '?'; Rule = 'unreadable' }
            continue
        }
        $rule = Get-KeyCheckExclusionReason -Reading $reading -ExcludeKeyNumber $ExcludeKeyNumber
        if ($rule) {
            $rejected += [pscustomobject]@{ KeyNumber = [int]$reading.KeyNumber; Label = [string]$reading.Label; Rule = $rule }
        } else {
            $eligible += $reading
        }
    }

    $ranked = if ($eligible.Count -eq 0) { @() } else {
        @($eligible | Sort-Object -Property `
                @{ Expression = { Get-KeyCheckMonthlyResetTicks -Reading $_ } }, `
                @{ Expression = { $_.KeyNumber } })
    }

    return [pscustomobject]@{ Eligible = @($ranked); Rejected = @($rejected) }
}

function Get-KeyCheckCandidates {
    <#
    .SYNOPSIS
        Every eligible target, ranked by soonest monthly reset then lowest key
        number. Empty when nothing is eligible.
    .PARAMETER Readings
        All observed readings (normally every pool key).
    .PARAMETER ExcludeKeyNumber
        The active key, excluded so a rescue never "moves" onto itself.
    #>
    param([object[]]$Readings, [int]$ExcludeKeyNumber = 0)

    $report = Get-KeyCheckCandidateReport -Readings $Readings -ExcludeKeyNumber $ExcludeKeyNumber
    return @($report.Eligible)
}

function Get-KeyCheckReplacement {
    <#
    .SYNOPSIS
        The best eligible target: soonest monthly reset, ties by lowest number.
    #>
    param([object[]]$Readings, [int]$ExcludeKeyNumber = 0)

    $ranked = @(Get-KeyCheckCandidates -Readings $Readings -ExcludeKeyNumber $ExcludeKeyNumber)
    if ($ranked.Count -eq 0) { return $null }
    return $ranked[0]
}

function Get-KeyCheckNextPhase {
    <#
    .SYNOPSIS
        The single state transition: given the phase, the clock and a reading,
        return the next phase and why.
    .DESCRIPTION
        Ordering is fixed: the deadline ends the run first; then imminent
        (-> discover, or trigger when a replacement is already armed); then
        the disarm band (near -> heartbeat); then near-exhaustion
        (heartbeat -> discover); otherwise stay put.

        `initial` is the only phase allowed to enter `heartbeat`/`discover`
        directly. No transition creates or moves a deadline.

        Two tolerances live here, not in the caller:
          - a RATE-LIMITED read triggers only on the second consecutive one
            (ConsecutiveRateLimited), while a percentage over 96/98 triggers
            immediately;
          - `near` disarms to `heartbeat` after two consecutive readings inside
            the disarm band (weekly < 70 AND monthly < 80).
    .PARAMETER ConsecutiveRateLimited
        How many checks in a row (including this reading) were rate-limited.
    .PARAMETER ConsecutiveBelowThreshold
        How many checks in a row (including this reading) were inside the
        disarm band.
    #>
    param(
        [ValidateSet('initial', 'heartbeat', 'discover', 'near', 'trigger', 'end')]
        [string]$Phase,
        [datetime]$Now,
        [datetime]$Deadline,
        $Reading = $null,
        [int]$ReplacementKeyNumber = 0,
        [int]$ConsecutiveRateLimited = 0,
        [int]$ConsecutiveBelowThreshold = 0
    )

    if ($Now -ge $Deadline) { return [pscustomobject]@{ Phase = 'end'; Reason = 'deadline' } }

    if ($null -eq $Reading) {
        $stay = if ($Phase -in @('near', 'trigger')) { 'near' } else { 'heartbeat' }
        return [pscustomobject]@{ Phase = $stay; Reason = 'no-reading' }
    }

    $imminent = Test-KeyCheckImminent -Reading $Reading
    $percentImminent = Test-KeyCheckPercentImminent -Reading $Reading
    $rateLimited = Test-KeyCheckRateLimited -Reading $Reading
    $nearExhaustion = Test-KeyCheckNearExhaustion -Reading $Reading

    switch ($Phase) {
        'initial' {
            if ($imminent) { return [pscustomobject]@{ Phase = 'discover'; Reason = 'imminent' } }
            if ($nearExhaustion) { return [pscustomobject]@{ Phase = 'discover'; Reason = 'near-exhaustion' } }
            return [pscustomobject]@{ Phase = 'heartbeat'; Reason = 'healthy' }
        }
        'heartbeat' {
            if ($imminent) { return [pscustomobject]@{ Phase = 'discover'; Reason = 'imminent' } }
            if ($nearExhaustion) { return [pscustomobject]@{ Phase = 'discover'; Reason = 'near-exhaustion' } }
            return [pscustomobject]@{ Phase = 'heartbeat'; Reason = 'healthy' }
        }
        'discover' {
            return [pscustomobject]@{ Phase = 'near'; Reason = 'replacement-armed' }
        }
        'near' {
            # A percentage over the cap is the key dying: act now. A 429 is
            # evidence of pressure, not of death, so one is tolerated.
            $triggerNow = $percentImminent -or ($rateLimited -and $ConsecutiveRateLimited -ge $script:KeyCheckRateLimitTriggerStreak)
            if ($triggerNow) {
                $why = if ($percentImminent) { 'imminent' } else { "rate-limited-x$ConsecutiveRateLimited" }
                if ($ReplacementKeyNumber -gt 0) {
                    return [pscustomobject]@{ Phase = 'trigger'; Reason = $why }
                }
                return [pscustomobject]@{ Phase = 'discover'; Reason = 'no-replacement' }
            }
            if ($ConsecutiveBelowThreshold -ge $script:KeyCheckDisarmConsecutive) {
                return [pscustomobject]@{ Phase = 'heartbeat'; Reason = 'disarmed' }
            }
            return [pscustomobject]@{ Phase = 'near'; Reason = 'watching' }
        }
        'trigger' {
            return [pscustomobject]@{ Phase = 'near'; Reason = 'rescue-complete' }
        }
    }
    return [pscustomobject]@{ Phase = 'end'; Reason = 'unknown-phase' }
}

function Get-KeyCheckTriggerDecision {
    <#
    .SYNOPSIS
        Rescue is idempotent: active == replacement means no cutover, no churn.
    #>
    param([int]$ActiveKeyNumber, [int]$ReplacementKeyNumber)

    if ($ReplacementKeyNumber -le 0) {
        return [pscustomobject]@{ Action = 'none'; Reason = 'no-replacement' }
    }
    if ($ActiveKeyNumber -eq $ReplacementKeyNumber) {
        return [pscustomobject]@{ Action = 'none'; Reason = 'already-active' }
    }
    return [pscustomobject]@{ Action = 'cutover'; Reason = 'imminent' }
}

function Update-KeyCheckAfterCutover {
    <#
    .SYNOPSIS
        Post-rescue bookkeeping on a COPY of the run state.
    .DESCRIPTION
        Returns a new state: the exhausted key's final reading recorded, the new
        active key set, the replacement cleared, generation incremented, and the
        deadline copied VERBATIM (a rescue never extends or resets the run).

        A rescue is also a NEW METER, so the cadence is reset here, in the same
        write that records the cutover:
          - the sample ring and its reset-window signature are discarded (no delta
            may ever be measured across keys);
          - the gear goes back to the POST-CUTOVER PHASE CEILING (a verified rescue
            continues in `near`: 900 s) - never the 1-minute gear the exhausted key
            had earned (cl-common-8yq);
          - burn/ETT are cleared (they described the old key), and the per-key
            counters (loosen streak, 1-minute tick budget) restart;
          - `cadenceSampleGeneration` is deliberately LEFT on the old generation so
            the first tick on the new key reports the generation reset and audits
            it, instead of silently keeping a gear nobody can trace.
        The reset is recorded in `cadenceChanges[]` and in `evidence`, so a
        reviewer sees why the gear moved without waiting for the next tick.
    .PARAMETER PostCutoverPhase
        The phase the run continues in after a verified rescue (`near`).
    #>
    param(
        $State,
        [int]$FromKeyNumber,
        [int]$ToKeyNumber,
        $Reading = $null,
        [string]$PostCutoverPhase = 'near',
        [datetime]$Now = (Get-Date)
    )

    $clone = $State | ConvertTo-Json -Depth 16 | ConvertFrom-Json
    $clone | Add-Member -NotePropertyName generation -NotePropertyValue ([int]$State.generation + 1) -Force
    $clone | Add-Member -NotePropertyName activeKeyNumber -NotePropertyValue $ToKeyNumber -Force
    $clone | Add-Member -NotePropertyName replacementKeyNumber -NotePropertyValue 0 -Force
    $clone | Add-Member -NotePropertyName replacementKey -NotePropertyValue 0 -Force
    $clone | Add-Member -NotePropertyName lastReading -NotePropertyValue $Reading -Force
    # A rescue clears every tolerance counter: the new key starts with a clean
    # slate, and a stale cannot-evaluate streak must not end the fresh watch.
    $clone | Add-Member -NotePropertyName consecutiveRateLimited -NotePropertyValue 0 -Force
    $clone | Add-Member -NotePropertyName consecutiveBelowThreshold -NotePropertyValue 0 -Force
    $clone | Add-Member -NotePropertyName consecutiveCannotEvaluate -NotePropertyValue 0 -Force
    $clone | Add-Member -NotePropertyName armed -NotePropertyValue $false -Force
    # A different key has a different meter: no burn delta may be measured
    # across the cutover, so the sample ring starts empty.
    $clone | Add-Member -NotePropertyName cadenceSamples -NotePropertyValue @() -Force
    $clone | Add-Member -NotePropertyName cadenceSampleSignature -NotePropertyValue '' -Force

    # The gear belongs to the key that earned it. Reset to the phase ceiling.
    $previousSeconds = if ($clone.PSObject.Properties['cadenceSeconds']) { [int]$clone.cadenceSeconds } else { 0 }
    $ceiling = [int](Get-KeyCheckCadenceSeconds -Phase $PostCutoverPhase -CadenceSeconds $script:KeyCheckHeartbeatCeilingSeconds)
    $resetReason = "generation-reset/phase-$PostCutoverPhase-ceiling"
    $clone | Add-Member -NotePropertyName cadenceSeconds -NotePropertyValue $ceiling -Force
    $clone | Add-Member -NotePropertyName cadenceGear -NotePropertyValue (Get-KeyCheckCadenceLabel $ceiling) -Force
    $clone | Add-Member -NotePropertyName cadenceReason -NotePropertyValue $resetReason -Force
    $clone | Add-Member -NotePropertyName burnPerMinute -NotePropertyValue $null -Force
    $clone | Add-Member -NotePropertyName ettMinutes -NotePropertyValue $null -Force
    $clone | Add-Member -NotePropertyName cadenceLoosenStreak -NotePropertyValue 0 -Force
    $clone | Add-Member -NotePropertyName cadenceFloorTicks -NotePropertyValue 0 -Force
    # Same unroll trap as Update-KeyCheckCadence: @() wraps the whole if-expression,
    # otherwise a state holding one prior change yields a scalar and += throws.
    $changes = @(if ($clone.PSObject.Properties['cadenceChanges']) { $clone.cadenceChanges | Where-Object { $null -ne $_ } })
    $changes += @([pscustomobject]@{
            at        = $Now.ToString('o')
            from      = $previousSeconds
            to        = $ceiling
            reason    = $resetReason
            burnPerMinute = $null
            ettMinutes    = $null
            remaining     = $null
        })
    $clone | Add-Member -NotePropertyName cadenceChanges -NotePropertyValue @($changes) -Force

    $kept = @($clone.evidence | Where-Object { $_ })
    $frames = if ($null -ne $Reading) {
        $wk = if ($null -ne $Reading.Weekly.Percent) { "$([int]$Reading.Weekly.Percent)wk" } else { '?wk' }
        $mo = if ($null -ne $Reading.Monthly.Percent) { "$([int]$Reading.Monthly.Percent)mo" } else { '?mo' }
        " final reading GO$FromKeyNumber $wk/$mo"
    } else { '' }
    $clone | Add-Member -NotePropertyName evidence -NotePropertyValue (@($kept) + @(
        "generation $($clone.generation): cadence reset ${previousSeconds}s -> ${ceiling}s ($resetReason); burn and ETT cleared with the old key"
        "generation $($clone.generation): cutover GO$FromKeyNumber -> GO$ToKeyNumber$frames (deadline unchanged: $($State.deadline))"
    )) -Force
    return $clone
}

function Update-KeyCheckActiveKeyState {
    <#
    .SYNOPSIS
        Make the persisted active key follow the LIVE in-use key (cl-common-o1t).
    .DESCRIPTION
        Resolution is a MEASUREMENT of the machine, not a memory of the previous
        run. After an operator moved the fleet from GO3 to GO1, the resumed watch
        kept `activeKeyNumber = 3`, audited `resumed: resumed-cutover-verified
        GO3 -> GO3` against a seam that says GO1, and measured GO3's meters - the
        one component whose job is to see was blind, and a real GO1 cap would
        never have triggered a cutover. So EVERY start hashes the live in-use
        value against the pool and reconciles the state with the answer here.

        When the live key differs from the state's active key:
          - generation + 1 (a different key is a different rescue generation);
          - activeKeyNumber = the live key;
          - the armed replacement is dropped (it was ranked for the old key);
          - the last reading, the sample ring and the burn/ETT derived from them
            are discarded - they describe a key this run no longer watches - and
            the gear returns to the current phase ceiling;
          - every tolerance counter is zeroed: a 429 or disarm streak measured on
            the old key must not fire (or disarm) anything on the new one.

        Moves nothing when the live key is unknown (0) - an absent measurement is
        never a change - or when there was no previous key to change from (0:
        a fresh run records its active key in `initial`).
    .PARAMETER State
        The live run state. Read only: a changed state is returned as a copy.
    .PARAMETER LiveKeyNumber
        The pool key number the in-use value resolved to (0 = unresolved).
    .PARAMETER How
        How the resolution was made (`hash-match (User)`, `seam-activeKey`, ...).
    .PARAMETER Phase
        Phase whose ceiling the reset gear takes. Defaults to the state's phase.
    .OUTPUTS
        Changed / FromKeyNumber / ToKeyNumber / Generation / Reason / State.
    #>
    param(
        $State,
        [int]$LiveKeyNumber = 0,
        [string]$How = '',
        [string]$Phase = '',
        [datetime]$Now = (Get-Date)
    )

    $from = if ($null -ne $State -and $State.PSObject.Properties['activeKeyNumber']) { [int]$State.activeKeyNumber } else { 0 }
    $generation = if ($null -ne $State -and $State.PSObject.Properties['generation']) { [int]$State.generation } else { 0 }
    $unchanged = [pscustomobject]@{
        Changed = $false; FromKeyNumber = $from; ToKeyNumber = $LiveKeyNumber
        Generation = $generation; Reason = ''; State = $State
    }
    if ($null -eq $State) { return $unchanged }
    if ($LiveKeyNumber -le 0 -or $from -le 0 -or $LiveKeyNumber -eq $from) { return $unchanged }

    $targetPhase = if ($Phase) { $Phase }
                   elseif ($State.PSObject.Properties['phase'] -and $State.phase) { [string]$State.phase }
                   else { 'heartbeat' }
    if ($targetPhase -notin @('heartbeat', 'near')) { $targetPhase = 'heartbeat' }

    $clone = $State | ConvertTo-Json -Depth 16 | ConvertFrom-Json
    $generation += 1
    $reason = "active-key-changed GO$from -> GO$LiveKeyNumber"

    $clone | Add-Member -NotePropertyName generation -NotePropertyValue $generation -Force
    $clone | Add-Member -NotePropertyName activeKeyNumber -NotePropertyValue $LiveKeyNumber -Force
    $clone | Add-Member -NotePropertyName replacementKeyNumber -NotePropertyValue 0 -Force
    $clone | Add-Member -NotePropertyName replacementKey -NotePropertyValue 0 -Force
    # The meters read for the old key are not this key's meters.
    $clone | Add-Member -NotePropertyName lastReading -NotePropertyValue $null -Force
    $clone | Add-Member -NotePropertyName consecutiveRateLimited -NotePropertyValue 0 -Force
    $clone | Add-Member -NotePropertyName consecutiveCannotEvaluate -NotePropertyValue 0 -Force
    $clone | Add-Member -NotePropertyName consecutiveBelowThreshold -NotePropertyValue 0 -Force
    $clone | Add-Member -NotePropertyName armed -NotePropertyValue $false -Force
    # Same doctrine as a cutover: no burn delta may ever be measured across keys.
    $clone | Add-Member -NotePropertyName cadenceSamples -NotePropertyValue @() -Force
    $clone | Add-Member -NotePropertyName cadenceSampleSignature -NotePropertyValue '' -Force
    $clone | Add-Member -NotePropertyName burnPerMinute -NotePropertyValue $null -Force
    $clone | Add-Member -NotePropertyName ettMinutes -NotePropertyValue $null -Force
    $clone | Add-Member -NotePropertyName sampleAt -NotePropertyValue $null -Force
    $clone | Add-Member -NotePropertyName cadenceLoosenStreak -NotePropertyValue 0 -Force
    $clone | Add-Member -NotePropertyName cadenceFloorTicks -NotePropertyValue 0 -Force
    # `cadenceSampleGeneration` is left on the OLD generation on purpose, so the
    # first tick on the new key reports the generation reset and audits it.
    $previousSeconds = if ($clone.PSObject.Properties['cadenceSeconds']) { [int]$clone.cadenceSeconds } else { 0 }
    $ceiling = [int](Get-KeyCheckCadenceSeconds -Phase $targetPhase -CadenceSeconds $script:KeyCheckHeartbeatCeilingSeconds)
    $resetReason = "active-key-changed/phase-$targetPhase-ceiling"
    $clone | Add-Member -NotePropertyName cadenceSeconds -NotePropertyValue $ceiling -Force
    $clone | Add-Member -NotePropertyName cadenceGear -NotePropertyValue (Get-KeyCheckCadenceLabel $ceiling) -Force
    $clone | Add-Member -NotePropertyName cadenceReason -NotePropertyValue $resetReason -Force

    # @() wraps the whole if-expression: a state holding ONE prior change would
    # otherwise yield a scalar and += would throw (same trap as the cutover path).
    $changes = @(if ($clone.PSObject.Properties['cadenceChanges']) { $clone.cadenceChanges | Where-Object { $null -ne $_ } })
    $changes += @([pscustomobject]@{
            at            = $Now.ToString('o')
            from          = $previousSeconds
            to            = $ceiling
            reason        = $resetReason
            burnPerMinute = $null
            ettMinutes    = $null
            remaining     = $null
        })
    $clone | Add-Member -NotePropertyName cadenceChanges -NotePropertyValue @($changes) -Force

    $kept = @($clone.evidence | Where-Object { $_ })
    $via = if ($How) { " (resolved via $How)" } else { '' }
    $clone | Add-Member -NotePropertyName evidence -NotePropertyValue (@($kept) + @(
        "generation ${generation}: $reason$via; sample ring, meters and gear discarded with the old key"
    )) -Force

    return [pscustomobject]@{
        Changed = $true; FromKeyNumber = $from; ToKeyNumber = $LiveKeyNumber
        Generation = $generation; Reason = $reason; State = $clone
    }
}

function Format-KeyCheckReading {
    <#
    .SYNOPSIS
        One-line, value-free reading. Meters abbreviate wk (weekly) and mo
        (monthly) - never "w"/"m", because "m" already means minutes here.
    #>
    param($Reading, [string]$Tag = '')

    if ($null -eq $Reading) { return 'no reading' }
    $wk = if ($null -ne $Reading.Weekly.Percent) { "$([int]$Reading.Weekly.Percent)wk" } else { '?wk' }
    $mo = if ($null -ne $Reading.Monthly.Percent) { "$([int]$Reading.Monthly.Percent)mo" } else { '?mo' }
    $verdict = if (Test-KeyCheckImminent -Reading $Reading) { 'imminent' }
               elseif (Test-KeyCheckNearExhaustion -Reading $Reading) { 'near-cap' }
               else { 'healthy' }
    $suffix = if ($Tag) { " ($Tag)" } else { '' }
    return "$($Reading.Label)$suffix $wk/$mo - $verdict"
}


# ------------------------------------------------------------- successor ---
# A deadline-bounded run that merely EXITS leaves the active key unwatched until
# a human (or a Hub tick that happens to look) notices. Measured 2026-11-03: run
# 20261102-235920 ended at its 8 h deadline at 14:59:20Z and the key was
# unwatched for ~9 minutes until the next Hub tick started a fresh run
# (cl-common-0ai). So the run ARMS ONE successor before it ends, and a standing
# supervisor asserts liveness with the SAME decision below - one rule for
# "should something be watching right now", never two.
$script:KeyCheckSuccessorGraceSeconds = 30

function Test-KeyCheckShouldArmSuccessor {
    <#
    .SYNOPSIS
        True when THIS run's ending must leave a successor behind.
    .DESCRIPTION
        Only a DEADLINE ending arms. A failed rescue (4/5), a broken meter (1) or
        an empty candidate field (3) is a machine state a fresh watch must not
        paper over: the next run would inherit the same fault and the audit trail
        would show a healthy-looking chain over a broken machine.

        -DryRun is a rehearsal and -NoWait is a test seam, so neither arms a
        process; -NoSuccessor is the operator's deliberate opt-out (a bounded
        window, a maintenance host).
    #>
    param(
        [string]$EndReason,
        [switch]$DryRun,
        [switch]$NoWait,
        [switch]$NoSuccessor
    )

    if ($DryRun -or $NoWait -or $NoSuccessor) { return $false }
    return ($EndReason -eq 'deadline')
}

function Get-KeyCheckSuccessorDelaySeconds {
    <#
    .SYNOPSIS
        How long the armed successor waits before its first check.
    .DESCRIPTION
        Parent deadline plus a grace beat, floored at zero: the parent needs a
        moment to write its terminal state and release the lock, and a successor
        that fires a second early would meet a live lock and skip - a silently
        unarmed gap of exactly the kind this exists to remove.
    #>
    param(
        [Parameter(Mandatory)][datetime]$Deadline,
        [datetime]$Now = (Get-Date),
        [double]$GraceSeconds = $script:KeyCheckSuccessorGraceSeconds
    )

    $remaining = [Math]::Max(0, ($Deadline - $Now).TotalSeconds)
    $grace = [Math]::Max(0, $GraceSeconds)
    return [int][Math]::Ceiling($remaining + $grace)
}

function Get-KeyCheckSuccessorDecision {
    <#
    .SYNOPSIS
        Should this process start a watch, or is something already watching?
    .DESCRIPTION
        ONE rule, consumed by the armed successor and by the standing supervisor.

          skip  locked-by-run   a LIVE lock is the only liveness signal. A second
                                watcher would read the same meters and could cut
                                over twice, so it must not start (cl-common-0ai
                                acceptance 3).
          start no-state        no run state exists: nothing has ever watched.
          start run-ended       the state says the run ENDED (`phase = end`, an
                                `endReason`, or an `endedAt`) - the lapse this
                                bead is about.
          start run-not-live    the state says a run is IN FLIGHT but no live lock
                                exists: that run is unfinished, not finished, so
                                the start RESUMES it on its ORIGINAL deadline.

        `Action = 'skip'` never means "healthy" - it names what is holding the
        machine, and a reader that mistakes it for health loses the gap again.
    #>
    param(
        $State,
        $Lock = $null,
        [datetime]$Now = (Get-Date)
    )

    $holderRunId = ''
    $lockLive = $false
    if ($null -ne $Lock) {
        $exists = ($Lock.PSObject.Properties['Exists'] -and [bool]$Lock.Exists)
        $stale = ($Lock.PSObject.Properties['Stale'] -and [bool]$Lock.Stale)
        $lockLive = ($exists -and -not $stale)
        if ($Lock.PSObject.Properties['Lock'] -and $null -ne $Lock.Lock -and
            $Lock.Lock.PSObject.Properties['runId']) {
            $holderRunId = [string]$Lock.Lock.runId
        }
    }

    # Read the state's own facts once, so every verdict carries the same
    # description of WHAT it judged (a report without the runId and the deadline
    # cannot be checked by a reader).
    $runId = ''
    $phase = ''
    $endReason = ''
    $endedAt = ''
    $deadline = $null
    if ($null -ne $State) {
        $runId = if ($State.PSObject.Properties['runId']) { [string]$State.runId } else { '' }
        $phase = if ($State.PSObject.Properties['phase']) { [string]$State.phase } else { '' }
        $endReason = if ($State.PSObject.Properties['endReason']) { [string]$State.endReason } else { '' }
        $endedAt = if ($State.PSObject.Properties['endedAt'] -and $State.endedAt) { [string]$State.endedAt } else { '' }
        $deadlineText = if ($State.PSObject.Properties['deadlineAt'] -and $State.deadlineAt) { $State.deadlineAt }
                        elseif ($State.PSObject.Properties['deadline']) { $State.deadline } else { '' }
        $deadline = ConvertTo-KeyCheckResetTime -Text $deadlineText
    }

    if ($lockLive) {
        return [pscustomobject]@{
            Action = 'skip'; Reason = 'locked-by-run'
            Detail = "a live run holds the lock$(if ($holderRunId) { " (run $holderRunId)" })"
            HolderRunId = $holderRunId; RunId = $runId; Phase = $phase; EndReason = $endReason; DeadlineAt = $deadline
        }
    }

    if ($null -eq $State) {
        return [pscustomobject]@{
            Action = 'start'; Reason = 'no-state'
            Detail = 'no run state exists; nothing is watching'
            HolderRunId = ''; RunId = ''; Phase = ''; EndReason = ''; DeadlineAt = $null
        }
    }

    $terminal = ($phase -eq 'end') -or (-not [string]::IsNullOrWhiteSpace($endReason)) -or
                (-not [string]::IsNullOrWhiteSpace($endedAt))
    if ($terminal) {
        $why = if ($endReason) { $endReason } elseif ($endedAt) { 'endedAt' } else { 'end-phase' }
        return [pscustomobject]@{
            Action = 'start'; Reason = 'run-ended'
            Detail = "run $runId ended ($why); nothing is watching"
            HolderRunId = ''; RunId = $runId; Phase = $phase; EndReason = $why; DeadlineAt = $deadline
        }
    }

    return [pscustomobject]@{
        Action = 'start'; Reason = 'run-not-live'
        Detail = "run $runId is at phase $phase with no live lock; the start resumes it on its original deadline"
        HolderRunId = ''; RunId = $runId; Phase = $phase; EndReason = ''; DeadlineAt = $deadline
    }
}
