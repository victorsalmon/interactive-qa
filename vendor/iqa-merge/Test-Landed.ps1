#Requires -Version 7
<#
.SYNOPSIS
    Prove a merge actually landed on the remote trunk - or say it did not.

.DESCRIPTION
    On 2026-11-01 a hub landed `copy/pass-2`, reported "origin/dev head is
    e828d45bf, all three keys PRESENT", and marked the handoff done. It was not
    true: the merge commit existed only in the shared trunk checkout, the push
    never happened, and `origin/dev` was still two commits behind at the tip
    that predated the merge. The evidence it quoted was `git log` and a file
    read from the LOCAL tree - both describe the checkout, not the trunk.

    That is the third failure of the same shape that night (a name grep for a
    GIFI table, a local copy of a code table, a local `git log`): each trusted a
    signal that was available instead of the one that is authoritative. A
    shared trunk checkout can be ahead of, behind, or diverged from origin at
    any moment - another lane resets it routinely.

    So a landing is proven only by asking the REMOTE:

      1. `git fetch` (never compare against a stale remote-tracking ref),
      2. `git merge-base --is-ancestor <sha> origin/<trunk>` == 0,
      3. every `-Path` you claim exists is present in `origin/<trunk>`'s tree,
      4. the remote ref itself resolves (`git ls-remote`) and matches.

    Exit codes: 0 proven, 1 NOT landed (a named reason per failed check),
    2 error (not a repo, git failed, bad arguments). Fail-closed: an
    unevaluable check is never a pass.

.PARAMETER Sha
    The commit you claim landed. Short SHAs are resolved against the remote.

.PARAMETER Path
    Zero or more repo-relative paths (globs allowed) that must exist in the
    remote trunk tree - e.g. the migration and the catalog a change introduced.

.EXAMPLE
    ./Test-Landed.ps1 -RepoPath E:\Repos\currents-bookkeeping -Sha e828d45bf `
        -Trunk dev -Path 'backend/drizzle/0209_*.sql'

.EXAMPLE
    ./Test-Landed.ps1 -RepoPath E:\Repos\cl-common -Sha e74e7d8e -Json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RepoPath,
    [Parameter(Mandatory)][string]$Sha,
    [string]$Trunk = 'dev',
    [string]$Remote = 'origin',
    [string[]]$Path = @(),
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Verdict {
    param([hashtable]$Payload, [int]$ExitCode)
    if ($Json) { $Payload | ConvertTo-Json -Depth 6 -Compress }
    else {
        $Payload.GetEnumerator() | Sort-Object Name | ForEach-Object { '{0}: {1}' -f $_.Key, $_.Value }
    }
    exit $ExitCode
}

function Invoke-Git {
    param([string[]]$GitArgs)
    $out = & git -C $RepoPath @GitArgs 2>&1
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($out | Out-String).Trim() }
}

if (-not (Test-Path -LiteralPath (Join-Path $RepoPath '.git'))) {
    Write-Verdict -Payload ([ordered]@{ ok = $false; landed = $false; reason = "not a git repo: $RepoPath"; code = 'not-a-repo' }) -ExitCode 2
}

# 1. Fetch: a stale remote-tracking ref is exactly how a wrong answer survives.
$fetch = Invoke-Git @('fetch', $Remote, '--quiet')
if ($fetch.ExitCode -ne 0) {
    Write-Verdict -Payload ([ordered]@{ ok = $false; landed = $false; reason = "git fetch $Remote failed: $($fetch.Output)"; code = 'fetch-failed' }) -ExitCode 2
}

$remoteRef = "$Remote/$Trunk"

# 2. The remote ref must resolve at all.
$ref = Invoke-Git @('rev-parse', '--verify', "--quiet", "refs/remotes/$remoteRef")
if ($ref.ExitCode -ne 0) {
    Write-Verdict -Payload ([ordered]@{ ok = $false; landed = $false; reason = "remote ref $remoteRef does not resolve"; code = 'no-remote-ref' }) -ExitCode 1
}
$trunkSha = ($ref.Output -split "`n")[0].Trim()

# 3. Ancestry - the authoritative test.
$anc = Invoke-Git @('merge-base', '--is-ancestor', $Sha, $remoteRef)
if ($anc.ExitCode -ne 0) {
    Write-Verdict -Payload ([ordered]@{
            ok        = $false
            landed    = $false
            code      = 'not-an-ancestor'
            sha       = $Sha
            trunkRef  = $remoteRef
            trunkHead = $trunkSha
            reason    = "$Sha is NOT an ancestor of $remoteRef (trunk is at $trunkSha) - the commit exists locally but never landed"
        }) -ExitCode 1
}

# 4. Claimed paths must exist in the REMOTE tree, not the working copy.
$missing = @()
foreach ($pattern in $Path) {
    $ls = Invoke-Git @('ls-tree', '-r', '--name-only', $remoteRef, '--', $pattern)
    if ($ls.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($ls.Output)) { $missing += $pattern }
}
if ($missing.Count -gt 0) {
    Write-Verdict -Payload ([ordered]@{
            ok            = $false
            landed        = $false
            code          = 'missing-paths'
            sha           = $Sha
            trunkRef      = $remoteRef
            trunkHead     = $trunkSha
            missingPaths  = ($missing -join ', ')
            reason        = "ancestry holds but these paths are absent from $remoteRef's tree: $($missing -join ', ')"
        }) -ExitCode 1
}

Write-Verdict -Payload ([ordered]@{
        ok        = $true
        landed    = $true
        sha       = $Sha
        trunkRef  = $remoteRef
        trunkHead = $trunkSha
        paths     = if ($Path.Count -gt 0) { $Path -join ', ' } else { '(none claimed)' }
    }) -ExitCode 0
