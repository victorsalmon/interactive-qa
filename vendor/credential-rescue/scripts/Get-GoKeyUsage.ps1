#Requires -Version 7.0
<#
.SYNOPSIS
    Reads the opencode-go plan usage windows for one or every pool key.

.DESCRIPTION
    GET https://opencode.ai/inference/go/v1/usage returns, per key:

        { "usage": {
            "rolling": { "status": "ok",          "percent": 0,  "resetsAt": "..." },
            "weekly":  { "status": "ok",          "percent": 0,  "resetsAt": "..." },
            "monthly": { "status": "rate-limited","percent": 100,"resetsAt": "..." } } }

    This is a zero-token, non-blocking read: no model request, no CLI spawn, no
    hang. It replaces the "kill a canary after 60s and grep the log" hop used by
    Test-GoKey.ps1 for the question "how much is left?", while Test-GoKey remains
    the authority on "does this key work at all".

    Undocumented endpoint (observed live 2026-11-02). Treat it as an
    optimisation: if a call fails, fall back to Test-GoKey.ps1 rather than
    reporting a key healthy.

    SECURITY: key VALUES are never printed, logged, or written. Output identifies
    keys by number and scope only.

.PARAMETER UsageJsonFile
    Test/fixture seam: read the usage response body from this file instead of
    GET https://opencode.ai/inference/go/v1/usage. The file carries the same
    shape the endpoint returns (`{ "usage": { "rolling": ..., ... } }`), so a
    test can exercise the real parsing/formatting path offline.

.EXAMPLE
    ./Get-GoKeyUsage.ps1
    ./Get-GoKeyUsage.ps1 -KeyNumber 4
    ./Get-GoKeyUsage.ps1 -Json
#>
[CmdletBinding()]
param(
    [int]$KeyNumber = 0,
    [string]$KeyValue = '',
    [switch]$Json,
    [int]$TimeoutSeconds = 20,
    [string]$UsageJsonFile = ''
)

$ErrorActionPreference = 'Stop'

# Ledger date seam: format/parse shared with Set-/Get-OpencodeGoFreshness.
. (Join-Path $PSScriptRoot 'lib\LedgerDate.ps1')

function Get-PoolKeyFromScope {
    param([int]$Number, [string]$Scope)
    $bag = [Environment]::GetEnvironmentVariables($Scope)
    $name = "OPENCODE_GO${Number}_KEY"
    if ($bag.ContainsKey($name) -and -not [string]::IsNullOrWhiteSpace($bag[$name])) {
        return [pscustomobject]@{ Value = [string]$bag[$name]; Scope = $Scope }
    }
    return $null
}

function Resolve-KeyTargets {
    if (-not [string]::IsNullOrWhiteSpace($KeyValue)) {
        return @([pscustomobject]@{ Index = $KeyNumber; Value = $KeyValue; Scope = 'Explicit' })
    }
    $numbers = [System.Collections.Generic.SortedSet[int]]::new()
    foreach ($scope in @('Machine', 'User')) {
        $bag = [Environment]::GetEnvironmentVariables($scope)
        foreach ($name in $bag.Keys) {
            if ($name -match '^OPENCODE_GO(\d+)_KEY$' -and -not [string]::IsNullOrWhiteSpace($bag[$name])) {
                [void]$numbers.Add([int]$Matches[1])
            }
        }
    }
    if ($KeyNumber -gt 0) { $numbers = [System.Collections.Generic.SortedSet[int]]::new([int[]]@($KeyNumber)) }

    $targets = @()
    foreach ($n in $numbers) {
        $found = Get-PoolKeyFromScope -Number $n -Scope 'Machine'
        if (-not $found) { $found = Get-PoolKeyFromScope -Number $n -Scope 'User' }
        if ($found) { $targets += [pscustomobject]@{ Index = $n; Value = $found.Value; Scope = $found.Scope } }
    }
    return $targets
}

function Get-UsageWindow {
    param($Usage, [string]$Name)
    if ($null -eq $Usage -or $null -eq $Usage.PSObject.Properties[$Name]) { return $null }
    $w = $Usage.$Name
    # ConvertFrom-Json re-types an ISO timestamp as [datetime]; stringifying it
    # with [string] renders the AMBIENT culture (`11/09/2026 00:00:00`), which
    # is the cl-common-n42 defect. Format through the ledger seam instead: ISO
    # when the shape is known, the raw text when it is not (the writer then
    # refuses to persist it rather than guessing).
    $resetsState = Resolve-LedgerDateText -Text $(if ($w.PSObject.Properties['resetsAt']) { $w.resetsAt } else { '' })
    $resets = if ($resetsState.Status -eq 'ok') { $resetsState.Iso } else { $resetsState.Raw }
    return [pscustomobject]@{
        Status   = if ($w.PSObject.Properties['status']) { [string]$w.status } else { '' }
        Percent  = if ($w.PSObject.Properties['percent']) { [int]$w.percent } else { -1 }
        ResetsAt = $resets
    }
}

$rows = @()
foreach ($t in (Resolve-KeyTargets)) {
    $label = if ($t.Index -gt 0) { "GO$($t.Index)" } else { 'explicit' }
    $row = [pscustomobject]@{
        Key = $label; Scope = $t.Scope; Http = 0
        Rolling = $null; Weekly = $null; Monthly = $null
        Verdict = ''; Note = ''
    }
    try {
        if (-not [string]::IsNullOrWhiteSpace($UsageJsonFile)) {
            # Fixture seam: same body the endpoint returns, read from disk.
            $row.Http = 200
            $body = [string](Get-Content -LiteralPath $UsageJsonFile -Raw)
        } else {
            $r = Invoke-WebRequest -Uri 'https://opencode.ai/inference/go/v1/usage' -Method GET `
                -SkipHttpErrorCheck -TimeoutSec $TimeoutSeconds -Headers @{
                    Authorization        = "Bearer $($t.Value)"
                    'User-Agent'         = 'cl-fleet-quota-probe/1.0'
                    'x-opencode-session' = 'cl-fleet-quota-probe'
                }
            $row.Http = [int]$r.StatusCode
            $body = [string]$r.Content
        }
        if ($row.Http -eq 200) {
            $j = $body | ConvertFrom-Json
            $row.Rolling = Get-UsageWindow -Usage $j.usage -Name 'rolling'
            $row.Weekly  = Get-UsageWindow -Usage $j.usage -Name 'weekly'
            $row.Monthly = Get-UsageWindow -Usage $j.usage -Name 'monthly'

            # The binding window is whichever is closest to its cap; a
            # rate-limited window means the key is spent regardless of percent.
            $windows = @($row.Rolling, $row.Weekly, $row.Monthly) | Where-Object { $null -ne $_ }
            if ($windows | Where-Object { $_.Status -ne 'ok' }) { $row.Verdict = 'EXHAUSTED' }
            elseif (($windows | Measure-Object -Property Percent -Maximum).Maximum -ge 95) { $row.Verdict = 'NEAR-CAP' }
            elseif (($windows | Measure-Object -Property Percent -Maximum).Maximum -ge 80) { $row.Verdict = 'TIGHT' }
            else { $row.Verdict = 'HEALTHY' }
        } elseif ($row.Http -eq 401) {
            $row.Verdict = 'REVOKED'; $row.Note = '401 - key invalid, expired, or revoked'
        } elseif ($row.Http -eq 403) {
            $row.Verdict = 'FORBIDDEN'; $row.Note = '403 - key cannot read usage; fall back to Test-GoKey.ps1'
        } else {
            $row.Verdict = 'UNKNOWN'; $row.Note = "HTTP $($row.Http) - endpoint shape may have changed; fall back to Test-GoKey.ps1"
        }
    } catch {
        $row.Verdict = 'ERROR'; $row.Note = $_.Exception.Message
    }
    $rows += $row
}

if ($Json) {
    $rows | ConvertTo-Json -Depth 4
    return
}

$rows | Select-Object Key, Scope, Http, Verdict,
    @{ n = 'rolling%'; e = { $_.Rolling.Percent } },
    @{ n = 'weekly%';  e = { $_.Weekly.Percent } },
    @{ n = 'monthly%'; e = { $_.Monthly.Percent } },
    @{ n = 'resets(monthly)'; e = { $_.Monthly.ResetsAt } },
    Note | Format-Table -AutoSize
