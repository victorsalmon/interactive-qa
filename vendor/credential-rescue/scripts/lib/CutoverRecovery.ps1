# Shared helpers for post-cutover recovery.
# Single copy: dot-sourced by Invoke-KeyCheckCutover.ps1 (marker + kill window),
# Invoke-CutoverRecovery.ps1 and Test-CutoverInProgress.ps1.
#
# SECURITY: nothing here reads, compares, or writes a key value. The only
# key-shaped facts are GO<n> labels, which live in the seam/outcome files this
# layer never parses.

function Get-CutoverStateDir {
    param([string]$Override)
    if (-not [string]::IsNullOrWhiteSpace($Override)) { return $Override }
    return (Join-Path $env:USERPROFILE '.salmon\State\key-check')
}

function Get-CutoverMarkerPath {
    param([string]$StateDir)
    return (Join-Path $StateDir 'cutover-in-progress.json')
}

function Get-CutoverKillWindowPath {
    param([string]$StateDir)
    return (Join-Path $StateDir 'cutover-kill-window.json')
}

function Get-CutoverLastMarkerPath {
    param([string]$StateDir)
    return (Join-Path $StateDir 'last-cutover.json')
}

function Read-CutoverJsonFile {
    <#
    .SYNOPSIS
        Parse a JSON file. Returns $null when absent; sets the caller-visible
        read error on the script scope so "absent" and "unreadable" stay
        distinguishable facts.
    #>
    param([string]$Path)
    $script:CutoverReadError = ''
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    try {
        return (Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        $script:CutoverReadError = "unreadable: $Path ($($_.Exception.Message))"
        return $null
    }
}

function Write-CutoverMarkerFile {
    <#
    .SYNOPSIS
        Claim the machine for a cutover. Written BEFORE the switch moves any
        surface, so a helper killed by the restart still leaves the fact behind.
    #>
    param(
        [string]$Path,
        [string]$RunId,
        [string]$Phase = 'switch',
        [string]$HostName = $env:COMPUTERNAME,
        [string]$StartedAt = ''
    )
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
    $payload = [ordered]@{
        version   = 1
        runId     = $RunId
        startedAt = $(if ($StartedAt) { $StartedAt } else { (Get-Date).ToString('o') })
        phase     = $Phase
        host      = $HostName
    }
    Set-Content -LiteralPath $Path -Value ($payload | ConvertTo-Json -Depth 4) -Encoding utf8NoBOM
    return $payload
}

function Remove-CutoverMarkerFile {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        return $true
    }
    return $false
}

function Get-CutoverDefaultLeaseRoot {
    if (-not [string]::IsNullOrWhiteSpace($env:OC_WORKTREE_LEASE_ROOT)) { return $env:OC_WORKTREE_LEASE_ROOT }
    if (-not [string]::IsNullOrWhiteSpace($env:MACHINE_STATE_HOME)) {
        return (Join-Path $env:MACHINE_STATE_HOME 'worktree-leases')
    }
    return (Join-Path $env:USERPROFILE '.machine\state\worktree-leases')
}

function Get-CutoverDefaultHubRoot {
    return (Join-Path $env:USERPROFILE '.machine\state\hubs')
}

function Test-CutoverProcessAlive {
    param([int]$ProcessId)
    if ($ProcessId -le 0) { return $false }
    return ($null -ne (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue))
}

function Write-CutoverAuditLine {
    param([string]$Path, $Entry)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
    Add-Content -LiteralPath $Path -Value ($Entry | ConvertTo-Json -Compress) -Encoding utf8NoBOM
}

function Get-CutoverAuditRows {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) { return @() }
    $rows = @()
    foreach ($line in @(Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue)) {
        if (-not $line.Trim()) { continue }
        try { $rows += ($line | ConvertFrom-Json) } catch { }
    }
    return $rows
}

function Get-CutoverRepoIdentity {
    <#
    .SYNOPSIS
        The repo a checkout belongs to: the leaf of the MAIN checkout, so a lane
        worktree resolves to its repo. Falls back to the folder leaf.
    #>
    param([string]$Path)
    $leaf = if ([string]::IsNullOrWhiteSpace($Path)) { '' } else { Split-Path -Leaf ($Path.TrimEnd('\', '/')) }
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{ Name = $leaf; MainRoot = ''; IsWorktree = $false }
    }
    try {
        $top = (& git -C $Path rev-parse --show-toplevel 2>$null)
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($top)) {
            return [pscustomobject]@{ Name = $leaf; MainRoot = ''; IsWorktree = $false }
        }
        $top = ([string]$top).Trim()
        $common = (& git -C $Path rev-parse --git-common-dir 2>$null)
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($common)) {
            return [pscustomobject]@{ Name = (Split-Path -Leaf $top); MainRoot = $top; IsWorktree = $false }
        }
        $common = ([string]$common).Trim()
        if (-not [System.IO.Path]::IsPathRooted($common)) { $common = Join-Path $top $common }
        $common = [System.IO.Path]::GetFullPath($common)
        $mainRoot = Split-Path -Parent $common
        if ([string]::IsNullOrWhiteSpace($mainRoot)) { $mainRoot = $top }
        $mainRoot = ([System.IO.Path]::GetFullPath($mainRoot)).TrimEnd('\', '/')
        $top = ([System.IO.Path]::GetFullPath($top)).TrimEnd('\', '/')
        return [pscustomobject]@{
            Name       = (Split-Path -Leaf $mainRoot)
            MainRoot   = $mainRoot
            IsWorktree = ($top -ne $mainRoot)
        }
    } catch {
        return [pscustomobject]@{ Name = $leaf; MainRoot = ''; IsWorktree = $false }
    }
}

function Get-CutoverGitFacts {
    <#
    .SYNOPSIS
        Branch, short HEAD and dirty state for one checkout. Never throws.
    #>
    param([string]$Path)
    $facts = [ordered]@{ repo = (Get-CutoverRepoIdentity -Path $Path).Name; branch = ''; head = ''; uncommitted = $false }
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) { return [pscustomobject]$facts }
    try {
        $branch = (& git -C $Path rev-parse --abbrev-ref HEAD 2>$null)
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($branch)) { $facts.branch = ([string]$branch).Trim() }
        $head = (& git -C $Path rev-parse --short HEAD 2>$null)
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($head)) { $facts.head = ([string]$head).Trim() }
        $status = (& git -C $Path status --porcelain 2>$null)
        $facts.uncommitted = ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace([string]$status))
    } catch { }
    return [pscustomobject]$facts
}

function Get-CutoverWindowInfo {
    <#
    .SYNOPSIS
        The time window the cutover occupied, from the most specific evidence
        available: the kill window, then the in-progress marker, then the
        durable last-cutover marker, then the roster's capture stamp.
    .DESCRIPTION
        A window belongs to one runId. Evidence naming a different run is not
        this run's window (two cutovers in minutes must not stack), so it is
        skipped rather than merged.
    #>
    param(
        [string]$StateDir,
        [string]$RunId,
        [string]$RosterPath = '',
        [string]$KillWindowPath = '',
        [string]$MarkerPath = '',
        [datetime]$Now = (Get-Date)
    )
    if ([string]::IsNullOrWhiteSpace($KillWindowPath)) { $KillWindowPath = Get-CutoverKillWindowPath -StateDir $StateDir }
    if ([string]::IsNullOrWhiteSpace($MarkerPath)) { $MarkerPath = Get-CutoverMarkerPath -StateDir $StateDir }
    $result = [pscustomobject]@{
        RunId        = $RunId
        StartedAt    = $null
        EndedAt      = $null
        Source       = 'unknown'
        HasKillWindow = $false
    }

    $kill = Read-CutoverJsonFile -Path $KillWindowPath
    if ($null -ne $kill -and $kill.PSObject.Properties['runId'] -and [string]$kill.runId -eq $RunId) {
        $result.HasKillWindow = $true
        $result.Source = 'kill-window'
        $result.StartedAt = [datetime]::Parse([string]$kill.startedAt, [Globalization.CultureInfo]::InvariantCulture)
        if ($kill.PSObject.Properties['endedAt'] -and -not [string]::IsNullOrWhiteSpace([string]$kill.endedAt)) {
            try { $result.EndedAt = [datetime]::Parse([string]$kill.endedAt, [Globalization.CultureInfo]::InvariantCulture) } catch { }
        }
        if ($null -eq $result.EndedAt) { $result.EndedAt = $Now }
        return $result
    }

    $marker = Read-CutoverJsonFile -Path $MarkerPath
    if ($null -ne $marker -and $marker.PSObject.Properties['startedAt'] -and
        (-not $marker.PSObject.Properties['runId'] -or [string]$marker.runId -eq $RunId)) {
        $result.Source = 'in-progress-marker'
        $result.StartedAt = [datetime]::Parse([string]$marker.startedAt, [Globalization.CultureInfo]::InvariantCulture)
        $result.EndedAt = $Now
        return $result
    }

    $last = Read-CutoverJsonFile -Path (Get-CutoverLastMarkerPath -StateDir $StateDir)
    if ($null -ne $last -and $last.PSObject.Properties['at'] -and
        (-not $last.PSObject.Properties['runId'] -or [string]$last.runId -eq $RunId)) {
        $result.Source = 'last-cutover'
        $result.StartedAt = [datetime]::Parse([string]$last.at, [Globalization.CultureInfo]::InvariantCulture)
        $result.EndedAt = $Now
        return $result
    }

    $roster = Read-CutoverJsonFile -Path $RosterPath
    if ($null -ne $roster -and $roster.PSObject.Properties['capturedAt'] -and -not [string]::IsNullOrWhiteSpace([string]$roster.capturedAt)) {
        $result.Source = 'roster'
        $result.StartedAt = [datetime]::Parse([string]$roster.capturedAt, [Globalization.CultureInfo]::InvariantCulture)
        $result.EndedAt = $Now
        return $result
    }

    return $result
}

function Test-CutoverInWindow {
    <#
    .SYNOPSIS
        True when a recorded instant falls inside [start, end]. A window with no
        start is never a match (an unknown window is not a licence to act).
    #>
    param($Stamp, $Window)
    if ($null -eq $Window -or $null -eq $Window.StartedAt) { return $false }
    if ([string]::IsNullOrWhiteSpace([string]$Stamp)) { return $false }
    $value = $null
    try {
        if ($Stamp -is [datetimeoffset]) { $value = $Stamp.LocalDateTime }
        elseif ($Stamp -is [datetime]) { $value = $Stamp }
        else { $value = [datetime]::Parse([string]$Stamp, [Globalization.CultureInfo]::InvariantCulture) }
    } catch { return $false }
    $start = [datetime]$Window.StartedAt
    $end = if ($null -ne $Window.EndedAt) { [datetime]$Window.EndedAt } else { Get-Date }
    return ($value -ge $start -and $value -le $end)
}
