#Requires -Version 7.0
<#
.SYNOPSIS
    Print (or emit as JSON) the opencode-go key freshness ledger from the seam.

.DESCRIPTION
    Read-only view of the opencode-go freshness ledger: per-key state, tripped
    meter, operator-reported utilisation, reset date and the evidence date, plus
    the per-meter detail (weekly / monthly) each with its OWN reading date.

    The tracked seam (`assets/opencode-go-cutover.json`) is CONFIG only -
    activeKey, poolOrder, caps and the metering `windows`. The per-key
    observations live in the profile state root
    (`$HOME/.salmon/State/credential-rescue/seam-observations.json`), written by
    Set-OpencodeGoFreshness.ps1 and Key Check runs, so a watch cycle never
    modifies a tracked or vendored file. A machine with no observations yet
    reads an empty ledger and still resolves the config's active key.

    The weekly and monthly meters refresh independently, so each meter carries its
    own observedAt; row-level observedAt is the newest evidence for the key. A meter
    whose reading is older than -StaleDays is marked STALE so nobody acts on a
    figure that was true a fortnight ago.

    -Probe additionally runs Test-GoKey.ps1 per key (standalone CLI inference; spends
    a few tokens and takes ~30-60s per key) and reports the LIVE verdict beside the
    recorded one. The ledger is the record; the probe is the truth right now - when
    they disagree, the probe wins and the ledger should be updated.

.PARAMETER Probe
    Also canary every key and print the live verdict.

.PARAMETER KeyNumber
    Restrict -Probe (and the table) to one pool key index.

.PARAMETER Json
    Emit machine-readable JSON instead of the table. Use this from an agent/coding
    loop: it carries the same fields plus computed ageDays / stale per meter.

.PARAMETER StaleDays
    Age in days past which a meter reading is marked STALE. Default 7. 0 disables.

.PARAMETER SeamPath
    Test seam: the cutover CONFIG seam to read. Default
    ../assets/opencode-go-cutover.json. Point it at a temp copy in tests; this
    script never writes.

.PARAMETER ObservationsPath
    The runtime observations file to read. Default: the seam's declared
    `observationsPath`, else beside a non-canonical seam, else
    $HOME/.salmon/State/credential-rescue/seam-observations.json.

.EXAMPLE
    pwsh -File Get-OpencodeGoFreshness.ps1
    pwsh -File Get-OpencodeGoFreshness.ps1 -Probe -KeyNumber 4
    pwsh -File Get-OpencodeGoFreshness.ps1 -Json | ConvertFrom-Json
#>
[CmdletBinding()]
param(
    [switch]$Probe,
    [int]$KeyNumber = 0,
    [switch]$Json,
    [int]$StaleDays = 7,
    [string]$SeamPath,
    [string]$ObservationsPath
)

$ErrorActionPreference = 'Stop'

# Ledger date seam: never parse or format a ledger date with the ambient
# culture, and never present an ambiguous value as a confident date.
. (Join-Path $PSScriptRoot 'lib\LedgerDate.ps1')
# Config/observation split: config from the tracked seam, observations from the
# profile state root.
. (Join-Path $PSScriptRoot 'lib\CutoverSeam.ps1')

$seamPath = Resolve-CutoverSeamPath $SeamPath
if (-not (Test-Path -LiteralPath $seamPath)) { throw "seam not found: $seamPath" }
$seam = Get-Content -LiteralPath $seamPath -Raw | ConvertFrom-Json
$observationsPath = Get-CutoverObservationsPath -SeamPath $seamPath -Seam $seam -ObservationsPath $ObservationsPath
$ledger = Get-CutoverLedger -Seam $seam -ObservationsPath $observationsPath

$testScript = Join-Path $PSScriptRoot 'Test-GoKey.ps1'
$today = (Get-Date).Date

function Get-LedgerDateView {
    <#
    .SYNOPSIS
        One ledger date as a view: normalised ISO, raw text, and whether it can
        be evaluated at all.
    .DESCRIPTION
        `ok` and `empty` are evaluable. `ambiguous` (a locale shape whose day
        and month order cannot be determined) and `unparseable` are NOT: the
        caller surfaces cannot-evaluate for that key instead of a confident
        wrong date. The raw text is always carried so the operator can see what
        the file actually holds.
    #>
    param($Text)

    $state = Resolve-LedgerDateText -Text $Text
    $raw = if ($state.Raw) { $state.Raw } elseif ($null -ne $Text) { [string]$Text } else { '' }
    return [pscustomobject]@{
        Status         = $state.Status
        Value          = $state.Value
        Iso            = $state.Iso
        Raw            = $raw
        CannotEvaluate = ($state.Status -in @('ambiguous', 'unparseable'))
    }
}

function Get-AgeDays($dateText) {
    $state = Get-LedgerDateView $dateText
    if ($state.Status -ne 'ok') { return $null }
    return [int][math]::Floor(($today - $state.Value.Date).TotalDays)
}

# Derive the NEXT roll-over from a recorded resetsOn, so the answer survives that
# date passing. An ambiguous/unparseable value has no next roll-over to claim.
#   intervalDays > 0  -> a fixed-length cycle (weekly): roll forward in whole cycles.
#   intervalDays = 0  -> a term anniversary (monthly): the next occurrence of the
#                        key's day-of-month, clamped for short months (a 31st anchor
#                        lands on the 30th/28th rather than rolling into the next month).
function Get-NextRollover($resetsOnText, [int] $intervalDays = 0) {
    $state = Get-LedgerDateView $resetsOnText
    if ($state.Status -ne 'ok') { return $null }
    $recorded = $state.Value
    $now = Get-Date

    if ($intervalDays -gt 0) {
        $next = $recorded
        while ($next -le $now) { $next = $next.AddDays($intervalDays) }
        return [pscustomobject]@{
            anchorDay     = $null
            anchorWeekday = $recorded.DayOfWeek.ToString()
            anchorTime    = $recorded.ToString('HH:mm')
            on            = $next.ToString('yyyy-MM-ddTHH:mm')
        }
    }

    $anchorDay = $recorded.Day
    $mk = {
        param($y, $mo)
        [datetime]::new($y, $mo, [math]::Min($anchorDay, [datetime]::DaysInMonth($y, $mo)))
    }
    $candidate = & $mk $now.Year $now.Month
    if ($candidate -le $now) {
        $next = $now.AddMonths(1)
        $candidate = & $mk $next.Year $next.Month
    }
    return [pscustomobject]@{
        anchorDay     = $anchorDay
        anchorWeekday = $null
        anchorTime    = $null
        on            = $candidate.ToString('yyyy-MM-dd')
    }
}

$rows = foreach ($entry in $ledger.keys.PSObject.Properties) {    $name = $entry.Name
    if ($KeyNumber -gt 0 -and $name -ne "OPENCODE_GO${KeyNumber}_KEY") { continue }

    $row = $entry.Value
    $meters = [ordered]@{}
    $anyStale = $false
    $anyCannotEvaluate = $false
    foreach ($m in @('weekly', 'monthly')) {
        $meter = if ($row.meters) { $row.meters.$m } else { $null }
        if (-not $meter) { continue }
        $age = Get-AgeDays $meter.observedAt
        # An unreported meter (used = null) is 'unreported', not stale - there is nothing to refresh.
        $stale = ($meter.used -ne $null) -and ($StaleDays -gt 0) -and ($null -ne $age) -and ($age -gt $StaleDays)
        if ($stale) { $anyStale = $true }

        # the window (cycle) this meter lives in, from freshness.windows
        $win = if ($ledger.windows) { $ledger.windows.$m } else { $null }
        $windowComment = if ($win -and $win.kind -eq 'aligned' -and $win.boundary) {
            '{0} aligned ({1} {2})' -f $win.label, $win.boundary.weekday, $win.boundary.time
        } elseif ($win) {
            $win.label
        } else { $m }
        $cycleText = if ($win) {
            $shape = if ($win.kind -eq 'aligned' -and $win.boundary) {
                '{0} aligned to {1} {2}' -f $win.lengthDays, $win.boundary.weekday, $win.boundary.time
            } elseif ($win.lengthHours) { '{0}h rolling' -f $win.lengthHours }
            elseif ($win.lengthDays) { '{0}d rolling' -f $win.lengthDays }
            else { 'anniversary' }
            '{0} ({1}, {2}% of monthly)' -f $win.label, $shape, $win.percentOfMonthly
        } else { $null }

        $renewsIn = $null
        $rolled = $false
        $resetView = Get-LedgerDateView $meter.resetsOn
        if ($resetView.Status -eq 'ok') {
            if ($resetView.Value -lt (Get-Date)) { $rolled = $true }
            else { $renewsIn = [math]::Round(($resetView.Value - (Get-Date)).TotalDays, 1) }
        }

        # monthly is a term anniversary and weekly is a fixed 7-day cycle: both can
        # name their NEXT roll-over from the recorded instant, even after it passed.
        $intervalDays = if ($m -eq 'weekly') { 7 } else { 0 }
        $nextRoll = Get-NextRollover $meter.resetsOn $intervalDays
        $observedView = Get-LedgerDateView $meter.observedAt
        $observedIso = if ($observedView.Status -eq 'ok') { $observedView.Value.ToString('yyyy-MM-dd', [cultureinfo]::InvariantCulture) } else { $null }
        $meterCannotEvaluate = $resetView.CannotEvaluate -or $observedView.CannotEvaluate

        $meters[$m] = [ordered]@{
            label         = if ($win) { $windowComment } else { $m }
            cycle         = $cycleText
            cycleKind     = if ($win) { $win.kind } else { $null }
            lengthDays    = if ($win) { $win.lengthDays } else { $null }
            lengthHours   = if ($win) { $win.lengthHours } else { $null }
            percentOfMonthly = if ($win) { $win.percentOfMonthly } else { $null }
            used          = $meter.used
            of            = $meter.of
            resetsOn      = if ($resetView.Status -eq 'ok') { $resetView.Iso } else { $null }
            resetsOnRaw   = $resetView.Raw
            resetsOnStatus = $resetView.Status
            anchorDay     = if ($nextRoll) { $nextRoll.anchorDay } else { $null }
            anchorWeekday = if ($nextRoll) { $nextRoll.anchorWeekday } else { $null }
            anchorTime    = if ($nextRoll) { $nextRoll.anchorTime } else { $null }
            nextRollover  = if ($nextRoll) { $nextRoll.on } else { $null }
            renewsInDays  = $renewsIn
            rolledOver    = $rolled
            observedAt    = $observedIso
            observedAtRaw = $observedView.Raw
            observedAtStatus = $observedView.Status
            cannotEvaluate = [bool]$meterCannotEvaluate
            ageDays       = $age
            stale         = [bool]$stale
        }
        if ($meterCannotEvaluate) { $anyCannotEvaluate = $true }
    }

    $live = $null
    if ($Probe -and (Test-Path -LiteralPath $testScript)) {
        $out = & pwsh -NoProfile -File $testScript -KeyNumber ([int]($name -replace '\D', '')) 2>&1 | Out-String
        $live = ($out -replace '\s+', ' ').Trim()
    }

    $rowResetView = Get-LedgerDateView $row.resetsOn
    $rowObservedView = Get-LedgerDateView $row.observedAt
    $rowCannotEvaluate = $anyCannotEvaluate -or $rowResetView.CannotEvaluate -or $rowObservedView.CannotEvaluate

    [pscustomobject]@{
        key           = $name
        active        = ($name -eq $seam.activeKey)
        state         = $row.state
        trippedMeter  = $row.trippedMeter
        usage         = $row.usage
        resetsOn      = if ($rowResetView.Status -eq 'ok') { $rowResetView.Iso } else { $null }
        resetsOnRaw   = $rowResetView.Raw
        resetsOnStatus = $rowResetView.Status
        observedAt    = if ($rowObservedView.Status -eq 'ok') { $rowObservedView.Value.ToString('yyyy-MM-dd', [cultureinfo]::InvariantCulture) } else { $null }
        observedAtRaw = $rowObservedView.Raw
        observedAtStatus = $rowObservedView.Status
        cannotEvaluate = [bool]$rowCannotEvaluate
        anyMeterStale = $anyStale
        evidence      = $row.evidence
        meters        = [pscustomobject]$meters
        live          = $live
    }
}

if ($Json) {
    [pscustomobject]@{
        asOf        = $ledger.asOf
        activeKey   = $seam.activeKey
        ledgerSource = $ledger.source
        observationsPath = $observationsPath
        staleDays   = $StaleDays
        generatedAt = (Get-Date).ToString('s')
        windows     = $ledger.windows
        keys        = @($rows)
    } | ConvertTo-Json -Depth 8
    return
}

Write-Output ("Key freshness ledger - asOf {0}, activeKey {1} (stale threshold {2}d, source {3})" -f ($ledger.asOf ?? 'never'), $seam.activeKey, $StaleDays, $ledger.source)
if ($ledger.source -eq 'none') {
    Write-Output ("No observations recorded yet at {0}. The active key still resolves from the tracked config; record a reading with Set-OpencodeGoFreshness.ps1." -f $observationsPath)
}
Write-Output ''

foreach ($row in $rows) {
    $usage = if ($row.usage) { "{0}/{1}" -f $row.usage.used, $row.usage.of } else { '-' }
    $flag = if ($row.active) { '*' } else { ' ' }
    $staleTag = if ($row.anyMeterStale) { ' STALE' } else { '' }
    $ceTag = if ($row.cannotEvaluate) { ' CANNOT-EVALUATE' } else { '' }
    $resetCell = if ($row.resetsOn) { $row.resetsOn }
                 elseif ($row.resetsOnStatus -in @('ambiguous', 'unparseable')) { '?-' + $row.resetsOnStatus }
                 else { '-' }
    Write-Output ("{0} {1,-18} state={2,-10} meter={3,-8} usage={4,-8} resets={5,-12} updated={6}{7}{8}" -f `
        $flag, $row.key, $row.state, ($row.trippedMeter ?? '-'), $usage, $resetCell, ($row.observedAt ?? '-'), $staleTag, $ceTag)

    $parts = foreach ($m in $row.meters.PSObject.Properties) {
        $u = if ($m.Value.used -ne $null) { "{0}%" -f $m.Value.used } else { '?' }
        $age = if ($null -ne $m.Value.ageDays) { "{0}d" -f $m.Value.ageDays } else { '-' }
        $sfx = if ($m.Value.stale) { ' STALE' } else { '' }
        $resetText = if ($m.Value.resetsOn) { $m.Value.resetsOn }
                     elseif ($m.Value.resetsOnStatus -in @('ambiguous', 'unparseable')) { '?-' + $m.Value.resetsOnStatus }
                     else { '-' }
        $renews = if ($m.Value.cannotEvaluate) { 'CANNOT-EVALUATE' }
                  elseif ($m.Value.rolledOver) { 'ROLLED OVER' }
                  elseif ($null -ne $m.Value.renewsInDays) { "in {0}d" -f $m.Value.renewsInDays }
                  else { '-' }
        $next = if ($m.Value.nextRollover) {
            if ($m.Value.anchorWeekday) { " | next {0} ({1} {2})" -f $m.Value.nextRollover, $m.Value.anchorWeekday, $m.Value.anchorTime }
            else { " | next {0} (day {1})" -f $m.Value.nextRollover, $m.Value.anchorDay }
        } else { '' }
        "{0}: {1} of {2} | cycle {3} | resets {4} ({5}){6} | read {7} ({8}){9}" -f `
            $m.Name, $u, $m.Value.of, ($m.Value.cycle ?? '?'), $resetText, $renews, $next, ($m.Value.observedAt ?? 'never'), $age, $sfx
    }
    if ($parts) { Write-Output ("      meters: {0}" -f (($parts | ForEach-Object { $_ }) -join '  ||  ')) }

    if ($row.live) { Write-Output ("      live: {0}" -f $row.live) }
}

Write-Output ''
Write-Output '* = activeKey. Ledger rows are recorded state; -Probe reports live truth (probe wins on disagreement).'
Write-Output 'STALE = that meter''s reading is older than the threshold; ask the operator to read it again in the Console.'
Write-Output 'ROLLED OVER = the recorded resetsOn already passed, so that figure predates a roll-over - re-read it.'
Write-Output 'CANNOT-EVALUATE = the recorded date is ambiguous (reads as two different days per culture) or unparseable; it is not ranked and not trusted - re-record it in ISO (yyyy-MM-ddTHH:mm).'
if ($ledger.windows) {
    $winText = foreach ($w in $ledger.windows.PSObject.Properties) {
        if ($w.Name -like '$*') { continue }
        $len = if ($w.Value.kind -eq 'aligned' -and $w.Value.boundary) { '{0}d @ {1} {2}' -f $w.Value.lengthDays, $w.Value.boundary.weekday, $w.Value.boundary.time }
               elseif ($w.Value.lengthHours) { "$($w.Value.lengthHours)h" }
               elseif ($w.Value.lengthDays) { "$($w.Value.lengthDays)d" }
               else { 'anniversary' }
        $trk = if ($w.Value.tracked) { 'tracked' } else { 'not tracked (live probe only)' }
        "{0} = {1} / {2}% of monthly / {3}" -f $w.Name, $len, $w.Value.percentOfMonthly, $trk
    }
    Write-Output ("windows: {0}" -f (($winText | ForEach-Object { $_ }) -join '  |  '))
}
