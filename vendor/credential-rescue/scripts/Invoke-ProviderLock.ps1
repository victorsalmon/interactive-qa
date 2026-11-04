#Requires -Version 7
<#
.SYNOPSIS
    Provider lock - record where each provider credential lives and prove every
    consumer (env, Paseo, key file) matches the authoritative value, without
    ever printing a value.

.DESCRIPTION
    "Is Paseo using the right key?" was answered in 2026-10 by manually printing
    a secret once (disclosed). This script makes the safe answer the default: the
    lock asset stores each provider's source (AWS SM secret + field, or a key
    file) plus a SHA-256 fingerprint of the authoritative value. Status compares
    the source and every consumer to that fingerprint and reports MATCH / DRIFT /
    MISSING / NOT-CONFIGURED with lengths and short hash prefixes only.

    Modes:
      Status (default)  read-only verification; exit 1 on any drift
      Lock              (re)capture the authoritative fingerprint into the asset

    Where the lock lives (this copy only):
      The lock is MACHINE STATE. -Mode Lock fingerprints the credentials of the
      machine it runs on, so a copy shipped inside a package went stale against
      the machine that wrote it, and running the tool dirtied the package. It
      therefore resolves OUTSIDE the package:

        state root   $env:USERPROFILE\.salmon\State\credential-rescue\provider-lock.json
                     (or -StateRoot, or $env:IQA_PROVIDER_LOCK_STATE_ROOT)
        legacy       <package vendor>/assets/provider-lock.json - READ ONLY, used
                     only while the state file does not exist yet

      -Mode Lock always writes the state root (creating it), never the legacy
      path, and seeds the state file from the legacy copy on its first run. A
      machine with neither file is cannot-evaluate: the provider definitions
      (source secret/field, consumer targets) cannot be invented - seed the
      state root once from the deployment's lock asset.

    Consumer target kinds in the lock asset:
      { kind: env,   scope: Machine|User|Process, name: VAR, required: bool }
      { kind: paseo, provider: opencode, envName: OPENCODE_GO_KEY, required: bool }
      { kind: file,  path: C:\...\key }

    Optional targets (required:false) that are absent report OPTIONAL-MISSING or
    NOT-CONFIGURED and do not fail the run; required ones do.

.EXAMPLE
    pwsh -NoProfile -File $env:CL_REPOS_ROOT\cl-common\Skills\credential-rescue\scripts\Invoke-ProviderLock.ps1

.EXAMPLE
    pwsh -NoProfile -File $env:CL_REPOS_ROOT\cl-common\Skills\credential-rescue\scripts\Invoke-ProviderLock.ps1 -Mode Lock -Provider openrouter

.EXAMPLE
    pwsh -NoProfile -File ...\Invoke-ProviderLock.ps1 -Mode Status -NoAws   # compare consumers to the stored fingerprint only
#>
[CmdletBinding()]
param(
    [ValidateSet('Status', 'Lock')][string]$Mode = 'Status',
    [string[]]$Provider = @(),
    # Empty means "resolve the machine's lock": the profile state root, with a
    # read-only legacy fallback to the in-tree asset. Explicit wins (fixtures).
    [string]$LockPath = '',
    [string]$StateRoot = '',
    [ValidateRange(6, 64)][int]$FingerprintChars = 12,
    [switch]$NoAws,
    [string]$Actor = '',
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\..\aws\scripts\SecretFingerprint.ps1')

if (-not $Actor) {
    $Actor = if ($env:PASEO_AGENT_ID) { $env:PASEO_AGENT_ID } else { "$env:USERNAME@$env:COMPUTERNAME" }
}

# --- where the lock lives ------------------------------------------------------
# Runtime state must not live inside the package: a lock written here would drift
# from every other checkout by construction, and writing it dirties the tree the
# package is published from. Resolution order: explicit path, state root, legacy
# in-tree copy (read only).
$legacyPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'assets/provider-lock.json'

function Resolve-ProviderLockPath {
    param([string]$Explicit, [string]$Root, [string]$CurrentMode)

    if ($Explicit) { return [pscustomobject]@{ Path = $Explicit; Origin = 'explicit' } }

    $rootDir = if ($Root) { $Root }
        elseif ($env:IQA_PROVIDER_LOCK_STATE_ROOT) { $env:IQA_PROVIDER_LOCK_STATE_ROOT }
        else { Join-Path (Join-Path $HOME '.salmon') 'State/credential-rescue' }
    $statePath = Join-Path $rootDir 'provider-lock.json'

    if ($CurrentMode -eq 'Lock') {
        # A write always lands in the state root - never in the package.
        return [pscustomobject]@{ Path = $statePath; Origin = 'state-root' }
    }
    if (Test-Path -LiteralPath $statePath -PathType Leaf) {
        return [pscustomobject]@{ Path = $statePath; Origin = 'state-root' }
    }
    if (Test-Path -LiteralPath $legacyPath -PathType Leaf) {
        return [pscustomobject]@{ Path = $legacyPath; Origin = 'legacy in-tree (read-only)' }
    }
    return [pscustomobject]@{ Path = $statePath; Origin = 'state-root (absent)' }
}

$lockResolution = Resolve-ProviderLockPath -Explicit $LockPath -Root $StateRoot -CurrentMode $Mode
$LockPath = $lockResolution.Path
Write-Output ("Provider lock file: {0} ({1})" -f $LockPath, $lockResolution.Origin)

$lock = Read-JsonFileQuiet -Path $LockPath
if (-not $lock -and $Mode -eq 'Lock') {
    # First run on a machine: the definitions (source + targets) come from the
    # legacy in-tree copy if there is one; -Mode Lock then fingerprints into the
    # state root. The definitions are deployment configuration, not derivable.
    if (Test-Path -LiteralPath $legacyPath -PathType Leaf) {
        $lock = Read-JsonFileQuiet -Path $legacyPath
        if ($lock) { Write-Output "seeding the state-root definitions from the legacy in-tree copy: $legacyPath" }
    }
}
if (-not $lock -or -not $lock.providers) {
    Write-Output "ERROR provider-lock asset missing or unreadable: $LockPath"
    if ($Mode -eq 'Lock') {
        Write-Output "Nothing to seed from at $legacyPath either. The provider definitions cannot be invented:"
        Write-Output "copy the deployment's lock asset to $LockPath once, then re-run -Mode Lock."
    }
    exit 1
}
if ($Provider.Count -gt 0) {
    $unknown = @($Provider | Where-Object { -not $lock.providers.PSObject.Properties[$_] })
    if ($unknown.Count -gt 0) {
        Write-Output ("ERROR unknown provider(s): {0}; known: {1}" -f ($unknown -join ', '), (($lock.providers.PSObject.Properties.Name) -join ', '))
        exit 1
    }
}

$secretCache = @{}
$rows = [System.Collections.Generic.List[object]]::new()
$failures = 0

function Resolve-SourceValue {
    <#
    .SYNOPSIS
        Resolve a provider's authoritative value into memory. Returns
        { State = SOURCE|SOURCE-MISSING|SOURCE-SKIPPED, Value, Detail }.
        `aws-sm-seam` reads the field named by a seam file (the active pool key).
    #>
    param($Source, [string]$ActiveKey = '')

    if ($null -eq $Source) { return [pscustomobject]@{ State = 'SOURCE-MISSING'; Value = ''; Detail = 'no source in lock asset' } }
    $effectiveField = if ($ActiveKey) { $ActiveKey } else { [string]$Source.field }
    switch ([string]$Source.kind) {
        'aws-sm' {
            if ($NoAws) { return [pscustomobject]@{ State = 'SOURCE-SKIPPED'; Value = ''; Detail = 'aws read skipped (-NoAws)' } }
            $cacheKey = "{0}|{1}|{2}" -f $Source.secretId, $Source.profile, $Source.region
            if (-not $secretCache.ContainsKey($cacheKey)) {
                $raw = & aws secretsmanager get-secret-value --profile $Source.profile --region $Source.region `
                    --secret-id $Source.secretId --query SecretString --output text 2>$null
                $secretCache[$cacheKey] = if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($raw)) { [string]$raw } else { $null }
            }
            $body = $secretCache[$cacheKey]
            if (-not $body) { return [pscustomobject]@{ State = 'SOURCE-MISSING'; Value = ''; Detail = "secret '$($Source.secretId)' unreadable (no value shown)" } }
            if (-not $effectiveField) { return [pscustomobject]@{ State = 'SOURCE'; Value = $body; Detail = "$($Source.secretId) (whole value)" } }
            $parsed = $null
            try { $parsed = $body | ConvertFrom-Json } catch { $parsed = $null }
            if (-not $parsed) { return [pscustomobject]@{ State = 'SOURCE-MISSING'; Value = ''; Detail = "secret '$($Source.secretId)' is not JSON" } }
            $value = Get-JsonFieldValue -Object $parsed -Field $effectiveField
            if ([string]::IsNullOrEmpty($value)) { return [pscustomobject]@{ State = 'SOURCE-MISSING'; Value = ''; Detail = "$($Source.secretId)#$effectiveField absent" } }
            return [pscustomobject]@{ State = 'SOURCE'; Value = [string]$value; Detail = "$($Source.secretId)#$effectiveField" }
        }
        'aws-sm-seam' {
            if (-not $ActiveKey) {
                return [pscustomobject]@{ State = 'SOURCE-MISSING'; Value = ''; Detail = "seam '$($Source.seamPath)' names no active key" }
            }
            return Resolve-SourceValue -Source ([pscustomobject]@{
                    kind = 'aws-sm'; secretId = $Source.secretId
                    field = $ActiveKey; profile = $Source.profile; region = $Source.region
                })
        }
        'file' {
            $value = Get-FileSecretValue -Path $Source.path
            if ([string]::IsNullOrEmpty($value)) { return [pscustomobject]@{ State = 'SOURCE-MISSING'; Value = ''; Detail = "file '$($Source.path)' absent or empty" } }
            return [pscustomobject]@{ State = 'SOURCE'; Value = $value; Detail = "file '$($Source.path)'" }
        }
        default { return [pscustomobject]@{ State = 'SOURCE-MISSING'; Value = ''; Detail = "unsupported source kind '$($Source.kind)'" } }
    }
}

function Resolve-TargetValue {
    <#
    .SYNOPSIS
        Resolve one consumer target into memory. `${activeKey}` in a name is
        replaced with the seam's active key (opencode-go pool).
        Returns { State = PRESENT|MISSING|NOT-CONFIGURED, Value, Label }.
    #>
    param($Target, [string]$ActiveKey = '')

    $expand = {
        param([string]$Text)
        if (-not $Text) { return $Text }
        $Text -replace '\$\{activeKey\}', $ActiveKey
    }

    switch ([string]$Target.kind) {
        'env' {
            $scope = if ($Target.scope) { $Target.scope } else { 'Process' }
            $varName = & $expand $Target.name
            $value = Get-EnvSecretValue -Name $varName -Scope $scope
            $label = "$($scope):$varName"
            if ([string]::IsNullOrEmpty($value)) { return [pscustomobject]@{ State = 'MISSING'; Value = ''; Label = $label } }
            return [pscustomobject]@{ State = 'PRESENT'; Value = $value; Label = $label }
        }
        'paseo' {
            $configPath = if ($Target.configPath) { $Target.configPath } else { Join-Path $HOME '.paseo\config.json' }
            $config = Read-JsonFileQuiet -Path $configPath
            $envName = & $expand $Target.envName
            $label = "paseo:$($Target.provider).$envName"
            if (-not $config) { return [pscustomobject]@{ State = 'MISSING'; Value = ''; Label = $label } }
            $providersNode = if ($config.agents) { $config.agents.providers } else { $null }
            if (-not $providersNode -or -not $providersNode.PSObject.Properties[$Target.provider]) {
                return [pscustomobject]@{ State = 'NOT-CONFIGURED'; Value = ''; Label = $label }
            }
            $value = Get-PaseoProviderEnvValue -Provider $Target.provider -EnvName $envName -ConfigPath $configPath
            if ([string]::IsNullOrEmpty($value)) { return [pscustomobject]@{ State = 'MISSING'; Value = ''; Label = $label } }
            return [pscustomobject]@{ State = 'PRESENT'; Value = $value; Label = $label }
        }
        'file' {
            $value = Get-FileSecretValue -Path $Target.path
            $label = "file:$($Target.path)"
            if ([string]::IsNullOrEmpty($value)) { return [pscustomobject]@{ State = 'MISSING'; Value = ''; Label = $label } }
            return [pscustomobject]@{ State = 'PRESENT'; Value = $value; Label = $label }
        }
        default { return [pscustomobject]@{ State = 'NOT-CONFIGURED'; Value = ''; Label = "unknown target kind '$($Target.kind)'" } }
    }
}

function Format-Fingerprint {
    param([string]$Sha256)
    if (-not $Sha256) { return '-' }
    return $Sha256.Substring(0, [Math]::Min($FingerprintChars, $Sha256.Length))
}

$providerNames = if ($Provider.Count -gt 0) { @($Provider) } else { @($lock.providers.PSObject.Properties.Name) }
$lockChanged = $false

foreach ($name in $providerNames) {
    $entry = $lock.providers.$name
    # Optional seam: names the active key (opencode-go cutover) and can expand
    # `${activeKey}` in target names. Read regardless of source kind so a file
    # source can be seam-driven too (used by tests and file-based providers).
    $activeKey = ''
    $seamPathSetting = if ($entry.source.seamPath) { $entry.source.seamPath } elseif ($entry.seamPath) { $entry.seamPath } else { '' }
    if ($seamPathSetting) {
        $seamField = if ($entry.source.seamField) { $entry.source.seamField } elseif ($entry.seamField) { $entry.seamField } else { 'activeKey' }
        # A relative seam names the deployment's seam file. It is resolved beside
        # the lock first (the legacy in-tree layout), then beside this package's
        # assets/ - the copy the package ships - so a state-root lock still reads
        # the same seam record instead of looking for one in the state directory.
        $seamPath = if ([System.IO.Path]::IsPathRooted($seamPathSetting)) { $seamPathSetting }
        else {
            $packageAssets = Join-Path (Split-Path $PSScriptRoot -Parent) 'assets'
            $candidates = @(
                (Join-Path (Split-Path $LockPath -Parent) $seamPathSetting),
                (Join-Path $packageAssets $seamPathSetting),
                (Join-Path (Join-Path $HOME '.salmon/State/credential-rescue') $seamPathSetting)
            )
            $found = $candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
            if ($found) { $found } else { $candidates[1] }
        }
        $seam = Read-JsonFileQuiet -Path $seamPath
        if ($seam) { $activeKey = Get-JsonFieldValue -Object $seam -Field $seamField }
    }
    $source = Resolve-SourceValue -Source $entry.source -ActiveKey $activeKey
    $stored = Get-SecretFingerprint -Value '' -PrefixChars $FingerprintChars
    if ($entry.fingerprint -and $entry.fingerprint.sha256) {
        $stored = [pscustomobject]@{
            Present = $true
            Length  = [int]$entry.fingerprint.length
            Sha256  = [string]$entry.fingerprint.sha256
            Prefix  = ([string]$entry.fingerprint.sha256).Substring(0, [Math]::Min($FingerprintChars, 64))
        }
    }

    if ($Mode -eq 'Lock') {
        if ($source.State -ne 'SOURCE') {
            $rows.Add([pscustomobject]@{ Provider = $name; Target = $source.Detail; Status = 'LOCK-FAILED'; Length = 0; Fingerprint = '-' })
            $failures++
            continue
        }
        $computed = Get-SecretFingerprint -Value $source.Value -PrefixChars $FingerprintChars
        $entry.fingerprint = [pscustomobject]@{
            sha256   = $computed.Sha256
            length   = $computed.Length
            lockedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            lockedBy = $Actor
        }
        $lockChanged = $true
        $rows.Add([pscustomobject]@{ Provider = $name; Target = "source: $($source.Detail)"; Status = 'LOCKED'; Length = $computed.Length; Fingerprint = (Format-Fingerprint $computed.Sha256) })
        continue
    }

    # ---- Status -----------------------------------------------------------
    $expected = $null
    $sourceRow = switch ($source.State) {
        'SOURCE' {
            $computed = Get-SecretFingerprint -Value $source.Value -PrefixChars $FingerprintChars
            $expected = $computed
            if ($stored.Present -and -not (Test-SecretEqual -A $computed.Sha256 -B $stored.Sha256)) {
                $failures++
                [pscustomobject]@{ Provider = $name; Target = "source: $($source.Detail)"; Status = 'LOCK-DRIFT'; Length = $computed.Length; Fingerprint = (Format-Fingerprint $computed.Sha256) }
            }
            elseif (-not $stored.Present) {
                [pscustomobject]@{ Provider = $name; Target = "source: $($source.Detail)"; Status = 'UNLOCKED'; Length = $computed.Length; Fingerprint = (Format-Fingerprint $computed.Sha256) }
            }
            else {
                [pscustomobject]@{ Provider = $name; Target = "source: $($source.Detail)"; Status = 'SOURCE'; Length = $computed.Length; Fingerprint = (Format-Fingerprint $computed.Sha256) }
            }
        }
        'SOURCE-SKIPPED' {
            if ($stored.Present) { $expected = $stored }
            [pscustomobject]@{ Provider = $name; Target = $source.Detail; Status = 'SOURCE-SKIPPED'; Length = $stored.Length; Fingerprint = (Format-Fingerprint $stored.Sha256) }
        }
        default {
            $failures++
            [pscustomobject]@{ Provider = $name; Target = $source.Detail; Status = 'SOURCE-MISSING'; Length = 0; Fingerprint = '-' }
        }
    }
    $rows.Add($sourceRow)

    if (-not $expected) {
        # No expected value: consumers cannot be judged; say so rather than PASS.
        $rows.Add([pscustomobject]@{ Provider = $name; Target = 'consumers'; Status = 'UNVERIFIED'; Length = 0; Fingerprint = '-' })
        continue
    }

    foreach ($target in @($entry.targets)) {
        if ($null -eq $target) { continue }
        $resolved = Resolve-TargetValue -Target $target -ActiveKey $activeKey
        $required = -not ($target.PSObject.Properties['required'] -and $target.required -eq $false)
        $candidate = Get-SecretFingerprint -Value $resolved.Value -PrefixChars $FingerprintChars
        $status = if ($resolved.State -eq 'NOT-CONFIGURED') { if ($required) { 'NOT-CONFIGURED' } else { 'NOT-CONFIGURED' } }
        elseif ($resolved.State -eq 'MISSING') { if ($required) { 'MISSING' } else { 'OPTIONAL-MISSING' } }
        elseif ((Get-SecretFingerprint -Value $resolved.Value).Sha256 -eq $expected.Sha256) { 'MATCH' }
        else { 'DRIFT' }

        if ($status -eq 'DRIFT' -or $status -eq 'MISSING' -or ($status -eq 'NOT-CONFIGURED' -and $required)) { $failures++ }
        $rows.Add([pscustomobject]@{
                Provider    = $name
                Target      = $resolved.Label
                Status      = $status
                Length      = $candidate.Length
                Fingerprint = (Format-Fingerprint $candidate.Sha256)
            })
    }
}

function Write-Report {
    <#
    .SYNOPSIS
        Fixed-width report. Explicit columns, because Format-Table drops columns
        when a long target path eats the console width - and Status must never
        be the column that disappears.
    #>
    param($Rows)

    Write-Output ("{0,-12} {1,-44} {2,-16} {3,4}  {4}" -f 'Provider', 'Target', 'Status', 'Len', 'Fingerprint')
    Write-Output ("{0,-12} {1,-44} {2,-16} {3,4}  {4}" -f ('-' * 12), ('-' * 44), ('-' * 16), '----', ('-' * 12))
    foreach ($row in $Rows) {
        $target = [string]$row.Target
        if ($target.Length -gt 44) { $target = $target.Substring(0, 30) + '…' + $target.Substring($target.Length - 13) }
        Write-Output ("{0,-12} {1,-44} {2,-16} {3,4}  {4}" -f $row.Provider, $target, $row.Status, $row.Length, $row.Fingerprint)
    }
}

if ($Mode -eq 'Lock' -and $lockChanged) {
    $lockDir = Split-Path -Parent $LockPath
    if ($lockDir -and -not (Test-Path -LiteralPath $lockDir -PathType Container)) {
        New-Item -ItemType Directory -Path $lockDir -Force | Out-Null
    }
    $lock | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $LockPath
    if ($Json) { Write-Output ($rows | ConvertTo-Json -Depth 5) } else { Write-Output "Lock written: $LockPath" }
    Write-Report -Rows $rows
    if ($failures -gt 0) { exit 1 }
    exit 0
}

if ($Json) { Write-Output ($rows | ConvertTo-Json -Depth 5) }
else {
    Write-Output ("Provider lock ({0}) - {1} provider(s), fingerprints only" -f $Mode, $providerNames.Count)
    Write-Report -Rows $rows
    Write-Output ('Summary: {0} row(s) fail the lock; exit {1}' -f $failures, $(if ($failures -gt 0) { 1 } else { 0 }))
}
if ($failures -gt 0) { exit 1 }
exit 0
