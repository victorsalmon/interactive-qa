#Requires -Version 5.1
<#
.SYNOPSIS
    Switch the Salmon Run opencode-go credential to a fresh pool key (Salmon track).

.DESCRIPTION
    Fleet-canonical Salmon-track cutover for opencode-go key exhaustion, owned
    by Skills/credential-rescue. The pool lives in Machine env vars
    OPENCODE_GO1..5_KEY; the interactive/fallback surfaces hold a literal key
    VALUE and must be repointed:

      User env  OPENCODE_GO_KEY    - fallback consumed by the salmon-run
                                     Opencode executor and exported to the CLI
      User env  OPENCODE_API_KEY   - opencode provider env credential
      auth.json <XDG_DATA_HOME>\opencode\auth.json (live; D:\opencode-data here)
                  ."opencode-go".key (and ."opencode".key when present)
      ~/.machine/config.json execution.defaultCodingKey + caps (lane priority)

    Paseo is a SEPARATE consumer with its own track: after this cutover, run
    scripts/Repair-Paseo.ps1 (or pass -RestartPaseo to delegate to it) so the
    long-lived opencode helpers pick up the new key. This script never touches
    ~/.paseo/config.json itself. Existing processes keep the old env until restarted.

    If the EXHAUSTED key is a pool key, lanes will keep selecting it (the pool
    picks resolvable+under-cap keys, not healthy keys). Use -RetirePoolKey to
    clear its Machine env var so the pool skips it (logged removal), or re-run
    Tools/Sync-SalmonRunCodingKeys.ps1 after flipping its OPENCODE_GO<n>_ON
    flag in AWS Secrets Manager (requires working ~/.aws).

    Secret VALUES are never printed. Every mutation appends one JSON line to
    $env:CL_REPOS_ROOT\Tasks\Logs\credential-changes.jsonl (machine rule 1).

    A cutover is all-or-nothing. The pre-switch state of every surface this
    script writes (seam activeKey, User OPENCODE_GO_KEY / OPENCODE_API_KEY,
    auth.json, ~/.machine/config.json) is captured before the first write, and a
    post-write canary failure restores it and exits 1 with `rolled-back` - the
    machine is never left with surfaces that disagree. If that restore itself
    fails, the run writes ~/.machine/state/key-check/partial-cutover.json (labels
    only: {from, to, surfaces, at, runId}) and exits 6; the next invocation
    resolves it with -ResumePartial (complete or revert), and
    Invoke-KeyCheckCutover.ps1 does that automatically.

    Exit codes: 0 cutover applied and canaried; 1 canary failed and every
    surface was rolled back (or a partial cutover was reverted); 6 the rollback
    failed and a partial marker is on disk.

.PARAMETER KeyNumber
    Pool index to activate (1-5). Reads OPENCODE_GO<n>_KEY from Machine scope.

.PARAMETER RetirePoolKey
    Optional pool index (1-5) whose Machine env var should be CLEARED because
    the key is exhausted/dead, so lanes stop selecting it.

.PARAMETER Fast
    Fast path (default when the seam's canary.defaultMode is 'fast'): canary
    only the fleet default worker model (deepseek-v4.1-flash), run
    session hygiene only when poisoned parts actually exist, and project
    ~/.machine/config.json in the same pass. This is the near-instant path for
    "GO<n> is exhausted, GO<m> is fresh" — verify the new key and repoint.
    Safety is unchanged: the pre-check, one real canary, and the credential log
    all still run.

.PARAMETER Full
    Run the full canary set (every model in the seam's `full` block, not just
    the fleet default deepseek-v4.1-flash) and force the
    session-hygiene pass. Use when the operator wants the wider model-transport
    signal and does not mind the deepseek canary's current timeout.

.PARAMETER SeamPath
    The single cutover seam (registry) this script projects from. Defaults to
    ..\assets\opencode-go-cutover.json beside this script. The seam owns which
    key is active, pool order, per-key caps, the provider cap, and the canary
    and hygiene policies.

.PARAMETER RuntimeConfig
    ~/.machine/config.json to project execution.defaultCodingKey and the caps
    into. Defaults to $env:USERPROFILE\.machine\config.json. Pass -SkipRuntimeConfig
    to leave it untouched.

.PARAMETER SkipRuntimeConfig
    Do not project the seam into ~/.machine/config.json. Use only when another
    tool owns that file in the same change.

.PARAMETER SkipHygiene
    Alias for -SkipSessionCleanup, named to match the seam's hygiene policy.

.PARAMETER SkipCanary
    Skip the post-cutover canary set. Use only when the opencode CLI is
    unavailable; the canary is the guard that a cutover did not surface a
    latent model-transport defect.

.PARAMETER OpencodeCli
    Path to the opencode CLI used for the canary. Defaults to
    $env:OPENCODE_CLI_PATH, then `opencode` on PATH, then the fleet install.

.PARAMETER CanaryScript
    Test seam: a stub sender invoked instead of the CLI, exactly as the real
    canary would be - with the key under test in its environment and -KeyLabel
    naming the key (GO<n>). Used by the regression tests to prove the canary is
    invoked with the NEW key even when the caller's process env is stale.

.PARAMETER StateDir
    Where the rollback snapshot (cutover-snapshot/) and the partial-application
    marker (partial-cutover.json) live. Default
    ~/.machine/state/key-check - the same directory Key Check keeps its state in.

.PARAMETER FixtureState
    Test seam: a JSON state store ({"pool":{...},"user":{...}}) used instead of
    the Machine/User registry, so the switch can be exercised end to end
    without writing a real credential. Values are fixture strings, never keys.

.PARAMETER ResumePartial
    Do not start a fresh switch. Read partial-cutover.json, restore the recorded
    pre-switch state, then either COMPLETE the recorded target (when it is still
    the requested key - the normal cutover runs from the restored base and its
    own canary decides) or stay REVERTED. Clears the marker when decided.

.PARAMETER RunId
    Identifier recorded in the rollback snapshot, the partial marker and the
    audit log. Default: now.

.PARAMETER ConfigPath
    opencode config jsonc to read the configured opencode-go model transport
    from. Defaults to <XDG_CONFIG_HOME>\opencode\opencode.jsonc.

.PARAMETER AuthJson
    opencode auth store path. Default: <XDG_DATA_HOME>\opencode\auth.json
    (User XDG_DATA_HOME; D:\opencode-data\opencode\auth.json on this box).
    Falls back to the legacy $env:CL_REPOS_ROOT\Tools\opencode-data\opencode\auth.json
    only when XDG_DATA_HOME is unset.

.PARAMETER SkipSessionCleanup
    Skip the session-hygiene step. By default the cutover strips stored
    Responses-API reasoning metadata (part.metadata.openai, which carries the
    account-bound reasoningEncryptedContent) from every session, so continuing
    a pre-switch session on the new key cannot fail with `reasoning
    encrypted_content was not issued to this caller`. Rows are backed up to a
    JSON file before the strip.

.PARAMETER RestartPaseo
    After the Salmon cutover, delegate to scripts/Repair-Paseo.ps1 (worker
    restart) so Paseo helpers pick up the new key. Composition, not duplication:
    the pin + restart live in Repair-Paseo only.

.PARAMETER PaseoOnly
    DEPRECATED: forwards to scripts/Repair-Paseo.ps1 -KeyNumber <n> and exits.
    Kept so old callers fail with a redirect instead of an unknown-parameter error.

.PARAMETER SkipPaseo
    DEPRECATED no-op (Paseo is never touched by this script anymore).

.PARAMETER DispatchMode
    L2 dispatch-modes awareness (plan dispatch-modes-plan.md §4): under
    'single-active' (default) a provider cap above the active key's per-key cap
    is a misconfiguration and warns loudly; under 'waterfall'/'round-robin'
    spill past the active key is by design, so the same condition is reported
    as expected instead of warned. Unknown values throw (fail-closed).

.EXAMPLE
    pwsh -File Switch-OpencodeGoKey.ps1 -KeyNumber 5 -Reason "GO4 exhausted"
.EXAMPLE
    pwsh -File Switch-OpencodeGoKey.ps1 -KeyNumber 3 -RetirePoolKey 5 -DryRun
.EXAMPLE
    pwsh -File Switch-OpencodeGoKey.ps1 -KeyNumber 5 -RestartPaseo
    pwsh -File Repair-Paseo.ps1 -VerifyOnly
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateRange(1, 9)]
    [int]$KeyNumber,
    [ValidateRange(1, 9)]
    [int]$RetirePoolKey = 0,
    [string]$AuthJson = '',
    [switch]$DryRun,
    [switch]$SkipCanary,
    [switch]$SkipSessionCleanup,
    [switch]$SkipHygiene,
    [switch]$Fast,
    [switch]$Full,
    [switch]$SkipRuntimeConfig,
    [switch]$SkipPaseo,
    [switch]$PaseoOnly,
    [string]$SeamPath = '',
    [string]$RuntimeConfig = '',
    [string]$PaseoConfig = '',
    [string]$PaseoCli = '',
    [switch]$RestartPaseo,
    [string]$OpencodeCli = '',
    [string]$ConfigPath = '',
    [string]$Actor = 'agent/credential-rescue',
    [string]$Reason = 'opencode-go key exhaustion cutover',
    [string]$LogPath = '',
    [ValidateSet('single-active', 'waterfall', 'round-robin')]
    [string]$DispatchMode = 'single-active',
    [string]$RunId = '',
    [string]$StateDir = '',
    [string]$CanaryScript = '',
    [string]$FixtureState = '',
    [switch]$ResumePartial
)

$ErrorActionPreference = 'Stop'
$FleetRoot = if ($env:CL_REPOS_ROOT) { $env:CL_REPOS_ROOT } else { $env:CSBK_REPOS_ROOT }
if ([string]::IsNullOrWhiteSpace($FleetRoot)) {
    # Installed-package run (no fleet checkout). The fleet Tools/ paths do not
    # exist here, but the credential log is MACHINE state and must still be
    # written: machine state is never allowed to become a fleet dependency.
    $FleetRoot = ''
}
if ([string]::IsNullOrWhiteSpace($LogPath)) {
    $LogPath = if ($FleetRoot) { Join-Path $FleetRoot 'Tasks\Logs\credential-changes.jsonl' }
               else { Join-Path $HOME '.machine\logs\credential-changes.jsonl' }
}
. (Join-Path $PSScriptRoot 'lib\CredLog.ps1')
. (Join-Path $PSScriptRoot 'lib\PaseoCommon.ps1')

function Write-CredLogHere {
    param([string]$Action, [string]$Target, [string]$Detail)
    Write-CredLog -Action $Action -Target $Target -Detail $Detail -Actor $Actor -Reason $Reason -LogPath $LogPath
}

# --- deprecated Paseo entry: forward, do not duplicate ---
if ($PaseoOnly) {
    Write-Warning '-PaseoOnly is deprecated: forwarding to Repair-Paseo.ps1 (the single Paseo entry).'
    & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'Repair-Paseo.ps1') -KeyNumber $KeyNumber -Actor $Actor -LogPath $LogPath
    exit $LASTEXITCODE
}
if ($SkipPaseo) { Write-Warning '-SkipPaseo is a deprecated no-op: this script never touches Paseo anymore.' }
if ($PaseoConfig) { Write-Warning '-PaseoConfig is deprecated and ignored here; Repair-Paseo.ps1 owns the Paseo config.' }
if ($PaseoCli) { Write-Warning '-PaseoCli is deprecated and ignored here; Repair-Paseo.ps1 owns the Paseo CLI.' }

# --- state surface: registry in production, a fixture JSON under test --------
# Every User/Machine environment read and write goes through these helpers, so
# the tests can drive the whole switch (read the pool, capture the pre-switch
# state, write, roll back) without touching this machine's real registry or a
# real credential. In production they are thin wrappers over the registry.
$StateDir = if ($StateDir) { $StateDir } else { Join-Path $env:USERPROFILE '.machine\state\key-check' }
$MarkerPath = Join-Path $StateDir 'partial-cutover.json'
$SnapshotDir = Join-Path $StateDir 'cutover-snapshot'
$SnapshotStatePath = Join-Path $SnapshotDir 'snapshot.json'
if ([string]::IsNullOrWhiteSpace($RunId)) { $RunId = (Get-Date).ToString('yyyyMMddTHHmmss') }

$FixtureStore = $null
if ($FixtureState) {
    if (-not (Test-Path -LiteralPath $FixtureState)) { throw "fixture state not found: $FixtureState" }
    $FixtureStore = Get-Content -LiteralPath $FixtureState -Raw | ConvertFrom-Json
    foreach ($prop in @('pool', 'user')) {
        if ($null -eq $FixtureStore.PSObject.Properties[$prop]) {
            $FixtureStore | Add-Member -NotePropertyName $prop -NotePropertyValue ([pscustomobject]@{}) -Force
        }
    }
}

function Save-FixtureStore {
    if (-not $FixtureStore) { return }
    $FixtureStore | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $FixtureState -Encoding utf8 -NoNewline
}

function Get-StateValue {
    param([string]$Name, [string]$Scope)
    if ($FixtureStore) {
        $block = if ($Scope -eq 'Machine') { $FixtureStore.pool } else { $FixtureStore.user }
        $p = $block.PSObject.Properties[$Name]
        if ($p) { return [string]$p.Value }
        if ($Scope -eq 'Machine') {
            $p = $FixtureStore.user.PSObject.Properties[$Name]
            if ($p) { return [string]$p.Value }
        }
        return ''
    }
    return [Environment]::GetEnvironmentVariable($Name, $Scope)
}

function Set-StateValue {
    param([string]$Name, [string]$Value, [string]$Scope)
    if ($FixtureStore) {
        $block = if ($Scope -eq 'Machine') { $FixtureStore.pool } else { $FixtureStore.user }
        $block | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
        Save-FixtureStore
        return
    }
    [Environment]::SetEnvironmentVariable($Name, $Value, $Scope)
}

function Resolve-PoolKey {
    # Pool keys are normally Machine scope; staged User-scope keys must resolve
    # too (a rescue that could not get a UAC click). Machine -> User fallback.
    param([string]$Name, [ref]$ScopeOut)
    foreach ($scope in @('Machine', 'User')) {
        $v = Get-StateValue -Name $Name -Scope $scope
        if (-not [string]::IsNullOrWhiteSpace($v)) {
            if ($ScopeOut) { $ScopeOut.Value = $scope }
            return $v
        }
    }
    if ($ScopeOut) { $ScopeOut.Value = '' }
    return ''
}

function Get-PoolLabel {
    # Compare-only pool match: GO<n> or no-pool-match. Never returns a value.
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return 'no-pool-match' }
    foreach ($n in 1..9) {
        $pv = Resolve-PoolKey -Name "OPENCODE_GO${n}_KEY"
        if (-not [string]::IsNullOrWhiteSpace($pv) -and $pv -ceq $Value) { return "GO$n" }
    }
    return 'no-pool-match'
}

# --- pre-switch snapshot: the rollback guarantee ------------------------------
# The switch writes four surfaces (seam activeKey, User OPENCODE_GO_KEY /
# OPENCODE_API_KEY, auth.json, ~/.machine/config.json). A post-write canary
# failure must never leave them disagreeing, so the exact pre-write bytes of
# every file surface - and the pre-write User values - are captured first and
# restored on failure. The snapshot lives beside auth.json's own .bak siblings
# (same trust boundary) and is deleted once a run ends in a decided state.
function New-CutoverSnapshot {
    param([string]$TargetLabel, [string]$FromLabel)
    if (Test-Path -LiteralPath $SnapshotDir) { Remove-Item -LiteralPath $SnapshotDir -Recurse -Force }
    $null = New-Item -ItemType Directory -Path $SnapshotDir -Force
    $files = [ordered]@{}
    $paths = [ordered]@{ seam = $SeamPath; authJson = $AuthJson; runtimeConfig = $RuntimeConfig }
    foreach ($key in $paths.Keys) {
        $path = [string]$paths[$key]
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        $present = Test-Path -LiteralPath $path
        $files[$key] = [ordered]@{ path = $path; present = $present; copy = '' }
        if ($present) {
            $copyName = Join-Path $SnapshotDir ("{0}{1}" -f $key, [System.IO.Path]::GetExtension($path))
            Copy-Item -LiteralPath $path -Destination $copyName -Force
            $files[$key].copy = $copyName
        }
    }
    $state = [ordered]@{
        version  = 1
        at       = (Get-Date).ToString('o')
        runId    = $RunId
        from     = $FromLabel
        to       = $TargetLabel
        surfaces = $files
        user     = [ordered]@{
            OPENCODE_GO_KEY  = (Get-StateValue -Name 'OPENCODE_GO_KEY' -Scope 'User')
            OPENCODE_API_KEY = (Get-StateValue -Name 'OPENCODE_API_KEY' -Scope 'User')
        }
    }
    Set-Content -LiteralPath $SnapshotStatePath -Value ($state | ConvertTo-Json -Depth 10) -Encoding utf8 -NoNewline
    return [pscustomobject]$state
}

function Read-CutoverSnapshot {
    if (-not (Test-Path -LiteralPath $SnapshotStatePath)) { return $null }
    try { return (Get-Content -LiteralPath $SnapshotStatePath -Raw | ConvertFrom-Json) }
    catch { return $null }
}

function Restore-CutoverSnapshot {
    # Put every surface back exactly as it was before the write. Returns the
    # list of surfaces it could NOT restore; empty means the rollback is clean.
    param($Snapshot)
    $errors = @()
    if (-not $Snapshot) { return @('snapshot-unreadable') }
    foreach ($key in @('seam', 'authJson', 'runtimeConfig')) {
        $entry = $null
        # The in-run snapshot is an ordered dictionary; a snapshot re-read from
        # disk is a PSCustomObject. Support both - a missed lookup would report
        # a clean rollback that restored nothing.
        if ($Snapshot.surfaces -is [System.Collections.IDictionary]) {
            if ($Snapshot.surfaces.Contains($key)) { $entry = $Snapshot.surfaces[$key] }
        } elseif ($Snapshot.surfaces.PSObject.Properties[$key]) {
            $entry = $Snapshot.surfaces.$key
        }
        if (-not $entry) { continue }
        try {
            if ($entry.present) {
                if (-not (Test-Path -LiteralPath ([string]$entry.copy))) { throw 'snapshot copy missing' }
                [System.IO.File]::WriteAllBytes([string]$entry.path, [System.IO.File]::ReadAllBytes([string]$entry.copy))
            } elseif (Test-Path -LiteralPath ([string]$entry.path)) {
                Remove-Item -LiteralPath ([string]$entry.path) -Force
            }
        } catch { $errors += ("{0}: {1}" -f $key, $_.Exception.Message) }
    }
    foreach ($name in @('OPENCODE_GO_KEY', 'OPENCODE_API_KEY')) {
        try { Set-StateValue -Name $name -Value ([string]$Snapshot.user.$name) -Scope 'User' }
        catch { $errors += ("{0}: {1}" -f $name, $_.Exception.Message) }
    }
    if (-not $FixtureStore) {
        $env:OPENCODE_GO_KEY = Get-StateValue -Name 'OPENCODE_GO_KEY' -Scope 'User'
        $env:OPENCODE_API_KEY = Get-StateValue -Name 'OPENCODE_API_KEY' -Scope 'User'
    }
    return $errors
}

function Remove-CutoverSnapshot {
    if (Test-Path -LiteralPath $SnapshotDir) { Remove-Item -LiteralPath $SnapshotDir -Recurse -Force }
}

function Write-PartialMarker {
    # The rollback itself failed: record labels only (never a value) so the next
    # invocation can complete or revert deliberately instead of guessing.
    param([string]$FromLabel, [string]$ToLabel, [object[]]$Surfaces, [string[]]$RollbackErrors)
    $payload = [ordered]@{
        from     = $FromLabel
        to       = $ToLabel
        surfaces = @($Surfaces)
        at       = (Get-Date).ToString('o')
        runId    = $RunId
    }
    $dir = Split-Path -Parent $MarkerPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
    Set-Content -LiteralPath $MarkerPath -Value ($payload | ConvertTo-Json -Depth 8) -Encoding utf8 -NoNewline
    Write-CredLogHere -Action 'partial-cutover' -Target 'key-check partial-cutover marker' -Detail ("from {0} to {1}; rollback failed on: {2}" -f $FromLabel, $ToLabel, (@($RollbackErrors) -join '; '))
}

function Clear-PartialMarker {
    if (Test-Path -LiteralPath $MarkerPath) { Remove-Item -LiteralPath $MarkerPath -Force }
}


# --- load the single cutover seam (registry) ---
# The seam owns which key is active, pool order, caps, and the canary/hygiene
# policies. Everything below projects FROM it, so changing the active key is a
# one-file edit. Missing seam = fall back to the historical hardcoded behaviour.
if ([string]::IsNullOrWhiteSpace($SeamPath)) {
    $SeamPath = Join-Path $PSScriptRoot '..\assets\opencode-go-cutover.json'
}
$SeamPath = [System.IO.Path]::GetFullPath($SeamPath)
$seam = $null
if (Test-Path -LiteralPath $SeamPath) {
    try { $seam = Get-Content -LiteralPath $SeamPath -Raw | ConvertFrom-Json }
    catch { Write-Warning "could not parse seam $SeamPath : $($_.Exception.Message)" }
}

# -Full beats -Fast; neither means "use the seam default".
$canaryMode = 'fast'
if ($seam -and $seam.canary.defaultMode) { $canaryMode = [string]$seam.canary.defaultMode }
if ($Full) { $canaryMode = 'full' }
if ($Fast) { $canaryMode = 'fast' }

# Resolve the LIVE opencode data dir. XDG_DATA_HOME is authoritative; the
# $env:CL_REPOS_ROOT\Tools\opencode-data\opencode path is a legacy 113-byte stub (no
# opencode.db) that silently accepts writes and changes nothing.
if ([string]::IsNullOrWhiteSpace($AuthJson)) {
    $dataHome = [Environment]::GetEnvironmentVariable('XDG_DATA_HOME', 'User')
    if ([string]::IsNullOrWhiteSpace($dataHome)) {
        $dataHome = [Environment]::GetEnvironmentVariable('XDG_DATA_HOME', 'Process')
    }
    if ([string]::IsNullOrWhiteSpace($dataHome)) {
        if (-not $FleetRoot) {
            throw 'XDG_DATA_HOME is unset and there is no fleet checkout to fall back to; set XDG_DATA_HOME or pass -AuthJson.'
        }
        $dataHome = Join-Path $FleetRoot 'Tools\opencode-data'
        Write-Warning "XDG_DATA_HOME unset; falling back to legacy $dataHome"
    }
    $AuthJson = Join-Path $dataHome 'opencode\auth.json'
}

# Resolve the runtime config path up front: the rollback snapshot must capture
# ~/.machine/config.json BEFORE any write, not when the projection block runs.
if (-not $SkipRuntimeConfig -and [string]::IsNullOrWhiteSpace($RuntimeConfig)) {
    $RuntimeConfig = Join-Path $env:USERPROFILE '.machine\config.json'
}

$targetName = "OPENCODE_GO${KeyNumber}_KEY"
$targetLabel = "GO$KeyNumber"
$targetScope = ''
$targetVal = Resolve-PoolKey -Name $targetName -ScopeOut ([ref]$targetScope)
if ([string]::IsNullOrWhiteSpace($targetVal)) { throw "$targetName is not set at Machine or User scope - cannot activate." }

# Resolve the live opencode SQLite store (session-hygiene target).
$opencodeDb = Join-Path (Split-Path -Parent $AuthJson) 'opencode.db'

# --- resolve the opencode CLI for the canary (env -> PATH -> fleet install) ---
$canaryCli = $OpencodeCli
if (-not $canaryCli) { $canaryCli = $env:OPENCODE_CLI_PATH }
if (-not $canaryCli) {
    $cmd = Get-Command opencode -ErrorAction SilentlyContinue
    if ($cmd) { $canaryCli = $cmd.Source }
}
if (-not $canaryCli -and $FleetRoot) {
    $fallback = Join-Path $FleetRoot 'Tools\opencode-standalone\node_modules\.bin\opencode.ps1'
    if (Test-Path -LiteralPath $fallback) { $canaryCli = $fallback }
}

# --- resolve the configured opencode-go model + its transport BEFORE touching
#     the credential. A Responses-API transport pin (`"npm": "@ai-sdk/openai"`)
#     with encrypted-reasoning variants is the defect class that a key cutover
#     turns into `reasoning encrypted_content was not issued to this caller`;
#     surface it up front so the operator sees the model name and endpoint the
#     cutover is about to exercise. ---
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $cfgHome = [Environment]::GetEnvironmentVariable('XDG_CONFIG_HOME', 'User')
    if ([string]::IsNullOrWhiteSpace($cfgHome)) { $cfgHome = Join-Path $env:USERPROFILE '.config' }
    $ConfigPath = Join-Path $cfgHome 'opencode\opencode.jsonc'
}
$configuredModel = $null
$configuredNpm = $null
$configuredBaseUrl = $null
if (Test-Path -LiteralPath $ConfigPath) {
    try {
        $cfgText = Get-Content -LiteralPath $ConfigPath -Raw
        # Strip // line comments so jsonc parses (block comments are not used here).
        $cfgJson = ($cfgText -split "`n" | ForEach-Object { $_ -replace '^\s*//.*$', '' }) -join "`n"
        $cfg = $cfgJson | ConvertFrom-Json
        $ocg = $cfg.provider.'opencode-go'
        if ($ocg) {
            $configuredBaseUrl = $ocg.options.baseURL
            # The Responses-API transport pin can live at the PROVIDER level
            # (this box: "npm": "@ai-sdk/openai" under provider opencode-go) —
            # read it there first, then let a model-level npm override it. Only
            # checking the model entry missed this and reported a false "clean".
            if ($ocg.npm) { $configuredNpm = [string]$ocg.npm }
            foreach ($p in $ocg.models.PSObject.Properties) { $configuredModel = $p.Name; if ($p.Value.npm) { $configuredNpm = [string]$p.Value.npm }; break }
        }
    } catch { Write-Warning "could not parse $ConfigPath : $($_.Exception.Message)" }
}
$modelVariant = @{ 'deepseek-v4.1-flash' = 'low'; 'deepseek-v4-pro' = 'max' }

Write-Output ''
Write-Output '--- model pre-check (before credential change) ---'
if ($configuredModel) {
    Write-Output ("configured opencode-go model : {0}" -f $configuredModel)
    Write-Output ("  endpoint                   : {0}" -f $configuredBaseUrl)
    Write-Output ("  transport npm              : {0}" -f ($configuredNpm ?? '<provider default>'))
    if ($configuredNpm -eq '@ai-sdk/openai') {
        Write-Warning "  transport is the Responses API (@ai-sdk/openai) with encrypted-reasoning variants — a key cutover will surface 'reasoning encrypted_content was not issued to this caller' on existing sessions. Prefer the provider default transport (drop the npm pin) for this model."
    }
} else {
    Write-Output "configured opencode-go model : <none found> ($ConfigPath)"
}

# The canary set comes from the seam: 'fast' is the fleet default worker model
# only; 'full' adds the second standard model. The configured model is always
# included at its real variant, so a cutover can never pass while the model the
# box is actually configured to run stays untested. -SkipCanary skips entirely.
$canarySet = @()
if (-not $SkipCanary) {
    $seamCanary = @()
    if ($seam -and $seam.canary) {
        $chosen = if ($canaryMode -eq 'full') { $seam.canary.full } else { $seam.canary.fast }
        if ($chosen) { $seamCanary = @($chosen) }
    }
    if ($seamCanary.Count -eq 0) {
        # No seam (or no canary block): historical fallback set.
        $seamCanary = @(
            [pscustomobject]@{ model = 'opencode-go/deepseek-v4.1-flash'; variant = 'low' }
            [pscustomobject]@{ model = 'opencode-go/deepseek-v4-pro'; variant = 'max' }
        )
        if ($canaryMode -eq 'fast') { $seamCanary = @($seamCanary[0]) }
    }
    foreach ($c in $seamCanary) {
        $m = [string]$c.model
        # The configured model must be canaried at ITS real variant, not the
        # seam's default, so a latent model-transport defect on the model this
        # box actually runs is caught.
        $v = [string]$c.variant
        if ($configuredModel -and $m -eq "opencode-go/$configuredModel") {
            $v = 'default'; if ($modelVariant.ContainsKey($configuredModel)) { $v = $modelVariant[$configuredModel] }
        }
        $canarySet += ,@($m, $v)
    }
    # Dedupe WITHOUT piping through Select-Object -Unique: with a single-entry
    # set the pipe unwraps the pair and the model/variant become two separate
    # strings (rendering "o --variant p"). A keyed rebuild preserves the pairs.
    $deduped = @()
    $seen = @{}
    foreach ($entry in $canarySet) {
        $key = (@($entry) -join '|')
        if (-not $seen.ContainsKey($key)) { $seen[$key] = $true; $deduped += ,@($entry) }
    }
    $canarySet = $deduped
}

function Invoke-GoCanary {
    <#
    .SYNOPSIS
        Canary ONE model against ONE key value, and say which key label it used.

    .DESCRIPTION
        The key under test arrives as an explicit argument and is injected into
        the canary's own environment. Nothing here may read an inherited
        OPENCODE_GO_KEY: the switch's caller (a lane, the cutover helper) holds
        the pre-switch value in its process env, so an inherited value tests the
        OLD key and reports a healthy cutover as a failure.

        The CLI is also run `--standalone` on purpose. `opencode run` otherwise
        talks to the long-lived `serve --service` background server, which
        freezes its environment at spawn: it keeps answering with the
        pre-cutover key's quota error forever (`AI.Error.QuotaExceeded: Go usage
        limit exceeded`), so a non-standalone canary measures the daemon, not
        the key just written. A private server inherits THIS environment.
    #>
    param([string]$Model, [string]$Variant, [string]$KeyValue, [string]$KeyLabel)

    $savedGo = $env:OPENCODE_GO_KEY
    $savedApi = $env:OPENCODE_API_KEY
    try {
        $env:OPENCODE_GO_KEY = $KeyValue
        $env:OPENCODE_API_KEY = $KeyValue
        $env:OPENCODE_CANARY_KEY_LABEL = $KeyLabel

        if ($CanaryScript) {
            # Test seam: a stub sender receives the key in its environment.
            $stubOut = & pwsh -NoProfile -File $CanaryScript -Model $Model -Variant $Variant -KeyLabel $KeyLabel 2>&1 | Out-String
            if ($stubOut.Trim()) { Write-Output $stubOut.Trim() }
            return $LASTEXITCODE
        }

        # The variant is part of the model id; opencode v2 has no --variant flag.
        $target = if ($Variant -and $Variant -ne 'default') { "$Model#$Variant" } else { $Model }
        $out = & $canaryCli run 'reply with the single word pong' --model $target --standalone 2>&1 | Out-String
        $text = $out.Trim()
        if ($out -match 'encrypted_content|not issued to this caller') { Write-Output $text; return 1 }
        if ($out -match 'usage limit|rate_limit|exceeded|insufficient|unauthorized|401|403|429|not found|no such model') { Write-Output $text; return 1 }
        if ($out -notmatch 'pong') { Write-Output $text; return 1 }
        return 0
    } finally {
        $env:OPENCODE_GO_KEY = $savedGo
        $env:OPENCODE_API_KEY = $savedApi
        Remove-Item Env:\OPENCODE_CANARY_KEY_LABEL -ErrorAction SilentlyContinue
    }
}

# --- resume a partial cutover before any fresh write -------------------------
# A previous run wrote some surfaces and could not roll itself back (it left
# partial-cutover.json). This path decides deliberately instead of switching on
# top of a split machine: restore the recorded pre-switch state, then either
# COMPLETE the recorded target (if it is still the requested key - the normal
# cutover runs from the restored base, with its own canary and rollback) or stay
# REVERTED. The marker is cleared only once the machine is in a decided state.
if ($ResumePartial) {
    Write-Output ''
    Write-Output '--- resume partial cutover ---'
    $marker = $null
    if (Test-Path -LiteralPath $MarkerPath) {
        try { $marker = Get-Content -LiteralPath $MarkerPath -Raw | ConvertFrom-Json } catch { $marker = $null }
    }
    if (-not $marker) {
        Write-Output "no partial-cutover marker at $MarkerPath; nothing to resume"
        exit 4
    }
    if ($DryRun) {
        Write-Output ("dry-run: would restore the pre-switch state and then {0} {1}" -f $(if ([string]$marker.to -eq $targetLabel) { 'complete' } else { 'revert (recorded target ' + $marker.to + ' is not ' + $targetLabel + ')' }), $MarkerPath)
        exit 0
    }
    $fromLabel = [string]$marker.from
    $toLabel = [string]$marker.to
    Write-Output ("recorded partial cutover: from {0} to {1} (runId {2}, at {3})" -f $fromLabel, $toLabel, $marker.runId, $marker.at)

    $restoreErrors = @(Restore-CutoverSnapshot -Snapshot (Read-CutoverSnapshot))
    if ($restoreErrors.Count -gt 0) {
        [Console]::Error.WriteLine("partial-cutover: could not restore the recorded from state (" + ($restoreErrors -join '; ') + "); marker left in place")
        exit 6
    }
    Write-Output ("restored the recorded pre-switch surfaces ({0})" -f $fromLabel)

    if ($toLabel -ne $targetLabel) {
        Clear-PartialMarker
        Remove-CutoverSnapshot
        Write-CredLogHere -Action 'cutover-reverted' -Target 'key-check partial cutover' -Detail ("reverted partial cutover {0} -> {1}: recorded target is not the requested {2}" -f $fromLabel, $toLabel, $targetLabel)
        Write-Output ("partial cutover reverted to {0}: recorded target {1} is not the requested {2}" -f $fromLabel, $toLabel, $targetLabel)
        exit 1
    }

    Write-Output "recorded target $toLabel is still the requested key; completing the cutover"
    $childArgs = @('-NoProfile', '-File', $PSCommandPath, '-KeyNumber', "$KeyNumber", '-Actor', $Actor, '-Reason', $Reason, '-LogPath', $LogPath, '-DispatchMode', $DispatchMode, '-RunId', $RunId)
    foreach ($pair in @(
            @('-SeamPath', $SeamPath), @('-AuthJson', $AuthJson), @('-RuntimeConfig', $RuntimeConfig),
            @('-StateDir', $StateDir), @('-ConfigPath', $ConfigPath), @('-OpencodeCli', $OpencodeCli),
            @('-CanaryScript', $CanaryScript), @('-FixtureState', $FixtureState))) {
        if ($pair[1]) { $childArgs += $pair[0]; $childArgs += $pair[1] }
    }
    if ($RetirePoolKey -gt 0) { $childArgs += @('-RetirePoolKey', "$RetirePoolKey") }
    if ($SkipRuntimeConfig) { $childArgs += '-SkipRuntimeConfig' }
    if ($SkipCanary) { $childArgs += '-SkipCanary' }
    if ($SkipSessionCleanup -or $SkipHygiene) { $childArgs += '-SkipSessionCleanup' }
    if ($Full) { $childArgs += '-Full' } elseif ($Fast) { $childArgs += '-Fast' }

    & pwsh @childArgs
    $completionCode = $LASTEXITCODE
    if ($completionCode -eq 0 -or $completionCode -eq 1) {
        Clear-PartialMarker
        Remove-CutoverSnapshot
    }
    exit $completionCode
}

# --- report current state (names + which pool key matches, never values) ---
$currentGo = Get-StateValue -Name 'OPENCODE_GO_KEY' -Scope 'User'
$currentApi = Get-StateValue -Name 'OPENCODE_API_KEY' -Scope 'User'
$preLabel = Get-PoolLabel -Value $currentGo
foreach ($pair in @(@('OPENCODE_GO_KEY', $currentGo), @('OPENCODE_API_KEY', $currentApi))) {
    $match = Get-PoolLabel -Value $pair[1]
    Write-Output ("{0} (User) currently -> {1}" -f $pair[0], $match)
}
if (Test-Path -LiteralPath $AuthJson) {
    $auth = Get-Content -LiteralPath $AuthJson -Raw | ConvertFrom-Json
    $ocg = $auth.'opencode-go'.key
    $m = Get-PoolLabel -Value $ocg
    Write-Output ("auth.json opencode-go currently -> {0}" -f $m)
} else { Write-Output "auth.json absent at $AuthJson" }

if ($DryRun) {
    Write-Output ("dry-run: would repoint OPENCODE_GO_KEY, OPENCODE_API_KEY, auth.json opencode-go -> {0}" -f $targetName)
    if (-not $SkipRuntimeConfig -and $seam) {
        Write-Output ("dry-run: would set ~/.machine/config.json execution.defaultCodingKey -> {0}" -f $targetName)
        Write-Output "dry-run: would project keyMaxConcurrent + providerMaxConcurrent from the seam"
    }
    Write-Output "dry-run: Paseo untouched here — run Repair-Paseo.ps1 -KeyNumber $KeyNumber as step 2"
    if (-not $SkipSessionCleanup) {
        Write-Output "dry-run: would run session hygiene ($($seam.hygiene.mode)) - strip account-bound reasoning when poisoned parts exist"
    }
    if (-not $SkipCanary) {
        Write-Output "dry-run: would then canary ($canaryMode set):"
        foreach ($c in $canarySet) { Write-Output ("  {0} --variant {1}" -f $c[0], $c[1]) }
    }
    exit 0
}

# --- capture the pre-switch state of every surface this run writes ----------
# The canary runs after the write; if it fails, this snapshot is what puts the
# machine back exactly as it was, so no run can end with surfaces disagreeing.
$snapshot = New-CutoverSnapshot -TargetLabel $targetLabel -FromLabel $preLabel
Write-Output ("pre-switch state captured (from {0} to {1}; snapshot {2})" -f $preLabel, $targetLabel, $SnapshotDir)

# --- repoint User env vars ---
Set-StateValue -Name 'OPENCODE_GO_KEY' -Value $targetVal -Scope 'User'
Set-StateValue -Name 'OPENCODE_API_KEY' -Value $targetVal -Scope 'User'
if (-not $FixtureStore) {
    $env:OPENCODE_GO_KEY = $targetVal
    $env:OPENCODE_API_KEY = $targetVal
}
Write-Output "User env OPENCODE_GO_KEY + OPENCODE_API_KEY repointed to $targetName"

# --- repoint auth.json ---
if ((Test-Path -LiteralPath $AuthJson)) {
    $stamp = [datetimeoffset]::UtcNow.ToString('yyyyMMddTHHmmssZ')
    Copy-Item -LiteralPath $AuthJson -Destination "$AuthJson.bak-$stamp" -Force
    $auth = Get-Content -LiteralPath $AuthJson -Raw | ConvertFrom-Json
    $touched = @()
    foreach ($p in @('opencode-go', 'opencode')) {
        if ($null -ne $auth.PSObject.Properties[$p] -and $null -ne $auth.$p.PSObject.Properties['key']) {
            $auth.$p.key = $targetVal
            $touched += $p
        }
    }
    $auth | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $AuthJson -Encoding utf8 -NoNewline
    Write-Output ("auth.json updated providers: " + ($touched -join ', ') + " (backup $AuthJson.bak-$stamp)")
}

# --- project the seam into ~/.machine/config.json ---
# THIS is what makes "only the active key is used" true for spawned lanes.
# execution.defaultCodingKey is not advisory: Get-OpencodeDefaultCodingKey feeds
# it into Get-OpencodeKeyPriority -DefaultKey, which moves the named key to the
# FRONT of the pool order. Left pointing at an exhausted key, every lane tries
# that key first and dies before reaching the fresh one — the exact failure this
# script exists to prevent. The caps are projected from the same seam so the
# provider cap and the active key's per-key cap stay consistent.
if (-not $SkipRuntimeConfig -and $seam) {
    if ([string]::IsNullOrWhiteSpace($RuntimeConfig)) {
        $RuntimeConfig = Join-Path $env:USERPROFILE '.machine\config.json'
    }
    if (Test-Path -LiteralPath $RuntimeConfig) {
        $rcStamp = [datetimeoffset]::UtcNow.ToString('yyyyMMddTHHmmssZ')
        Copy-Item -LiteralPath $RuntimeConfig -Destination "$RuntimeConfig.bak-$rcStamp" -Force
        $rc = Get-Content -LiteralPath $RuntimeConfig -Raw | ConvertFrom-Json
        if ($null -eq $rc.execution) { $rc | Add-Member -NotePropertyName execution -NotePropertyValue ([pscustomobject]@{}) -Force }
        $rc.execution | Add-Member -NotePropertyName defaultCodingKey -NotePropertyValue ([string]$targetName) -Force
        if ($seam.keyMaxConcurrent) {
            $kmc = [pscustomobject]@{}
            foreach ($p in $seam.keyMaxConcurrent.PSObject.Properties) { $kmc | Add-Member -NotePropertyName $p.Name -NotePropertyValue ([int]$p.Value) -Force }
            $rc.execution | Add-Member -NotePropertyName keyMaxConcurrent -NotePropertyValue $kmc -Force
        }
        if ($seam.providerMaxConcurrent) {
            $pmc = [pscustomobject]@{}
            foreach ($p in $seam.providerMaxConcurrent.PSObject.Properties) { $pmc | Add-Member -NotePropertyName $p.Name -NotePropertyValue ([int]$p.Value) -Force }
            $rc.execution | Add-Member -NotePropertyName providerMaxConcurrent -NotePropertyValue $pmc -Force
        }
        # Spillover guard. The active key sits FIRST in pool order, so a lane can
        # only reach a lower-priority (exhausted) key when the provider cap
        # exceeds the active key's per-key cap. Keep them equal and only the
        # active key is ever used; if the provider cap is higher, warn loudly.
        $activeCap = 0; $pmcGo = 0
        if ($seam.keyMaxConcurrent) {
            $ap = $seam.keyMaxConcurrent.PSObject.Properties | Where-Object Name -IEQ $targetName | Select-Object -First 1
            if ($ap) { $activeCap = [int]$ap.Value }
        }
        if ($seam.providerMaxConcurrent) {
            $pp = $seam.providerMaxConcurrent.PSObject.Properties | Where-Object Name -IEQ 'opencode-go' | Select-Object -First 1
            if ($pp) { $pmcGo = [int]$pp.Value }
        }
        if ($pmcGo -gt 0 -and $activeCap -gt 0 -and $pmcGo -gt $activeCap) {
            if ($DispatchMode -in @('waterfall', 'round-robin')) {
                Write-Output ("dispatch spill expected: providerMaxConcurrent.opencode-go ({0}) exceeds {1} cap ({2}) by design under -DispatchMode {3}; lanes past {2} spill onto lower-priority keys on purpose." -f $pmcGo, $targetName, $activeCap, $DispatchMode)
            }
            else {
                Write-Warning ("spillover risk: providerMaxConcurrent.opencode-go ({0}) exceeds {1} cap ({2}); lanes beyond {2} will spill onto lower-priority keys." -f $pmcGo, $targetName, $activeCap)
            }
        }
        $rc | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $RuntimeConfig -Encoding utf8 -NoNewline
        Write-Output ("$RuntimeConfig updated: defaultCodingKey -> {0}; caps projected from seam (backup $RuntimeConfig.bak-$rcStamp)" -f $targetName)
        Write-CredLogHere -Action 'config-projection' -Target "$RuntimeConfig execution.defaultCodingKey" -Detail ("defaultCodingKey -> {0}; keyMaxConcurrent + providerMaxConcurrent projected from seam" -f $targetName)
    } else {
        Write-Warning "runtime config not found at $RuntimeConfig; defaultCodingKey not projected (lanes may still prefer a stale key)."
    }
}

# --- persist the new active key back into the seam (single source of truth) ---
# The seam is authoritative; this script is the only thing that flips it, so a
# later agent reading the seam sees the key actually in force. -KeyNumber 5
# therefore means "activeKey = OPENCODE_GO5_KEY" everywhere, not just in the env.
if ($seam -and (Test-Path -LiteralPath $SeamPath)) {
    try {
        $seam.activeKey = $targetName
        $seam.updated = (Get-Date -Format 'yyyy-MM-dd')
        $seam | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $SeamPath -Encoding utf8 -NoNewline
        Write-Output "seam updated: $SeamPath activeKey -> $targetName"
    } catch { Write-Warning "could not persist activeKey into $SeamPath : $($_.Exception.Message)" }
}

# --- session hygiene: strip account-bound Responses-API reasoning ---
# The Responses API persists reasoning items carrying
# metadata.openai.reasoningEncryptedContent, bound to the caller (account/key)
# that issued them. Continuing a pre-switch session on the new key replays them
# and the upstream rejects the request: `reasoning encrypted_content was not
# issued to this caller`. Strip that node from every session's parts (backing
# them up first) so a key change can never poison existing sessions.
#
# Policy comes from the seam (hygiene.mode): never = skip; auto/always = run the
# cheap count first and only pay the strip when poisoned parts actually exist.
$doHygiene = -not ($SkipSessionCleanup -or $SkipHygiene)
if ($seam -and $seam.hygiene -and ([string]$seam.hygiene.mode) -eq 'never') { $doHygiene = $false }
if ($doHygiene) {
    Write-Output ''
    Write-Output '--- session hygiene (strip account-bound reasoning replay) ---'
    $dbTool = $null
    if ($canaryCli -and (Test-Path -LiteralPath $canaryCli)) { $dbTool = $canaryCli }
    $poisonedSql = "SELECT count(*) FROM part WHERE json_extract(data,'`$.metadata.openai.reasoningEncryptedContent') IS NOT NULL"
    $poisoned = $null
    if ($dbTool) {
        $poisoned = (& $dbTool db $poisonedSql 2>&1 | Select-Object -Last 1).Trim()
    } elseif (Get-Command sqlite3 -ErrorAction SilentlyContinue) {
        $poisoned = (& sqlite3 $opencodeDb $poisonedSql 2>&1 | Select-Object -Last 1).Trim()
    }
    if (-not $poisoned -or $poisoned -notmatch '^\d+$') {
        Write-Warning "could not count poisoned parts (opencode CLI/db or sqlite3 unavailable); skipping session hygiene. DB: $opencodeDb"
    } elseif ([int]$poisoned -eq 0) {
        Write-Output "no account-bound reasoning parts found; nothing to strip."
    } else {
        $stamp2 = [datetimeoffset]::UtcNow.ToString('yyyyMMddTHHmmssZ')
        $backupPath = Join-Path $env:TEMP "opencode-encrypted-reasoning-$stamp2.json"
        $backupSql = "SELECT session_id, id, data FROM part WHERE json_extract(data,'`$.metadata.openai.reasoningEncryptedContent') IS NOT NULL"
        try {
            if ($dbTool) { & $dbTool db $backupSql --format json 2>&1 | Out-File -LiteralPath $backupPath -Encoding utf8 }
            else { & sqlite3 -json $opencodeDb $backupSql 2>&1 | Out-File -LiteralPath $backupPath -Encoding utf8 }
            $updateSql = "UPDATE part SET data=json_remove(data,'`$.metadata.openai') WHERE json_extract(data,'`$.metadata.openai.reasoningEncryptedContent') IS NOT NULL"
            if ($dbTool) { & $dbTool db $updateSql 2>&1 | Out-Null }
            else { & sqlite3 $opencodeDb $updateSql 2>&1 | Out-Null }
            $remaining = if ($dbTool) { (& $dbTool db $poisonedSql 2>&1 | Select-Object -Last 1).Trim() } else { (& sqlite3 $opencodeDb $poisonedSql 2>&1 | Select-Object -Last 1).Trim() }
            Write-Output ("stripped metadata.openai from {0} reasoning part(s); {1} remaining (backup: {2})" -f $poisoned, $remaining, $backupPath)
            Write-CredLogHere -Action 'session-hygiene' -Target 'part.metadata.openai (opencode store)' -Detail ("cutover to $targetName; stripped account-bound reasoning from {0} part(s); backup {1}" -f $poisoned, $backupPath)
        } catch {
            Write-Warning "session hygiene failed: $($_.Exception.Message)"
        }
    }
}

Write-CredLogHere -Action 'credential-update' -Target 'OPENCODE_GO_KEY + OPENCODE_API_KEY (User env), auth.json opencode-go' -Detail "repointed to $targetName ($targetScope-scope value)"

# --- post-cutover canary set ---
# Repointing the key can surface a latent MODEL-transport defect (the
# Responses-API encrypted-reasoning replay error) that is invisible until the
# new caller replays account-bound reasoning. Canary the configured model (at
# its real variant) plus the two fleet-standard opencode-go models, so a
# cutover that breaks dispatch on the default worker model is caught here, not
# by the next lane that dies on its first turn.
#
# The canary is told which key to exercise and which label that key is; it never
# inherits this process's OPENCODE_GO_KEY (the caller's stale value) and it runs
# the CLI `--standalone` so the shared background server - which keeps the
# pre-cutover key forever - cannot answer for it.
$canaryFailed = @()
if (-not $SkipCanary) {
    Write-Output ''
    Write-Output '--- post-cutover canary (model-transport + credential check) ---'
    Write-Output ("  key under test: {0} ({1}-scope value)" -f $targetLabel, $targetScope)
    if ($CanaryScript) {
        Write-Output ("  canary sender : stub {0}" -f $CanaryScript)
    }
    elseif (-not $canaryCli -or -not (Test-Path -LiteralPath $canaryCli)) {
        Write-Warning "opencode CLI not found (set OPENCODE_CLI_PATH or -OpencodeCli); skipping canary."
        $canaryFailed += '<cli-missing>'
    }
    if ($canaryFailed.Count -eq 0) {
        foreach ($c in $canarySet) {
            $model = $c[0]; $variant = $c[1]
            $rc = Invoke-GoCanary -Model $model -Variant $variant -KeyValue $targetVal -KeyLabel $targetLabel
            if ($rc -eq 0) { Write-Output ("  PASS  {0} --variant {1} (key {2})" -f $model, $variant, $targetLabel) }
            else { Write-Output ("  FAIL  {0} --variant {1} (key {2})" -f $model, $variant, $targetLabel); $canaryFailed += "$model/$variant" }
        }
    }
}

# --- a failed canary must never leave a split machine -----------------------
# The canary measured the key this run wrote, so a failure is a real failure of
# that key. Restore every surface captured before the write: the seam activeKey,
# the User values, auth.json and ~/.machine/config.json. Only a rollback that
# itself fails may leave the machine split, and then it says so on disk.
if ($canaryFailed.Count -gt 0) {
    Write-CredLogHere -Action 'canary-failed' -Target 'opencode-go canary set' -Detail ("cutover to $targetName; failed: " + ($canaryFailed -join ', '))
    Write-Output ''
    Write-Output '--- rollback (canary failed after the write) ---'
    $rollbackErrors = @(Restore-CutoverSnapshot -Snapshot $snapshot)
    if ($rollbackErrors.Count -eq 0) {
        Remove-CutoverSnapshot
        Clear-PartialMarker
        Write-CredLogHere -Action 'cutover-rolled-back' -Target 'cutover surfaces (seam, User env, auth.json, salmon config)' -Detail ("canary failed on {0}; every surface restored to {1}" -f ($canaryFailed -join ', '), $preLabel)
        [Console]::Error.WriteLine(("Cutover rolled-back: the canary set reported failures on {0}; every surface is back on {1}" -f ($canaryFailed -join ', '), $preLabel))
        exit 1
    }
    Write-PartialMarker -FromLabel $preLabel -ToLabel $targetLabel -Surfaces @('seam', 'user-env', 'auth.json', 'salmon-config') -RollbackErrors $rollbackErrors
    [Console]::Error.WriteLine(("partial-cutover: the rollback could not restore {0}; marker written to {1} - the next invocation completes or reverts it deliberately" -f ($rollbackErrors -join '; '), $MarkerPath))
    exit 6
}

Write-CredLogHere -Action 'canary-passed' -Target 'opencode-go canary set' -Detail "cutover to $targetName; all canaries passed"

# --- optional pool-key retirement (only once the cutover proved out) --------
if ($RetirePoolKey -gt 0) {
    $dead = "OPENCODE_GO${RetirePoolKey}_KEY"
    if ($dead -ieq $targetName) { throw "Refusing to retire $dead - it is the activation target." }
    $cleared = @()
    foreach ($scope in @('Machine', 'User')) {
        $existing = Get-StateValue -Name $dead -Scope $scope
        if ([string]::IsNullOrWhiteSpace($existing)) { continue }
        Set-StateValue -Name $dead -Value '' -Scope $scope
        $cleared += $scope
    }
    if ($cleared.Count -eq 0) {
        Write-Output "$dead already unset at Machine and User scope."
    } else {
        $where = ($cleared -join ' + ')
        Write-Output "$dead cleared at $where scope (exhausted; pool now skips it)."
        Write-CredLogHere -Action 'remove' -Target "$dead ($where env var)" -Detail 'cleared exhausted pool key so the salmon-run executor stops selecting it; value retained in AWS SM ClockLobster/Salmon-Run if OPENCODE_GO<n>_ON is still true'
    }
}

# The cutover is decided (applied and proven): drop the rollback snapshot and
# any stale partial marker so the next run starts from a clean state.
Clear-PartialMarker
Remove-CutoverSnapshot

Write-Output ''
Write-Output 'Salmon cutover complete. Next steps:'
Write-Output '  1. Paseo is a separate track — make helpers use the new key:'
Write-Output '       pwsh -File scripts/Repair-Paseo.ps1 -KeyNumber <n>   (or without -KeyNumber for the current User key)'
Write-Output '       pwsh -File scripts/Repair-Paseo.ps1 -VerifyOnly      (classify only)'
Write-Output '  2. If a canary FAILED with an encrypted_content / "not issued to this caller" error,'
Write-Output '     that is a model-transport defect (not credential) - see'
Write-Output '     skills/providers/opencode/model-replacement and the encrypted_content note'
Write-Output '     in credential-rescue REFERENCE § Error taxonomy.'
Write-Output '  3. If failures persist, classify via skills/providers/opencode/model-replacement.'
Write-Output ''
Write-Output ("Note: this run used the '{0}' canary set and '{1}' hygiene (seam: {2})." -f $canaryMode, ($seam.hygiene.mode ?? 'auto'), $SeamPath)

if ($RestartPaseo) {
    Write-Output ''
    Write-Output '--- -RestartPaseo: delegating to Repair-Paseo.ps1 (composition) ---'
    & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'Repair-Paseo.ps1') -KeyNumber $KeyNumber -Actor $Actor -LogPath $LogPath
    exit $LASTEXITCODE
}

exit 0

