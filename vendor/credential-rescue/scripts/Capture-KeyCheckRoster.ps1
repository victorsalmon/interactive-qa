#Requires -Version 7.0
<#
.SYNOPSIS
    Snapshot the live Paseo agents before a key cutover, so whichever process
    survives can nudge them back to work.

.DESCRIPTION
    The Paseo repair runs `paseo restart`, which ends every Paseo-hosted
    session - agents, and Hubs, that were mid-turn. Nothing on the machine
    records who they were, so after a restart a stranded lane looks exactly
    like a lane nobody ever started.

    This script is that record. It writes one JSON roster per run:

        <StateDir>\<runId>-roster.json

    with, per live agent, `id`, `shortId`, `title`, `cwd`, `cwdIsRepoRoot`,
    `status`, `created`, `sessionId` (when the daemon exposes it),
    `lastActivityAt`, `labels`, `isHub`, and `hasDoneFile` (completion evidence
    that plausibly belongs to THIS agent, so the lane already finished and must
    not be nudged). The header carries `capturedAt`, `runId`, `from`, `to`
    (GO<n> labels only) and `source` (where the list came from).

    A cwd holding `.git` is a repository ROOT (a shared trunk), never one
    agent's checkout: merge workers' `.iqa-report.md` and `.iqa-done-merge-*`
    files accumulate there, and reading them as the occupant's own completion
    evidence skipped the `cl-common` Hub during the 2026-11-03 rescue. A repo
    root is therefore never evidence. Outside one, an `.iqa-done-*.json` counts
    only when its name carries this agent's id/short id or a bead id from its
    title/labels - or when the agent is `closed` and the file is newer than the
    agent was created. `.iqa-report.md` is the lane's own brief-mandated report.

    A roster entry counts as a Hub when its labels carry a `hub-*` key or
    `iqa-role=merge`: a Hub is not recovered by restarting it, it is recovered
    by telling it to enumerate and resume its own children.

    SECURITY: no key value is ever read, compared, or written here. The only
    key-shaped facts are the GO<n> labels for `from` / `to`.

.PARAMETER RunId
    The Key Check run this roster belongs to. Required.

.PARAMETER FromKeyNumber
    The key being left (written as GO<n>; omitted when 0).

.PARAMETER ToKeyNumber
    The key being activated (written as GO<n>; omitted when 0).

.PARAMETER OutPath
    Default `<StateDir>\<runId>-roster.json`.

.PARAMETER StateDir
    Default `~/.salmon/State/key-check`. Test seam.

.PARAMETER AgentListFile
    Test seam: a JSON array in `paseo ls --json` shape instead of the live
    daemon. Never combined with a live read.

.PARAMETER AgentsDir
    Where the daemon keeps per-agent state (`<id>.json` per workspace folder).
    Default `~/.paseo/agents`. Test seam.

.PARAMETER PaseoCommand
    Explicit Paseo CLI path. Default: resolve `paseo` / the install path.

.PARAMETER SelfAgentId
    The agent running this capture (excluded). Default `$env:PASEO_AGENT_ID`.

.PARAMETER Json
    Emit the roster on stdout instead of a one-line summary.

.OUTPUTS
    Exit 0 roster written - 1 the agent list could not be read (the caller logs
    `roster-capture-failed`; a cutover is never failed by a roster failure).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$RunId,
    [ValidateRange(0, 9)]
    [int]$FromKeyNumber = 0,
    [ValidateRange(0, 9)]
    [int]$ToKeyNumber = 0,
    [string]$OutPath = '',
    [switch]$Json,
    [string]$StateDir = '',
    [string]$AgentListFile = '',
    [string]$AgentsDir = '',
    [string]$PaseoCommand = '',
    [string]$SelfAgentId = ''
)

$ErrorActionPreference = 'Stop'

$scriptRoot = $PSScriptRoot
. (Join-Path $scriptRoot 'lib\PaseoCommon.ps1')

if ([string]::IsNullOrWhiteSpace($StateDir)) { $StateDir = Join-Path $env:USERPROFILE '.salmon\State\key-check' }
if ([string]::IsNullOrWhiteSpace($OutPath)) { $OutPath = Join-Path $StateDir "$RunId-roster.json" }
if ([string]::IsNullOrWhiteSpace($AgentsDir)) { $AgentsDir = Join-Path $env:USERPROFILE '.paseo\agents' }
if ([string]::IsNullOrWhiteSpace($SelfAgentId)) { $SelfAgentId = [string]$env:PASEO_AGENT_ID }

function Get-RosterAgentRows {
    <#
    .SYNOPSIS
        The live agent list, or the fixture standing in for it.
    #>
    if ($AgentListFile) {
        if (-not (Test-Path -LiteralPath $AgentListFile)) { throw "agent list fixture not found: $AgentListFile" }
        $parsed = Get-Content -LiteralPath $AgentListFile -Raw | ConvertFrom-Json
        return [pscustomobject]@{ Source = "fixture:$AgentListFile"; Rows = @($parsed) }
    }
    $cli = if ($PaseoCommand) { $PaseoCommand } else { Resolve-PaseoCli }
    if ([string]::IsNullOrWhiteSpace($cli)) { throw 'paseo CLI not found' }
    $raw = & $cli ls --json --background 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($raw)) { throw "paseo ls failed (exit $LASTEXITCODE)" }
    try { $parsed = $raw | ConvertFrom-Json } catch { throw "paseo ls output unparsable: $($_.Exception.Message)" }
    return [pscustomobject]@{ Source = 'paseo-ls'; Rows = @($parsed) }
}

function Get-RosterAgentState {
    <#
    .SYNOPSIS
        The daemon's per-agent state file (`<AgentsDir>\<workspace>\<id>.json`),
        which is where labels, lastActivityAt and the provider session id live.
        Returns $null when the daemon has not written one.
    #>
    param([string]$AgentId)
    if ([string]::IsNullOrWhiteSpace($AgentId) -or -not (Test-Path -LiteralPath $AgentsDir)) { return $null }
    foreach ($folder in @(Get-ChildItem -LiteralPath $AgentsDir -Directory -ErrorAction SilentlyContinue)) {
        $candidate = Join-Path $folder.FullName "$AgentId.json"
        if (Test-Path -LiteralPath $candidate) {
            try { return (Get-Content -LiteralPath $candidate -Raw | ConvertFrom-Json) } catch { return $null }
        }
    }
    return $null
}

function Get-RosterLabels {
    <#
    .SYNOPSIS
        Labels as a plain ordered map. Never includes anything but label
        key/value text the operator or dispatcher set.
    #>
    param($State)
    $bag = [ordered]@{}
    if ($null -eq $State -or $null -eq $State.PSObject.Properties['labels']) { return $bag }
    foreach ($p in $State.labels.PSObject.Properties) { $bag[$p.Name] = [string]$p.Value }
    return $bag
}

function Test-RosterHub {
    <#
    .SYNOPSIS
        A Hub is an agent whose labels carry a `hub-*` key or `iqa-role=merge`.
    #>
    param($Labels)
    foreach ($key in @($Labels.Keys)) {
        if ($key -match '^hub[-.]') { return $true }
        if ($key -ieq 'iqa-role' -and [string]$Labels[$key] -ieq 'merge') { return $true }
    }
    return $false
}

function Test-RosterDoneFile {
    <#
    .SYNOPSIS
        True when the agent's own checkout already holds completion evidence.
    .DESCRIPTION
        Ownership, not mere presence. A repository root is a shared trunk (its
        `.git` says so) and is never evidence for the agent sitting in it;
        `.iqa-done-*.json` counts only when its name carries this agent's
        identity, or the agent is closed and the file postdates its creation.
    #>
    param([string]$Cwd, [string[]]$Tokens = @(), [string]$Status = '', $CreatedAt = $null)
    if ([string]::IsNullOrWhiteSpace($Cwd) -or -not (Test-Path -LiteralPath $Cwd)) { return $false }
    if (Test-RosterRepoRoot -Cwd $Cwd) { return $false }
    if (Test-Path -LiteralPath (Join-Path $Cwd '.iqa-report.md')) { return $true }
    $hits = @(Get-ChildItem -LiteralPath $Cwd -Filter '.iqa-done-*.json' -File -ErrorAction SilentlyContinue)
    foreach ($hit in $hits) {
        if (Test-RosterOwnFileName -Name $hit.Name -Tokens $Tokens) { return $true }
        if ($Status -ieq 'closed' -and $null -ne $CreatedAt -and $hit.LastWriteTime -gt $CreatedAt) { return $true }
    }
    return $false
}

function Test-RosterRepoRoot {
    <#
    .SYNOPSIS
        True when the cwd is a repository root (holds `.git`), i.e. a shared
        trunk rather than one agent's worktree.
    #>
    param([string]$Cwd)
    if ([string]::IsNullOrWhiteSpace($Cwd) -or -not (Test-Path -LiteralPath $Cwd)) { return $false }
    return (Test-Path -LiteralPath (Join-Path $Cwd '.git'))
}

function Get-RosterOwnTokens {
    <#
    .SYNOPSIS
        The names a done file may carry to count as this agent's own: its id,
        its short id, and any bead id visible in its title or labels.
    #>
    param([string]$AgentId, [string]$ShortId, [string]$Title, $Labels)
    $tokens = [System.Collections.Generic.List[string]]::new()
    foreach ($value in @($AgentId, $ShortId)) {
        if (-not [string]::IsNullOrWhiteSpace($value) -and $value.Length -ge 4) {
            $tokens.Add($value.ToLowerInvariant())
        }
    }
    $texts = @($Title)
    if ($null -ne $Labels) {
        foreach ($key in @($Labels.Keys)) { $texts += [string]$Labels[$key]; $texts += [string]$key }
    }
    foreach ($text in $texts) {
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        # bead ids: `<repo>-<hash>` / `<prefix>-<repo>-<hash>`, e.g. cl-common-qz8
        foreach ($match in [regex]::Matches($text.ToLowerInvariant(), '(?<![a-z0-9-])[a-z][a-z0-9]*(?:-[a-z0-9]+)*-[0-9a-z]{3}(?![a-z0-9])')) {
            $tokens.Add($match.Value)
        }
    }
    return @($tokens | Select-Object -Unique)
}

function Test-RosterOwnFileName {
    <#
    .SYNOPSIS
        True when a file name carries one of the agent's own identifiers.
    #>
    param([string]$Name, [string[]]$Tokens = @())
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    $lower = $Name.ToLowerInvariant()
    foreach ($token in @($Tokens)) {
        if (-not [string]::IsNullOrWhiteSpace($token) -and $lower.Contains($token)) { return $true }
    }
    return $false
}

function Get-RosterSessionId {
    param($State)
    if ($null -eq $State) { return $null }
    foreach ($path in @(@('persistence', 'sessionId'), @('runtimeInfo', 'sessionId'))) {
        $node = $State
        $found = $true
        foreach ($part in $path) {
            if ($null -eq $node -or $null -eq $node.PSObject.Properties[$part]) { $found = $false; break }
            $node = $node.$part
        }
        if ($found -and -not [string]::IsNullOrWhiteSpace([string]$node)) { return [string]$node }
    }
    return $null
}

$listing = Get-RosterAgentRows
$agents = @()
foreach ($row in @($listing.Rows)) {
    if ($null -eq $row) { continue }
    $id = [string]$row.id
    if ([string]::IsNullOrWhiteSpace($id)) { continue }
    $title = [string]$row.name
    $status = [string]$row.status
    # this process, and merge workers that own the merge queue, are never nudged
    if ($SelfAgentId -and $id -eq $SelfAgentId) { continue }
    if ($title -match '^merge-') { continue }
    if ($status -ieq 'closed') { continue }

    $state = Get-RosterAgentState -AgentId $id
    $labels = Get-RosterLabels -State $state
    $cwd = [string]$row.cwd
    if ([string]::IsNullOrWhiteSpace($cwd) -and $null -ne $state) { $cwd = [string]$state.cwd }
    $lastActivity = $null
    if ($null -ne $state -and $null -ne $state.PSObject.Properties['lastActivityAt']) { $lastActivity = $state.lastActivityAt }

    $shortId = [string]$row.shortId
    if ([string]::IsNullOrWhiteSpace($shortId)) { $shortId = $id.Substring(0, [Math]::Min(7, $id.Length)) }
    $created = $null
    foreach ($source in @($row, $state)) {
        if ($null -eq $source -or $null -eq $source.PSObject.Properties['created'] -or -not $source.created) { continue }
        try { $created = [datetime]$source.created; break } catch { $created = $null }
    }
    $tokens = Get-RosterOwnTokens -AgentId $id -ShortId $shortId -Title $title -Labels $labels

    $agents += [ordered]@{
        id             = $id
        shortId        = $shortId
        title          = $title
        cwd            = $cwd
        cwdIsRepoRoot  = (Test-RosterRepoRoot -Cwd $cwd)
        status         = $status
        created        = $(if ($null -ne $created) { $created.ToString('o') } else { '' })
        sessionId      = (Get-RosterSessionId -State $state)
        lastActivityAt = $lastActivity
        labels         = $labels
        isHub          = (Test-RosterHub -Labels $labels)
        hasDoneFile    = (Test-RosterDoneFile -Cwd $cwd -Tokens $tokens -Status $status -CreatedAt $created)
    }
}

$payload = [ordered]@{
    version    = 1
    capturedAt = (Get-Date).ToString('o')
    runId      = $RunId
    from       = $(if ($FromKeyNumber -gt 0) { "GO$FromKeyNumber" } else { '' })
    to         = $(if ($ToKeyNumber -gt 0) { "GO$ToKeyNumber" } else { '' })
    source     = $listing.Source
    agents     = @($agents)
}

$dir = Split-Path -Parent $OutPath
if ($dir -and -not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
Set-Content -LiteralPath $OutPath -Value ($payload | ConvertTo-Json -Depth 10) -Encoding utf8NoBOM

$hubs = @($agents | Where-Object { $_.isHub }).Count
if ($Json) {
    $payload | ConvertTo-Json -Depth 10
} else {
    Write-Output ("roster {0}: {1} agent(s) ({2} hub) -> {3}" -f $RunId, $agents.Count, $hubs, $OutPath)
}
exit 0
