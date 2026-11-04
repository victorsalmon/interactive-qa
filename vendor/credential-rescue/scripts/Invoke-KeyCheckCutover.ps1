#Requires -Version 7.0
<#
.SYNOPSIS
    The cutover sequence Key Check delegates to: Salmon switch, then Paseo
    repair, then verify that three surfaces agree.

.DESCRIPTION
    Key Check must not perform the cutover in its own process. The Paseo repair
    runs `paseo restart`, which ends every Paseo-hosted session - including the
    Key Check session that asked for the rescue. So the watch creates THIS
    script outside its own process tree (Win32_Process.Create) and reads the
    outcome file it writes.

    The sequence is fixed and ordered, and the destructive step is LAST:

        1. Switch-OpencodeGoKey.ps1 -KeyNumber <n>
             the Salmon track: seam activeKey, User OPENCODE_GO_KEY /
             OPENCODE_API_KEY, auth.json, ~/.machine/config.json
        2. verify the TWO non-Paseo surfaces (seam activeKey, User key hash)
        3. write the outcome { applied: true, verified: 'pending',
             restartPending: true }  <- before anything destructive
        4. Repair-Paseo.ps1 -KeyNumber <n>
             the Paseo track: provider env pin, worker restart, its own
             verification and canary. This step may kill even this helper.
        5. re-verify the THREE surfaces and rewrite the outcome as
             verified: true, restartPending: false

    Step 3 is the point of the order: a restart may kill the helper, and a
    killed helper must never look like "nothing happened". The worst case is
    "applied, restart pending" - a fact the next Key Check invocation finishes
    verifying (it re-checks the Paseo pin and only then accepts the cutover).

    A failed step stops the sequence (`applied=false`): a repair on top of a
    half-applied switch only produces split-brain. Exit 4 means nothing usable
    moved; exit 5 means it moved and cannot be proven.

    Step 0 - a partial cutover left by a previous run (`partial-cutover.json`,
    which the Salmon switch writes when its own rollback failed) - is resolved
    BEFORE any fresh switch: the switch is asked to complete the recorded target
    (when it is still this run's key and its canary passes) or to revert to the
    recorded `from` key. A revert is exit 4 (`nothing moved`); a machine that is
    still split is exit 5 (`applied, unproven`).

    Exit codes:
        0  applied and all three surfaces agree
        4  cutover failed (a step did not exit 0, the switch rolled its own
           write back, the recorded partial cutover was reverted, or the helper
           never spawned)
        5  applied but unproven (the Paseo pin disagrees after the repair, or a
           partial-cutover marker is still unresolved)

    SECURITY: nothing here prints, logs, or writes a key value. Keys are named
    by number; comparisons are ordinal equality inside this process, and the
    outcome carries only GO<n> labels.

.PARAMETER KeyNumber
    The pool key to activate (1-9).

.PARAMETER OutcomePath
    Where the outcome JSON is written. Default
    ~/.machine/state/key-check/<runId>-cutover.json. The watch polls this file,
    so it is written even when a step fails.

.PARAMETER RunId
    The Key Check run id this cutover belongs to. Default: now.

.PARAMETER SwitchScript
    Override the Salmon switch (default Switch-OpencodeGoKey.ps1). Test seam.

.PARAMETER RepairScript
    Override the Paseo repair (default Repair-Paseo.ps1). Test seam.

.PARAMETER TimeoutSeconds
    Per-step wall-clock budget. Default 300. A step that overruns is killed and
    reported as exit 124, never as a pass.

.PARAMETER SeamPath
    The cutover seam to verify (default ../assets/opencode-go-cutover.json).
    Test seam.

.PARAMETER KeyValuesFile
    Test seam: { "inUse": "<value>", "keys": { "GO1": "<value>" } } instead of
    the Machine/User OPENCODE_GO<n>_KEY environment. Values are never printed.

.PARAMETER PaseoConfig
    The Paseo config whose provider pin is verified. Default
    ~/.paseo/config.json. Test seam.

.PARAMETER PartialMarkerPath
    The partial-application marker the Salmon switch leaves when a rollback
    failed: ~/.machine/state/key-check/partial-cutover.json. When it exists, a
    fresh switch is refused and the recorded cutover is completed or reverted
    first. Test seam.

.PARAMETER RosterScript
    Override the roster capture (default Capture-KeyCheckRoster.ps1). Test seam.

.PARAMETER ResumeScript
    Override the roster resume (default Resume-KeyCheckRoster.ps1). Test seam.

.PARAMETER WitnessScript
    Override the witness (default Invoke-KeyCheckWitness.ps1). Test seam.

.PARAMETER RosterPath
    Where the roster is written. Default `<outcome dir>\<runId>-roster.json`.

.PARAMETER NoRoster
    Skip the roster capture, the resume pass and the witness. Test seam.

.PARAMETER AgentListFile
    Test seam, passed to the roster capture and the resume pass.

.PARAMETER AgentsDir
    Test seam, passed to the roster capture and the resume pass.

.PARAMETER SendScript
    Test seam, passed to the resume pass instead of `paseo send`.

.PARAMETER AuditPath
    The audit trail the roster/witness failure lines go to. Default
    ~/.machine/logs/keycheck.jsonl.

.PARAMETER MarkerPath
    The cutover-in-progress marker: `{runId, startedAt, phase, host}`, written
    BEFORE the switch moves any surface and removed when the cutover ends -
    verified or failed. A backstop (a scheduled agent, a Hub revived by a
    watchdog) reads it with `Test-CutoverInProgress.ps1` and stands down
    instead of inheriting the role. Default `<outcome dir>/cutover-in-progress.json`.
    A helper killed by the restart leaves the marker behind for the post-cutover
    recovery to adopt and clear.

.PARAMETER KillWindowPath
    The destructive-step window: `{runId, startedAt, endedAt}`, written around
    the Paseo repair so `Stamp-InterruptedGates.ps1` can mark every gate run
    modified inside it as killed by the cutover. Default
    `<outcome dir>/cutover-kill-window.json` (a per-run sibling is written too).

.PARAMETER RecoveryScript
    Override the post-cutover recovery (default Invoke-CutoverRecovery.ps1).
    Test seam.

.EXAMPLE
    pwsh -File Invoke-KeyCheckCutover.ps1 -KeyNumber 3 -RunId 20261102-101500
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateRange(1, 9)]
    [int]$KeyNumber,
    [string]$OutcomePath = '',
    [string]$RunId = '',
    [string]$SwitchScript = '',
    [string]$RepairScript = '',
    [int]$TimeoutSeconds = 300,
    [string]$SeamPath = '',
    [string]$KeyValuesFile = '',
    [string]$PaseoConfig = '',
    [string]$PartialMarkerPath = '',
    [string]$RosterScript = '',
    [string]$ResumeScript = '',
    [string]$WitnessScript = '',
    [string]$RosterPath = '',
    [switch]$NoRoster,
    [string]$AgentListFile = '',
    [string]$AgentsDir = '',
    [string]$SendScript = '',
    [string]$AuditPath = '',
    [string]$MarkerPath = '',
    [string]$KillWindowPath = '',
    [string]$RecoveryScript = ''
)

$ErrorActionPreference = 'Stop'

$scriptRoot = $PSScriptRoot
. (Join-Path $scriptRoot 'lib\PaseoCommon.ps1')
. (Join-Path $scriptRoot 'lib\CutoverRecovery.ps1')
. (Join-Path $scriptRoot '..\..\aws\scripts\SecretFingerprint.ps1')

if ([string]::IsNullOrWhiteSpace($RunId)) { $RunId = (Get-Date).ToString('yyyyMMdd-HHmmss') }
if ([string]::IsNullOrWhiteSpace($SwitchScript)) { $SwitchScript = Join-Path $scriptRoot 'Switch-OpencodeGoKey.ps1' }
if ([string]::IsNullOrWhiteSpace($RepairScript)) { $RepairScript = Join-Path $scriptRoot 'Repair-Paseo.ps1' }
if ([string]::IsNullOrWhiteSpace($RosterScript)) { $RosterScript = Join-Path $scriptRoot 'Capture-KeyCheckRoster.ps1' }
if ([string]::IsNullOrWhiteSpace($ResumeScript)) { $ResumeScript = Join-Path $scriptRoot 'Resume-KeyCheckRoster.ps1' }
if ([string]::IsNullOrWhiteSpace($WitnessScript)) { $WitnessScript = Join-Path $scriptRoot 'Invoke-KeyCheckWitness.ps1' }
if ([string]::IsNullOrWhiteSpace($RecoveryScript)) { $RecoveryScript = Join-Path $scriptRoot 'Invoke-CutoverRecovery.ps1' }
if ([string]::IsNullOrWhiteSpace($SeamPath)) { $SeamPath = Join-Path $scriptRoot '..\assets\opencode-go-cutover.json' }
if ([string]::IsNullOrWhiteSpace($PaseoConfig)) { $PaseoConfig = Join-Path $env:USERPROFILE '.paseo\config.json' }
if ([string]::IsNullOrWhiteSpace($AuditPath)) { $AuditPath = Join-Path $env:USERPROFILE '.machine\logs\keycheck.jsonl' }
if ([string]::IsNullOrWhiteSpace($PartialMarkerPath)) {
    $PartialMarkerPath = Join-Path (Join-Path $env:USERPROFILE '.machine\state\key-check') 'partial-cutover.json'
}
if ([string]::IsNullOrWhiteSpace($OutcomePath)) {
    $OutcomePath = Join-Path (Join-Path $env:USERPROFILE '.machine\state\key-check') "$RunId-cutover.json"
}
$outcomeDir = Split-Path -Parent $OutcomePath
if ([string]::IsNullOrWhiteSpace($RosterPath)) { $RosterPath = Join-Path $outcomeDir "$RunId-roster.json" }
$witnessPath = Join-Path $outcomeDir "witness-$RunId.json"
if ([string]::IsNullOrWhiteSpace($MarkerPath)) { $MarkerPath = Join-Path $outcomeDir 'cutover-in-progress.json' }
if ([string]::IsNullOrWhiteSpace($KillWindowPath)) { $KillWindowPath = Join-Path $outcomeDir 'cutover-kill-window.json' }
$killWindowRunPath = Join-Path $outcomeDir "cutover-kill-window-$RunId.json"

$targetName = "OPENCODE_GO${KeyNumber}_KEY"
$targetLabel = "GO$KeyNumber"
$expected = [ordered]@{ seam = $targetName; user = $targetLabel; pin = $targetLabel }

# --- fixture key values (test seam); the live path reads Machine -> User env ---
$keyMap = $null
$fixtureInUse = ''
$fixtureUsed = $false
if ($KeyValuesFile) {
    if (Test-Path -LiteralPath $KeyValuesFile) {
        $kv = Get-Content -LiteralPath $KeyValuesFile -Raw | ConvertFrom-Json
        $keyMap = @{}
        foreach ($p in $kv.keys.PSObject.Properties) { $keyMap[$p.Name] = [string]$p.Value }
        if ($kv.PSObject.Properties['inUse']) { $fixtureInUse = [string]$kv.inUse }
        $fixtureUsed = $true
    }
}

function Get-CutoverPoolLabel {
    <#
    .SYNOPSIS
        GO<n> / no-pool-match for a value. Never returns or prints the value.
    #>
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return 'no-pool-match' }
    if ($keyMap) {
        foreach ($name in ($keyMap.Keys | Sort-Object)) {
            if (Test-SecretEqual -A ([string]$keyMap[$name]) -B $Value) {
                if ($name -match '^GO(\d+)$') { return "GO$($Matches[1])" }
            }
        }
        return 'no-pool-match'
    }
    return (Get-PoolMatchLabel -KeyValue $Value)
}

function Read-CutoverSeamActiveKey {
    if (-not (Test-Path -LiteralPath $SeamPath)) { return '<seam-missing>' }
    try {
        $seam = Get-Content -LiteralPath $SeamPath -Raw | ConvertFrom-Json
        return [string]$seam.activeKey
    } catch {
        return '<seam-unreadable>'
    }
}

function Read-CutoverUserKey {
    if ($fixtureUsed) { return $fixtureInUse }
    foreach ($scope in @('User', 'Process')) {
        $v = [Environment]::GetEnvironmentVariable('OPENCODE_GO_KEY', $scope)
        if (-not [string]::IsNullOrWhiteSpace($v)) { return $v }
    }
    return ''
}

function Read-CutoverPaseoPin {
    # The repair pins agents.providers.opencode.env. Older configs may use a
    # differently-named provider entry, so fall back to any provider that
    # carries an OPENCODE_GO_KEY env value before reporting "no pin".
    foreach ($provider in @('opencode', 'opencode-go')) {
        $v = Get-PaseoProviderEnvValue -Provider $provider -EnvName 'OPENCODE_GO_KEY' -ConfigPath $PaseoConfig
        if (-not [string]::IsNullOrWhiteSpace($v)) { return $v }
    }
    if (Test-Path -LiteralPath $PaseoConfig) {
        try {
            $cfg = Get-Content -LiteralPath $PaseoConfig -Raw | ConvertFrom-Json
            foreach ($p in $cfg.agents.providers.PSObject.Properties) {
                $envBlock = $p.Value.PSObject.Properties['env']
                if (-not $envBlock -or $null -eq $envBlock.Value) { continue }
                $hit = $envBlock.Value.PSObject.Properties | Where-Object Name -IEQ 'OPENCODE_GO_KEY' | Select-Object -First 1
                if ($hit -and -not [string]::IsNullOrWhiteSpace([string]$hit.Value)) { return [string]$hit.Value }
            }
        } catch { }
    }
    return ''
}

function Invoke-CutoverStep {
    <#
    .SYNOPSIS
        Run one step script with a wall-clock budget; never throws on failure.
    #>
    param([string]$Name, [string]$Path, [int]$TimeoutSeconds = 300, [string[]]$ExtraArgs = @())

    $step = [ordered]@{
        name     = $Name
        script   = (Split-Path -Leaf $Path)
        exitCode = -1
        ok       = $false
        detail   = ''
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        $step.detail = 'script not found'
        return [pscustomobject]$step
    }

    $stamp = [guid]::NewGuid().ToString('N')
    $outFile = Join-Path ([System.IO.Path]::GetTempPath()) "kc-cutover-$stamp.out"
    $errFile = Join-Path ([System.IO.Path]::GetTempPath()) "kc-cutover-$stamp.err"
    $proc = $null
    $argList = @('-NoProfile', '-File', $Path, '-KeyNumber', "$KeyNumber") + @($ExtraArgs)
    try {
        $proc = Start-Process -FilePath (Join-Path $PSHOME 'pwsh.exe') `
            -ArgumentList $argList `
            -PassThru -WindowStyle Hidden -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    } catch {
        $step.detail = "spawn-failed: $($_.Exception.Message)"
        return [pscustomobject]$step
    }

    if (-not $proc.WaitForExit([Math]::Max(1, $TimeoutSeconds) * 1000)) {
        try { $proc.Kill() } catch { }
        $step.exitCode = 124
        $step.detail = "timeout after ${TimeoutSeconds}s"
    } else {
        $step.exitCode = [int]$proc.ExitCode
    }

    $lines = @()
    foreach ($file in @($outFile, $errFile)) {
        if (Test-Path -LiteralPath $file) {
            $lines += @(Get-Content -LiteralPath $file -ErrorAction SilentlyContinue | Where-Object { $_.Trim() })
            Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
        }
    }
    if ($lines.Count -gt 0) {
        $last = [string]$lines[-1]
        if ($last.Length -gt 200) { $last = $last.Substring(0, 200) }
        if (-not $step.detail) { $step.detail = $last.Trim() }
    }
    $step.ok = ($step.exitCode -eq 0)
    return [pscustomobject]$step
}

function Write-CutoverAudit {
    param($Entry)
    $dir = Split-Path -Parent $AuditPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
    Add-Content -LiteralPath $AuditPath -Value ($Entry | ConvertTo-Json -Compress) -Encoding utf8NoBOM
}

function Exit-Cutover {
    <#
    .SYNOPSIS
        Leave the sequence, always releasing the marker. A cutover is over
        whether it worked or not; a marker left behind by a live helper would
        block every backstop for a cutover that is not running.
    #>
    param([int]$Code)
    $null = Remove-CutoverMarkerFile -Path $MarkerPath
    exit $Code
}

function Set-CutoverPhase {
    <#
    .SYNOPSIS
        Advance the in-progress marker, preserving the original startedAt so
        the window is the cutover's, not the last phase's.
    #>
    param([string]$Phase)
    $existing = Read-CutoverJsonFile -Path $MarkerPath
    $startedAt = ''
    if ($null -ne $existing -and $existing.PSObject.Properties['runId'] -and [string]$existing.runId -eq $RunId -and
        $existing.PSObject.Properties['startedAt']) {
        $startedAt = [string]$existing.startedAt
    }
    $null = Write-CutoverMarkerFile -Path $MarkerPath -RunId $RunId -Phase $Phase -StartedAt $startedAt
}

function Start-CutoverKillWindow {
    <#
    .SYNOPSIS
        Open the destructive-step window BEFORE the Paseo repair, so a helper
        killed by the restart still leaves a bounded window to stamp gates with.
    #>
    $payload = [ordered]@{
        version   = 1
        runId     = $RunId
        startedAt = (Get-Date).ToString('o')
        endedAt   = $null
    }
    foreach ($path in @($KillWindowPath, $killWindowRunPath)) {
        $dir = Split-Path -Parent $path
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
        Set-Content -LiteralPath $path -Value ($payload | ConvertTo-Json -Depth 4) -Encoding utf8NoBOM
    }
}

function Stop-CutoverKillWindow {
    <#
    .SYNOPSIS
        Close the window once the repair returns. A helper killed before this
        runs leaves endedAt empty; the post-cutover recovery then treats the
        window as open to its own start, which is the honest bound.
    #>
    foreach ($path in @($KillWindowPath, $killWindowRunPath)) {
        $existing = Read-CutoverJsonFile -Path $path
        if ($null -eq $existing) { continue }
        $payload = [ordered]@{
            version   = 1
            runId     = $(if ($existing.PSObject.Properties['runId']) { [string]$existing.runId } else { $RunId })
            startedAt = $(if ($existing.PSObject.Properties['startedAt']) { [string]$existing.startedAt } else { (Get-Date).ToString('o') })
            endedAt   = (Get-Date).ToString('o')
        }
        Set-Content -LiteralPath $path -Value ($payload | ConvertTo-Json -Depth 4) -Encoding utf8NoBOM
    }
}

function Invoke-CutoverAux {
    <#
    .SYNOPSIS
        Run one companion script (roster capture / resume / witness) with its own
        argument list. Never throws, never changes the cutover's exit code: these
        steps are recovery aids, not gates.
    #>
    param([string]$Name, [string]$Path, [string[]]$Arguments = @())

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-CutoverAudit -Entry ([ordered]@{
                ts = (Get-Date).ToString('s'); kind = "$Name-failed"; runId = $RunId
                reason = 'script not found'; script = (Split-Path -Leaf $Path); at = (Get-Date).ToString('o')
            })
        return [pscustomobject]@{ Name = $Name; Ok = $false; ExitCode = -1; Detail = 'script not found'; Output = '' }
    }

    $stamp = [guid]::NewGuid().ToString('N')
    $outFile = Join-Path ([System.IO.Path]::GetTempPath()) "kc-aux-$stamp.out"
    $errFile = Join-Path ([System.IO.Path]::GetTempPath()) "kc-aux-$stamp.err"
    $proc = $null
    try {
        $proc = Start-Process -FilePath (Join-Path $PSHOME 'pwsh.exe') `
            -ArgumentList (@('-NoProfile', '-File', $Path) + $Arguments) `
            -PassThru -WindowStyle Hidden -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    } catch {
        Write-CutoverAudit -Entry ([ordered]@{
                ts = (Get-Date).ToString('s'); kind = "$Name-failed"; runId = $RunId
                reason = "spawn-failed: $($_.Exception.Message)"; script = (Split-Path -Leaf $Path)
                at = (Get-Date).ToString('o')
            })
        return [pscustomobject]@{ Name = $Name; Ok = $false; ExitCode = -1; Detail = $_.Exception.Message; Output = '' }
    }

    $null = $proc.WaitForExit([Math]::Max(1, $TimeoutSeconds) * 1000)
    $output = ''
    if (Test-Path -LiteralPath $outFile) {
        $output = (Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue)
        Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue
    }
    $errText = ''
    if (Test-Path -LiteralPath $errFile) {
        $errText = (Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue)
        Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue
    }
    $code = if ($proc.HasExited) { [int]$proc.ExitCode } else { 124 }
    if ($code -ne 0 -and -not $proc.HasExited) { try { $proc.Kill() } catch { } }
    # An empty redirect file yields no output at all (not an empty string), so
    # guard before trimming rather than member-calling a null.
    $detailText = if ($null -ne $errText) { ([string]$errText).Trim() } else { '' }
    $outputText = if ($null -ne $output) { ([string]$output).Trim() } else { '' }
    return [pscustomobject]@{
        Name = $Name; Ok = ($code -eq 0); ExitCode = $code
        Detail = $detailText; Output = $outputText
    }
}

function Get-CutoverFromLabel {
    <#
    .SYNOPSIS
        The GO<n> label the machine is leaving, read before the switch runs: the
        partial marker's recorded `from`, else the seam's current activeKey.
    #>
    if (Test-Path -LiteralPath $PartialMarkerPath) {
        try {
            $marker = Get-Content -LiteralPath $PartialMarkerPath -Raw | ConvertFrom-Json
            if ($marker.PSObject.Properties['from'] -and [string]$marker.from -match '^GO(\d+)$') { return "GO$($Matches[1])" }
        } catch { }
    }
    $seamName = Read-CutoverSeamActiveKey
    if ($seamName -match '^OPENCODE_GO(\d+)_KEY$') { return "GO$($Matches[1])" }
    return ''
}

function Get-CutoverAuxFirstLine {
    <#
    .SYNOPSIS
        The first non-empty line of a companion script's stdout, for a log line.
    #>
    param([string]$Text)
    $lines = @(([string]$Text) -split "`n" | Where-Object { $_.Trim() })
    if ($lines.Count -eq 0) { return '' }
    return [string]$lines[0]
}

function Invoke-CutoverRosterCapture {
    <#
    .SYNOPSIS
        Snapshot the live agents BEFORE anything destructive, and record the path
        in the outcome so whichever process survives can nudge them.
    #>
    if ($NoRoster) { return '' }
    $fromLabel = Get-CutoverFromLabel
    $fromNumber = if ($fromLabel -match '^GO(\d+)$') { [int]$Matches[1] } else { 0 }
    $captureArgs = @(
        '-RunId', $RunId, '-FromKeyNumber', "$fromNumber", '-ToKeyNumber', "$KeyNumber", '-OutPath', $RosterPath
    )
    if ($AgentListFile) { $captureArgs += @('-AgentListFile', $AgentListFile) }
    if ($AgentsDir) { $captureArgs += @('-AgentsDir', $AgentsDir) }
    $capture = Invoke-CutoverAux -Name 'roster-capture' -Path $RosterScript -Arguments $captureArgs
    if (-not $capture.Ok -or -not (Test-Path -LiteralPath $RosterPath)) {
        Write-CutoverAudit -Entry ([ordered]@{
                ts = (Get-Date).ToString('s'); kind = 'roster-capture-failed'; runId = $RunId
                reason = $(if ($capture.Detail) { $capture.Detail } else { "exit $($capture.ExitCode)" })
                rosterPath = $RosterPath; at = (Get-Date).ToString('o')
            })
        Write-Host ("  roster  capture failed (exit {0}); the cutover continues" -f $capture.ExitCode)
        return ''
    }
    Write-Host ("  roster  captured {0}" -f (Get-CutoverAuxFirstLine -Text $capture.Output))
    return $RosterPath
}

function Invoke-CutoverRecovery {
    <#
    .SYNOPSIS
        After a proven cutover: nudge the roster and witness the result. Two call
        sites are safe because the pass is idempotent per runId+agentId.
    #>
    param([string]$RosterFile)
    $result = [ordered]@{ rosterPath = $RosterFile; witnessPath = ''; witnessVerdict = '' }

    if ($RosterFile -and (Test-Path -LiteralPath $RosterFile)) {
        $resumeArgs = @(
            '-RosterPath', $RosterFile, '-StateDir', $outcomeDir, '-AuditPath', $AuditPath
        )
        if ($AgentListFile) { $resumeArgs += @('-AgentListFile', $AgentListFile) }
        if ($AgentsDir) { $resumeArgs += @('-AgentsDir', $AgentsDir) }
        if ($SendScript) { $resumeArgs += @('-SendScript', $SendScript) }
        $resume = Invoke-CutoverAux -Name 'roster-resume' -Path $ResumeScript -Arguments $resumeArgs
        if (-not $resume.Ok) {
            Write-CutoverAudit -Entry ([ordered]@{
                    ts = (Get-Date).ToString('s'); kind = 'roster-resume-failed'; runId = $RunId
                    reason = $(if ($resume.Detail) { $resume.Detail } else { "exit $($resume.ExitCode)" })
                    rosterPath = $RosterFile; at = (Get-Date).ToString('o')
                })
            Write-Host ("  resume  failed (exit {0}); the cutover outcome is unaffected" -f $resume.ExitCode)
        } else {
            Write-Host ("  resume  {0}" -f (Get-CutoverAuxFirstLine -Text $resume.Output))
        }
    }

    $witness = Invoke-CutoverAux -Name 'witness' -Path $WitnessScript -Arguments @(
        '-RunId', $RunId, '-OutcomePath', $OutcomePath, '-StateDir', $outcomeDir, '-AuditPath', $AuditPath
    )
    if (Test-Path -LiteralPath $witnessPath) {
        try {
            $report = Get-Content -LiteralPath $witnessPath -Raw | ConvertFrom-Json
            $result.witnessPath = $witnessPath
            $result.witnessVerdict = [string]$report.verdict
        } catch { }
    }
    if ($witness.ExitCode -notin @(0, 1) -or -not $result.witnessPath) {
        Write-CutoverAudit -Entry ([ordered]@{
                ts = (Get-Date).ToString('s'); kind = 'witness-failed'; runId = $RunId
                reason = $(if ($witness.Detail) { $witness.Detail } else { "exit $($witness.ExitCode)" })
                outcomePath = $OutcomePath; at = (Get-Date).ToString('o')
            })
        Write-Host ("  witness failed (exit {0}); the cutover outcome is unaffected" -f $witness.ExitCode)
    } else {
        Write-Host ("  witness {0}" -f $result.witnessVerdict)
    }
    return $result
}

# --- the ordered cutover sequence -------------------------------------------
# The destructive action is LAST, and the evidence is on disk before it runs:#
#   1. switch            Salmon track (seam, User env, auth.json, config.json)
#   2. verify 2 surfaces seam + User env (the NON-Paseo surfaces)
#   3. write outcome     applied=true, verified='pending', restartPending=true
#   4. repair            Paseo pin + worker restart (may kill even this helper)
#   5. re-verify 3       rewrite the same file as verified=true / pending:false
#
# The restart may kill the helper, so step 3 is what turns the worst case from
# silence into a fact the next invocation can finish: "applied, restart pending".
# A killed helper must never look like "nothing happened".
Write-Output "cutover ${targetName}: starting (runId $RunId)"

function Write-CutoverOutcome {
    param(
        [bool]$Applied,
        $Verified,
        [string]$Reason,
        [bool]$RestartPending,
        [object[]]$Steps = @(),
        [object[]]$Surfaces = @(),
        [string]$RosterFile = '',
        [string]$WitnessFile = '',
        [string]$WitnessVerdict = ''
    )
    $payload = [ordered]@{
        version        = 1
        runId          = $RunId
        keyNumber      = $KeyNumber
        target         = $targetName
        at             = (Get-Date).ToString('o')
        applied        = $Applied
        verified       = $Verified
        restartPending = $RestartPending
        reason         = $Reason
        steps          = @($Steps)
        surfaces       = @($Surfaces)
        rosterPath     = $RosterFile
        witnessPath    = $WitnessFile
        witnessVerdict = $WitnessVerdict
    }
    $dir = Split-Path -Parent $OutcomePath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
    Set-Content -LiteralPath $OutcomePath -Value ($payload | ConvertTo-Json -Depth 8) -Encoding utf8NoBOM
    return $payload
}

function Get-CutoverSurfaces {
    param([switch]$IncludePaseoPin)
    $seamActual = Read-CutoverSeamActiveKey
    $userActual = Get-CutoverPoolLabel -Value (Read-CutoverUserKey)
    $list = @(
        [pscustomobject]@{ name = 'seam'; expected = $expected.seam; actual = $seamActual; ok = ($seamActual -eq $expected.seam) }
        [pscustomobject]@{ name = 'user-env'; expected = $expected.user; actual = $userActual; ok = ($userActual -eq $expected.user) }
    )
    if ($IncludePaseoPin) {
        $pinActual = Get-CutoverPoolLabel -Value (Read-CutoverPaseoPin)
        $list += [pscustomobject]@{ name = 'paseo-pin'; expected = $expected.pin; actual = $pinActual; ok = ($pinActual -eq $expected.pin) }
    }
    return $list
}

function Show-CutoverSurfaces {
    param([object[]]$Surfaces)
    foreach ($surface in $Surfaces) {
        Write-Output ("  {0,-10} expected {1}, found {2} ({3})" -f $surface.name, $surface.expected, $surface.actual, $(if ($surface.ok) { 'ok' } else { 'DISAGREES' }))
    }
}

$steps = @()
$switchOk = $false

# --- the roster, BEFORE anything destructive --------------------------------
# A restart strands every agent that was mid-turn - lanes AND Hubs. This
# snapshot is what the surviving process nudges; a failure here is audited and
# never fails the cutover.
$rosterFile = Invoke-CutoverRosterCapture

# --- claim the machine BEFORE the switch touches any surface ----------------
# A backstop that runs inside the cutover window cannot see the restart, so it
# inherits the role the cutover just vacated. The marker is the fact it reads
# (Test-CutoverInProgress.ps1); it is written here, before the first write, and
# released on every exit path below.
Set-CutoverPhase -Phase 'switch'
Write-Output "  marker  cutover-in-progress written: $MarkerPath"

# --- 0. a partial cutover from a previous run owns the machine --------------
# A marker means surfaces disagree (the Salmon switch wrote some of them and its
# rollback failed). Starting a fresh switch on top of that split-brains the
# machine, so the recorded cutover is resolved FIRST: completed when its target
# is still this run's key and its canary passes, reverted to the recorded `from`
# key otherwise. The switch owns both mechanics (it owns the surfaces) and
# clears the marker; this helper reads the decision off its exit code.
$switchStep = $null
if (Test-Path -LiteralPath $PartialMarkerPath) {
    Write-Output "  partial-cutover marker found: $PartialMarkerPath"
    Write-Output '  refusing a fresh switch until the recorded cutover is completed or reverted'
    $resumeStep = Invoke-CutoverStep -Name 'resume' -Path $SwitchScript -TimeoutSeconds $TimeoutSeconds -ExtraArgs @('-ResumePartial')
    $steps += $resumeStep
    Write-Output ("  resume  exit {0}: {1}" -f $resumeStep.exitCode, $resumeStep.detail)

    if ($resumeStep.exitCode -ne 0) {
        if ($resumeStep.exitCode -eq 6 -or (Test-Path -LiteralPath $PartialMarkerPath)) {
            # Still split: the resume could neither complete nor revert.
            $surfaces = Get-CutoverSurfaces
            Show-CutoverSurfaces -Surfaces $surfaces
            $null = Write-CutoverOutcome -Applied $true -Verified $false -Reason 'partial-cutover' -RestartPending $false `
                -Steps $steps -Surfaces $surfaces
            Write-Output ("cutover {0}: applied=True verified=False reason=partial-cutover (marker left in place)" -f $targetName)
            Exit-Cutover 5
        }
        # Reverted to the recorded `from` key: nothing usable moved.
        $surfaces = Get-CutoverSurfaces
        Show-CutoverSurfaces -Surfaces $surfaces
        $null = Write-CutoverOutcome -Applied $false -Verified $false -Reason 'partial-reverted' -RestartPending $false `
            -Steps $steps -Surfaces $surfaces
        Write-Output ("cutover {0}: applied=False verified=False reason=partial-reverted" -f $targetName)
        Exit-Cutover 4
    }
    Write-Output '  partial cutover completed; continuing with the Paseo track'
    $switchOk = $true
}
else {
    $switchStep = Invoke-CutoverStep -Name 'switch' -Path $SwitchScript -TimeoutSeconds $TimeoutSeconds
    $steps += $switchStep
    Write-Output ("  switch  exit {0}: {1}" -f $switchStep.exitCode, $switchStep.detail)

    if (-not $switchStep.ok) {
        if ($switchStep.exitCode -eq 6 -or (Test-Path -LiteralPath $PartialMarkerPath)) {
            # The switch wrote surfaces and could not roll them back. That is
            # applied-but-unproven, not "nothing moved": the next invocation
            # completes or reverts it via the marker.
            [Console]::Error.WriteLine('  the Salmon switch left a partial-cutover marker; the next invocation completes or reverts it')
            $surfaces = Get-CutoverSurfaces
            Show-CutoverSurfaces -Surfaces $surfaces
            $null = Write-CutoverOutcome -Applied $true -Verified $false -Reason 'partial-cutover' -RestartPending $false `
                -Steps $steps -Surfaces $surfaces
            Write-Output ("cutover {0}: applied=True verified=False reason=partial-cutover" -f $targetName)
            Exit-Cutover 5
        }
        # A repair on top of a failed switch only split-brains the machine, so the
        # sequence stops here and the outcome says nothing moved.
        Write-Output '  repair  skipped: the switch did not apply, so a repair would only split-brain the machine'
        $preSurfaces = Get-CutoverSurfaces
        Show-CutoverSurfaces -Surfaces $preSurfaces
        $null = Write-CutoverOutcome -Applied $false -Verified $false -Reason 'switch-failed' -RestartPending $false `
            -Steps $steps -Surfaces $preSurfaces
        Write-Output ("cutover {0}: applied=False verified=False reason=switch-failed" -f $targetName)
        Exit-Cutover 4
    }
    $switchOk = $true
}

# --- 2. the two non-Paseo surfaces, BEFORE anything destructive --------------
$preSurfaces = Get-CutoverSurfaces
Show-CutoverSurfaces -Surfaces $preSurfaces
$preDisagrees = @($preSurfaces | Where-Object { -not $_.ok })

if ($preDisagrees.Count -gt 0) {
    # The switch claimed success but its own surfaces disagree: nothing usable
    # moved, so the repair is refused and this is a failure (4), not unproven.
    Write-Output '  repair  skipped: the switch did not move the seam/User surfaces, so a repair would split-brain the machine'
    $null = Write-CutoverOutcome -Applied $false -Verified $false -Reason 'surface-disagrees' -RestartPending $false `
        -Steps $steps -Surfaces $preSurfaces
    Write-Output ("cutover {0}: applied=False verified=False reason=surface-disagrees" -f $targetName)
    Exit-Cutover 4
}

# --- 3. the pre-restart outcome: applied, verification still pending --------
$null = Write-CutoverOutcome -Applied $true -Verified 'pending' -Reason 'restart-pending' -RestartPending $true `
    -Steps $steps -Surfaces $preSurfaces -RosterFile $rosterFile
Write-Output "  outcome written (verified=pending, restartPending=true): $OutcomePath"

# --- 4. the destructive step, last ------------------------------------------
# The kill window opens HERE: everything modified inside it was interrupted by
# the restart, and Stamp-InterruptedGates.ps1 marks those gate runs so a killed
# measurement can never be read as red (or as a pass).
Set-CutoverPhase -Phase 'repair'
Start-CutoverKillWindow
$repairStep = Invoke-CutoverStep -Name 'repair' -Path $RepairScript -TimeoutSeconds $TimeoutSeconds
Stop-CutoverKillWindow
$steps += $repairStep
Write-Output ("  repair  exit {0}: {1}" -f $repairStep.exitCode, $repairStep.detail)

$applied = [bool]($switchOk -and $repairStep.ok)
$reason = if ($applied) { '' } else { 'paseo-repair-failed' }

# --- 5. verify all three surfaces and rewrite the outcome -------------------
$surfaces = Get-CutoverSurfaces -IncludePaseoPin
$verified = ($applied -and -not ($surfaces | Where-Object { -not $_.ok }))
if (-not $reason -and -not $verified) { $reason = 'surface-disagrees' }
if (-not $reason) { $reason = 'verified' }

Show-CutoverSurfaces -Surfaces $surfaces

# --- 6. after a proven cutover: nudge the roster, then witness --------------
# The nudge is sent by whichever process survives, so the watch's resume path
# may run this same pass - idempotent per runId+agentId.
$recovery = [ordered]@{ rosterPath = $rosterFile; witnessPath = ''; witnessVerdict = '' }
if ($verified -and -not $NoRoster) {
    $recovery = Invoke-CutoverRecovery -RosterFile $rosterFile
}

# --- 6b. reconcile the machine: backstops, dead leases, killed gates, report -
# Recovery is keyed by runId, so the second caller for the same cutover is a
# no-op. A failure here is audited and never changes the cutover's exit code.
# A roster with no agents means the capture found nothing to reconcile (or a
# seam stood in for it), so the pass is skipped rather than reading this
# machine's live registry and lease store.
$rosterAgentCount = 0
if ($rosterFile -and (Test-Path -LiteralPath $rosterFile)) {
    try {
        $rosterPayload = Get-Content -LiteralPath $rosterFile -Raw | ConvertFrom-Json
        if ($rosterPayload.PSObject.Properties['agents']) { $rosterAgentCount = @($rosterPayload.agents).Count }
    } catch { $rosterAgentCount = 0 }
}
if (-not $NoRoster -and $rosterAgentCount -gt 0) {
    Set-CutoverPhase -Phase 'recovery'
    $reconcileArgs = @(
        '-RunId', $RunId, '-StateDir', $outcomeDir,
        '-RosterPath', $rosterFile, '-AuditPath', $AuditPath,
        '-KillWindowPath', $KillWindowPath, '-MarkerPath', $MarkerPath
    )
    if ($SendScript) { $reconcileArgs += @('-SendScript', $SendScript) }
    $reconcile = Invoke-CutoverAux -Name 'cutover-reconcile' -Path $RecoveryScript -Arguments $reconcileArgs
    if (-not $reconcile.Ok) {
        Write-CutoverAudit -Entry ([ordered]@{
                ts = (Get-Date).ToString('s'); kind = 'cutover-reconcile-failed'; runId = $RunId
                reason = $(if ($reconcile.Detail) { $reconcile.Detail } else { "exit $($reconcile.ExitCode)" })
                at = (Get-Date).ToString('o')
            })
        Write-Host ("  reconcile failed (exit {0}); the cutover outcome is unaffected" -f $reconcile.ExitCode)
    } else {
        Write-Host ("  reconcile {0}" -f (Get-CutoverAuxFirstLine -Text $reconcile.Output))
    }
}

$null = Write-CutoverOutcome -Applied $applied -Verified ([bool]$verified) -Reason $reason -RestartPending $false `
    -Steps $steps -Surfaces $surfaces -RosterFile $rosterFile `
    -WitnessFile ([string]$recovery.witnessPath) -WitnessVerdict ([string]$recovery.witnessVerdict)
Write-Output ("cutover {0}: applied={1} verified={2} pending=False reason={3}" -f $targetName, $applied, $verified, $reason)

if (-not $applied) { Exit-Cutover 4 }
if (-not $verified) { Exit-Cutover 5 }
Exit-Cutover 0

