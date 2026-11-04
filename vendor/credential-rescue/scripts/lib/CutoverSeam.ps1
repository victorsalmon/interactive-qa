#Requires -Version 7.0
<#
.SYNOPSIS
    Where the cutover seam keeps CONFIG versus RUNTIME OBSERVATIONS.

.DESCRIPTION
    `assets/opencode-go-cutover.json` is committed config: schema version, pool
    order, the active key slot, concurrency caps, the canary set and the metering
    window definitions. It is also vendored into the IQA package, so it must be
    byte-stable between commits - a file that changes on a timer cannot be a
    manifest row.

    The per-key freshness ledger (`asOf`, per-key `state` / `usage` / `resetsOn` /
    `observedAt` / `evidence` / `meters`) is RUNTIME OBSERVATION: every Key Watch
    or Key Check cycle rewrites it. It lives in the profile state root beside the
    provider lock:

        $HOME/.machine/state/credential-rescue/seam-observations.json

    This is the same split the provider lock already uses (tracked fingerprints
    live in the state root, never in the package). One store, no daemon: a JSON
    file written by Set-OpencodeGoFreshness.ps1 and read by
    Get-OpencodeGoFreshness.ps1.

    Resolution order for the observations path (first wins):

      1. an explicit -ObservationsPath (tests, an operator move);
      2. beside the seam file, when the seam being used is not the canonical one
         (a test fixture stays hermetic - it never reads or writes the live
         profile, even though the config it copied declares the state path);
      3. `observationsPath` declared by the seam config itself;
      4. the profile state root above (the canonical seam).

    A machine that has never run a watch has no observations file. That is a
    cold start, not an error: readers return an empty ledger and the active key
    still resolves from the tracked config.
#>

function Expand-CutoverSeamPath {
    <#
    .SYNOPSIS
        Expand `~` / `~/...` in a seam-declared path. Never resolves a value.
    #>
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }
    if ($Path -eq '~') { return $HOME }
    if ($Path.StartsWith('~/') -or $Path.StartsWith('~\')) {
        return (Join-Path $HOME $Path.Substring(2))
    }
    return $Path
}

function Resolve-CutoverSeamPath {
    <#
    .SYNOPSIS
        The canonical seam path, or the one the caller named (absolute).
    #>
    param([string]$SeamPath)

    $path = if ([string]::IsNullOrWhiteSpace($SeamPath)) {
        Join-Path $PSScriptRoot '..\..\assets\opencode-go-cutover.json'
    } else {
        Expand-CutoverSeamPath $SeamPath
    }
    return [System.IO.Path]::GetFullPath($path)
}

function Get-CutoverObservationsPath {
    <#
    .SYNOPSIS
        Resolve the runtime-observations file for a seam.
    .DESCRIPTION
        See the module help. `-Seam` is optional; when supplied, its declared
        `observationsPath` is honoured for the canonical seam as well, so the
        location is config, not hardcoded in every consumer.
    #>
    param(
        [string]$SeamPath,
        [string]$ObservationsPath,
        $Seam
    )

    if (-not [string]::IsNullOrWhiteSpace($ObservationsPath)) {
        return [System.IO.Path]::GetFullPath((Expand-CutoverSeamPath $ObservationsPath))
    }

    $seamFull = Resolve-CutoverSeamPath $SeamPath
    $defaultSeam = Resolve-CutoverSeamPath ''
    if ($seamFull -ne $defaultSeam) {
        # A fixture/test seam keeps its observations beside itself, so a suite
        # can never read or write the live profile state - even though the seam
        # config it copied still declares the canonical observationsPath.
        return (Join-Path (Split-Path -Parent $seamFull) 'seam-observations.json')
    }

    if ($Seam -and $Seam.PSObject.Properties['observationsPath'] -and
        -not [string]::IsNullOrWhiteSpace([string]$Seam.observationsPath)) {
        return [System.IO.Path]::GetFullPath((Expand-CutoverSeamPath ([string]$Seam.observationsPath)))
    }

    return (Join-Path (Join-Path $HOME '.machine\state\credential-rescue') 'seam-observations.json')
}

function Read-CutoverObservations {
    <#
    .SYNOPSIS
        Read the observations file, or $null when it does not exist yet.
    #>
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json)
}

function Get-CutoverLedger {
    <#
    .SYNOPSIS
        The merged, read-only view every consumer needs.
    .DESCRIPTION
        `windows`/`$comment` come from the tracked config, `asOf`/`keys` from the
        runtime observations. A machine with no observations file falls back to a
        legacy seam that still embeds `freshness.keys` (read-only), then to an
        empty ledger - never an error, so a fresh checkout can start a watch.
    #>
    param(
        [Parameter(Mandatory)]$Seam,
        [Parameter(Mandatory)][string]$ObservationsPath
    )

    $observations = Read-CutoverObservations -Path $ObservationsPath
    $configLedger = $Seam.freshness

    $keys = $null
    $asOf = $null
    $source = 'none'

    if ($observations -and $observations.PSObject.Properties['keys'] -and $observations.keys) {
        $keys = $observations.keys
        $asOf = $observations.asOf
        $source = 'observations'
    } elseif ($configLedger -and $configLedger.PSObject.Properties['keys'] -and $configLedger.keys) {
        # Legacy seam written before the split: read-only fallback so an install
        # that predates the state file keeps answering until its next write.
        $keys = $configLedger.keys
        $asOf = $configLedger.asOf
        $source = 'legacy-embedded'
    }

    if (-not $keys) {
        $keys = [pscustomobject]@{}
        $source = 'none'
    }

    return [pscustomobject]@{
        asOf             = $asOf
        windows          = if ($configLedger) { $configLedger.windows } else { $null }
        keys             = $keys
        source           = $source
        observationsPath = $ObservationsPath
    }
}

function Write-CutoverObservations {
    <#
    .SYNOPSIS
        Write the observations file (creating its directory), one trailing newline.
    #>
    param(
        [Parameter(Mandatory)]$Observations,
        [Parameter(Mandatory)][string]$Path
    )

    $json = $Observations | ConvertTo-Json -Depth 12
    # validate before writing
    $null = $json | ConvertFrom-Json

    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $content = $json.TrimEnd() + "`n"
    [System.IO.File]::WriteAllText($Path, $content, (New-Object System.Text.UTF8Encoding($false)))
}
