<#
.SYNOPSIS
    Cross-repo worktree lease: serialize writers per checkout and make dirty
    worktrees inspectable instead of blocking.

.DESCRIPTION
    Isolation rule: one writer per worktree. This helper implements the lease
    that backs that rule for every agent (Salmon Run lanes already carry their
    own lane lease; this is the worktree-level equivalent for interactive and
    out-of-band agents and for the shared-tree commit wrappers).

    A lease is a small JSON document in a central, git-ignored store:

        $env:OC_WORKTREE_LEASE_ROOT
          ?? $env:IQA_MACHINE_HOME/State/worktree-leases
          ?? ~/.salmon/State/worktree-leases

    keyed by the SHA1 of the normalized checkout path. The Salmon Run engine
    reads the same store (Modules/SalmonRun.PondEngine/Private/
    Invoke-PondOrphanedDirtRecovery.ps1) to distinguish live owners from
    orphaned dirt before it recovers a stream, so acquiring a lease is how an
    agent says "this dirty tree is mine, do not touch it".

    Lease lifecycle:
      Acquire  creates or refreshes (same owner) or takes over (expired/dead
               pid) the lease. With -WaitSec it retries with exponential
               backoff plus full jitter before reporting Contended.
      Release  removes the lease when the caller owns it (or -Force).
      Status   reports the current holder without mutating anything.

    Liveness = expiresAt in the future AND (process alive when the lease was
    written on this host; remote-host leases are trusted until expiry).

    Invoke with the call operator (& path\to\Invoke-WorktreeLease.ps1 ...) so
    the exit codes below land in $LASTEXITCODE; the script returns an object
    and exits 0 (ok), 3 (contended / not owner), or 1 (error).

.PARAMETER Mode
    Acquire, Release, or Status.

.PARAMETER Path
    Checkout to lease: a git worktree (preferred) or any directory. Absolute
    or relative; normalized before hashing.

.PARAMETER Owner
    Owner identity. Defaults to $env:OC_RESERVATION_AGENT_ID, then
    $env:OPENCODE_AGENT_ID, then "$env:USERNAME@$env:COMPUTERNAME:$PID".

.PARAMETER TaskId
    Optional task/plan identifier recorded on the lease for observability.

.PARAMETER TtlMinutes
    Lease lifetime in minutes (default 30). Re-run Acquire with the same Owner
    to refresh (heartbeat).

.PARAMETER WaitSec
    Maximum seconds Acquire waits for a contended lease before returning
    Contended (default 0 = one attempt). Retries use exponential backoff with
    full jitter.

.PARAMETER Force
    Take over an existing lease regardless of liveness (operator use), or
    release a lease owned by someone else.

.PARAMETER Json
    Emit a single JSON object instead of a PowerShell object.

.OUTPUTS
    [pscustomobject] with Mode, Acquired, Released, Held, Live, Owner,
    LeasePath, ExpiresAt, Generation, WaitedMs, Reason.

.EXAMPLE
    $lease = & $env:LEASE_SCRIPT -Mode Acquire -Path (Get-Location).Path -TaskId 'plan-42' -TtlMinutes 30 -WaitSec 60
    if (-not $lease.Acquired) { throw "worktree busy: $($lease.Owner)" }

.EXAMPLE
    & .\Invoke-WorktreeLease.ps1 -Mode Status -Path ${env:CL_REPOS_ROOT}\app -Json

.EXAMPLE
    & .\Invoke-WorktreeLease.ps1 -Mode Release -Path ${env:CL_REPOS_ROOT}\app
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Acquire', 'Release', 'Status')]
    [string]$Mode,

    [Parameter(Mandatory)]
    [string]$Path,

    [string]$Owner,

    [string]$TaskId,

    [int]$TtlMinutes = 30,

    [int]$WaitSec = 0,

    [switch]$Force,

    [switch]$Json
)

$ErrorActionPreference = 'Stop'

function Get-LeaseRoot {
    if (-not [string]::IsNullOrWhiteSpace($env:OC_WORKTREE_LEASE_ROOT)) {
        return $env:OC_WORKTREE_LEASE_ROOT
    }
    if (-not [string]::IsNullOrWhiteSpace($env:IQA_MACHINE_HOME)) {
        return (Join-Path $env:IQA_MACHINE_HOME 'State\worktree-leases')
    }
    return (Join-Path $HOME '.machine\state\worktree-leases')
}

function Get-NormalizedPath {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    try {
        return ([System.IO.Path]::GetFullPath($Value)).TrimEnd('\', '/')
    } catch {
        return $Value.Trim().TrimEnd('\', '/')
    }
}

function Get-PathHash {
    param([string]$NormalizedPath)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($NormalizedPath.ToLowerInvariant())
    $sha1 = [System.Security.Cryptography.SHA1]::Create()
    try {
        $hash = $sha1.ComputeHash($bytes)
    } finally {
        $sha1.Dispose()
    }
    return (($hash | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Get-LeaseFilePath {
    param([string]$NormalizedPath, [string]$Root)
    return (Join-Path $Root ((Get-PathHash -NormalizedPath $NormalizedPath) + '.json'))
}

function Read-LeaseFile {
    param([string]$LeasePath)
    if (-not (Test-Path -LiteralPath $LeasePath -PathType Leaf)) { return $null }
    try {
        return (Get-Content -LiteralPath $LeasePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        return $null
    }
}

function Write-LeaseFile {
    param([string]$LeasePath, [object]$Lease)
    $dir = Split-Path -Path $LeasePath -Parent
    $null = New-Item -ItemType Directory -Path $dir -Force -ErrorAction SilentlyContinue
    $tmp = "$LeasePath.tmp-$PID-$([guid]::NewGuid().ToString('n'))"
    try {
        $Lease | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $tmp -Encoding utf8 -NoNewline -ErrorAction Stop
        Move-Item -LiteralPath $tmp -Destination $LeasePath -Force -ErrorAction Stop
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

function Test-LeaseLive {
    param([object]$Lease)
    if ($null -eq $Lease) { return $false }
    $expires = $null
    try {
        if ($Lease.PSObject.Properties['expiresAt']) {
            $expires = [datetimeoffset]::Parse([string]$Lease.expiresAt, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
        }
    } catch { $expires = $null }
    if ($null -eq $expires -or $expires -le [datetimeoffset]::UtcNow) { return $false }

    # A lease written on another host cannot be PID-checked; trust its TTL.
    $leaseHost = ''
    try { if ($Lease.PSObject.Properties['host']) { $leaseHost = [string]$Lease.host } } catch { $leaseHost = '' }
    if ($leaseHost -and -not [string]::Equals($leaseHost, $env:COMPUTERNAME, [StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }

    $leasePid = 0
    try { if ($Lease.PSObject.Properties['pid']) { $leasePid = [int]$Lease.pid } } catch { $leasePid = 0 }
    if ($leasePid -le 0) { return $true }
    return ($null -ne (Get-Process -Id $leasePid -ErrorAction SilentlyContinue))
}

function New-LeaseDocument {
    param([string]$NormalizedPath, [int]$Generation)
    $now = [datetimeoffset]::UtcNow
    $repoRoot = ''
    $branch = ''
    try {
        $toplevel = & git -C $NormalizedPath rev-parse --show-toplevel 2>$null
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($toplevel)) {
            $repoRoot = (Get-NormalizedPath ([string]$toplevel))
        }
        $branchOut = & git -C $NormalizedPath rev-parse --abbrev-ref HEAD 2>$null
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($branchOut)) {
            $branch = ([string]$branchOut).Trim()
        }
    } catch { }
    return [ordered]@{
        schemaVersion = 1
        path          = $NormalizedPath
        repoRoot      = $repoRoot
        branch        = $branch
        owner         = $Owner
        agentId       = $Owner
        pid           = $PID
        host          = $env:COMPUTERNAME
        taskId        = $TaskId
        acquiredAt    = $now.ToString('o')
        heartbeatAt   = $now.ToString('o')
        expiresAt     = $now.AddMinutes($TtlMinutes).ToString('o')
        generation    = $Generation
    }
}

if ([string]::IsNullOrWhiteSpace($Owner)) {
    $Owner = $env:OC_RESERVATION_AGENT_ID
    if ([string]::IsNullOrWhiteSpace($Owner)) { $Owner = $env:OPENCODE_AGENT_ID }
    if ([string]::IsNullOrWhiteSpace($Owner)) { $Owner = "$env:USERNAME@$env:COMPUTERNAME:$PID" }
}

$normalizedPath = Get-NormalizedPath -Value $Path
$root = Get-LeaseRoot
$null = New-Item -ItemType Directory -Path $root -Force -ErrorAction SilentlyContinue
$leasePath = Get-LeaseFilePath -NormalizedPath $normalizedPath -Root $root
$sw = [System.Diagnostics.Stopwatch]::StartNew()

$result = [ordered]@{
    Mode      = $Mode
    Acquired  = $false
    Released  = $false
    Held      = $false
    Live      = $false
    Owner     = ''
    LeasePath = $leasePath
    ExpiresAt = $null
    Generation = 0
    WaitedMs  = 0
    Reason    = ''
    Lease     = $null
}

try {
    switch ($Mode) {
        'Status' {
            $lease = Read-LeaseFile -LeasePath $leasePath
            if ($null -eq $lease) {
                $result.Reason = 'no lease'
            } else {
                $live = Test-LeaseLive -Lease $lease
                $result.Held = $true
                $result.Live = $live
                $result.Owner = [string]$lease.owner
                $result.ExpiresAt = [string]$lease.expiresAt
                if ($null -ne $lease.generation) { $result.Generation = [int]$lease.generation }
                $result.Reason = if ($live) { 'held by live owner' } else { 'stale lease present' }
                $result.Lease = $lease
            }
        }

        'Release' {
            $lease = Read-LeaseFile -LeasePath $leasePath
            if ($null -eq $lease) {
                $result.Released = $true
                $result.Reason = 'no lease to release'
            } elseif ($Force -or [string]::Equals([string]$lease.owner, $Owner, [StringComparison]::OrdinalIgnoreCase)) {
                Remove-Item -LiteralPath $leasePath -Force -ErrorAction Stop
                $result.Released = $true
                $result.Owner = [string]$lease.owner
                $result.Reason = if ($Force -and -not [string]::Equals([string]$lease.owner, $Owner, [StringComparison]::OrdinalIgnoreCase)) { 'released by force' } else { 'released' }
            } else {
                $result.Owner = [string]$lease.owner
                $result.Held = $true
                $result.Live = Test-LeaseLive -Lease $lease
                $result.Reason = "lease owned by '$($lease.owner)'"
            }
        }

        'Acquire' {
            $deadline = (Get-Date).AddSeconds([Math]::Max(0, $WaitSec))
            $attempt = 0
            while ($true) {
                $lease = Read-LeaseFile -LeasePath $leasePath
                $won = $false

                if ($null -eq $lease) {
                    # No readable lease: first writer wins with an atomic create.
                    $doc = New-LeaseDocument -NormalizedPath $normalizedPath -Generation 1
                    try {
                        $jsonText = $doc | ConvertTo-Json -Depth 5
                        $null = New-Item -ItemType File -Path $leasePath -Value $jsonText -ErrorAction Stop
                        $won = $true
                        $result.Reason = 'acquired'
                    } catch [System.IO.IOException] {
                        if (Test-Path -LiteralPath $leasePath -PathType Leaf) {
                            # Unreadable/corrupt file: replace it, then verify ownership.
                            $doc = New-LeaseDocument -NormalizedPath $normalizedPath -Generation 2
                            Write-LeaseFile -LeasePath $leasePath -Lease $doc
                            $verify = Read-LeaseFile -LeasePath $leasePath
                            if ($verify -and [string]::Equals([string]$verify.owner, $Owner, [StringComparison]::OrdinalIgnoreCase)) {
                                $won = $true
                                $result.Reason = 'acquired (replaced unreadable lease)'
                            }
                        }
                    }
                } elseif (-not (Test-LeaseLive -Lease $lease)) {
                    # Expired or dead: take over with a generation bump, then verify.
                    $generation = 1
                    if ($null -ne $lease.generation) { $generation = [int]$lease.generation + 1 }
                    $doc = New-LeaseDocument -NormalizedPath $normalizedPath -Generation $generation
                    Write-LeaseFile -LeasePath $leasePath -Lease $doc
                    $verify = Read-LeaseFile -LeasePath $leasePath
                    if ($verify -and [string]::Equals([string]$verify.owner, $Owner, [StringComparison]::OrdinalIgnoreCase)) {
                        $won = $true
                        $result.Reason = 'acquired (took over stale/dead lease)'
                    }
                } elseif ([string]::Equals([string]$lease.owner, $Owner, [StringComparison]::OrdinalIgnoreCase)) {
                    # Same owner: refresh (heartbeat).
                    $generation = 1
                    if ($null -ne $lease.generation) { $generation = [int]$lease.generation }
                    $doc = New-LeaseDocument -NormalizedPath $normalizedPath -Generation $generation
                    Write-LeaseFile -LeasePath $leasePath -Lease $doc
                    $won = $true
                    $result.Reason = 'refreshed (same owner)'
                } elseif ($Force) {
                    $generation = 1
                    if ($null -ne $lease.generation) { $generation = [int]$lease.generation + 1 }
                    $doc = New-LeaseDocument -NormalizedPath $normalizedPath -Generation $generation
                    Write-LeaseFile -LeasePath $leasePath -Lease $doc
                    $won = $true
                    $result.Reason = 'acquired by force'
                } else {
                    $result.Owner = [string]$lease.owner
                    $result.Held = $true
                    $result.Live = $true
                    $result.ExpiresAt = [string]$lease.expiresAt
                    if ($null -ne $lease.generation) { $result.Generation = [int]$lease.generation }
                    $result.Reason = "held by '$($lease.owner)'"
                }

                if ($won) {
                    $result.Acquired = $true
                    $result.Owner = $Owner
                    $result.ExpiresAt = [string]$doc.expiresAt
                    if ($null -ne $doc) { $result.Generation = [int]$doc.generation }
                    $result.Lease = $doc
                }

                if ($result.Acquired -or [datetime]::Now -ge $deadline) { break }

                # Exponential backoff with full jitter, capped at 4s.
                $capMs = [int][Math]::Min(4000, 200 * [Math]::Pow(2, [Math]::Min($attempt, 5)))
                $delayMs = Get-Random -Minimum 25 -Maximum ([Math]::Max(50, $capMs))
                Start-Sleep -Milliseconds $delayMs
                $attempt++
            }
            if (-not $result.Acquired -and -not $result.Reason) {
                $result.Reason = 'contended and wait budget exhausted'
            }
        }
    }
} catch {
    $result.Reason = "error: $($_.Exception.Message)"
    $sw.Stop()
    $result.WaitedMs = [int]$sw.ElapsedMilliseconds
    $out = [pscustomobject]$result
    if ($Json) { $out | ConvertTo-Json -Depth 6 -Compress } else { $out }
    exit 1
}

$sw.Stop()
$result.WaitedMs = [int]$sw.ElapsedMilliseconds
$out = [pscustomobject]$result
if ($Json) { $out | ConvertTo-Json -Depth 6 -Compress } else { $out }

if ($Mode -eq 'Acquire') {
    if ($result.Acquired) { exit 0 }
    exit 3
}
if ($Mode -eq 'Release') {
    if ($result.Released) { exit 0 }
    exit 3
}
exit 0
