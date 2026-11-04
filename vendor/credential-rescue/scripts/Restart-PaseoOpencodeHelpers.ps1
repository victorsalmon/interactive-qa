#Requires -Version 5.1
<#
.SYNOPSIS
    DEPRECATED shim — process-only stop without the provider-env pin is unsafe.
    Forwards to Repair-Paseo.ps1, which pins first and then restarts.
#>
[CmdletBinding()]
param(
    [switch]$VerifyOnly
)

Write-Warning 'Restart-PaseoOpencodeHelpers.ps1 is deprecated (stop-only, no env pin); forwarding to Repair-Paseo.ps1. Update callers.'
$fwd = @()
if ($VerifyOnly) { $fwd += '-VerifyOnly' }
& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'Repair-Paseo.ps1') @fwd
exit $LASTEXITCODE
