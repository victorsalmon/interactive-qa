# Shared credential-change logger for Skills/credential-rescue.
# Dot-source this file; do NOT duplicate the function per script.
# Machine rule: every credential add/remove/move/modify appends one JSON line
# to ${env:USERPROFILE}\.machine\logs\credential-changes.jsonl — NAMES only, never values.

function Write-CredLog {
    param(
        [string]$Action,
        [string]$Target,
        [string]$Detail,
        [string]$Actor = 'agent/credential-rescue',
        [string]$Reason = 'opencode-go key exhaustion cutover',
        [string]$LogPath = "$($env:USERPROFILE)\.machine\logs\credential-changes.jsonl"
    )
    try {
        $line = @{
            ts = [datetimeoffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ssZ")
            actor = $Actor; action = $Action; target = $Target
            detail = $Detail; reason = $Reason; valuesLogged = $false
        } | ConvertTo-Json -Compress
        $dir = Split-Path -Parent $LogPath
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Add-Content -LiteralPath $LogPath -Value $line -Encoding utf8
    } catch { Write-Warning "credential log append failed: $($_.Exception.Message)" }
}
