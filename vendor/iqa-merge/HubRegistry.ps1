#Requires -Version 7
<#
.SYNOPSIS
    Per-repo Hub registry: the durable advertisement a Sub can always read.

.DESCRIPTION
    Hub discovery used to depend on one thing: an agent label, read through
    `paseo_list_agents`. Both halves of that failed on 2026-11-01 in the same
    handoff (bead cl-common: hub discovery):

      1. the list is WORKSPACE-scoped unless called with `cwd`, so a Sub in the
         "CBK Copy" workspace could not see the Hub sitting in "Hub-CBK" at all —
         it returned three agents and none of them was the Hub;
      2. the Hub had never set its labels (`{}`), so even a correctly scoped
         label scan would have matched nothing.

    Either failure alone loses the handoff. This helper makes the advertisement
    a FILE, written by each Hub at start and refreshed by heartbeat, so a Sub
    reads a fact instead of inferring one from a filtered list:

        ~/.salmon/State/hubs/<repo>.json

    The record names the HUB AGENT ID and the MACHINE as well as the repo, and
    carries a heartbeat timestamp — "repo X has a hub" is not actionable, while
    "repo X is served by agent <id> on <machine>, alive as of <t>" is.

    SCHEMA v2 holds a SET of entries, one per hub agent. v1 held a single
    record with last-writer-wins, and that assumption was wrong in the same way
    the label scan was: on 2026-11-01 two Hubs were live on currents-bookkeeping
    at once (a takeover during a drain, plus a lane opened by mistake), and
    `Find` named whichever registered last while the other was landing on the
    same trunk. The duplicate landing that nearly followed is the exact failure
    this registry exists to prevent, so "one hub per repo" is now a representable
    state rather than an overwrite. A v1 file is read as a one-entry set.

    Modes
      Register   upsert THIS agent's entry for a repo (hub start; also refreshes)
      Heartbeat  refresh this agent's entry
      Clear      remove this agent's entry, and only this agent's
      Find       fold every entry into one verdict (below)
      List       one row per repo, folded, with each entry's state

    Liveness is THREE states, and only `dead` means "no hub here":

      live     heartbeat inside MaxAgeMinutes                          exit 0
      unknown  stale, but inside a declared busy window, inside one
               grace window after that busy window closed, or inside
               UnknownGraceMinutes — probably working, MUST NOT be
               duplicated; verify by direct status                   exit 3
      dead     none of the above, or no record at all                  exit 1

    The repo-level verdict FOLDS the entries: `live` if any entry is live,
    `unknown` if any is unknown, and `dead` only when every entry is dead. A
    busy Hub therefore cannot hide a live one, and a dead stale entry cannot
    mask a live one either.

    A busy declaration is an explicit opt-out from heartbeating, not a promise
    to die. Inside the window, and for one grace window after it closes, the
    verdict is `unknown` — because a Hub that said "do not expect a heartbeat
    until T" had no opportunity to refresh before T, so T plus grace is the
    earliest point at which its silence is evidence of absence. Without that,
    a window shorter than the work it covers manufactures the very death it was
    meant to prevent: Hub-CBK registered a 60-minute window over a longer
    serialised suite and watched itself decay to `dead` mid-run.

    `pid` is the pid of the process that WROTE the entry (usually a short-lived
    `pwsh`), kept for diagnosis only. It is not a liveness signal: the writing
    process exits immediately, while the Hub it speaks for does not.

.PARAMETER MaxAgeMinutes
    How stale a heartbeat may be before an entry stops counting as live. The
    Hub's own cadence re-heartbeats well under this (see `Get-HubCadence.ps1`).

.PARAMETER UnknownGraceMinutes
    Window past MaxAgeMinutes in which a stale entry reports `unknown` instead
    of `dead`. Defaults to twice MaxAgeMinutes. The same width is granted after
    a declared busy window closes.

.PARAMETER BusyMinutes
    Register/Heartbeat only: declare that this Hub will not heartbeat for this
    many minutes (a serialised suite, a long build, a merge window). Size it to
    the expected block PLUS margin, and renew it with a Heartbeat between
    blocks — the window is an opt-out from heartbeating, never a renewal of it.

.PARAMETER PruneMinutes
    On a write, drop OTHER agents' entries that have been dead for longer than
    this. Recent dead entries are kept: they are still the truth about who was
    here, and a Sub may need that answer. Default 1440 (one day).

.PARAMETER HubAgentId
    The STABLE id of the hub of record, for Heartbeat and Clear. A merge-tick is
    a NEW Paseo agent every fire, so "renew MY entry" is not a thing a tick can
    honestly say: its own id has no entry, and the old fallback registered a new
    hub every fire (measured 2026-11-03: four ticks -> hubCount 6, Find reported
    duplicate=true, the primary flapped between the tick and the real Hub).

    Resolution order for the hub of record:
      1. this parameter
      2. `$env:SALMON_HUB_AGENT_ID`
      3. `-AgentId`, when that id already HAS an entry (legacy self-heartbeat)
      4. no id named at all -> the live primary for the repo in the registry
      5. nothing -> a named, non-zero `no-hub-of-record` verdict (exit 4)

    A tick therefore NEVER registers its own id. Where no record exists at all,
    a declared stable id (1 or 2) is registered ONCE, so the repository keeps
    exactly one hub of record rather than one per tick.

.PARAMETER Terminal
    Clear only: assert that the predecessor run being cleared is terminal
    (already closed/idle). A `live` entry is never cleared this way - it is a
    peer, not a predecessor. Without this switch an `unknown` predecessor is
    also refused; clearing your OWN entry needs no switch.

.EXAMPLE
    ./HubRegistry.ps1 -Mode Register -Repo currents-bookkeeping `
        -RepoPath E:\Repos\currents-bookkeeping -AgentId cb0d5cd5 -Trunk dev

.EXAMPLE
    ./HubRegistry.ps1 -Mode Heartbeat -Repo currents-bookkeeping -AgentId cb0d5cd5 -BusyMinutes 45

.EXAMPLE
    # A merge-tick renews the HUB OF RECORD, never its own transient id.
    ./HubRegistry.ps1 -Mode Heartbeat -Repo cl-common -HubAgentId 5f825afa-9bab-4087-9590-80bf4671ef58

.EXAMPLE
    ./HubRegistry.ps1 -Mode Find -Repo currents-bookkeeping -Json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Register', 'Heartbeat', 'Clear', 'Find', 'List', 'Version')]
    [string]$Mode,

    [string]$Repo,
    [string]$RepoPath,
    [string]$Trunk = 'dev',
    [string]$AgentId,
    [string]$HubAgentId,
    [switch]$Terminal,
    [string]$Machine = $env:COMPUTERNAME,
    [int]$MaxAgeMinutes = 15,
    [int]$UnknownGraceMinutes = 0,
    [int]$BusyMinutes = 0,
    [int]$PruneMinutes = 1440,

    # Publish retry policy, passed straight to the shared atomic-write owner
    # (AtomicRecordWrite.ps1). Defaults are the owner's: 4 attempts, 250 ms
    # doubling to a 4 s cap - enough for the sub-four-second contention measured
    # on 2026-11-03. Exposed so a test can prove the retry, not so a caller can
    # weaken it.
    [ValidateRange(1, 50)]
    [int]$WriteAttempts = 4,
    [ValidateRange(0, 60000)]
    [int]$WriteInitialDelayMilliseconds = 250,
    [ValidateRange(0, 600000)]
    [int]$WriteMaxDelayMilliseconds = 4000,

    # Registry root. Overridable so tests never touch the machine's real state.
    [string]$Root = (Join-Path $HOME '.salmon/State/hubs'),

    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# The helper advertises its OWN version, separate from the record's
# schemaVersion: the schema says what shape the FILE has, this says what
# SEMANTICS answered you. They move independently - identity resolution and
# primary/secondary roles changed behaviour without changing the file shape.
# 3 = identity resolution from any path + primary/secondary roles + freshness.
# 4 = hub-of-record resolution: a merge-tick heartbeats a STABLE id and never
#     registers its own transient one (cl-common-y49).
#
# NOT bumped for cl-common-2jz: routing the publish through the shared atomic-write
# owner (AtomicRecordWrite.ps1) changes how the record is WRITTEN, not what it
# MEANS - same schema, same fields, same verdicts. `helperVersion` gates writes
# (`Assert-WritableSchema` refuses when the record is newer), so bumping it would
# make every still-deployed v4 helper refuse to write a v5 record for no semantic
# reason. A publish fix is not a semantics change.
$script:HelperVersion = 4

function Write-Verdict {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Payload,
        [int]$ExitCode = 0,
        [string]$HumanLine
    )
    # Every answer advertises which helper produced it, so a caller never has to
    # infer the semantics from the presence or absence of a field.
    if (-not $Payload.Contains('helperVersion')) { $Payload['helperVersion'] = $script:HelperVersion }
    if ($Json) {
        $Payload | ConvertTo-Json -Depth 8 -Compress
    } else {
        $Payload.GetEnumerator() | Sort-Object Name | ForEach-Object { '{0}: {1}' -f $_.Key, $_.Value }
        if ($HumanLine) { $HumanLine }
    }
    exit $ExitCode
}

function Get-RecordPath {
    param([string]$Name)
    Join-Path $Root ("{0}.json" -f $Name)
}

# --- the shared atomic-write owner (bead cl-common-2jz) ----------------------
# "Publish a JSON record atomically under contention" has exactly one
# implementation: AtomicRecordWrite.ps1. It classifies the rename failure
# (EPERM / Windows sharing violation), backs off, retries within a bounded
# budget, and fails with a NAMED error. The schedule-record wrapper
# (Invoke-ScheduleRecordWrite.ps1) reuses the same policy, so a registry write
# and a schedule write cannot drift into two different retry behaviours.
$script:AtomicWriteOwnerPath = Join-Path $PSScriptRoot 'AtomicRecordWrite.ps1'
if (-not (Test-Path -LiteralPath $script:AtomicWriteOwnerPath -PathType Leaf)) {
    Write-Verdict -Payload ([ordered]@{
            ok     = $false
            verdict = 'atomic-write-owner-missing'
            reason = "the shared atomic-write owner is missing: $($script:AtomicWriteOwnerPath) - refusing to fall back to a bare rename, because that is the unretried publish cl-common-2jz is about"
        }) -ExitCode 2
}
. $script:AtomicWriteOwnerPath

function Resolve-RepoIdentity {
    <#
    .SYNOPSIS
        Resolve a filesystem path to the identity of the repo that owns it.

    .DESCRIPTION
        A Hub looks itself up by the repo it is working on, but callers passed
        whatever string they had: the repo name, the folder they were standing
        in, or a bare path. Those are different KEYS for the same repo, and a
        miss used to read as "no hub here, spawn one" - which is how a second
        hub came to exist while the first was mid-suite.

        Every form now resolves to one identity: the leaf of the MAIN checkout.
        A path inside `.worktrees/<name>` maps back to the repo that owns the
        worktree, because git reports the same common git dir for both.
    #>
    param([string]$Path)

    if (-not $Path) { return $null }
    try {
        if (-not (Test-Path -LiteralPath $Path)) { return $null }
        $probe = if (Test-Path -LiteralPath $Path -PathType Container) { $Path } else { Split-Path -Parent $Path }

        $top = (& git -C $probe rev-parse --show-toplevel 2>$null)
        if ($LASTEXITCODE -ne 0 -or -not $top) { return $null }
        $top = ([string]$top).Trim()

        $common = (& git -C $probe rev-parse --git-common-dir 2>$null)
        if ($LASTEXITCODE -ne 0 -or -not $common) { return $null }
        $common = ([string]$common).Trim()
        if (-not [System.IO.Path]::IsPathRooted($common)) { $common = Join-Path $top $common }
        $common = [System.IO.Path]::GetFullPath($common)

        # The common git dir is <mainRoot>/.git for a checkout AND for every
        # linked worktree of it, so its parent is the repo identity.
        $mainRoot = Split-Path -Parent $common
        if (-not $mainRoot) { $mainRoot = $top }
        # Normalize BOTH through GetFullPath before comparing: git reports the
        # worktree root with forward slashes but the resolved common dir with
        # backslashes on Windows, so comparing the raw strings marked every
        # checkout - including the main one - as a worktree.
        $mainRoot = ([System.IO.Path]::GetFullPath($mainRoot)).TrimEnd('\', '/')
        $top = ([System.IO.Path]::GetFullPath($top)).TrimEnd('\', '/')

        return [pscustomobject]@{
            Name         = Split-Path -Leaf $mainRoot
            MainRoot     = $mainRoot
            WorktreeRoot = $top
            IsWorktree   = ($top -ne $mainRoot)
        }
    } catch {
        return $null
    }
}

function Get-RepoName {
    <#
    .SYNOPSIS
        Turn whatever the caller passed into a usable record name.

    .DESCRIPTION
        A bare name is returned as-is. A path-like value is resolved to the repo
        that contains it. Returns $null when a path-like value does not resolve,
        so Register can refuse instead of creating a record named after a path
        (the old code happily built `<root>\E:\Repos\....json`).
    #>
    param([string]$Repo, [string]$RepoPath)

    if ($RepoPath) {
        $identity = Resolve-RepoIdentity -Path $RepoPath
        if ($identity) { return $identity.Name }
    }
    if (-not $Repo) { return $null }
    if ($Repo -match '[\\/:]') {
        $identity = Resolve-RepoIdentity -Path $Repo
        if ($identity) { return $identity.Name }
        return $null
    }
    return $Repo.Trim()
}

function Find-RegistryByIdentity {
    <#
    .SYNOPSIS
        Find the record that belongs to a resolved repo identity, whatever name
        it happens to be filed under.

    .DESCRIPTION
        The name-key lookup only works when the caller guessed the exact name.
        This is the safety net: match on the identity the repo path resolves to,
        and on a case-insensitive name, so a differently-named record can never
        hide a live hub.
    #>
    param($Identity, [string]$Name)

    if (-not (Test-Path -LiteralPath $Root)) { return $null }
    foreach ($file in Get-ChildItem -LiteralPath $Root -Filter '*.json' -File) {
        $candidate = $file.BaseName
        $byName = $Name -and ($candidate -ieq $Name)
        if (-not $byName) {
            $read = Read-Registry -Name $candidate
            if (-not $read.Ok) { continue }
            if ($Identity) {
                foreach ($entry in @($read.Entries)) {
                    $entryPath = Get-Optional $entry 'repoPath'
                    if (-not $entryPath) { continue }
                    $entryIdentity = Resolve-RepoIdentity -Path $entryPath
                    if ($entryIdentity -and $entryIdentity.MainRoot -ieq $Identity.MainRoot) {
                        return [pscustomobject]@{ Name = $candidate; Registry = $read }
                    }
                }
            }
            continue
        }
        $read = Read-Registry -Name $candidate
        if ($read.Ok) { return [pscustomobject]@{ Name = $candidate; Registry = $read } }
    }
    return $null
}

function Get-KnownRepos {
    <# Every repo with a live or unknown hub, so a caller that queried the wrong
       key sees what IS registered instead of a bare "no record". #>
    param([int]$MaxAge, [int]$Grace)

    $known = @()
    if (-not (Test-Path -LiteralPath $Root)) { return @() }
    foreach ($file in Get-ChildItem -LiteralPath $Root -Filter '*.json' -File) {
        $read = Read-Registry -Name $file.BaseName
        if (-not $read.Ok) { continue }
        $fold = Fold-Entries -Entries @($read.Entries) -MaxAge $MaxAge -Grace $Grace
        if ($fold.State -eq 'dead') { continue }
        $known += [ordered]@{
            repo    = $file.BaseName
            state   = $fold.State
            agentId = $fold.Representative.AgentId
        }
    }
    return @($known)
}

function Get-Optional {
    # StrictMode throws on a missing property, and a v1 record predates fields a
    # v2 entry carries (busyUntil, machine). Absent is null, never an error.
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $null
    }
    if ($Object.PSObject.Properties.Name -contains $Name) { return $Object.$Name }
    return $null
}

function Read-Registry {
    param([string]$Name)
    $path = Get-RecordPath -Name $Name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return [pscustomobject]@{ Ok = $false; Kind = 'absent'; SchemaVersion = $null; Reason = "no hub record for '$Name' at $path"; Entries = @() }
    }
    try {
        $raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch {
        # Fail closed: a corrupt record is not evidence of a hub, and it is not
        # evidence of no hub either - it is simply unreadable, and saying so is
        # the only honest verdict.
        return [pscustomobject]@{ Ok = $false; Kind = 'unreadable'; SchemaVersion = $null; Reason = "hub record for '$Name' is unreadable: $($_.Exception.Message)"; Entries = @() }
    }

    $entries = @()
    $schemaVersion = 1
    if ($null -ne (Get-Optional $raw 'hubs')) {
        $schemaVersion = Get-Optional $raw 'schemaVersion'
        if ($null -eq $schemaVersion) { $schemaVersion = 2 }
        foreach ($entry in @(Get-Optional $raw 'hubs')) {
            if ($null -ne $entry) { $entries += $entry }
        }
    } elseif ($null -ne (Get-Optional $raw 'agentId')) {
        # v1: one record, last-writer-wins. Read it as a one-entry set so an
        # existing record still answers after the upgrade.
        $schemaVersion = 1
        $entries = @($raw)
    } else {
        return [pscustomobject]@{ Ok = $false; Kind = 'unreadable'; SchemaVersion = $null; Reason = "hub record for '$Name' carries neither 'hubs' nor 'agentId'"; Entries = @() }
    }

    [pscustomobject]@{ Ok = $true; Kind = 'ok'; SchemaVersion = [int]$schemaVersion; HelperVersion = (Get-Optional $raw 'helperVersion'); Reason = $null; Entries = @($entries) }
}

function Write-RegistryAtomic {
    <#
    .SYNOPSIS
        Publish the registry record through the shared atomic-write owner.

    .DESCRIPTION
        This used to be a bare `Move-Item ... -Force` publish with no retry (bead
        cl-common-2jz). On Windows a rename needs DELETE access on the
        destination, so it fails with EPERM / a sharing violation whenever another
        process holds the file open - and this file is written by EVERY Hub
        heartbeat and read by every `Find`. One unlucky overlap therefore failed a
        heartbeat, and a stale entry makes a LIVE hub look `dead` - which is what
        licenses a takeover.

        The retry policy is NOT implemented here. `Write-JsonRecordAtomic`
        (AtomicRecordWrite.ps1) owns it once, and the schedule-record writes use
        the same owner. The publish is a single replace-rename, never
        delete-then-write, so a failed publish leaves the PREVIOUS valid record
        exactly as it was.

        A failure is reported as a named, non-zero verdict: the record was not
        published, so the caller must not report this hub as registered or
        refreshed.

        RETURNS the owner's result object (Ok / Attempt / Attempts / AttemptLog).
        ALWAYS capture it (`$write = Write-RegistryAtomic ...`): an uncaptured
        return lands in the verdict stream and corrupts the `-Json` output, which
        is a machine contract every caller parses.

    .PARAMETER Mode
        The calling mode ('register' / 'heartbeat' / 'clear'), named verbatim in
        the failure verdict so a log line says which write failed.
    #>
    param([string]$Path, [string]$Repo, $Entries, [string]$Mode = 'write')
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $record = [ordered]@{
        schemaVersion = 2
        helperVersion = $script:HelperVersion
        repo          = $Repo
        hubs          = @($Entries)
    }
    try {
        return Write-JsonRecordAtomic -Path $Path -Value $record -Depth 8 `
            -Attempts $WriteAttempts `
            -InitialDelayMilliseconds $WriteInitialDelayMilliseconds `
            -MaxDelayMilliseconds $WriteMaxDelayMilliseconds
    }
    catch {
        Write-Verdict -Payload ([ordered]@{
                ok      = $false
                verdict = 'registry-write-failed'
                mode    = $Mode
                repo    = $Repo
                path    = $Path
                reason  = $_.Exception.Message
                note    = 'the publish was retried and did not land; the previous valid record is unchanged, so do not report this hub as registered or refreshed'
            }) -ExitCode 1
    }
}

function Test-Entry {
    <#
    .SYNOPSIS
        Liveness of ONE registered hub entry: live / unknown / dead.
    #>
    param($Entry, [int]$MaxAge, [int]$Grace)
    $grace = if ($Grace -gt 0) { $Grace } else { $MaxAge * 2 }
    $agentId = Get-Optional $Entry 'agentId'
    $stamp = Get-Optional $Entry 'heartbeatAt'
    $who = if ($agentId) { $agentId } else { '(unnamed entry)' }

    if (-not $stamp) {
        return [pscustomobject]@{ State = 'dead'; Live = $false; AgeMinutes = $null; Reason = "$who carries no heartbeatAt" }
    }
    try {
        $hb = [DateTimeOffset]::Parse($stamp, [Globalization.CultureInfo]::InvariantCulture)
    } catch {
        return [pscustomobject]@{ State = 'dead'; Live = $false; AgeMinutes = $null; Reason = "$who has a heartbeatAt that is not an ISO-8601 timestamp: $stamp" }
    }
    $age = ([DateTimeOffset]::UtcNow - $hb).TotalMinutes

    if ($age -le $MaxAge) {
        return [pscustomobject]@{ State = 'live'; Live = $true; AgeMinutes = [math]::Round($age, 2); Reason = $null }
    }

    # A declared busy window outranks staleness: the Hub is mid-battery, not gone.
    $busyUntil = Get-Optional $Entry 'busyUntil'
    if ($busyUntil) {
        try {
            $bu = [DateTimeOffset]::Parse($busyUntil, [Globalization.CultureInfo]::InvariantCulture)
            $now = [DateTimeOffset]::UtcNow
            if ($now -lt $bu) {
                return [pscustomobject]@{
                    State      = 'unknown'
                    Live       = $false
                    AgeMinutes = [math]::Round($age, 2)
                    Reason     = ('{0} declared busy until {1} (heartbeat {2:N1} min old) - UNKNOWN, do not spawn a duplicate' -f $who, $busyUntil, $age)
                }
            }
            # The window closed. Give one grace window to renew: the Hub had no
            # chance to heartbeat before the edge it declared, so the edge alone
            # cannot be evidence of absence.
            if ($now -lt $bu.AddMinutes($grace)) {
                return [pscustomobject]@{
                    State      = 'unknown'
                    Live       = $false
                    AgeMinutes = [math]::Round($age, 2)
                    Reason     = ('{0} busy window closed at {1}, inside the {2}-min renewal grace (heartbeat {3:N1} min old) - UNKNOWN, do not spawn a duplicate' -f $who, $busyUntil, $grace, $age)
                }
            }
        } catch {
            # An unparseable busyUntil is not evidence of life; fall through.
        }
    }

    if ($age -le $grace) {
        return [pscustomobject]@{
            State      = 'unknown'
            Live       = $false
            AgeMinutes = [math]::Round($age, 2)
            Reason     = ('{0} heartbeat is {1:N1} min old (live limit {2}, grace {3}) - UNKNOWN, verify by direct status, do not spawn a duplicate' -f $who, $age, $MaxAge, $grace)
        }
    }

    [pscustomobject]@{
        State      = 'dead'
        Live       = $false
        AgeMinutes = [math]::Round($age, 2)
        Reason     = ('{0} heartbeat is {1:N1} min old (live limit {2}, grace {3}) - hub presumed gone' -f $who, $age, $MaxAge, $grace)
    }
}

function Fold-Entries {
    <#
    .SYNOPSIS
        Fold every entry in a repo's registry into one verdict.

    .DESCRIPTION
        live if ANY entry is live, unknown if any is unknown, dead only when
        ALL are dead. The representative (returned at top level for callers that
        want one agent id) is the best-ranked, most recently refreshed entry.
    #>
    param($Entries, [int]$MaxAge, [int]$Grace)

    $rank = @{ 'live' = 0; 'unknown' = 1; 'dead' = 2 }
    $states = @()
    foreach ($entry in @($Entries)) {
        $verdict = Test-Entry -Entry $entry -MaxAge $MaxAge -Grace $Grace
        $states += [pscustomobject]@{
            AgentId = Get-Optional $entry 'agentId'
            Entry   = $entry
            Verdict = $verdict
        }
    }

    if ($states.Count -eq 0) {
        return [pscustomobject]@{ State = 'dead'; Representative = $null; Hubs = @() }
    }

    $ordered = @($states | Sort-Object -Property `
        @{ Expression = { $rank[$_.Verdict.State] } }, `
        @{ Expression = { if ($null -eq $_.Verdict.AgeMinutes) { [double]::MaxValue } else { [double]$_.Verdict.AgeMinutes } } })

    [pscustomobject]@{ State = $ordered[0].Verdict.State; Representative = $ordered[0]; Hubs = $ordered }
}

function Get-LivePrimaryAgentId {
    <#
    .SYNOPSIS
        The agent id of the live PRIMARY entry in a folded registry, or $null.

    .DESCRIPTION
        `Find` classifies primary (anchored at the repo itself) vs secondary
        (alive but standing in a lane worktree). The hub of record is the
        primary; a secondary is visible but never the thing a tick renews when
        the primary is right there.
    #>
    param($Fold, [string]$RepoName)

    if (-not $Fold) { return $null }
    $live = @($Fold.Hubs | Where-Object { $_.Verdict.State -eq 'live' })
    if ($live.Count -eq 0) { return $null }

    foreach ($h in $live) {
        $entryPath = Get-Optional $h.Entry 'repoPath'
        if (-not $entryPath) { return $h.AgentId }
        $identity = Resolve-RepoIdentity -Path $entryPath
        if ($identity -and (-not $identity.IsWorktree) -and (-not $RepoName -or $identity.Name -ieq $RepoName)) {
            return $h.AgentId
        }
    }
    return $live[0].AgentId
}

function Resolve-HubOfRecord {
    <#
    .SYNOPSIS
        Decide WHICH agent id is the hub of record for this call.

    .DESCRIPTION
        A merge-tick is a new Paseo agent on every fire, so "renew my entry" is
        not a statement a tick can make: its id has no entry, and the old
        fallback quietly registered a new hub each time. The hub of record is
        resolved from a stable source instead, in this order:

          1. -HubAgentId (explicit)
          2. $env:SALMON_HUB_AGENT_ID
          3. -AgentId, but only when that id ALREADY has an entry (a Hub
             heartbeating itself - the legacy contract, and the reason an
             unknown id is still refused rather than redirected)
          4. nothing named at all -> the live primary for the repo
          5. nothing -> AgentId $null and Source 'none'; the caller must fail
             closed with a named verdict, never register the caller's own id

        `Source` travels with the answer so the caller can tell "a declared
        stable id" (may be registered once when absent) from "a claimed id that
        the registry does not know" (refused).
    #>
    param(
        $Record,
        [string]$ExplicitHubId,
        [string]$ClaimedAgentId,
        [string]$EnvId,
        [string]$RepoName,
        [int]$MaxAge,
        [int]$Grace
    )

    if ($ExplicitHubId) { return [pscustomobject]@{ AgentId = $ExplicitHubId; Source = 'parameter' } }
    if ($EnvId) { return [pscustomobject]@{ AgentId = $EnvId; Source = 'env' } }
    if ($ClaimedAgentId) { return [pscustomobject]@{ AgentId = $ClaimedAgentId; Source = 'agent-id' } }

    if ($Record -and $Record.Ok) {
        $fold = Fold-Entries -Entries @($Record.Entries) -MaxAge $MaxAge -Grace $Grace
        $primary = Get-LivePrimaryAgentId -Fold $fold -RepoName $RepoName
        if ($primary) { return [pscustomobject]@{ AgentId = $primary; Source = 'registry-live-primary' } }
    }

    return [pscustomobject]@{ AgentId = $null; Source = 'none' }
}

function Remove-Stale {
    <#
    .SYNOPSIS
        Drop other agents' entries that have been dead for longer than PruneMinutes.
    #>
    param($Entries, [int]$MaxAge, [int]$Grace, [int]$PruneMinutes)
    $kept = @()
    foreach ($entry in @($Entries)) {
        if (-not (Get-Optional $entry 'agentId')) { continue }
        $verdict = Test-Entry -Entry $entry -MaxAge $MaxAge -Grace $Grace
        if ($verdict.State -eq 'dead' -and $null -ne $verdict.AgeMinutes -and $verdict.AgeMinutes -gt $PruneMinutes) { continue }
        $kept += $entry
    }
    # Emit plainly: callers wrap in @(), and a comma-wrapped empty array would
    # arrive as a one-element array whose element is itself empty - which is how
    # a single Register briefly wrote two "entries".
    $kept
}

function Format-EntryList {
    param($Entries)
    @($Entries | ForEach-Object { Get-Optional $_ 'agentId' }) -join ', '
}

function Assert-WritableSchema {
    <#
    .SYNOPSIS
        Refuse to write a record a NEWER helper owns.

    .DESCRIPTION
        The recorded schemaVersion is the only way a writer can tell that it is
        the stale one. v1 could not: a v1 helper writing over a v2 file silently
        collapsed a set of hubs back to a single slot. That specific writer
        cannot be patched retroactively, so the guard is symmetric instead -
        whichever helper is older refuses, and the caller learns why.
    #>
    param($Read, [string]$Mode, [string]$Repo)
    if ($Read.Ok -and $Read.SchemaVersion -gt 2) {
        Write-Verdict -Payload ([ordered]@{
                ok     = $false
                mode   = $Mode
                repo   = $Repo
                reason = "refusing to write: '$Repo' is schemaVersion $($Read.SchemaVersion) and this helper knows 2 - a newer helper owns that record, and writing would discard fields it relies on. Run the helper from a checkout at origin/<trunk>."
            }) -ExitCode 2
    }
    # Same guard one level up: the record may keep a shape this helper knows while
    # carrying SEMANTICS (fields, meaning) from a newer helper.
    $recordHelper = Get-Optional $Read 'HelperVersion'
    if ($Read.Ok -and $null -ne $recordHelper -and [int]$recordHelper -gt $script:HelperVersion) {
        Write-Verdict -Payload ([ordered]@{
                ok            = $false
                mode          = $Mode
                repo          = $Repo
                helperVersion = $script:HelperVersion
                recordHelper  = [int]$recordHelper
                reason        = "refusing to write: '$Repo' was written by helper v$recordHelper and this copy is v$($script:HelperVersion) - a newer helper owns that record. Run the helper from a checkout at origin/<trunk>."
            }) -ExitCode 2
    }
}

switch ($Mode) {
    'Register' {
        $rawRepo = $Repo
        $Repo = Get-RepoName -Repo $Repo -RepoPath $RepoPath
        if (-not $Repo) {
            Write-Verdict -Payload ([ordered]@{
                    ok = $false; mode = 'register'; requestedRepo = $rawRepo
                    reason = 'Register needs -Repo (a repo name, or a path inside the repo)'
                    note   = 'a path-like -Repo must resolve to a git repository; refusing to file a record named after an unresolved path'
                }) -ExitCode 2
        }
        if (-not $AgentId) { Write-Verdict -Payload ([ordered]@{ ok = $false; reason = "Register needs -AgentId (the hub's own agent id)" }) -ExitCode 2 }

        # A merge-tick must never register its transient id while a declared hub
        # of record is already named (cl-common-y49). Registering the tick is
        # what turned one repo into six hubs in four fires.
        $declaredHub = if ($HubAgentId) { $HubAgentId } elseif ($env:SALMON_HUB_AGENT_ID) { $env:SALMON_HUB_AGENT_ID } else { $null }
        if ($declaredHub -and ($declaredHub -ne $AgentId)) {
            Write-Verdict -Payload ([ordered]@{
                    ok = $false; mode = 'register'; repo = $Repo; agentId = $AgentId; hubOfRecord = $declaredHub
                    verdict = 'transient-id-refused'
                    reason = "refusing to register ${AgentId}: the hub of record for '$Repo' is already $declaredHub. A merge-tick renews the stable id (-Mode Heartbeat -HubAgentId <id>) and never registers its own transient agent id."
                    note   = 'cl-common-y49: every tick is a new Paseo agent; registering one per fire is the duplicate-hub hazard this registry exists to prevent'
                }) -ExitCode 2
        }

        # Record where this hub actually stands. When it differs from the repo it
        # claims, Find reports it as a secondary hub rather than letting two
        # hubs both call themselves primary.
        if (-not $RepoPath) { $RepoPath = (Get-Location).Path }

        $read = Read-Registry -Name $Repo
        if (-not $read.Ok -and $read.Kind -eq 'unreadable') {
            Write-Verdict -Payload ([ordered]@{
                    ok = $false; mode = 'register'; repo = $Repo; reason = $read.Reason
                    note = 'refusing to overwrite a record that cannot be parsed - another hub may own it'
                }) -ExitCode 1
        }
        Assert-WritableSchema -Read $read -Mode 'register' -Repo $Repo

        $now = [DateTimeOffset]::UtcNow.ToString('o')
        $existing = if ($read.Ok) { @($read.Entries) } else { @() }
        $mine = $existing | Where-Object { (Get-Optional $_ 'agentId') -eq $AgentId } | Select-Object -First 1
        $others = @($existing | Where-Object { $a = Get-Optional $_ 'agentId'; $a -and $a -ne $AgentId })
        $others = @(Remove-Stale -Entries $others -MaxAge $MaxAgeMinutes -Grace $UnknownGraceMinutes -PruneMinutes $PruneMinutes)

        $registeredAt = if ($mine -and (Get-Optional $mine 'registeredAt')) { Get-Optional $mine 'registeredAt' } else { $now }
        $busyUntil = if ($BusyMinutes -gt 0) { [DateTimeOffset]::UtcNow.AddMinutes($BusyMinutes).ToString('o') } else { $null }
        $entry = [ordered]@{
            agentId      = $AgentId
            machine      = $Machine
            pid          = $PID
            repoPath     = $RepoPath
            trunk        = $Trunk
            helperVersion = $script:HelperVersion
            registeredAt = $registeredAt
            heartbeatAt  = $now
            busyUntil    = $busyUntil
        }
        $entries = @($others) + @($entry)
        $path = Get-RecordPath -Name $Repo
        $write = Write-RegistryAtomic -Path $path -Repo $Repo -Entries $entries -Mode 'register'

        $payload = [ordered]@{
            ok        = $true
            mode      = 'register'
            path      = $path
            repo      = $Repo
            agentId   = $AgentId
            machine   = $Machine
            busyUntil = $busyUntil
            hubCount  = @($entries).Count
            schemaVersion = 2
            writeAttempts = $write.Attempt
        }
        if (@($others).Count -gt 0) { $payload.coexisting = Format-EntryList -Entries $others }
        Write-Verdict -Payload $payload
    }

    'Heartbeat' {
        if (-not $Repo) { Write-Verdict -Payload ([ordered]@{ ok = $false; reason = 'Heartbeat needs -Repo' }) -ExitCode 2 }

        # Resolve the identity EXACTLY as Register does. Register has always
        # sanitised a path into the record's name; Heartbeat and Clear did not, so
        # a Hub that passed its repo path (`-Repo E:\Repos\upscale-havens`) was
        # told "no hub record for 'E:\Repos\upscale-havens' at
        # <root>\E:\Repos\upscale-havens.json" - a false negative that reads
        # exactly like "no hub here", on the one call that keeps a live Hub
        # looking live. On 2026-11-03 that lapsed a Hub's record to 73 minutes and
        # `Find` reported `live: False ... hub presumed gone` while the Hub was
        # mid-drain, which is the duplicate-Hub spawn this registry exists to
        # prevent.
        $requestedRepo = $Repo
        $Repo = Get-RepoName -Repo $Repo -RepoPath $RepoPath
        if (-not $Repo) {
            Write-Verdict -Payload ([ordered]@{
                    ok = $false; mode = 'heartbeat'; requestedRepo = $requestedRepo
                    reason = 'Heartbeat needs -Repo (a repo name, or a path inside the repo)'
                    note   = 'a path-like -Repo must resolve to a git repository; refusing to guess the record name'
                }) -ExitCode 2
        }

        $read = Read-Registry -Name $Repo
        if (-not $read.Ok -and $read.Kind -ne 'absent') {
            Write-Verdict -Payload ([ordered]@{ ok = $false; mode = 'heartbeat'; repo = $Repo; reason = $read.Reason }) -ExitCode 1
        }
        if ($read.Ok) { Assert-WritableSchema -Read $read -Mode 'heartbeat' -Repo $Repo }

        # WHO are we refreshing? A merge-tick is a new agent every fire, so its
        # own id is not a hub of record and is never registered (cl-common-y49).
        $resolved = Resolve-HubOfRecord -Record $read -ExplicitHubId $HubAgentId -ClaimedAgentId $AgentId `
            -EnvId $env:SALMON_HUB_AGENT_ID -RepoName $Repo -MaxAge $MaxAgeMinutes -Grace $UnknownGraceMinutes

        if (-not $resolved.AgentId) {
            # Fail closed and honestly. The old behaviour registered the caller
            # instead, which is how one repo acquired six hubs in four ticks.
            Write-Verdict -Payload ([ordered]@{
                    ok              = $false
                    mode            = 'heartbeat'
                    repo            = $Repo
                    verdict         = 'no-hub-of-record'
                    resolveFrom     = 'none'
                    reason          = "no hub of record resolved for '$Repo': no -HubAgentId, no SALMON_HUB_AGENT_ID, and the registry has no live primary entry. Nothing was written."
                    resolveOrder    = '-HubAgentId -> $env:SALMON_HUB_AGENT_ID -> -AgentId (only when it already has an entry) -> live primary in the registry'
                    note            = 'a merge-tick must never register its own transient agent id; name the hub of record or set SALMON_HUB_AGENT_ID'
                }) -ExitCode 4
        }

        $hubOfRecordId = $resolved.AgentId
        $entries = if ($read.Ok) { @($read.Entries) } else { @() }
        $mine = $entries | Where-Object { (Get-Optional $_ 'agentId') -eq $hubOfRecordId } | Select-Object -First 1

        if (-not $mine) {
            # Only a DECLARED stable id may be registered here, and only once.
            # A claimed id the registry does not know is refused: registering it
            # is the duplicate-hub hazard, not a repair.
            if ($resolved.Source -ne 'parameter' -and $resolved.Source -ne 'env') {
                Write-Verdict -Payload ([ordered]@{
                        ok          = $false; mode = 'heartbeat'; repo = $Repo
                        agentId     = $hubOfRecordId; resolveFrom = $resolved.Source
                        verdict     = 'unknown-agent-id'
                        reason      = "no entry for $hubOfRecordId in '$Repo' (registered: $(Format-EntryList -Entries $entries)) - Register first, do not heartbeat a repo you have not advertised. A transient id is never registered: pass -HubAgentId <hub of record> or set SALMON_HUB_AGENT_ID."
                        note        = 'refusing to create an entry from a claimed id; that is how duplicate hubs appeared (cl-common-y49)'
                    }) -ExitCode 1
            }

            # No hub of record exists at all: register the STABLE id once.
            if (-not $RepoPath) { $RepoPath = (Get-Location).Path }
            $others = @($entries | Where-Object { Get-Optional $_ 'agentId' })
            $others = @(Remove-Stale -Entries $others -MaxAge $MaxAgeMinutes -Grace $UnknownGraceMinutes -PruneMinutes $PruneMinutes)
            $now = [DateTimeOffset]::UtcNow.ToString('o')
            $busyUntilNew = if ($BusyMinutes -gt 0) { [DateTimeOffset]::UtcNow.AddMinutes($BusyMinutes).ToString('o') } else { $null }
            $newEntry = [ordered]@{
                agentId       = $hubOfRecordId
                machine       = $Machine
                pid           = $PID
                repoPath      = $RepoPath
                trunk         = $Trunk
                helperVersion = $script:HelperVersion
                registeredAt  = $now
                heartbeatAt   = $now
                busyUntil     = $busyUntilNew
            }
            $entries = @($others) + @($newEntry)
            $write = Write-RegistryAtomic -Path (Get-RecordPath -Name $Repo) -Repo $Repo -Entries $entries -Mode 'heartbeat'
            Write-Verdict -Payload ([ordered]@{
                    ok = $true; mode = 'heartbeat'; repo = $Repo; agentId = $hubOfRecordId
                    hubOfRecord = $hubOfRecordId; resolveFrom = $resolved.Source
                    registered = $true
                    busyUntil = $busyUntilNew; hubCount = @($entries).Count
                    writeAttempts = $write.Attempt
                    note = 'no record existed; the declared stable id was registered once (never a transient tick id)'
                })
        }

        $busyUntil = if ($BusyMinutes -gt 0) { [DateTimeOffset]::UtcNow.AddMinutes($BusyMinutes).ToString('o') } else { $null }
        $mine | Add-Member -NotePropertyName heartbeatAt -NotePropertyValue ([DateTimeOffset]::UtcNow.ToString('o')) -Force
        $mine | Add-Member -NotePropertyName pid -NotePropertyValue $PID -Force
        $mine | Add-Member -NotePropertyName busyUntil -NotePropertyValue $busyUntil -Force
        $mine | Add-Member -NotePropertyName helperVersion -NotePropertyValue $script:HelperVersion -Force

        $entries = @($entries | ForEach-Object { if ((Get-Optional $_ 'agentId') -eq $hubOfRecordId) { $mine } else { $_ } })
        $write = Write-RegistryAtomic -Path (Get-RecordPath -Name $Repo) -Repo $Repo -Entries $entries -Mode 'heartbeat'
        Write-Verdict -Payload ([ordered]@{
                ok = $true; mode = 'heartbeat'; repo = $Repo; agentId = $hubOfRecordId
                hubOfRecord = $hubOfRecordId; resolveFrom = $resolved.Source
                busyUntil = $busyUntil; hubCount = @($entries).Count
                writeAttempts = $write.Attempt
            })
    }

    'Clear' {
        if (-not $Repo) { Write-Verdict -Payload ([ordered]@{ ok = $false; reason = 'Clear needs -Repo' }) -ExitCode 2 }
        $requestedRepo = $Repo
        $Repo = Get-RepoName -Repo $Repo -RepoPath $RepoPath
        if (-not $Repo) {
            Write-Verdict -Payload ([ordered]@{
                    ok = $false; mode = 'clear'; requestedRepo = $requestedRepo
                    reason = 'Clear needs -Repo (a repo name, or a path inside the repo)'
                    note   = 'same identity rule as Register and Heartbeat; refusing to guess the record name'
                }) -ExitCode 2
        }
        $path = Get-RecordPath -Name $Repo
        $read = Read-Registry -Name $Repo
        if (-not $read.Ok) {
            Write-Verdict -Payload ([ordered]@{ ok = $true; mode = 'clear'; repo = $Repo; removed = $false; reason = $read.Reason })
        }
        Assert-WritableSchema -Read $read -Mode 'clear' -Repo $Repo

        $entries = @($read.Entries)
        if (-not $AgentId) {
            # No agent named: an explicit clear-all, which is what a hub finishing
            # a solo turn wants when no other hub is registered.
            #
            # A delete, not a publish, so it is deliberately NOT routed through the
            # atomic-write owner (bead cl-common-2jz). A sharing violation on a
            # delete publishes nothing and destroys nothing: the record stays as
            # the previous valid one, no live hub can be made to look dead, and the
            # failure is loud (non-zero exit) rather than silent. Retrying belongs
            # on the rename, which REPLACES a record on every heartbeat.
            Remove-Item -LiteralPath $path -Force
            Write-Verdict -Payload ([ordered]@{
                    ok = $true; mode = 'clear'; repo = $Repo; removed = $true; cleared = @($entries).Count
                    note = 'every entry removed (no -AgentId given)'
                })
        }

        $remaining = @($entries | Where-Object { (Get-Optional $_ 'agentId') -ne $AgentId })
        if ($remaining.Count -eq @($entries).Count) {
            Write-Verdict -Payload ([ordered]@{
                    ok = $false; mode = 'clear'; repo = $Repo; agentId = $AgentId
                    reason = "no entry for $AgentId in '$Repo' (registered: $(Format-EntryList -Entries $entries))"
                }) -ExitCode 1
        }

        # A finishing tick may clear its PREDECESSOR only when that run is
        # terminal. "Predecessor" is a real distinction here: the caller clears
        # some id other than its own hub of record. A live peer is never cleared
        # this way - that is how one Hub's close-out deletes a working Hub.
        $clearingId = $AgentId
        $resolvedForClear = Resolve-HubOfRecord -Record $read -ExplicitHubId $HubAgentId -ClaimedAgentId $clearingId `
            -EnvId $env:SALMON_HUB_AGENT_ID -RepoName $Repo -MaxAge $MaxAgeMinutes -Grace $UnknownGraceMinutes
        $isPredecessor = $resolvedForClear.AgentId -and ($resolvedForClear.AgentId -ne $clearingId)
        if ($isPredecessor) {
            $targetEntry = $entries | Where-Object { (Get-Optional $_ 'agentId') -eq $clearingId } | Select-Object -First 1
            $targetVerdict = Test-Entry -Entry $targetEntry -MaxAge $MaxAgeMinutes -Grace $UnknownGraceMinutes
            if ($targetVerdict.State -eq 'live' -or ($targetVerdict.State -eq 'unknown' -and -not $Terminal)) {
                Write-Verdict -Payload ([ordered]@{
                        ok = $false; mode = 'clear'; repo = $Repo; agentId = $clearingId
                        verdict = 'predecessor-not-terminal'
                        predecessorState = $targetVerdict.State
                        hubOfRecord = $resolvedForClear.AgentId
                        reason = "$clearingId is not terminal in '$Repo' (state: $($targetVerdict.State) - $($targetVerdict.Reason)). A live peer is never cleared by a finishing tick; clear only a terminal predecessor (pass -Terminal to assert an unknown one). Nothing was removed."
                    }) -ExitCode 5
            }
        }

        $write = $null
        if ($remaining.Count -eq 0) {
            # Remove-Item, NOT the atomic publish, and deliberately left unretried
            # (bead cl-common-2jz). A delete is a REMOVAL, not a publish: it
            # publishes no new record, so a sharing violation here cannot lose
            # data and cannot make a LIVE hub look dead - the prior record simply
            # stays in place, which is the conservative outcome. The failure is
            # also loud (non-zero exit with the OS message) rather than silent, so
            # the caller retries the clear. The rename needed retrying because it
            # REPLACES a record every heartbeat; this runs once, at close-out.
            Remove-Item -LiteralPath $path -Force
        } else {
            $write = Write-RegistryAtomic -Path $path -Repo $Repo -Entries $remaining -Mode 'clear'
        }
        Write-Verdict -Payload ([ordered]@{
                ok = $true; mode = 'clear'; repo = $Repo; agentId = $AgentId; removed = $true
                remaining = $remaining.Count
                remainingAgentIds = if ($remaining.Count -gt 0) { Format-EntryList -Entries $remaining } else { $null }
                writeAttempts = if ($write) { $write.Attempt } else { $null }
            })
    }

    'Find' {
        # Identity first. A caller may hand us the repo name, a bare path, its
        # own worktree folder, or nothing at all (meaning "where I stand").
        $rawRepo = $Repo
        # A path claim is the caller saying "this is where I stand". Only then is
        # an identity scan legitimate: a bare name that simply misses must NOT be
        # answered with whatever repo the caller's cwd happens to resolve to.
        $pathClaim = [bool]($RepoPath) -or ($Repo -and ($Repo -match '[\\/:]'))
        $identity = $null
        if ($RepoPath) { $identity = Resolve-RepoIdentity -Path $RepoPath }
        if (-not $identity -and $Repo -and ($Repo -match '[\\/:]')) { $identity = Resolve-RepoIdentity -Path $Repo }
        if (-not $identity) { $identity = Resolve-RepoIdentity -Path (Get-Location).Path }

        $name = Get-RepoName -Repo $Repo -RepoPath $RepoPath
        if (-not $name -and $identity) { $name = $identity.Name }
        if (-not $name) {
            Write-Verdict -Payload ([ordered]@{
                    ok = $false; state = 'dead'; live = $false; repo = $rawRepo; hubCount = 0
                    reason = 'Find needs -Repo (a repo name, or a path inside the repo)'
                    note   = 'a path-like value must resolve to a git repository'
                }) -ExitCode 2
        }

        # Name-key lookup, then identity lookup. The second exists because the
        # first only works when the caller guessed the exact name, and a miss
        # used to read as "no hub here" - the licence to spawn a duplicate.
        $resolvedFrom = 'name'
        $read = Read-Registry -Name $name
        if ($pathClaim -and -not $read.Ok -and $read.Kind -eq 'absent') {
            $hit = Find-RegistryByIdentity -Identity $identity -Name $name
            if ($hit) {
                $read = $hit.Registry
                $name = $hit.Name
                $resolvedFrom = 'identity'
            }
        }
        if (-not $read.Ok) {
            $payload = [ordered]@{
                ok = $false; state = 'dead'; live = $false; repo = $name; requestedRepo = $rawRepo
                hubCount = 0; reason = $read.Reason
            }
            $known = Get-KnownRepos -MaxAge $MaxAgeMinutes -Grace $UnknownGraceMinutes
            if (@($known).Count -gt 0) {
                $payload.knownRepos = @($known)
                $payload.reason = ('{0}; live registries: {1} - if one of those is the repo you meant, ask for it by name' -f $read.Reason, ((@($known) | ForEach-Object { $_.repo }) -join ', '))
            }
            Write-Verdict -Payload $payload -ExitCode 1
        }

        $fold = Fold-Entries -Entries @($read.Entries) -MaxAge $MaxAgeMinutes -Grace $UnknownGraceMinutes
        $rep = $fold.Representative
        if ($null -eq $rep) {
            Write-Verdict -Payload ([ordered]@{
                    ok = $false; state = 'dead'; live = $false; repo = $name; hubCount = 0
                    reason = "hub record for '$name' exists but carries no entries"
                }) -ExitCode 1
        }
        $entry = $rep.Entry
        $verdict = $rep.Verdict
        $hubCount = @($fold.Hubs).Count

        # Which helper wrote this record, and did any entry come from an older
        # one? A record can keep a shape this helper understands while carrying
        # semantics it does not, so the version travels with the verdict.
        $recordHelperVersion = if ($null -eq (Get-Optional $read 'HelperVersion')) { 0 } else { [int](Get-Optional $read 'HelperVersion') }
        $staleWriters = @($fold.Hubs | Where-Object {
                $v = Get-Optional $_.Entry 'helperVersion'
                ($null -eq $v) -or ([int]$v -lt $script:HelperVersion)
            } | ForEach-Object { $_.AgentId })

        # One hub per repo is the RULE; a set is what the file can hold. So each
        # entry is classified: primary = anchored at the repo itself, secondary =
        # alive but standing somewhere else (a lane worktree, or a folder that is
        # not this repo). Secondaries are surfaced, never silently authoritative.
        $primaryIds = @()
        $secondaryIds = @()
        $hubRows = @()
        foreach ($h in $fold.Hubs) {
            $entryPath = Get-Optional $h.Entry 'repoPath'
            $entryIdentity = if ($entryPath) { Resolve-RepoIdentity -Path $entryPath } else { $null }
            $isPrimary = $false
            if ($entryIdentity) {
                if ($identity) {
                    $isPrimary = ($entryIdentity.MainRoot -ieq $identity.MainRoot) -and (-not $entryIdentity.IsWorktree)
                } else {
                    $isPrimary = (-not $entryIdentity.IsWorktree) -and ($entryIdentity.Name -ieq $name)
                }
            }
            $role = if ($isPrimary) { 'primary' } else { 'secondary' }
            if ($isPrimary) { $primaryIds += $h.AgentId } else { $secondaryIds += $h.AgentId }
            $hubRows += [ordered]@{
                agentId     = $h.AgentId
                machine     = Get-Optional $h.Entry 'machine'
                role        = $role
                state       = $h.Verdict.State
                ageMinutes  = $h.Verdict.AgeMinutes
                repoPath    = $entryPath
                helperVersion = Get-Optional $h.Entry 'helperVersion'
                heartbeatAt = Get-Optional $h.Entry 'heartbeatAt'
                busyUntil   = Get-Optional $h.Entry 'busyUntil'
            }
        }
        # No entry could be placed by path (an older record, or a Register that
        # carried no repoPath): the representative stands in as primary rather
        # than leaving the repo with no authority at all.
        if (@($primaryIds).Count -eq 0) {
            $primaryIds = @($rep.AgentId)
            for ($i = 0; $i -lt @($hubRows).Count; $i++) {
                if ($hubRows[$i].agentId -eq $rep.AgentId) {
                    $hubRows[$i].role = 'primary'
                    $secondaryIds = @($secondaryIds | Where-Object { $_ -ne $rep.AgentId })
                }
            }
        }

        # A duplicate hub is a finding in its own right, so it is never silent:
        # the count, every id, and who is primary travel with the verdict.
        $reason = $verdict.Reason
        if ($hubCount -gt 1) {
            $reason = ('{0} hubs registered ({1}); primary {2}; folded verdict {3} - {4}' -f `
                    $hubCount, (Format-EntryList -Entries @($fold.Hubs | ForEach-Object { $_.Entry })), `
                    ((@($primaryIds) -join ', ')), $fold.State, $verdict.Reason)
        }

        $payload = [ordered]@{
            ok             = ($fold.State -eq 'live')
            state          = $fold.State
            live           = ($fold.State -eq 'live')
            repo           = $name
            requestedRepo  = $rawRepo
            resolvedFrom   = $resolvedFrom
            hubCount       = $hubCount
            duplicate      = ($hubCount -gt 1)
            schemaVersion = $read.SchemaVersion
            schemaVersionOutdated = ($read.SchemaVersion -lt 2)
            recordHelperVersion = $recordHelperVersion
            helperVersionOutdated = ($recordHelperVersion -lt $script:HelperVersion)
            staleWriterAgentIds = @($staleWriters)
            primaryAgentId = (@($primaryIds) | Select-Object -First 1)
            secondaryAgentIds = @($secondaryIds)
            agentId        = $rep.AgentId
            machine        = Get-Optional $entry 'machine'
            repoPath       = Get-Optional $entry 'repoPath'
            trunk          = Get-Optional $entry 'trunk'
            heartbeatAt    = Get-Optional $entry 'heartbeatAt'
            busyUntil      = Get-Optional $entry 'busyUntil'
            ageMinutes     = $verdict.AgeMinutes
            hubs           = @($hubRows)
        }
        if ($reason) { $payload.reason = $reason }
        if ($read.SchemaVersion -lt 2) {
            $payload.note = "record is schemaVersion $($read.SchemaVersion): written by an older helper. It is read here as a one-entry set, but a v1 helper writing again would collapse co-registered hubs - re-register with the helper from a checkout at origin/<trunk>."
        } elseif ($recordHelperVersion -lt $script:HelperVersion) {
            $payload.note = "record was last written by helper v$recordHelperVersion and this copy is v$($script:HelperVersion): the presence and shape of its entries were judged by older semantics. Stale writers: $(if (@($staleWriters).Count -gt 0) { @($staleWriters) -join ', ' } else { 'none' }). Re-register from a checkout at origin/<trunk> to refresh it."
        }

        # 0 live, 3 UNKNOWN (exists but unrefreshed: verify, never duplicate), 1 dead.
        $code = switch ($fold.State) { 'live' { 0 } 'unknown' { 3 } default { 1 } }
        Write-Verdict -Payload $payload -ExitCode $code
    }

    'Version' {
        # The point of a version you can ASK for: a caller can distinguish "the
        # helper said no hub" from "a stale helper that could not see one".
        Write-Verdict -Payload ([ordered]@{
                ok            = $true
                mode          = 'version'
                helperVersion = $script:HelperVersion
                schemaVersion = 2
                path          = $PSCommandPath
                machine       = $Machine
                hubOfRecord   = '-HubAgentId -> $env:SALMON_HUB_AGENT_ID -> -AgentId (only when it already has an entry) -> live primary in the registry; nothing resolved is exit 4 no-hub-of-record (helper v4+)'
                note          = 'helperVersion is the SEMANTICS that answered you (identity resolution, roles, freshness, hub-of-record); schemaVersion is the record shape on disk. A stale checkout answers with an older helperVersion even when its output looks current.'
            })
    }

    'List' {
        if (-not (Test-Path -LiteralPath $Root)) {
            Write-Verdict -Payload ([ordered]@{ ok = $true; hubs = @(); note = "no registry at $Root" })
        }
        $rows = @()
        foreach ($file in Get-ChildItem -LiteralPath $Root -Filter '*.json' -File) {
            $name = $file.BaseName
            $read = Read-Registry -Name $name
            if (-not $read.Ok) {
                $rows += [ordered]@{ repo = $name; state = 'unknown'; live = $false; hubCount = 0; reason = $read.Reason }
                continue
            }
            $fold = Fold-Entries -Entries @($read.Entries) -MaxAge $MaxAgeMinutes -Grace $UnknownGraceMinutes
            $rep = $fold.Representative
            $rows += [ordered]@{
                repo       = $name
                state      = $fold.State
                live       = ($fold.State -eq 'live')
                hubCount   = @($fold.Hubs).Count
                agentId    = $rep.AgentId
                machine    = Get-Optional $rep.Entry 'machine'
                trunk      = Get-Optional $rep.Entry 'trunk'
                ageMinutes = $rep.Verdict.AgeMinutes
                hubs       = @($fold.Hubs | ForEach-Object {
                        [ordered]@{ agentId = $_.AgentId; state = $_.Verdict.State; ageMinutes = $_.Verdict.AgeMinutes }
                    })
            }
        }
        Write-Verdict -Payload ([ordered]@{ ok = $true; count = @($rows).Count; hubs = @($rows) })
    }
}
