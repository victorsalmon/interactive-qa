#Requires -Version 7.0
<#
.SYNOPSIS
    Preflight health check for an opencode provider/model before dispatch.

.DESCRIPTION
    Runs a one-word canary (`opencode run "reply with the single word pong"
    --model <provider/model>`) and classifies the result:

      exit 0  - provider responded (healthy enough to dispatch on)
      exit 1  - quota/auth/model failure or timeout; stderr explains

    Motivation: opencode-go pool keys exhaust weekly; a dead key produces
    workers that die on their first turn. Test the credential BEFORE
    spawning. When the whole pool is down, rotate keys (see
    credential-rescue Runbook A) and re-dispatch on the fleet default
    worker model — audit runs never swap model families.

    WHICH key is tested is the machine's ACTIVE key (or the gate-selected
    -KeyNumber when a keyed dispatch supplies one), not whatever the caller
    inherited. The seam (credential-rescue assets/opencode-go-cutover.json)
    names it (`activeKey` -> OPENCODE_GO<n>_KEY); that pool key's value is
    read from Machine scope first, then User, and injected into the CLI child
    explicitly. Before this, the canary tested the caller's inherited
    OPENCODE_GO_KEY: a Hub session born on GO6 kept failing after the machine
    moved to GO3 and the advice ("rotate the credential") was actively wrong
    (measured 2026-11-02). If the seam or the pool value cannot be resolved,
    the canary falls back to the inherited environment and SAYS SO — an
    invisible fallback is how that bug returns.

    The seam is resolved from the CANONICAL checkout
    (`$env:CL_REPOS_ROOT\cl-common\...`), not from this script's worktree:
    the seam is tracked and the switch mutates the main checkout, so a lane
    worktree carries a stale copy (measured 2026-11-03: worktree said GO6, the
    machine was on GO3). The canonical path is printed with the label.

    The canary always runs with `--standalone`. Without it the CLI talks to a
    long-lived background service that caches the credential it booted with,
    so every key reports "Go usage limit exceeded" and the whole pool looks
    dead (measured 2026-11-03). `--standalone` starts a private server that
    reads the current environment, which is the only way the pinned key is
    actually the key that gets measured.

    The pass/fail summary names the exercised key by label and source only
    (`canary: key GO3 (seam) PASS`). No secret value is ever printed.

.PARAMETER Model
    Provider/model pair as opencode sees it; defaults to the fleet default
    worker model 'opencode-go/deepseek-v4.1-flash'.

.PARAMETER Variant
    Model variant (reasoning effort) to canary. Defaults to the model's
    configured effort where known (deepseek-v4.1-flash -> low,
    muse-spark-1.3-contributor -> high), else 'default'. The variant matters: a model
    whose Responses-API transport is misconfigured can answer a `default`
    ping yet fail its real reasoning variant, so a `default`-only canary is a
    false green.

.PARAMETER KeyNumber
    Pool key number to exercise instead of the seam's `activeKey` (1..n).
    The value still comes from the pool (Machine, then User), never from the
    caller's inherited OPENCODE_GO_KEY.

.PARAMETER SeamPath
    The cutover seam to read. Defaults to
    ../../credential-rescue/assets/opencode-go-cutover.json beside this skill
    (a test seam; production should omit it).

.PARAMETER PoolScope
    Environment scopes searched for the pool key value, in order. Default
    Machine, User, Process. Tests pin `Process` so a fixture value is used
    instead of a real machine key.

.PARAMETER OpencodeCli
    Path to the opencode CLI. Defaults to $env:OPENCODE_CLI_PATH, then
    `opencode` on PATH.

.PARAMETER TimeoutSeconds
    Kill the canary after this long and treat it as a failure.
    Default 90 (cold CLI start can take ~30s).

.OUTPUTS
    One summary line naming the exercised key (`canary: key GO3 (seam) PASS`);
    a diagnostic on stderr + nonzero exit on failure.

.EXAMPLE
    ./Test-OpencodeProvider.ps1 -Model opencode-go/deepseek-v4.1-flash
    if ($LASTEXITCODE -ne 0) { throw 'rotate the key or swap provider' }
#>
[CmdletBinding()]
param(
    [string]$Model = 'opencode-go/deepseek-v4.1-flash',
    [string]$Variant = '',
    [int]$KeyNumber = 0,
    [string]$SeamPath = '',
    [string[]]$PoolScope = @('Machine', 'User', 'Process'),
    [string]$OpencodeCli = '',
    [int]$TimeoutSeconds = 90
)

# Recognised model -> configured effort. A variant that exercises the model's
# real reasoning path (not the trivial `default`) is what catches the
# `encrypted_content` / Responses-API transport regression that a key cutover
# can surface. Keep in sync with harness-defaults.json `providers.opencode-go`.
$configuredVariant = @{
    'opencode-go/muse-spark-1.3-contributor' = 'high'
    'opencode-go/deepseek-v4.1-flash'        = 'low'
    'opencode-go/deepseek-v4-pro'            = 'max'
    'opencode/deepseek-v4.1-flash-free'      = 'low'
    'opencode/deepseek-v4.1-flash'           = 'low'
}
if (-not $Variant) {
    if ($configuredVariant.ContainsKey($Model)) { $Variant = $configuredVariant[$Model] }
    else { $Variant = 'default' }
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-PoolKeyValue {
    <#
        Read a pool key's VALUE from the environment, in the given scope order.
        Returns '' when the name is unstaged in every scope.
    #>
    param([string]$Name, [string[]]$Scopes)
    foreach ($scope in $Scopes) {
        try { $value = [Environment]::GetEnvironmentVariable($Name, $scope) }
        catch { $value = $null }
        if (-not [string]::IsNullOrWhiteSpace($value)) { return [string]$value }
    }
    return ''
}

function Get-PoolKeyLabel {
    <#
        Map a key VALUE back to its pool label (GO<n>), by comparing it against
        the OPENCODE_GO<n>_KEY pool. Labels only; the value is never printed.
    #>
    param([string]$Value, [string[]]$Scopes)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    for ($n = 1; $n -le 12; $n++) {
        if ((Get-PoolKeyValue -Name "OPENCODE_GO${n}_KEY" -Scopes $Scopes) -eq $Value) { return "GO$n" }
    }
    return ''
}

# ------------------------------------------------------- active key resolution
if (-not $SeamPath) {
    # The seam is a TRACKED file that the switch mutates in the main checkout.
    # A lane worktree carries the committed (stale) copy, so prefer the
    # canonical checkout - a Hub dispatching from a worktree is the normal case.
    $canonicalSeam = ''
    if (-not [string]::IsNullOrWhiteSpace($env:CL_REPOS_ROOT)) {
        $canonicalSeam = Join-Path $env:CL_REPOS_ROOT 'cl-common\Skills\credential-rescue\assets\opencode-go-cutover.json'
    }
    if ($canonicalSeam -and (Test-Path -LiteralPath $canonicalSeam)) { $SeamPath = $canonicalSeam }
    else { $SeamPath = Join-Path $PSScriptRoot '..\..\credential-rescue\assets\opencode-go-cutover.json' }
}

$keyVar = ''
$keySource = ''
$keyLabel = ''
$keyValue = ''
$apiKeyVar = 'OPENCODE_API_KEY'
$fallbackNote = ''
$seam = $null

if ($KeyNumber -gt 0) {
    $keyVar = "OPENCODE_GO${KeyNumber}_KEY"
    $keySource = 'key-number'
}
else {
    if (Test-Path -LiteralPath $SeamPath) {
        try { $seam = Get-Content -LiteralPath $SeamPath -Raw | ConvertFrom-Json -AsHashtable }
        catch { $seam = $null }
    }
    if ($seam -and $seam.ContainsKey('activeKey') -and -not [string]::IsNullOrWhiteSpace([string]$seam['activeKey'])) {
        $keyVar = [string]$seam['activeKey']
        $keySource = 'seam'
    }
    if ($seam -and $seam.ContainsKey('activeApiKeyEnv') -and -not [string]::IsNullOrWhiteSpace([string]$seam['activeApiKeyEnv'])) {
        $apiKeyVar = [string]$seam['activeApiKeyEnv']
    }
}

if ($keyVar -match '^OPENCODE_(GO\d+)_KEY$') {
    $keyLabel = $Matches[1]
    $keyValue = Get-PoolKeyValue -Name $keyVar -Scopes $PoolScope
}

if (-not $keyValue) {
    # Fallback: the seam (or the numbered key) could not provide a value, so the
    # child will inherit whatever this process carries. Say so out loud — a
    # silent fallback is exactly how the stale-key bug hid.
    $why = if ($keyVar) { "seam names $keyVar but no value is staged ($($PoolScope -join ', '))" }
           elseif (Test-Path -LiteralPath $SeamPath) { "seam $SeamPath does not name an activeKey" }
           else { "seam not readable at $SeamPath" }
    $fallbackNote = "preflight: $why; fell back to the inherited environment (this session's OPENCODE_GO_KEY may be stale - restart the host if it disagrees with the machine's active key)."
    $keySource = 'inherited fallback'
    $keyLabel = Get-PoolKeyLabel -Value $env:OPENCODE_GO_KEY -Scopes $PoolScope
    $keyValue = ''
}

$keyLine = "canary: key $(if ($keyLabel) { $keyLabel } else { 'unknown' }) ($keySource)"

if ($keySource -eq 'seam') {
    Write-Output "preflight: seam $SeamPath -> $(if ($keyLabel) { $keyLabel } else { 'unresolved' }) ($keyVar)"
}
elseif ($keySource -eq 'key-number') {
    Write-Output "preflight: -KeyNumber $KeyNumber -> $keyLabel ($keyVar)"
}

if ($fallbackNote) { Write-Output $fallbackNote }

if (-not $OpencodeCli) {
    $OpencodeCli = $env:OPENCODE_CLI_PATH
}
if (-not $OpencodeCli) {
    $cmd = Get-Command opencode -ErrorAction SilentlyContinue
    if ($cmd) { $OpencodeCli = $cmd.Source }
}
if (-not $OpencodeCli -or -not (Test-Path -LiteralPath $OpencodeCli)) {
    Write-Output "$keyLine FAIL"
    [Console]::Error.WriteLine('opencode CLI not found (set OPENCODE_CLI_PATH or put opencode on PATH); cannot preflight provider health.')
    exit 1
}

$job = Start-Job -ScriptBlock {
    param($cli, $model, $variant, $goKey, $apiVar, $apiKey)
    if (-not [string]::IsNullOrWhiteSpace($goKey)) {
        # Pin the machine's active key and never rely on what this child
        # inherited: that inherited value is the stale key this canary exists
        # to stop measuring.
        $env:OPENCODE_GO_KEY = $goKey
        if (-not [string]::IsNullOrWhiteSpace($apiVar)) { Set-Item -LiteralPath "Env:$apiVar" -Value $apiKey }
    }
    # opencode v2 removed `run --variant`; the variant is a suffix on the model
    # reference (`provider/model#variant`). Passing the old flag makes every
    # canary fail with "Unrecognized flag" — a false red for the whole pool.
    $modelRef = if ($variant -and $variant -ne 'default') { "$model#$variant" } else { $model }
    # `--standalone` is load-bearing: the default path talks to a long-lived
    # background service that CACHES the credential it booted with, so a key
    # change (env or auth.json) never reaches it and every key reports
    # "Go usage limit exceeded" (measured 2026-11-02/03). `--standalone` starts
    # a private server that reads the current environment - which is the only
    # way this canary can measure the key it just pinned.
    & $cli run 'reply with the single word pong' --model $modelRef --standalone 2>&1 | Out-String
} -ArgumentList $OpencodeCli, $Model, $Variant, $keyValue, $apiKeyVar, $keyValue

$done = Wait-Job -Job $job -Timeout $TimeoutSeconds
if (-not $done) {
    Stop-Job -Job $job | Out-Null
    Remove-Job -Job $job -Force
    Write-Output "$keyLine FAIL"
    [Console]::Error.WriteLine("Preflight canary timed out after ${TimeoutSeconds}s on model '$Model' (variant '$Variant') — provider unresponsive.")
    exit 1
}

$out = Receive-Job -Job $job | Out-String
Remove-Job -Job $job -Force

# Credential/quota/model-availability failures.
if ($out -match 'usage limit|rate_limit|exceeded|insufficient|unauthorized|401|403|429|not found|no such model') {
    Write-Output "$keyLine FAIL"
    [Console]::Error.WriteLine("Preflight canary failed on '$Model' (variant '$Variant'): $($out.Trim())")
    if ($out -match 'usage limit|rate_limit|quota|429') {
        [Console]::Error.WriteLine('  -> The canary ran --standalone (private server reading the current environment), so this limit is a real key/quota result, not a stale background-service artifact.')
    }
    exit 1
}
# Transport/model-shape failures that are NOT credential failures but still
# break dispatch — notably the Responses-API encrypted-reasoning replay error
# (`reasoning encrypted_content was not issued to this caller`) that a key
# cutover surfaces when a session replays account-bound reasoning items. A
# `default`-variant ping often passes; the model's real variant is what fails.
if ($out -match 'encrypted_content|not issued to this caller|invalid_request_error') {
    Write-Output "$keyLine FAIL"
    [Console]::Error.WriteLine("Preflight canary failed on '$Model' (variant '$Variant') with a model-transport error (not a credential failure): $($out.Trim())")
    [Console]::Error.WriteLine('  -> This is a model/config defect, not key exhaustion. See skills/providers/opencode/model-replacement and credential-rescue REFERENCE Runbook A (encrypted_content note).')
    exit 1
}
if ($out -notmatch 'pong') {
    Write-Output "$keyLine FAIL"
    [Console]::Error.WriteLine("Preflight canary on '$Model' (variant '$Variant') returned unexpected output: $($out.Trim())")
    exit 1
}

Write-Output "$keyLine PASS"
exit 0
