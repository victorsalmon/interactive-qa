#Requires -Version 7.0
<#
.SYNOPSIS
    DEPRECATED shim — forwards to Repair-Paseo.ps1 (the single Paseo entry).
#>
[CmdletBinding()]
param(
    [ValidateSet('Worker', 'App')]
    [string]$Mode = 'Worker',
    [switch]$FullApp,
    [switch]$VerifyOnly,
    [switch]$NoReopen,
    [int]$StartWaitSeconds = 60,
    [string]$PaseoExe = 'C:\Program Files\Paseo\Paseo.exe',
    [string]$PaseoCli = '',
    [string]$PaseoConfig = ''
)

Write-Warning 'Restart-Paseo.ps1 is deprecated; forwarding to Repair-Paseo.ps1 (same flags). Update callers.'
$fwd = @()
if ($FullApp) { $fwd += '-FullApp' } else { $fwd += @('-Mode', $Mode) }
if ($VerifyOnly) { $fwd += '-VerifyOnly' }
if ($NoReopen) { $fwd += '-NoReopen' }
$fwd += @('-StartWaitSeconds', $StartWaitSeconds)
if ($PaseoExe) { $fwd += @('-PaseoExe', $PaseoExe) }
if ($PaseoCli) { $fwd += @('-PaseoCli', $PaseoCli) }
if ($PaseoConfig) { $fwd += @('-PaseoConfig', $PaseoConfig) }
& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'Repair-Paseo.ps1') @fwd
exit $LASTEXITCODE
