# Shared Paseo helpers for Skills/credential-rescue.
# Single copy — dot-source from Repair-Paseo.ps1 (canonical) and any shim.
# Secret VALUES are never printed here; pool matches are reported as GO<n> labels.

function Resolve-PaseoCli {
    param([string]$Explicit)
    if ($Explicit -and (Test-Path -LiteralPath $Explicit)) { return $Explicit }
    $cmd = Get-Command paseo -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $fallback = 'C:\Program Files\Paseo\resources\bin\paseo.cmd'
    if (Test-Path -LiteralPath $fallback) { return $fallback }
    return ''
}

function Get-PaseoProcs {
    Get-Process -Name 'Paseo' -ErrorAction SilentlyContinue
}

function Get-HelperProcs {
    Get-CimInstance Win32_Process -Filter "Name='opencode.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match 'opencode.*serve' }
}

function Get-DaemonAlive {
    $pidFile = Join-Path $env:USERPROFILE '.paseo\paseo.pid'
    if (-not (Test-Path -LiteralPath $pidFile)) { return $false }
    try {
        $j = Get-Content -LiteralPath $pidFile -Raw | ConvertFrom-Json
        return [bool](Get-Process -Id $j.pid -ErrorAction SilentlyContinue)
    } catch { return $false }
}

function Set-PaseoOpencodeEnv {
    # Pin the active key into agents.providers.<id>.env so a worker restart
    # rebuilds the server manager WITH the credential. Values never printed.
    param([string]$ConfigPath, [string]$ProviderId, [string]$KeyValue)
    if (-not (Test-Path -LiteralPath $ConfigPath)) { Write-Warning "Paseo config not found at $ConfigPath"; return $false }
    $stamp = [datetimeoffset]::UtcNow.ToString('yyyyMMddTHHmmssZ')
    Copy-Item -LiteralPath $ConfigPath -Destination "$ConfigPath.bak-$stamp" -Force
    $cfg = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    if ($null -eq $cfg.agents -or $null -eq $cfg.agents.providers) { Write-Warning "Paseo config has no agents.providers; skipping."; return $false }
    $prov = $cfg.agents.providers.PSObject.Properties | Where-Object Name -IEQ $ProviderId | Select-Object -First 1
    if (-not $prov) {
        $cfg.agents.providers | Add-Member -NotePropertyName $ProviderId -NotePropertyValue ([pscustomobject]@{}) -Force
        $prov = $cfg.agents.providers.PSObject.Properties | Where-Object Name -IEQ $ProviderId | Select-Object -First 1
    }
    $entry = $prov.Value
    if ($null -eq $entry.PSObject.Properties['env']) { $entry | Add-Member -NotePropertyName env -NotePropertyValue ([pscustomobject]@{}) -Force }
    $entry.env | Add-Member -NotePropertyName OPENCODE_GO_KEY -NotePropertyValue $KeyValue -Force
    $entry.env | Add-Member -NotePropertyName OPENCODE_API_KEY -NotePropertyValue $KeyValue -Force
    $cfg | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $ConfigPath -Encoding utf8 -NoNewline
    return $true
}

function Get-PoolKeyValue {
    # Resolve a pool key by NAME or NUMBER with a Machine -> User fallback.
    # Pool keys are normally Machine scope, but writing Machine scope needs an
    # elevation prompt; a key staged at User scope (a rescue that could not get
    # the UAC click) must still resolve, or the cutover half-applies. User scope
    # is the same trust boundary as the User OPENCODE_GO_KEY/auth.json copies, so
    # the fallback widens availability, not exposure. Returns '' when neither
    # scope holds a value; never prints the value.
    param([string]$Name = '', [int]$Number = 0, [ref]$ScopeOut)
    if ([string]::IsNullOrWhiteSpace($Name)) {
        if ($Number -lt 1) { return '' }
        $Name = "OPENCODE_GO${Number}_KEY"
    }
    foreach ($scope in @('Machine', 'User')) {
        $v = [Environment]::GetEnvironmentVariable($Name, $scope)
        if (-not [string]::IsNullOrWhiteSpace($v)) {
            if ($ScopeOut) { $ScopeOut.Value = $scope }
            return $v
        }
    }
    if ($ScopeOut) { $ScopeOut.Value = '' }
    return ''
}

function Get-PoolMatchLabel {
    # Compare-only pool match: returns GO<n> or no-pool-match. Never prints values.
    param([string]$KeyValue)
    if ([string]::IsNullOrWhiteSpace($KeyValue)) { return 'no-pool-match' }
    foreach ($n in 1..9) {
        $pv = Get-PoolKeyValue -Number $n
        if (-not [string]::IsNullOrWhiteSpace($pv) -and $pv -eq $KeyValue) { return "GO$n" }
    }
    return 'no-pool-match'
}

function Get-DshApiKeyEnvName {
    # DeepSeek Harness credential reference: the apiKeyEnv NAME from the managed
    # DSH model patch (owned by salmon-run Tools/Install-PaseoDeepSeekHarness.ps1).
    # Returns the env-var NAME only, never a value. The DSH child reads that
    # Machine/User env var at spawn — there is no provider-env pin for it in
    # ~/.paseo/config.json, so only a (worker) restart picks up a changed value.
    param([string]$PatchPath = '')
    if ([string]::IsNullOrWhiteSpace($PatchPath)) {
        $dshHome = $env:DSH_HOME
        if ([string]::IsNullOrWhiteSpace($dshHome)) { $dshHome = Join-Path $env:USERPROFILE '.dsh' }
        $PatchPath = Join-Path $dshHome 'profiles\acp\salmon-run-model.yml'
    }
    if (-not (Test-Path -LiteralPath $PatchPath)) { return '<patch-missing>' }
    $hit = Select-String -LiteralPath $PatchPath -Pattern '^\s*apiKeyEnv\s*:\s*(\S+)' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $hit) { return '<apiKeyEnv-missing>' }
    return $hit.Matches[0].Groups[1].Value.Trim()
}

function Get-DshKeyGoLabel {
    # GO<n>/no-pool-match/empty label for the DSH apiKeyEnv key. Names only.
    param([string]$ApiKeyEnvName = '')
    if ([string]::IsNullOrWhiteSpace($ApiKeyEnvName)) { $ApiKeyEnvName = Get-DshApiKeyEnvName }
    if ($ApiKeyEnvName -like '<*>') { return $ApiKeyEnvName }
    $v = Get-PoolKeyValue -Name $ApiKeyEnvName
    if ([string]::IsNullOrWhiteSpace($v)) { return 'env-missing' }
    return Get-PoolMatchLabel -KeyValue $v
}

function Set-DshApiKeyEnv {
    # Repoint the DSH patch apiKeyEnv NAME (never a value) at another env var,
    # e.g. OPENCODE_GO3_KEY -> OPENCODE_GO5_KEY. Only the one line changes;
    # every other patch line stays byte-identical (unlike a full installer
    # re-run, which would also rebuild the provider entry and drop any
    # non-default lines it was not passed). Touches nothing until the DSH
    # child respawns (worker restart) — report that, don't hide it.
    # Returns @{ Changed = [bool]; Old = [string]; Backup = [string] }.
    param([string]$ApiKeyEnvName, [string]$PatchPath = '')
    if ($ApiKeyEnvName -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { throw "Refusing to write apiKeyEnv '$ApiKeyEnvName': not a plain env-var name." }
    if ([string]::IsNullOrWhiteSpace($PatchPath)) {
        $dshHome = $env:DSH_HOME
        if ([string]::IsNullOrWhiteSpace($dshHome)) { $dshHome = Join-Path $env:USERPROFILE '.dsh' }
        $PatchPath = Join-Path $dshHome 'profiles\acp\salmon-run-model.yml'
    }
    if (-not (Test-Path -LiteralPath $PatchPath)) { throw "DSH patch not found at $PatchPath." }
    $raw = [System.IO.File]::ReadAllText($PatchPath)
    $eol = if ($raw.Contains("`r`n")) { "`r`n" } else { "`n" }
    if ($raw -notmatch '(?m)^\s*apiKeyEnv\s*:\s*\S+') { throw "No apiKeyEnv line in $PatchPath — reinstall via Install-PaseoDeepSeekHarness.ps1." }
    $old = ([regex]::Match($raw, '(?m)^\s*apiKeyEnv\s*:\s*(\S+)')).Groups[1].Value.Trim()
    if ($old -ceq $ApiKeyEnvName) { return @{ Changed = $false; Old = $old; Backup = '' } }
    $stamp = [datetimeoffset]::UtcNow.ToString('yyyyMMddTHHmmssZ')
    $backup = "$PatchPath.bak-$stamp"
    [System.IO.File]::Copy($PatchPath, $backup)
    $bytes = [System.IO.File]::ReadAllBytes($PatchPath)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $enc = New-Object System.Text.UTF8Encoding($hasBom)
    $new = [regex]::Replace($raw, '(?m)^\s*apiKeyEnv\s*:.*$', "    apiKeyEnv: $ApiKeyEnvName")
    if ($eol -eq "`r`n") { $new = $new -replace "(?<!\r)\n", "`r`n" }
    [System.IO.File]::WriteAllText($PatchPath, $new, $enc)
    return @{ Changed = $true; Old = $old; Backup = $backup }
}
