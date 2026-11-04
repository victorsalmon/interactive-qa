#Requires -Version 7.0
<#
.SYNOPSIS
    Canary a SPECIFIC opencode-go pool key (by number or value) in isolation.

.DESCRIPTION
    Unlike Test-OpencodeProvider.ps1 (which reads the User-scope key), this
    script takes a pool key NUMBER (reads OPENCODE_GO<n>_KEY from Machine scope)
    or an explicit value and injects it into a child opencode run, so a
    non-active key can be probed independently of the active one.

    Used by Credential Rescue Watch to answer, each tick, "does the OLD key
    still work?" and "does the NEW key work?" without disturbing the live env.

    IMPORTANT — an exhaustion/subscription failure does NOT return a fast error
    to the CLI: the request hangs and retries, so the CLI is killed as a timeout
    and the only reliable evidence is the opencode LOG line the attempt writes.
    The log is shared across every session on the machine, so evidence is
    attributed by time (only lines at/after this attempt's start count).

    Transient "provider busy" errors (e.g. "Output token rate limit exceeded.
    Please retry after a brief wait.", "Upstream response was not valid JSON")
    are NOT key failures: the script retries the attempt up to -MaxRetries
    times before giving up, and only then reports BUSY.

.OUTPUTS
    Prints a classified first token (see result contract below).

.NOTES
    Canonical copy. The duplicate under Skills/credential-rescue-watch/scripts
    is a thin forwarder to this file — never re-implement the CLI call there.

    opencode CLI assumption: v2.1.2 (verified 2026-11-03). Relevant to this
    script: 2.1.2 has NO `--variant` flag (it rejects the flag and prints help,
    which makes every key look dead), a variant rides inside the model id
    (`--model provider/model#variant`), and `--standalone` exists and is
    mandatory here. If the CLI is upgraded, re-check `opencode run --help` for
    those two facts before editing the invocation below.
#>
[CmdletBinding()]
param(
    [int]$KeyNumber = 0,
    [string]$KeyValue = '',
    [string]$Model = 'opencode-go/deepseek-v4.1-flash',
    [string]$Variant = '',
    [string]$OpencodeCli = '',
    [int]$TimeoutSeconds = 60,
    [int]$MaxRetries = 3,
    [int]$RetryDelaySeconds = 15
)

$configuredVariant = @{
    'opencode-go/deepseek-v4.1-flash' = 'low'
    'opencode-go/deepseek-v4-pro'     = 'max'
}
if (-not $Variant) {
    if ($configuredVariant.ContainsKey($Model)) { $Variant = $configuredVariant[$Model] }
    else { $Variant = 'default' }
}

$ErrorActionPreference = 'Stop'

# Resolve the key value without ever printing it. Pool keys live at Machine
# scope normally; a key staged at User scope (elevation not available) resolves
# through the same Machine -> User fallback the rest of the rescue uses.
if (-not $KeyValue) {
    if ($KeyNumber -lt 1) { [Console]::Error.WriteLine('Provide -KeyNumber (1-9) or -KeyValue.'); exit 1 }
    . (Join-Path $PSScriptRoot 'lib\PaseoCommon.ps1')
    $KeyValue = Get-PoolKeyValue -Number $KeyNumber
    if ([string]::IsNullOrWhiteSpace($KeyValue)) {
        [Console]::Error.WriteLine("OPENCODE_GO${KeyNumber}_KEY not set at Machine or User scope."); exit 1
    }
}

if (-not $OpencodeCli) { $OpencodeCli = $env:OPENCODE_CLI_PATH }
if (-not $OpencodeCli) {
    $cmd = Get-Command opencode -ErrorAction SilentlyContinue
    if ($cmd) { $OpencodeCli = $cmd.Source }
}
if (-not $OpencodeCli) {
    $fallback = "$($env:CL_REPOS_ROOT)\Tools\opencode-standalone\node_modules\.bin\opencode.ps1"
    if (Test-Path -LiteralPath $fallback) { $OpencodeCli = $fallback }
}
if (-not $OpencodeCli -or -not (Test-Path -LiteralPath $OpencodeCli)) {
    [Console]::Error.WriteLine('opencode CLI not found (set OPENCODE_CLI_PATH or put opencode on PATH).'); exit 1
}

# Locate the live opencode log — the authoritative source for the quota /
# subscription error text (the CLI itself may stay silent while it retries).
$ocLog = $null
$dataHome = [Environment]::GetEnvironmentVariable('XDG_DATA_HOME', 'User')
if ([string]::IsNullOrWhiteSpace($dataHome)) { $dataHome = $env:XDG_DATA_HOME }
if ($dataHome) { $cand = Join-Path $dataHome 'opencode\log\opencode.log'; if (Test-Path -LiteralPath $cand) { $ocLog = $cand } }

# Return only error/stream-error log lines timestamped at/after <Since>.
# Bounded tail read: never read the whole (possibly rotated) file, and time
# attribution stops a shared log dragging another key's old lines into this one.
function Get-AttemptErrorLines {
    param([datetime]$Since)
    if (-not $ocLog) { return '' }
    try {
        $fs = [System.IO.File]::Open($ocLog, 'Open', 'Read', 'ReadWrite')
        try {
            $len = $fs.Length
            $take = [Math]::Min($len, 2MB)
            $fs.Seek([Math]::Max(0, $len - $take), 'Begin') | Out-Null
            $buf = New-Object byte[] $take
            $read = $fs.Read($buf, 0, $take)
            $text = [Text.Encoding]::UTF8.GetString($buf, 0, $read)
        } finally { $fs.Dispose() }
        $sinceStr = $Since.ToString('yyyy-MM-ddTHH:mm:ss')
        $kept = New-Object System.Collections.Generic.List[string]
        foreach ($ln in ($text -split "`n")) {
            if ($ln -notmatch 'error\.error=|stream error') { continue }
            if ($ln -match 'timestamp=([0-9T:\-\.]+)Z') {
                if ($Matches[1] -ge $sinceStr) { $kept.Add($ln) }
            }
        }
        return ($kept -join "`n")
    } catch { return '' }
}

# Result contract (machine-readable first token):
#   OK <model>/<variant>
#   EXHAUSTED <model>/<variant>: <detail>       -> weekly cap spent; SAFE to rescue
#   NOT-SUBSCRIBED <model>/<variant>: <detail>  -> monthly term lapsed, no payment; do NOT rescue onto it
#   BUSY <model>/<variant>: <detail>            -> provider busy / transient upstream; RETRY, not a key fault
#   TRANSPORT <model>/<variant>: <detail>       -> model/config defect, not the key
#   AUTH <model>/<variant>: <detail>            -> bad/invalid credential, not quota
#   TIMEOUT <model>/<variant>: <detail>         -> no answer in time; NOT exhaustion
#   ERROR <model>/<variant>: <detail>           -> anything else
# The watch loop rescues ONLY on EXHAUSTED. Busy/not-subscribed/timeout/
# transport/auth/error are NOT proof the key is spent and never trigger a cutover.

function Invoke-OneAttempt {
    param([datetime]$Since)
    $job = Start-Job -ScriptBlock {
        param($cli, $key, $model, $variant)
        $env:OPENCODE_GO_KEY = $key
        $env:OPENCODE_API_KEY = $key
        # No --variant flag in the current CLI: fold a real variant into the id.
        $target = if ($variant -and $variant -ne 'default') { "$model#$variant" } else { $model }
        # --standalone is MANDATORY here: without it `opencode run` is served by
        # the long-lived background service (`opencode serve --service`), whose
        # env is frozen at spawn, so every probe answers with THAT server's key
        # verdict and a healthy pool key is misreported EXHAUSTED once the
        # server's own key lapses (live case 2026-10-25: all five keys reported
        # EXHAUSTED while GO1/GO3/GO5 returned HTTP 200 to a direct probe).
        & $cli run 'reply with the single word pong' --model $target --standalone 2>&1 | Out-String
    } -ArgumentList $OpencodeCli, $KeyValue, $Model, $Variant

    $done = Wait-Job -Job $job -Timeout $TimeoutSeconds
    $o = ''
    if ($done) { $o = Receive-Job -Job $job | Out-String }
    else { Stop-Job -Job $job | Out-Null }
    Remove-Job -Job $job -Force

    $log = Get-AttemptErrorLines -Since $Since
    $c = "$o`n$log"
    $safe = $o -replace '[A-Za-z0-9_\-]{30,}', '<masked>'
    return @{ done = $done; out = $o; combined = $c; safe = $safe }
}

function Classify-Attempt {
    param($A)
    $c = $A.combined
    # A real answer from the probed key outranks the shared log: the log is
    # machine-wide, so a co-tenant session spewing quota errors inside this
    # attempt's window must never turn a successful run into EXHAUSTED.
    if ($A.out -match '(?i)\bpong\b') { return 'OK' }
    if ($c -match '(?i)subscription is required|active OpenCode Go subscr|no active subscr|not subscribed') {
        return 'NOT-SUBSCRIBED'
    }
    if ($c -match '(?i)usage[ _]?limit|rate[ _]?limit|Go usage|quota exceeded|too many requests') {
        # "Output token rate limit exceeded. Please retry after a brief wait." is
        # a TRANSIENT provider-busy signal, not a spent key — detect it first.
        if ($c -match '(?i)output token rate limit|please retry after|retry after a brief') { return 'BUSY' }
        return 'EXHAUSTED'
    }
    if ($c -match '(?i)429.{0,40}(limit|exceed)|(limit|exceed).{0,40}429') { return 'EXHAUSTED' }
    # Provider busy / transient upstream classes (retry, not a key fault).
    if ($c -match '(?i)output token rate limit|please retry after|retry after a brief wait|upstream response was not valid json|overloaded|temporarily unavailable|service unavailable|provider is busy|too many concurrent|503|502|504') {
        return 'BUSY'
    }
    if ($A.out -match '(?i)encrypted_content|not issued to this caller|invalid_request_error') { return 'TRANSPORT' }
    if ($A.out -match '(?i)unauthorized|invalid api key|authentication failed|\b401\b|\b403\b|insufficient') { return 'AUTH' }
    if (-not $A.done) { return 'TIMEOUT' }
    if ($A.out -notmatch 'pong') { return 'ERROR' }
    return 'OK'
}

$attempt = 0
$result = $null
while ($attempt -lt $MaxRetries) {
    $attempt++
    $start = [datetime]::UtcNow
    $a = Invoke-OneAttempt -Since $start
    $class = Classify-Attempt -A $a
    if ($class -eq 'OK') { Write-Output "OK $Model/$Variant"; exit 0 }
    # Only retry the transient BUSY class (and TIMEOUT, which is most often a
    # busy/hung provider rather than a spent key). A definitive verdict
    # (EXHAUSTED / NOT-SUBSCRIBED / AUTH / TRANSPORT / ERROR) is not retried.
    if ($class -eq 'BUSY' -or $class -eq 'TIMEOUT') {
        if ($attempt -lt $MaxRetries) {
            Start-Sleep -Seconds $RetryDelaySeconds
            continue
        }
    }
    $result = @{ class = $class; detail = $a }
    break
}

$r = $result
switch ($r.class) {
    'EXHAUSTED'      { Write-Output "EXHAUSTED $Model/${Variant}: usage/rate limit reported"; exit 1 }
    'NOT-SUBSCRIBED' { Write-Output "NOT-SUBSCRIBED $Model/${Variant}: key has no active subscription"; exit 1 }
    'BUSY'           { Write-Output "BUSY $Model/${Variant}: provider busy after $attempt attempt(s); retry later"; exit 1 }
    'TRANSPORT'      { Write-Output "TRANSPORT $Model/${Variant}: $($r.detail.safe.Trim())"; exit 1 }
    'AUTH'           { Write-Output "AUTH $Model/${Variant}: $($r.detail.safe.Trim())"; exit 1 }
    'TIMEOUT'        { Write-Output "TIMEOUT $Model/${Variant}: no response within ${TimeoutSeconds}s across $attempt attempt(s); NOT exhaustion"; exit 1 }
    default          { Write-Output "ERROR $Model/${Variant}: $($r.detail.safe.Trim())"; exit 1 }
}
