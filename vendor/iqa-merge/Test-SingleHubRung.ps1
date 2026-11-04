#Requires -Version 7
<#
.SYNOPSIS
    Single-rung guard - refuses a second ACTIVE MERGE-TICK schedule for one repo
    graph, and names both schedules when it does.

.DESCRIPTION
    Two Paseo schedules that both spawn a Hub tick for the same repo are two
    writers on one trunk. That was measured on 2026-11-03 (bead cl-common-3tv):
    main rung `b3fdf56a` and backstop `728ea6ac` both fired for `cl-common`;
    one tick verified a branch and dispatched a merge worker while the other
    tick landed the same branch, advanced `dev`, deleted the local branch and
    removed the worker's worktree admin entry - the worker was left running in
    an orphaned checkout against a deleted branch reference.

    Pausing the loser is the mitigation; this helper is the durable guard. It
    answers one question, read-only: is there more than one ACTIVE schedule
    that acts as a merge-tick rung for the same repo?

    A row is a MERGE-TICK rung when either:
      - its NAME starts with `hub-watch` (e.g. `hub-watch-cl-common`,
        `hub-watch-cl-common-backstop`), or
      - its PROMPT carries a `MERGE-TICK` or `HUB BACKSTOP` marker.
    Other schedules (nightly suites, CI check-backs, one-shot lane crons,
    an overnight hub tick named differently) are a different class and are
    deliberately NOT judged here - see REFERENCE.md `### One rung per repo`.

    Each rung is identified by the keys it carries:
      session:<guid>   every GUID in the prompt (the Hub session it addresses)
      repo:<name>      from `hub-<x>` tokens, `Repo root:`/`-RepoPath`/`-Repo`
                       arguments, `cwd =` inside the prompt, the schedule's
                       target cwd, or the `hub-watch-<repo>[-backstop]` name.

    Two LIVE rungs that share ANY key are a REFUSE. A rung is LIVE only while it
    can still fire: `status = active` AND not spent (`maxRuns` reached - the
    daemon's `runs` history has that many entries). A spent one-shot lane
    dispatch is not a writer any more, so counting it made one live rung plus one
    finished lane look like a duplicate (bead cl-common-5wy).

    A row that cannot fire is tolerated and named in the output, never counted:
    `paused` (a pause is reversible, so resuming it does create the second live
    rung again), `completed`/`expired` (history), and `active` with `maxRuns`
    reached (spent between the last fire and the daemon settling it).

    Exit codes
      0  PASS               at most one active rung per repo/session
      1  REFUSE             two or more active rungs share a repo or session;
                            both ids and crons are printed
      2  CANNOT-EVALUATE    the schedule source is unreadable, or an active
                            rung carries no identity key at all - an unevaluable
                            guard is never a pass
      3  NO-RUNG            no active rung for the requested repo; the Hub must
                            create exactly one (coverage defect, not a duplicate)

    Read-only by construction: it opens the Paseo schedule JSON files for
    reading and writes nothing. It never pauses, deletes, updates or creates a
    schedule. The only supported mutation is the Hub's own, after the refusal.

.PARAMETER Repo
    Repo to scope to: name or slug (`cl-common`, `currents-bookkeeping`, `cbk`,
    `upscale-havens`, `uh`). Omit to judge every repo the schedule store holds.

.PARAMETER SchedulesPath
    A schedule JSON file, or a directory of them. Defaults to
    `$env:PASEO_SCHEDULES_DIR` when set, else `<USERPROFILE>\.paseo\schedules`
    (the daemon's own store, read only).

.PARAMETER SchedulesJson
    The schedule list as inline JSON (an array, or `{ "schedules": [...] }` -
    the `paseo_list_schedules` shape). Mutually exclusive with the other two.

.PARAMETER Schedules
    The schedule list as objects already in memory. Mutually exclusive with the
    other two.

.PARAMETER Json
    Emit one JSON object instead of the report line.

.EXAMPLE
    pwsh -NoProfile -File <Skills>/iqa-merge/Test-SingleHubRung.ps1 -Repo cl-common

.EXAMPLE
    pwsh -NoProfile -File <Skills>/iqa-merge/Test-SingleHubRung.ps1 -Repo upscale-havens -Json
#>
[CmdletBinding()]
param(
    [string]$Repo = '',

    [string]$SchedulesPath,

    [string]$SchedulesJson,

    [AllowNull()]
    [object[]]$Schedules = $null,

    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Repo aliases: the same graph is named differently by a scheduler, a label and
# a checkout. One normalisation keeps the comparison honest.
$script:RepoAliases = @{
    'cl-common'            = 'cl-common'
    'common'               = 'cl-common'
    'currents-bookkeeping' = 'currents-bookkeeping'
    'cbk'                  = 'currents-bookkeeping'
    'upscale-havens'       = 'upscale-havens'
    'uh'                   = 'upscale-havens'
}

function ConvertTo-RepoName {
    <#
    .SYNOPSIS
        Normalise a repo path, slug, label name or schedule-name fragment to the
        one name the guard compares.
    #>
    param([AllowNull()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }

    $name = $Value.Trim().Trim('"', "'")
    # A path names the repository by its leaf, never by the lane it is in.
    if ($name -match '[\\/]' -or $name -match '^[A-Za-z]:') {
        $name = ($name -replace '[\\/]+$', '')
        $name = @($name -split '[\\/]' | Where-Object { $_ })[-1]
    }
    $name = $name -replace '\.git$', ''
    $name = $name -replace '^(?i)hub-', ''
    $name = $name -replace '(?i)-backstop$', ''
    $name = $name -replace '(?i)^watch-', ''
    $name = $name.ToLowerInvariant()

    if ([string]::IsNullOrWhiteSpace($name)) { return $null }
    if ($script:RepoAliases.ContainsKey($name)) { return $script:RepoAliases[$name] }
    return $name
}

function Get-ScheduleRowsFromPath {
    <#
    .SYNOPSIS
        Read the schedule rows from a JSON file or a directory of them.
        Unreadable input is a named error, never an empty list.
    #>
    param([Parameter(Mandatory)][string]$Path)

    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $text = Get-Content -LiteralPath $Path -Raw -Encoding utf8
        return @(ConvertFrom-ScheduleJson -Text $text -Source $Path)
    }

    if (Test-Path -LiteralPath $Path -PathType Container) {
        $files = @(Get-ChildItem -LiteralPath $Path -Filter '*.json' -File | Sort-Object Name)
        if ($files.Count -eq 0) {
            throw "The schedule directory '$Path' holds no *.json schedule records; rung uniqueness cannot be evaluated."
        }
        $rows = [System.Collections.Generic.List[object]]::new()
        foreach ($file in $files) {
            try {
                $text = Get-Content -LiteralPath $file.FullName -Raw -Encoding utf8
                foreach ($row in @(ConvertFrom-ScheduleJson -Text $text -Source $file.FullName)) { $rows.Add($row) }
            }
            catch {
                throw "Schedule record '$($file.FullName)' is unreadable: $($_.Exception.Message)"
            }
        }
        return @($rows)
    }

    throw "No Paseo schedule store at '$Path'; rung uniqueness cannot be evaluated."
}

function ConvertFrom-ScheduleJson {
    <#
    .SYNOPSIS
        Parse one schedule JSON document: an array, one record, or the
        `{ schedules: [...] }` shape the list tool returns.
    #>
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Source
    )

    try {
        $parsed = ConvertFrom-Json -InputObject $Text -Depth 12
    }
    catch {
        throw "Schedule source '$Source' is not valid JSON: $($_.Exception.Message)"
    }
    if ($null -eq $parsed) { throw "Schedule source '$Source' parsed to nothing." }

    $property = $parsed.PSObject.Properties['schedules']
    if ($null -ne $property) { return @($property.Value) }
    return @($parsed)
}

function Get-Property {
    <#
    .SYNOPSIS
        Read a dotted property path without tripping StrictMode on a missing member.
    #>
    param(
        [AllowNull()][object]$Object,
        [Parameter(Mandatory)][string]$Path
    )

    $current = $Object
    foreach ($segment in ($Path -split '\.')) {
        if ($null -eq $current) { return $null }
        $property = $current.PSObject.Properties[$segment]
        if ($null -eq $property) { return $null }
        $current = $property.Value
    }
    return $current
}

function Test-RungRole {
    <#
    .SYNOPSIS
        Is this row a MERGE-TICK rung, or a different class of schedule?
    #>
    param([AllowNull()][object]$Row)

    $name = [string](Get-Property -Object $Row -Path 'name')
    $prompt = [string](Get-Property -Object $Row -Path 'prompt')

    if ($name -match '(?i)^hub[-_]?watch') { return $true }
    if ($prompt -match '(?i)MERGE-TICK') { return $true }
    if ($prompt -match '(?i)HUB\s+BACKSTOP') { return $true }
    return $false
}

function Get-RungIdentity {
    <#
    .SYNOPSIS
        The keys a rung carries: the hub session(s) it addresses and the repo
        graph it works on. Every source is evidence; none of them is a guess.
    #>
    param([AllowNull()][object]$Row)

    $prompt = [string](Get-Property -Object $Row -Path 'prompt')
    $name = [string](Get-Property -Object $Row -Path 'name')
    $cwd = [string](Get-Property -Object $Row -Path 'target.config.cwd')

    $sessions = [System.Collections.Generic.List[string]]::new()
    foreach ($match in [regex]::Matches($prompt, '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}')) {
        $value = 'session:' + $match.Value.ToLowerInvariant()
        if (-not $sessions.Contains($value)) { $sessions.Add($value) }
    }

    $repos = [System.Collections.Generic.List[string]]::new()
    $AddRepo = {
        param([string]$Candidate)
        $normalised = ConvertTo-RepoName -Value $Candidate
        if (-not $normalised) { return }
        $key = 'repo:' + $normalised
        if (-not $repos.Contains($key)) { $repos.Add($key) }
    }

    # hub-<x> label tokens name the repo graph (hub-common, hub-cbk, hub-uh).
    foreach ($match in [regex]::Matches($prompt, '(?i)\bhub-([a-z0-9][a-z0-9-]*)')) {
        if ($match.Groups[1].Value -match '(?i)^watch') { continue }
        & $AddRepo $match.Groups[1].Value
    }

    # Explicit path arguments in the prompt.
    foreach ($pattern in @(
            '(?i)Repo(?:sit|sitory)?\s+root:\s*("[^"]+"|''[^'']+''|\S+)',
            '(?i)-RepoPath\s+("[^"]+"|''[^'']+''|\S+)',
            '(?i)-Repo\s+("[^"]+"|''[^'']+''|\S+)',
            '(?i)\bcwd\s*=\s*("[^"]+"|''[^'']+''|\S+)'
        )) {
        foreach ($match in [regex]::Matches($prompt, $pattern)) {
            $value = $match.Groups[1].Value.Trim('"', "'").TrimEnd('\', '/')
            if ($value -match '[\\/]' -or $value -match '^[A-Za-z]:') { & $AddRepo $value }
        }
    }

    # The schedule's own target checkout.
    if (-not [string]::IsNullOrWhiteSpace($cwd)) { & $AddRepo $cwd }

    # The schedule name itself: hub-watch-<repo>[-backstop].
    if ($name -match '(?i)^hub[-_]?watch[-_](.+)$') { & $AddRepo $Matches[1] }

    [pscustomobject]@{
        Sessions = @($sessions)
        Repos    = @($repos)
        Keys     = @(@($sessions) + @($repos))
    }
}

function Get-RunCount {
    <#
    .SYNOPSIS
        How many times has this row fired, from the daemon's `runs` history?

    .DESCRIPTION
        `runs` is an array of run records, but JSON parsing collapses a
        single-element array to the bare object and an absent history to null -
        and a ONE-SHOT lane dispatch is exactly the one-element case. Counting
        only real arrays would therefore read every spent one-shot as unspent,
        and counting a bare object as unspent would do the same. A number is
        accepted too, so a caller-supplied summary is honoured.
    #>
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return 0 }
    if ($Value -is [System.Array]) { return $Value.Count }
    if ($Value -is [System.Collections.ICollection]) { return $Value.Count }

    $parsed = 0
    $text = [string]$Value
    if ($text -match '^\s*\d+\s*$' -and [int]::TryParse($text.Trim(), [ref]$parsed)) { return $parsed }

    return 1
}

function Test-RungSpent {
    <#
    .SYNOPSIS
        Has this row already used up its allowance, so it can never fire again?

    .DESCRIPTION
        The daemon keeps the run history in `runs` and the allowance in
        `maxRuns`. `maxRuns` absent, null or 0 means no limit. A row whose
        history has reached the allowance is spent: a one-shot lane dispatch
        stays `active` at least until the daemon settles it, and it is not a
        competing rung while spent (bead cl-common-5wy).
    #>
    param([AllowNull()][object]$Row)

    $maxRuns = Get-Property -Object $Row -Path 'maxRuns'
    if ($null -eq $maxRuns) { return $false }

    $limit = 0
    if (-not [int]::TryParse(([string]$maxRuns).Trim(), [ref]$limit)) { return $false }
    if ($limit -le 0) { return $false }

    $runs = Get-Property -Object $Row -Path 'runs'
    return ((Get-RunCount -Value $runs) -ge $limit)
}

function Get-RungRecord {
    <#
    .SYNOPSIS
        Flatten one schedule row to what the verdict needs.
    #>
    param([Parameter(Mandatory)][object]$Row)

    $identity = Get-RungIdentity -Row $Row
    $status = ([string](Get-Property -Object $Row -Path 'status')).Trim().ToLowerInvariant()
    $spent = Test-RungSpent -Row $Row
    $live = ($status -eq 'active') -and (-not $spent)

    # What the reader is told: `active` only when it can still fire, so a spent
    # row is never reported in a way that reads as a writer.
    $disposition = if ($live) { 'active' } elseif ($status -eq 'active') { 'active (spent: maxRuns reached)' } else { $status }

    [pscustomobject]@{
        Id          = [string](Get-Property -Object $Row -Path 'id')
        Name        = [string](Get-Property -Object $Row -Path 'name')
        Cron        = [string](Get-Property -Object $Row -Path 'cadence.expression')
        Status      = $status
        Spent       = $spent
        Live        = $live
        Disposition = $disposition
        Sessions    = @($identity.Sessions)
        Repos       = @($identity.Repos)
        Keys        = @($identity.Keys)
    }
}

function Format-Rung {
    param([Parameter(Mandatory)][object]$Rung)
    $cron = if ($Rung.Cron) { $Rung.Cron } else { '<no cron>' }
    "id={0} name='{1}' cron='{2}'" -f $Rung.Id, $Rung.Name, $cron
}

try {
    $supplied = @(
        (-not [string]::IsNullOrWhiteSpace($SchedulesPath))
        (-not [string]::IsNullOrWhiteSpace($SchedulesJson))
        ($null -ne $Schedules)
    ) | Where-Object { $_ }

    if (@($supplied).Count -gt 1) {
        throw 'Pass only one of -SchedulesPath, -SchedulesJson and -Schedules: one schedule list, one owner.'
    }

    if ($null -ne $Schedules) {
        $rows = @($Schedules)
    }
    elseif (-not [string]::IsNullOrWhiteSpace($SchedulesJson)) {
        $rows = @(ConvertFrom-ScheduleJson -Text $SchedulesJson -Source 'SchedulesJson')
    }
    else {
        $source = if (-not [string]::IsNullOrWhiteSpace($SchedulesPath)) { $SchedulesPath }
        elseif ($env:PASEO_SCHEDULES_DIR) { $env:PASEO_SCHEDULES_DIR }
        else { Join-Path $HOME '.paseo\schedules' }
        $rows = @(Get-ScheduleRowsFromPath -Path $source)
    }

    $allRungs = @($rows | Where-Object { Test-RungRole -Row $_ } | ForEach-Object { Get-RungRecord -Row $_ })
}
catch {
    $message = "CANNOT-EVALUATE - $($_.Exception.Message)"
    if ($Json) {
        [ordered]@{ schemaVersion = 1; verdict = 'CANNOT-EVALUATE'; repo = $Repo; reason = $message; active = @(); tolerated = @() } | ConvertTo-Json -Depth 6
    }
    else { Write-Output ("Test-SingleHubRung: {0}" -f $message) }
    exit 2
}

$targetRepo = ConvertTo-RepoName -Value $Repo

# Scope: with -Repo, a rung belongs to this graph when it names this repo; a
# rung that names ANOTHER repo is not this repo's business (that is what keeps a
# sibling repo's duplicate from failing this one). A rung with no repo evidence
# at all cannot be placed, so it is unevaluable rather than ignored.
$unplaceable = [System.Collections.Generic.List[object]]::new()
$inScope = [System.Collections.Generic.List[object]]::new()
foreach ($rung in $allRungs) {
    if (-not $targetRepo) { $inScope.Add($rung); continue }
    $repoKeys = @($rung.Repos)
    $thisKey = 'repo:' + $targetRepo
    if ($repoKeys -contains $thisKey) { $inScope.Add($rung); continue }
    if ($repoKeys.Count -gt 0) { continue }
    if ($rung.Live) { $unplaceable.Add($rung) }
}

if ($unplaceable.Count -gt 0) {
    $detail = ($unplaceable | ForEach-Object { Format-Rung -Rung $_ }) -join '; '
    $message = "CANNOT-EVALUATE - {0} active MERGE-TICK rung(s) carry no repo or session identity, so uniqueness for '{1}' cannot be proven: {2}" -f $unplaceable.Count, ($targetRepo ?? '<all>'), $detail
    if ($Json) {
        [ordered]@{ schemaVersion = 1; verdict = 'CANNOT-EVALUATE'; repo = $targetRepo; reason = $message; active = @($unplaceable | ForEach-Object { $_.Id }); tolerated = @() } | ConvertTo-Json -Depth 6
    }
    else { Write-Output ("Test-SingleHubRung: {0}" -f $message) }
    exit 2
}

$active = @($inScope | Where-Object { $_.Live })
$tolerated = @($inScope | Where-Object { -not $_.Live } | Sort-Object Name, Id)

# Duplicate groups: one group per shared key with more than one active rung.
$duplicates = [System.Collections.Generic.List[object]]::new()
$seen = [System.Collections.Generic.HashSet[string]]::new()
foreach ($rung in $active) {
    foreach ($key in $rung.Keys) {
        if (-not $seen.Add($key)) { continue }
        $holders = @($active | Where-Object { $_.Keys -contains $key })
        if ($holders.Count -gt 1) {
            $duplicates.Add([pscustomobject]@{
                    Key   = $key
                    Rungs = $holders
                })
        }
    }
}

$toleratedText = if ($tolerated.Count -gt 0) {
    ($tolerated | ForEach-Object { "{0} (status={1})" -f (Format-Rung -Rung $_), $_.Disposition }) -join '; '
}
else { 'none' }

$scopeText = if ($targetRepo) { $targetRepo } else { '<all repos>' }

if ($duplicates.Count -gt 0) {
    $groups = foreach ($group in $duplicates) {
        "{0} -> {1}" -f $group.Key, (($group.Rungs | ForEach-Object { Format-Rung -Rung $_ }) -join ' vs ')
    }
    $message = ("REFUSE - {0} duplicate ACTIVE MERGE-TICK rung group(s) for {1} ({2} active rung(s)). Exactly one active rung per repo is allowed, because two ticks are two writers on one trunk and one can sweep a branch/worktree out from under the other's merge worker (measured 2026-11-03, bead cl-common-3tv). Duplicate: {3}. Tolerated non-live rung(s): {4}." -f `
            $duplicates.Count, $scopeText, $active.Count, ($groups -join ' | '), $toleratedText)
    if ($Json) {
        [ordered]@{
            schemaVersion = 1
            verdict       = 'REFUSE'
            repo          = $targetRepo
            reason        = $message
            active        = @($active | ForEach-Object { [ordered]@{ id = $_.Id; name = $_.Name; cron = $_.Cron; status = $_.Status; keys = $_.Keys } })
            duplicates    = @($duplicates | ForEach-Object { [ordered]@{ key = $_.Key; ids = @($_.Rungs | ForEach-Object { $_.Id }); crons = @($_.Rungs | ForEach-Object { $_.Cron }) } })
            tolerated     = @($tolerated | ForEach-Object { [ordered]@{ id = $_.Id; name = $_.Name; cron = $_.Cron; status = $_.Status; spent = $_.Spent; disposition = $_.Disposition } })
        } | ConvertTo-Json -Depth 8
    }
    else { Write-Output ("Test-SingleHubRung: {0}" -f $message) }
    exit 1
}

if ($active.Count -eq 0) {
    $message = ("NO-RUNG - no ACTIVE MERGE-TICK rung for {0}. A Hub must have exactly one (create it in the same turn it advertises). Tolerated non-live rung(s): {1}." -f $scopeText, $toleratedText)
    if ($Json) {
        [ordered]@{ schemaVersion = 1; verdict = 'NO-RUNG'; repo = $targetRepo; reason = $message; active = @(); tolerated = @($tolerated | ForEach-Object { [ordered]@{ id = $_.Id; name = $_.Name; cron = $_.Cron; status = $_.Status; spent = $_.Spent; disposition = $_.Disposition } }) } | ConvertTo-Json -Depth 6
    }
    else { Write-Output ("Test-SingleHubRung: {0}" -f $message) }
    exit 3
}

if ($targetRepo) {
    $winner = $active[0]
    $message = ("PASS - exactly one ACTIVE MERGE-TICK rung for {0}: {1}. Tolerated non-live rung(s): {2}. A paused rung is tolerated only while it stays paused; resuming it creates a second active rung and this guard will refuse." -f `
            $scopeText, (Format-Rung -Rung $winner), $toleratedText)
}
else {
    # Unscoped: one rung per repo graph, reported per graph so a clean repo is
    # not confused with a clean store.
    $byRepo = [ordered]@{}
    foreach ($rung in $active) {
        foreach ($key in @($rung.Repos)) {
            if (-not $byRepo.Contains($key)) { $byRepo[$key] = [System.Collections.Generic.List[object]]::new() }
            $byRepo[$key].Add($rung)
        }
    }
    $summary = @($byRepo.Keys | ForEach-Object { "{0} -> {1}" -f $_, ((@($byRepo[$_] | ForEach-Object { $_.Id }) | Select-Object -Unique) -join ',') }) -join '; '
    $message = ("PASS - one ACTIVE MERGE-TICK rung per repo ({0}): {1}. Tolerated non-live rung(s): {2}." -f `
            @($byRepo.Keys).Count, $summary, $toleratedText)
}

if ($Json) {
    [ordered]@{
        schemaVersion = 1
        verdict       = 'PASS'
        repo          = $targetRepo
        reason        = $message
        active        = @($active | ForEach-Object { [ordered]@{ id = $_.Id; name = $_.Name; cron = $_.Cron; status = $_.Status; keys = $_.Keys } })
        duplicates    = @()
        tolerated     = @($tolerated | ForEach-Object { [ordered]@{ id = $_.Id; name = $_.Name; cron = $_.Cron; status = $_.Status; spent = $_.Spent; disposition = $_.Disposition } })
    } | ConvertTo-Json -Depth 6
}
else { Write-Output ("Test-SingleHubRung: {0}" -f $message) }

exit 0
