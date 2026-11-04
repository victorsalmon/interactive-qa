#Requires -Version 7.0
<#
.SYNOPSIS
    Credential Rescue Watch — unattended opencode-go key cutover daemon.

.DESCRIPTION
    Watches the ACTIVE opencode-go key against a NEW key. Each tick it canaries
    both; when the active key stops working it performs the credential-rescue
    cutover to the new key, restarts Paseo so helpers respawn, and reports the
    agents that need a "Continue" nudge. Designed to run overnight.

    Companion to Skills/credential-rescue. This script only DETECTS exhaustion
    and performs the automated cutover + Paseo repair; nudging agents'
    "Continue" and final reporting are driven by the watch session (the agent)
    using the Paseo MCP tools, because agent state lives in the running daemon.

    Loop contract:
      0. Snapshot which agents are running now (JSON to the run dir).
      1. Test active key + new key. Both must work at start.
      Repeat every -IntervalSeconds:
      2. Test active + new.
      3. If active FAILED -> run Switch-OpencodeGoKey.ps1 -KeyNumber <New>,
          then Repair-Paseo.ps1 (pin + worker restart), re-canary the new key,
         and exit success so the watch session can nudge agents.
         If new key ALSO failed -> abort loudly (no safe target).
      4. If active OK -> sleep and loop.

.PARAMETER ActiveKeyNumber
    Pool index currently active (the key we watch). Default 3.

.PARAMETER NewKeyNumber
    Pool index to rescue onto. Default 2.

.PARAMETER IntervalSeconds
    Unit of time between tests. Default 3600 (one hour).

.PARAMETER MaxIterations
    Safety bound on loop count. Default 12 (12 hours at 1h).

.PARAMETER RunDir
    Where snapshot/log/state are written. Default
    %TEMP%\opencode\credential-rescue-watch.

.PARAMETER DryRun
    Test only; never perform the cutover.

.EXAMPLE
    pwsh -File Invoke-CredentialRescueWatch.ps1 -ActiveKeyNumber 3 -NewKeyNumber 2
#>
[CmdletBinding()]
param(
    [int]$ActiveKeyNumber = 3,
    [int]$NewKeyNumber = 2,
    [int]$IntervalSeconds = 3600,
    [int]$MaxIterations = 12,
    [int]$CanaryTimeoutSeconds = 60,
    [int]$CanaryRetries = 3,
    [string]$RunDir = (Join-Path $env:TEMP 'opencode\credential-rescue-watch'),
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$PSRoot = $PSScriptRoot
$SkillRoot = Split-Path -Parent $PSRoot
$CredRescue = "$($env:CL_REPOS_ROOT)\cl-common\Skills\credential-rescue"
$Canary = Join-Path $PSRoot 'Test-GoKey.ps1'
$Restart = Join-Path $PSRoot 'Repair-Paseo.ps1'
$Switch = Join-Path $CredRescue 'scripts\Switch-OpencodeGoKey.ps1'
$Cli = $env:OPENCODE_CLI_PATH
if (-not $Cli) { $Cli = "$($env:CL_REPOS_ROOT)\Tools\opencode-standalone\node_modules\.bin\opencode.ps1" }

New-Item -ItemType Directory -Force -Path $RunDir | Out-Null
$logPath = Join-Path $RunDir 'watch.log'
$statePath = Join-Path $RunDir 'state.json'

function Log {
    param([string]$Msg)
    $line = "[{0}] {1}" -f ([datetimeoffset]::Now.ToString('yyyy-MM-dd HH:mm:sszzz')), $Msg
    Write-Output $line
    Add-Content -LiteralPath $logPath -Value $line -Encoding utf8
}

function Test-Key {
    param([int]$Num)
    $out = & pwsh -NoProfile -File $Canary -KeyNumber $Num -OpencodeCli $Cli -TimeoutSeconds $CanaryTimeoutSeconds -MaxRetries $CanaryRetries 2>&1 | Out-String
    $out = $out.Trim()
    # Class token is the first word emitted by Test-GoKey.ps1.
    $class = 'ERROR'
    if ($out -match '^OK\b') { $class = 'OK' }
    elseif ($out -match '^EXHAUSTED\b') { $class = 'EXHAUSTED' }
    elseif ($out -match '^NOT-SUBSCRIBED\b') { $class = 'NOT-SUBSCRIBED' }
    elseif ($out -match '^BUSY\b') { $class = 'BUSY' }
    elseif ($out -match '^TRANSPORT\b') { $class = 'TRANSPORT' }
    elseif ($out -match '^AUTH\b') { $class = 'AUTH' }
    elseif ($out -match '^TIMEOUT\b') { $class = 'TIMEOUT' }
    return @{ ok = ($class -eq 'OK'); class = $class; detail = $out }
}

Log "=== Credential Rescue Watch start (active=GO$ActiveKeyNumber, new=GO$NewKeyNumber, interval=${IntervalSeconds}s) ==="

# --- Step 0: initial agents snapshot is produced by the session via Paseo MCP;
#     here we record the canary baseline and (best-effort) any run marker. ---
Log "baseline: testing GO$ActiveKeyNumber and GO$NewKeyNumber before the loop"
$a0 = Test-Key -Num $ActiveKeyNumber
$n0 = Test-Key -Num $NewKeyNumber
Log "baseline GO${ActiveKeyNumber}: $($a0.detail)"
Log "baseline GO${NewKeyNumber}: $($n0.detail)"
if (-not $n0.ok) {
    if ($n0.class -eq 'NOT-SUBSCRIBED') {
        Log "ABORT: standby GO$NewKeyNumber has no active subscription; it cannot be a rescue target. Halting."
        [Console]::Error.WriteLine("standby GO$NewKeyNumber NOT-SUBSCRIBED: $($n0.detail)")
    } else {
        Log "ABORT: new key GO$NewKeyNumber is not healthy; refusing to watch with no safe target."
        [Console]::Error.WriteLine("new key GO$NewKeyNumber unhealthy: $($n0.detail)")
    }
    exit 2
}
if ($a0.class -eq 'EXHAUSTED') {
    Log "NOTE: active key GO$ActiveKeyNumber already reports EXHAUSTED at baseline; rescuing immediately."
}

$iter = 0
while ($iter -lt $MaxIterations) {
    $iter++
    if ($a0.ok -and $n0.ok) {
        Log "iter ${iter}: both keys healthy; sleeping ${IntervalSeconds}s."
        [System.IO.File]::WriteAllText($statePath, (@{ phase = 'watching'; iter = $iter; active = "GO$ActiveKeyNumber"; new = "GO$NewKeyNumber"; ts = (Get-Date).ToString('o') } | ConvertTo-Json))
        Start-Sleep -Seconds $IntervalSeconds
    }

    Log "iter ${iter}: re-testing GO${ActiveKeyNumber} and GO${NewKeyNumber}"
    $a = Test-Key -Num $ActiveKeyNumber
    $n = Test-Key -Num $NewKeyNumber
    Log "iter ${iter}: GO${ActiveKeyNumber} -> $($a.detail)"
    Log "iter ${iter}: GO${NewKeyNumber} -> $($n.detail)"

    if ($a.ok) { $a0 = $a; $n0 = $n; continue }   # active still fine -> keep waiting

    # Active key did not answer. Rescue ONLY on an explicit quota/usage-limit
    # signature (EXHAUSTED). A NOT-SUBSCRIBED/TIMEOUT/TRANSPORT/AUTH/ERROR is not
    # proof the key is spent — log it and keep watching rather than risking a
    # spurious cutover onto the standby key.
    if ($a.class -ne 'EXHAUSTED') {
        Log "iter ${iter}: active key GO${ActiveKeyNumber} non-OK but NOT exhaustion (class=$($a.class)); continuing to watch."
        $a0 = $a; $n0 = $n
        Start-Sleep -Seconds $IntervalSeconds
        continue
    }

    # Active key is genuinely exhausted — attempt rescue onto the new key.
    Log "DETECTED: active key GO${ActiveKeyNumber} EXHAUSTED (usage/rate limit)."
    if (-not $n.ok) {
        if ($n.class -eq 'NOT-SUBSCRIBED') {
            Log "ABORT: standby GO$NewKeyNumber has no active subscription; it cannot be a rescue target. Halting."
            [Console]::Error.WriteLine("active GO${ActiveKeyNumber} exhausted but standby GO$NewKeyNumber is NOT-SUBSCRIBED: $($n.detail)")
        } else {
            Log "ABORT: new key GO$NewKeyNumber also failing; cannot rescue. Halting."
            [Console]::Error.WriteLine("both keys failing; GO${ActiveKeyNumber}: $($a.detail) ; GO${NewKeyNumber}: $($n.detail)")
        }
        exit 3
    }
    if ($DryRun) { Log "dry-run: would cut over to GO$NewKeyNumber now."; exit 0 }

    Log "rescuing: cutting over to GO$NewKeyNumber"
    & pwsh -NoProfile -File $Switch -KeyNumber $NewKeyNumber -Reason "CRW: GO$ActiveKeyNumber exhausted (watch)" 2>&1 | ForEach-Object { Log "  switch: $_" }
    $switchRc = $LASTEXITCODE
    Log "switch exit code: $switchRc"

    Log "restarting Paseo (env pin + daemon worker restart) so helpers use the new key"
    & pwsh -NoProfile -File $Restart 2>&1 | ForEach-Object { Log "  paseo: $_" }
    $restartRc = $LASTEXITCODE
    Log "paseo restart exit code: $restartRc"

    $post = Test-Key -Num $NewKeyNumber
    Log "post-rescue GO${NewKeyNumber}: $($post.detail)"
    [System.IO.File]::WriteAllText($statePath, (@{ phase = 'rescued'; iter = $iter; active = "GO$ActiveKeyNumber"; new = "GO$NewKeyNumber"; postOk = $post.ok; switchRc = $switchRc; restartRc = $restartRc; ts = (Get-Date).ToString('o') } | ConvertTo-Json))

    if ($post.ok -and $restartRc -eq 0) {
        Log "RESCUE COMPLETE: GO$NewKeyNumber active, Paseo restarted. Session should now nudge agents."
        exit 0
    } else {
        Log "RESCUE INCOMPLETE: cutover done but post-check/restart imperfect. Manual review needed."
        exit 4
    }
}

Log "MaxIterations ($MaxIterations) reached with active key still healthy; exiting without rescue."
exit 0
