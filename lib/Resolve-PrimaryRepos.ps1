#Requires -Version 7.0
<#
.SYNOPSIS
    Resolve the machine's PRIMARY repos, or say clearly that the registry is absent.

.DESCRIPTION
    Which checkouts are primary is a property of THIS machine's fleet shape - not
    of the plugin, the monitor, or any other consumer. A primary repo is a product
    repo whose beads graph and merge progress are worth supervising: it has a live
    roadmap, lanes land into it, and a stall there is a real stall. Container and
    infrastructure repos (cl-common and friends) are not primary.

    The registry lives in machine state, never in a repo and never in a tool:

        ~/.machine/state/primary-repos.json
        { "version": 1,
          "repos": [ { "name": "...", "path": "...", "trunk": "dev" } ] }

    Consumers MUST read this instead of hardcoding names. When the registry is
    absent or empty, the correct behaviour is a NAMED absence - never a guessed
    default list, because a guessed list silently supervises the wrong repos.

    Resolution order for the registry file itself:
      1. $env:PRIMARY_REPOS_FILE                 explicit override (tests, other machines)
      2. $env:MACHINE_STATE_HOME\primary-repos.json
      3. ~/.machine/state/primary-repos.json

.EXAMPLE
    $r = Resolve-PrimaryRepos
    if ($r.Available) { $r.Repos | ForEach-Object { $_.name } } else { Write-Warning $r.Reason }

.OUTPUTS
    [pscustomobject] Path, Source, Available, Repos, Reason
#>
[CmdletBinding()]
param()

function Get-RegistryCandidate {
    if (-not [string]::IsNullOrWhiteSpace($env:PRIMARY_REPOS_FILE)) {
        return [pscustomobject]@{ Path = $env:PRIMARY_REPOS_FILE; Source = 'PRIMARY_REPOS_FILE' }
    }
    if (-not [string]::IsNullOrWhiteSpace($env:MACHINE_STATE_HOME)) {
        return [pscustomobject]@{ Path = (Join-Path $env:MACHINE_STATE_HOME 'primary-repos.json'); Source = 'MACHINE_STATE_HOME' }
    }
    return [pscustomobject]@{ Path = (Join-Path (Join-Path $HOME '.machine') 'state/primary-repos.json'); Source = '~/.machine/state' }
}

$candidate = Get-RegistryCandidate

if (-not (Test-Path -LiteralPath $candidate.Path -PathType Leaf)) {
    return [pscustomobject]@{
        Path      = $candidate.Path
        Source    = $candidate.Source
        Available = $false
        Repos     = @()
        Reason    = "no primary-repo registry at $($candidate.Path) ($($candidate.Source)); which repos are primary is this machine's fleet shape and must be recorded, not guessed"
    }
}

try {
    $registry = Get-Content -LiteralPath $candidate.Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
}
catch {
    return [pscustomobject]@{
        Path      = $candidate.Path
        Source    = $candidate.Source
        Available = $false
        Repos     = @()
        Reason    = "the primary-repo registry at $($candidate.Path) is unreadable or malformed: $($_.Exception.Message)"
    }
}

$repos = @($registry.repos | Where-Object { $_ -and $_.name } | ForEach-Object {
        [pscustomobject]@{
            name  = [string]$_.name
            path  = [string]$_.path
            trunk = if ($_.trunk) { [string]$_.trunk } else { 'dev' }
            exists = if ($_.path) { Test-Path -LiteralPath $_.path -PathType Container } else { $false }
        }
    })

if ($repos.Count -eq 0) {
    return [pscustomobject]@{
        Path      = $candidate.Path
        Source    = $candidate.Source
        Available = $false
        Repos     = @()
        Reason    = "the primary-repo registry at $($candidate.Path) lists no repos; record at least one, or the monitor has nothing to supervise"
    }
}

return [pscustomobject]@{
    Path      = $candidate.Path
    Source    = $candidate.Source
    Available = $true
    Repos     = $repos
    Reason    = $null
}
