#Requires -Version 7.0
<#
.SYNOPSIS
    Dispatch one supervised IQA worker as a Paseo background agent.

.DESCRIPTION
    Wraps the canonical bypass-mode worker dispatch documented in the
    iqa-mode skill's "Worker dispatch (bypass mode, supervised)" section.
    Resolves the Paseo CLI (PATH first, then the desktop app bundle),
    validates the brief and workdir, points OPENCODE_CONFIG at the
    no-approval config, appends a completion handshake to the worker prompt
    (one best-effort `paseo send` ping at the resolved parent, so finishes
    never go silent), and prints the background agent id on stdout
    (diagnostics go to the host stream).

.PARAMETER Brief
    Path to the worker task brief, conventionally
    <workdir>/.iqa-brief-<id>.md.

.PARAMETER Title
    Paseo agent title, conventionally "<issue-id> <short description>".

.PARAMETER Workdir
    Worker working directory (a dedicated git worktree for the task).

.PARAMETER NoApprovalsConfig
    OpenCode no-approval config file. Defaults to
    %USERPROFILE%\.paseo\iqa-no-approvals.json, then the copy shipped at
    assets/no-approvals.json beside this skill.

.PARAMETER ParentAgentId
    Paseo parent linkage for the worker. 'auto' (default) links the worker
    as a child of the current agent: an inherited PASEO_AGENT_ID env var
    wins, else the running agent whose registered cwd equals (or is the
    nearest ancestor of) this process's cwd is used. Pass an explicit agent
    id to link to a known parent, or 'none' to dispatch unparented.
    Unresolvable parentage warns and proceeds — it never fails a dispatch.

.PARAMETER Provider
    Paseo provider triple (<cli>/<provider-id>/<model-id>). Defaults to
    opencode/opencode-go/deepseek-v4.1-flash - the fleet default
    worker model. Audit runs of every kind (Complete, IQA, Paseo, attached
    or detached) always stay on this default: when the pool is exhausted,
    rotate/rescue keys per the credential-rescue runbook and re-dispatch,
    never swap model families.

    The `--mode` argument is derived from this provider's own mode surface
    (Get-WorkerModeArgument): OpenCode takes `build`, the DeepSeek Harness
    and the OpenRouter gateway take no `--mode` at all, and a provider with
    no known rule fails closed instead of being guessed at.

.PARAMETER Pool
    Registry pool id, or 'auto' (the default) to walk the pools by priority -
    Gemini first, so its free daily allowance is spent before anything paid is
    touched, then opencode-go. A spent or busy pool simply falls through.

.PARAMETER Role
    WORK role: recon | review | fix | code | refactor | simple | merge (or 'any' for the pool default).
    The work role selects the route AND the effort from the pool's workRoles
    map - opencode-go runs recon and review at xhigh on Muse Spark,
    code/fix/refactor at high, and simple (small, well-scoped tasks) at
    medium. Drop fix/code to Default/Medium only when the
    task is simple enough to justify it, and record why in the brief; never
    downgrade merges or audit recons.

    `merge` is the ONE work role admitted at a git checkout's repo root by
    design: landing a built branch on its integration trunk is exactly a
    merge worker's job, so it needs neither a lane checkout nor the
    -AllowTrunkWrite exemption (cl-common-hql). Every other writing role
    stays refused at the trunk.

.PARAMETER DispatchMode
    opencode-go key-walk: single-active (default, first free key wins -
    today's behavior, byte-identical) | waterfall (fill key[i] to its
    per-key cap before key[i+1]) | round-robin (one agent per eligible
    key, cycling). Opt-in per dispatch; omitted stays single-active.
    Forwarded to the spawn-capacity gate's Acquire. Unknown values throw
    (fail-closed). Modes engage on opencode-go only and refuse while the
    credential-rescue watch state reads 'watching'.

.PARAMETER MaxDispatchAttempts
    Dispatch attempts before giving up (default 2). A failed attempt releases
    its slot as a provider error and re-acquires from the next pool, which is
    how a spent Gemini daily allowance hands its work to opencode-go.

.PARAMETER Thinking
    Thinking option ID passed to paseo as `--thinking`. Valid IDs are
    model-specific — list them with `paseo provider models <provider> --json`
    and read `thinkingOptionIds`. For example opencode/muse-spark-1.3 supports
    default|minimal|low|medium|high|xhigh (there is no `max` on that route).
    Defaults to the capacity slot's resolved effort (`xhigh` when no slot
    applies) so existing callers are unaffected; pass an ID the chosen
    model actually supports, or the dispatch will fail.

.PARAMETER WorkspaceId
    Paseo workspace the worker is bound to. Omit (the default) to bind to the
    workdir: the path's existing workspace record is REUSED when one exists
    (a re-run must never mint a duplicate - see Get-PathWorkspaceRecords), and
    only a path with no record gets a new local workspace rooted at -Workdir,
    which is almost always what you want. `-cwd` alone does NOT bind the workspace: an agent-scoped
    dispatch otherwise inherits the CALLER's workspace, leaving the worker's
    session cwd on the dispatcher's checkout - for an interactive IQA
    session that is the repo's primary checkout, which normally holds
    another lane's uncommitted work. Pass an explicit id only to reuse an
    existing workspace (e.g. a second worker on the same lane).

.PARAMETER SkipPreflight
    Skip the provider canary. By default, an opencode/* provider is
    health-checked with scripts/Test-OpencodeProvider.ps1 BEFORE dispatch —
    a dead credential (e.g. an exhausted opencode-go pool key) aborts the
    dispatch instead of spawning a worker that dies on its first turn.
    Non-opencode providers have no canary and are dispatched unchecked.

.PARAMETER AllowTrunkWrite
    Permit ONE writing worker to start in a git checkout's repo root. The
    default is refusal (see Test-TrunkWritingRole / Resolve-TrunkWriteGuard);
    every exemption prints a TRUNK-WRITE-EXEMPTION warning and appends an audit
    line, and the dispatch fails closed if it cannot be logged.

.PARAMETER TrunkWriteAuditLog
    Path of the exemption audit trail (JSONL). Defaults to
    %LOCALAPPDATA%\cl-common\logs\trunk-write-exemptions.jsonl.

.OUTPUTS
    System.String. The background agent id.

.EXAMPLE
    $id = ./run-iqa-worker.ps1 -Brief ../../../.worktrees/iqa-2-4/.iqa-brief-2-4.md `
        -Title '2-4 bypass runbooks' -Workdir ../../../.worktrees/iqa-2-4
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Brief,

    [Parameter(Mandatory = $true)]
    [string]$Title,

    [Parameter(Mandatory = $true)]
    [string]$Workdir,

    [string]$NoApprovalsConfig = '',

    [string]$ParentAgentId = 'auto',

    [string]$Provider = 'opencode/opencode-go/deepseek-v4.1-flash',

    # Thinking option ID for the worker's model (paseo `--thinking`). Valid IDs
    # are model-specific - list them with
    #   paseo provider models <provider> --json
    # e.g. `opencode-go/deepseek-v4.1-flash` supports
    # default|minimal|low|medium|high|xhigh.
    # Defaults to `xhigh` for the default model; pass an ID the chosen model
    # actually supports, or the dispatch will fail.
    [string]$Thinking = 'low',

    [string]$WorkspaceId = '',

    [switch]$SkipPreflight,

    # Spawn-capacity gate (Skills/agent-spawn-capacity). Acquire a slot before
    # the dispatch and Register the returned agent id after it, so the key-set
    # cap, the model failover, the priority walk, and the provider-error log all
    # apply to IQA and IQA-Beads workers. -SkipCapacity bypasses the gate
    # entirely (nothing is then recorded for the spawn).
    [string]$Pool = 'auto',

    # WORK role, not a route: it selects both the route and the effort from the
    # pool's workRoles map (recon and review run at the highest effort).
    [ValidateSet('any', 'recon', 'review', 'fix', 'code', 'refactor', 'simple', 'merge')]
    [string]$Role = 'any',

    [ValidateSet('single-active', 'waterfall', 'round-robin')]
    [string]$DispatchMode = 'single-active',

    [switch]$IgnoreCapacity,

    [switch]$SkipCapacity,

    # Dispatch attempts before giving up. On a failure the slot is released as a
    # provider error and the work is re-acquired from the next pool by priority -
    # which is how a spent Gemini daily allowance hands its work to opencode-go.
    [ValidateRange(1, 4)]
    [int]$MaxDispatchAttempts = 2,

    # Escapes the trunk-write guard for ONE dispatch. The default is refusal:
    # a WRITING role may not start in a git checkout's repo root. Every use
    # writes an audit line and a loud warning - a silent override would
    # recreate the bug this guard exists to stop.
    [switch]$AllowTrunkWrite,

    # Where the exemption audit trail is appended (JSONL). Defaults to
    # %LOCALAPPDATA%\cl-common\logs\trunk-write-exemptions.jsonl.
    [string]$TrunkWriteAuditLog = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-GoPoolKeyValue {
    <#
    .SYNOPSIS
        Reads a pool key's VALUE (OPENCODE_GO<n>_KEY) from Machine, User, then
        Process scope. The value is only compared or injected, never printed.
    #>
    param([string]$Name)
    foreach ($scope in @('Machine', 'User', 'Process')) {
        try { $value = [Environment]::GetEnvironmentVariable($Name, $scope) }
        catch { $value = $null }
        if (-not [string]::IsNullOrWhiteSpace($value)) { return [string]$value }
    }
    return ''
}

function Find-GoKeyLabel {
    <#
    .SYNOPSIS
        Maps a key VALUE back to its pool label (GO<n>), or '' when unmapped.
    #>
    param(
        [string]$Value,
        [scriptblock]$PoolLookup = $null
    )
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    for ($n = 1; $n -le 12; $n++) {
        $name = "OPENCODE_GO${n}_KEY"
        $poolValue = if ($PoolLookup) { & $PoolLookup $name } else { Get-GoPoolKeyValue -Name $name }
        if ($poolValue -eq $Value) { return "GO$n" }
    }
    return ''
}

function Get-CanaryKeyLabel {
    <#
    .SYNOPSIS
        Reads the exercised key's label from the canary's summary line
        (`canary: key GO3 (seam) ...`). Labels only - never a key value.
    #>
    param([string]$Text)
    if ($Text -match 'canary: key (GO\d+) \(') { return $Matches[1] }
    return ''
}

function Get-PreflightFailureAdvice {
    <#
    .SYNOPSIS
        Explains a failed canary. A session holding a DIFFERENT key than the one
        the machine is using must not be told to rotate a healthy credential.
    #>
    param(
        [string]$TestedLabel = '',
        [string]$SessionLabel = ''
    )
    if ($TestedLabel -and $SessionLabel -and $TestedLabel -ne $SessionLabel) {
        return "preflight tested $TestedLabel (active) but this session's environment holds $SessionLabel; restart the host or pass -SkipPreflight only if you understand the mismatch."
    }
    return 'Rotate the credential (credential-rescue Runbook A), pass -Provider with a healthy provider, or -SkipPreflight to force.'
}

function Get-PreflightFailureMessage {
    <#
    .SYNOPSIS
        The single dispatch-refusal message: which key failed, and whether the
        session's inherited key is even the same one the canary measured.
    #>
    param(
        [string]$Model,
        [string]$CanaryOutput,
        [string]$SessionKeyValue,
        [scriptblock]$PoolLookup = $null
    )
    $tested = Get-CanaryKeyLabel -Text $CanaryOutput
    $session = Find-GoKeyLabel -Value $SessionKeyValue -PoolLookup $PoolLookup
    $advice = Get-PreflightFailureAdvice -TestedLabel $tested -SessionLabel $session
    return "Provider preflight failed for '$Model' — refusing to dispatch a worker that would die on its first turn. $advice"
}

function Get-ServiceLimitFailureAdvice {
    <#
    .SYNOPSIS
        Distinguishes a Go usage-limit message from the long-lived opencode
        service (which caches the credential it booted with) from a real
        credential verdict, so it is never read as proof about the key.
    #>
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    if ($Text -notmatch 'usage limit|rate limit|rate_limit|quota|exceeded|429') { return '' }
    if ($Text -notmatch 'Go (?:usage|limit)|go usage|opencode-go|Go usage') { return '' }
    return "This limit came from the long-lived opencode service, which caches the key it booted with - it is NOT proof about the credential. Re-canary with Test-OpencodeProvider.ps1 (which now runs --standalone), or restart the service, before rotating a key."
}

function Resolve-PaseoCli {
    <#
    .SYNOPSIS
        Finds the Paseo CLI: PATH first, then the desktop app's bundled shim.
    #>
    $command = Get-Command paseo -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }

    $roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, (Join-Path $env:LOCALAPPDATA 'Programs')) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    foreach ($root in $roots) {
        $candidate = Join-Path $root 'Paseo/resources/bin/paseo.cmd'
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    return ''
}

function Resolve-NoApprovalsConfig {
    <#
    .SYNOPSIS
        Resolves the OpenCode bypass config: explicit path, machine copy, then
        the copy shipped beside this skill.
    #>
    param(
        [string]$Override,
        [string]$ScriptRoot
    )

    $candidates = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($Override)) { $candidates.Add($Override) }
    if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        $candidates.Add((Join-Path (Join-Path $env:USERPROFILE '.paseo') 'iqa-no-approvals.json'))
    }
    $candidates.Add((Join-Path (Join-Path (Split-Path -Parent $ScriptRoot) 'assets') 'no-approvals.json'))

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    throw 'No no-approval config found. Copy assets/no-approvals.json to %USERPROFILE%\.paseo\iqa-no-approvals.json, or pass -NoApprovalsConfig.'
}

function Resolve-SelfAgent {
    <#
    .SYNOPSIS
        Best-effort identity of the running Paseo agent that owns this
        process: the unique running agent whose registered cwd equals
        $CallerCwd, else the unique nearest-ancestor match. Returns the
        agent record (id + cwd) or $null when zero or several match.
    .DESCRIPTION
        paseo run links ParentAgentId only when PASEO_AGENT_ID is in the
        dispatching process env. Providers the daemon does not inject that
        variable into (e.g. the Devin ACP provider) must discover it here.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Paseo,
        [Parameter(Mandatory = $true)][string]$CallerCwd
    )

    $raw = & $Paseo ls --json 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $raw) { return $null }
    try { $agents = @($raw | Out-String | ConvertFrom-Json) }
    catch { return $null }

    $normalize = {
        param($p)
        if ($null -eq $p) { return '' }
        return "$p".Trim().TrimEnd('\', '/').ToLowerInvariant()
    }
    $self = & $normalize $CallerCwd
    $running = @($agents | Where-Object {
            $_.status -eq 'running' -and -not [string]::IsNullOrWhiteSpace($_.cwd)
        })

    $exact = @($running | Where-Object { (& $normalize $_.cwd) -eq $self })
    $candidates = $exact
    if ($candidates.Count -eq 0) {
        # Caller is in a subdirectory/worktree of the agent's registered cwd.
        $ancestors = @($running | Where-Object {
                $candidate = & $normalize $_.cwd
                $candidate -and $self.StartsWith("$candidate\")
            })
        $best = @($ancestors | Sort-Object { (& $normalize $_.cwd).Length } -Descending)
        if ($best.Count -gt 1 -and ((& $normalize $best[0].cwd).Length -eq (& $normalize $best[1].cwd).Length)) {
            return $null
        }
        $candidates = @($best | Select-Object -First 1)
    }

    if ($candidates.Count -eq 1) { return $candidates[0] }
    if ($candidates.Count -eq 0) { return $null }

    # Paseo stamps a child's registered cwd with its parent's cwd, so
    # previously dispatched children collide here. The real session agent is
    # the one that is not itself a child — drop candidates with a parent.
    $roots = [System.Collections.Generic.List[object]]::new()
    foreach ($candidate in $candidates) {
        $detail = & $Paseo inspect $candidate.id --json 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $detail) { continue }
        try { $parsed = ($detail | Out-String) | ConvertFrom-Json } catch { continue }
        if ([string]::IsNullOrWhiteSpace($parsed.ParentAgentId)) { $roots.Add($candidate) }
    }
    if ($roots.Count -eq 1) { return $roots[0] }
    return $null
}

function Test-TrunkWritingRole {
    <#
    .SYNOPSIS
        Does this work role WRITE to the checkout it is dispatched into?

    .DESCRIPTION
        Derived from the pool workRoles table (Skills/agent-spawn-capacity/
        assets/agent-capacity.json), not invented here:

          * fix | code | refactor | simple | merge -> writing (they edit and
            commit; merge lands a built branch on the trunk);
          * recon | review                  -> reading (a census or a review
            legitimately needs the trunk itself);
          * anything else, including 'any'  -> writing, because an undeclared
            role carries no read-only intent. 'any' is this script's default,
            so the default is refusal and a caller that really only reads says
            so with -Role recon or -Role review. Fail closed.

        Writing at the trunk is a separate question: Test-TrunkMergeRole says
        whether the trunk is exactly where this writer belongs.
    #>
    param([AllowEmptyString()][string]$Role)

    $value = if ($null -eq $Role) { '' } else { $Role.Trim().ToLowerInvariant() }
    if (@('fix', 'code', 'refactor', 'simple', 'merge') -contains $value) { return $true }
    if (@('recon', 'review') -contains $value) { return $false }
    return $true
}

function Test-TrunkMergeRole {
    <#
    .SYNOPSIS
        May this work role write at a git checkout's REPO ROOT by design?

    .DESCRIPTION
        Only 'merge' may (cl-common-hql, measured 2026-11-02 22:46): a merge
        worker's job is to land a built branch on the integration trunk FROM
        the repo's trunk checkout, so refusing it there was correct for a lane
        and wrong for a merge - it forced every merge onto the -AllowTrunkWrite
        exemption hatch, which is meant to be exceptional and audited.

        The admission is by ROLE, not by a flag: a merge dispatch at the trunk
        writes no exemption record, and passing -AllowTrunkWrite to a merge
        role does not manufacture one either. Every other role returns false
        here and keeps the refusal (or the exemption) it has today.
    #>
    param([AllowEmptyString()][string]$Role)

    $value = if ($null -eq $Role) { '' } else { $Role.Trim().ToLowerInvariant() }
    return ($value -eq 'merge')
}

function Test-TrunkCheckoutPath {
    <#
    .SYNOPSIS
        Is this directory the repo root of a git checkout (as opposed to a
        .worktrees/<name> lane checkout)?

    .DESCRIPTION
        The brief's predicate, measured rather than pattern-matched on the
        caller's string: the resolved directory contains a `.git` entry AND it
        is not inside a `.worktrees` segment.

        A lane worktree also contains `.git` (a file pointing at the admin
        dir), so "contains .git" alone cannot separate the two - the
        `.worktrees` segment is what identifies a lane. Resolution is done by
        Resolve-Path first (case, trailing separator and `.`/`..` collapse) so
        `E:\repos\cl-common\`, `E:\repos\cl-common\.` and
        `E:\repos\cl-common\NOWHERE\..` are the same directory here.
    #>
    param([AllowEmptyString()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }

    $resolved = ''
    $existing = Resolve-Path -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($existing) { $resolved = $existing.Path }
    else {
        try { $resolved = [System.IO.Path]::GetFullPath($Path) } catch { return $false }
    }

    if (-not (Test-Path -LiteralPath $resolved -PathType Container)) { return $false }
    if (-not (Test-Path -LiteralPath (Join-Path $resolved '.git'))) { return $false }

    $segments = @(($resolved -replace '/', '\').Split('\') | Where-Object { $_ -ne '' })
    if ($segments -contains '.worktrees') { return $false }
    return $true
}

function Resolve-TrunkWriteGuard {
    <#
    .SYNOPSIS
        The trunk-write decision for one dispatch: refuse, exempt, or allow.

    .DESCRIPTION
        Measured defect (cl-common-9ep, 2026-11-02/03, twice in 40 minutes):
        while a merge worker held the trunk on E:\repos\cl-common, a writing
        agent committed in that same checkout on top of the merge (736bc142 ->
        b297bdb9/ee0a0511; 59da26ab -> 6eac300f/138eba4c/0b5a3e74). The merge
        worker's own push then said "Everything up-to-date" because the trunk
        tip had moved under it. Nothing prevented the write.

        Refusal is the default for a writing role whose workdir is a repo root.
        -AllowTrunkWrite permits it and returns the exemption text the caller
        must WARN with and LOG (Write-TrunkWriteExemption) - an exemption that
        leaves no trace is the original bug with extra steps.

        The 'merge' role is the exception, and it is an exception BY ROLE
        rather than by flag (cl-common-hql): a merge worker lands a built
        branch on the trunk from the trunk checkout, which is exactly what the
        trunk is for. It is admitted with Refuse=$false, Exempt=$false and no
        audit line, so a routine merge never pollutes the exemption trail; an
        explicit -AllowTrunkWrite on a merge role still writes nothing.

    .OUTPUTS
        Hashtable: Refuse, Exempt, IsTrunkCheckout, IsWritingRole,
        IsMergeRole, RepoRoot, Role, Cwd, AgentId, Title, Timestamp, Message.
    #>
    param(
        [Parameter(Mandatory)][string]$WorkdirPath,
        [AllowEmptyString()][string]$Role = 'any',
        [AllowEmptyString()][string]$Title = '',
        [bool]$AllowTrunkWrite = $false,
        [AllowEmptyString()][string]$AgentId = ''
    )

    $resolved = $WorkdirPath
    $existing = Resolve-Path -LiteralPath $WorkdirPath -ErrorAction SilentlyContinue
    if ($existing) { $resolved = $existing.Path }

    $isWriting = Test-TrunkWritingRole -Role $Role
    $isMerge = Test-TrunkMergeRole -Role $Role
    $isTrunk = Test-TrunkCheckoutPath -Path $resolved
    $agent = if (-not [string]::IsNullOrWhiteSpace($AgentId)) {
        [string]$AgentId
    }
    elseif (-not [string]::IsNullOrWhiteSpace($env:PASEO_AGENT_ID)) {
        [string]$env:PASEO_AGENT_ID
    }
    else { 'unknown' }
    $label = if ([string]::IsNullOrWhiteSpace($Title)) { '(untitled)' } else { $Title }
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

    $decision = @{
        Refuse          = $false
        Exempt          = $false
        IsTrunkCheckout = $isTrunk
        IsWritingRole   = $isWriting
        IsMergeRole     = $isMerge
        RepoRoot        = $resolved
        Role            = $Role
        Cwd             = $resolved
        AgentId         = $agent
        Title           = $label
        Timestamp       = $stamp
        Message         = ''
    }

    if (-not $isTrunk) { return $decision }

    # The merge role lands a branch ON the trunk from the trunk checkout: that
    # is its job, not an exemption. Checked BEFORE -AllowTrunkWrite so a merge
    # dispatch never manufactures an exemption record, flag or no flag.
    if ($isMerge) { return $decision }

    if (-not $isWriting) { return $decision }

    if ($AllowTrunkWrite) {
        $decision.Exempt = $true
        $decision.Message = "TRUNK-WRITE-EXEMPTION: writing role '$Role' for task '$label' is starting IN THE REPO ROOT '$resolved' (agent $agent, $stamp). Exempted by -AllowTrunkWrite: this worker may commit on the trunk and race a merge worker's push. The exemption is appended to the audit log."
        return $decision
    }

    $decision.Refuse = $true
    $decision.Message = "TRUNK-WRITE-REFUSED: writing role '$Role' for task '$label' would run in the repo root '$resolved', a git checkout holding the trunk. A writing worker must run in its own lane checkout at '$resolved\.worktrees\<name>'. Pass -Workdir <repo>\.worktrees\<name>; if the trunk is genuinely what this worker needs, dispatch a reading role (-Role recon or -Role review), dispatch a MERGE worker with -Role merge (admitted at the trunk by design, no exemption needed), or pass -AllowTrunkWrite to exempt this one dispatch (warned and logged)."
    return $decision
}

function Write-TrunkWriteExemption {
    <#
    .SYNOPSIS
        Appends one JSONL audit line for an -AllowTrunkWrite exemption.

    .DESCRIPTION
        The line carries the agent id, the role, the cwd, the task title and a
        UTC timestamp - the four facts needed to answer "who wrote to the
        trunk, and why was it allowed?". Append-only; a second exemption adds
        a second line.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Decision
    )

    $directory = Split-Path -Parent $Path
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $entry = [ordered]@{
        event     = 'trunk-write-exemption'
        timestamp = [string]$Decision['Timestamp']
        agentId   = [string]$Decision['AgentId']
        role      = [string]$Decision['Role']
        cwd       = [string]$Decision['Cwd']
        title     = [string]$Decision['Title']
    }
    $line = $entry | ConvertTo-Json -Compress
    Add-Content -LiteralPath $Path -Value $line -Encoding utf8
    return $line
}

if (-not (Test-Path -LiteralPath $Brief -PathType Leaf)) {
    throw "Task brief not found: $Brief"
}
if (-not (Test-Path -LiteralPath $Workdir -PathType Container)) {
    throw "Worker workdir not found: $Workdir"
}

$briefPath = (Resolve-Path -LiteralPath $Brief).Path
$workdirPath = (Resolve-Path -LiteralPath $Workdir).Path
$reportPath = Join-Path $workdirPath '.iqa-report.md'

# Trunk-write guard (cl-common-9ep). Runs BEFORE anything is spawned and before
# a capacity slot is taken: a writing role may not start in a git checkout's
# repo root, because that write lands on top of whatever a merge worker is
# pushing and the merge worker's own `git push` then reports "Everything
# up-to-date" while the trunk tip has moved (measured twice on 2026-11-02/03).
# A reading role (recon/review) may still run there, and the merge role is
# admitted BY DESIGN (cl-common-hql): landing a branch on the trunk from the
# trunk checkout is a merge worker's job, so it needs no exemption and writes
# no audit line. -AllowTrunkWrite is the one escape hatch for every other
# writing role, and it always warns AND appends an audit line - an exemption
# with no trace is the original bug with extra steps.
$trunkAuditLog = if (-not [string]::IsNullOrWhiteSpace($TrunkWriteAuditLog)) {
    $TrunkWriteAuditLog
}
elseif (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
    Join-Path $env:LOCALAPPDATA 'cl-common\logs\trunk-write-exemptions.jsonl'
}
else {
    Join-Path ([System.IO.Path]::GetTempPath()) 'cl-common\logs\trunk-write-exemptions.jsonl'
}
$guardAgentId = if ($ParentAgentId -and $ParentAgentId -notin @('auto', 'none')) { $ParentAgentId } else { '' }
$trunkGuard = Resolve-TrunkWriteGuard -WorkdirPath $workdirPath -Role $Role -Title $Title `
    -AllowTrunkWrite:$AllowTrunkWrite.IsPresent -AgentId $guardAgentId
if ($trunkGuard.Refuse) {
    throw $trunkGuard.Message
}
if ($trunkGuard.Exempt) {
    Write-Warning $trunkGuard.Message
    Write-Host $trunkGuard.Message -ForegroundColor Yellow
    try {
        $auditLine = Write-TrunkWriteExemption -Path $trunkAuditLog -Decision $trunkGuard
        Write-Host "Trunk-write exemption logged to $trunkAuditLog" -ForegroundColor Yellow
    }
    catch {
        # Fail closed: an exemption nobody can audit is a silent override.
        throw "TRUNK-WRITE-EXEMPTION-UNLOGGED: -AllowTrunkWrite was passed but the audit line could not be written to '$trunkAuditLog' ($($_.Exception.Message)). Refusing to start an unaudited trunk write."
    }
}

$paseo = Resolve-PaseoCli
if (-not $paseo) {
    throw 'Paseo CLI not found on PATH or in the desktop app bundle (resources/bin/paseo.cmd).'
}

$configPath = Resolve-NoApprovalsConfig -Override $NoApprovalsConfig -ScriptRoot $PSScriptRoot

function Resolve-AgentKeyEnv {
    <#
    .SYNOPSIS
        The extra `--env` pairs one agent needs for a keyed pool.
    .DESCRIPTION
        A keyed pool (Gemini, opencode-go) has several accounts, each with its
        own budget, but the CLI reads only one variable name. So the selected
        key's value is bridged into THIS agent's own variable - never a global
        override - which is what keeps two concurrent agents on two different
        keys.

        The bridge variable is declared by the pool's `bridgeEnv`. It is NOT
        defaulted for arbitrary pools: an absent bridge is a hard failure except
        for the legacy Gemini pool, because injecting an OpenCode key into
        GEMINI_API_KEY would silently leave the agent on the machine-pinned key.

        The value is read here and nowhere else. It is never printed, never
        written to a log, and is redacted out of any text that reaches the error
        log, so a provider message echoing the key cannot leak it.
    #>
    param([Parameter(Mandatory)]$Slot)

    $empty = @{ Pairs = @(); Value = ''; KeyName = '' }
    if ($null -eq $Slot -or [string]::IsNullOrWhiteSpace([string](Get-Prop $Slot 'KeyEnv' ''))) { return $empty }

    $keyName = [string]$Slot.KeyEnv
    $scope = if ([string](Get-Prop $Slot 'KeyScope' '')) { [string]$Slot.KeyScope } else { 'Machine' }
    $value = ''
    foreach ($candidate in @($scope, 'Machine', 'User', 'Process') | Select-Object -Unique) {
        $value = [Environment]::GetEnvironmentVariable($keyName, $candidate)
        if (-not [string]::IsNullOrWhiteSpace($value)) { break }
    }
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "Key '$keyName' is registered for pool '$([string](Get-Prop $Slot 'Pool' ''))' but has no value in any scope; refusing to dispatch an unauthenticated agent. Set the Machine-scope variable and retry."
    }

    $pool = [string](Get-Prop $Slot 'Pool' '')
    $provider = [string](Get-Prop $Slot 'Provider' '')
    $bridge = [string](Get-Prop $Slot 'BridgeEnv' '')
    if ([string]::IsNullOrWhiteSpace($bridge)) {
        # Gemini is the one legacy keyed pool whose CLI reads GEMINI_API_KEY and
        # whose registry row may omit bridgeEnv. Every other keyed pool MUST
        # declare its bridge explicitly: silently falling back to
        # GEMINI_API_KEY would inject an OpenCode key into a variable OpenCode
        # never reads, and the agent would quietly run on the machine-pinned
        # key instead of the selected one.
        if ($pool -eq 'gemini' -or $provider -match '^gemini/') {
            $bridge = 'GEMINI_API_KEY'
        }
        else {
            throw "Pool '$pool' selected key '$keyName' but declares no bridgeEnv; refusing to inject it into GEMINI_API_KEY. Set the pool's bridgeEnv (opencode-go: OPENCODE_GO_KEY) in agent-capacity.json and retry."
        }
    }
    return @{ Pairs = @("$bridge=$value"); Value = $value; KeyName = $keyName; BridgeEnv = $bridge }
}

function Get-WorkerModeArgument {
    <#
    .SYNOPSIS
        The `--mode` argument this dispatch must pass, derived from what the
        selected provider accepts - never hardcoded.

    .DESCRIPTION
        Paseo forwards `--mode` verbatim to the provider, so the mode is a
        property of the provider, not of the dispatcher:

          * OpenCode exposes build|plan, so `--mode build` is the bypass-mode
            worker agent this skill documents.
          * The DeepSeek Harness (and the OpenRouter ACP gateway) exposes NO
            modes, so ANY --mode is rejected before the first turn:
                Invalid mode build for provider deepseek-harness
            The argument must be omitted entirely on those routes.
          * Gemini and Codex expose their own mode sets and do not have
            `build`; each takes the mode its registry route declares.

        Measured 2026-11-02 with `paseo provider inspect <provider>` (the
        `modes` list); the per-route `mode` values in
        Skills/agent-spawn-capacity/assets/agent-capacity.json agree with this
        table. A harness this table does not know is a hard failure: guessing
        a mode is the exact bug this function removes.

    .PARAMETER Provider
        The provider string handed to `paseo run --provider`, optionally with
        its model: `<harness>` or `<harness>/<model>` (model ids may carry
        further slashes, e.g. openrouter/deepseek/deepseek-chat).

    .OUTPUTS
        Hashtable: Harness, Mode ('' when the argument is omitted), Args (the
        tokens to splat, empty when omitted) and Summary (the one-line
        decision and its reason, printed at dispatch time).
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Provider)

    $value = if ($null -eq $Provider) { '' } else { $Provider.Trim() }
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw 'Cannot choose a dispatch mode: no provider was given. Pass -Provider <cli>/<provider>/<model> (e.g. opencode/opencode-go/deepseek-v4.1-flash).'
    }
    # Only the first segment is the harness; model ids may contain slashes.
    $harness = ($value -split '/', 2)[0].ToLowerInvariant()

    $rules = @{
        'opencode'         = @{ Mode = 'build'; Why = 'modes: build|plan' }
        'opencode-go'      = @{ Mode = 'build'; Why = 'OpenCode alias, modes: build|plan' }
        'deepseek-harness' = @{ Mode = ''; Why = 'exposes no modes' }
        'openrouter'       = @{ Mode = ''; Why = 'exposes no modes' }
        'gemini'           = @{ Mode = 'yolo'; Why = 'modes: default|autoEdit|yolo|plan' }
        'codex'            = @{ Mode = 'full-access'; Why = 'modes: auto|auto-review|full-access' }
        'devin'            = @{ Mode = 'bypass'; Why = 'its registry routes declare bypass' }
    }

    if (-not $rules.ContainsKey($harness)) {
        throw "MODE-RULE-UNKNOWN: no dispatch mode rule for provider '$value' (harness '$harness'). Refusing to guess a mode - list what it accepts with 'paseo provider inspect $harness' (its modes array), then add that harness to Get-WorkerModeArgument."
    }

    $rule = $rules[$harness]
    $mode = [string]$rule.Mode
    if ([string]::IsNullOrWhiteSpace($mode)) {
        return @{
            Harness = $harness
            Mode    = ''
            Args    = @()
            Summary = "Mode: (omitted - $harness $($rule.Why))"
        }
    }
    return @{
        Harness = $harness
        Mode    = $mode
        Args    = @('--mode', $mode)
        Summary = "Mode: $mode ($harness - $($rule.Why))"
    }
}

function Select-PathWorkspaceRecords {
    <#
    .SYNOPSIS
        The workspace records bound to exactly this path.
    .DESCRIPTION
        Split out from Get-PathWorkspaceRecords so the matching rule is provable
        without a daemon: a record belongs to a path when its cwd equals the path
        after trimming trailing separators, folding separators and lowercasing.
        A sibling path (.worktrees/merge-84m-b) never matches, because the
        comparison is equality, not a prefix.
    #>
    param(
        [object[]]$Rows = @(),
        [Parameter(Mandatory)][string]$Path
    )

    $normalize = {
        param($p)
        if ($null -eq $p) { return '' }
        return ("$p".Trim().TrimEnd('\', '/') -replace '/', '\').ToLowerInvariant()
    }
    $target = & $normalize $Path
    return @($Rows | Where-Object { $_.cwd -and (& $normalize $_.cwd) -eq $target })
}

function Get-PathWorkspaceRecords {
    <#
    .SYNOPSIS
        The Paseo workspace records whose cwd is exactly this checkout.
    .DESCRIPTION
        Paseo binds a workspace to a path, and a path can end up with MANY
        workspace records - every `--new-workspace local` dispatch mints one, so
        a retry loop multiplies them (measured 2026-11-02: six active records on
        E:\Repos\cl-common\.worktrees\merge-84m). Once there is more than one,
        the daemon cannot tell which record is live and OpenCode never reaches
        readiness for that location:

            OpenCode location <path> did not activate within 30000ms

        This is the measurement half of the dispatcher's reuse-or-fail guard;
        Resolve-WorkspaceDispatchPlan is the decision. It never throws: a dead
        or absent CLI yields an empty set so the decision falls back to its
        no-record branch instead of crashing the dispatch.
    .OUTPUTS
        Object[] of { workspaceId, name, cwd, isolation } - empty when the CLI is
        unavailable or the path has no records.
    #>
    param(
        [Parameter(Mandatory)][string]$Paseo,
        [Parameter(Mandatory)][string]$Path
    )

    $raw = $null
    try { $raw = & $Paseo workspace ls --json 2>$null }
    catch { return @() }
    if ($LASTEXITCODE -ne 0 -or -not $raw) { return @() }
    try { $rows = @($raw | Out-String | ConvertFrom-Json) }
    catch { return @() }

    return @(Select-PathWorkspaceRecords -Rows $rows -Path $Path)
}

function Resolve-WorkspaceDispatchPlan {
    <#
    .SYNOPSIS
        What the dispatcher may do after a failed `paseo run`: reuse the
        existing workspace for the path, mint one (only when none exists), or
        fail ONCE, named, with the duplicate count.

    .DESCRIPTION
        The bug this removes: every retry passed `--new-workspace local`, so a
        failing location minted another workspace record on each attempt. That
        is create-on-retry, and it made a recoverable timeout permanent - six
        records on one path, ~40 minutes of a blocked merge, and a worktree that
        could not be removed while the daemon held it.

        Rules:

          * An ACTIVATION failure (`did not activate`, AGENT_CREATE_FAILED) is
            never a provider/quota problem, so it must not be released as one
            and must not be retried blind. One record for the path -> reuse it
            (`--workspace <id>`) exactly once. Zero or several -> fail named,
            with the count, the ids and the cleanup command. Never mint.
          * Any other failure reuses the path's existing record when there is
            one - a retry must never be the thing that creates a duplicate.
          * Minting stays legal only when the path genuinely has no record.

    .OUTPUTS
        Hashtable: Action ('reuse' | 'create' | 'fail'), WorkspaceId ('' unless
        reuse), IsActivationFailure, Code (stable error code for 'fail') and
        Message (the one line an operator reads).
    #>
    param(
        [AllowEmptyString()][string]$FailureText = '',
        [object[]]$Records = @(),
        [AllowEmptyString()][string]$Path = '',
        [AllowEmptyString()][string]$ReusedWorkspaceId = '',
        [int]$Attempt = 1,
        [int]$MaxAttempts = 2
    )

    $text = if ($null -eq $FailureText) { '' } else { [string]$FailureText }
    $ids = @($Records | ForEach-Object { [string]$_.workspaceId } | Where-Object { $_ })
    $count = $ids.Count
    $idList = if ($count -gt 0) { $ids -join ', ' } else { '(none)' }
    $label = if ([string]::IsNullOrWhiteSpace($Path)) { 'the worker checkout' } else { $Path }

    $isActivation = $text -match 'did not activate within' -or
                    $text -match 'OpenCodeLocationReadyTimeoutError' -or
                    $text -match 'AGENT_CREATE_FAILED' -or
                    $text -match 'LOCATION-ACTIVATION-FAILED'

    if ($isActivation) {
        if ($count -eq 1 -and [string]::IsNullOrWhiteSpace($ReusedWorkspaceId)) {
            return @{
                Action              = 'reuse'
                WorkspaceId         = $ids[0]
                IsActivationFailure = $true
                Code                = ''
                Message             = "LOCATION-ACTIVATION-RETRY: activation timed out for '$label' which has 1 workspace record ($($ids[0])); reusing that record for this retry instead of minting another."
            }
        }

        $why = if ($count -eq 0) {
            'no workspace record exists for this path, so the timeout is not a duplicate-record problem'
        }
        elseif ($count -eq 1) {
            "the only record ($($ids[0])) was already reused for a retry, so a further attempt cannot help"
        }
        else {
            "$count workspace records are bound to this path ($idList); the daemon cannot tell which is live and every retry mints yet another record"
        }

        return @{
            Action              = 'fail'
            WorkspaceId         = ''
            IsActivationFailure = $true
            Code                = 'LOCATION_ACTIVATION_FAILED'
            Message             = "LOCATION-ACTIVATION-FAILED: OpenCode location '$label' did not activate (attempt $Attempt/$MaxAttempts); $why. Duplicate workspace records for this path: $count ($idList). Not retried and no new workspace minted. Inspect with Skills/cl-paseo/scripts/Get-PaseoWorkspaceRecordReport.ps1. Records cannot be removed non-destructively - paseo offers create/ls/rename/archive only, and archive takes the workspace's agents with it - so move this lane to a fresh path, or raise the record cleanup as a Paseo/operator decision."
        }
    }

    if ($count -ge 1) {
        return @{
            Action              = 'reuse'
            WorkspaceId         = $ids[0]
            IsActivationFailure = $false
            Code                = ''
            Message             = "Reusing workspace $($ids[0]) for the retry on '$label' ($count record(s) already exist, so this attempt must not mint another)."
        }
    }

    if ($Attempt -ge $MaxAttempts) {
        return @{
            Action              = 'fail'
            WorkspaceId         = ''
            IsActivationFailure = $false
            Code                = 'DISPATCH_FAILED'
            Message             = "Dispatch failed after $Attempt attempt(s) with no workspace record for '$label'."
        }
    }

    return @{
        Action              = 'create'
        WorkspaceId         = ''
        IsActivationFailure = $false
        Code                = ''
        Message             = "No workspace record exists for '$label'; the next attempt may create one."
    }
}

function Get-Prop {
    param($Object, [Parameter(Mandatory)][string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $Default
    }
    $prop = $Object.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    return $Default
}

$keyEnv = @{ Pairs = @(); Value = ''; KeyName = '' }

# Spawn-capacity gate: refuse a dispatch nothing can absorb, and take the route,
# effort and pool to spawn on. -Pool auto walks the pools by priority, so Gemini
# is tried first and a spent or busy pool simply falls through to the next one.
$capacityScript = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'agent-spawn-capacity/scripts/AgentCapacity.ps1'
$capacityAvailable = Test-Path -LiteralPath $capacityScript
$slot = $null
if (-not $SkipCapacity) {
    if (-not $capacityAvailable) {
        Write-Warning "Spawn-capacity gate not found at $capacityScript - dispatching WITHOUT a pool cap. Install Skills/agent-spawn-capacity."
    }
    else {
        $acquireArgs = @{ Mode = 'Acquire'; Pool = $Pool; Role = $Role; DispatchMode = $DispatchMode; Title = $Title; Lane = $workdirPath }
        if ($IgnoreCapacity) { $acquireArgs['IgnoreCapacity'] = $true }
        $slot = & $capacityScript @acquireArgs
        if ($slot) {
            if ($slot.Provider -and -not $PSBoundParameters.ContainsKey('Provider')) { $Provider = [string]$slot.Provider }
            if (-not $PSBoundParameters.ContainsKey('Thinking')) { $Thinking = [string]$slot.Thinking }
            $keyEnv = Resolve-AgentKeyEnv -Slot $slot
            Write-Host "Capacity: $($slot.Pool)/$($slot.Role) work=$($slot.WorkRole) $($slot.PoolUsed)/$($slot.PoolCap) used - provider $Provider$(if ($Thinking) { " (thinking $Thinking)" })$(if ($keyEnv.KeyName) { " key=$($keyEnv.KeyName) (value never shown)" })$(if ($DispatchMode -ne 'single-active') { " dispatch=$DispatchMode" })" -ForegroundColor Cyan
            # Free-tier tight supervision (operator rule 2026-10-17): a worker
            # holding a free key is polled EVERY MINUTE until its key fails or
            # its done file lands. Two silent 1-min rounds escalate to
            # Release (provider-error) + re-dispatch on the next pool, so a
            # fast-dying free key never blocks paid work. Detection is
            # additive: the gate's KeyTier when present, else the ':free'
            # provider suffix.
            $slotTier = ''
            try { $slotTier = [string](Get-Prop $slot 'KeyTier' '') } catch { $slotTier = '' }
            if (-not $slotTier -and $Provider -match ':free\b') { $slotTier = 'free' }
            if ($slotTier -eq 'free') {
                $watchGrace = 1
                try { if ([int](Get-Prop $slot 'WatchGraceMinutes' 0) -gt 0) { $watchGrace = [int](Get-Prop $slot 'WatchGraceMinutes' 1) } } catch { $watchGrace = 1 }
                Write-Host "Free-tier watch: this worker holds a FREE key - poll every 60s with lane-watch --grace-minutes $watchGrace until the done file lands or the key fails; on 2 silent rounds Release as provider-error and re-dispatch to the next pool. Loop: while (\$true) { node <Skills>/paseo-child-agents/lane-watch.mjs --parent <parent-id> --workdir $workdirPath --grace-minutes $watchGrace; Start-Sleep -Seconds 60 }" -ForegroundColor Yellow
            }
        }
    }
}
# Gemini exposes no thinking options: an empty effort means "do not pass
# --thinking at all", never "--thinking ''".
$useThinking = -not [string]::IsNullOrWhiteSpace($Thinking)

if (-not $SkipPreflight -and $Provider -match '^opencode/([^/]+)/(.+)$') {
    $canaryModel = "$($Matches[1])/$($Matches[2])"
    $canary = Join-Path $PSScriptRoot 'Test-OpencodeProvider.ps1'
    Write-Host "Preflight: canary on $canaryModel" -ForegroundColor DarkGray
    # Capture so the explanation can name the key the canary actually exercised
    # (it reports a label, never a value) and compare it with the key this
    # session inherited.
    # Exercise the key this dispatch actually selected, not whatever key the
    # caller inherited. The gate returns KeyEnv=OPENCODE_GO<n>_KEY; pass that
    # number to the canary so a GO6 dispatch is canaried on GO6 even when the
    # machine's active key is GO1.
    $canaryArgs = @{ Model = $canaryModel }
    $selectedKeyNumber = 0
    if ($keyEnv.KeyName -match '^OPENCODE_GO(\d+)_KEY$') { $selectedKeyNumber = [int]$Matches[1] }
    if ($selectedKeyNumber -gt 0) { $canaryArgs['KeyNumber'] = $selectedKeyNumber }
    $canaryText = & $canary @canaryArgs 2>&1 | Out-String
    if (-not [string]::IsNullOrWhiteSpace($canaryText)) { Write-Host $canaryText.TrimEnd() }
    if ($LASTEXITCODE -ne 0) {
        $sessionKeyValue = if ($keyEnv.Value) { [string]$keyEnv.Value } else { $env:OPENCODE_GO_KEY }
        throw (Get-PreflightFailureMessage -Model $canaryModel -CanaryOutput $canaryText -SessionKeyValue $sessionKeyValue)
    }
}

$prompt = "Read the task brief at $briefPath and execute it end to end. Write your final report to $reportPath. Keep the report terse (status, commits, gates, deferred - at most 25 lines; never paste file contents, logs, or diffs, cite paths instead). Do not ask questions; if blocked, record the blocker and stop."
# NOTE: $prompt gains the completion handshake below, after parent resolution.

$resolvedParentId = ''
$resolvedParentCwd = ''
if ($ParentAgentId -ieq 'none') {
    Write-Host 'Parent linkage: disabled (-ParentAgentId none).' -ForegroundColor DarkGray
}
elseif ($ParentAgentId -ieq 'auto') {
    if (-not [string]::IsNullOrWhiteSpace($env:PASEO_AGENT_ID)) {
        $resolvedParentId = $env:PASEO_AGENT_ID
        $resolvedParentCwd = $env:PASEO_AGENT_CWD
    }
    else {
        $self = Resolve-SelfAgent -Paseo $paseo -CallerCwd $PWD.Path
        if ($null -ne $self) {
            $resolvedParentId = [string]$self.id
            $resolvedParentCwd = [string]$self.cwd
        }
    }
    if (-not $resolvedParentId) {
        Write-Host 'Parent linkage: no unique running Paseo agent matched this cwd; dispatching unparented. Pass -ParentAgentId <id> to link explicitly.' -ForegroundColor Yellow
    }
}
else {
    $resolvedParentId = $ParentAgentId
    $resolvedParentCwd = $PWD.Path
}

$prevPaseoAgentId = $env:PASEO_AGENT_ID
$prevPaseoAgentCwd = $env:PASEO_AGENT_CWD
try {
    # Completion handshake (2026-09-24): `paseo run` has no notify-on-finish
    # flag and the parent label is metadata, not a wakeup — a worker that just
    # "writes the report and stops" finishes silently and the orchestrator's
    # memory of it rots. So every parented dispatch stages a ping shim,
    # `.iqa-ping.cmd`, in the lane: the worker's last step is running
    # `.\.iqa-ping.cmd`, which sends one best-effort ping at the parent. The
    # shim exists because the mechanism was proven the hard way: bare `paseo`
    # is not on a worker's PATH (probe 1), and models drop the double quotes
    # around the spaced absolute path when retyping it (probe 2: `& C:\Program`
    # → "not recognized"). A byte-exact file the worker only *invokes* removes
    # the fidelity risk. The ping is a reconcile trigger (inspect worker, read
    # .iqa-report.md), never proof of success; polling (`paseo ls` + lane
    # reports) is the backstop. `.iqa-*` is lane metadata — never committed.
    if ($resolvedParentId) {
        $safeTitle = ($Title -replace "'", '') -replace '"', ''
        $shimPath = Join-Path $workdirPath '.iqa-ping.cmd'
        @(
            '@echo off'
            "`"$paseo`" send $resolvedParentId --no-wait `"IQA worker done: $safeTitle | report: $reportPath | lane: $workdirPath`""
        ) | Set-Content -LiteralPath $shimPath -Encoding Ascii
        $prompt = "$prompt As your very last step after the report is written and pushed, run .\.iqa-ping.cmd to wake the orchestrator (best-effort: attempt it once, ignore any failure, then stop — the orchestrator also reconciles by polling). Never commit .iqa-* files."
    }
    else {
        $prompt = "$prompt No orchestrator link exists, so just stop after writing the report; the orchestrator will find it by polling the lane."
    }
    if ($resolvedParentId) {
        $env:PASEO_AGENT_ID = $resolvedParentId
        $env:PASEO_AGENT_CWD = if ($resolvedParentCwd) { $resolvedParentCwd } else { $PWD.Path }
        Write-Host "Parent linkage: $resolvedParentId" -ForegroundColor Cyan
    }
    Write-Host "Dispatching IQA worker '$Title' in $workdirPath" -ForegroundColor Cyan
    # Bind the agent to the WORKER's checkout. `--cwd` alone does not: an
    # agent-scoped dispatch defaults to the CALLER's workspace, so the session
    # cwd and every workspace-relative tool stay on the dispatcher's checkout.
    # For an interactive IQA session that is the repo's PRIMARY checkout, which
    # usually holds another lane's uncommitted work (observed 2026-09-23: the
    # worker's session cwd was the primary checkout while its brief pointed at
    # the lane worktree). Pass an explicit workspace id, else mint a local
    # workspace rooted at the workdir.
    $workspaceArgs = if ([string]::IsNullOrWhiteSpace($WorkspaceId)) {
        # Reuse before create: if this path already has a workspace record, bind
        # to it instead of minting a second one. Minting is what produced six
        # duplicate records on .worktrees/merge-84m (2026-11-02); the very first
        # dispatch of a re-run must not add another.
        $existing = @(Get-PathWorkspaceRecords -Paseo $paseo -Path $workdirPath)
        if ($existing.Count -ge 1) {
            Write-Host "Workspace: reusing $($existing[0].workspaceId) ($($existing.Count) record(s) already bound to this path)." -ForegroundColor DarkGray
            @('--workspace', [string]$existing[0].workspaceId)
        }
        else {
            @('--new-workspace', 'local')
        }
    }
    else {
        @('--workspace', $WorkspaceId)
    }
    $dispatchAttempts = 0
    $maxAttempts = if ($SkipCapacity -or -not $capacityAvailable) { 1 } else { $MaxDispatchAttempts }
    # The workspace this dispatch has already fallen back to. A second failure
    # on the same reused record fails named instead of looping.
    $reusedWorkspaceId = ''
    while ($true) {
        $dispatchAttempts++
        $thinkingArgs = if ($useThinking) { @('--thinking', $Thinking) } else { @() }
        # The mode is the PROVIDER's property, not this script's: OpenCode takes
        # build, the DeepSeek Harness takes no --mode at all. Derived per attempt
        # because a retry normally lands on a different route.
        $modeRule = Get-WorkerModeArgument -Provider $Provider
        Write-Host $modeRule.Summary -ForegroundColor DarkGray
        $modeArgs = @($modeRule.Args)
        # Each --env pair is scoped to THIS agent, so a bridged key never
        # becomes a global override. The value is never echoed.
        $envFlags = @('--env', "OPENCODE_CONFIG=$configPath")
        foreach ($pair in @($keyEnv.Pairs)) { $envFlags += @('--env', $pair) }
        # Provider failures normally print to stderr; the gate classifies that
        # text (a daily-quota message takes the pool/key out of circulation), so
        # it must be captured rather than discarded. `.iqa-*` is lane metadata
        # and is never committed.
        $stderrPath = Join-Path $workdirPath '.iqa-dispatch.err'
        $raw = & $paseo run -d --json --title $Title @modeArgs `
            --provider $Provider @thinkingArgs `
            @workspaceArgs `
            --cwd $workdirPath @envFlags $prompt 2>$stderrPath
        if ($LASTEXITCODE -eq 0) { break }

        $stderrText = ''
        if (Test-Path -LiteralPath $stderrPath) { $stderrText = (Get-Content -LiteralPath $stderrPath -Raw -ErrorAction SilentlyContinue) }
        $failureText = (@($stderrText, ($raw | Out-String)) -join "`n").Trim()
        # Redact before anything can log it: a provider message that echoes the
        # credential must not carry it into the error log.
        if ($keyEnv.Value) { $failureText = $failureText.Replace([string]$keyEnv.Value, '***REDACTED-KEY***') }
        if ($failureText.Length -gt 800) { $failureText = $failureText.Substring(0, 800) }

        # Reuse-or-fail (2026-11-02): the retry must never be the thing that
        # mints another workspace for the same path. Measured failure this
        # removes: six active workspace records on .worktrees/merge-84m, each
        # one minted by a `--new-workspace local` retry, after which the location
        # could no longer activate at all. An activation timeout is not a
        # provider error: it is decided here, once, with the duplicate count.
        $workspaceRecords = @(Get-PathWorkspaceRecords -Paseo $paseo -Path $workdirPath)
        $plan = Resolve-WorkspaceDispatchPlan -FailureText $failureText -Records $workspaceRecords `
            -Path $workdirPath -ReusedWorkspaceId $reusedWorkspaceId `
            -Attempt $dispatchAttempts -MaxAttempts $maxAttempts

        if ($plan.Action -eq 'fail') {
            if ($slot -and $slot.Token) {
                try {
                    & $capacityScript -Mode Release -Token $slot.Token -Outcome provider-error `
                        -ErrorCode $plan.Code -Message $failureText -KeyName $keyEnv.KeyName | Out-Null
                }
                catch { }
            }
            $serviceAdvice = Get-ServiceLimitFailureAdvice -Text $failureText
            throw ("$([string]$plan.Message)" + $(if ($serviceAdvice) { " $serviceAdvice" } else { '' }))
        }

        if ($plan.Action -eq 'reuse') {
            # Same slot, same brief, same path: only the workspace binding
            # changes, from create-or-retry to reuse. No capacity release, no
            # re-acquire, and no new workspace record.
            Write-Host ([string]$plan.Message) -ForegroundColor Yellow
            $reusedWorkspaceId = [string]$plan.WorkspaceId
            $workspaceArgs = @('--workspace', [string]$plan.WorkspaceId)
            continue
        }

        # Plan is 'create': the path genuinely has no record. Fall through to the
        # provider-error path below, which re-acquires from the next pool.
        if ($slot -and $slot.Token) {
            try {
                & $capacityScript -Mode Release -Token $slot.Token -Outcome provider-error `
                    -ErrorCode 'DISPATCH_FAILED' -Message $failureText -KeyName $keyEnv.KeyName | Out-Null
            }
            catch { }
        }
        if ($dispatchAttempts -ge $maxAttempts) {
            $serviceAdvice = Get-ServiceLimitFailureAdvice -Text $failureText
            throw "paseo run failed after $dispatchAttempts attempt(s) (exit code $LASTEXITCODE). Last output: $failureText$(if ($serviceAdvice) { " $serviceAdvice" })"
        }

        Write-Warning "Dispatch on '$($slot.Pool)' failed; re-dispatching the same brief on the next pool by priority (attempt $($dispatchAttempts + 1)/$maxAttempts)."
        $slot = & $capacityScript -Mode Acquire -Pool auto -Role $Role -DispatchMode $DispatchMode -Title $Title -Lane $workdirPath
        if (-not $PSBoundParameters.ContainsKey('Provider')) { $Provider = [string]$slot.Provider }
        $Thinking = [string]$slot.Thinking
        $useThinking = -not [string]::IsNullOrWhiteSpace($Thinking)
        # Re-resolve: the retry is normally on a DIFFERENT pool, and a different
        # Gemini key if the failure was a spent key rather than a spent executor.
        $keyEnv = Resolve-AgentKeyEnv -Slot $slot
        Write-Host "Capacity (retry): $($slot.Pool)/$($slot.Role) work=$($slot.WorkRole) - provider $Provider$(if ($Thinking) { " (thinking $Thinking)" })$(if ($keyEnv.KeyName) { " key=$($keyEnv.KeyName) (value never shown)" })$(if ($DispatchMode -ne 'single-active') { " dispatch=$DispatchMode" })" -ForegroundColor Cyan
        if (-not $SkipPreflight -and $Provider -match '^opencode/([^/]+)/(.+)$') {
            $retryModel = "$($Matches[1])/$($Matches[2])"
            $retryCanaryArgs = @{ Model = $retryModel }
            if ($keyEnv.KeyName -match '^OPENCODE_GO(\d+)_KEY$') { $retryCanaryArgs['KeyNumber'] = [int]$Matches[1] }
            & (Join-Path $PSScriptRoot 'Test-OpencodeProvider.ps1') @retryCanaryArgs
            if ($LASTEXITCODE -ne 0) { throw "Provider preflight failed for '$retryModel' on the re-dispatch." }
        }
    }
}
finally {
    if ($null -ne $prevPaseoAgentId) { $env:PASEO_AGENT_ID = $prevPaseoAgentId }
    else { Remove-Item -LiteralPath 'Env:PASEO_AGENT_ID' -ErrorAction SilentlyContinue }
    if ($null -ne $prevPaseoAgentCwd) { $env:PASEO_AGENT_CWD = $prevPaseoAgentCwd }
    else { Remove-Item -LiteralPath 'Env:PASEO_AGENT_CWD' -ErrorAction SilentlyContinue }
}

# Dispatch failures are handled inside the retry loop above.

$agentId = ''
try {
    $parsed = ($raw | Out-String) | ConvertFrom-Json
    if ($null -ne $parsed -and $parsed.PSObject.Properties['agentId']) {
        $agentId = [string]$parsed.agentId
    }
}
catch {
    $agentId = ''
}

if ([string]::IsNullOrWhiteSpace($agentId)) {
    $lines = @($raw | Where-Object { -not [string]::IsNullOrWhiteSpace("$_") })
    if ($lines.Count -gt 0) { $agentId = "$($lines[-1])".Trim() }
}
if ([string]::IsNullOrWhiteSpace($agentId)) {
    throw 'paseo run did not report an agent id.'
}

Write-Host "Agent id: $agentId" -ForegroundColor Green
if ($slot -and $slot.Token -and $capacityAvailable) {
    try {
        & $capacityScript -Mode Register -Token $slot.Token -AgentId $agentId | Out-Null
    }
    catch {
        Write-Warning "Could not bind agent $agentId to its capacity reservation: $($_.Exception.Message). Release it by hand when the worker ends."
    }
}
Write-Output $agentId
