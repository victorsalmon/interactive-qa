#Requires -Version 7.0
<#
.SYNOPSIS
    Resolve the cl-common checkout, or say clearly that it is not installed.

.DESCRIPTION
    cl-common owns the fleet-wide machine skills (machine-state, work-now,
    work-unattended) and tools that the IQA plugin *integrates with* rather than
    bundles. Bundling them here would fork them; assuming they exist would make
    the plugin fail on a machine that only installed the plugin.

    Resolution order (first hit wins):
      1. $env:CL_COMMON_HOME            the machine's cl-common install location
      2. $env:CL_COMMON_PATH            legacy alias, still honoured
      3. $env:CL_REPOS_ROOT\cl-common   the fleet's conventional layout
      4. nothing                        -> Available = $false, never an exception

    CL_COMMON_HOME is the name the machine sets when cl-common is installed as a
    first-class dependency (it is a User environment variable on this fleet).
    CL_COMMON_PATH predates it and stays supported so an existing machine or a
    pinned worker environment does not break; a machine that sets both gets the
    same answer, and CL_COMMON_HOME wins if they ever disagree.

    Callers MUST branch on `Available` and degrade with a named reason (for
    example "cl-common not installed: machine-state/work-now unavailable")
    instead of crashing or silently doing nothing.

.EXAMPLE
    $common = Resolve-ClCommon
    if ($common.Available) { & (Join-Path $common.Path 'Skills/work-now/SKILL.md') }
    else { Write-Warning $common.Reason }

.OUTPUTS
    [pscustomobject] Path, Source, Available, Reason
#>
[CmdletBinding()]
param()

$candidates = [System.Collections.Generic.List[object]]::new()

if (-not [string]::IsNullOrWhiteSpace($env:CL_COMMON_HOME)) {
    $candidates.Add([pscustomobject]@{ Path = $env:CL_COMMON_HOME; Source = 'CL_COMMON_HOME' })
}
if (-not [string]::IsNullOrWhiteSpace($env:CL_COMMON_PATH)) {
    $candidates.Add([pscustomobject]@{ Path = $env:CL_COMMON_PATH; Source = 'CL_COMMON_PATH' })
}
if (-not [string]::IsNullOrWhiteSpace($env:CL_REPOS_ROOT)) {
    $candidates.Add([pscustomobject]@{ Path = (Join-Path $env:CL_REPOS_ROOT 'cl-common'); Source = 'CL_REPOS_ROOT' })
}

foreach ($candidate in $candidates) {
    try {
        $resolved = (Resolve-Path -LiteralPath $candidate.Path -ErrorAction Stop).Path
    }
    catch {
        continue
    }
    # A cl-common checkout is identifiable by its Skills root; a bare directory
    # with that name is not the thing we want and must not be reported as found.
    if (Test-Path -LiteralPath (Join-Path $resolved 'Skills') -PathType Container) {
        return [pscustomobject]@{
            Path      = $resolved
            Source    = $candidate.Source
            Available = $true
            Reason    = $null
        }
    }
}

$tried = if ($candidates.Count -gt 0) {
    ($candidates | ForEach-Object { "$($_.Source)=$($_.Path)" }) -join '; '
}
else { 'none of CL_COMMON_HOME, CL_COMMON_PATH or CL_REPOS_ROOT is set' }

return [pscustomobject]@{
    Path      = $null
    Source    = $null
    Available = $false
    Reason    = "cl-common not installed (tried: $tried). Fleet-wide machine skills - machine-state, work-now, work-unattended - are unavailable; plugin-local behaviour is unaffected."
}
