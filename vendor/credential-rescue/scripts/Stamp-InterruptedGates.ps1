#Requires -Version 7.0
<#
.SYNOPSIS
    Mark gate runs a cutover killed, so an interrupted measurement can never be
    read as red - or as a pass.

.DESCRIPTION
    A cutover restarts Paseo, which kills whatever gate battery it was hosting.
    The half-written run is a directory under `<repo>/.gate-runs/<stamp>` whose
    log stops mid-line. Nothing about that directory says "killed": a reader
    that only checks for pass/fail lines reports it exactly like a real failure,
    and the next lane spends a night chasing a red that never happened.

    So the window is recorded first (`cutover-kill-window.json`, written by the
    cutover helper around the destructive step - `{runId, startedAt, endedAt}`),
    and every `.gate-runs/<stamp>` MODIFIED INSIDE that window gets a
    `killed-by-cutover.json`:

        { runId, at, lastLogLine }

    The stamp is evidence about the measurement, not a judgement about the
    code: a reader that finds it skips the run instead of reading it either way.

.PARAMETER Root
    One or more repositories to scan. Each is inspected at `<root>/.gate-runs`.

.PARAMETER WindowStart
    ISO-8601 start of the kill window. Omit to read `-KillWindowPath`.

.PARAMETER WindowEnd
    ISO-8601 end of the kill window. Omit to read `-KillWindowPath`.

.PARAMETER KillWindowPath
    Default `~/.salmon/State/key-check/cutover-kill-window.json`.

.PARAMETER RunId
    The cutover run the window belongs to. Default: the value in the window file.

.PARAMETER Now
    Test seam: the "at" stamped into each marker.

.OUTPUTS
    Exit 0 stamped or nothing to stamp; 2 the window cannot be evaluated.

.EXAMPLE
    pwsh -File Stamp-InterruptedGates.ps1 -Root E:\Repos\cl-common -RunId 20261102-172700
#>
[CmdletBinding()]
param(
    [string[]]$Root = @(),
    [string]$WindowStart = '',
    [string]$WindowEnd = '',
    [string]$KillWindowPath = '',
    [string]$RunId = '',
    [string]$StateDir = '',
    [datetime]$Now = (Get-Date),
    [switch]$Json
)

$ErrorActionPreference = 'Stop'

$scriptRoot = $PSScriptRoot
. (Join-Path $scriptRoot 'lib\CutoverRecovery.ps1')

$StateDir = Get-CutoverStateDir -Override $StateDir
if ([string]::IsNullOrWhiteSpace($KillWindowPath)) { $KillWindowPath = Get-CutoverKillWindowPath -StateDir $StateDir }

$start = $null
$end = $null
if ($WindowStart) {
    try { $start = [datetime]::Parse($WindowStart, [Globalization.CultureInfo]::InvariantCulture) } catch { $start = $null }
}
if ($WindowEnd) {
    try { $end = [datetime]::Parse($WindowEnd, [Globalization.CultureInfo]::InvariantCulture) } catch { $end = $null }
}

if ($null -eq $start) {
    $window = Read-CutoverJsonFile -Path $KillWindowPath
    if ($null -eq $window) {
        Write-Output ("gates: cannot-evaluate ({0})" -f $(if ($script:CutoverReadError) { $script:CutoverReadError } else { "no kill window at $KillWindowPath and no -WindowStart" }))
        exit 2
    }
    if ($window.PSObject.Properties['startedAt']) {
        try { $start = [datetime]::Parse([string]$window.startedAt, [Globalization.CultureInfo]::InvariantCulture) } catch { $start = $null }
    }
    if ($null -eq $end -and $window.PSObject.Properties['endedAt'] -and -not [string]::IsNullOrWhiteSpace([string]$window.endedAt)) {
        try { $end = [datetime]::Parse([string]$window.endedAt, [Globalization.CultureInfo]::InvariantCulture) } catch { $end = $null }
    }
    if (-not $RunId -and $window.PSObject.Properties['runId']) { $RunId = [string]$window.runId }
}
if ($null -eq $start) {
    Write-Output 'gates: cannot-evaluate (the kill window carries no parsable startedAt)'
    exit 2
}
if ($null -eq $end) { $end = $Now }
if (-not $RunId) { $RunId = 'unknown' }

$stamped = @()
$scanned = 0
foreach ($repoRoot in @($Root)) {
    if ([string]::IsNullOrWhiteSpace($repoRoot)) { continue }
    $gateRuns = Join-Path $repoRoot '.gate-runs'
    if (-not (Test-Path -LiteralPath $gateRuns)) { continue }
    foreach ($run in @(Get-ChildItem -LiteralPath $gateRuns -Directory -ErrorAction SilentlyContinue)) {
        $scanned++
        $modified = $run.LastWriteTime
        if ($modified -lt $start -or $modified -gt $end) { continue }

        $lastLogLine = ''
        $logs = @(Get-ChildItem -LiteralPath $run.FullName -Filter '*.log' -File -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending)
        if ($logs.Count -gt 0) {
            $lines = @(Get-Content -LiteralPath $logs[0].FullName -ErrorAction SilentlyContinue | Where-Object { $_.Trim() })
            if ($lines.Count -gt 0) {
                $lastLogLine = ([string]$lines[-1]).Trim()
                if ($lastLogLine.Length -gt 300) { $lastLogLine = $lastLogLine.Substring(0, 300) }
            }
        }
        $payload = [ordered]@{
            version     = 1
            runId       = $RunId
            at          = $Now.ToString('o')
            lastLogLine = $lastLogLine
        }
        Set-Content -LiteralPath (Join-Path $run.FullName 'killed-by-cutover.json') `
            -Value ($payload | ConvertTo-Json -Depth 4) -Encoding utf8NoBOM
        $stamped += [ordered]@{
            repo = $repoRoot; stamp = $run.Name; lastLogLine = $lastLogLine
        }
    }
}

if ($Json) {
    [ordered]@{
        runId   = $RunId
        startedAt = $start.ToString('o')
        endedAt = $end.ToString('o')
        scanned = $scanned
        stamped = @($stamped)
    } | ConvertTo-Json -Depth 6
} else {
    Write-Output ("gates: stamped {0} of {1} run(s) in the cutover window ({2})" -f @($stamped).Count, $scanned, $RunId)
}
exit 0
