# Ledger date seam for Skills/credential-rescue.
# Dot-source this file; do NOT duplicate the format/parse rules per script.
#
# THE RULE (cl-common-n42): a date that reaches the freshness observations
# (the seam's observationsPath, `seam-observations.json` in the profile state
# root) is written as round-trip ISO with invariant formatting, never through
# [datetime].ToString() with the ambient culture. `11/09/2026` is 9 November
# under en-US and 11 September under en-GB, and the reset instant is exactly
# what the eligibility ranking and the ETT arithmetic compare - so an ambiguous
# value silently picks the wrong key.
#
# Producers call ConvertTo-LedgerIsoText (strict: refuses ambiguity).
# Readers call Resolve-LedgerDateText (lenient: reports ambiguous or
# unparseable so a caller can surface cannot-evaluate instead of a confident
# wrong date).

$script:LedgerDateIsoFormats = @(
    'yyyy-MM-ddTHH:mm:ss.FFFFFFFzzz'
    'yyyy-MM-ddTHH:mm:sszzz'
    'yyyy-MM-ddTHH:mm:ss.FFFFFFFZ'
    'yyyy-MM-ddTHH:mm:ssZ'
    'yyyy-MM-ddTHH:mm:ss.FFFFFFF'
    'yyyy-MM-ddTHH:mm:ss'
    'yyyy-MM-ddTHH:mm'
    'yyyy-MM-dd HH:mm:ss'
    'yyyy-MM-dd HH:mm'
    'yyyy-MM-dd'
)

# The locale-shaped shapes a producer may have emitted. Both day/month orders
# are listed so an ambiguous value can be DETECTED (both parse, different
# dates) rather than silently resolved by the machine's culture.
$script:LedgerDateMonthFirstFormats = @(
    'M/d/yyyy H:mm:ss'
    'M/d/yyyy h:mm:ss tt'
    'M/d/yyyy H:mm'
    'M/d/yyyy h:mm tt'
    'M/d/yyyy'
)

$script:LedgerDateDayFirstFormats = @(
    'd/M/yyyy H:mm:ss'
    'd/M/yyyy h:mm:ss tt'
    'd/M/yyyy H:mm'
    'd/M/yyyy h:mm tt'
    'd/M/yyyy'
)

function Get-LedgerParsedExact {
    param([string]$Value, [string[]]$Formats)

    foreach ($format in $Formats) {
        $parsed = [datetime]::MinValue
        $ok = [datetime]::TryParseExact(
            $Value,
            $format,
            [cultureinfo]::InvariantCulture,
            ([System.Globalization.DateTimeStyles]::AllowWhiteSpaces -bor [System.Globalization.DateTimeStyles]::RoundtripKind),
            [ref]$parsed)
        # 0001-01-01 is the JSON null-date default, not a real reading.
        if ($ok -and $parsed.Year -gt 1) { return $parsed }
    }
    return $null
}

function Resolve-LedgerDateText {
    <#
    .SYNOPSIS
        Classify a ledger date value without ever guessing its culture.
    .DESCRIPTION
        Returns { Status, Iso, Value, Raw, Kind } where Status is

          ok         - a real instant; Iso is the normalised round-trip form
          empty      - null/whitespace (not an error: the field was not reported)
          ambiguous  - a locale shape both d/M and M/d read as a date, to
                       DIFFERENT days; the only honest answer is cannot-evaluate
          unparseable- no known shape matches

        A [datetime] / [datetimeoffset] is accepted as-is (the JSON reader
        re-types ISO timestamps), and its clock is preserved - no timezone
        shifting, so a recorded instant never moves a day.
    #>
    param($Text)

    $state = [pscustomobject]@{
        Status = 'empty'
        Iso    = $null
        Value  = $null
        Raw    = ''
        Kind   = 'none'
    }

    if ($null -eq $Text) { return $state }

    if ($Text -is [datetime]) {
        $date = [datetime]$Text
        if ($date.Year -le 1) { $state.Status = 'unparseable'; return $state }
        $state.Status = 'ok'
        $state.Value = $date
        $state.Iso = $date.ToString('yyyy-MM-ddTHH:mm:ss', [cultureinfo]::InvariantCulture)
        $state.Kind = 'datetime'
        return $state
    }

    if ($Text -is [datetimeoffset]) {
        $offset = [datetimeoffset]$Text
        $state.Status = 'ok'
        $state.Value = $offset.DateTime
        $state.Iso = $offset.ToString('yyyy-MM-ddTHH:mm:ss', [cultureinfo]::InvariantCulture)
        $state.Kind = 'datetimeoffset'
        return $state
    }

    $raw = [string]$Text
    $state.Raw = $raw
    $value = $raw.Trim()
    if ([string]::IsNullOrWhiteSpace($value)) { return $state }

    $iso = Get-LedgerParsedExact -Value $value -Formats $script:LedgerDateIsoFormats
    if ($iso) {
        $state.Status = 'ok'
        $state.Value = $iso
        $state.Iso = $iso.ToString('yyyy-MM-ddTHH:mm:ss', [cultureinfo]::InvariantCulture)
        $state.Kind = 'iso'
        return $state
    }

    $monthFirst = Get-LedgerParsedExact -Value $value -Formats $script:LedgerDateMonthFirstFormats
    $dayFirst = Get-LedgerParsedExact -Value $value -Formats $script:LedgerDateDayFirstFormats

    if ($monthFirst -and $dayFirst -and $monthFirst.Date -ne $dayFirst.Date) {
        $state.Status = 'ambiguous'
        $state.Kind = 'locale'
        return $state
    }

    $picked = if ($monthFirst) { $monthFirst } elseif ($dayFirst) { $dayFirst } else { $null }
    if (-not $picked) {
        $state.Status = 'unparseable'
        $state.Kind = 'locale'
        return $state
    }

    # Unambiguous locale shape: exactly one order is a valid date, so it can be
    # normalised deterministically (e.g. 11/23/2026 -> 2026-11-23).
    $state.Status = 'ok'
    $state.Value = $picked
    $state.Iso = $picked.ToString('yyyy-MM-ddTHH:mm:ss', [cultureinfo]::InvariantCulture)
    $state.Kind = 'locale'
    return $state
}

function ConvertTo-LedgerIsoText {
    <#
    .SYNOPSIS
        Format a ledger date value as round-trip ISO, or refuse it.
    .DESCRIPTION
        The writer's contract: an ambiguous or unparseable value throws, so it
        can never be persisted (a KeyCheck run then reports the failed ledger
        write instead of recording a date that reads differently per culture).
    .PARAMETER Kind
        Instant -> yyyy-MM-ddTHH:mm:ss. Date -> yyyy-MM-dd (observedAt).
    #>
    param(
        $Text,
        [ValidateSet('Instant', 'Date')][string]$Kind = 'Instant',
        [string]$Field = 'date'
    )

    $state = Resolve-LedgerDateText -Text $Text
    switch ($state.Status) {
        'ok' {
            if ($Kind -eq 'Date') {
                return $state.Value.ToString('yyyy-MM-dd', [cultureinfo]::InvariantCulture)
            }
            return $state.Value.ToString('yyyy-MM-ddTHH:mm:ss', [cultureinfo]::InvariantCulture)
        }
        'empty' { return '' }
        'ambiguous' {
            throw ("{0} '{1}' is ambiguous - its day and month order cannot be determined (it reads as two different dates in different cultures). Refusing to write it; pass ISO, e.g. yyyy-MM-ddTHH:mm." -f $Field, $state.Raw)
        }
        default {
            throw ("{0} '{1}' is not a recognised date shape. Refusing to write it; pass ISO, e.g. yyyy-MM-ddTHH:mm." -f $Field, $state.Raw)
        }
    }
}
