#Requires -Version 5.1
<#
.SYNOPSIS
    Backup, restore, and verify the ~/.aws credential store on this dev machine.

.DESCRIPTION
    ~/.aws (config + credentials) has been deleted by external cleanup tools
    repeatedly (2026-09-13, 2026-09-15). This script is the fleet-canonical
    repair tool owned by Skills/credential-rescue.

    Restore source order:
      0. Committed repo bundle: -RepoZipDir\restore.zip + restore.txt +
         restore.ps1 (encrypted zip; delegated to the bundle script)
      1. -BackupRoot/latest plaintext copy (written by -Mode Backup)
      2. <file>.enc in the newest backup dir, decrypted with AWS_CRED_BACKUP_KEY
         (64-hex AES-256 key read from ~/.machine/.env)
      3. -CredentialsFile <path> (operator-provided credentials file)
      4. -FromSessionDb: scrape agent session stores (Devin cli sessions.db /
         transcripts / summaries, opencode-data opencode.db / tool-output /
         snapshot) for the newest ini-shaped credential blocks
      5. config falls back to the embedded canonical template; credentials then
         require an operator paste (IAM console / off-machine store)

    SAFETY: never prints a secret value, AKIA string, or file contents.
    Every mutation appends one JSON line to the fleet credential log
    (names and sources only) per saas-modules AGENTS.md machine rule 1.

.PARAMETER Mode
    Status   - report which ~/.aws files and backups exist (default)
    Backup   - snapshot ~/.aws/config + credentials to BackupRoot/<utc> and latest/
    Restore  - rebuild ~/.aws from the source order above
    Verify   - aws configure list-profiles + sts get-caller-identity per profile

.PARAMETER BackupRoot
    Backup home. MUST live outside ~/.aws (the cleaner wipes the whole dir).
    Default: ~/.machine/backups

.EXAMPLE
    pwsh -File Restore-AwsStore.ps1 -Mode Restore -FromSessionDb
.EXAMPLE
    pwsh -File Restore-AwsStore.ps1 -Mode Backup
#>
[CmdletBinding()]
param(
    [ValidateSet('Status','Backup','Restore','Verify')]
    [string]$Mode = 'Status',
    [string]$BackupRoot = (Join-Path $env:USERPROFILE '.machine\backups'),
    [string]$RepoZipDir = "$($env:CL_REPOS_ROOT)\cl-common\restore",
    [switch]$SkipRepoZip,
    [string]$CredentialsFile = '',
    [switch]$FromSessionDb,
    [switch]$Encrypt,
    [switch]$DryRun,
    [string]$Actor = 'agent/credential-rescue',
    [string]$Reason = '',
    [string]$LogPath = "$($env:USERPROFILE)\.machine\logs\credential-changes.jsonl"
)

$ErrorActionPreference = 'Stop'
$AwsHome = Join-Path $env:USERPROFILE '.aws'
$ExpectedCredProfiles = @('dev-daily-fixed', 'currentsSetup')
$ExpectedConfigProfiles = @('dev-daily-fixed', 'currentsSetup')

# ---------------------------------------------------------------- logging ---
function Write-CredLog {
    param([string]$Action, [string]$Target, [string]$Detail)
    try {
        $line = @{
            ts     = [datetimeoffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ssZ")
            actor  = $Actor
            action = $Action
            target = $Target
            detail = $Detail
            reason = $Reason
            valuesLogged = $false
        } | ConvertTo-Json -Compress
        $dir = Split-Path -Parent $LogPath
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Add-Content -LiteralPath $LogPath -Value $line -Encoding utf8
    } catch { Write-Warning "credential log append failed: $($_.Exception.Message)" }
}

# ------------------------------------------------------------- encryption ---
function Get-BackupKeyBytes {
    # Machine secrets home (2026-11-04): ~/.machine replaced ~/.salmon. The legacy path is a
    # read-only fallback so this keeps working until the old tree is retired; never write there.
    $envFile = Join-Path $env:USERPROFILE '.machine\.env'
    if (-not (Test-Path -LiteralPath $envFile)) {
        $legacyEnvFile = Join-Path $env:USERPROFILE '.salmon\.env'
        if (Test-Path -LiteralPath $legacyEnvFile) { $envFile = $legacyEnvFile }
    }
    if (-not (Test-Path -LiteralPath $envFile)) { return $null }
    foreach ($line in @(Get-Content -LiteralPath $envFile -ErrorAction SilentlyContinue)) {
        if ($line -match '^\s*AWS_CRED_BACKUP_KEY\s*=\s*(\S+)\s*$') {
            $raw = $Matches[1].Trim('"').Trim("'")
            if ($raw -match '^[0-9a-fA-F]{64}$') {
                $b = New-Object byte[] 32
                for ($i = 0; $i -lt 32; $i++) { $b[$i] = [Convert]::ToByte($raw.Substring($i * 2, 2), 16) }
                return $b
            }
            $sha = [System.Security.Cryptography.SHA256]::Create()
            try { return ,[byte[]]($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($raw))) } finally { $sha.Dispose() }
        }
    }
    return $null
}

function Protect-FileBytes {
    param([byte[]]$Data, [byte[]]$Key)
    $aes = [System.Security.Cryptography.Aes]::Create()
    $aes.KeySize = 256; $aes.Key = $Key; $aes.Mode = 'CBC'; $aes.GenerateIV()
    $enc = $aes.CreateEncryptor()
    try { $cipher = $enc.TransformFinalBlock($Data, 0, $Data.Length) } finally { $aes.Dispose() }
    $out = New-Object byte[] ($aes.IV.Length + $cipher.Length)
    [Array]::Copy($aes.IV, 0, $out, 0, $aes.IV.Length)
    [Array]::Copy($cipher, 0, $out, $aes.IV.Length, $cipher.Length)
    return ,$out
}

function Unprotect-FileBytes {
    param([byte[]]$Data, [byte[]]$Key)
    if ($Data.Length -lt 17) { throw 'encrypted blob too short' }
    $iv = $Data[0..15]
    $cipher = $Data[16..($Data.Length - 1)]
    $aes = [System.Security.Cryptography.Aes]::Create()
    $aes.KeySize = 256; $aes.Key = $Key; $aes.Mode = 'CBC'; $aes.IV = [byte[]]$iv
    $dec = $aes.CreateDecryptor()
    try { return ,[byte[]]($dec.TransformFinalBlock([byte[]]$cipher, 0, $cipher.Length)) } finally { $aes.Dispose() }
}

# ------------------------------------------------------------ scrape (db) ---
function ConvertFrom-EscapedText {
    param([string]$Text)
    $t = $Text -replace '\\r\\n', "`n" -replace '\\n', "`n" -replace '\\r', "`n"
    $t = $t -replace '\\"', '"' -replace "\\'", "'"
    return $t
}

function Find-CredentialBlocks {
    <# Returns ordered list of @{Profile; Aki; Secret} for every ini-shaped
       [profile]\n aws_access_key_id = AKIA..\n aws_secret_access_key = ..
       cluster in $Text, in file order (later = more recently written). #>
    param([string]$Text)
    $list = @()
    $rx = [regex]'(?ms)^\s*\[(?<p>[A-Za-z0-9_.\-]+)\][^\S\r\n]*\r?\n(?:(?!\[)[^\r\n]*\r?\n){0,6}?\s*aws_access_key_id\s*=\s*(?<a>AKIA[0-9A-Z]{16})[^\S\r\n]*\r?\n\s*aws_secret_access_key\s*=\s*(?<s>[A-Za-z0-9/+=]{30,})'
    foreach ($m in $rx.Matches($Text)) {
        $p = ($m.Groups['p'].Value.Trim() -replace '^profile\s+', '').Trim()
        $list += @{ Profile = $p; Aki = $m.Groups['a'].Value.Trim(); Secret = $m.Groups['s'].Value.Trim() }
    }
    return $list
}

function Get-OpencodeDataHome {
    # XDG_DATA_HOME (User) is authoritative. The ${env:CL_REPOS_ROOT}\Tools\opencode-data
    # copy is a legacy stub that no longer holds opencode.db or the logs.
    foreach ($scope in @('User', 'Process')) {
        $v = [Environment]::GetEnvironmentVariable('XDG_DATA_HOME', $scope)
        if (-not [string]::IsNullOrWhiteSpace($v)) { return (Join-Path $v 'opencode') }
    }
    return "$($env:CL_REPOS_ROOT)\Tools\opencode-data\opencode"
}

function Get-SessionDbCandidates {
    $ocHome = Get-OpencodeDataHome
    $dirs = @(
        (Join-Path $env:APPDATA 'devin\cli\transcripts'),
        (Join-Path $env:APPDATA 'devin\cli\summaries'),
        (Join-Path $env:APPDATA 'devin\cli'),
        (Join-Path $ocHome 'tool-output'),
        (Join-Path $ocHome 'snapshot'),
        $ocHome,
        # legacy stub kept as a last resort for older scrapes
        "$($env:CL_REPOS_ROOT)\Tools\opencode-data\opencode\tool-output",
        "$($env:CL_REPOS_ROOT)\Tools\opencode-data\opencode\snapshot",
        "$($env:CL_REPOS_ROOT)\Tools\opencode-data\opencode"
    )
    $files = @()
    foreach ($d in $dirs) {
        if (Test-Path -LiteralPath $d) {
            $files += @(Get-ChildItem -LiteralPath $d -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '\.(db|json|md|txt|log)$' -or $_.Name -like 'tool_*' -or $_.Length -gt 0 })
        }
    }
    return @($files | Sort-Object LastWriteTime -Descending)
}

function Get-ScrapedCredentialCandidates {
    <# Scans session stores newest-file-first, last-position-first inside each
       file (later transcript entries are newer). Returns ordered unique
       candidates: @{Profile; Aki; Secret; Source}. Never prints values. #>
    $seen = @{}
    $out = @()
    foreach ($f in @(Get-SessionDbCandidates)) {
        $text = $null
        try { $text = [System.IO.File]::ReadAllText($f.FullName) } catch { continue }
        if ($text -notmatch 'aws_access_key_id') { continue }
        $blocks = @(Find-CredentialBlocks -Text (ConvertFrom-EscapedText $text))
        for ($i = $blocks.Count - 1; $i -ge 0; $i--) {
            $b = $blocks[$i]
            $sig = "$($b.Profile)|$($b.Aki)|$($b.Secret)"
            if ($seen.ContainsKey($sig)) { continue }
            $seen[$sig] = $true
            $out += @{ Profile = $b.Profile; Aki = $b.Aki; Secret = $b.Secret; Source = $f.FullName }
        }
    }
    return $out
}

function Test-AwsCredentialPair {
    <# Writes a one-profile credentials file and verifies with sts.
       Returns $true when the key pair authenticates. Never prints values. #>
    param([string]$Profile, [string]$Aki, [string]$Secret)
    $credPath = Join-Path $AwsHome 'credentials'
    $body = "[{0}]`naws_access_key_id = {1}`naws_secret_access_key = {2}`n" -f $Profile, $Aki, $Secret
    $prior = $null
    if (Test-Path -LiteralPath $credPath) { $prior = [System.IO.File]::ReadAllText($credPath) }
    [System.IO.File]::WriteAllText($credPath, $body, (New-Object System.Text.UTF8Encoding($false)))
    $ErrorActionPreference = 'Continue'
    $null = aws sts get-caller-identity --profile $Profile --region ca-central-1 --query Arn --output text 2>$null
    $ok = ($LASTEXITCODE -eq 0)
    if ($prior) { [System.IO.File]::WriteAllText($credPath, $prior, (New-Object System.Text.UTF8Encoding($false))) }
    return $ok
}

# -------------------------------------------------------------- templates ---
function Get-CanonicalConfig {
    return @'
[default]
region = ca-central-1
output = json

[profile dev-daily-fixed]
region = ca-central-1
output = json

[profile currentsSetup]
region = ca-central-1
output = json
'@
}

function Write-AwsFile {
    param([string]$Name, [string]$Body)
    $path = Join-Path $AwsHome $Name
    if (-not (Test-Path -LiteralPath $AwsHome)) { New-Item -ItemType Directory -Path $AwsHome -Force | Out-Null }
    [System.IO.File]::WriteAllText($path, $Body, (New-Object System.Text.UTF8Encoding($false)))
    return $path
}

function Get-BackupDirs {
    if (-not (Test-Path -LiteralPath $BackupRoot)) { return @() }
    return @(Get-ChildItem -LiteralPath $BackupRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne 'latest' } | Sort-Object Name -Descending)
}

# ------------------------------------------------------------------ modes ---
switch ($Mode) {

    'Status' {
        Write-Output "aws home: $AwsHome"
        foreach ($n in @('config', 'credentials')) {
            $p = Join-Path $AwsHome $n
            $exists = Test-Path -LiteralPath $p -PathType Leaf
            Write-Output ("  {0}: {1}" -f $n, $(if ($exists) { 'present' } else { 'MISSING' }))
        }
        $latest = Join-Path $BackupRoot 'latest'
        Write-Output ("backup latest: " + $(if (Test-Path -LiteralPath $latest) { 'present' } else { 'absent' }) + "  root: $BackupRoot")
        Write-Output ("backups on disk: " + @(Get-BackupDirs).Count)
        Write-Output ("AWS_CRED_BACKUP_KEY resolvable: " + ($null -ne (Get-BackupKeyBytes)))
        break
    }

    'Backup' {
        $stamp = [datetimeoffset]::UtcNow.ToString('yyyyMMddTHHmmssZ')
        $dest = Join-Path $BackupRoot $stamp
        $names = @('config', 'credentials') | Where-Object { Test-Path -LiteralPath (Join-Path $AwsHome $_) -PathType Leaf }
        if ($names.Count -eq 0) { Write-Warning 'nothing to back up: ~/.aws config/credentials absent'; break }
        if ($DryRun) { Write-Output "dry-run: would back up $($names -join ', ') -> $dest"; break }
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
        $key = if ($Encrypt) { Get-BackupKeyBytes } else { $null }
        if ($Encrypt -and $null -eq $key) { throw '-Encrypt requested but AWS_CRED_BACKUP_KEY not found in ~/.machine/.env' }
        foreach ($n in $names) {
            $src = Join-Path $AwsHome $n
            if ($null -ne $key) {
                $bytes = Protect-FileBytes -Data ([System.IO.File]::ReadAllBytes($src)) -Key $key
                [System.IO.File]::WriteAllBytes((Join-Path $dest "$n.enc"), $bytes)
            } else {
                Copy-Item -LiteralPath $src -Destination (Join-Path $dest $n) -Force
            }
        }
        $latest = Join-Path $BackupRoot 'latest'
        if (Test-Path -LiteralPath $latest) { Remove-Item -LiteralPath $latest -Recurse -Force }
        Copy-Item -LiteralPath $dest -Destination $latest -Recurse -Force
        Write-Output ("backed up: " + ($names -join ', ') + " -> $dest" + $(if ($key) { ' (AES-256 encrypted)' } else { '' }))
        Write-CredLog -Action 'backup' -Target '~/.aws/config,~/.aws/credentials' -Detail "snapshot -> $dest ($(($names -join '+'))$(if($key){'; AES-256 via AWS_CRED_BACKUP_KEY'}))"
        break
    }

    'Restore' {
        $latest = Join-Path $BackupRoot 'latest'
        $wrote = @{}
        $from = ''

        # 0. committed repo bundle (operator-curated canonical artifact)
        $repoZipScript = Join-Path $RepoZipDir 'restore.ps1'
        if (-not $SkipRepoZip -and
            (Test-Path -LiteralPath (Join-Path $RepoZipDir 'restore.zip') -PathType Leaf) -and
            (Test-Path -LiteralPath (Join-Path $RepoZipDir 'restore.txt') -PathType Leaf) -and
            (Test-Path -LiteralPath $repoZipScript -PathType Leaf)) {
            if ($DryRun) {
                Write-Output "dry-run: would delegate to $repoZipScript -Apply"
            } else {
                try {
                    & $repoZipScript -Apply -Actor $Actor -Reason $Reason -LogPath $LogPath
                    foreach ($n in @('config', 'credentials')) {
                        if (Test-Path -LiteralPath (Join-Path $AwsHome $n) -PathType Leaf) { $wrote[$n] = 'repo-zip' }
                    }
                } catch { Write-Warning "repo-zip restore failed: $($_.Exception.Message)" }
            }
        }

        # 1-2. plaintext or encrypted newest backup
        if ((Test-Path -LiteralPath (Join-Path $latest 'credentials')) -or (Test-Path -LiteralPath (Join-Path $latest 'config'))) {
            foreach ($n in @('config', 'credentials')) {
                $src = Join-Path $latest $n
                if (Test-Path -LiteralPath $src -PathType Leaf) {
                    if (-not $DryRun) { Copy-Item -LiteralPath $src -Destination (Join-Path $AwsHome $n) -Force }
                    $wrote[$n] = "backup:latest"
                }
            }
            $from = 'backup:latest'
        } else {
            $encDir = @(Get-BackupDirs | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'credentials.enc') } | Select-Object -First 1)
            if ($encDir.Count -gt 0) {
                $key = Get-BackupKeyBytes
                if ($null -eq $key) { throw "encrypted backup exists at $($encDir[0].FullName) but AWS_CRED_BACKUP_KEY is unresolvable" }
                foreach ($n in @('config', 'credentials')) {
                    $src = Join-Path $encDir[0].FullName "$n.enc"
                    if (Test-Path -LiteralPath $src -PathType Leaf) {
                        $plain = Unprotect-FileBytes -Data ([System.IO.File]::ReadAllBytes($src)) -Key $key
                        if (-not $DryRun) { [System.IO.File]::WriteAllBytes((Join-Path $AwsHome $n), $plain) }
                        $wrote[$n] = "backup-enc:$($encDir[0].Name)"
                    }
                }
                $from = "backup-enc:$($encDir[0].Name)"
            }
        }

        # 3. operator-provided credentials file
        if (-not $wrote.ContainsKey('credentials') -and -not [string]::IsNullOrWhiteSpace($CredentialsFile)) {
            if (-not (Test-Path -LiteralPath $CredentialsFile -PathType Leaf)) { throw "-CredentialsFile not found: $CredentialsFile" }
            if (-not $DryRun) { Copy-Item -LiteralPath $CredentialsFile -Destination (Join-Path $AwsHome 'credentials') -Force }
            $wrote['credentials'] = "file:$CredentialsFile"
        }

        # 4. session-db scrape: gather all distinct (profile,key) candidates
        #    newest-first, then sts-verify each until one authenticates.
        $scrapedProfiles = @()
        if (-not $wrote.ContainsKey('credentials') -and $FromSessionDb) {
            $cands = @(Get-ScrapedCredentialCandidates)
            $byProfile = @{}
            foreach ($c in $cands) {
                if (-not $byProfile.ContainsKey($c.Profile)) { $byProfile[$c.Profile] = @() }
                $byProfile[$c.Profile] += $c
            }
            if ($DryRun) {
                foreach ($p in $byProfile.Keys) { Write-Output ("candidate profile {0}: {1} candidate(s)" -f $p, $byProfile[$p].Count) }
                $scrapedProfiles = @($byProfile.Keys)
            } else {
                $chosen = @{}
                foreach ($p in $byProfile.Keys) {
                    $tries = @($byProfile[$p] | Select-Object -First 8)
                    $ok = $false
                    foreach ($c in $tries) {
                        if (Test-AwsCredentialPair -Profile $c.Profile -Aki $c.Aki -Secret $c.Secret) { $chosen[$p] = $c; $ok = $true; break }
                    }
                    if (-not $ok) {
                        $chosen[$p] = $tries[0]
                        Write-Warning "no scraped candidate for '$p' passed sts; writing newest anyway (best-effort)"
                    }
                }
                if ($chosen.Count -gt 0) {
                    $order = @($ExpectedCredProfiles | Where-Object { $chosen.ContainsKey($_) }) +
                             @($chosen.Keys | Where-Object { $ExpectedCredProfiles -notcontains $_ })
                    $body = (($order | ForEach-Object {
                        "[{0}]`naws_access_key_id = {1}`naws_secret_access_key = {2}" -f $_, $chosen[$_].Aki, $chosen[$_].Secret
                    }) -join "`n`n") + "`n"
                    $null = Write-AwsFile -Name 'credentials' -Body $body
                    $scrapedProfiles = @($order)
                    $src = ($order | ForEach-Object { Split-Path -Leaf $chosen[$_].Source } | Select-Object -Unique) -join ','
                    $wrote['credentials'] = "sessiondb:$src"
                    Write-Output ("session-db restored profiles: " + ($order -join ', '))
                }
            }
        }

        # 5. config template fallback (+ stanzas for any extra scraped profiles)
        if (-not $wrote.ContainsKey('config')) {
            $cfg = Get-CanonicalConfig
            foreach ($p in $scrapedProfiles) {
                if ($cfg -notmatch "\[profile $([regex]::Escape($p))\]" -and $cfg -notmatch "\[$([regex]::Escape($p))\]") {
                    $cfg += "`n[profile $p]`nregion = ca-central-1`noutput = json`n"
                }
            }
            if (-not $DryRun) { $null = Write-AwsFile -Name 'config' -Body $cfg }
            $wrote['config'] = 'embedded-template'
        }

        if ($wrote.Count -eq 0 -and -not $wrote.ContainsKey('credentials')) {
            Write-Output 'nothing restorable: no backup, no -CredentialsFile, no session-db hits.'
            Write-Output 'operator path: paste fresh IAM keys into ~/.aws/credentials, or create new keys in IAM console.'
        }
        foreach ($k in $wrote.Keys) { Write-Output ("restored {0} <- {1}" -f $k, $wrote[$k]) }
        $missing = @()
        if (-not $DryRun) {
            $missing = @($ExpectedCredProfiles) | Where-Object {
                $c = Join-Path $AwsHome 'credentials'
                -not (Test-Path -LiteralPath $c) -or ((Get-Content -LiteralPath $c -Raw) -notmatch "\[$_\]")
            }
        } else {
            $missing = @($ExpectedCredProfiles | Where-Object { $scrapedProfiles -notcontains $_ -and -not $wrote.ContainsKey('credentials') })
        }
        if ($missing.Count -gt 0) { Write-Warning ("credentials still missing profiles: " + ($missing -join ', ')) }
        if (-not $DryRun) {
            Write-CredLog -Action 'restore' -Target '~/.aws/config,~/.aws/credentials' -Detail (($wrote.GetEnumerator() | ForEach-Object { "$($_.Key)<-$($_.Value)" }) -join '; ')
            Write-Output 'next: run -Mode Verify; then -Mode Backup to reseed the off-.aws snapshot.'
        }
        break
    }

    'Verify' {
        if (-not (Get-Command aws -ErrorAction SilentlyContinue)) { Write-Warning 'aws CLI not on PATH'; break }
        $ErrorActionPreference = 'Continue'   # native stderr must not terminate the loop
        $profiles = @(aws configure list-profiles 2>$null)
        Write-Output ("profiles: " + ($profiles -join ', '))
        foreach ($p in $profiles) {
            $id = aws sts get-caller-identity --profile $p --region ca-central-1 --query Arn --output text 2>$null
            if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($id)) { Write-Output ("  {0}: OK -> {1}" -f $p, $id) }
            else { Write-Output ("  {0}: FAILED/no-creds (run: aws sts get-caller-identity --profile {0})" -f $p) }
        }
        break
    }
}
