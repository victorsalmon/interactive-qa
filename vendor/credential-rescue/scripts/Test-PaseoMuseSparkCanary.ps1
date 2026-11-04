#Requires -Version 5.1
<#
.SYNOPSIS
    Very quick model-name canary for the fleet worker model (no inference by default).

.DESCRIPTION
    Proves the EXACT endpoint name `opencode-go/deepseek-v4.1-flash` resolves,
    without spending inference tokens: `opencode models opencode-go`
    must list it. This is the name Paseo must pass through verbatim — a bare
    `opencode/<model>` form does NOT exist upstream for the paid GO names, which
    is exactly the daemon's `Model not found` turn_failed. The file keeps its
    historical name because the incident record it came from was
    `Skills/_archive/iqa-superseded-2026-11-03/credential-rescue/assets/paseo-muse-spark-resolution-2026-10-15.md`
    (archived 2026-11-03; the live body is
    `interactive-qa-agent/vendor/credential-rescue/assets/paseo-muse-spark-resolution-2026-10-15.md`).
    The model it checks is
    the current fleet worker, DeepSeek V4.1 Flash (operator directive
    2026-10-28 — Muse Spark 1.3 is retired for agent creation).

    With -WithRun it additionally sends the one-word `pong` prompt through
    `opencode run` (User-scope key, the same values a restarted daemon hands
    to new helpers), classifying model-not-found / quota / transport failures.
    Secret VALUES are never printed — key NAMES and match labels only.

    Owned by Skills/credential-rescue. Called automatically by
    Repair-Paseo.ps1 (classify + verify); safe to run standalone any time Paseo
    reports a model error.

.PARAMETER Model
    Exact opencode model string. Default 'opencode-go/deepseek-v4.1-flash'.

.PARAMETER WithRun
    Also run the one-word inference proof (~60s, spends tokens).

.PARAMETER RunTimeoutSeconds
    Kill the inference canary after this long. Default 60.

.PARAMETER OpencodeCli
    Path to the opencode CLI. Defaults to $env:OPENCODE_CLI_PATH, then
    `opencode` on PATH, then the fleet install.

.EXAMPLE
    pwsh -File Test-PaseoMuseSparkCanary.ps1
.EXAMPLE
    pwsh -File Test-PaseoMuseSparkCanary.ps1 -WithRun
#>
[CmdletBinding()]
param(
    [string]$Model = 'opencode-go/deepseek-v4.1-flash',
    [switch]$WithRun,
    [int]$RunTimeoutSeconds = 60,
    [string]$OpencodeCli = ''
)

$ErrorActionPreference = 'Stop'

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
    [Console]::Error.WriteLine('canary: opencode CLI not found (set OPENCODE_CLI_PATH or put opencode on PATH).')
    exit 1
}

$provider, $modelId = $Model -split '/', 2
if (-not $provider -or -not $modelId) {
    [Console]::Error.WriteLine("canary: model '$Model' is not provider/model shaped.")
    exit 1
}

# --- 1. name resolution (fast, no tokens) ---
Write-Output "canary: resolving '$Model' via 'opencode models' ..."
# `opencode models` takes NO provider argument in the current CLI (a positional
# arg exits non-zero with USAGE text, which used to read as a NAME failure).
$listed = & $OpencodeCli models 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) {
    [Console]::Error.WriteLine("canary FAIL: 'opencode models' errored: $($listed.Trim())")
    exit 1
}
if ($listed -notmatch [regex]::Escape($Model)) {
    [Console]::Error.WriteLine("canary FAIL: '$Model' not listed under provider '$provider'.")
    if ($provider -eq 'opencode-go' -and $modelId -eq 'muse-spark-1.3-contributor') {
        [Console]::Error.WriteLine("  -> '$Model' is the paid GO name. 'opencode/$modelId' does NOT exist upstream")
        [Console]::Error.WriteLine("     (only opencode/muse-spark-1.3-contributor-free does) — that is the Paseo")
        [Console]::Error.WriteLine("     'Model not found: opencode/muse-spark-1.3-contributor' turn_failed verbatim.")
        [Console]::Error.WriteLine("     Paseo must pass '$Model' through with the opencode-go/ prefix intact.")
    }
    exit 1
}
Write-Output "  PASS  name resolves: $Model"

if (-not $WithRun) {
    Write-Output "canary: name check only (no inference). For the pong proof run this script with -WithRun, or run: opencode run 'reply with the single word pong' --model $Model --standalone (Repair-Paseo.ps1 itself has no -WithRun flag; it only surfaces this line)."
    exit 0
}

# --- 2. inference proof (spends tokens, ~60s) ---
Write-Output "canary: inference proof '$Model' ..."
$job = Start-Job -ScriptBlock {
    param($cli, $model)
    # Same credential a restarted daemon hands new helpers (names only out here).
    $env:OPENCODE_GO_KEY = [Environment]::GetEnvironmentVariable('OPENCODE_GO_KEY', 'User')
    $env:OPENCODE_API_KEY = [Environment]::GetEnvironmentVariable('OPENCODE_API_KEY', 'User')
    # The CLI no longer accepts --variant; the variant rides on the model id
    # (`provider/model#variant`) and only real variants are accepted.
    & $cli run 'reply with the single word pong' --model $model 2>&1 | Out-String
} -ArgumentList $OpencodeCli, $Model

$done = Wait-Job -Job $job -Timeout $RunTimeoutSeconds
if (-not $done) {
    Stop-Job -Job $job | Out-Null
    Remove-Job -Job $job -Force
    [Console]::Error.WriteLine("canary FAIL: inference timed out after ${RunTimeoutSeconds}s (provider unresponsive, not a name failure).")
    exit 1
}
$out = Receive-Job -Job $job | Out-String
Remove-Job -Job $job -Force
if ($out -match 'Model not found|no such model') {
    [Console]::Error.WriteLine("canary FAIL: endpoint reports model-not-found: $($out.Trim())")
    exit 1
}
if ($out -match 'usage limit|rate_limit|exceeded|insufficient|unauthorized|401|403|429') {
    [Console]::Error.WriteLine("canary FAIL: quota/auth class (name is fine, key is not): $($out.Trim())")
    exit 1
}
if ($out -match 'encrypted_content|not issued to this caller') {
    [Console]::Error.WriteLine('canary FAIL: model-transport class (encrypted-reasoning replay), not credential — see credential-rescue REFERENCE Runbook A.')
    exit 1
}
if ($out -notmatch 'pong') {
    [Console]::Error.WriteLine("canary FAIL: unexpected output: $($out.Trim())")
    exit 1
}
Write-Output '  PASS  endpoint answered pong'
exit 0
