#Requires -Version 7.0
<#
.SYNOPSIS
    Record a per-key meter reading in the opencode-go freshness ledger.

.DESCRIPTION
    The write side of Get-OpencodeGoFreshness.ps1. Updates the RUNTIME
    observations for ONE pool key, stamping the reading per meter (weekly /
    monthly each carry their own observedAt, because the two meters are read at
    different times and refresh independently), then recomputes the row summary
    (state / trippedMeter / usage / resetsOn / observedAt) and the ledger asOf.

    Observations never touch the tracked seam. `assets/opencode-go-cutover.json`
    is committed config (activeKey, poolOrder, caps, windows) and is also a
    vendored manifest row, so a watch cycle must not modify it. The ledger is
    written to the profile state root instead:

        $HOME/.machine/state/credential-rescue/seam-observations.json

    (see scripts/lib/CutoverSeam.ps1 for the resolution order). A first write
    imports any legacy `freshness.keys` still embedded in the seam, so no
    recorded reading is lost during the split.

    Only the meters you actually pass are touched - an omitted meter keeps its
    previous figures and reading date, so recording a weekly reading never
    silently re-dates a monthly one. Pass -WeeklyUsed/-WeeklyResets or
    -MonthlyUsed/-MonthlyResets to update that meter; -Unknown marks a meter as
    not reported (used = null).

    Never stores a key value. Read it back with Get-OpencodeGoFreshness.ps1.

.PARAMETER KeyNumber
    Pool key index, e.g. 4 for OPENCODE_GO4_KEY.

.PARAMETER State
    fresh | exhausted | unknown. Omit to derive it from the meters.

.PARAMETER TrippedMeter
    weekly | monthly. Omit to derive it (the meter at 100%) when exhausted.

.PARAMETER WeeklyUsed
    Weekly utilisation percentage 0-100 (the rolling 7-day pool cap = 50% of the
    monthly allowance).

.PARAMETER WeeklyResets
    Weekly roll-over instant, e.g. '2026-11-01T17:00'.

.PARAMETER MonthlyUsed
    Monthly utilisation percentage 0-100 (the account-term cap).

.PARAMETER MonthlyResets
    Monthly roll-over date, e.g. '2026-11-13'.

.PARAMETER Unknown
    Meter(s) to mark as not reported: 'weekly', 'monthly' or 'both'.

.PARAMETER ObservedAt
    Date of this reading. Defaults to today.

.PARAMETER SeamPath
    The cutover CONFIG seam that supplies `freshness.windows`. Default
    ../assets/opencode-go-cutover.json. It is only read - never written - so a
    temp copy is safe in tests.

.PARAMETER ObservationsPath
    The runtime observations file to write. Default: the seam's declared
    `observationsPath`, else beside a non-canonical seam, else
    $HOME/.machine/state/credential-rescue/seam-observations.json.

.PARAMETER Evidence
    Free text of what was observed and how (probe, operator Console reading).

.PARAMETER Log
    Also append the update to Tasks/Logs/credential-changes.jsonl when that file's
    directory exists. Default on; -NoLog disables.

.EXAMPLE
    pwsh -File Set-OpencodeGoFreshness.ps1 -KeyNumber 4 -MonthlyUsed 73 -MonthlyResets 2026-11-13 `
        -WeeklyUsed 40 -WeeklyResets 2026-11-01T17:00 -Evidence 'operator Console read 2026-10-31'

.EXAMPLE
    pwsh -File Set-OpencodeGoFreshness.ps1 -KeyNumber 2 -State exhausted -TrippedMeter monthly `
        -MonthlyUsed 100 -MonthlyResets 2026-11-10 -Evidence '429 limitName=monthly direct probe'
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][int]$KeyNumber,
    [ValidateSet('fresh', 'exhausted', 'unknown')][string]$State,
    [ValidateSet('weekly', 'monthly')][string]$TrippedMeter,
    [ValidateRange(0, 100)][int]$WeeklyUsed = -1,
    [string]$WeeklyResets,
    [ValidateRange(0, 100)][int]$MonthlyUsed = -1,
    [string]$MonthlyResets,
    [ValidateSet('weekly', 'monthly', 'both')][string]$Unknown,
    [string]$ObservedAt = (Get-Date).ToString('yyyy-MM-dd'),
    [string]$SeamPath,
    [string]$ObservationsPath,
    [string]$Evidence,
    [switch]$NoLog
)

$ErrorActionPreference = 'Stop'

# Ledger date seam: one invariant formatter/parser shared with the producer and
# the read view. Never format a ledger date with the ambient culture.
. (Join-Path $PSScriptRoot 'lib\LedgerDate.ps1')
# Config/observation split: the seam is committed config, the ledger is runtime
# state in the profile state root.
. (Join-Path $PSScriptRoot 'lib\CutoverSeam.ps1')

$seamPath = Resolve-CutoverSeamPath $SeamPath

# Normalise at the WRITER, before anything is stored: resetsOn is a round-trip
# instant, observedAt a round-trip date. An ambiguous value (e.g. 11/09/2026,
# which is 9 November in en-US and 11 September in en-GB) throws here rather
# than being persisted, so the ledger can never hold a date that reads two ways.
$ObservedAt = ConvertTo-LedgerIsoText -Text $ObservedAt -Kind Date -Field 'observedAt'
if ([string]::IsNullOrWhiteSpace($ObservedAt)) { throw 'observedAt is required' }
if ($WeeklyResets) { $WeeklyResets = ConvertTo-LedgerIsoText -Text $WeeklyResets -Kind Instant -Field 'weekly resetsOn' }
if ($MonthlyResets) { $MonthlyResets = ConvertTo-LedgerIsoText -Text $MonthlyResets -Kind Instant -Field 'monthly resetsOn' }
if (-not (Test-Path -LiteralPath $seamPath)) { throw "seam not found: $seamPath" }

$keyName = "OPENCODE_GO${KeyNumber}_KEY"
$seam = Get-Content -LiteralPath $seamPath -Raw | ConvertFrom-Json
$observationsPath = Get-CutoverObservationsPath -SeamPath $seamPath -Seam $seam -ObservationsPath $ObservationsPath
$observations = Read-CutoverObservations -Path $observationsPath

# Start from the observations file. A legacy seam that still embeds
# `freshness.keys` is imported on this first write, so the split loses no
# recorded reading.
if (-not $observations -or -not $observations.PSObject.Properties['keys'] -or -not $observations.keys) {
    $legacyLedger = $seam.freshness
    $legacyKeys = if ($legacyLedger -and $legacyLedger.PSObject.Properties['keys']) { $legacyLedger.keys } else { $null }
    $legacyAsOf = if ($legacyLedger -and $legacyLedger.PSObject.Properties['asOf']) { $legacyLedger.asOf } else { $null }
    $observations = [pscustomobject]@{
        version = 1
        note    = 'Runtime observations for the opencode-go cutover seam. Written by Set-OpencodeGoFreshness.ps1 (profile state root); never commit this file. Config lives in Skills/credential-rescue/assets/opencode-go-cutover.json.'
        asOf    = $legacyAsOf
        keys    = if ($legacyKeys) { $legacyKeys } else { [pscustomobject]@{} }
    }
}

$ledger = [pscustomobject]@{
    asOf    = $observations.asOf
    windows = if ($seam.freshness) { $seam.freshness.windows } else { $null }
    keys    = $observations.keys
}
if (-not $ledger.keys) {
    $ledger.keys = [pscustomobject]@{}
    $observations | Add-Member -NotePropertyName keys -NotePropertyValue $ledger.keys -Force
}
$row = $ledger.keys.$keyName
if (-not $row) {
    # A pool key that has never been read has no ledger row yet (a key just added
    # to the pool). Create it as unknown so its first reading can be recorded
    # instead of the write being refused.
    $row = [pscustomobject]@{
        state        = 'unknown'
        trippedMeter = $null
        usage        = $null
        resetsOn     = $null
        observedAt   = $null
        evidence     = $null
        meters       = [pscustomobject]@{
            weekly  = [pscustomobject]@{ used = $null; of = 100; resetsOn = $null; observedAt = $null }
            monthly = [pscustomobject]@{ used = $null; of = 100; resetsOn = $null; observedAt = $null }
        }
    }
    $ledger.keys | Add-Member -NotePropertyName $keyName -NotePropertyValue $row -Force
    Write-Output "created ledger row for $keyName (state unknown)"
}

# --- per-meter updates: only touch a meter when something was passed for it ---
$touchWeekly = ($WeeklyUsed -ge 0) -or $WeeklyResets -or ($Unknown -in @('weekly', 'both'))
$touchMonthly = ($MonthlyUsed -ge 0) -or $MonthlyResets -or ($Unknown -in @('monthly', 'both'))
if (-not $touchWeekly -and -not $touchMonthly -and -not $State) {
    throw 'nothing to record: pass a meter reading (-Weekly*/-Monthly*) and/or -State'
}

function Set-Meter($meter, [bool]$touch, [int]$used, [string]$resets, [bool]$markUnknown) {
    if (-not $touch) { return $meter }
    if ($markUnknown) {
        $meter.used = $null
        $meter.resetsOn = $null
        $meter.observedAt = $null
        return $meter
    }
    if ($used -ge 0) { $meter.used = $used }
    if ($resets) { $meter.resetsOn = $resets }
    $meter.observedAt = $ObservedAt
    return $meter
}

if (-not $row.meters) {
    $row | Add-Member -NotePropertyName meters -NotePropertyValue ([pscustomobject]@{}) -Force
}
foreach ($m in @('weekly', 'monthly')) {
    if (-not $row.meters.$m) {
        $row.meters | Add-Member -NotePropertyName $m -NotePropertyValue ([pscustomobject]@{ used = $null; of = 100; resetsOn = $null; observedAt = $null }) -Force
    }
}

$markWeeklyUnknown = $Unknown -in @('weekly', 'both')
$markMonthlyUnknown = $Unknown -in @('monthly', 'both')
$row.meters.weekly = Set-Meter $row.meters.weekly $touchWeekly $WeeklyUsed $WeeklyResets $markWeeklyUnknown
$row.meters.monthly = Set-Meter $row.meters.monthly $touchMonthly $MonthlyUsed $MonthlyResets $markMonthlyUnknown

# --- recompute the row summary ---
$reported = @($row.meters.PSObject.Properties | ForEach-Object { $_.Value } | Where-Object { $null -ne $_.used })
$fullest = $reported | Sort-Object -Property used -Descending | Select-Object -First 1
if ($fullest) {
    $row.usage = [pscustomobject]@{ used = $fullest.used; of = $fullest.of }
} elseif ($touchWeekly -or $touchMonthly) {
    $row.usage = $null
}

if ($State) {
    $row.state = $State
} else {
    $atCap = $reported | Where-Object { $null -ne $_.of -and $_.used -ge $_.of }
    $row.state = if ($atCap) { 'exhausted' } elseif ($reported) { 'fresh' } else { 'unknown' }
}

if ($TrippedMeter) {
    $row.trippedMeter = $TrippedMeter
} elseif ($row.state -eq 'exhausted') {
    $tripped = $row.meters.PSObject.Properties |
        Where-Object { $null -ne $_.Value.used -and $null -ne $_.Value.of -and $_.Value.used -ge $_.Value.of } |
        Select-Object -First 1
    $row.trippedMeter = if ($tripped) { $tripped.Name } else { $row.trippedMeter }
} else {
    $row.trippedMeter = $null
}

# resetsOn = the reset that actually FREES the key: when exhausted, the meter that
# tripped (a weekly reset does not unblock a monthly-capped key); otherwise the
# refresh of the BINDING meter - the one with the least remaining headroom, weighed
# in points of the monthly allowance (a weekly window is only percentOfMonthly of
# it). Soonest-by-date is wrong when a meter is nearly spent: a key at 99 % monthly
# is not helped by the weekly boundary just because that boundary comes first.
$resets = @($row.meters.PSObject.Properties | ForEach-Object { $_.Value.resetsOn } | Where-Object { $_ })
$trippedReset = if ($row.state -eq 'exhausted' -and $row.trippedMeter -and $row.meters.($row.trippedMeter)) {
    $row.meters.($row.trippedMeter).resetsOn
} else { $null }

function Get-WindowFactor([string] $meterName) {
    $window = $ledger.windows.$meterName
    if ($window -and $null -ne $window.percentOfMonthly -and $window.percentOfMonthly -gt 0) {
        return ([double]$window.percentOfMonthly) / 100
    }
    return 1
}

$binding = $null
if (-not $trippedReset) {
    $binding = @(
        $row.meters.PSObject.Properties |
            Where-Object { $_.Value.resetsOn -and $null -ne $_.Value.used -and $_.Value.of } |
            ForEach-Object {
                # Only a resolvable date can be ranked; an ambiguous/unparseable
                # one is skipped (the reader surfaces it as cannot-evaluate).
                $dateState = Resolve-LedgerDateText -Text $_.Value.resetsOn
                if ($dateState.Status -ne 'ok') { return }
                [pscustomobject]@{
                    text     = $dateState.Iso
                    when     = $dateState.Value
                    headroom = ([double]$_.Value.of - [double]$_.Value.used) * (Get-WindowFactor $_.Name)
                }
            } |
            Sort-Object -Property @{ Expression = 'headroom' }, @{ Expression = 'when' } |
            Select-Object -First 1
    ) | Select-Object -First 1
}

if ($trippedReset) {
    $row.resetsOn = $trippedReset
} elseif ($binding) {
    $row.resetsOn = $binding.text
} elseif ($resets.Count -gt 0) {
    $soonest = $resets |
        ForEach-Object {
            $dateState = Resolve-LedgerDateText -Text $_
            if ($dateState.Status -ne 'ok') { return }
            [pscustomobject]@{ text = $dateState.Iso; when = $dateState.Value }
        } |
        Sort-Object -Property when |
        Select-Object -First 1
    if ($soonest) { $row.resetsOn = $soonest.text }
}

$dates = @($row.meters.PSObject.Properties | ForEach-Object { $_.Value.observedAt } | Where-Object { $_ })
if ($dates.Count -gt 0) {
    $parsedDates = @($dates | ForEach-Object {
            $dateState = Resolve-LedgerDateText -Text $_
            if ($dateState.Status -eq 'ok') { $dateState.Value }
        })
    if ($parsedDates.Count -gt 0) {
        $row.observedAt = ($parsedDates | Sort-Object | Select-Object -Last 1).ToString('yyyy-MM-dd', [cultureinfo]::InvariantCulture)
    }
}
if ($Evidence) { $row.evidence = $Evidence }

# asOf dates the newest evidence. A ledger asOf that cannot be resolved is not
# a usable floor, so the new reading replaces it.
$asOfState = Resolve-LedgerDateText -Text $ledger.asOf
$observedState = Resolve-LedgerDateText -Text $ObservedAt
if ($asOfState.Status -ne 'ok' -or ($observedState.Status -eq 'ok' -and $asOfState.Value -lt $observedState.Value)) {
    $ledger.asOf = $ObservedAt
}

$observations.asOf = $ledger.asOf
$observations.keys = $ledger.keys

if ($PSCmdlet.ShouldProcess($observationsPath, "record $keyName freshness (state=$($row.state))")) {
    # One trailing newline, explicitly: a write with no final newline is noise in
    # every diff that touches the ledger.
    Write-CutoverObservations -Observations $observations -Path $observationsPath
    Write-Output ("recorded {0}: state={1} meter={2} usage={3}/{4} resets={5} updated={6} -> {7}" -f `
        $keyName, $row.state, ($row.trippedMeter ?? '-'),
        $(if ($row.usage) { $row.usage.used } else { '-' }), $(if ($row.usage) { $row.usage.of } else { '-' }),
        ($row.resetsOn ?? '-'), ($row.observedAt ?? '-'), $observationsPath)

    if (-not $NoLog) {
        $logDir = Join-Path $env:CL_REPOS_ROOT 'Tasks\Logs'
        if (Test-Path -LiteralPath $logDir) {
            $entry = [ordered]@{
                ts       = (Get-Date).ToString('s')
                kind     = 'freshness-update'
                key      = $keyName
                state    = $row.state
                meter    = $row.trippedMeter
                usage    = $row.usage
                resetsOn = $row.resetsOn
                observed = $row.observedAt
                source   = 'Set-OpencodeGoFreshness.ps1'
            }
            Add-Content -LiteralPath (Join-Path $logDir 'credential-changes.jsonl') -Value ($entry | ConvertTo-Json -Compress) -Encoding utf8NoBOM
        }
    }
}
