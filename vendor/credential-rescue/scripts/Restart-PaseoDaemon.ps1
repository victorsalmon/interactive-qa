#Requires -Version 5.1
<#
.SYNOPSIS
    DEPRECATED shim — forwards to Repair-Paseo.ps1 (the single Paseo entry).
#>
[CmdletBinding()]
param(
    [switch]$VerifyOnly,
    [string]$PaseoCli = '',
    [switch]$SkipCanary,
    [string]$Actor = 'agent/credential-rescue',
    [string]$LogPath = "$($env:USERPROFILE)\.machine\logs\credential-changes.jsonl"
)

Write-Warning 'Restart-PaseoDaemon.ps1 is deprecated; forwarding to Repair-Paseo.ps1. Update callers.'
$fwd = @('-Mode', 'Worker', '-Actor', $Actor, '-LogPath', $LogPath)
if ($VerifyOnly) { $fwd += '-VerifyOnly' }
if ($SkipCanary) { $fwd += '-SkipCanary' }
if ($PaseoCli) { $fwd += @('-PaseoCli', $PaseoCli) }
& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'Repair-Paseo.ps1') @fwd
exit $LASTEXITCODE
