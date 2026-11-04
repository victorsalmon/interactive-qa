#Requires -Version 7
<#
.SYNOPSIS
    Close a lane: archive its Paseo workspace, which archives the agents it owns.

.DESCRIPTION
    A merged branch leaves three things behind: the branch, its worktree, and the
    Paseo workspace bound to that path. Removing the worktree does not remove the
    workspace, so agents accumulate in the sidebar forever - measured 2026-11-04:
    19 workspaces and 12 agents idle beyond the capacity grace window.

    `paseo workspace archive <id>` archives the workspace "and everything it owns",
    which is exactly the close-out we want. It is also destructive to anything
    still running in that path, so this tool is a two-step:

      plan (default)   report what would be archived, change nothing
      -Apply           archive it

    and it refuses when a live agent still has its cwd under the workspace path.
    Archived agents are excluded from `paseo agent ls`, so "listed" means "live".

.PARAMETER Path
    The worktree path the workspace is bound to (the workspace's `cwd`).

.PARAMETER WorkspaceId
    Archive an explicit workspace id instead of resolving by path.

.PARAMETER Apply
    Actually archive. Without it this tool only reports.

.PARAMETER PaseoCommand
    The paseo CLI to use. Defaults to PATH, then the desktop app bundle.

.EXAMPLE
    pwsh -File tools/Close-IqaWorkspace.ps1 -Path E:\Repos\cl-common\.worktrees\lane-x

.EXAMPLE
    pwsh -File tools/Close-IqaWorkspace.ps1 -Path <worktree> -Apply

.OUTPUTS
    Human lines. EXIT 0 plan/archived, 1 archive failed, 2 usage or cannot-evaluate
    (no workspace for that path, or the CLI is missing), 3 refused (live agents).
#>
[CmdletBinding()]
param(
    [string]$Path,
    [string]$WorkspaceId,
    [switch]$Apply,
    [string]$PaseoCommand
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-PaseoCli {
    if ($PaseoCommand) { return $PaseoCommand }
    $command = Get-Command paseo -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    $bundled = Join-Path $env:ProgramFiles 'Paseo/resources/bin/paseo.cmd'
    if (Test-Path -LiteralPath $bundled) { return $bundled }
    Write-Output 'CANNOT-EVALUATE: the paseo CLI was not found on PATH or in the app bundle.'
    exit 2
}

function Get-Json {
    param([string]$Paseo, [string[]]$Arguments)
    $raw = & $Paseo @Arguments 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        Write-Output "CANNOT-EVALUATE: 'paseo $($Arguments -join ' ')' exited $LASTEXITCODE. $($raw.Trim())"
        exit 2
    }
    return @($raw | ConvertFrom-Json)
}

function Normalize-Path {
    param([string]$Value)
    if (-not $Value) { return '' }
    return ($Value.TrimEnd('\', '/') -replace '/', '\').ToLowerInvariant()
}

$paseo = Resolve-PaseoCli
$workspaces = Get-Json -Paseo $paseo -Arguments @('workspace', 'ls', '--json')

$target = $null
if ($WorkspaceId) {
    $target = @($workspaces | Where-Object { $_.workspaceId -eq $WorkspaceId }) | Select-Object -First 1
    if (-not $target) {
        Write-Output "CANNOT-EVALUATE: no workspace with id '$WorkspaceId'."
        exit 2
    }
}
elseif ($Path) {
    $want = Normalize-Path $Path
    $target = @($workspaces | Where-Object { (Normalize-Path $_.cwd) -eq $want }) | Select-Object -First 1
    if (-not $target) {
        Write-Output "CANNOT-EVALUATE: no workspace is bound to '$Path'. Nothing to archive."
        exit 2
    }
}
else {
    Write-Output 'Usage: Close-IqaWorkspace.ps1 (-Path <worktree> | -WorkspaceId <wks_id>) [-Apply]'
    exit 2
}

$agents = Get-Json -Paseo $paseo -Arguments @('agent', 'ls', '--json')
$bound = Normalize-Path $target.cwd
$live = @($agents | Where-Object {
        $cwd = Normalize-Path $_.cwd
        $cwd -and ($cwd -eq $bound -or $cwd.StartsWith($bound + '\'))
    })

Write-Output ("workspace {0}  cwd={1}  project={2}  name={3}" -f $target.workspaceId, $target.cwd, $target.project, $target.name)
Write-Output ("live agents bound to it: {0}" -f $live.Count)

if ($live.Count -gt 0) {
    foreach ($agent in $live) { Write-Output ("  BLOCKS  {0}  {1}  status={2}" -f $agent.shortId, $agent.name, $agent.status) }
    Write-Output ''
    Write-Output 'REFUSED: archiving this workspace would archive agents that are still live. Finish or archive them first.'
    exit 3
}

if (-not $Apply) {
    Write-Output ''
    Write-Output 'PLAN: this workspace has no live agents and would be archived. Re-run with -Apply to do it.'
    exit 0
}

$out = & $paseo workspace archive $target.workspaceId 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) {
    Write-Output ("FAILED: 'paseo workspace archive {0}' exited {1}. {2}" -f $target.workspaceId, $LASTEXITCODE, $out.Trim())
    exit 1
}
Write-Output ''
Write-Output ("ARCHIVED: {0} ({1}). Its agents are archived with it." -f $target.workspaceId, $target.cwd)
exit 0
