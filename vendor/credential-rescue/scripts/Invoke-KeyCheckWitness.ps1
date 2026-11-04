#Requires -Version 7.0
<#
.SYNOPSIS
    The shipped witness: after a key cutover, say what is actually true about
    this machine - and prove it, rather than infer it from one surface.

.DESCRIPTION
    A cutover has an outcome file, three credential surfaces and a daemon. This
    script reports all of them and derives ONE verdict:

        verified-by-helper   the helper's outcome says `verified: true`
        verified-by-witness  seam label == User label == Paseo pin label, and
                             the daemon is alive
        applied-but-unproven the outcome applied, but the surfaces disagree
        cutover-failed       the outcome applied = false
        no-evidence          no outcome, and the surfaces disagree

    Exit 0 only for the two verified verdicts.

    Every label comes from `Get-PoolMatchLabel`, and the seam's `activeKey`
    (a NAME such as `OPENCODE_GO3_KEY`) is resolved to its VALUE first and then
    labelled. It is never labelled by stripping `_KEY`: that produced
    `OPENCODE_GO3` compared against `GO3`, and a verified machine was reported
    as `no-evidence`. That regression is pinned by a test.

    It writes `<StateDir>\witness-<runId>.json`, one `cutover-witness` audit
    line, and refreshes `<StateDir>\last-cutover.json` so any process can learn
    a cutover happened without knowing the runId.

    SECURITY: only GO<n> labels and fingerprints leave this process - never a
    key value.

.PARAMETER RunId
    The Key Check run being witnessed. Required.

.PARAMETER OutcomePath
    The helper's outcome file. Default `<StateDir>\<runId>-cutover.json`.

.PARAMETER DelaySeconds
    Wait before reading the surfaces. Default 0. Used when the witness is
    started while the helper is still finishing its restart.

.PARAMETER StateDir
    Default `~/.machine/state/key-check`.

.PARAMETER AuditPath
    Default `~/.machine/logs/keycheck.jsonl`.

.PARAMETER SeamPath
    Default `../assets/opencode-go-cutover.json`. Test seam.

.PARAMETER PaseoConfig
    The config whose provider pin is labelled. Default `~/.paseo/config.json`.

.PARAMETER KeyValuesFile
    Test seam: `{ "inUse": "<value>", "keys": { "GO1": "<value>" } }` instead of
    the Machine/User `OPENCODE_GO<n>_KEY` environment.

.PARAMETER DaemonPidFile
    Default `~/.paseo/paseo.pid`.

.PARAMETER Json
    Emit the witness report on stdout.

.OUTPUTS
    Exit 0 verified (by helper or by witness) - 1 any other verdict.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$RunId,
    [string]$OutcomePath = '',
    [ValidateRange(0, 3600)]
    [int]$DelaySeconds = 0,
    [switch]$Json,
    [string]$StateDir = '',
    [string]$AuditPath = '',
    [string]$SeamPath = '',
    [string]$PaseoConfig = '',
    [string]$KeyValuesFile = '',
    [string]$DaemonPidFile = ''
)

$ErrorActionPreference = 'Stop'

$scriptRoot = $PSScriptRoot
. (Join-Path $scriptRoot 'lib\PaseoCommon.ps1')
. (Join-Path $scriptRoot '..\..\aws\scripts\SecretFingerprint.ps1')

if ([string]::IsNullOrWhiteSpace($StateDir)) { $StateDir = Join-Path $env:USERPROFILE '.machine\state\key-check' }
if ([string]::IsNullOrWhiteSpace($AuditPath)) { $AuditPath = Join-Path $env:USERPROFILE '.machine\logs\keycheck.jsonl' }
if ([string]::IsNullOrWhiteSpace($OutcomePath)) { $OutcomePath = Join-Path $StateDir "$RunId-cutover.json" }
if ([string]::IsNullOrWhiteSpace($SeamPath)) { $SeamPath = Join-Path $scriptRoot '..\assets\opencode-go-cutover.json' }
if ([string]::IsNullOrWhiteSpace($PaseoConfig)) { $PaseoConfig = Join-Path $env:USERPROFILE '.paseo\config.json' }
if ([string]::IsNullOrWhiteSpace($DaemonPidFile)) { $DaemonPidFile = Join-Path $env:USERPROFILE '.paseo\paseo.pid' }

if ($DelaySeconds -gt 0) { Start-Sleep -Seconds $DelaySeconds }

# --- fixture key values (test seam) -----------------------------------------
$keyMap = $null
$fixtureInUse = ''
if ($KeyValuesFile -and (Test-Path -LiteralPath $KeyValuesFile)) {
    $kv = Get-Content -LiteralPath $KeyValuesFile -Raw | ConvertFrom-Json
    $keyMap = @{}
    foreach ($p in $kv.keys.PSObject.Properties) { $keyMap[$p.Name] = [string]$p.Value }
    if ($kv.PSObject.Properties['inUse']) { $fixtureInUse = [string]$kv.inUse }
}

function Get-WitnessLabel {
    <#
    .SYNOPSIS
        GO<n> / no-value / no-pool-match for a key VALUE. Never returns the value.
    #>
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return 'no-value' }
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

function Get-WitnessValueByName {
    <#
    .SYNOPSIS
        Resolve a seam entry to a key VALUE, so it can be labelled by comparison
        like every other surface: a pool NAME (`OPENCODE_GO3_KEY`) resolves to
        the value the pool holds for it; a raw value resolves to itself.
    #>
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return '' }
    if ($keyMap) {
        if ($keyMap.ContainsKey($Name)) { return [string]$keyMap[$Name] }
        # A pool env name is resolved to the pool slot it names - name to value,
        # never a label derived by editing the name.
        if ($Name -match '^OPENCODE_GO(\d+)_KEY$') {
            $slot = "GO$($Matches[1])"
            if ($keyMap.ContainsKey($slot)) { return [string]$keyMap[$slot] }
        }
        foreach ($candidate in $keyMap.Values) { if ([string]$candidate -eq $Name) { return $Name } }
        return $Name
    }
    $resolved = Get-PoolKeyValue -Name $Name
    if (-not [string]::IsNullOrWhiteSpace($resolved)) { return $resolved }
    return $Name
}

function Read-WitnessSeamName {
    if (-not (Test-Path -LiteralPath $SeamPath)) { return '<seam-missing>' }
    try {
        $seam = Get-Content -LiteralPath $SeamPath -Raw | ConvertFrom-Json
        return [string]$seam.activeKey
    } catch {
        return '<seam-unreadable>'
    }
}

function Get-WitnessUserValue {
    if ($fixtureInUse) { return $fixtureInUse }
    foreach ($scope in @('User', 'Process')) {
        $v = [Environment]::GetEnvironmentVariable('OPENCODE_GO_KEY', $scope)
        if (-not [string]::IsNullOrWhiteSpace($v)) { return $v }
    }
    return ''
}

function Get-WitnessPinValue {
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

function Test-WitnessDaemonAlive {
    if (-not (Test-Path -LiteralPath $DaemonPidFile)) { return $false }
    try {
        $j = Get-Content -LiteralPath $DaemonPidFile -Raw | ConvertFrom-Json
        return [bool](Get-Process -Id ([int]$j.pid) -ErrorAction SilentlyContinue)
    } catch { return $false }
}

function Write-WitnessAudit {
    param($Entry)
    $dir = Split-Path -Parent $AuditPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
    Add-Content -LiteralPath $AuditPath -Value ($Entry | ConvertTo-Json -Compress) -Encoding utf8NoBOM
}

# --- the evidence ------------------------------------------------------------
$outcome = $null
if (Test-Path -LiteralPath $OutcomePath) {
    try { $outcome = Get-Content -LiteralPath $OutcomePath -Raw | ConvertFrom-Json } catch { $outcome = $null }
}
$outcomeVerified = $false
$outcomeApplied = $false
$outcomeReason = ''
$restartPending = $false
if ($null -ne $outcome) {
    if ($outcome.PSObject.Properties['verified']) { $outcomeVerified = ($outcome.verified -is [bool] -and $outcome.verified) }
    if ($outcome.PSObject.Properties['applied']) { $outcomeApplied = [bool]$outcome.applied }
    if ($outcome.PSObject.Properties['reason']) { $outcomeReason = [string]$outcome.reason }
    if ($outcome.PSObject.Properties['restartPending']) { $restartPending = [bool]$outcome.restartPending }
}

$seamName = Read-WitnessSeamName
$seamLabel = if ($seamName -like '<*>') { $seamName } else { Get-WitnessLabel -Value (Get-WitnessValueByName -Name $seamName) }
$userLabel = Get-WitnessLabel -Value (Get-WitnessUserValue)
$pinLabel = Get-WitnessLabel -Value (Get-WitnessPinValue)
$daemonAlive = Test-WitnessDaemonAlive

$poolLabels = @($seamLabel, $userLabel, $pinLabel)
$allAgree = (($poolLabels | Select-Object -Unique).Count -eq 1) -and ($poolLabels[0] -match '^GO\d+$')

$verdict = ''
if ($outcomeVerified) {
    $verdict = 'verified-by-helper'
} elseif ($null -ne $outcome -and -not $outcomeApplied) {
    # The helper recorded a failure. That is a fact about what the cutover did,
    # and it outranks three labels that happen to agree now.
    $verdict = 'cutover-failed'
} elseif ($allAgree -and $daemonAlive) {
    $verdict = 'verified-by-witness'
} elseif ($outcomeApplied -or $allAgree) {
    # Something moved (an applied outcome, or three agreeing surfaces) but the
    # proof is incomplete - usually a daemon that is not alive yet.
    $verdict = 'applied-but-unproven'
} else {
    $verdict = 'no-evidence'
}

$verifiedVerdict = ($verdict -in @('verified-by-helper', 'verified-by-witness'))
$exitCode = if ($verifiedVerdict) { 0 } else { 1 }

$payload = [ordered]@{
    version      = 1
    runId        = $RunId
    at           = (Get-Date).ToString('o')
    verdict      = $verdict
    outcome      = [ordered]@{
        present        = ($null -ne $outcome)
        path           = $OutcomePath
        applied        = $outcomeApplied
        verified       = $outcomeVerified
        restartPending = $restartPending
        reason         = $outcomeReason
    }
    surfaces     = [ordered]@{
        seam = [ordered]@{ name = $seamName; label = $seamLabel }
        user = [ordered]@{ label = $userLabel }
        pin  = [ordered]@{ label = $pinLabel }
    }
    daemonAlive  = $daemonAlive
    allAgree     = $allAgree
    exitCode     = $exitCode
}

$dir = Split-Path -Parent $OutcomePath
$witnessPath = Join-Path $StateDir "witness-$RunId.json"
$witnessDir = Split-Path -Parent $witnessPath
if ($witnessDir -and -not (Test-Path -LiteralPath $witnessDir)) { $null = New-Item -ItemType Directory -Path $witnessDir -Force }
Set-Content -LiteralPath $witnessPath -Value ($payload | ConvertTo-Json -Depth 8) -Encoding utf8NoBOM

Write-WitnessAudit -Entry ([ordered]@{
        ts          = (Get-Date).ToString('s'); kind = 'cutover-witness'; runId = $RunId
        verdict     = $verdict; seam = $seamLabel; user = $userLabel; pin = $pinLabel
        daemonAlive = $daemonAlive; outcomePresent = ($null -ne $outcome)
        applied     = $outcomeApplied; verified = $outcomeVerified
        witnessPath = $witnessPath; at = (Get-Date).ToString('o')
    })

# --- refresh the durable discovery marker -----------------------------------
$markerPath = Join-Path $StateDir 'last-cutover.json'
$marker = [ordered]@{
    runId       = $RunId
    at          = (Get-Date).ToString('o')
    from        = ''
    to          = ''
    rosterPath  = ''
    witnessPath = $witnessPath
    verdict     = $verdict
    updatedAt   = (Get-Date).ToString('o')
}
if (Test-Path -LiteralPath $markerPath) {
    try {
        $existing = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
        if ([string]$existing.runId -eq $RunId) {
            foreach ($field in @('at', 'from', 'to', 'rosterPath')) {
                if ($existing.PSObject.Properties[$field] -and $existing.$field) { $marker[$field] = [string]$existing.$field }
            }
        }
    } catch { }
}
Set-Content -LiteralPath $markerPath -Value ($marker | ConvertTo-Json -Depth 6) -Encoding utf8NoBOM

if ($Json) {
    $payload | ConvertTo-Json -Depth 8
} else {
    Write-Output ("witness {0}: {1} (seam={2} user={3} pin={4} daemon={5})" -f `
            $RunId, $verdict, $seamLabel, $userLabel, $pinLabel, $(if ($daemonAlive) { 'alive' } else { 'down' }))
}
exit $exitCode
