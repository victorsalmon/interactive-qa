#Requires -Version 7.0
<#
.SYNOPSIS
    Answer one question for a would-be backstop: is a key cutover in progress
    (or did one just finish) on this machine?

.DESCRIPTION
    A cutover restarts Paseo. A backstop - a scheduled agent, or a Hub revived
    by a watchdog - that runs INSIDE that window cannot see the restart, so it
    does the one thing it must not do: it takes the role the cutover just
    vacated. After runId 20261102-172700 that produced two live Hubs for one
    repo, a worktree lease held by the wrong one, and gate batteries killed
    mid-run that looked like red gates.

    Two facts stop it, and both are on disk BEFORE anything destructive:

      - `cutover-in-progress.json` (`{runId, startedAt, phase, host}`), written
        by the cutover helper before the switch and removed when the cutover
        ends - verified or failed;
      - `last-cutover.json` (`{runId, at, ...}`), the durable discovery marker
        the resume/witness pass writes.

    Exit codes:
        0   clear - no cutover in progress and none inside -WindowMinutes
        3   in progress (marker present) OR a cutover ended inside -WindowMinutes
        2   cannot-evaluate - the state exists but cannot be read. Never
            reported as 0: a false "clear" is a licence for a duplicate role.

    Exactly one line is printed on stdout, so a backstop can log it verbatim.

.PARAMETER StateDir
    The Key Check state directory. Default `~/.machine/state/key-check`.

.PARAMETER WindowMinutes
    How long after a finished cutover a backstop must still stand down.
    Default 60.

.PARAMETER Now
    Test seam: the instant "recent" is measured from.

.OUTPUTS
    Exit 0 clear, 3 in progress/recent, 2 cannot-evaluate.

.EXAMPLE
    pwsh -File Test-CutoverInProgress.ps1; if ($LASTEXITCODE -eq 3) { exit 0 }
#>
[CmdletBinding()]
param(
    [string]$StateDir = '',
    [ValidateRange(1, 1440)]
    [int]$WindowMinutes = 60,
    [datetime]$Now = (Get-Date)
)

$ErrorActionPreference = 'Stop'

$scriptRoot = $PSScriptRoot
. (Join-Path $scriptRoot 'lib\CutoverRecovery.ps1')

$StateDir = Get-CutoverStateDir -Override $StateDir
$markerPath = Get-CutoverMarkerPath -StateDir $StateDir
$lastPath = Get-CutoverLastMarkerPath -StateDir $StateDir

function Write-ProbeLine {
    param([string]$Text)
    Write-Output $Text
}

if (-not (Test-Path -LiteralPath $StateDir)) {
    Write-ProbeLine ("cutover-in-progress: no (no cutover state at {0})" -f $StateDir)
    exit 0
}

if (Test-Path -LiteralPath $markerPath) {
    $marker = Read-CutoverJsonFile -Path $markerPath
    if ($null -eq $marker) {
        Write-ProbeLine ("cutover-in-progress: cannot-evaluate ({0})" -f $(if ($script:CutoverReadError) { $script:CutoverReadError } else { "unreadable marker $markerPath" }))
        exit 2
    }
    $runId = if ($marker.PSObject.Properties['runId']) { [string]$marker.runId } else { 'unknown' }
    $phase = if ($marker.PSObject.Properties['phase']) { [string]$marker.phase } else { 'unknown' }
    $startedAt = if ($marker.PSObject.Properties['startedAt']) { [string]$marker.startedAt } else { 'unknown' }
    $hostName = if ($marker.PSObject.Properties['host']) { [string]$marker.host } else { 'unknown' }
    Write-ProbeLine ("cutover-in-progress: yes runId={0} phase={1} since={2} host={3} ({4})" -f `
            $runId, $phase, $startedAt, $hostName, $markerPath)
    exit 3
}

if (Test-Path -LiteralPath $lastPath) {
    $last = Read-CutoverJsonFile -Path $lastPath
    if ($null -eq $last) {
        Write-ProbeLine ("cutover-in-progress: cannot-evaluate ({0})" -f $(if ($script:CutoverReadError) { $script:CutoverReadError } else { "unreadable marker $lastPath" }))
        exit 2
    }
    $at = $null
    if ($last.PSObject.Properties['at'] -and -not [string]::IsNullOrWhiteSpace([string]$last.at)) {
        try { $at = [datetime]::Parse([string]$last.at, [Globalization.CultureInfo]::InvariantCulture) } catch { $at = $null }
    }
    if ($null -eq $at) {
        Write-ProbeLine ("cutover-in-progress: cannot-evaluate (last-cutover.json carries no parsable 'at')")
        exit 2
    }
    $ageMinutes = ($Now - $at).TotalMinutes
    $runId = if ($last.PSObject.Properties['runId']) { [string]$last.runId } else { 'unknown' }
    if ($ageMinutes -le $WindowMinutes) {
        Write-ProbeLine ("cutover-in-progress: yes runId={0} ended-at={1} age={2:N0}m within={3}m" -f `
                $runId, $at.ToString('o'), [Math]::Max(0, $ageMinutes), $WindowMinutes)
        exit 3
    }
    Write-ProbeLine ("cutover-in-progress: no (last cutover {0} ended {1:N0}m ago, outside {2}m)" -f `
            $runId, $ageMinutes, $WindowMinutes)
    exit 0
}

Write-ProbeLine ("cutover-in-progress: no (within {0}m)" -f $WindowMinutes)
exit 0
