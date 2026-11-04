#Requires -Version 7
<#
.SYNOPSIS
    One cheap call that answers "did my durable dispatch actually produce an
    agent, or did the fire fail with no agentId?".

.DESCRIPTION
    A one-shot Paseo schedule (cron, `maxRuns: 1`) is the fleet's documented way to
    survive a parent turn ending, so a fire that fails before spawning an agent is
    a dispatch-durability hole, not a cosmetic error: the tick has already moved
    on, the bead reads as dispatched, and nothing is running (measured 2026-11-03,
    bead cl-common-q8k - a run ended `status=failed`, `agentId=null` on
    `EPERM: operation not permitted, rename '...\.paseo\schedules\<id>.json.<tmp>'
    -> '...\.paseo\schedules\<id>.json'`, and `maxRuns: 1` spent the whole budget).

    This helper is the Hub-side assertion. Given a schedule id (or a repo + name)
    it reads that schedule's record and returns exactly one of four verdicts:

      spawned-and-live      the newest run carries an `agentId` and is still open
                            (`running`/`started`), so a live agent exists
      spawned-and-terminal  the newest run carries an `agentId` and has ended
                            (`succeeded`, `failed`, ...): the spawn happened, so
                            the DISPATCH is not what failed - judge the work
      failed-spawn          a run ended with `agentId: null` (or the schedule
                            ended with no run ever recorded and no future fire):
                            the fire consumed budget and produced NO work
      pending-fire          no run has fired yet, or a run is open with no agent
                            recorded yet - WAIT and assert again, do not fail

    The read is RAW TEXT with regex, never `ConvertFrom-Json`. JSON coercion
    re-formats `nextRunAt` and can drop or shift its UTC offset; that misread is
    bead cl-common-gct, where an offset-less wall clock was read as UTC and
    reported a 420-minute phantom future. Every instant this helper prints is the
    record's own token, verbatim (including its trailing `Z` or `+hh:mm`), and the
    run ordering uses the raw tokens only - nothing is converted to a local time.

    It reads nothing but the one record file, writes nothing, and calls no
    daemon. Run it immediately after a dispatch and again at every check-back: a
    tick never leaves a bead looking dispatched with nothing running.

    Exit codes
      0  spawned-and-live, or spawned-and-terminal (the spawn happened)
      1  failed-spawn - the record proves the dispatch produced no agent
      2  CANNOT-EVALUATE - no such record, an ambiguous id/name, or an unreadable
         record. An unevaluable assertion is never a pass.
      3  pending-fire - WAIT (named non-verdict; the fire has not produced an
         agent yet, and that is not yet a failure)

.PARAMETER ScheduleId
    The schedule id, as returned by `paseo_create_schedule` and as the record's
    file name (`%USERPROFILE%\.paseo\schedules\<id>.json`). A prefix is
    accepted; an ambiguous prefix is CANNOT-EVALUATE rather than a guess.

.PARAMETER Name
    The schedule name to resolve when the id was lost (e.g. from a bead note that
    only recorded `lane-gct-naive-instant`). Combine with -Cwd to disambiguate
    two schedules of the same name in different repos.

.PARAMETER Cwd
    With -Name, require the record's `cwd` to match. Paths are compared
    case-insensitively with `/` and `\` normalised, so a forward-slash and a
    backslash spelling of one checkout name the same directory.

.PARAMETER SchedulesPath
    The schedule store to read. Defaults to `$env:PASEO_SCHEDULES_DIR` when set,
    else `<HOME>\.paseo\schedules` - the same resolution every other Hub helper
    uses. The test seam; never point it at the live store from a test.

.PARAMETER Json
    Emit the verdict as JSON (schemaVersion 1) instead of the host lines.

.EXAMPLE
    pwsh Test-ScheduleDispatch.ps1 -ScheduleId 16e0588b
    Test-ScheduleDispatch: FAILED-SPAWN schedule=16e0588b ...

.EXAMPLE
    pwsh Test-ScheduleDispatch.ps1 -Name lane-gct-naive-instant-b -Cwd <repo>\.worktrees\lane-gct -Json

.EXAMPLE
    # the check-back assertion, tolerant of a fire that has not landed yet
    pwsh Test-ScheduleDispatch.ps1 -ScheduleId b3fdf56a -Json | ConvertFrom-Json | Select-Object verdict, nextRunAt
#>
[CmdletBinding(DefaultParameterSetName = 'ById')]
param(
    [Parameter(Mandatory, ParameterSetName = 'ById')]
    [ValidateNotNullOrEmpty()]
    [string]$ScheduleId,

    [Parameter(Mandatory, ParameterSetName = 'ByName')]
    [ValidateNotNullOrEmpty()]
    [string]$Name,

    [Parameter(ParameterSetName = 'ByName')]
    [string]$Cwd,

    [string]$SchedulesPath,

    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:LiveRunStates = @('running', 'started', 'in-progress', 'in_progress', 'active', 'queued')
$script:TerminalScheduleStates = @('completed', 'failed', 'cancelled', 'canceled', 'expired', 'error')

function Stop-CannotEvaluate {
    param([Parameter(Mandatory)][string]$Reason)

    $message = "CANNOT-EVALUATE - $Reason"
    if ($Json) {
        [ordered]@{
            schemaVersion = 1
            verdict       = 'cannot-evaluate'
            exitCode      = 2
            reason        = $message
            source        = $null
        } | ConvertTo-Json -Depth 6
    }
    else {
        Write-Output ("Test-ScheduleDispatch: {0}" -f $message)
    }
    exit 2
}

function Find-JsonValueBounds {
    <#
        Given the index of an opening '[' or '{', return the index of its matching
        close, string-aware (braces inside strings and escaped quotes do not
        count). Returns -1 when unbalanced.
    #>
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][int]$StartIndex
    )

    $openChar = $Text[$StartIndex]
    $closeChar = if ($openChar -eq '[') { ']' } else { '}' }
    $depth = 0
    $inString = $false
    $escaped = $false

    for ($i = $StartIndex; $i -lt $Text.Length; $i++) {
        $ch = $Text[$i]
        if ($inString) {
            if ($escaped) { $escaped = $false; continue }
            if ([int]$ch -eq 92) { $escaped = $true; continue }
            if ($ch -eq '"') { $inString = $false }
            continue
        }
        if ($ch -eq '"') { $inString = $true; continue }
        if ($ch -eq $openChar) { $depth++; continue }
        if ($ch -eq $closeChar) {
            $depth--
            if ($depth -eq 0) { return $i }
        }
    }
    return -1
}

function ConvertFrom-RawJsonString {
    <#
        Unescape the one JSON string form this helper reads (Windows paths carry
        `\\`; nothing else is expected). Done explicitly so the printed value is
        the file's value, not a re-serialisation of it.
    #>
    param([Parameter(Mandatory)][string]$Value)

    $builder = [System.Text.StringBuilder]::new()
    for ($i = 0; $i -lt $Value.Length; $i++) {
        $ch = $Value[$i]
        if ([int]$ch -ne 92) { $null = $builder.Append($ch); continue }
        if ($i + 1 -ge $Value.Length) { $null = $builder.Append($ch); continue }
        $next = $Value[$i + 1]
        switch ($next) {
            '"' { $null = $builder.Append('"'); $i++ }
            '\' { $null = $builder.Append('\'); $i++ }
            '/' { $null = $builder.Append('/'); $i++ }
            'n' { $null = $builder.Append("`n"); $i++ }
            'r' { $null = $builder.Append("`r"); $i++ }
            't' { $null = $builder.Append("`t"); $i++ }
            default { $null = $builder.Append($ch) }
        }
    }
    return $builder.ToString()
}

function Get-RawScalar {
    <#
        Read one scalar field from raw JSON text as the record spells it. Returns
        the unescaped string for a JSON string, the number/bool token as text, and
        $null for an explicit null or an absent field. Never a typed instant: the
        whole point is that `nextRunAt` keeps its own offset token.
    #>
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Field
    )

    $pattern = '(?<!\\)"' + [regex]::Escape($Field) + '"\s*:\s*(?<value>"(?:[^"\\]|\\.)*"|null|true|false|-?\d+(?:\.\d+)?)'
    $match = [regex]::Match($Text, $pattern)
    if (-not $match.Success) { return $null }

    $raw = $match.Groups['value'].Value
    if ($raw -eq 'null') { return $null }
    if ($raw.StartsWith('"')) { return (ConvertFrom-RawJsonString -Value $raw.Substring(1, $raw.Length - 2)) }
    return $raw
}

function Get-RunsBounds {
    <#
        Locate the `runs` array in the raw record. The schedule-level scalars are
        read from the record with this block REMOVED, so a run's own `status` can
        never be mistaken for the schedule's, whatever order the daemon wrote.
    #>
    param([Parameter(Mandatory)][string]$Text)

    $runsMatch = [regex]::Match($Text, '(?<!\\)"runs"\s*:\s*')
    if (-not $runsMatch.Success) { return $null }
    $arrayStart = $Text.IndexOf('[', $runsMatch.Index + $runsMatch.Length)
    if ($arrayStart -lt 0) { return $null }
    $arrayEnd = Find-JsonValueBounds -Text $Text -StartIndex $arrayStart
    if ($arrayEnd -lt 0) { return $null }
    return [pscustomobject]@{ Start = $arrayStart; End = $arrayEnd }
}

function Get-RunObjects {
    <#
        Split the record's `runs` array into one raw text block per run object.
        Works on the raw text so every field keeps its original token.
    #>
    param([Parameter(Mandatory)][string]$Text)

    $bounds = Get-RunsBounds -Text $Text
    if ($null -eq $bounds) { return @() }

    $blocks = [System.Collections.Generic.List[string]]::new()
    $i = $bounds.Start + 1
    while ($i -lt $bounds.End) {
        if ($Text[$i] -eq '{') {
            $objectEnd = Find-JsonValueBounds -Text $Text -StartIndex $i
            if ($objectEnd -lt 0) { break }
            $blocks.Add($Text.Substring($i, $objectEnd - $i + 1))
            $i = $objectEnd + 1
            continue
        }
        $i++
    }
    return $blocks.ToArray()
}

function Select-NewestRun {
    <#
        The newest run is the one the dispatch verdict is about. Order by the raw
        `startedAt` token (else `scheduledFor`), falling back to file order on a
        tie or a missing token. Ordering only - the printed instant stays raw.
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$RunBlocks)

    $newest = $null
    $newestKey = ''
    for ($index = 0; $index -lt $RunBlocks.Count; $index++) {
        $block = $RunBlocks[$index]
        $key = Get-RawScalar -Text $block -Field 'startedAt'
        if ([string]::IsNullOrWhiteSpace($key)) { $key = Get-RawScalar -Text $block -Field 'scheduledFor' }
        if ([string]::IsNullOrWhiteSpace($key)) { $key = '' }

        # File order wins ties: a later block is a later fire.
        if ($null -eq $newest -or [string]::CompareOrdinal($key, $newestKey) -ge 0) {
            $newest = [pscustomobject]@{
                Index = $index
                Block = $block
                Key   = $key
            }
            $newestKey = $key
        }
    }
    return $newest
}

function Get-FailureSignature {
    <#
        Classify a run error. The defect this helper exists for is the daemon's
        momentary schedule-state rename, reported as EPERM/EACCES/EBUSY on a
        `<id>.json.<tmp>` file. A different failure still counts (an agent that
        was never spawned is a lost dispatch), but the signature tells the tick
        whether the retry-with-backoff path can clear it.
    #>
    param([AllowNull()][string]$ErrorText)

    if ([string]::IsNullOrWhiteSpace($ErrorText)) { return $null }
    if ($ErrorText -match 'EPERM|EACCES|EBUSY|ETXTBSY|operation not permitted|resource busy|text file busy') {
        if ($ErrorText -match '\.tmp|rename|schedules[\\/][0-9a-fA-F]{6,}\.json') { return 'schedule-state-rename' }
        return 'transient-write'
    }
    return 'other'
}

function Resolve-ScheduleRecord {
    <#
        Resolve exactly one record file. Ambiguity is a named non-verdict - two
        candidate records mean the assertion cannot be about one dispatch.
    #>
    param(
        [Parameter(Mandatory)][string]$Store,
        [AllowNull()][string]$Id,
        [AllowNull()][string]$Name,
        [AllowNull()][string]$Cwd
    )

    if (-not (Test-Path -LiteralPath $Store -PathType Container)) {
        Stop-CannotEvaluate ("the schedule store does not exist: {0}" -f $Store)
    }

    $files = @(Get-ChildItem -LiteralPath $Store -Filter '*.json' -File -ErrorAction SilentlyContinue)

    if (-not [string]::IsNullOrWhiteSpace($Id)) {
        $exact = @($files | Where-Object { $_.BaseName -ieq $Id })
        if ($exact.Count -eq 1) { return $exact[0] }
        if ($exact.Count -gt 1) {
            Stop-CannotEvaluate ("{0} record(s) are named exactly '{1}': {2}" -f $exact.Count, $Id, (($exact | ForEach-Object { $_.BaseName }) -join ', '))
        }
        $prefixed = @($files | Where-Object { $_.BaseName.StartsWith($Id, [System.StringComparison]::OrdinalIgnoreCase) })
        if ($prefixed.Count -eq 1) { return $prefixed[0] }
        if ($prefixed.Count -gt 1) {
            Stop-CannotEvaluate ("id '{0}' matches {1} schedule records ({2}); pass the full id - an ambiguous id is not an assertion" -f $Id, $prefixed.Count, (($prefixed | ForEach-Object { $_.BaseName }) -join ', '))
        }
        Stop-CannotEvaluate ("no schedule record named '{0}' in {1}" -f $Id, $Store)
    }

    $matches = [System.Collections.Generic.List[object]]::new()
    foreach ($file in $files) {
        $text = Get-Content -LiteralPath $file.FullName -Raw -Encoding utf8
        $recordName = Get-RawScalar -Text $text -Field 'name'
        if ($recordName -ne $Name) { continue }
        if (-not [string]::IsNullOrWhiteSpace($Cwd)) {
            $recordCwd = Get-RawScalar -Text $text -Field 'cwd'
            if ([string]::IsNullOrWhiteSpace($recordCwd)) { continue }
            $left = $recordCwd.Replace('\', '/').TrimEnd('/')
            $right = $Cwd.Replace('\', '/').TrimEnd('/')
            if (-not $left.Equals($right, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        }
        $matches.Add($file)
    }

    if ($matches.Count -eq 1) { return $matches[0] }
    if ($matches.Count -gt 1) {
        $detail = ($matches | ForEach-Object { $_.BaseName }) -join ', '
        Stop-CannotEvaluate ("name '{0}' matches {1} schedule records ({2}); narrow with -Cwd or pass -ScheduleId" -f $Name, $matches.Count, $detail)
    }
    Stop-CannotEvaluate ("no schedule record named '{0}'{1} in {2}" -f $Name, $(if ($Cwd) { " with cwd '$Cwd'" } else { '' }), $Store)
}

$store = if (-not [string]::IsNullOrWhiteSpace($SchedulesPath)) { $SchedulesPath }
elseif ($env:PASEO_SCHEDULES_DIR) { $env:PASEO_SCHEDULES_DIR }
else { Join-Path $HOME '.paseo\schedules' }

$recordFile = Resolve-ScheduleRecord -Store $store -Id $ScheduleId -Name $Name -Cwd $Cwd

try {
    $raw = Get-Content -LiteralPath $recordFile.FullName -Raw -Encoding utf8
}
catch {
    Stop-CannotEvaluate ("the schedule record could not be read: {0} ({1})" -f $recordFile.FullName, $_.Exception.Message)
}

if ([string]::IsNullOrWhiteSpace($raw)) {
    Stop-CannotEvaluate ("the schedule record is empty: {0}" -f $recordFile.FullName)
}

$runBlocks = @(Get-RunObjects -Text $raw)
$runsBounds = Get-RunsBounds -Text $raw
$scheduleText = if ($null -ne $runsBounds) { $raw.Remove($runsBounds.Start, $runsBounds.End - $runsBounds.Start + 1) } else { $raw }
$scheduleStatus = Get-RawScalar -Text $scheduleText -Field 'status'
$nextRunAt = Get-RawScalar -Text $scheduleText -Field 'nextRunAt'
$lastRunAt = Get-RawScalar -Text $scheduleText -Field 'lastRunAt'
$recordName = Get-RawScalar -Text $scheduleText -Field 'name'
$maxRuns = Get-RawScalar -Text $scheduleText -Field 'maxRuns'
$recordCwd = Get-RawScalar -Text $scheduleText -Field 'cwd'
$recordId = if ($recordFile.BaseName) { $recordFile.BaseName } else { $ScheduleId }

# maxRuns is a count, not an instant: a JSON consumer can compare it, while every
# instant below stays the record's raw token.
$maxRunsValue = $null
if (-not [string]::IsNullOrWhiteSpace($maxRuns)) {
    $parsedMaxRuns = 0
    $maxRunsValue = if ([int]::TryParse($maxRuns, [ref]$parsedMaxRuns)) { $parsedMaxRuns } else { $maxRuns }
}

$newest = if ($runBlocks.Count -gt 0) { Select-NewestRun -RunBlocks $runBlocks } else { $null }

$run = $null
if ($null -ne $newest) {
    $block = $newest.Block
    $runStatus = Get-RawScalar -Text $block -Field 'status'
    $runAgent = Get-RawScalar -Text $block -Field 'agentId'
    $runError = Get-RawScalar -Text $block -Field 'error'
    $run = [pscustomobject]@{
        Id           = Get-RawScalar -Text $block -Field 'id'
        Status       = $runStatus
        AgentId      = $runAgent
        WorkspaceId  = Get-RawScalar -Text $block -Field 'workspaceId'
        ScheduledFor = Get-RawScalar -Text $block -Field 'scheduledFor'
        StartedAt    = Get-RawScalar -Text $block -Field 'startedAt'
        EndedAt      = Get-RawScalar -Text $block -Field 'endedAt'
        Error        = $runError
        Signature    = Get-FailureSignature -ErrorText $runError
    }
}

$hasAgent = ($null -ne $run) -and (-not [string]::IsNullOrWhiteSpace($run.AgentId))
$runIsOpen = ($null -ne $run) -and ($script:LiveRunStates -contains ([string]$run.Status).ToLowerInvariant())

if ($null -eq $run) {
    if ([string]::IsNullOrWhiteSpace($nextRunAt) -and ($script:TerminalScheduleStates -contains ([string]$scheduleStatus).ToLowerInvariant())) {
        $verdict = 'failed-spawn'
        $exitCode = 1
        $reason = ("no run was ever recorded and the schedule can no longer fire (status={0}, nextRunAt=null): the dispatch produced no agent and no retry will happen" -f $scheduleStatus)
    }
    else {
        $verdict = 'pending-fire'
        $exitCode = 3
        $nextText = if ([string]::IsNullOrWhiteSpace($nextRunAt)) { 'null' } else { $nextRunAt }
        $reason = ("no run recorded yet (status={0}, nextRunAt={1}) - the fire has not happened; assert again, do not fail" -f $scheduleStatus, $nextText)
    }
}
elseif ($hasAgent) {
    if ($runIsOpen) {
        $verdict = 'spawned-and-live'
        $exitCode = 0
        $reason = ("run {0} is open (status={1}) and recorded agent {2} - a live dispatch exists" -f $run.Id, $run.Status, $run.AgentId)
    }
    else {
        $verdict = 'spawned-and-terminal'
        $exitCode = 0
        $reason = ("run {0} ended status={1} after spawning agent {2} - the dispatch happened; judge the work, not the spawn" -f $run.Id, $run.Status, $run.AgentId)
    }
}
elseif ($runIsOpen) {
    $verdict = 'pending-fire'
    $exitCode = 3
    $reason = ("run {0} is open (status={1}) but records no agentId yet - the daemon may still be spawning; assert again" -f $run.Id, $run.Status)
}
else {
    $verdict = 'failed-spawn'
    $exitCode = 1
    $reason = ("run {0} ended status={1} with agentId=null - the fire consumed the schedule's budget and spawned NO agent" -f $run.Id, $run.Status)
    if ($run.Signature) { $reason += (" (error signature: {0})" -f $run.Signature) }
}

$label = switch ($verdict) {
    'spawned-and-live' { 'SPAWNED-AND-LIVE' }
    'spawned-and-terminal' { 'SPAWNED-AND-TERMINAL' }
    'failed-spawn' { 'FAILED-SPAWN' }
    default { 'PENDING-FIRE' }
}

$actionHint = switch ($verdict) {
    'spawned-and-live' { 'record the agent id on the bead note and keep supervising' }
    'spawned-and-terminal' { 'verify the run artifacts; a terminal run is not a lost dispatch' }
    'failed-spawn' {
        'recreate the one-shot (a completed maxRuns-1 record cannot be re-armed by update), assert again, and record the failed run on the bead'
    }
    default { 'wait, then assert again; do not report the dispatch as delivered' }
}

# Printed instants stay exactly as the record spells them. Nothing here converts
# a token, so a naive value cannot be dressed up as UTC (bead cl-common-gct).
$nextRunAtDisplay = if ([string]::IsNullOrWhiteSpace($nextRunAt)) { 'none' } else { $nextRunAt }

if ($Json) {
    [ordered]@{
        schemaVersion    = 1
        verdict          = $verdict
        exitCode         = $exitCode
        scheduleId       = $recordId
        name             = $recordName
        scheduleStatus   = $scheduleStatus
        maxRuns          = $maxRunsValue
        nextRunAt        = $nextRunAt
        lastRunAt        = $lastRunAt
        cwd              = $recordCwd
        runCount         = $runBlocks.Count
        run              = if ($null -eq $run) { $null } else {
            [ordered]@{
                id           = $run.Id
                status       = $run.Status
                agentId      = $run.AgentId
                workspaceId  = $run.WorkspaceId
                scheduledFor = $run.ScheduledFor
                startedAt    = $run.StartedAt
                endedAt      = $run.EndedAt
                error        = $run.Error
                signature    = $run.Signature
            }
        }
        failureSignature = if ($null -eq $run) { $null } else { $run.Signature }
        reason           = $reason
        actionHint       = $actionHint
        source           = $recordFile.FullName
    } | ConvertTo-Json -Depth 6
}
else {
    Write-Output ("Test-ScheduleDispatch: {0} schedule={1} name='{2}' status={3} nextRunAt={4}{5}" -f `
            $label, $recordId, $recordName, $scheduleStatus, $nextRunAtDisplay,
        $(if ($null -ne $run) { " run=$($run.Id) runStatus=$($run.Status) agentId=$(if ([string]::IsNullOrWhiteSpace($run.AgentId)) { 'null' } else { $run.AgentId })" } else { ' run=none' }))

    if ($null -ne $run -and -not [string]::IsNullOrWhiteSpace($run.Error)) {
        $errorText = $run.Error
        if ($errorText.Length -gt 300) { $errorText = $errorText.Substring(0, 300) + '...' }
        Write-Output ("  error: {0}" -f $errorText)
    }
    Write-Output ("  reason: {0}" -f $reason)
    Write-Output ("  action: {0}" -f $actionHint)
}

exit $exitCode
