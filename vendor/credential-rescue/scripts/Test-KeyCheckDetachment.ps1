#Requires -Version 7.0
<#
.SYNOPSIS
    Measure whether a helper launched the way Key Check launches it actually
    survives its launching process being killed.

.DESCRIPTION
    The cutover helper should outlive a `paseo restart`, which kills the agent's
    whole process tree. Whether an ordinary child survives that depends on the
    host: Windows does not cascade kills by itself, but an agent host can wrap
    its tree in a Job Object, and a `Start-Process` child may then inherit
    membership.

    This probe measures ONE chain - the one it runs in:

        1. create a marker-writing child through the SAME mechanism the cutover
           uses (Win32_Process.Create by default);
        2. force-kill the runner that created it;
        3. wait for the marker.

    `survives: true` means that mechanism escaped the launcher's job object **in
    this chain, on this host**. It is not a universal claim, and it is not proof
    about a real `paseo restart`. On the 2026-11-02 host both mechanisms survived
    in both the plain-shell and the agent-hosted chain, so survivability across
    a real restart remains unproven.

    `-Legacy` measures the `Start-Process` mechanism as a CONTRAST probe - not a
    demonstration that it fails. If it does fail on a host, that says the host
    guards its tree.

    Survival is not what the cutover depends on: the helper writes its outcome
    before the restart and the next invocation finishes the verification, so a
    helper that dies is recovered rather than lost.

    This script kills processes it created itself, which is why it is NOT part
    of the Pester suite. The suite asserts the launch mechanism and its argv;
    this is the live measurement.

    Exit codes: 0 the mechanism survived · 1 it did not · 2 the probe could not
    run.

.PARAMETER Json
    Emit one JSON object (machine-readable) instead of prose.

.PARAMETER Legacy
    Measure the `Start-Process` mechanism instead of Win32_Process.Create.
    Contrast probe only.

.PARAMETER WaitSeconds
    How long to wait for the marker after the kill. Default 15.

.PARAMETER KeepArtifacts
    Leave the temporary directory (marker, child, runner, pid file) in place.

.EXAMPLE
    pwsh -File Test-KeyCheckDetachment.ps1 -Json

.EXAMPLE
    pwsh -File Test-KeyCheckDetachment.ps1 -Legacy
#>
[CmdletBinding()]
param(
    [switch]$Json,
    [switch]$Legacy,
    [int]$WaitSeconds = 15,
    [switch]$KeepArtifacts
)

$ErrorActionPreference = 'Stop'

$scriptRoot = $PSScriptRoot
. (Join-Path $scriptRoot 'lib\KeyCheck.Decision.ps1')
. (Join-Path $scriptRoot 'lib\KeyCheck.State.ps1')

$startedAt = Get-Date
$dir = Join-Path ([System.IO.Path]::GetTempPath()) ("kc-detach-{0}" -f ([guid]::NewGuid().ToString('N')))
$marker = Join-Path $dir 'marker.txt'
$pidFile = Join-Path $dir 'child-pid.txt'
$childPath = Join-Path $dir 'child.ps1'
$runnerPath = Join-Path $dir 'runner.ps1'
$mechanism = if ($Legacy) { 'Start-Process (legacy)' } else { 'Win32_Process.Create' }

function Write-Result {
    param([bool]$Survives, [string]$Detail, [int]$Code, $RunnerPid = 0, $ChildPid = 0, $ElapsedMs = -1, [string]$ChildLauncher = '')
    $result = [ordered]@{
        host             = $env:COMPUTERNAME
        checkedAt        = (Get-Date).ToString('o')
        mechanism        = $mechanism
        childLauncher    = $ChildLauncher
        survives         = $Survives
        runnerPid        = [int]$RunnerPid
        childPid         = [int]$ChildPid
        markerAppearedMs = [int]$ElapsedMs
        detail           = $Detail
        probePid         = $PID
        note             = 'Job-object membership is inherited: this measures ONE chain (the one the probe runs in). Survives=true is not evidence about a real paseo restart. On 2026-11-02 both mechanisms survived in both the plain-shell and agent-hosted chains.'
        artifacts        = $dir
    }
    if ($Json) {
        $result | ConvertTo-Json -Depth 5
    } else {
        Write-Output "detachment probe on $($result.host) at $($result.checkedAt)"
        Write-Output "  mechanism      : $mechanism"
        if ($ChildLauncher) { Write-Output "  child launcher : $ChildLauncher" }
        Write-Output "  runner pid     : $($result.runnerPid) (killed)"
        Write-Output "  child pid      : $($result.childPid)"
        Write-Output "  marker after   : $(if ($ElapsedMs -ge 0) { "$ElapsedMs ms" } else { 'never' })"
        Write-Output "  detail         : $Detail"
        Write-Output "  survives       : $Survives"
        Write-Output "  artifacts      : $dir"
    }
    exit $Code
}

try {
    $null = New-Item -ItemType Directory -Path $dir -Force

    # The child writes its marker 3 s after it starts: late enough that the
    # runner is dead before the marker exists, early enough for a short wait.
    @'
param([string]$Marker)
Start-Sleep -Seconds 3
"survived" | Set-Content -LiteralPath $Marker
'@ | Set-Content -LiteralPath $childPath

    $runnerBody = if ($Legacy) {
        @"
param([string]`$Lib, [string]`$Child, [string]`$Marker, [string]`$PidFile)
`$proc = Start-Process -FilePath (Join-Path `$PSHOME 'pwsh.exe') -ArgumentList @('-NoProfile', '-File', `$Child, '-Marker', `$Marker) -PassThru -WindowStyle Hidden
"Start-Process|`$(`$proc.Id)" | Set-Content -LiteralPath `$PidFile
Start-Sleep -Seconds 60
"@
    } else {
        @"
param([string]`$Lib, [string]`$Child, [string]`$Marker, [string]`$PidFile)
. `$Lib
`$exe = Join-Path `$PSHOME 'pwsh.exe'
`$cmd = @(
    (ConvertTo-KeyCheckCommandLineArg `$exe)
    (ConvertTo-KeyCheckCommandLineArg '-NoProfile')
    (ConvertTo-KeyCheckCommandLineArg '-File')
    (ConvertTo-KeyCheckCommandLineArg `$Child)
    (ConvertTo-KeyCheckCommandLineArg '-Marker')
    (ConvertTo-KeyCheckCommandLineArg `$Marker)
) -join ' '
`$launch = Start-KeyCheckDetachedProcess -CommandLine `$cmd
"`$(`$launch.Method)|`$(`$launch.ProcessId)" | Set-Content -LiteralPath `$PidFile
Start-Sleep -Seconds 60
"@
    }
    Set-Content -LiteralPath $runnerPath -Value $runnerBody

    $lib = Join-Path $scriptRoot 'lib\KeyCheck.State.ps1'
    $runner = Start-Process -FilePath (Join-Path $PSHOME 'pwsh.exe') -PassThru -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-File', $runnerPath, '-Lib', $lib, '-Child', $childPath, '-Marker', $marker, '-PidFile', $pidFile
    )

    $deadline = (Get-Date).AddSeconds([Math]::Max(5, $WaitSeconds))
    while (-not (Test-Path -LiteralPath $pidFile) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100 }
    if (-not (Test-Path -LiteralPath $pidFile)) {
        try { Stop-Process -Id $runner.Id -Force -ErrorAction SilentlyContinue } catch { }
        Write-Result -Survives $false -Code 2 -RunnerPid $runner.Id `
            -Detail 'the runner never reported how it launched the child; nothing to measure'
    }

    $parts = (Get-Content -LiteralPath $pidFile -Raw).Trim() -split '\|'
    $childLauncher = [string]$parts[0]
    $childPid = if ($parts.Count -gt 1) { [int]$parts[1] } else { 0 }

    # The kill this whole probe is about.
    $killedAt = Get-Date
    try { Stop-Process -Id $runner.Id -Force -ErrorAction Stop } catch {
        Write-Result -Survives $false -Code 2 -RunnerPid $runner.Id -ChildPid $childPid -ChildLauncher $childLauncher `
            -Detail "could not kill the runner: $($_.Exception.Message)"
    }

    $deadline = $killedAt.AddSeconds([Math]::Max(5, $WaitSeconds))
    while (-not (Test-Path -LiteralPath $marker) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 200 }

    $survives = Test-Path -LiteralPath $marker
    $elapsed = if ($survives) { [int]((Get-Date) - $killedAt).TotalMilliseconds } else { -1 }
    $detail = if ($survives) {
        "the child created via $childLauncher wrote its marker $elapsed ms after its parent was force-killed"
    } elseif ($childLauncher -ne 'Win32_Process.Create') {
        "the child ($childLauncher) never wrote its marker: this host appears to guard its process tree, so the legacy mechanism did not escape it (this is the contrast case, not a universal result)"
    } else {
        'the child never wrote its marker even though it was created outside the process tree - this host blocks the CIM escape too, so an unattended watch cannot rely on a helper surviving the restart here; the pre-restart outcome is what keeps the cutover recoverable'
    }

    try { if ($childPid -gt 0) { Stop-Process -Id $childPid -Force -ErrorAction SilentlyContinue } } catch { }
    Write-Result -Survives $survives -Code $(if ($survives) { 0 } else { 1 }) -RunnerPid $runner.Id `
        -ChildPid $childPid -ChildLauncher $childLauncher -ElapsedMs $elapsed -Detail $detail
} catch {
    Write-Result -Survives $false -Code 2 -Detail "probe failed: $($_.Exception.Message)"
} finally {
    if (-not $KeepArtifacts -and (Test-Path -LiteralPath $dir)) {
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
