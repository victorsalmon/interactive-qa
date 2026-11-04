#Requires -Version 7.0
<#
.SYNOPSIS
    Single-entry Paseo repair: classify (BINARY/NAME/KEY), pin, restart, verify.

.DESCRIPTION
    Canonical Paseo track for Skills/credential-rescue. Salmon Run lanes are a
    SEPARATE consumer — cut over first with Switch-OpencodeGoKey.ps1, then run
    this script to make Paseo's long-lived opencode helpers use the new key. It
    covers BOTH harnesses on the shared opencode-go wallet: the opencode
    helper servers AND the deepseek-harness ACP child (which reads its key
    from the Machine/User env var named by the DSH patch apiKeyEnv — there is
    no provider-env pin for it, so only a restart carries a changed DSH key).

    Steps:
      1. Classify: BINARY (provider unavailable / CLI unresolvable), NAME
         (opencode/ vs opencode-go/ prefix via Test-PaseoMuseSparkCanary, no
         tokens), WEDGE (session.create timeout storm), KEY (helper holds
         the old pool key), plus the DSH key-health check (apiKeyEnv name,
         GO-label, diagnostic, pool-key canary — warn-only). -VerifyOnly
         stops here.
      2. Pin the key into agents.providers.opencode.env in ~/.paseo/config.json
         (from -KeyNumber Machine var, or the current User scope by default),
         AND repoint the DSH apiKeyEnv at the same pool key (both harnesses,
         one command; -NoDshSync skips the DSH half, -DshKeyNumber <m> moves
         DSH alone). The DSH half needs no pin — only the apiKeyEnv NAME.
      3. Worker restart (default): `paseo restart` rebuilds the opencode server
         manager WITH the env; supervisor + UI retained. `paseo reload` can NOT
         apply a launch env, so it is not used as a repair step.
      4. App fallback (-Mode App / -FullApp): close + re-open the Desktop app
         with a composed child env built from the current User-scope values,
         so the daemon never inherits a frozen pre-cutover shell env.
      5. Verify: both provider diagnostics + name canary + live helper session.create probe.

    Ending Paseo sessions (including yours) is inherent to steps 3-4 — warn the
    operator first when interactive. Sessions persist in opencode.db; a helper
    swap loses at most one in-flight turn.

    Secret VALUES are never printed — pool matches reported as GO<n> labels.
    Every mutation appends one JSON line to credential-changes.jsonl.

.PARAMETER KeyNumber
    Optional pool index (1-9) to pin. Reads OPENCODE_GO<n>_KEY from Machine
    scope. Default 0 = keep the current User-scope key (post-cutover value).
    A given -KeyNumber ALSO repoints the DSH apiKeyEnv at OPENCODE_GO<n>_KEY
    (both harnesses, one command) unless -NoDshSync is passed.

.PARAMETER DshKeyNumber
    Optional pool index (1-9) for the DSH harness only. Overrides the DSH
    target when -KeyNumber is also given; acts alone otherwise. 0 = follow
    -KeyNumber (or change nothing when -KeyNumber is 0).

.PARAMETER NoDshSync
    Pin opencode only; leave the DSH apiKeyEnv untouched.

.PARAMETER Mode
    Worker (default) or App. -FullApp is an alias for -Mode App.

.PARAMETER VerifyOnly
    Classify only: daemon status + helper ages + diagnostic + name canary +
    live helper session.create probe. The probe creates one empty session per
    helper and deletes it immediately (a leftover empty row is harmless).
    Changes no credentials.

.PARAMETER SkipCanary
    Skip both name-canary runs (only when the opencode CLI is unavailable).

.PARAMETER NoReopen
    App mode only: stop Paseo but do not relaunch it.

.EXAMPLE
    pwsh -File Repair-Paseo.ps1 -VerifyOnly
.EXAMPLE
    pwsh -File Repair-Paseo.ps1
.EXAMPLE
    pwsh -File Repair-Paseo.ps1 -KeyNumber 5
.EXAMPLE
    pwsh -File Repair-Paseo.ps1 -FullApp
#>
[CmdletBinding()]
param(
    [int]$KeyNumber = 0,
    [int]$DshKeyNumber = 0,
    [switch]$NoDshSync,
    [ValidateSet('Worker', 'App')]
    [string]$Mode = 'Worker',
    [switch]$FullApp,
    [switch]$VerifyOnly,
    [switch]$SkipCanary,
    [switch]$NoReopen,
    [int]$StartWaitSeconds = 60,
    [string]$PaseoExe = 'C:\Program Files\Paseo\Paseo.exe',
    [string]$PaseoCli = '',
    [string]$PaseoConfig = '',
    [string]$Actor = 'agent/credential-rescue',
    [string]$LogPath = "$($env:CL_REPOS_ROOT)\Tasks\Logs\credential-changes.jsonl"
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\CredLog.ps1')
. (Join-Path $PSScriptRoot 'lib\PaseoCommon.ps1')

if ($FullApp) { $Mode = 'App' }
if ([string]::IsNullOrWhiteSpace($PaseoConfig)) { $PaseoConfig = Join-Path $env:USERPROFILE '.paseo\config.json' }

function Write-Log {
    param([string]$Action, [string]$Target, [string]$Detail)
    Write-CredLog -Action $Action -Target $Target -Detail $Detail -Actor $Actor -LogPath $LogPath
}

function Test-HelperSessionCreate {
    # Live-helper proof: POST /session to every registered helper, DELETE the
    # probe session immediately after. The name canary passes while session
    # creation times out, so only this proves the helper is unstuck.
    # Returns @{ Slow = [int]; Fail = [int] }. Progress goes to the host
    # stream (Write-Host) so callers can capture the return value without
    # swallowing the per-helper lines into the result variable.
    param([int]$TimeoutSec = 35, [double]$SlowSeconds = 20)
    $slow = 0; $fail = 0
    $ports = @()
    $mpDir = Join-Path $env:USERPROFILE '.paseo\runtime\managed-processes'
    if (Test-Path -LiteralPath $mpDir) {
        foreach ($f in (Get-ChildItem -LiteralPath $mpDir -Filter '*.json' -ErrorAction SilentlyContinue)) {
            try {
                $m = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json
                if ($m.metadata.port) { $ports += [int]$m.metadata.port }
            } catch {}
        }
    }
    $ports = $ports | Sort-Object -Unique | Select-Object -First 5
    if (-not $ports -or $ports.Count -eq 0) { Write-Host '  (no registered helpers to probe)'; return @{ Slow = 0; Fail = 0 } }
    foreach ($port in $ports) {
        $id = $null
        try {
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $r = Invoke-RestMethod -Uri ("http://127.0.0.1:{0}/session" -f $port) -Method Post -Body '{}' -ContentType 'application/json' -TimeoutSec $TimeoutSec
            $sw.Stop()
            $id = $r.id
            Write-Host ("  helper :{0} session.create {1:N1}s id={2}" -f $port, $sw.Elapsed.TotalSeconds, $id)
            if ($sw.Elapsed.TotalSeconds -gt $SlowSeconds) { $slow++ }
        } catch {
            $fail++
            Write-Host ("  helper :{0} session.create FAIL ({1})" -f $port, $_.Exception.Message)
        }
        if ($id) {
            try { $null = Invoke-RestMethod -Uri ("http://127.0.0.1:{0}/session/{1}" -f $port, $id) -Method Delete -TimeoutSec 15 } catch {}
        }
    }
    return @{ Slow = $slow; Fail = $fail }
}

$canaryScript = Join-Path $PSScriptRoot 'Test-PaseoMuseSparkCanary.ps1'
$cli = Resolve-PaseoCli -Explicit $PaseoCli

# --- 1. classify (read-only) ---
Write-Output '--- 1/4 classify (BINARY / NAME / KEY) ---'
$helpers = Get-HelperProcs
Write-Output ("Paseo processes : {0}" -f ((Get-PaseoProcs | Measure-Object).Count))
Write-Output ("opencode helpers: {0}" -f (($helpers | Measure-Object).Count))
Write-Output ("daemon alive    : {0}" -f (Get-DaemonAlive))

$diagStatus = '<unknown>'
if ($cli) {
    $diag = (& $cli provider diagnostic opencode 2>&1 | Out-String)
    foreach ($ln in ($diag -split "`n")) {
        if ($ln -match 'Status:\s*(\S+)') { $diagStatus = $Matches[1]; break }
    }
    Write-Output ("provider diagnostic: Status $diagStatus")
    if ($diagStatus -match 'Unavailable|Not') {
        Write-Output 'CLASS=BINARY: provider did not launch (PATH/binary or command pin) — see REFERENCE Runbook C.'
    }
} else {
    Write-Output 'CLASS=BINARY: paseo CLI not found (PATH or Desktop bundle).'
}

$userGo = [Environment]::GetEnvironmentVariable('OPENCODE_GO_KEY', 'User')
Write-Output ("User OPENCODE_GO_KEY -> {0}" -f (Get-PoolMatchLabel -KeyValue $userGo))

if (-not $SkipCanary -and (Test-Path -LiteralPath $canaryScript)) {
    & pwsh -NoProfile -File $canaryScript -Model 'opencode-go/deepseek-v4.1-flash' 2>&1 | ForEach-Object { Write-Output "  canary: $_" }
    if ($LASTEXITCODE -ne 0) {
        Write-Output 'CLASS=NAME: exact opencode-go/ model name does not resolve — fix the name before blaming the key.'
    } else {
        Write-Output 'CLASS=KEY candidate: model name resolves; a stale helper env is one suspect — see WEDGE check next.'
    }
}

# DeepSeek Harness (second consumer, same opencode-go wallet): the DSH ACP
# child reads its key from the Machine/User env var named by the DSH patch
# apiKeyEnv — there is no provider-env pin for it, so only a (worker) restart
# carries a changed DSH key to it. Classify its health here too, warn-only:
# a sick DSH key must never trigger an opencode cutover.
$dshName = Get-DshApiKeyEnvName
$dshLabel = Get-DshKeyGoLabel -ApiKeyEnvName $dshName
Write-Output ("DSH apiKeyEnv -> {0} ({1})" -f $dshName, $dshLabel)
if ($cli) {
    $dshDiag = '<unknown>'
    $dd = (& $cli provider diagnostic deepseek-harness 2>&1 | Out-String)
    foreach ($ln in ($dd -split "`n")) {
        if ($ln -match 'Status:\s*(\S+)') { $dshDiag = $Matches[1]; break }
    }
    Write-Output ("DSH provider diagnostic: Status {0}" -f $dshDiag)
    if ($dshDiag -match 'Unavailable|Not|Error') {
        Write-Output 'CLASS=BINARY(DSH): deepseek-harness child did not launch — reinstall via salmon-run Tools/Install-PaseoDeepSeekHarness.ps1.'
    }
}
if ($dshLabel -eq 'env-missing') {
    Write-Warning ("DSH apiKeyEnv {0} is set in neither Machine nor User scope — DSH calls will fail." -f $dshName)
} elseif ($dshName -match '^OPENCODE_GO(\d+)_KEY$' -and -not $SkipCanary) {
    $dshNum = [int]$Matches[1]
    $goKeyScript = Join-Path $PSScriptRoot 'Test-GoKey.ps1'
    if (Test-Path -LiteralPath $goKeyScript) {
        & pwsh -NoProfile -File $goKeyScript -KeyNumber $dshNum 2>&1 | ForEach-Object { Write-Output ("  dsh-key: {0}" -f $_.ToString().Trim()) }
        if ($LASTEXITCODE -ne 0) {
            Write-Warning ("DSH key {0} canary non-OK — the opencode track may still be healthy; move DSH with Repair-Paseo.ps1 -KeyNumber <healthy-n> (both harnesses) or -DshKeyNumber <m> (DSH only), never the opencode pin alone." -f $dshLabel)
        }
    }
}

# WEDGE check: a session.create timeout storm is a stuck helper/daemon, NOT a
# key. The name canary passes through it, so only the daemon-log scan and the
# live-helper probe below can see it. A WEDGE finding means restart — never a
# key cutover (the follow-on workspace_request_key_conflict is the UI retrying
# the timed-out create under the same request key, not a second fault).
# Only timeouts from the CURRENT daemon pid count as a live wedge — older-pid
# lines are pre-restart history (a restart already cleared them).
$wedgeFresh = 0; $wedgeStale = 0
$daemonLog = Join-Path $env:USERPROFILE '.paseo\daemon.log'
$daemonPid = $null
$pidFile = Join-Path $env:USERPROFILE '.paseo\paseo.pid'
if (Test-Path -LiteralPath $pidFile) {
    try { $daemonPid = (Get-Content -LiteralPath $pidFile -Raw | ConvertFrom-Json).pid } catch {}
}
if (Test-Path -LiteralPath $daemonLog) {
    $tail = Get-Content -LiteralPath $daemonLog -Tail 300
    foreach ($ln in $tail) {
        if ($ln -match 'session\.create timed out|first-record watchdog expired|stream watchdog expired') {
            if ($daemonPid -and $ln -match ('"pid":' + $daemonPid + '(,|[^0-9])')) { $wedgeFresh++ } else { $wedgeStale++ }
        }
    }
    Write-Output ("daemon.log timeout/watchdog in tail-300: live(pid {0})={1} pre-restart={2}" -f $daemonPid, $wedgeFresh, $wedgeStale)
}
Write-Output 'live helper session.create probe:'
$probe = Test-HelperSessionCreate
if ($wedgeFresh -gt 0 -or $probe.Slow -gt 0 -or $probe.Fail -gt 0) {
    Write-Output 'CLASS=WEDGE: helper/daemon stuck (session.create timeouts or slow helpers) — restart clears it; do NOT cut over the key.'
} elseif ($wedgeStale -gt 0) {
    Write-Output 'note: session.create timeouts in the log are pre-restart history (older daemon pid) — no live wedge; live probe above is the current truth.'
}

if ($VerifyOnly) { Write-Output 'verify-only: nothing changed.'; exit 0 }
if (-not $cli -and $Mode -eq 'Worker') {
    Write-Warning 'paseo CLI not found; falling back to the full app restart.'
    $Mode = 'App'
}

# --- 2. pin ---
Write-Output '--- 2/4 pin provider env ---'
$pinVal = $null
$pinLabel = 'current-User-key'
if ($KeyNumber -gt 0) {
    $pinScope = ''
    $pinVal = Get-PoolKeyValue -Number $KeyNumber -ScopeOut ([ref]$pinScope)
    if ([string]::IsNullOrWhiteSpace($pinVal)) { throw "OPENCODE_GO${KeyNumber}_KEY not set at Machine or User scope - cannot pin." }
    $pinLabel = "GO$KeyNumber ($pinScope-scope)"
} else {
    $apiKey = [Environment]::GetEnvironmentVariable('OPENCODE_API_KEY', 'User')
    $pinVal = if (-not [string]::IsNullOrWhiteSpace($userGo)) { $userGo } else { $apiKey }
    if ([string]::IsNullOrWhiteSpace($pinVal)) { throw 'User-scope OPENCODE_GO_KEY/OPENCODE_API_KEY are empty; nothing to pin. Cut over first (Switch-OpencodeGoKey) or pass -KeyNumber.' }
    $pinLabel = Get-PoolMatchLabel -KeyValue $pinVal
}
if (Set-PaseoOpencodeEnv -ConfigPath $PaseoConfig -ProviderId 'opencode' -KeyValue $pinVal) {
    Write-Output ("pinned {0} agents.providers.opencode.env -> {1}" -f $PaseoConfig, $pinLabel)
    Write-Log -Action 'credential-update' -Target "$PaseoConfig agents.providers.opencode.env" -Detail "pinned OPENCODE_GO_KEY + OPENCODE_API_KEY to $pinLabel by Repair-Paseo"
} else {
    Write-Warning "could not pin the provider env in $PaseoConfig; continuing to App fallback."
    $Mode = 'App'
}
Write-Output ("DSH needs no pin: deepseek-harness reads Machine/User {0} ({1}) at child spawn — the restart below is what carries any changed value to it." -f $dshName, $dshLabel)
# Dual-harness sync: -KeyNumber <n> moves BOTH harnesses to GO<n> unless
# -NoDshSync; -DshKeyNumber <m> moves DSH alone (or overrides the DSH half).
$dshTarget = 0
if ($DshKeyNumber -gt 0) { $dshTarget = $DshKeyNumber }
elseif ($KeyNumber -gt 0 -and -not $NoDshSync) { $dshTarget = $KeyNumber }
if ($dshTarget -gt 0) {
    $dshWant = "OPENCODE_GO${dshTarget}_KEY"
    if ([string]::IsNullOrWhiteSpace((Get-PoolKeyValue -Name $dshWant))) { throw "$dshWant not set at Machine or User scope - cannot point DSH at it." }
    $sw = Set-DshApiKeyEnv -ApiKeyEnvName $dshWant
    if ($sw.Changed) {
        Write-Output ("DSH apiKeyEnv {0} -> {1} (backup {2}); takes effect when the DSH child respawns (the restart below)." -f $sw.Old, $dshWant, $sw.Backup)
        Write-Log -Action 'credential-update' -Target 'DSH salmon-run-model.yml apiKeyEnv' -Detail ("repointed {0} to {1} by Repair-Paseo" -f $sw.Old, $dshWant)
    } else {
        Write-Output ("DSH apiKeyEnv already {0} — no change." -f $dshWant)
    }
    $dshName = Get-DshApiKeyEnvName
    $dshLabel = Get-DshKeyGoLabel -ApiKeyEnvName $dshName
}

# --- 3. worker restart (default) ---
if ($Mode -eq 'Worker') {
    Write-Output '--- 3/4 daemon worker restart (supervisor retained) ---'
    Write-Warning 'This ends every Paseo session the daemon hosts, including this one.'
    $out = (& $cli restart 2>&1 | Out-String).Trim()
    Write-Output ("paseo restart: " + $out)
    Write-Log -Action 'credential-update' -Target 'paseo daemon worker' -Detail "daemon worker restarted by Repair-Paseo (pin $pinLabel)"
    Start-Sleep -Seconds 8
    if (Get-DaemonAlive) {
        Write-Output '--- 4/4 verify ---'
        & $cli provider diagnostic opencode 2>&1 | Select-String 'Status|Models:|Auth:' | ForEach-Object { Write-Output ("  " + $_.ToString().Trim()) }
        & $cli provider diagnostic deepseek-harness 2>&1 | Select-String 'Status|Models:' | ForEach-Object { Write-Output ("  dsh: " + $_.ToString().Trim()) }
        if (-not $SkipCanary -and (Test-Path -LiteralPath $canaryScript)) {
            & pwsh -NoProfile -File $canaryScript -Model 'opencode-go/deepseek-v4.1-flash' 2>&1 | ForEach-Object { Write-Output "  $_" }
            if ($LASTEXITCODE -ne 0) { throw 'post-restart name canary failed.' }
        }
        $vprobe = Test-HelperSessionCreate
        if ($vprobe.Fail -gt 0) { throw 'post-restart helper session.create probe failed — helpers still wedged.' }
        if ($vprobe.Slow -gt 0) { Write-Warning 'post-restart helper session.create slow (>20s) — wedge may be returning; watch opencode.db growth.' }
        Write-Log -Action 'canary-passed' -Target 'opencode-go/deepseek-v4.1-flash (name check)' -Detail 'post-restart verification in Repair-Paseo'
        Write-Output '=== Paseo worker repair complete ==='
        exit 0
    }
    Write-Warning 'daemon not alive after worker restart; falling back to the full app restart.'
    $Mode = 'App'
}

# --- 3b. app fallback: close + re-open with a CURRENT child env ---
Write-Output '--- 3/4b full app restart (close + re-open) ---'
Write-Warning 'This ends every Paseo session the daemon hosts, including this one.'
$paseo = Get-PaseoProcs
$helpers = Get-HelperProcs
foreach ($h in $helpers) {
    try { Stop-Process -Id $h.ProcessId -Force -ErrorAction Stop; Write-Output "  stopped helper PID $($h.ProcessId)" }
    catch { Write-Output "  warn: helper PID $($h.ProcessId): $($_.Exception.Message)" }
}
foreach ($p in ($paseo | Sort-Object { $_.MainWindowHandle -ne 0 })) {
    try { Stop-Process -Id $p.Id -Force -ErrorAction Stop; Write-Output "  stopped Paseo PID $($p.Id)" }
    catch { Write-Output "  warn: Paseo PID $($p.Id): $($_.Exception.Message)" }
}
for ($i = 0; $i -lt 30; $i++) {
    if (-not (Get-PaseoProcs) -and -not (Get-HelperProcs)) { break }
    Start-Sleep -Seconds 1
}
if ($NoReopen) { Write-Output 'NoReopen: leaving Paseo closed.'; exit 0 }
if (-not (Test-Path -LiteralPath $PaseoExe)) {
    [Console]::Error.WriteLine("Paseo.exe not found at $PaseoExe; cannot reopen. Start Paseo manually.")
    exit 1
}
# Compose the child env from the CURRENT User-scope values so the daemon never
# inherits a frozen pre-cutover shell env (the detached-watch trap).
$goKey = [Environment]::GetEnvironmentVariable('OPENCODE_GO_KEY', 'User')
$apiKey = [Environment]::GetEnvironmentVariable('OPENCODE_API_KEY', 'User')
$childEnv = @{}
foreach ($k in [Environment]::GetEnvironmentVariables('Process').Keys) { $childEnv[$k] = [Environment]::GetEnvironmentVariable($k, 'Process') }
if (-not [string]::IsNullOrWhiteSpace($goKey)) { $childEnv['OPENCODE_GO_KEY'] = $goKey }
if (-not [string]::IsNullOrWhiteSpace($apiKey)) { $childEnv['OPENCODE_API_KEY'] = $apiKey }
Write-Output ("launch env OPENCODE_GO_KEY -> {0} (from User scope)" -f (Get-PoolMatchLabel -KeyValue $goKey))
Start-Process -FilePath $PaseoExe -Environment $childEnv
Write-Log -Action 'credential-update' -Target 'Paseo desktop app' -Detail 'full app restarted by Repair-Paseo with current User-scope launch env'
$deadline = (Get-Date).AddSeconds($StartWaitSeconds)
while ((Get-Date) -lt $deadline) {
    if (Get-DaemonAlive) { break }
    Start-Sleep -Seconds 2
}
if (-not (Get-DaemonAlive)) {
    [Console]::Error.WriteLine('Paseo daemon did not come back within the wait window.')
    exit 1
}
Write-Output '--- 4/4 verify ---'
$cli2 = Resolve-PaseoCli -Explicit $PaseoCli
if ($cli2) {
    & $cli2 provider diagnostic opencode 2>&1 | Select-String 'Status|Models:|Auth:' | ForEach-Object { Write-Output ("  " + $_.ToString().Trim()) }
    & $cli2 provider diagnostic deepseek-harness 2>&1 | Select-String 'Status|Models:' | ForEach-Object { Write-Output ("  dsh: " + $_.ToString().Trim()) }
}
if (-not $SkipCanary -and (Test-Path -LiteralPath $canaryScript)) {
    & pwsh -NoProfile -File $canaryScript -Model 'opencode-go/deepseek-v4.1-flash' 2>&1 | ForEach-Object { Write-Output "  $_" }
    if ($LASTEXITCODE -ne 0) { throw 'post-restart name canary failed.' }
}
$vprobe = Test-HelperSessionCreate
if ($vprobe.Fail -gt 0) { throw 'post-restart helper session.create probe failed — helpers still wedged.' }
if ($vprobe.Slow -gt 0) { Write-Warning 'post-restart helper session.create slow (>20s) — wedge may be returning; watch opencode.db growth.' }
Write-Output '=== Paseo app repair complete ==='
