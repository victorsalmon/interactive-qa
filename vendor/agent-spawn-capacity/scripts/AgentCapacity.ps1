#Requires -Version 7.0
<#
.SYNOPSIS
    Spawn-capacity gate + model failover + provider-error log for Paseo agents.

.DESCRIPTION
    One registry (assets/agent-capacity.json) owns every per-key-set concurrency
    cap, the primary/alternate route per pool, and the error-state policy. This
    script is the only place those rules are executed, so an IQA / IQA-Beads /
    attached / detached dispatcher all obey the same numbers.

    Contract for a dispatcher (attached or detached), in order:

      1. Acquire  - ask permission + get the route AND effort to spawn on.
                    -Pool auto walks the pools by priority (Gemini first) and
                    takes the first that fits, so a spent or busy pool simply
                    falls through to the next one. Refuses only when nothing
                    fits: disabled, at cap, cooling down, or out of circulation
                    for the calendar day.
      2. spawn    - paseo run -d ... (detached) or paseo_create_agent (attached)
      3. Register - bind the returned agent id to the reservation.
      4. Release  - on finish: -Outcome ok, or -Outcome provider-error with the
                    provider's message when the AGENT ITSELF failed.

    Occupancy is reconciled against `paseo ls --json` (running/idle agents whose
    provider matches the pool), so a worker that dies without a Release does not
    leak a slot forever; an unregistered reservation expires after
    defaults.reservationTtlMinutes.

    Failure state machine (per pool+route): provider-error releases are bucketed
    into failurePolicy.windowMinutes windows. failureWindowsToTrip distinct
    windows trips the route into cooldown for failurePolicy.cooldownMinutes; while
    a route is cooling down, Acquire prefers the pool's other route. When the
    cooldown expires the route is canaried before it is trusted again.

    Every provider error, refusal, canary failure, and cooldown transition is
    appended to the error log as one JSON line - that log is what answers
    "were there any errors last night?". Key VALUES are never read or printed;
    only environment-variable NAMES are recorded.

.PARAMETER Mode
    Status   - pools, occupancy, caps, route health (read-only).
    Acquire  - reserve a slot and return the route to spawn on.
    Register - bind an agent id to a reservation token.
    Release  - free the slot; optionally record a provider error.
    Report   - human summary of logged errors/refusals/cooldowns.
    Clear    - clear a route's cooldown + failure windows (operator override).
    Canary   - L3 dispatch canary (plan dispatch-modes-plan.md §3): session-start
               5-parallel probe (no -KeyName) or single-key on-failure re-canary
               (-KeyName) on the opencode-go pool under -DispatchMode
               waterfall|round-robin. Fixture path for tests:
               $env:AGENT_CAPACITY_CANARY_STUB replaces the live probe.

.PARAMETER Pool
    Registry pool id (gemini | opencode-go | codex | devin), or 'auto' to walk
    the pools by priority - Gemini first, so its free daily allowance is spent
    before anything paid is touched. Acquire defaults to 'auto'.

.PARAMETER DispatchMode
    L2 dispatch-modes (plan dispatch-modes-plan.md §2): single-active (default,
    legacy first-free-key selection, behavior unchanged) | waterfall (fill key[i]
    to its per-key cap before key[i+1]) | round-robin (cycle one agent per key).
    Modes engage on the opencode-go pool only; every other pool keeps the
    existing selection and the mode is echoed back untouched. Unknown values
    throw via ValidateSet (fail-closed). NOTE: the name -Mode is the operation
    selector (Status/Acquire/...), so the dispatch mode lives on -DispatchMode.

.PARAMETER Profile
    F3 profile-level mode selection: an explicit Paseo profile - the object
    paseo_list_profiles returns, a hashtable of the same shape, or its JSON
    text. If the profile carries an optional 'dispatchMode' field, that field
    owns the mode for this dispatch: it is validated (unknown values throw,
    never a silent fall back to single-active) and used in place of the
    -DispatchMode default. Absent / null / blank field = the -DispatchMode
    value, byte-identical to the pre-F3 behavior. Omitting -Profile changes
    nothing, and no registry default is flipped (decision D4 stays open).
    An explicitly bound -DispatchMode that disagrees with the profile field
    throws: one owner per dispatch.

.PARAMETER Role
    WORK role: recon | review | fix | code | refactor | simple | merge (or 'any' for the pool default).
    The work role selects both the route and the effort, from the pool's
    workRoles map - e.g. opencode-go runs every work role at low on DeepSeek V4.1
    Flash (raise to high for complex logic/edge cases/multi-step invariants).
    A route name (primary | alternate) is still accepted as an
    explicit route pin.

.PARAMETER Since
    Report window: a DateTime, or 24h | 12h | 7d | lastnight. Default: registry
    defaults.reportDefaultSince.

.PARAMETER LastNight
    Shorthand for -Since lastnight (previous day at defaults.lastNightStartsAt).

.PARAMETER Force
    Clear only: also drop a pool's calendar-day disable. A spent daily
    allowance is meant to stand until the next calendar day, so clearing it
    early is an explicit operator override and is logged as one.

.PARAMETER IgnoreCapacity
    Operator override: acquire even when at cap / cooling down. Always logged as
    spawn-refused=false + override=true, so an override is never invisible.

.PARAMETER OptInCodex
    Explicit user opt-in to use the Codex pool while it remains disabled for
    automatic routing. Requires -Pool codex and cannot be combined with
    -IgnoreCapacity; it never enables Codex in -Pool auto. Normal capacity,
    role caps, and failure checks still apply, and the opt-in is recorded.

.OUTPUTS
    Acquire/Register: a PSCustomObject (or JSON with -AsJson). Others: text.

.EXAMPLE
    $slot = ./AgentCapacity.ps1 -Mode Acquire -Pool opencode-go -Role recon
    # -> DeepSeek V4.1 Flash at low (the fleet default; high for complex work)

.EXAMPLE
    $slot = ./AgentCapacity.ps1 -Mode Acquire      # -Pool auto: Gemini first
    # ... paseo run -d --provider $slot.Provider --thinking $slot.Thinking ...
    ./AgentCapacity.ps1 -Mode Register -Token $slot.Token -AgentId $id
    ./AgentCapacity.ps1 -Mode Release  -Pool opencode-go -AgentId $id -Outcome ok

.EXAMPLE
    ./AgentCapacity.ps1 -Mode Report -LastNight
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Status', 'Acquire', 'Register', 'Release', 'Report', 'Config', 'Clear', 'Canary')]
    [string]$Mode,

    [string]$Pool = '',

    [ValidateSet('single-active', 'waterfall', 'round-robin')]
    [string]$DispatchMode = 'single-active',

    # F3: an explicit Paseo profile (object, hashtable, or JSON text) whose
    # optional 'dispatchMode' field owns mode selection. Omitted = unchanged.
    $Profile = $null,

    [string]$Role = 'any',

    [string]$AgentId = '',

    [string]$Token = '',

    # Which key (env-var NAME) the failed agent was on. Release derives it from
    # the reservation; pass it only for a log-only error record.
    [string]$KeyName = '',

    [string]$Title = '',

    [string]$Lane = '',

    [ValidateSet('ok', 'provider-error')]
    [string]$Outcome = 'ok',

    [string]$ErrorCode = '',

    [string]$Message = '',

    [string]$Since = '',

    [switch]$LastNight,

    [switch]$SkipCanary,

    [switch]$IgnoreCapacity,

    [switch]$OptInCodex,

    [switch]$Force,

    # Reservation-only accounting: skip `paseo ls` reconciliation. Use it when
    # the daemon is unreachable or for a dry run - never as a normal dispatch.
    [switch]$NoReconcile,

    [switch]$AsJson,

    [string]$RegistryPath = '',

    [string]$StatePath = '',

    # Relocate the JSONL logs (tests, dry runs, a host with a different fleet
    # root). Default comes from the registry's paths.logDir.
    [string]$LogDir = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($OptInCodex -and $Mode -ne 'Acquire') {
    throw '-OptInCodex is valid only with -Mode Acquire.'
}

# F3: was -DispatchMode explicitly bound (rather than defaulted)? Captured here,
# once, so the profile resolver below can tell "the caller pinned a mode" from
# "the caller took the default".
$dispatchModeBound = $PSBoundParameters.ContainsKey('DispatchMode')

# ---------------------------------------------------------------------------
# Registry / state plumbing
# ---------------------------------------------------------------------------

function Expand-FleetPath {
    <#
    .SYNOPSIS
        Expands %VAR% tokens, ~, and the fleet roots in a registry path.
    #>
    param([Parameter(Mandatory)][string]$Value)

    $map = @{
        '%CL_COMMON_HOME%' = if ($env:CL_COMMON_HOME) { $env:CL_COMMON_HOME } else { "$($env:CL_REPOS_ROOT)\cl-common" }
        '%CL_REPOS%'       = if ($env:CL_REPOS_ROOT) { $env:CL_REPOS_ROOT } else { "$($env:CL_REPOS_ROOT)" }
        '%USERPROFILE%'    = $env:USERPROFILE
        '%APPDATA%'        = $env:APPDATA
        '%LOCALAPPDATA%'   = $env:LOCALAPPDATA
        '%XDG_DATA_HOME%'  = if ($env:XDG_DATA_HOME) { $env:XDG_DATA_HOME } else { Join-Path $env:USERPROFILE '.local\share' }
    }
    $result = $Value
    foreach ($key in $map.Keys) {
        if ($null -ne $map[$key]) { $result = $result.Replace($key, [string]$map[$key]) }
    }
    if ($result.StartsWith('~/') -or $result.StartsWith('~\')) {
        $result = Join-Path $env:USERPROFILE $result.Substring(2)
    }
    return $result
}

function Get-Prop {
    <#
    .SYNOPSIS
        Safe property read on a hashtable/object under StrictMode.
    #>
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

# Work-role -> (route, effort) resolvers live in one shared lib.
. (Join-Path $PSScriptRoot 'AgentCapacity.Registry.ps1')

function Get-Registry {
    param([string]$Override)

    $path = if ($Override) { $Override }
            elseif ($env:AGENT_CAPACITY_REGISTRY) { $env:AGENT_CAPACITY_REGISTRY }
            else { Join-Path (Join-Path $PSScriptRoot '..') 'assets/agent-capacity.json' }
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Spawn-capacity registry not found: $path"
    }
    return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable)
}

function Get-Paths {
    param([Parameter(Mandatory)]$Registry, [string]$StateOverride, [string]$LogDirOverride)

    $paths = Get-Prop $Registry 'paths' @{}
    $logDir = if ($LogDirOverride) { $LogDirOverride }
              elseif ($env:AGENT_CAPACITY_LOGDIR) { $env:AGENT_CAPACITY_LOGDIR }
              else { Expand-FleetPath ([string](Get-Prop $paths 'logDir' "$($env:CL_REPOS_ROOT)\Tasks\Logs")) }
    $state = if ($StateOverride) { $StateOverride }
             elseif ($env:AGENT_CAPACITY_STATE) { $env:AGENT_CAPACITY_STATE }
             else { Expand-FleetPath ([string](Get-Prop $paths 'stateFile' '~/.machine/state/agent-capacity.json')) }
    return @{
        LogDir    = $logDir
        SpawnLog  = Join-Path $logDir ([string](Get-Prop $paths 'spawnLog' 'agent-spawns.jsonl'))
        ErrorLog  = Join-Path $logDir ([string](Get-Prop $paths 'errorLog' 'agent-spawn-errors.jsonl'))
        StateFile = $state
    }
}

function Get-State {
    param([Parameter(Mandatory)][string]$StateFile)

    if (-not (Test-Path -LiteralPath $StateFile)) {
        return @{ version = 1; updated = ''; entries = @(); routes = @{}; pools = @{}; keys = @{}; dispatch = @{ inFlight = @{}; cursor = 0; assignments = @(); canaryVerdicts = @{}; effectiveOrder = @(); lastMode = 'single-active' } }
    }
    try {
        $raw = Get-Content -LiteralPath $StateFile -Raw
        if ([string]::IsNullOrWhiteSpace($raw)) { throw 'empty' }
        $state = $raw | ConvertFrom-Json -AsHashtable
        if (-not $state.Contains('entries')) { $state['entries'] = @() }
        if (-not $state.Contains('routes')) { $state['routes'] = @{} }
        if (-not $state.Contains('pools')) { $state['pools'] = @{} }
        if (-not $state.Contains('keys')) { $state['keys'] = @{} }
        if (-not $state.Contains('dispatch')) { $state['dispatch'] = @{ inFlight = @{}; cursor = 0; assignments = @(); canaryVerdicts = @{}; effectiveOrder = @(); lastMode = 'single-active' } }
        return $state
    }
    catch {
        # A corrupt state file must never block a dispatch: quarantine and start clean.
        $bad = "$StateFile.corrupt-$([DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))"
        Copy-Item -LiteralPath $StateFile -Destination $bad -ErrorAction SilentlyContinue
        return @{ version = 1; updated = ''; entries = @(); routes = @{}; pools = @{}; keys = @{}; recoveredFrom = $bad; dispatch = @{ inFlight = @{}; cursor = 0; assignments = @(); canaryVerdicts = @{}; effectiveOrder = @(); lastMode = 'single-active' } }
    }
}

function Save-State {
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][string]$StateFile)

    $State['updated'] = (Get-Date).ToString('o')
    $parent = Split-Path -Parent $StateFile
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        $null = New-Item -ItemType Directory -Path $parent -Force
    }
    $json = $State | ConvertTo-Json -Depth 20
    [System.IO.File]::WriteAllText($StateFile, $json + "`n", [System.Text.UTF8Encoding]::new($false))
}

function Invoke-WithStateLock {
    <#
    .SYNOPSIS
        Serializes state mutation behind a named OS mutex (abandoned locks are
        adopted, not feared - a crashed holder must not wedge every dispatcher).
    #>
    param([Parameter(Mandatory)][scriptblock]$Body, [int]$TimeoutSec = 60)

    $mutex = $null
    foreach ($ns in @('Global', 'Local')) {
        try { $mutex = [Threading.Mutex]::new($false, "$ns\AgentSpawnCapacity"); break }
        catch { $mutex = $null }
    }
    if (-not $mutex) { throw 'Could not create the agent-capacity state lock.' }
    try {
        $acquired = $false
        try { $acquired = $mutex.WaitOne([TimeSpan]::FromSeconds($TimeoutSec)) }
        catch [Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) { throw "Timed out waiting ${TimeoutSec}s for the agent-capacity lock." }
        try { return (& $Body) }
        finally { $mutex.ReleaseMutex() }
    }
    finally { $mutex.Dispose() }
}

function Write-LogLine {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Record)

    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        $null = New-Item -ItemType Directory -Path $parent -Force
    }
    $line = ($Record | ConvertTo-Json -Depth 10 -Compress)
    Add-Content -LiteralPath $Path -Value $line -Encoding utf8
}

# ---------------------------------------------------------------------------
# Paseo occupancy reconciliation
# ---------------------------------------------------------------------------

function Resolve-PaseoCli {
    # -ErrorAction Ignore (not SilentlyContinue): a missing paseo must not even
    # land in $Error, so a caller inspecting $Error sees only real failures.
    $command = Get-Command paseo -CommandType Application -ErrorAction Ignore
    if ($command) { return $command.Source }
    $roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, (Join-Path $env:LOCALAPPDATA 'Programs')) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    foreach ($root in $roots) {
        $candidate = Join-Path $root 'Paseo/resources/bin/paseo.cmd'
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    return ''
}

function Get-LiveAgents {
    <#
    .SYNOPSIS
        Live (non-archived) Paseo agents plus whether the query actually worked.
    .DESCRIPTION
        Ok=$false means "could not ask", which is NOT the same as "nothing is
        running": pruning reservations on a failed query would silently disable
        the cap exactly when the daemon is flaky. Callers must degrade to
        reservation-only accounting instead.
    #>
    $paseo = Resolve-PaseoCli
    if (-not $paseo) { return @{ Ok = $false; Agents = @(); Detail = 'paseo CLI not found' } }
    try {
        $raw = & $paseo ls --json 2>$null | Out-String
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($raw)) {
            return @{ Ok = $false; Agents = @(); Detail = "paseo ls exited $LASTEXITCODE" }
        }
        # Take the JSON array out of the output instead of parsing the WHOLE
        # stream. The CLI prints notices/banners on stdout ahead of its payload
        # (observed 2026-11-02: "Warning: --background (-d) is deprecated..." on
        # the `run` path), and one such line used to throw here - silently
        # switching the gate to reservation-only accounting, which then counted
        # every stale reservation and reported a pool at cap with nothing
        # running. A banner is noise, not an answer, so it must not disable
        # reconciliation; only a genuinely unparseable payload may.
        $start = $raw.IndexOf('[')
        $end = $raw.LastIndexOf(']')
        if ($start -lt 0 -or $end -le $start) {
            return @{ Ok = $false; Agents = @(); Detail = 'paseo ls returned no JSON array' }
        }
        $payload = $raw.Substring($start, $end - $start + 1)
        return @{ Ok = $true; Agents = @($payload | ConvertFrom-Json); Detail = 'ok' }
    }
    catch { return @{ Ok = $false; Agents = @(); Detail = "paseo ls failed: $($_.Exception.Message)" } }
}

function Resolve-AgentExistence {
    <#
    .SYNOPSIS
        Does this listed agent id actually resolve on the daemon?
    .DESCRIPTION
        `paseo ls` is answered from the agent store, which outlives the daemon's
        live session table, so a listing row is a CLAIM, not proof the agent
        exists. Measured 2026-11-04 (bead cl-common-vv7): `de03ce64` was listed
        with status=running and adopted as an occupant while the daemon answered
        "Agent not found" for it - a phantom occupant holding a real slot, and
        indistinguishable from a genuine cap hit to the caller.

        `paseo inspect <id>` is the existence check:
          $true  - the daemon resolved the id;
          $false - the daemon answered AGENT_NOT_FOUND (a phantom);
          $null  - cannot tell (inspect missing, failed some other way, or
                   returned an unreadable payload). A failed query is NOT
                   evidence of a phantom: callers keep the status verdict, so a
                   flaky daemon cannot silently disable the cap.
        Verdicts are cached for the run: one inspect per candidate id.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$AgentId,
        [string]$Paseo = ''
    )

    if ([string]::IsNullOrWhiteSpace($AgentId)) { return $false }
    if ([string]::IsNullOrWhiteSpace($Paseo)) { $Paseo = Resolve-PaseoCli }
    if ([string]::IsNullOrWhiteSpace($Paseo)) { return $null }
    if (-not (Get-Variable -Name AgentExistenceCache -Scope Script -ErrorAction Ignore)) {
        $script:AgentExistenceCache = @{}
    }
    if ($script:AgentExistenceCache.ContainsKey($AgentId)) { return $script:AgentExistenceCache[$AgentId] }
    $verdict = $null
    try {
        $raw = & $Paseo inspect $AgentId --json 2>$null | Out-String
        if ($LASTEXITCODE -eq 0) { $verdict = $true }
        elseif ($raw -match 'AGENT_NOT_FOUND') { $verdict = $false }
    }
    catch { $verdict = $null }
    $script:AgentExistenceCache[$AgentId] = $verdict
    return $verdict
}

function Test-ProviderMatch {
    <#
    .SYNOPSIS
        Does a live agent's provider string belong to this route? Unresolved
        route ids (for example, codex/gpt-6-luna) match by harness prefix.
    #>
    param([string]$AgentProvider, [string]$RouteProvider)

    if ([string]::IsNullOrWhiteSpace($AgentProvider) -or [string]::IsNullOrWhiteSpace($RouteProvider)) { return $false }
    if ($RouteProvider -match '<verify') {
        $harness = ($RouteProvider -split '/')[0]
        return $AgentProvider.StartsWith("$harness/", [StringComparison]::OrdinalIgnoreCase)
    }
    return $AgentProvider.Equals($RouteProvider, [StringComparison]::Ordinal)
}

function Test-RouteProviderId {
    <#
    .SYNOPSIS
        Can this route's provider id be handed straight to `paseo run --provider`?
    .DESCRIPTION
        A route is only dispatchable if its `provider` is ONE plain
        'provider/model' string. Two shapes are provably rejected by Paseo and
        must never reach a dispatch:

        * a serialized tuple/array (the DeepSeek Harness ACP catalog renders its
          model as ["deepseek-official","deepseek-v4.1-flash"]; copied into a
          route it is not a provider/model id at all), and
        * an opencode model id without its nested '<providerID>/<modelID>'
          segment - Paseo's opencode adapter splits the model part again and
          throws "OpenCode model must be provider/model" (observed 2026-11-02 on
          'opencode/deepseek-v4.1-flash-free').

        Deliberately shape-only: no provider is queried, so the check is cheap,
        deterministic, and safe to call inside the state lock. An unresolved
        placeholder ('devin/<verify-at-dispatch>') still passes - it is a real
        provider/model pair whose model is chosen at dispatch time.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Provider)

    if ([string]::IsNullOrWhiteSpace($Provider)) {
        return [pscustomobject]@{ Ok = $false; Reason = 'the provider id is empty' }
    }
    if ($Provider -match '[\s\[\]"{},'']') {
        return [pscustomobject]@{ Ok = $false; Reason = 'it contains JSON-array/quote/whitespace characters, so it is a serialized tuple rather than one provider id' }
    }
    $slash = $Provider.IndexOf('/')
    if ($slash -lt 1 -or $slash -eq $Provider.Length - 1) {
        return [pscustomobject]@{ Ok = $false; Reason = 'it is not provider/model (exactly one slash, with a provider before it and a model after it)' }
    }
    $providerPart = $Provider.Substring(0, $slash)
    $modelPart = $Provider.Substring($slash + 1)
    if ($providerPart -eq 'opencode' -and $modelPart -notmatch '/') {
        return [pscustomobject]@{ Ok = $false; Reason = "the opencode provider needs a nested model id '<providerID>/<modelID>' (for example opencode-go/deepseek-v4.1-flash), and '$modelPart' has no inner slash" }
    }
    return [pscustomobject]@{ Ok = $true; Reason = '' }
}

function Assert-RouteProviderId {
    <#
    .SYNOPSIS
        Fail closed when the selected route cannot be passed to `paseo run`.
    .DESCRIPTION
        Called on the route the gate is about to hand back. A malformed id must
        stop the dispatch HERE, with the pool, the route and the offending value
        named, instead of letting a caller spawn and die on the provider. The
        refusal writes no reservation, so it cannot leak occupancy.
    #>
    param(
        [Parameter(Mandatory)][string]$PoolId,
        [Parameter(Mandatory)][string]$RouteRole,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Provider,
        [Parameter(Mandatory)][hashtable]$Paths
    )

    $check = Test-RouteProviderId -Provider $Provider
    if ($check.Ok) { return }
    $message = "Route '$PoolId/$RouteRole' has an unusable provider id '$Provider': $($check.Reason). `paseo run --provider` accepts one plain '<provider>/<model>' string, so a dispatcher cannot use this slot; fix that route's provider field in assets/agent-capacity.json."
    Write-LogLine -Path $Paths.ErrorLog -Record @{
        ts = (Get-Date).ToString('o'); event = 'spawn-refused'; pool = $PoolId; role = $RouteRole
        errorCode = 'ROUTE-PROVIDER-ID'; provider = $Provider; message = $message
    }
    throw $message
}

function Test-PoolMatch {
    <#
    .SYNOPSIS
        Does a live agent draw on this pool's KEY SET?
    .DESCRIPTION
        Deliberately broader than a route match: the cap is per wallet, so any
        provider sharing the wallet counts even when it has no registry route
        (observed: a standalone `opencode-go/deepseek-v4-pro` alias alongside the
        DeepSeek V4.1 Flash primary - same OPENCODE_GO* wallet, different model id).
    #>
    param([string]$AgentProvider, [Parameter(Mandatory)]$Pool)

    if ([string]::IsNullOrWhiteSpace($AgentProvider)) { return $false }
    $prefixes = @(Get-Prop $Pool 'matchPrefixes' @())
    if ($prefixes.Count -eq 0) {
        $harness = [string](Get-Prop $Pool 'harness' '')
        if ($harness) { $prefixes = @("$harness/") }
    }
    foreach ($prefix in $prefixes) {
        if ($AgentProvider.StartsWith([string]$prefix, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Test-AgentLive {
    <#
    .SYNOPSIS
        Is this `paseo ls` record a genuinely live agent - that is, a slot holder?
    .DESCRIPTION
        Occupancy is a claim about RIGHT NOW, so only a live Paseo lifecycle
        state counts: `running` or `initializing`. Every other state - `idle`
        (between turns, parked, or idle-finished), `closed`, `error`/`errored`,
        `failed`, `stopped`, `archived`, and any unknown value - is not a live
        occupant, however recently the record was created.

        Why this exists: enumerating `paseo ls` records and counting every
        record (or treating a stale `running` label as truth) inflated
        PoolUsed, and the capacity gate then refused dispatches that would
        have fit. Measured 2026-11-03: 9 "adopted/running" occupants against 2
        agents that were actually running; the rest were idle/closed history.

        Additional evidence is used where the source records it:
        * an `archived` flag / `archivedAt` instant is decisive even when the
          status still says `running`;
        * a recorded heartbeat (`heartbeatAt`, `lastEventAt`,
          `lastActivityAt`, `lastSeenAt`, `updatedAt`) must be inside the
          freshness window;
        * a recorded local `pid` must still resolve to a process.
        Absent evidence is NOT treated as evidence of death: the lifecycle
        status then stands, so a source that records no heartbeat (today's
        `paseo ls --json` returns no such field) keeps working unchanged.
    #>
    param(
        [Parameter(Mandatory)]$Agent,
        [DateTime]$Now = (Get-Date),
        [int]$FreshnessMinutes = 15
    )

    $status = ([string](Get-Prop $Agent 'status' '')).Trim().ToLowerInvariant()
    $stateLabel = if ($status) { $status } else { 'unknown' }
    $archivedFlag = Get-Prop $Agent 'archived' $null
    $archivedAt = [string](Get-Prop $Agent 'archivedAt' '')
    if ($archivedFlag -eq $true -or -not [string]::IsNullOrWhiteSpace($archivedAt) -or $status -eq 'archived') {
        return [pscustomobject]@{ Live = $false; Terminal = $true; State = $stateLabel; Reason = 'archived' }
    }

    if ($status -ne 'running' -and $status -ne 'initializing') {
        $terminal = $status -in @('closed', 'error', 'errored', 'failed', 'stopped', 'deleted')
        return [pscustomobject]@{
            Live     = $false
            Terminal = $terminal
            State    = $stateLabel
            Reason   = if ($terminal) { "terminal state '$status'" } else { "status '$status' is not running or initializing" }
        }
    }

    foreach ($field in @('heartbeatAt', 'lastEventAt', 'lastActivityAt', 'lastSeenAt', 'updatedAt')) {
        $raw = [string](Get-Prop $Agent $field '')
        if ([string]::IsNullOrWhiteSpace($raw)) { continue }
        $beat = [DateTime]::MinValue
        if (-not [DateTime]::TryParse($raw, [ref]$beat)) { break }  # unreadable: status stands
        if ($beat -lt $Now.AddMinutes(-$FreshnessMinutes)) {
            $ageMinutes = [int]($Now - $beat).TotalMinutes
            return [pscustomobject]@{ Live = $false; Terminal = $false; State = $stateLabel; Reason = "heartbeat stale ($ageMinutes min old)" }
        }
        break
    }

    $processId = 0
    [void][int]::TryParse([string](Get-Prop $Agent 'pid' 0), [ref]$processId)
    $agentHost = [string](Get-Prop $Agent 'host' (Get-Prop $Agent 'hostId' ''))
    if ($processId -gt 0 -and [string]::IsNullOrWhiteSpace($agentHost)) {
        # Only a local pid can be checked from this host; a remote agent's pid
        # would look dead here, so its status stays authoritative.
        $process = Get-Process -Id $processId -ErrorAction Ignore
        if ($null -eq $process) {
            return [pscustomobject]@{ Live = $false; Terminal = $true; State = $stateLabel; Reason = "pid $processId is not running" }
        }
    }

    return [pscustomobject]@{ Live = $true; Terminal = $false; State = $stateLabel; Reason = '' }
}

function Register-CallerSession {
    <#
    .SYNOPSIS
        Record the dispatching session so caps count subagents, never sessions.
    .DESCRIPTION
        Operator rule 2026-10-09: caps bound concurrent subagent workers; an
        interactive/dispatcher session (this shell's PASEO_AGENT_ID) never
        occupies a slot. Called on Acquire; upserts state.sessions[] and prunes
        sessions whose agent vanished from `paseo ls`. Raw-CLI dispatchers
        self-register on their first Acquire (the skill already mandates
        Acquire-before-run); a session that never touches the gate stays
        visible as an adopted agent until the idle grace drops it.
    #>
    param(
        [Parameter(Mandatory)]$State,
        [array]$LiveAgents = @(),
        [bool]$Reconcile = $true
    )
    $me = [string]$env:PASEO_AGENT_ID
    if ([string]::IsNullOrWhiteSpace($me)) { return }
    $kept = [System.Collections.Generic.List[object]]::new()
    foreach ($s in @(Get-Prop $State 'sessions' @())) {
        $sid = [string](Get-Prop $s 'agentId' '')
        if ([string]::IsNullOrWhiteSpace($sid) -or $sid -eq $me) { continue }
        if ($Reconcile -and $LiveAgents.Count -gt 0) {
            $gone = ($LiveAgents | Where-Object { [string](Get-Prop $_ 'id' '') -eq $sid } | Select-Object -First 1) -eq $null
            if ($gone) { continue }
        }
        $kept.Add($s)
    }
    $kept.Add(@{
        agentId = $me
        cwd = [string]$env:PASEO_AGENT_CWD
        registeredAt = (Get-Date).ToString('o')
    })
    $State['sessions'] = @($kept)
}

function Get-Occupancy {
    <#
    .SYNOPSIS
        Unified occupancy for one pool: reservations plus adopted live agents.
    .DESCRIPTION
        Operator rule 2026-10-09: caps count subagents, never interactive
        sessions (state.sessions[], self-registered on Acquire), and a record
        counts only while the agent is GENUINELY LIVE - `running` or
        `initializing` (see Test-AgentLive). Idle, closed, errored and
        archived records never hold a slot, no matter how new they are: the
        2026-11-03 defect counted historic idle/closed sessions and inflated
        PoolUsed (9 occupants against 2 running agents), which manufactured
        "pool is saturated" refusals.

        * A RESERVATION is a deliberate spawn from this gate. While its agent
          is live it is counted. When the agent is idle or in any other
          non-terminal state the reservation is kept (the agent may resume)
          but not counted; a terminal state (closed/errored/failed/archived)
          drops the reservation outright. Reservation-only accounting (no live
          query at all) still bounds an unregistered claim by
          defaults.reservationTtlMinutes, never "unknown, so forever" -
          a registered entry has no expiresAt and would otherwise hold a slot
          for good (measured 2026-11-02: 9 stale reservations counted at once).
          Only when neither the live agent nor a timestamp exists does a
          deliberate claim keep counting: two unknowns are not evidence of
          staleness.
        * An ADOPTED agent (spawned without going through the gate) counts
          only while genuinely live; every non-live record is named in
          Skipped (agent id, source, state, age) and counted nowhere.
        * An id that the daemon cannot resolve is a PHANTOM, never an
          occupant: `paseo ls` rows are claims, and `paseo inspect` is the
          check (see Resolve-AgentExistence). Both an adopted row and a
          reservation naming that id are named in Skipped with state
          'id-not-found' and count nowhere (measured 2026-11-04,
          bead cl-common-vv7: a listed `running` row the daemon did not know
          consumed a real slot and made a refusal indistinguishable from a
          genuine cap hit).
        * When the live query cannot be made (daemon unreachable, CLI missing)
          a reservation is counted only inside defaults.reservationTtlMinutes
          of its own createdAt, as 'unverified': the slot is bounded rather
          than pinned. A worker that finishes with no Release therefore frees
          its slot on a timer even with no live state to reconcile against.

        Reservations past their TTL, entries whose agent is gone from
        `paseo ls`, and agents that are not live are pruned - a worker that
        dies without a Release must not leak a slot. Every exclusion is named
        in Skipped (agent id, source, state, age) so `-Mode Status` can say
        what it counted and what it left out.
    #>
    param(
        [Parameter(Mandatory)]$Registry,
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$PoolId,
        # NOT Mandatory: an empty array is a valid (and common) input - a fresh
        # host, every agent archived, or a stubbed CLI. Mandatory rejects it.
        [array]$LiveAgents = @(),
        [Parameter(Mandatory)][hashtable]$Paths,
        [bool]$Reconcile = $true
    )

    $poolDef = Get-Prop (Get-Prop $Registry 'pools' @{}) $PoolId
    if ($null -eq $poolDef) { throw "Unknown pool '$PoolId'." }
    $routes = @(Get-Prop $poolDef 'routes' @())
    $defaults = Get-Prop $Registry 'defaults' @{}
    $ttl = [int](Get-Prop $defaults 'reservationTtlMinutes' 30)
    $idleGrace = [int](Get-Prop $defaults 'idleGraceMinutes' 10)
    $freshness = [int](Get-Prop $defaults 'liveFreshnessMinutes' 15)
    $now = Get-Date

    $occupants = [System.Collections.Generic.List[object]]::new()
    $keepEntries = [System.Collections.Generic.List[object]]::new()
    $skipped = [System.Collections.Generic.List[object]]::new()
    $seenAgents = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)

    # Operator rule 2026-10-09: caps count subagents, never sessions. Prune
    # session records whose agent vanished; the survivors are skipped in the
    # adopted sweep below (a reservation naming a session outright is
    # pathological and keeps counting — pending spawns must never be dropped).
    $sessionIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $keptSessions = [System.Collections.Generic.List[object]]::new()
    foreach ($s in @(Get-Prop $State 'sessions' @())) {
        $sid = [string](Get-Prop $s 'agentId' '')
        if ([string]::IsNullOrWhiteSpace($sid)) { continue }
        if ($Reconcile -and $LiveAgents.Count -gt 0) {
            $present = ($LiveAgents | Where-Object { [string](Get-Prop $_ 'id' '') -eq $sid } | Select-Object -First 1) -ne $null
            if (-not $present) { continue }
        }
        [void]$sessionIds.Add($sid)
        $keptSessions.Add($s)
    }
    $State['sessions'] = @($keptSessions)

    foreach ($entry in @(Get-Prop $State 'entries' @())) {
        if ((Get-Prop $entry 'pool') -ne $PoolId) { $keepEntries.Add($entry); continue }
        $expires = [DateTime]::MinValue
        $expiresRaw = Get-Prop $entry 'expiresAt' ''
        if ($expiresRaw) { [DateTime]::TryParse([string]$expiresRaw, [ref]$expires) | Out-Null }
        $entryBorn = [DateTime]::MinValue
        $entryBornRaw = Get-Prop $entry 'createdAt' ''
        if ($entryBornRaw) { [DateTime]::TryParse([string]$entryBornRaw, [ref]$entryBorn) | Out-Null }
        if ($entryBorn -eq [DateTime]::MinValue) { $entryBorn = $null }
        $agentId = [string](Get-Prop $entry 'agentId' '')
        $entryRole = [string](Get-Prop $entry 'role' '')
        if (-not $agentId) {
            if ($expires -ne [DateTime]::MinValue -and $expires -lt $now) { continue }  # expired reservation
            # Reservation-only accounting has no live state to bound it, so the
            # TTL is the bound: a claim we cannot verify must not hold a slot
            # forever. The entry itself is kept so a later reconcile can still
            # prove or refute it.
            if (-not $Reconcile -and $null -ne $entryBorn -and $entryBorn -lt $now.AddMinutes(-$ttl)) {
                $skipped.Add([pscustomobject]@{ Pool = $PoolId; Role = $entryRole; Source = 'reservation'; AgentId = ''; KeyName = [string](Get-Prop $entry 'keyName' ''); State = 'unverified'; AgeMinutes = [int]($now - $entryBorn).TotalMinutes })
                $keepEntries.Add($entry)
                continue
            }
            $occupants.Add([pscustomobject]@{ Pool = $PoolId; Role = $entryRole; Source = 'reservation'; AgentId = ''; KeyName = [string](Get-Prop $entry 'keyName' ''); State = 'pending'; AgeMinutes = if ($null -ne $entryBorn) { [int]($now - $entryBorn).TotalMinutes } else { $null } })
            $keepEntries.Add($entry)
            continue
        }
        $live = $LiveAgents | Where-Object { $_.id -eq $agentId } | Select-Object -First 1
        if ($null -eq $live) {
            if ($Reconcile) {
                # Gone from `paseo ls` => archived/stopped: release the slot.
                continue
            }
            # Cannot ask: the reservation's own createdAt is the only bound, so
            # an unreachable daemon cannot pin a finished worker's slot forever.
            if ($null -ne $entryBorn -and $entryBorn -lt $now.AddMinutes(-$ttl)) {
                $skipped.Add([pscustomobject]@{ Pool = $PoolId; Role = $entryRole; Source = 'reservation'; AgentId = $agentId; KeyName = [string](Get-Prop $entry 'keyName' ''); State = 'unverified'; AgeMinutes = [int]($now - $entryBorn).TotalMinutes })
                $keepEntries.Add($entry)
                continue
            }
            $occupants.Add([pscustomobject]@{ Pool = $PoolId; Role = $entryRole; Source = 'reservation'; AgentId = $agentId; KeyName = [string](Get-Prop $entry 'keyName' ''); State = 'unverified'; AgeMinutes = if ($null -ne $entryBorn) { [int]($now - $entryBorn).TotalMinutes } else { $null } })
            $keepEntries.Add($entry)
            continue
        }
        $verdict = Test-AgentLive -Agent $live -Now $now -FreshnessMinutes $freshness
        if (-not $verdict.Live) {
            if ($verdict.Terminal) {
                # Closed/errored/archived: the agent cannot come back, so the
                # reservation is dropped exactly as a vanished agent's is.
                continue
            }
            # Idle or otherwise non-live but not terminal: keep the entry so a
            # resumed agent is counted again, but free the slot now.
            [void]$seenAgents.Add($agentId)
            $born = ConvertFrom-PaseoAge ([string](Get-Prop $live 'created' ''))
            if ($null -eq $born) { $born = $entryBorn }
            $ageMinutes = if ($null -ne $born) { [int]($now - $born).TotalMinutes } else { $null }
            # The label keeps the long-standing idle-beyond-grace signal while
            # never letting any non-live state hold a slot.
            $skipState = if ($verdict.State -eq 'idle' -and ($null -eq $ageMinutes -or $ageMinutes -ge $idleGrace)) { 'idle-beyond-grace' } else { $verdict.State }
            $skipped.Add([pscustomobject]@{ Pool = $PoolId; Role = $entryRole; Source = 'reservation'; AgentId = $agentId; KeyName = [string](Get-Prop $entry 'keyName' ''); State = $skipState; AgeMinutes = $ageMinutes })
            $keepEntries.Add($entry)
            continue
        }
        if ((Resolve-AgentExistence -AgentId $agentId) -eq $false) {
            # A phantom id resolves to no agent, so it holds no slot: release it
            # exactly as a vanished agent's reservation is released, and name it
            # once (seenAgents keeps the adopted sweep from repeating the row).
            [void]$seenAgents.Add($agentId)
            $born = ConvertFrom-PaseoAge ([string](Get-Prop $live 'created' ''))
            if ($null -eq $born) { $born = $entryBorn }
            $skipped.Add([pscustomobject]@{ Pool = $PoolId; Role = $entryRole; Source = 'reservation'; AgentId = $agentId; KeyName = [string](Get-Prop $entry 'keyName' ''); State = 'id-not-found'; AgeMinutes = if ($null -ne $born) { [int]($now - $born).TotalMinutes } else { $null } })
            continue
        }
        [void]$seenAgents.Add($agentId)
        $occupants.Add([pscustomobject]@{ Pool = $PoolId; Role = $entryRole; Source = 'reservation'; AgentId = $agentId; KeyName = [string](Get-Prop $entry 'keyName' ''); State = $verdict.State; AgeMinutes = $null })
        $keepEntries.Add($entry)
    }

    if ($Reconcile) {
    foreach ($agent in $LiveAgents) {
        $agentId = [string](Get-Prop $agent 'id' '')
        if (-not $agentId) { continue }
        if ($seenAgents.Contains($agentId)) { continue }
        if ($sessionIds.Contains($agentId)) { continue }  # dispatcher session, never a slot
        $provider = [string](Get-Prop $agent 'provider' '')
        $model = [string](Get-Prop $agent 'model' '')
        if (-not $model) { $model = [string](Get-Prop (Get-Prop $agent 'config' @{}) 'model' '') }
        if (-not $model) { $model = [string](Get-Prop (Get-Prop $agent 'runtimeInfo' @{}) 'model' '') }
        if ($provider -and $model -and $provider -notmatch '/') { $provider = "$provider/$model" }
        if (-not (Test-PoolMatch -AgentProvider $provider -Pool $poolDef)) { continue }
        $verdict = Test-AgentLive -Agent $agent -Now $now -FreshnessMinutes $freshness
        if (-not $verdict.Live) {
            # A historic record for this pool is named, never counted. This is
            # the 2026-11-03 defect: idle/closed sessions adopted as running
            # occupants inflated PoolUsed and manufactured saturation.
            $created = ConvertFrom-PaseoAge ([string](Get-Prop $agent 'created' ''))
            $ageMinutes = if ($null -ne $created) { [int]($now - $created).TotalMinutes } else { $null }
            $skipState = if ($verdict.State -eq 'idle' -and ($null -eq $ageMinutes -or $ageMinutes -ge $idleGrace)) { 'idle-beyond-grace' } else { $verdict.State }
            $skipped.Add([pscustomobject]@{ Pool = $PoolId; Role = ''; Source = 'adopted'; AgentId = $agentId; KeyName = ''; State = $skipState; AgeMinutes = $ageMinutes })
            continue
        }
        if ((Resolve-AgentExistence -AgentId $agentId) -eq $false) {
            # `paseo ls` advertised a row the daemon cannot resolve: a phantom
            # occupant, not a slot holder (bead cl-common-vv7).
            $created = ConvertFrom-PaseoAge ([string](Get-Prop $agent 'created' ''))
            $ageMinutes = if ($null -ne $created) { [int]($now - $created).TotalMinutes } else { $null }
            $skipped.Add([pscustomobject]@{ Pool = $PoolId; Role = ''; Source = 'adopted'; AgentId = $agentId; KeyName = ''; State = 'id-not-found'; AgeMinutes = $ageMinutes })
            continue
        }
        $matched = $routes | Where-Object { Test-ProviderMatch -AgentProvider $provider -RouteProvider ([string](Get-Prop $_ 'provider' '')) } | Select-Object -First 1
        $role = if ($null -ne $matched) { [string](Get-Prop $matched 'role' '') } else { '' }
        $occupants.Add([pscustomobject]@{ Pool = $PoolId; Role = $role; Source = 'adopted'; AgentId = $agentId; KeyName = ''; State = $verdict.State; AgeMinutes = $null })
    }
    }

    $State['entries'] = @($keepEntries)
    return @{ Occupants = @($occupants); Skipped = @($skipped); Pool = $poolDef; Routes = $routes }
}

# ---------------------------------------------------------------------------
# Route health (cooldown + canary)
# ---------------------------------------------------------------------------

function Get-RouteKey { param([string]$PoolId, [string]$Role) return "$PoolId/$Role" }

function ConvertTo-WindowInstant {
    <#
    .SYNOPSIS
        Normalizes a stored failure-window value to a [DateTime].
    .DESCRIPTION
        Required because ConvertFrom-Json silently turns an ISO-8601 string
        back into a [DateTime]: a state round-trip changes how the value
        renders, so string comparison would see one window as two and the
        cooldown threshold would never be reached.
    #>
    param($Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [DateTime]) { return $Value }
    $dt = [DateTime]::MinValue
    if ([DateTime]::TryParse([string]$Value, [ref]$dt)) { return $dt }
    return $null
}

function ConvertFrom-PaseoAge {
    <#
    .SYNOPSIS
        Parses `paseo ls --json`'s relative `created` field into a [DateTime].
    .DESCRIPTION
        The field is a human string ("just now", "6 minutes ago",
        "1 days ago"), not a timestamp, so [DateTime]::TryParse never matches
        it. Returns $null when the age cannot be established - callers must
        treat that as "not evidence of youth", never as "new".
    #>
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $v = $Value.Trim().ToLowerInvariant()
    if ($v -eq 'just now') { return (Get-Date) }
    if ($v -match '^(\d+)\s*(second|minute|hour|day|week|month)s?\s+ago$') {
        $n = [int]$Matches[1]
        switch ($Matches[2]) {
            'second' { return (Get-Date).AddSeconds(-$n) }
            'minute' { return (Get-Date).AddMinutes(-$n) }
            'hour'   { return (Get-Date).AddHours(-$n) }
            'day'    { return (Get-Date).AddDays(-$n) }
            'week'   { return (Get-Date).AddDays(-7 * $n) }
            'month'  { return (Get-Date).AddDays(-30 * $n) }
        }
    }
    $dt = [DateTime]::MinValue
    if ([DateTime]::TryParse($Value, [ref]$dt)) { return $dt }
    return $null
}

function Get-RouteHealth {
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][string]$Key)

    $routes = Get-Prop $State 'routes' @{}
    if (-not $routes.Contains($Key)) {
        $routes[$Key] = @{ cooldownUntil = ''; failureWindows = @(); lastError = ''; lastErrorAt = '' }
    }
    return $routes[$Key]
}

function Get-PoolState {
    <#
    .SYNOPSIS
        Pool-level state: the calendar-day exhaustion window (Gemini's free-tier
        daily allowance) and why it was set.
    #>
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][string]$PoolId)

    $pools = Get-Prop $State 'pools' @{}
    if (-not $pools.Contains($PoolId)) {
        $pools[$PoolId] = @{ disabledUntil = ''; reason = ''; setAt = '' }
    }
    return $pools[$PoolId]
}

function Get-PoolDisabledUntil {
    <#
    .SYNOPSIS
        When the pool's calendar-day allowance returns; [DateTime]::MinValue
        when the pool is in circulation.
    #>
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][string]$PoolId)

    $raw = [string](Get-Prop (Get-PoolState -State $State -PoolId $PoolId) 'disabledUntil' '')
    if ([string]::IsNullOrWhiteSpace($raw)) { return [DateTime]::MinValue }
    $dt = [DateTime]::MinValue
    if ([DateTime]::TryParse($raw, [ref]$dt)) { return $dt }
    return [DateTime]::MinValue
}

function Get-KeyNames {
    <#
    .SYNOPSIS
        The pool's key env-var NAMES - never their values.
    #>
    param([Parameter(Mandatory)]$Pool)

    # A plain array, NOT `,@(...)`: the comma form double-wraps once a caller
    # also wraps with @(), and a nested array then fails the [string] cast.
    # Every call site wraps with @(), which is what stops an EMPTY result
    # unrolling to $null and breaking `$names.Count` under StrictMode.
    return @(Get-Prop $Pool 'keys' @() | ForEach-Object { [string](Get-Prop $_ 'name' '') } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Get-KeyState {
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][string]$KeyName)

    $keys = Get-Prop $State 'keys' @{}
    if (-not $keys.Contains($KeyName)) { $keys[$KeyName] = @{ disabledUntil = ''; reason = ''; setAt = '' } }
    return $keys[$KeyName]
}

function Get-KeyDisabledUntil {
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][string]$KeyName)

    $raw = [string](Get-Prop (Get-KeyState -State $State -KeyName $KeyName) 'disabledUntil' '')
    if ([string]::IsNullOrWhiteSpace($raw)) { return [DateTime]::MinValue }
    $dt = [DateTime]::MinValue
    if ([DateTime]::TryParse($raw, [ref]$dt)) { return $dt }
    return [DateTime]::MinValue
}

function Sync-PoolExhaustion {
    <#
    .SYNOPSIS
        Derive a keyed pool's day-window from its keys.
    .DESCRIPTION
        A keyed pool is out of circulation only when EVERY key is spent. The
        pool-level window is computed here and never set by hand, so one spent
        key can never take the whole executor down.
    #>
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][string]$PoolId, [Parameter(Mandatory)]$Pool)

    $names = @(Get-KeyNames -Pool $Pool)
    if ($names.Count -eq 0) { return $null }
    $now = Get-Date
    $exhausted = @()
    $live = @()
    foreach ($name in $names) {
        if ((Get-KeyDisabledUntil -State $State -KeyName $name) -gt $now) { $exhausted += $name } else { $live += $name }
    }
    $ps = Get-PoolState -State $State -PoolId $PoolId
    if ($live.Count -eq 0) {
        $latest = @($exhausted | ForEach-Object { Get-KeyDisabledUntil -State $State -KeyName $_ } | Sort-Object | Select-Object -Last 1)
        $ps['disabledUntil'] = if ($latest.Count) { ([datetime]$latest[0]).ToString('o') } else { (Get-NextCalendarDay -Now $now).ToString('o') }
        if ([string]::IsNullOrWhiteSpace([string](Get-Prop $ps 'reason' ''))) { $ps['reason'] = "all $($names.Count) keys spent for the day" }
    }
    else {
        $ps['disabledUntil'] = ''
        $ps['reason'] = ''
    }
    return [pscustomobject]@{ Exhausted = @($exhausted); Live = @($live); PoolDisabled = ($live.Count -eq 0) }
}

function Resolve-KeySelection {
    <#
    .SYNOPSIS
        The key (env-var NAME) a keyed pool should spawn on.
    .DESCRIPTION
        The first key that is neither spent for the day nor already held by a
        live reservation. One agent per key is what keeps each agent on its own
        budget and makes a future cap > 1 safe.
    #>
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][string]$PoolId, [Parameter(Mandatory)]$Pool, [array]$Occupants = @())

    $names = @(Get-KeyNames -Pool $Pool)
    if ($names.Count -eq 0) { return [pscustomobject]@{ KeyName = ''; Spent = @(); InUse = @(); Free = @() } }
    $now = Get-Date
    $spent = @(); $inUse = @(); $free = @()
    foreach ($name in $names) {
        if ((Get-KeyDisabledUntil -State $State -KeyName $name) -gt $now) { $spent += $name; continue }
        if (@($Occupants | Where-Object { $_.KeyName -eq $name }).Count -gt 0) { $inUse += $name; continue }
        $free += $name
    }
    return [pscustomobject]@{
        KeyName = if ($free.Count) { [string]$free[0] } else { '' }
        Spent   = @($spent)
        InUse   = @($inUse)
        Free    = @($free)
    }
}

# ---------------------------------------------------------------------------
# L2 dispatch modes: waterfall + round-robin (plan dispatch-modes-plan.md §2)
# ---------------------------------------------------------------------------
# Split (L1 contract, preserved): the SELECTORS below are pure — ordered key
# names in, one key (or a refusal reason) out. They emit only
# filled-cap / pool-cap-reached / no-eligible-keys. The CALLER adapter
# (Resolve-DispatchedKeySelection) owns every gate-state verdict: it filters
# spent/busy keys out of eligibleKeys BEFORE invoking a selector and prepends
# the matching key-spent / key-busy-skip debug entries, so the trail stays
# complete. Canary verdicts never enter the pure call — only the adapter reads
# them (L3 owns writing them; L2 reads state.dispatch.canaryVerdicts when
# present and treats a missing store as "no verdicts").
#
# Reference: Skills/dispatch-waterfall/REFERENCE.md,
#            Skills/dispatch-round-robin/REFERENCE.md (same branch).

# ---------------------------------------------------------------------------
# F3: profile-level mode selection (explicit profile field, never a default flip)
# ---------------------------------------------------------------------------
# Source: 00Intake/2026-10-17-dispatch-modes-cross-repo-followups.md (F3). Mode
# selection may be owned by an EXPLICIT optional Paseo profile field; it must
# never be closed by flipping a registry default (that decision, D4, stays open
# and operator-owned). Absent field = today's behavior, byte-identical.

function Get-DispatchModeValues {
    <#
    .SYNOPSIS
        The legal dispatch modes - one home for -DispatchMode and a profile field.
    .DESCRIPTION
        -DispatchMode validates against its own literal ValidateSet (PowerShell
        requires a constant there), so this list and that attribute must agree;
        Tests/AgentCapacity.Profile.Tests.ps1 asserts they do. A profile field is
        checked against THIS list.
    #>
    return @('single-active', 'waterfall', 'round-robin')
}

function Resolve-ProfileDispatchMode {
    <#
    .SYNOPSIS
        The dispatch mode an explicit Paseo profile declares (fail-closed).
    .DESCRIPTION
        Accepts the object paseo_list_profiles returns, a hashtable of the same
        shape, or the profile's JSON text.

        * field absent / null / blank -> -Default (the caller's -DispatchMode
          value): omitting the field is byte-identical to the pre-F3 behavior.
        * a legal mode (any case) -> that mode, canonical lowercase.
        * anything else -> throws. An unknown value never degrades silently to
          single-active, and a profile never invents a fourth mode.
    #>
    param(
        $Profile = $null,
        [string]$Default = 'single-active'
    )

    $obj = $Profile
    if ($obj -is [string]) {
        if ([string]::IsNullOrWhiteSpace($obj)) { return $Default }
        try { $obj = $obj | ConvertFrom-Json -AsHashtable }
        catch { throw "Paseo profile is not readable as JSON: $($_.Exception.Message)" }
    }
    if ($null -eq $obj) { return $Default }
    if ($obj -is [array]) {
        throw "Paseo profile must be ONE profile object (paseo_list_profiles entry) or its JSON, not an array of $($obj.Count)."
    }

    $declared = Get-Prop $obj 'dispatchMode' $null
    if ($null -eq $declared) { return $Default }
    $profileName = [string](Get-Prop $obj 'name' '')
    $who = if ($profileName) { "Paseo profile '$profileName'" } else { 'Paseo profile' }
    $legal = @(Get-DispatchModeValues)

    if ($declared -isnot [string]) {
        throw "$who field 'dispatchMode' must be a string naming one of: $($legal -join ', '); got a $($declared.GetType().Name)."
    }
    $value = ([string]$declared).Trim()
    if ([string]::IsNullOrWhiteSpace($value)) { return $Default }

    foreach ($mode in $legal) {
        if ([string]::Equals($mode, $value, [System.StringComparison]::OrdinalIgnoreCase)) { return $mode }
    }
    throw "$who declares dispatchMode '$declared', which is not a legal dispatch mode. Use one of: $($legal -join ', ') - or omit the field to keep the -DispatchMode default ($Default)."
}

function Select-WaterfallKey {
    <#
    .SYNOPSIS
        Pure waterfall selector: first eligible key with room, in order.
    #>
    param(
        [array]$EligibleKeys = @(),
        $Caps = @{},
        $InFlight = @{},
        [int]$PoolCapRemaining = 0
    )

    $considered = [System.Collections.Generic.List[string]]::new()
    $skipped = [System.Collections.Generic.List[object]]::new()

    if (@($EligibleKeys).Count -eq 0) {
        return @{ Key = $null; Reason = 'no-eligible-keys'; Debug = @{ considered = @($considered); skipped = @($skipped) } }
    }
    if ($PoolCapRemaining -le 0) {
        return @{ Key = $null; Reason = 'pool-cap-reached'; Debug = @{ considered = @($considered); skipped = @($skipped) } }
    }
    foreach ($key in @($EligibleKeys)) {
        $considered.Add([string]$key)
        $cap = [int](Get-Prop $Caps ([string]$key) 0)
        $load = [int](Get-Prop $InFlight ([string]$key) 0)
        if ($load -lt $cap) {
            return @{ Key = [string]$key; Reason = $null; Debug = @{ considered = @($considered); skipped = @($skipped) } }
        }
        $skipped.Add(@{ key = [string]$key; why = 'filled-cap' })
    }
    return @{ Key = $null; Reason = 'filled-cap'; Debug = @{ considered = @($considered); skipped = @($skipped) } }
}

function Select-RoundRobinKey {
    <#
    .SYNOPSIS
        Pure round-robin selector: next eligible key at/after the cursor.
    #>
    param(
        [array]$EligibleKeys = @(),
        $Caps = @{},
        $InFlight = @{},
        [int]$Cursor = 0,
        [int]$PoolCapRemaining = 0
    )

    $list = @($EligibleKeys)
    $n = $list.Count
    $considered = [System.Collections.Generic.List[string]]::new()
    $skipped = [System.Collections.Generic.List[object]]::new()

    if ($n -eq 0) {
        return @{ Key = $null; Reason = 'no-eligible-keys'; CursorNext = $Cursor; Debug = @{ considered = @($considered); skipped = @($skipped) } }
    }
    if ($PoolCapRemaining -le 0) {
        return @{ Key = $null; Reason = 'pool-cap-reached'; CursorNext = $Cursor; Debug = @{ considered = @($considered); skipped = @($skipped) } }
    }
    for ($step = 0; $step -lt $n; $step++) {
        $i = ($Cursor + $step) % $n
        $key = [string]$list[$i]
        $considered.Add($key)
        $cap = [int](Get-Prop $Caps $key 0)
        $load = [int](Get-Prop $InFlight $key 0)
        if ($load -lt $cap) {
            return @{ Key = $key; Reason = $null; CursorNext = (($i + 1) % $n); Debug = @{ considered = @($considered); skipped = @($skipped) } }
        }
        $skipped.Add(@{ key = $key; why = 'filled-cap' })
    }
    return @{ Key = $null; Reason = 'filled-cap'; CursorNext = $Cursor; Debug = @{ considered = @($considered); skipped = @($skipped) } }
}

function Get-OpencodeGoSeam {
    <#
    .SYNOPSIS
        opencode-go order + caps from the cutover seam (never hardcoded).
    .DESCRIPTION
        Reads Skills/credential-rescue/assets/opencode-go-cutover.json beside
        this skill tree: activeKey (moved to index 0 = defaultCodingKey front),
        poolOrder, keyMaxConcurrent. Falls back to the registry
        keySources.poolEnvMachine order when the seam is unreadable; caps have
        NO fallback — unknown caps throw fail-closed in the adapter.
    #>
    param([Parameter(Mandatory)]$Pool)

    $skillsRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $seamPath = Join-Path $skillsRoot 'credential-rescue\assets\opencode-go-cutover.json'
    $order = @()
    $caps = @{}
    $active = ''
    $found = $false
    if (Test-Path -LiteralPath $seamPath) {
        try {
            $seam = Get-Content -LiteralPath $seamPath -Raw | ConvertFrom-Json -AsHashtable
            $active = [string](Get-Prop $seam 'activeKey' '')
            $order = @(Get-Prop $seam 'poolOrder' @() | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            foreach ($kv in @((Get-Prop $seam 'keyMaxConcurrent' @{}).GetEnumerator())) {
                $caps[[string]$kv.Key] = [int]$kv.Value
            }
            $found = $true
        }
        catch { $found = $false }
    }
    if ($order.Count -eq 0) {
        $order = @(Get-Prop (Get-Prop $Pool 'keySources' @{}) 'poolEnvMachine' @() | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    if ($active -and $order -contains $active) {
        $order = @($active) + @($order | Where-Object { $_ -ne $active })
    }
    return @{ Order = @($order); Caps = $caps; ActiveKey = $active; Found = $found; SeamPath = $seamPath }
}

function Get-DispatchBucket {
    <#
    .SYNOPSIS
        The state.dispatch bucket, normalized (older state files predate L2).
    #>
    param([Parameter(Mandatory)]$State)

    if (-not $State.Contains('dispatch') -or $null -eq $State['dispatch']) {
        $State['dispatch'] = @{ inFlight = @{}; cursor = 0; assignments = @(); canaryVerdicts = @{}; effectiveOrder = @(); lastMode = 'single-active' }
    }
    $d = $State['dispatch']
    if ($d -isnot [System.Collections.IDictionary]) {
        $d = @{ inFlight = @{}; cursor = 0; assignments = @(); canaryVerdicts = @{}; effectiveOrder = @(); lastMode = 'single-active' }
        $State['dispatch'] = $d
    }
    foreach ($k in @('inFlight', 'canaryVerdicts', 'lastErrorByKey')) {
        if (-not $d.Contains($k) -or $null -eq $d[$k]) { $d[$k] = @{} }
    }
    if (-not $d.Contains('assignments') -or $null -eq $d['assignments']) { $d['assignments'] = @() }
    if (-not $d.Contains('effectiveOrder') -or $null -eq $d['effectiveOrder']) { $d['effectiveOrder'] = @() }
    if (-not $d.Contains('cursor')) { $d['cursor'] = 0 }
    if (-not $d.Contains('lastMode')) { $d['lastMode'] = 'single-active' }
    return $d
}

function Test-DispatchCanaryExclusion {
    <#
    .SYNOPSIS
        Session-canary verdict -> adapter exclusion (L2 reads, L3 writes).
    .DESCRIPTION
        Plan §3 verdict -> eligibility (session-local), resolved here in L3:
        returns '' when the key stays eligible, 'key-spent' when the verdict
        removes it for the session (EXHAUSTED / NOT-SUBSCRIBED / AUTH), or
        'key-busy-skip' when it skips this dispatch (TRANSPORT / ERROR hold
        until one clean OK re-canary). BUSY / TIMEOUT stay ELIGIBLE (the failed
        dispatch was the skip; the verdict remains visible as caution in
        Status/Config) — 'keep eligible, skip once'. No verdict recorded =
        eligible.
    #>
    param($CanaryVerdicts, [Parameter(Mandatory)][string]$KeyName)

    if ($null -eq $CanaryVerdicts) { return '' }
    $v = Get-Prop $CanaryVerdicts $KeyName $null
    if ($null -eq $v) { return '' }
    $verdict = [string](Get-Prop $v 'verdict' '')
    if ([string]::IsNullOrWhiteSpace($verdict)) { return '' }
    switch ($verdict.ToUpperInvariant()) {
        'OK' { return '' }
        'BUSY' { return '' }
        'TIMEOUT' { return '' }
        'EXHAUSTED' { return 'key-spent' }
        'NOT-SUBSCRIBED' { return 'key-spent' }
        'AUTH' { return 'key-spent' }
        default { return 'key-busy-skip' }
    }
    return ''
}

# ---------------------------------------------------------------------------
# L3 dispatch canary wiring: session-start 5-parallel + on-failure re-canary
# (plan dispatch-modes-plan.md §3)
# ---------------------------------------------------------------------------
# ONE WRITE SHAPE, BOTH SIDES (L3 resolves the L2 shape question here):
#   state.dispatch.canaryVerdicts[<KeyName>] = @{ verdict = '<TOKEN>'; at = '<o-string>' }
# verdict is the Test-GoKey.ps1 first token (OK | EXHAUSTED | NOT-SUBSCRIBED |
# BUSY | TRANSPORT | AUTH | TIMEOUT | ERROR). L2's Test-DispatchCanaryExclusion
# and Get-DispatchKeyEntries read exactly these two fields — nothing else.
# Set-DispatchCanaryVerdict below is the single writer; the session path and
# the re-canary path both funnel through it. No migration: L2 never wrote
# verdicts, it only read them (a missing store means "no verdicts").
#
# SESSION-LOCAL, NEVER MEMORY: verdicts gate assignment only. The session path
# never touches day-spent; only an EXHAUSTED re-canary verdict (or a real
# provider error via Release, the pre-existing Test-DailyQuotaError path)
# writes a calendar-day disable. -SkipCanary bypasses the probe AND writes
# nothing — never a recorded spent state.
#
# LIVE-KEY RULE: the only live execution is Test-GoKey.ps1 -KeyNumber (the
# pool key value is resolved inside that script from Machine env, never here).
# Tests and fixtures set $env:AGENT_CAPACITY_CANARY_STUB to a script that
# accepts -KeyNumber and prints a fixture first-token line — no inference
# spend, no key values anywhere in this lane.

function Get-DispatchCanaryProbe {
    <#
    .SYNOPSIS
        Paid-model-first probe args for the opencode-go canary (plan §3).
    .DESCRIPTION
        Model + variant come from the seam canary.fast block (today
        opencode-go/deepseek-v4.1-flash at low, the fleet default; raise to
        high only for complex work). The probe must be a PAID model: a
        free-tier route would prove the free key, not the wallet the dispatch
        is about to spend. Fail-closed: a missing fast block or a free-tier
        model throws. Timeout/retries mirror the Test-GoKey defaults, bounded
        by the seam timeout where present.

        History: this guard used to refuse any model matching 'deepseek',
        because the *full-set* probe of that era was a transport-timeout sink.
        When the fleet moved to DeepSeek V4.1 Flash as the canary model
        (2026-10-28) the family check started refusing the very model it was
        meant to probe, so it now tests the property that actually matters —
        paid vs free — instead of a model family.
    #>
    $skillsRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $seamPath = Join-Path $skillsRoot 'credential-rescue\assets\opencode-go-cutover.json'
    $canaryScript = Join-Path $skillsRoot 'credential-rescue\scripts\Test-GoKey.ps1'
    if (-not (Test-Path -LiteralPath $canaryScript)) {
        throw "Dispatch canary probe not found: $canaryScript"
    }
    $model = ''
    $variant = ''
    $timeoutSeconds = 90
    if (Test-Path -LiteralPath $seamPath) {
        try {
            $seam = Get-Content -LiteralPath $seamPath -Raw | ConvertFrom-Json -AsHashtable
            $canary = Get-Prop $seam 'canary' @{}
            $t = [int](Get-Prop $canary 'timeoutSeconds' 0)
            if ($t -gt 0) { $timeoutSeconds = $t }
            $fast = @(Get-Prop $canary 'fast' @())
            if ($fast.Count -gt 0) {
                $model = [string](Get-Prop $fast[0] 'model' '')
                $variant = [string](Get-Prop $fast[0] 'variant' '')
            }
        }
        catch { }
    }
    if ([string]::IsNullOrWhiteSpace($model)) {
        throw "Dispatch canary has no paid-model-first probe: seam canary.fast is missing or unreadable ($seamPath)."
    }
    if ($model -match '(?i)(-free$|:free$|-free\b)') {
        throw "Dispatch canary refuses the free-tier probe model '$model': a free key cannot prove the paid pool it is guarding."
    }
    if ([string]::IsNullOrWhiteSpace($variant)) { $variant = 'high' }
    return @{
        Model = $model; Variant = $variant; TimeoutSeconds = $timeoutSeconds
        MaxRetries = 3; RetryDelaySeconds = 15; Script = $canaryScript
    }
}

function ConvertFrom-DispatchCanaryToken {
    <#
    .SYNOPSIS
        First-token line -> normalized canary verdict (unknown = ERROR).
    #>
    param([string]$Line = '')

    $first = @(($Line -split '\s+') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1)
    $t = if ($first.Count -gt 0) { [string]$first[0].ToUpperInvariant() } else { '' }
    if (@('OK', 'EXHAUSTED', 'NOT-SUBSCRIBED', 'BUSY', 'TRANSPORT', 'AUTH', 'TIMEOUT', 'ERROR') -contains $t) { return $t }
    return 'ERROR'
}

function Set-DispatchCanaryVerdict {
    <#
    .SYNOPSIS
        THE single writer of state.dispatch.canaryVerdicts (L3 shape).
    #>
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$KeyName,
        [Parameter(Mandatory)][string]$Verdict
    )

    $d = Get-DispatchBucket -State $State
    $store = Get-Prop $d 'canaryVerdicts' @{}
    $store[$KeyName] = @{ verdict = $Verdict; at = (Get-Date).ToString('o') }
    $d['canaryVerdicts'] = $store
    return $store[$KeyName]
}

function Get-DispatchKeyNumber {
    <#
    .SYNOPSIS
        Pool key env-var NAME -> Test-GoKey -KeyNumber (0 when not a pool key).
    #>
    param([Parameter(Mandatory)][string]$KeyName)

    if ($KeyName -match '^OPENCODE_GO([1-9])_KEY$') { return [int]$Matches[1] }
    return 0
}

function ConvertTo-DispatchErrorClass {
    <#
    .SYNOPSIS
        provider-error text -> closed failure class (names only, never values).
    #>
    param([string]$ErrorCode = '', [string]$Message = '')

    $c = "$ErrorCode $Message"
    if ($c -match '(?i)quota|exhaust|usage[ _]?limit|rate[ _]?limit|too many requests|\b429\b|DAILY_QUOTA') { return 'quota' }
    if ($c -match '(?i)unauthorized|invalid api key|authentication failed|NOT-SUBSCRIBED|no active subscr|insufficient|\b401\b|\b403\b') { return 'auth' }
    if ($c -match '(?i)\btransport\b|timeout|timed out|BUSY|overloaded|temporarily unavailable|service unavailable|provider is busy|too many concurrent|\b502\b|\b503\b|\b504\b') { return 'transport' }
    return 'provider'
}

function Write-DispatchCanaryFail {
    <#
    .SYNOPSIS
        Emit the existing canary-fail event for a non-OK verdict (no values).
    .DESCRIPTION
        Same event name the route canary uses; fields are names only (key NAME,
        verdict token, mode) — never key material, never probe detail text.
        NOT-SUBSCRIBED / AUTH additionally escalate to the operator (never a
        rescue target).
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Paths,
        [Parameter(Mandatory)][string]$KeyName,
        [Parameter(Mandatory)][string]$Verdict,
        [Parameter(Mandatory)][string]$DispatchMode
    )

    Write-LogLine -Path $Paths.ErrorLog -Record @{
        ts = (Get-Date).ToString('o'); event = 'canary-fail'; pool = 'opencode-go'
        keyName = $KeyName; verdict = $Verdict
        dispatchMode = $DispatchMode; errorCode = 'CANARY'
    }
    if ($Verdict -in @('NOT-SUBSCRIBED', 'AUTH')) {
        Write-Warning "$KeyName canaried $Verdict — remove from rotation and escalate to the operator (not a rescue target; the watch must not cut over onto it)."
    }
}

function Invoke-DispatchSessionCanary {
    <#
    .SYNOPSIS
        Session-start 5-parallel canary (plan §3): probe keys 1..5 at once.
    .DESCRIPTION
        Paid model first (the probe builder asserts the seam fast set); one
        Start-Job per key, bounded by the per-probe timeout. Verdicts are
        session-local eligibility input via the single writer — never day-spent.
        -SkipCanary bypasses the probe and writes nothing. A job that never
        answers in budget is TIMEOUT (eligible-with-caution); a crashed job is
        ERROR (held until a clean re-canary) — the safe direction each way.
    #>
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][hashtable]$Paths,
        [Parameter(Mandatory)][string]$DispatchMode,
        [switch]$SkipCanary
    )

    if ($SkipCanary) {
        return @{ Skipped = $true; Verdicts = @{} }
    }
    $probe = Get-DispatchCanaryProbe
    $stub = $env:AGENT_CAPACITY_CANARY_STUB
    $useStub = (-not [string]::IsNullOrWhiteSpace($stub)) -and (Test-Path -LiteralPath $stub)
    $keyNumbers = @(1, 2, 3, 4, 5)
    $jobs = @()
    foreach ($n in $keyNumbers) {
        if ($useStub) {
            $jobs += Start-Job -ScriptBlock {
                param($stubPath, $num)
                $o = & $stubPath -KeyNumber $num 2>&1 | Out-String
                [pscustomobject]@{ KeyNumber = $num; Line = @(($o -split "`r?`n") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1) }
            } -ArgumentList $stub, $n
        }
        else {
            $jobs += Start-Job -ScriptBlock {
                param($canaryPath, $num, $model, $variant, $to, $retries, $delay)
                $o = & $canaryPath -KeyNumber $num -Model $model -Variant $variant -TimeoutSeconds $to -MaxRetries $retries -RetryDelaySeconds $delay 2>&1 | Out-String
                [pscustomobject]@{ KeyNumber = $num; Line = @(($o -split "`r?`n") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1) }
            } -ArgumentList $probe.Script, $n, $probe.Model, $probe.Variant, $probe.TimeoutSeconds, $probe.MaxRetries, $probe.RetryDelaySeconds
        }
    }
    $budget = ([int]$probe.TimeoutSeconds * [int]$probe.MaxRetries) + ([int]$probe.RetryDelaySeconds * ([int]$probe.MaxRetries - 1)) + 30
    $null = Wait-Job -Job $jobs -Timeout $budget
    $verdicts = @{}
    try {
        for ($i = 0; $i -lt $jobs.Count; $i++) {
            $n = $keyNumbers[$i]
            $name = "OPENCODE_GO${n}_KEY"
            $token = 'ERROR'
            try {
                if ($jobs[$i].State -eq 'Completed') {
                    $r = Receive-Job -Job $jobs[$i]
                    $line = ''
                    if ($r) {
                        $first = @($r | ForEach-Object { [string](Get-Prop $_ 'Line' '') } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1)
                        if ($first.Count -gt 0) { $line = [string]$first[0] }
                    }
                    $token = ConvertFrom-DispatchCanaryToken -Line $line
                }
                elseif ($jobs[$i].State -eq 'Running') {
                    $token = 'TIMEOUT'
                }
            }
            catch { $token = 'ERROR' }
            $null = Set-DispatchCanaryVerdict -State $State -KeyName $name -Verdict $token
            $verdicts[$name] = $token
            if ($token -ne 'OK') {
                Write-DispatchCanaryFail -Paths $Paths -KeyName $name -Verdict $token -DispatchMode $DispatchMode
            }
        }
    }
    finally {
        foreach ($j in $jobs) {
            try { if ($j.State -eq 'Running') { Stop-Job -Job $j } } catch { }
            try { Remove-Job -Job $j -Force } catch { }
        }
    }
    return @{ Skipped = $false; Verdicts = $verdicts }
}

function Update-DispatchKeyAfterRecanary {
    <#
    .SYNOPSIS
        Apply one re-canary verdict to gate state (plan §3 mapping).
    .DESCRIPTION
        EXHAUSTED -> mark day-spent (calendar-day disable, same writer family
        as Release) + remove from rotation via the stored verdict; the
        watch/cutover path owns any active-pointer move — this function never
        repoints User env, auth.json, or config.json.
        NOT-SUBSCRIBED / AUTH -> stored verdict removes the key + operator
        escalate (never a rescue target, never day-spent).
        BUSY / TIMEOUT -> stored verdict, key stays eligible (the failed
        dispatch was the skip); caution stays visible in Status/Config.
        TRANSPORT / ERROR -> stored verdict holds the key out until one clean
        OK re-canary. OK -> clears any hold. Only EXHAUSTED writes day-spent.
    #>
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$KeyName,
        [Parameter(Mandatory)][string]$Verdict,
        [Parameter(Mandatory)][hashtable]$Paths,
        [Parameter(Mandatory)][string]$DispatchMode
    )

    $token = ConvertFrom-DispatchCanaryToken -Line $Verdict
    $now = Get-Date
    $null = Set-DispatchCanaryVerdict -State $State -KeyName $KeyName -Verdict $token
    if ($token -eq 'OK') {
        return [pscustomobject]@{ KeyName = $KeyName; Verdict = $token; Action = 'eligible' }
    }
    Write-DispatchCanaryFail -Paths $Paths -KeyName $KeyName -Verdict $token -DispatchMode $DispatchMode
    switch ($token) {
        'EXHAUSTED' {
            $ks = Get-KeyState -State $State -KeyName $KeyName
            $ks['disabledUntil'] = ($now.Date.AddDays(1)).ToString('o')
            $ks['reason'] = 'dispatch re-canary EXHAUSTED (weekly cap spent; watch/cutover owns any pointer move)'
            $ks['setAt'] = $now.ToString('o')
            Write-LogLine -Path $Paths.ErrorLog -Record @{
                ts = $now.ToString('o'); event = 'key-daily-exhausted'; pool = 'opencode-go'
                keyName = $KeyName; errorCode = 'DAILY_QUOTA'
                message = 'dispatch re-canary EXHAUSTED'; disabledUntil = [string]$ks['disabledUntil']
            }
            Write-Warning "$KeyName re-canaried EXHAUSTED — marked day-spent and removed from rotation (watch/cutover owns any active-pointer move)."
            return [pscustomobject]@{ KeyName = $KeyName; Verdict = $token; Action = 'day-spent' }
        }
        'NOT-SUBSCRIBED' {
            return [pscustomobject]@{ KeyName = $KeyName; Verdict = $token; Action = 'removed-escalated' }
        }
        'AUTH' {
            return [pscustomobject]@{ KeyName = $KeyName; Verdict = $token; Action = 'removed-escalated' }
        }
        'BUSY' {
            return [pscustomobject]@{ KeyName = $KeyName; Verdict = $token; Action = 'eligible-with-caution' }
        }
        'TIMEOUT' {
            return [pscustomobject]@{ KeyName = $KeyName; Verdict = $token; Action = 'eligible-with-caution' }
        }
        default {
            Write-Warning "$KeyName re-canaried $token — held out of rotation until one clean OK re-canary."
            return [pscustomobject]@{ KeyName = $KeyName; Verdict = $token; Action = 'held-until-clean-recanary' }
        }
    }
    return [pscustomobject]@{ KeyName = $KeyName; Verdict = $token; Action = 'held-until-clean-recanary' }
}

function Invoke-DispatchKeyRecanary {
    <#
    .SYNOPSIS
        On-failure single-key re-canary (plan §3): probe, then apply the mapping.
    .DESCRIPTION
        The dispatcher runs this for the failed agent's key before the key is
        trusted again. -SkipCanary bypasses the probe and changes nothing.
    #>
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$KeyName,
        [Parameter(Mandatory)][hashtable]$Paths,
        [Parameter(Mandatory)][string]$DispatchMode,
        [switch]$SkipCanary
    )

    if ($SkipCanary) {
        return [pscustomobject]@{ KeyName = $KeyName; Verdict = ''; Action = 'skipped'; Skipped = $true }
    }
    $n = Get-DispatchKeyNumber -KeyName $KeyName
    if ($n -lt 1) { throw "Cannot re-canary '$KeyName': not an OPENCODE_GO<n>_KEY pool key name." }
    $probe = Get-DispatchCanaryProbe
    $stub = $env:AGENT_CAPACITY_CANARY_STUB
    $raw = ''
    if ((-not [string]::IsNullOrWhiteSpace($stub)) -and (Test-Path -LiteralPath $stub)) {
        try { $raw = & $stub -KeyNumber $n 2>&1 | Out-String }
        catch { $raw = 'ERROR canary stub failed' }
    }
    else {
        try { $raw = & $probe.Script -KeyNumber $n -Model ([string]$probe.Model) -Variant ([string]$probe.Variant) -TimeoutSeconds ([int]$probe.TimeoutSeconds) -MaxRetries ([int]$probe.MaxRetries) -RetryDelaySeconds ([int]$probe.RetryDelaySeconds) 2>&1 | Out-String }
        catch { $raw = 'ERROR canary invocation failed' }
    }
    $firstLine = @(($raw -split "`r?`n") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1)
    $line = if ($firstLine.Count -gt 0) { [string]$firstLine[0] } else { '' }
    $token = ConvertFrom-DispatchCanaryToken -Line $line
    return (Update-DispatchKeyAfterRecanary -State $State -KeyName $KeyName -Verdict $token -Paths $Paths -DispatchMode $DispatchMode)
}

function Resolve-DispatchedKeySelection {
    <#
    .SYNOPSIS
        Caller adapter: eligibility + order from gate state, math from skills.
    .DESCRIPTION
        opencode-go only (L2 scope). Builds eligibleKeys (seam order,
        activeKey front) minus day-spent keys (key-spent) minus
        session-canary exclusions, invokes Select-WaterfallKey /
        Select-RoundRobinKey with inFlight + pool headroom, and prepends the
        adapter-side skip entries so the debug trail stays complete. The
        returned CursorNext / EffectiveOrder / Debug are computed only — the
        caller persists cursor, inFlight, and the assignment AFTER minting the
        reservation token (one write site, same state lock).
    #>
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$PoolId,
        [Parameter(Mandatory)]$Pool,
        [array]$Occupants = @(),
        [int]$PoolCapRemaining = 0,
        [Parameter(Mandatory)][ValidateSet('waterfall', 'round-robin')]
        [string]$DispatchMode
    )

    $seam = Get-OpencodeGoSeam -Pool $Pool
    if ($seam.Caps.Count -eq 0) {
        throw "Dispatch mode '$DispatchMode' needs per-key caps from the cutover seam, but none were readable ($($seam.SeamPath)). Stay on -DispatchMode single-active until the seam is present."
    }
    $effectiveOrder = @($seam.Order)
    $d = Get-DispatchBucket -State $State
    $now = Get-Date
    $adapterSkips = [System.Collections.Generic.List[object]]::new()
    $eligible = [System.Collections.Generic.List[string]]::new()
    foreach ($name in $effectiveOrder) {
        if ((Get-KeyDisabledUntil -State $State -KeyName $name) -gt $now) {
            $adapterSkips.Add(@{ key = $name; why = 'key-spent' })
            continue
        }
        $exclusion = Test-DispatchCanaryExclusion -CanaryVerdicts $d['canaryVerdicts'] -KeyName $name
        if ($exclusion) {
            $adapterSkips.Add(@{ key = $name; why = $exclusion })
            continue
        }
        $eligible.Add($name)
    }

    $inFlight = Get-Prop $d 'inFlight' @{}
    $cursor = 0
    try { $cursor = [int](Get-Prop $d 'cursor' 0) } catch { $cursor = 0 }
    if ($eligible.Count -gt 0) {
        $cursor = ((($cursor % $eligible.Count) + $eligible.Count) % $eligible.Count)
    }
    else { $cursor = 0 }

    if ($DispatchMode -eq 'waterfall') {
        $sel = Select-WaterfallKey -EligibleKeys @($eligible) -Caps $seam.Caps -InFlight $inFlight -PoolCapRemaining $PoolCapRemaining
        $cursorNext = $null
    }
    else {
        $sel = Select-RoundRobinKey -EligibleKeys @($eligible) -Caps $seam.Caps -InFlight $inFlight -Cursor $cursor -PoolCapRemaining $PoolCapRemaining
        $cursorNext = [int]$sel.CursorNext
    }
    $merged = @($adapterSkips) + @($sel.Debug.skipped)
    $orderIndex = -1
    if ($sel.Key) {
        $orderIndex = [Array]::IndexOf([string[]]@($effectiveOrder), [string]$sel.Key)
    }
    return @{
        KeyName        = if ($sel.Key) { [string]$sel.Key } else { '' }
        Reason         = $sel.Reason
        CursorNext     = $cursorNext
        CursorUsed     = $cursor
        EffectiveOrder = @($effectiveOrder)
        OrderIndex     = $orderIndex
        Caps           = $seam.Caps
        Debug          = @{ considered = @($sel.Debug.considered); skipped = @($merged) }
    }
}

function Sync-DispatchInFlight {
    <#
    .SYNOPSIS
        Prune mode assignments the same way reservations are pruned.
    .DESCRIPTION
        Drops assignments whose reservation TTL passed before registration,
        and (when reconciling) assignments whose agent vanished from `paseo
        ls` or is not genuinely live (see Test-AgentLive: only running or
        initializing holds a slot; idle/closed/errored/archived never do);
        decrements inFlight per dropped
        assignment, floored at 0. With no live state to reconcile against the
        assignment's own createdAt is the bound, so a registered assignment
        cannot pin a key's per-key count forever.
        Adopted live agents carry no key name, so they bind the pool total
        (via PoolCapRemaining) but never a per-key count — noted, not guessed.
        Single-active counters are untouched.
    #>
    param(
        [Parameter(Mandatory)]$State,
        [array]$LiveAgents = @(),
        [bool]$Reconcile = $true,
        [int]$TtlMinutes = 30,
        [int]$IdleGraceMinutes = 10,
        [int]$FreshnessMinutes = 15
    )

    $d = Get-DispatchBucket -State $State
    $inFlight = Get-Prop $d 'inFlight' @{}
    $kept = [System.Collections.Generic.List[object]]::new()
    $now = Get-Date
    foreach ($a in @(Get-Prop $d 'assignments' @())) {
        $agentId = [string](Get-Prop $a 'agentId' '')
        $drop = $false
        $expires = [DateTime]::MinValue
        $raw = [string](Get-Prop $a 'expiresAt' '')
        if ($raw) { [DateTime]::TryParse($raw, [ref]$expires) | Out-Null }
        if ([string]::IsNullOrWhiteSpace($agentId)) {
            if ($expires -ne [DateTime]::MinValue -and $expires -lt $now) { $drop = $true }
        }
        elseif ($Reconcile -and $LiveAgents.Count -gt 0) {
            $live = $LiveAgents | Where-Object { [string](Get-Prop $_ 'id' '') -eq $agentId } | Select-Object -First 1
            if ($null -eq $live) { $drop = $true }
            else {
                # One liveness rule for occupancy and per-key dispatch: an
                # idle/closed/archived agent is not holding its key either.
                $verdict = Test-AgentLive -Agent $live -Now $now -FreshnessMinutes $FreshnessMinutes
                if (-not $verdict.Live) { $drop = $true }
            }
        }
        else {
            # No live state to check (or the daemon answered with nothing), so
            # the assignment's own createdAt is the bound. Registration clears
            # expiresAt, and without this a single registered assignment inside
            # state.dispatch.inFlight would pin a key's per-key count forever -
            # the same leak the reservation TTL already prevents for slots.
            $born = [DateTime]::MinValue
            $bornRaw = [string](Get-Prop $a 'createdAt' '')
            if ($bornRaw) { [DateTime]::TryParse($bornRaw, [ref]$born) | Out-Null }
            if ($born -ne [DateTime]::MinValue -and $born -lt $now.AddMinutes(-$TtlMinutes)) { $drop = $true }
        }
        if ($drop) {
            $key = [string](Get-Prop $a 'key' '')
            if ($key -and $inFlight.Contains($key)) {
                $inFlight[$key] = [Math]::Max(0, [int]$inFlight[$key] - 1)
            }
            continue
        }
        $kept.Add($a)
    }
    $d['assignments'] = @($kept)
    $d['inFlight'] = $inFlight
}

function Add-DispatchAssignment {
    <#
    .SYNOPSIS
        Record one mode assignment: cursor + inFlight + attribution (L2 write).
    #>
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)]$Dispatched,
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$DispatchMode,
        [int]$ReservationTtlMinutes = 30
    )

    $d = Get-DispatchBucket -State $State
    $inFlight = Get-Prop $d 'inFlight' @{}
    $key = [string]$Dispatched.KeyName
    if ([string]::IsNullOrWhiteSpace($key)) { return }
    $inFlight[$key] = [int](Get-Prop $inFlight $key 0) + 1
    $d['inFlight'] = $inFlight
    if ($null -ne $Dispatched.CursorNext) { $d['cursor'] = [int]$Dispatched.CursorNext }
    $d['effectiveOrder'] = @($Dispatched.EffectiveOrder)
    $d['lastMode'] = $DispatchMode
    $d['assignments'] = @(@(Get-Prop $d 'assignments' @()) + @(@{
        token = $Token; agentId = ''; key = $key
        createdAt = (Get-Date).ToString('o'); expiresAt = (Get-Date).AddMinutes($ReservationTtlMinutes).ToString('o')
        dispatchMode = $DispatchMode
    }))
}

function Remove-DispatchAssignment {
    <#
    .SYNOPSIS
        Drop one mode assignment by token or agent id; decrement inFlight.
    #>
    param(
        [Parameter(Mandatory)]$State,
        [string]$Token = '',
        [string]$AgentId = ''
    )

    $d = Get-DispatchBucket -State $State
    $inFlight = Get-Prop $d 'inFlight' @{}
    $kept = [System.Collections.Generic.List[object]]::new()
    $dropped = $false
    foreach ($a in @(Get-Prop $d 'assignments' @())) {
        if (-not $dropped) {
            $match = $false
            if ($Token -and [string](Get-Prop $a 'token' '') -eq $Token) { $match = $true }
            elseif ($AgentId -and [string](Get-Prop $a 'agentId' '') -eq $AgentId) { $match = $true }
            if ($match) {
                $dropped = $true
                $key = [string](Get-Prop $a 'key' '')
                if ($key -and $inFlight.Contains($key)) {
                    $inFlight[$key] = [Math]::Max(0, [int]$inFlight[$key] - 1)
                }
                continue
            }
        }
        $kept.Add($a)
    }
    $d['assignments'] = @($kept)
    $d['inFlight'] = $inFlight
    return $dropped
}

function Test-DispatchWatchInterlock {
    <#
    .SYNOPSIS
        Modes and the overnight watch are mutually exclusive (plan §4).
    .DESCRIPTION
        Refuses waterfall/round-robin while the credential-rescue watch state
        file reads `watching`; single-active never blocks. Only an actual
        `watching` phase blocks — a missing, unreadable, or otherwise-phased
        file is not a watch in flight.
    #>
    param([Parameter(Mandatory)][string]$DispatchMode)

    if ($DispatchMode -eq 'single-active') { return }
    if ([string]::IsNullOrWhiteSpace($env:TEMP)) { return }
    $watchState = Join-Path $env:TEMP 'opencode\credential-rescue-watch\state.json'
    if (-not (Test-Path -LiteralPath $watchState)) { return }
    try {
        $phase = [string](Get-Prop ((Get-Content -LiteralPath $watchState -Raw) | ConvertFrom-Json -AsHashtable) 'phase' '')
        if ($phase -eq 'watching') {
            throw "Refusing -DispatchMode '$DispatchMode': the credential-rescue watch is active (state file reads 'watching'). Stop the watch first, or stay on -DispatchMode single-active (modes assume no concurrent single-active cutover)."
        }
    }
    catch {
        if ($_.Exception.Message -like 'Refusing -DispatchMode*') { throw }
    }
}

function Get-DispatchKeyEntries {
    <#
    .SYNOPSIS
        Plan §5 per-key surface (names only): Status keys[] + Config lines.
    .DESCRIPTION
        L2-owned values are real (eligibility, inFlight, caps, spent-until,
        session assignments); canaryVerdict/canaryAt come from the L3 single
        writer (Set-DispatchCanaryVerdict) and lastErrorClass from the L3
        Release hook (ConvertTo-DispatchErrorClass, cause only — verdicts stay
        probe-owned). Remaining budget stays unknown by rule — counts are
        spawns, never requests.
    #>
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)]$Pool)

    $seam = Get-OpencodeGoSeam -Pool $Pool
    $d = Get-DispatchBucket -State $State
    $now = Get-Date
    $verdicts = Get-Prop $d 'canaryVerdicts' @{}
    $lastErrors = Get-Prop $d 'lastErrorByKey' @{}
    $inFlight = Get-Prop $d 'inFlight' @{}
    $today = $now.Date
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($name in @($seam.Order)) {
        $untilRaw = [string](Get-Prop (Get-KeyState -State $State -KeyName $name) 'disabledUntil' '')
        $until = [DateTime]::MinValue
        if ($untilRaw) { [DateTime]::TryParse($untilRaw, [ref]$until) | Out-Null }
        $spent = $until -gt $now
        $v = Get-Prop $verdicts $name $null
        $exclusion = Test-DispatchCanaryExclusion -CanaryVerdicts $verdicts -KeyName $name
        $assigned = @(Get-Prop $d 'assignments' @() | Where-Object {
                [string](Get-Prop $_ 'key' '') -eq $name -and
                ([DateTime](Get-Prop $_ 'createdAt' '0001-01-01')) -ge $today
            }).Count
        $rows.Add([pscustomobject]@{
                name               = $name
                scope              = 'Machine'
                eligible           = ((-not $spent) -and ([string]::IsNullOrWhiteSpace($exclusion)))
                inFlight           = [int](Get-Prop $inFlight $name 0)
                keyMaxConcurrent   = if ($seam.Caps.Contains($name)) { [int]$seam.Caps[$name] } else { 0 }
                canaryVerdict      = if ($null -ne $v) { [string](Get-Prop $v 'verdict' '') } else { '' }
                canaryAt           = if ($null -ne $v) { [string](Get-Prop $v 'at' '') } else { '' }
                disabledUntil      = $untilRaw
                assignedThisSession = $assigned
                lastErrorClass     = [string](Get-Prop (Get-Prop $lastErrors $name @{}) 'class' '')
            })
    }
    return @{ Keys = @($rows); Found = $seam.Found; ActiveKey = $seam.ActiveKey }
}

function Test-DailyQuotaError {
    <#
    .SYNOPSIS
        Does this provider failure mean the pool's calendar-day allowance is gone?
    .DESCRIPTION
        Distinct from a route cooldown on purpose: a spent daily allowance is
        not a health problem, so the pool leaves circulation for the rest of the
        calendar day and is never canaried back early.
    #>
    param([Parameter(Mandatory)]$Pool, [string]$ErrorCode, [string]$Message)

    $quota = Get-Prop $Pool 'dailyQuota' @{}
    if (-not [bool](Get-Prop $quota 'enabled' $false)) { return $false }
    foreach ($code in @(Get-Prop $quota 'errorCodes' @())) {
        if ($ErrorCode -and $ErrorCode -ieq [string]$code) { return $true }
    }
    if ([string]::IsNullOrWhiteSpace($Message)) { return $false }
    foreach ($pattern in @(Get-Prop $quota 'messagePatterns' @())) {
        if ($Message -match [string]$pattern) { return $true }
    }
    return $false
}

function Get-NextCalendarDay {
    param([datetime]$Now = (Get-Date))
    return $Now.Date.AddDays(1)
}

function Resolve-SinceStart {
    <#
    .SYNOPSIS
        Turn a -Since value into a window start time.
    .DESCRIPTION
        Shared by Report and Config so the window grammar has one owner.
        Accepts `24h`, `7d`, `lastnight`, or any parseable DateTime.
    #>
    param([Parameter(Mandatory)]$Registry, [string]$Since, [datetime]$Now = (Get-Date))

    if ([string]::IsNullOrWhiteSpace($Since)) {
        $Since = [string](Get-Prop (Get-Prop $Registry 'defaults' @{}) 'reportDefaultSince' '24h')
    }
    # NOTE: switch is a statement - it cannot sit inside ( ) on a return.
    $window = switch -Regex ($Since) {
            '^(?i)lastnight$' {
                $at = [string](Get-Prop (Get-Prop $Registry 'defaults' @{}) 'lastNightStartsAt' '18:00')
                $t = [DateTime]::ParseExact($at, 'HH:mm', $null)
                $d = $Now.Date.AddDays(-1).AddHours($t.Hour).AddMinutes($t.Minute)
                if ($d -gt $Now) { $d = $d.AddDays(-1) }
                $d
            }
            '^(?i)(\d+)h$' { $Now.AddHours(-[int]$Matches[1]) }
            '^(?i)(\d+)d$' { $Now.AddDays(-[int]$Matches[1]) }
            default {
                $parsed = [DateTime]::MinValue
                if ([DateTime]::TryParse($Since, [ref]$parsed)) { $parsed } else { $Now.AddHours(-24) }
            }
        }
    return $window
}

function Get-PoolOrder {
    <#
    .SYNOPSIS
        Pool ids by priority ascending (Gemini first), name as the tie-break.
    #>
    param([Parameter(Mandatory)]$PoolTable)

    $ranked = foreach ($id in ($PoolTable.Keys | Sort-Object)) {
        [pscustomobject]@{ Id = $id; Priority = [int](Get-Prop $PoolTable[$id] 'priority' 999) }
    }
    return @($ranked | Sort-Object Priority, Id | ForEach-Object { $_.Id })
}

function Invoke-RouteCanary {
    <#
    .SYNOPSIS
        Canaries an opencode route before trusting it again after a cooldown.
    .DESCRIPTION
        Only opencode routes have a canary today (Test-OpencodeProvider.ps1).
        Any other pool returns $true with Canaried=$false - the caller must not
        read that as proof of health.
    #>
    param([Parameter(Mandatory)]$Pool, [Parameter(Mandatory)][string]$Provider)

    $canary = [string](Get-Prop $Pool 'canary' '')
    if ([string]::IsNullOrWhiteSpace($canary)) { return @{ Ok = $true; Canaried = $false; Detail = 'no canary for this pool' } }
    $canary = Expand-FleetPath $canary
    if (-not (Test-Path -LiteralPath $canary)) { return @{ Ok = $true; Canaried = $false; Detail = "canary script missing: $canary" } }
    if ($Provider -notmatch '^opencode/(.+)$') { return @{ Ok = $true; Canaried = $false; Detail = 'canary only covers opencode/* routes' } }
    $model = $Matches[1]
    $out = & $canary -Model $model 2>&1 | Out-String
    $ok = $LASTEXITCODE -eq 0
    return @{ Ok = $ok; Canaried = $true; Detail = if ($ok) { "canary passed on $model" } else { "canary failed on $model" } }
}

function Resolve-RouteSelection {
    <#
    .SYNOPSIS
        Picks the route AND the effort for a work role.
    .DESCRIPTION
        -Role names a WORK role (recon | review | fix | code | refactor), not a route:
        workRoles.<role>.route prefers a route and workRoles.<role>.thinking
        overrides that route's default effort. The pool's other routes stay
        eligible as failover, so a cooling primary still degrades to the
        alternate. A legacy route name (primary/alternate) is accepted as an
        explicit route pin.
    #>
    param(
        [Parameter(Mandatory)]$Registry,
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$PoolId,
        [Parameter(Mandatory)]$Pool,
        [Parameter(Mandatory)][array]$Routes,
        [string]$RequestedRole = 'any',
        [switch]$SkipCanary,
        [Parameter(Mandatory)][hashtable]$Paths
    )

    $policy = Get-Prop $Pool 'failurePolicy' (Get-Prop $Registry 'defaults' @{})
    $cooldownMinutes = [int](Get-Prop $policy 'cooldownMinutes' 60)
    $windowMinutes = [int](Get-Prop $policy 'windowMinutes' 15)
    $windowsToTrip = [int](Get-Prop $policy 'failureWindowsToTrip' 2)
    $now = Get-Date

    $workRoles = Get-Prop $Pool 'workRoles' @{}
    $routeRoles = @($Routes | ForEach-Object { [string](Get-Prop $_ 'role' '') })
    $workRole = if ([string]::IsNullOrWhiteSpace($RequestedRole) -or $RequestedRole -ieq 'any') {
        [string](Get-Prop $Pool 'defaultWorkRole' (Get-Prop (Get-Prop $Registry 'defaults' @{}) 'defaultWorkRole' 'code'))
    }
    else { $RequestedRole }

    $routePin = ''
    if ($workRoles.Contains($workRole)) {
        $routePin = [string](Get-Prop $workRoles[$workRole] 'route' '')
    }
    elseif ($workRole -in $routeRoles) {
        $routePin = $workRole
        $notes0 = "route pin '$workRole'"
    }
    else {
        throw "Pool '$PoolId' has no work role '$workRole'. Known work roles: $(($workRoles.Keys | Sort-Object) -join ', '); route pins: $($routeRoles -join ', ')."
    }

    # Preferred route first, then every other route as failover.
    $ordered = @()
    if ($routePin) { $ordered += @($Routes | Where-Object { [string](Get-Prop $_ 'role') -eq $routePin }) }
    $ordered += @($Routes | Where-Object { [string](Get-Prop $_ 'role') -ne $routePin })

    $notes = [System.Collections.Generic.List[string]]::new()
    $available = [System.Collections.Generic.List[object]]::new()
    foreach ($route in $ordered) {
        $role = [string](Get-Prop $route 'role' '')
        $key = Get-RouteKey $PoolId $role
        $health = Get-RouteHealth -State $State -Key $key
        $cooldownUntil = [DateTime]::MinValue
        $raw = [string](Get-Prop $health 'cooldownUntil' '')
        if ($raw) { [DateTime]::TryParse($raw, [ref]$cooldownUntil) | Out-Null }

        if ($cooldownUntil -ne [DateTime]::MinValue -and $cooldownUntil -gt $now) {
            $notes.Add("$role cooling down until $($cooldownUntil.ToString('HH:mm:ss'))")
            continue
        }
        if ($cooldownUntil -ne [DateTime]::MinValue) {
            # Cooldown expired - prove the route before trusting it again.
            if ($SkipCanary) {
                $notes.Add("$role cooldown expired (canary skipped)")
            }
            else {
                $probe = Invoke-RouteCanary -Pool $Pool -Provider ([string](Get-Prop $route 'provider' ''))
                if ($probe.Canaried) {
                    if ($probe.Ok) {
                        $notes.Add("$role canary passed after cooldown")
                        $health['cooldownUntil'] = ''
                        $health['failureWindows'] = @()
                        Write-LogLine -Path $Paths.ErrorLog -Record @{
                            ts = $now.ToString('o'); event = 'cooldown-end'; pool = $PoolId; role = $role
                            provider = [string](Get-Prop $route 'provider' ''); detail = $probe.Detail
                        }
                    }
                    else {
                        $extend = (Get-Prop $policy 'extendOnFailedCanary' $true)
                        $next = if ($extend) { $now.AddMinutes($cooldownMinutes) } else { $now }
                        $health['cooldownUntil'] = if ($extend) { $next.ToString('o') } else { '' }
                        $notes.Add("$role canary FAILED after cooldown")
                        Write-LogLine -Path $Paths.ErrorLog -Record @{
                            ts = $now.ToString('o'); event = 'canary-fail'; pool = $PoolId; role = $role
                            provider = [string](Get-Prop $route 'provider' ''); errorCode = 'CANARY'
                            message = $probe.Detail; extendedUntil = [string]$health['cooldownUntil']
                        }
                        continue
                    }
                }
                else { $notes.Add("$role cooldown expired ($($probe.Detail))") }
            }
        }
        $available.Add($route)
    }

    if ($available.Count -eq 0) {
        return [pscustomobject]@{ Selected = $null; Thinking = ''; WorkRole = $workRole; RouteRole = ''; Notes = @($notes); Policy = $policy }
    }
    $selected = $available[0]
    $selectedRoute = [string](Get-Prop $selected 'role' '')
    # Effort is a property of the ROUTE actually chosen, so a failover carries
    # the failover route's own effort rather than the preferred route's.
    $routeThinking = [string](Get-Prop $selected 'thinking' '')
    $thinking = Resolve-RouteEffort -Registry $Registry -PoolId $PoolId -RouteRole $selectedRoute -WorkRole $workRole
    if ($thinking -and $thinking -ne $routeThinking) {
        $notes.Add("effort '$thinking' for work role '$workRole' on route '$selectedRoute' (route default '$routeThinking')")
    }
    return [pscustomobject]@{
        Selected   = $selected
        Thinking   = $thinking
        WorkRole   = $workRole
        RouteRole  = [string](Get-Prop $selected 'role' '')
        Notes      = @($notes)
        Policy     = $policy
    }
}

# ---------------------------------------------------------------------------
# Modes
# ---------------------------------------------------------------------------

$registry = Get-Registry -Override $RegistryPath
$paths = Get-Paths -Registry $registry -StateOverride $StatePath -LogDirOverride $LogDir
$liveProbe = Get-LiveAgents
$live = @($liveProbe.Agents)
$reconcile = ($liveProbe.Ok -and -not $NoReconcile)
if (-not $reconcile) {
    Write-Host "Occupancy reconciliation off ($($liveProbe.Detail)$(if ($NoReconcile) { '; -NoReconcile' })) - counting reservations only." -ForegroundColor DarkGray
}

function Get-WorkEffortSummary {
    <#
    .SYNOPSIS
        One-line "role=effort" view of a pool's workRoles, for Status.
    #>
    param([Parameter(Mandatory)]$Pool, [Parameter(Mandatory)][array]$Routes)

    $workRoles = Get-Prop $Pool 'workRoles' @{}
    $parts = foreach ($role in ($workRoles.Keys | Sort-Object)) {
        $routePin = [string](Get-Prop $workRoles[$role] 'route' '')
        $route = @($Routes | Where-Object { [string](Get-Prop $_ 'role') -eq $routePin } | Select-Object -First 1)
        $routeThinking = if (@($route).Count -gt 0) { [string](Get-Prop $route[0] 'thinking' '') } else { '' }
        $override = Get-Prop $workRoles[$role] 'thinking' $null
        $effort = if ($null -ne $override -and -not [string]::IsNullOrWhiteSpace([string]$override)) { [string]$override } else { $routeThinking }
        "$role=$effort"
    }
    return (@($parts) -join ' ')
}

function Get-PoolSnapshot {
    param([Parameter(Mandatory)]$Registry, [Parameter(Mandatory)]$State, [Parameter(Mandatory)][hashtable]$Paths, [array]$LiveAgents = @(), [bool]$Reconcile = $true)

    $rows = [System.Collections.Generic.List[object]]::new()
    $occupancy = @{}
    foreach ($poolId in @((Get-Prop $registry 'pools' @{}).Keys | Sort-Object)) {
        $poolDef = Get-Prop (Get-Prop $registry 'pools' @{}) $poolId
        $occ = Get-Occupancy -Registry $Registry -State $State -PoolId $poolId -LiveAgents $LiveAgents -Paths $Paths -Reconcile $Reconcile
        $routes = @($occ.Routes)
        $roleCaps = Get-Prop $poolDef 'roleCaps' @{}
        # What occupancy actually counted, and what it deliberately left out.
        # Named per occupant (id, source, state, age) so a high PoolUsed can be
        # explained instead of guessed at; Skipped is the "not counted" list.
        $occupancy[$poolId] = @{ occupants = @($occ.Occupants); skipped = @($occ.Skipped) }
        foreach ($route in $routes) {
            $role = [string](Get-Prop $route 'role' '')
            $health = Get-RouteHealth -State $State -Key (Get-RouteKey $poolId $role)
            $until = [string](Get-Prop $health 'cooldownUntil' '')
            $cooling = $false
            if ($until) { $cooling = ([DateTime]::Parse($until) -gt (Get-Date)) }
            $poolDisabledUntil = Get-PoolDisabledUntil -State $State -PoolId $poolId
            $rows.Add([pscustomobject]@{
                Pool          = $poolId
                Priority      = [int](Get-Prop $poolDef 'priority' 999)
                Enabled       = [bool](Get-Prop $poolDef 'enabled' $false)
                Role          = $role
                Provider      = [string](Get-Prop $route 'provider' '')
                Thinking      = [string](Get-Prop $route 'thinking' '')
                WorkEfforts   = Get-WorkEffortSummary -Pool $poolDef -Routes $routes
                PoolCap       = [int](Get-Prop $poolDef 'cap' 0)
                RoleCap       = if ($roleCaps.Contains($role)) { [int]$roleCaps[$role] } else { $null }
                PoolUsed      = @($occ.Occupants).Count
                RoleUsed      = @($occ.Occupants | Where-Object { $_.Role -eq $role }).Count
                CooldownUntil = $until
                Cooling       = $cooling
                Keys          = (@(Get-KeyNames -Pool $poolDef | ForEach-Object {
                                    if ((Get-KeyDisabledUntil -State $State -KeyName $_) -gt (Get-Date)) { "$_=SPENT" } else { "$_=ok" }
                                }) -join ' ')
                PoolDisabled  = ($poolDisabledUntil -gt (Get-Date))
                DisabledUntil = [string](Get-Prop (Get-PoolState -State $State -PoolId $poolId) 'disabledUntil' '')
                FailureWindows = @(Get-Prop $health 'failureWindows' @()).Count
                IdleBeyondGrace = @($occ.Skipped | Where-Object { $_.State -eq 'idle-beyond-grace' }).Count
                Unverified     = @($occ.Skipped | Where-Object { $_.State -eq 'unverified' }).Count
                Reconciled     = $Reconcile
            })
        }
    }
    return @{ Rows = @($rows); Occupancy = $occupancy }
}

# ---------------------------------------------------------------------------
# F3: resolve the dispatch mode ONCE, before any mode runs
# ---------------------------------------------------------------------------
# A profile field, when present, is the owner of mode selection for this
# dispatch; every downstream path (watch interlock, key selection, the slot's
# DispatchMode echo, spawn/error log lines) then reads one value. No -Profile,
# or a profile without the field, leaves -DispatchMode exactly as bound.
if ($null -ne $Profile) {
    $profileMode = Resolve-ProfileDispatchMode -Profile $Profile -Default $DispatchMode
    if ($dispatchModeBound -and $profileMode -ne $DispatchMode) {
        throw "Conflicting dispatch modes: -DispatchMode '$DispatchMode' but the Paseo profile declares '$profileMode'. Mode selection has exactly one owner per dispatch - pass -Profile and drop -DispatchMode, or drop -Profile."
    }
    $DispatchMode = $profileMode
}

switch ($Mode) {
    'Status' {
        # L2: -AsJson gains the plan §5 surface — pools (the rows above,
        # unchanged), keys[] (per-key dispatch names), dispatch (last mode,
        # cursor, effective order). Read-only: the state mutations the readers
        # perform (bucket init, key-entry creation) stay in memory, exactly as
        # the occupancy prune above has always been discarded here.
        $payload = Invoke-WithStateLock {
            $statusState = Get-State -StateFile $paths.StateFile
            $snapshot = Get-PoolSnapshot -Registry $registry -State $statusState -Paths $paths -LiveAgents $live -Reconcile $reconcile
            $statusRows = @($snapshot.Rows)
            $statusKeys = @()
            $statusDispatch = @{ mode = 'single-active'; cursor = 0; effectiveOrder = @() }
            $goPool = Get-Prop (Get-Prop $registry 'pools' @{}) 'opencode-go' $null
            if ($null -ne $goPool) {
                $statusKeys = @((Get-DispatchKeyEntries -State $statusState -Pool $goPool).Keys)
                $statusBucket = Get-DispatchBucket -State $statusState
                $statusDispatch = @{
                    mode           = [string](Get-Prop $statusBucket 'lastMode' 'single-active')
                    cursor         = [int](Get-Prop $statusBucket 'cursor' 0)
                    effectiveOrder = @($statusBucket['effectiveOrder'])
                }
            }
            return @{
                pools     = @($statusRows)
                keys      = @($statusKeys)
                dispatch  = $statusDispatch
                occupancy = $snapshot.Occupancy
                reconcile = [bool]$reconcile
                reconcileDetail = [string]$liveProbe.Detail
            }
        }
        # Emit the objects themselves: a bare Format-* would push formatting
        # records into the pipeline and corrupt a caller that captured output.
        if ($AsJson) {
            ConvertTo-Json -InputObject $payload -Depth 10
        }
        else {
            if (Test-Path -LiteralPath $paths.ErrorLog) {
                Write-Host "Error log: $($paths.ErrorLog)" -ForegroundColor DarkGray
            }
            if (-not $payload.reconcile) {
                Write-Host "Occupancy is NOT reconciled against live agents ($($payload.reconcileDetail)); reservations are bounded by their TTL only." -ForegroundColor Yellow
            }
            # Name what occupancy counted. Without this the numbers are
            # unarguable: an operator seeing PoolUsed 8 and no worker in their
            # own view cannot tell which agents hold the slots (observed
            # 2026-11-02: the occupants were worker batteries in other repos).
            foreach ($poolId in @($payload.occupancy.Keys | Sort-Object)) {
                $detail = $payload.occupancy[$poolId]
                $counted = @($detail.occupants)
                $leftOut = @($detail.skipped)
                if ($counted.Count -eq 0 -and $leftOut.Count -eq 0) { continue }
                Write-Host "$poolId counts $($counted.Count) occupant(s):" -ForegroundColor DarkGray
                foreach ($o in $counted) {
                    $who = if ($o.AgentId) { ([string]$o.AgentId).Substring(0, [Math]::Min(8, ([string]$o.AgentId).Length)) } else { '(pending)' }
                    $age = if ($null -ne $o.AgeMinutes) { "$($o.AgeMinutes)m" } else { '-' }
                    Write-Host ("  - {0} {1}/{2} role={3} age={4}" -f $who, $o.Source, $o.State, $o.Role, $age) -ForegroundColor DarkGray
                }
                $beyond = @($leftOut | Where-Object { $_.State -eq 'idle-beyond-grace' })
                $unverified = @($leftOut | Where-Object { $_.State -eq 'unverified' })
                $otherNotLive = @($leftOut | Where-Object { $_.State -ne 'idle-beyond-grace' -and $_.State -ne 'unverified' })
                if ($beyond.Count -gt 0) {
                    Write-Host "  $($beyond.Count) idle beyond grace, not counted: $(($beyond | ForEach-Object { (([string]$_.AgentId).PadRight(8).Substring(0, 8)) + "/$($_.State)/$($_.AgeMinutes)m" }) -join ', ')" -ForegroundColor DarkGray
                }
                if ($otherNotLive.Count -gt 0) {
                    # Idle-inside-grace, closed, errored and archived records are
                    # history, not occupants. Naming them makes an honest count
                    # auditable against `paseo list agents`.
                    Write-Host "  $($otherNotLive.Count) not live, not counted: $(($otherNotLive | ForEach-Object { (([string]$_.AgentId).PadRight(8).Substring(0, 8)) + '/' + $(if ($_.State) { $_.State } else { 'unknown' }) }) -join ', ')" -ForegroundColor DarkGray
                }
                if ($unverified.Count -gt 0) {
                    Write-Host "  $($unverified.Count) unverified past TTL, not counted" -ForegroundColor DarkGray
                }
            }
            @($payload.pools)
        }
        break
    }

    'Acquire' {
        # -Pool 'auto' (the default) walks the pools by priority: Gemini first,
        # so the free daily allowance is spent before anything paid is touched,
        # and the walk simply falls through when Gemini is busy or spent.
        # L2 dispatch-modes: modes and the overnight watch never run together.
        try { Test-DispatchWatchInterlock -DispatchMode $DispatchMode }
        catch {
            Write-LogLine -Path $paths.ErrorLog -Record @{ ts = (Get-Date).ToString('o'); event = 'dispatch-refused'; pool = $Pool; role = $Role; dispatchMode = $DispatchMode; errorCode = 'WATCH-INTERLOCK'; message = $_.Exception.Message }
            throw
        }
        $poolTable = Get-Prop $registry 'pools' @{}
        if ($OptInCodex -and $Pool -ine 'codex') {
            throw '-OptInCodex requires an explicit -Pool codex; it cannot be combined with -Pool auto or another pool.'
        }
        if ($OptInCodex -and $IgnoreCapacity) {
            throw '-OptInCodex cannot be combined with -IgnoreCapacity; the disabled Codex route still enforces all configured capacity limits.'
        }
        if ($Pool -ieq 'codex' -and $IgnoreCapacity -and -not $OptInCodex) {
            throw '-IgnoreCapacity does not opt in to the disabled Codex pool. After an explicit user request, use -Pool codex -OptInCodex; the normal capacity limits still apply.'
        }
        $poolOrder = if ($Pool -and $Pool -ine 'auto') {
            if (-not $poolTable.Contains($Pool)) {
                throw "Unknown pool '$Pool'. Known pools: $(($poolTable.Keys | Sort-Object) -join ', '), or 'auto' for the priority walk."
            }
            @($Pool)
        }
        else { Get-PoolOrder -PoolTable $poolTable }

        $result = Invoke-WithStateLock {
            $state = Get-State -StateFile $paths.StateFile
            Register-CallerSession -State $state -LiveAgents $live -Reconcile $reconcile
            $rejections = [System.Collections.Generic.List[string]]::new()
            $chosen = $null
            $overridden = $false
            $optedInCodex = $false

            foreach ($poolId in $poolOrder) {
                $poolDef = $poolTable[$poolId]
                if (-not [bool](Get-Prop $poolDef 'enabled' $false)) {
                    if ($poolId -eq 'codex' -and $OptInCodex -and $Pool -ieq 'codex') {
                        $optedInCodex = $true
                    }
                    else {
                        $rejections.Add("$poolId disabled in the registry")
                        continue
                    }
                }

                $now = Get-Date
                $disabledUntil = Get-PoolDisabledUntil -State $state -PoolId $poolId
                if ($disabledUntil -ne [DateTime]::MinValue) {
                    if ($disabledUntil -gt $now) {
                        $rejections.Add("$poolId out of circulation until $($disabledUntil.ToString('yyyy-MM-dd HH:mm')) (calendar-day allowance spent)")
                        continue
                    }
                    # The calendar day rolled over: the allowance is back.
                    $ps = Get-PoolState -State $state -PoolId $poolId
                    $ps['disabledUntil'] = ''
                    $ps['reason'] = ''
                    Write-LogLine -Path $paths.ErrorLog -Record @{ ts = $now.ToString('o'); event = 'pool-quota-reset'; pool = $poolId; detail = 'calendar day rolled over; pool back in circulation' }
                }

                $occ = Get-Occupancy -Registry $registry -State $state -PoolId $poolId -LiveAgents $live -Paths $paths -Reconcile $reconcile
                $selection = Resolve-RouteSelection -Registry $registry -State $state -PoolId $poolId -Pool $poolDef `
                    -Routes @($occ.Routes) -RequestedRole $Role -SkipCanary:$SkipCanary -Paths $paths
                $cap = [int](Get-Prop $poolDef 'cap' 0)
                $roleCaps = Get-Prop $poolDef 'roleCaps' @{}
                $poolUsed = @($occ.Occupants).Count
                $routeRole = [string]$selection.RouteRole
                $roleUsed = if ($routeRole) { @($occ.Occupants | Where-Object { $_.Role -eq $routeRole }).Count } else { 0 }
                $roleCap = if ($routeRole -and $roleCaps.Contains($routeRole)) { [int]$roleCaps[$routeRole] } else { $null }

                $blockers = [System.Collections.Generic.List[string]]::new()
                if (-not $selection.Selected) { $blockers.Add("no healthy route: $($selection.Notes -join '; ')") }
                if ($cap -gt 0 -and $poolUsed -ge $cap) { $blockers.Add("pool at cap ($poolUsed/$cap)") }
                if ($null -ne $roleCap -and $roleUsed -ge $roleCap) { $blockers.Add("role at cap ($roleUsed/$roleCap)") }

                # Keyed pools (Gemini) additionally need a key with budget left
                # that no live agent is already holding: exhaustion is per key,
                # and the executor leaves circulation only when every key is out.
                # L2: on opencode-go under waterfall/round-robin the strategy
                # adapter below owns selection; every other pool (and
                # single-active everywhere) keeps the existing first-free-key
                # path verbatim.
                $keySelection = $null
                $dispatched = $null
                $keyNames = @(Get-KeyNames -Pool $poolDef)
                $useDispatchMode = ($poolId -eq 'opencode-go' -and $DispatchMode -ne 'single-active')
                if ($useDispatchMode) {
                    Sync-DispatchInFlight -State $state -LiveAgents $live -Reconcile $reconcile `
                        -TtlMinutes ([int](Get-Prop (Get-Prop $registry 'defaults' @{}) 'reservationTtlMinutes' 30)) `
                        -IdleGraceMinutes ([int](Get-Prop (Get-Prop $registry 'defaults' @{}) 'idleGraceMinutes' 10)) `
                        -FreshnessMinutes ([int](Get-Prop (Get-Prop $registry 'defaults' @{}) 'liveFreshnessMinutes' 15))
                    $headroom = if ($cap -gt 0) { $cap - $poolUsed } else { [int]::MaxValue }
                    try {
                        $dispatched = Resolve-DispatchedKeySelection -State $state -PoolId $poolId -Pool $poolDef `
                            -Occupants @($occ.Occupants) -PoolCapRemaining $headroom -DispatchMode $DispatchMode
                    }
                    catch {
                        $rejections.Add("$poolId`: dispatch mode '$DispatchMode' unavailable ($($_.Exception.Message))")
                        continue
                    }
                    $dispatchBucket = Get-DispatchBucket -State $state
                    $dispatchBucket['effectiveOrder'] = @($dispatched.EffectiveOrder)
                    $dispatchBucket['lastMode'] = $DispatchMode
                    $spentNames = @($dispatched.Debug.skipped | Where-Object { $_.why -eq 'key-spent' } | ForEach-Object { $_.key })
                    $busyNames = @($dispatched.Debug.skipped | Where-Object { $_.why -eq 'key-busy-skip' } | ForEach-Object { $_.key })
                    if ($spentNames.Count -gt 0 -or $busyNames.Count -gt 0) {
                        Write-LogLine -Path $paths.ErrorLog -Record @{
                            ts = (Get-Date).ToString('o'); event = 'key-spent-skipped'; pool = $poolId
                            keysSpent = @($spentNames); keysBusySkipped = @($busyNames); keysFree = @($dispatched.Debug.considered)
                            dispatchMode = $DispatchMode
                            detail = 'withheld keys are skipped; the mode routes around them'
                        }
                    }
                    if ([string]::IsNullOrWhiteSpace([string]$dispatched.KeyName)) {
                        Write-LogLine -Path $paths.ErrorLog -Record @{
                            ts = (Get-Date).ToString('o'); event = 'dispatch-refused'; pool = $poolId; role = $Role
                            dispatchMode = $DispatchMode; errorCode = 'DISPATCH-SELECTION'; message = [string]$dispatched.Reason
                        }
                        if ([string]$dispatched.Reason -eq 'pool-cap-reached') {
                            # The shared pool-cap blocker above already fired on
                            # the same count; do not list the cap twice.
                            if (@($blockers | Where-Object { $_ -like 'pool at cap*' }).Count -eq 0) {
                                $blockers.Add("pool at cap ($poolUsed/$cap)")
                            }
                        }
                        elseif ([string]$dispatched.Reason -eq 'no-eligible-keys') {
                            $nowKeys = Get-Date
                            $liveKeys = @($dispatched.EffectiveOrder | Where-Object { (Get-KeyDisabledUntil -State $state -KeyName $_) -le $nowKeys })
                            if (@($dispatched.EffectiveOrder).Count -gt 0 -and $liveKeys.Count -eq 0) {
                                Sync-PoolExhaustion -State $state -PoolId $poolId -Pool $poolDef | Out-Null
                                $rejections.Add("$poolId`: every key spent for the day ($($spentNames -join ', '))")
                                continue
                            }
                            $blockers.Add("no eligible keys under '$DispatchMode' (spent: $($spentNames -join ', '); skipped-this-dispatch: $($busyNames -join ', '))")
                        }
                        else {
                            $blockers.Add("every eligible key at per-key cap under '$DispatchMode'")
                        }
                    }
                    else {
                        # Single-active shape for the shared downstream: KeyName
                        # is real; Spent/InUse/Free stay empty because per-key
                        # occupancy under modes lives in state.dispatch.inFlight,
                        # not in these single-active counters (which the mode
                        # path never reads for refusal).
                        $keySelection = [pscustomobject]@{ KeyName = [string]$dispatched.KeyName; Spent = @(); InUse = @(); Free = @() }
                    }
                }
                elseif ($keyNames.Count -gt 0) {
                    $keySelection = Resolve-KeySelection -State $state -PoolId $poolId -Pool $poolDef -Occupants @($occ.Occupants)
                    if (-not $keySelection.KeyName) {
                        if (@($keySelection.Spent).Count -ge $keyNames.Count) {
                            Sync-PoolExhaustion -State $state -PoolId $poolId -Pool $poolDef | Out-Null
                            $rejections.Add("$poolId`: every key spent for the day ($(@($keySelection.Spent) -join ', '))")
                            continue
                        }
                        $blockers.Add("every key already in use ($(@($keySelection.InUse) -join ', '))")
                    }
                    if (@($keySelection.Spent).Count -gt 0) {
                        Write-LogLine -Path $paths.ErrorLog -Record @{
                            ts = (Get-Date).ToString('o'); event = 'key-spent-skipped'; pool = $poolId
                            keysSpent = @($keySelection.Spent); keysFree = @($keySelection.Free)
                            detail = 'spent keys are skipped; the executor stays in circulation while any key has budget'
                        }
                    }
                }

                if ($blockers.Count -gt 0) {
                    $rejections.Add("$poolId`: $($blockers -join '; ')")
                    continue
                }

                $chosen = [pscustomobject]@{
                    PoolId = $poolId; PoolDef = $poolDef; Selection = $selection
                    PoolUsed = $poolUsed; Cap = $cap; RoleCap = $roleCap; KeySelection = $keySelection
                    Dispatched = $dispatched
                }
                break
            }

            if ($null -eq $chosen -and $IgnoreCapacity) {
                # Operator override: the highest-priority enabled pool, whatever
                # the caps and the calendar-day window say. Always logged.
                # NOTE: no @() wrapper — a single-element Object[] fails
                # [string] argument transformation at the -PoolId calls below.
                $fallbackId = [string]($poolOrder | Where-Object { [bool](Get-Prop $poolTable[$_] 'enabled' $false) } | Select-Object -First 1)
                if (-not $fallbackId) { throw "Spawn refused: no enabled pool. $($rejections -join ' | ')" }
                $poolDef = $poolTable[$fallbackId]
                $occ = Get-Occupancy -Registry $registry -State $state -PoolId $fallbackId -LiveAgents $live -Paths $paths -Reconcile $reconcile
                $selection = Resolve-RouteSelection -Registry $registry -State $state -PoolId $fallbackId -Pool $poolDef `
                    -Routes @($occ.Routes) -RequestedRole $Role -SkipCanary -Paths $paths
                $overrideKeys = $null
                if (@(Get-KeyNames -Pool $poolDef).Count -gt 0) {
                    $overrideKeys = Resolve-KeySelection -State $state -PoolId $fallbackId -Pool $poolDef -Occupants @($occ.Occupants)
                }
                $chosen = [pscustomobject]@{
                    PoolId = $fallbackId; PoolDef = $poolDef; Selection = $selection
                    PoolUsed = @($occ.Occupants).Count; Cap = [int](Get-Prop $poolDef 'cap' 0); RoleCap = $null
                    KeySelection = $overrideKeys
                }
                $overridden = $true
            }

            if ($null -eq $chosen) {
                $summary = if ($rejections.Count) { $rejections -join ' | ' } else { 'no pools configured' }
                Write-LogLine -Path $paths.ErrorLog -Record @{ ts = (Get-Date).ToString('o'); event = 'spawn-refused'; pool = $Pool; role = $Role; errorCode = 'CAPACITY'; message = $summary }
                Save-State -State $state -StateFile $paths.StateFile
                $nextStep = if ($Pool -ieq 'codex' -and -not $OptInCodex) {
                    'After an explicit user request, use -Pool codex -OptInCodex; configured capacity limits still apply.'
                }
                else { 'Wait for a slot, or pass -IgnoreCapacity to override (logged).' }
                throw "Spawn refused (requested pool '$Pool', work role '$Role'): $summary. $nextStep"
            }

            # Fail closed on the route we are about to hand back: a provider id
            # the dispatcher cannot pass to `paseo run` must stop the dispatch
            # here, named, instead of dying at the provider 30s later. No
            # reservation is written, so a refusal cannot leak a slot.
            Assert-RouteProviderId -PoolId $chosen.PoolId -RouteRole ([string]$chosen.Selection.RouteRole) `
                -Provider ([string](Get-Prop $chosen.Selection.Selected 'provider' '')) -Paths $paths

            if ($overridden -or @($chosen.Selection.Notes).Count -gt 0) {
                Write-LogLine -Path $paths.ErrorLog -Record @{
                    ts = (Get-Date).ToString('o'); event = 'spawn-refused'; pool = $chosen.PoolId; role = $Role
                    errorCode = if ($overridden) { 'CAPACITY-OVERRIDE' } else { 'ROUTE-FAILOVER' }
                    message = if ($overridden) { $rejections -join ' | ' } else { @($chosen.Selection.Notes) -join '; ' }
                    override = $overridden
                }
            }

            $selected = $chosen.Selection.Selected
            $token = [guid]::NewGuid().ToString('n')
            $ttl = [int](Get-Prop (Get-Prop $registry 'defaults' @{}) 'reservationTtlMinutes' 30)
            $chosenDispatched = Get-Prop $chosen 'Dispatched' $null
            if ($null -ne $chosenDispatched -and -not [string]::IsNullOrWhiteSpace([string]$chosenDispatched.KeyName)) {
                Add-DispatchAssignment -State $state -Dispatched $chosenDispatched -Token $token -DispatchMode $DispatchMode -ReservationTtlMinutes $ttl
            }
            $keyEnv = if ($chosen.KeySelection) { [string]$chosen.KeySelection.KeyName } else { '' }
            $keyScope = ''
            $keyTier = ''
            if ($keyEnv) {
                # Registry keys[] order; opencode-go keys live in the cutover
                # seam (Machine env), not in keys[], so an empty match falls
                # back to Machine rather than indexing an empty array.
                $keyMatch = @(Get-Prop $chosen.PoolDef 'keys' @() | Where-Object { [string](Get-Prop $_ 'name' '') -eq $keyEnv } | Select-Object -First 1)
                if ($keyMatch.Count -gt 0) {
                    $keyScope = [string](Get-Prop $keyMatch[0] 'scope' 'Machine')
                    $keyTier = [string](Get-Prop $keyMatch[0] 'tier' '')
                }
                else { $keyScope = 'Machine' }
            }
            # Free-tier detection (additive): a keyed tier wins, else the
            # route tier, else the ':free' provider suffix (OpenRouter free
            # endpoints carry no key row). Free-tier workers get a 1-minute
            # watch until the key fails or the done file lands, so a fast-
            # dying free key can never block paid work.
            $routeTier = [string](Get-Prop $selected 'tier' '')
            $providerId = [string](Get-Prop $selected 'provider' '')
            if (-not $keyTier) { $keyTier = $routeTier }
            if (-not $keyTier -and $providerId -match ':free\b') { $keyTier = 'free' }
            $freeWatch = Get-Prop (Get-Prop $registry 'defaults' @{}) 'freeWatch' @{}
            $watchGrace = if ($keyTier -eq 'free') { [int](Get-Prop $freeWatch 'graceMinutes' 1) } else { 0 }
            $entry = @{
                token = $token; pool = $chosen.PoolId; role = [string]$chosen.Selection.RouteRole
                workRole = [string]$chosen.Selection.WorkRole
                provider = [string](Get-Prop $selected 'provider' ''); thinking = [string]$chosen.Selection.Thinking
                keyName = $keyEnv; keyScope = $keyScope; keyTier = $keyTier
                dispatchMode = $DispatchMode
                agentId = ''; title = $Title; lane = $Lane
                createdAt = (Get-Date).ToString('o'); expiresAt = (Get-Date).AddMinutes($ttl).ToString('o')
            }
            $state['entries'] = @(@(Get-Prop $state 'entries' @()) + @($entry))
            Save-State -State $state -StateFile $paths.StateFile
            Write-LogLine -Path $paths.SpawnLog -Record @{
                ts = (Get-Date).ToString('o'); event = 'acquire'; pool = $entry.pool; role = $entry.role
                workRole = $entry.workRole; provider = $entry.provider; thinking = $entry.thinking; token = $token
                keyName = $keyEnv; keyTier = $keyTier; watchGraceMinutes = $watchGrace; dispatchMode = $DispatchMode
                title = $Title; lane = $Lane; poolUsed = $chosen.PoolUsed; poolCap = $chosen.Cap; override = $overridden
                optIn = $optedInCodex
            }
            # L2 additive fields: DispatchMode echo + KeySelection. The base
            # shape above is untouched; single-active fills key/orderIndex from
            # the existing selection, modes fill key/order-index/cursor from
            # the adapter. reason is $null on success (the closed skip set has
            # no success token); cursor is $null except round-robin.
            $ksKeyOut = ''
            $ksOrderIndex = -1
            $ksCursorOut = $null
            if ($null -ne $chosenDispatched -and -not [string]::IsNullOrWhiteSpace([string]$chosenDispatched.KeyName)) {
                $ksKeyOut = [string]$chosenDispatched.KeyName
                $ksOrderIndex = [int]$chosenDispatched.OrderIndex
                $ksCursorOut = $chosenDispatched.CursorNext
            }
            elseif ($chosen.KeySelection -and -not [string]::IsNullOrWhiteSpace([string]$chosen.KeySelection.KeyName)) {
                $ksKeyOut = [string]$chosen.KeySelection.KeyName
                $ksOrderIndex = [Array]::IndexOf([string[]]@(Get-KeyNames -Pool $chosen.PoolDef), $ksKeyOut)
            }
            return [pscustomobject]@{
                Pool = $entry.pool; Role = $entry.role; WorkRole = $entry.workRole
                Provider = $entry.provider; Thinking = $entry.thinking
                # KeyEnv is the env-var NAME the value must be read from; the
                # dispatcher bridges it into BridgeEnv for this agent alone. The
                # gate never sees the value.
                KeyEnv = $keyEnv; KeyScope = $keyScope
                KeyTier = $keyTier; WatchGraceMinutes = $watchGrace
                BridgeEnv = [string](Get-Prop $chosen.PoolDef 'bridgeEnv' '')
                Token = $token; PoolUsed = $chosen.PoolUsed; PoolCap = $chosen.Cap
                SlotsRemaining = if ($chosen.Cap -gt 0) { [Math]::Max(0, $chosen.Cap - $chosen.PoolUsed - 1) } else { $null }
                RoleCap = $chosen.RoleCap; Notes = @($chosen.Selection.Notes); Overridden = $overridden
                OptedIn = $optedInCodex
                DispatchMode = $DispatchMode
                KeySelection = @{ key = $ksKeyOut; orderIndex = $ksOrderIndex; reason = $null; cursor = $ksCursorOut }
            }
        }
        if ($AsJson) { $result | ConvertTo-Json -Depth 10 } else { $result }
        break
    }

    'Register' {
        if (-not $Token) { throw '-Mode Register requires -Token.' }
        if (-not $AgentId) { throw '-Mode Register requires -AgentId.' }
        $result = Invoke-WithStateLock {
            $state = Get-State -StateFile $paths.StateFile
            $hit = $false
            foreach ($entry in @(Get-Prop $state 'entries' @())) {
                if ((Get-Prop $entry 'token') -eq $Token) {
                    $entry['agentId'] = $AgentId
                    $entry['expiresAt'] = ''
                    $hit = $true
                }
            }
            if (-not $hit) { throw "No reservation with token '$Token' (it may have expired)." }
            # L2: carry the bind onto the mode assignment so a later Release
            # by agent id can attribute (and decrement) the right key.
            foreach ($da in @(Get-Prop (Get-DispatchBucket -State $state) 'assignments' @())) {
                if ([string](Get-Prop $da 'token' '') -eq $Token) {
                    $da['agentId'] = $AgentId
                    $da['expiresAt'] = ''
                }
            }
            Save-State -State $state -StateFile $paths.StateFile
            Write-LogLine -Path $paths.SpawnLog -Record @{ ts = (Get-Date).ToString('o'); event = 'register'; token = $Token; agentId = $AgentId }
            return [pscustomobject]@{ Token = $Token; AgentId = $AgentId; Registered = $true }
        }
        if ($AsJson) { $result | ConvertTo-Json -Depth 10 } else { $result }
        break
    }

    'Release' {
        # -Pool alone is allowed: recording a provider error must never be
        # blocked by a missing reservation (a worker spawned outside the gate,
        # or an id already pruned, still has to land in the error log).
        if (-not $AgentId -and -not $Token -and -not $Pool) {
            throw '-Mode Release requires -AgentId, or -Token for an abandoned reservation, or -Pool for a log-only error record.'
        }
        $result = Invoke-WithStateLock {
            $state = Get-State -StateFile $paths.StateFile
            # L2: prune expired/vanished mode assignments alongside the entry
            # sweep below (dispatch bucket only; occupancy rules untouched).
            Sync-DispatchInFlight -State $state -LiveAgents $live -Reconcile $reconcile `
                -TtlMinutes ([int](Get-Prop (Get-Prop $registry 'defaults' @{}) 'reservationTtlMinutes' 30)) `
                -IdleGraceMinutes ([int](Get-Prop (Get-Prop $registry 'defaults' @{}) 'idleGraceMinutes' 10)) `
                -FreshnessMinutes ([int](Get-Prop (Get-Prop $registry 'defaults' @{}) 'liveFreshnessMinutes' 15))
            $kept = [System.Collections.Generic.List[object]]::new()
            $released = $null
            foreach ($entry in @(Get-Prop $state 'entries' @())) {
                $match = if ($AgentId) { (Get-Prop $entry 'agentId') -eq $AgentId } else { (Get-Prop $entry 'token') -eq $Token }
                if ($match -and $null -eq $released) { $released = $entry; continue }
                $kept.Add($entry)
            }
            $state['entries'] = @($kept)

            if ($null -eq $released) {
                # Unknown agent: still record a provider error, but say so.
                Write-Host "No capacity reservation matched; releasing without an entry." -ForegroundColor Yellow
                $released = @{ pool = $Pool; role = $Role; provider = '' }
            }

            $poolId = if ($Pool) { $Pool } else { [string](Get-Prop $released 'pool' '') }
            # The health key is the ROUTE role (the model), never the work role:
            # -Role names recon/review/fix/code/refactor, which is not a route.
            $roleId = [string](Get-Prop $released 'role' '')
            if ([string]::IsNullOrWhiteSpace($roleId) -and $Role -and $Role -ine 'any') { $roleId = $Role }
            $workRoleId = [string](Get-Prop $released 'workRole' '')
            $provider = [string](Get-Prop $released 'provider' '')

            if ($Outcome -eq 'provider-error') {
                $poolDef = Get-Prop (Get-Prop $registry 'pools' @{}) $poolId
                $policy = Get-Prop $poolDef 'failurePolicy' (Get-Prop $registry 'defaults' @{})
                $windowMinutes = [int](Get-Prop $policy 'windowMinutes' 15)
                $cooldownMinutes = [int](Get-Prop $policy 'cooldownMinutes' 60)
                $windowsToTrip = [int](Get-Prop $policy 'failureWindowsToTrip' 2)
                $now = Get-Date
                $windowTicks = [TimeSpan]::FromMinutes($windowMinutes).Ticks
                $bucketIndex = [long][Math]::Floor($now.Ticks / $windowTicks)
                $bucketStart = [DateTime]::new($bucketIndex * $windowTicks, $now.Kind)
                $bucket = $bucketStart.ToString('o')

                $health = Get-RouteHealth -State $state -Key (Get-RouteKey $poolId $roleId)
                # Distinct-window counting on real instants, never on rendered
                # strings: ConvertFrom-Json re-hydrates an ISO value back into a
                # [DateTime], and `-and` on a [DateTime] operand coerces to false.
                # Either mistake silently resets the window set, so the cooldown
                # threshold is never reached and the failover never fires.
                $windows = @(
                    @(Get-Prop $health 'failureWindows' @()) |
                        ForEach-Object { ConvertTo-WindowInstant $_ } |
                        Where-Object { $null -ne $_ } |
                        Where-Object { $_ -ne $bucketStart }
                )
                $windows = @($windows) + @($bucketStart)
                $cutoff = $now.AddHours(-24)
                $windows = @(@($windows) | Where-Object { $_ -ge $cutoff })
                $health['failureWindows'] = @($windows | ForEach-Object { $_.ToString('o') })
                $health['lastError'] = $Message
                $health['lastErrorAt'] = $now.ToString('o')

                $tripped = $false
                if (@($windows).Count -ge $windowsToTrip) {
                    $current = [string](Get-Prop $health 'cooldownUntil' '')
                    if (-not $current -or [DateTime]::Parse($current) -le $now) {
                        $health['cooldownUntil'] = $now.AddMinutes($cooldownMinutes).ToString('o')
                        $tripped = $true
                    }
                }

                Write-LogLine -Path $paths.ErrorLog -Record @{
                    ts = $now.ToString('o'); event = 'provider-error'; pool = $poolId; role = $roleId
                    workRole = $workRoleId
                    provider = $provider; agentId = $AgentId; title = $Title; lane = $Lane
                    window = $bucket; windowMinutes = $windowMinutes
                    distinctWindows = @($windows).Count; windowsToTrip = $windowsToTrip
                    errorCode = if ($ErrorCode) { $ErrorCode } else { 'UNCLASSIFIED' }
                    message = $Message; cooldownTripped = $tripped
                    cooldownUntil = [string](Get-Prop $health 'cooldownUntil' '')
                }
                if ($tripped) {
                    Write-LogLine -Path $paths.ErrorLog -Record @{
                        ts = $now.ToString('o'); event = 'cooldown-start'; pool = $poolId; role = $roleId
                        provider = $provider; cooldownUntil = [string]$health['cooldownUntil']
                        reason = "$($windowsToTrip) provider failures in $($windowsToTrip) distinct ${windowMinutes}m windows"
                    }
                    Write-Warning "$poolId/$roleId marked in error state until $(([DateTime]$health['cooldownUntil']).ToString('HH:mm:ss')) - Acquire will prefer the pool's other route."
                }

                # A spent calendar-day allowance is not a health problem: it
                # takes the whole POOL out until the day rolls over, is never
                # canaried back early, and the in-flight work is re-dispatched
                # to the next pool by priority.
                if (Test-DailyQuotaError -Pool $poolDef -ErrorCode $ErrorCode -Message $Message) {
                    $keyNames = @(Get-KeyNames -Pool $poolDef)
                    if ($keyNames.Count -gt 0) {
                        # Exhaustion is PER KEY. One spent key must not take the
                        # executor down while its siblings still have budget.
                        # Key selection walks keys[] in order, so array order IS
                        # burn order (free keys first, paid backstop last).
                        $failedKey = if ($KeyName) { $KeyName } else { [string](Get-Prop $released 'keyName' '') }
                        if ([string]::IsNullOrWhiteSpace($failedKey)) { $failedKey = [string]$keyNames[0] }
                        # Per-key quota reset: registry `quotaResetDays` (paid
                        # backstops stand longer); default is next calendar day
                        # (free-tier RPD resets at midnight Pacific, which is
                        # local midnight on this machine).
                        $resetDays = 1
                        foreach ($k in @(Get-Prop $poolDef 'keys' @())) {
                            if ([string](Get-Prop $k 'name' '') -ieq $failedKey) { $resetDays = [int](Get-Prop $k 'quotaResetDays' 1); break }
                        }
                        if ($resetDays -lt 1) { $resetDays = 1 }
                        $reset = $now.Date.AddDays($resetDays)
                        $ks = Get-KeyState -State $State -KeyName $failedKey
                        $ks['disabledUntil'] = $reset.ToString('o')
                        $ks['reason'] = if ($Message) { $Message } else { $ErrorCode }
                        $ks['setAt'] = $now.ToString('o')
                        Write-LogLine -Path $paths.ErrorLog -Record @{
                            ts = $now.ToString('o'); event = 'key-daily-exhausted'; pool = $poolId; role = $roleId
                            keyName = $failedKey
                            provider = $provider; agentId = $AgentId; title = $Title; lane = $Lane
                            errorCode = if ($ErrorCode) { $ErrorCode } else { 'DAILY_QUOTA' }
                            message = $Message; disabledUntil = [string]$ks['disabledUntil']
                        }
                        $sync = Sync-PoolExhaustion -State $state -PoolId $poolId -Pool $poolDef
                        if ($sync -and $sync.PoolDisabled) {
                            $poolUntil = [string](Get-Prop (Get-PoolState -State $state -PoolId $poolId) 'disabledUntil' '')
                            $poolUntilShort = $poolUntil
                            try { $poolUntilShort = ([DateTime]$poolUntil).ToString('yyyy-MM-dd HH:mm') } catch { }
                            Write-LogLine -Path $paths.ErrorLog -Record @{
                                ts = $now.ToString('o'); event = 'pool-daily-exhausted'; pool = $poolId; role = $roleId
                                provider = $provider; errorCode = 'DAILY_QUOTA'
                                message = "all $($keyNames.Count) keys spent"; disabledUntil = $poolUntil
                            }
                            Write-Warning "${poolId}: all $($keyNames.Count) keys are spent - the executor is out of circulation until ${poolUntilShort}. Re-dispatch this work on the next pool (Acquire -Pool auto)."
                        }
                        else {
                            $spentFor = if ($resetDays -gt 1) { "$resetDays days" } else { "the day" }
                            Write-Warning "$failedKey is spent for ${spentFor} ($(@($sync.Live).Count) of $($keyNames.Count) key(s) still available) - re-dispatch this work; the executor stays in circulation."
                        }
                    }
                    else {
                        $ps = Get-PoolState -State $state -PoolId $poolId
                        $ps['disabledUntil'] = $reset.ToString('o')
                        $ps['reason'] = if ($Message) { $Message } else { $ErrorCode }
                        $ps['setAt'] = $now.ToString('o')
                        Write-LogLine -Path $paths.ErrorLog -Record @{
                            ts = $now.ToString('o'); event = 'pool-daily-exhausted'; pool = $poolId; role = $roleId
                            provider = $provider; agentId = $AgentId; title = $Title; lane = $Lane
                            errorCode = if ($ErrorCode) { $ErrorCode } else { 'DAILY_QUOTA' }
                            message = $Message; disabledUntil = [string]$ps['disabledUntil']
                        }
                        Write-Warning "$poolId calendar-day allowance is spent - out of circulation until $($reset.ToString('yyyy-MM-dd HH:mm')). Re-dispatch this work on the next pool (Acquire -Pool auto)."
                    }
                }
            }

            # L3: remember the failure class per key (Status keys[].lastErrorClass).
            # No live probe here — Release stays spend-free; the dispatcher runs
            # -Mode Canary -KeyName <key> (Invoke-DispatchKeyRecanary) before the
            # key is trusted again. Verdicts are probe-owned; this records cause only.
            if ($Outcome -eq 'provider-error') {
                $errKey = if ($KeyName) { $KeyName } else { [string](Get-Prop $released 'keyName' '') }
                if (-not [string]::IsNullOrWhiteSpace($errKey)) {
                    $ldb = Get-DispatchBucket -State $state
                    $leb = Get-Prop $ldb 'lastErrorByKey' @{}
                    $leb[$errKey] = @{ class = (ConvertTo-DispatchErrorClass -ErrorCode $ErrorCode -Message $Message); at = $now.ToString('o') }
                    $ldb['lastErrorByKey'] = $leb
                }
            }

            Save-State -State $state -StateFile $paths.StateFile
            $releasedKey = if ($KeyName) { $KeyName } else { [string](Get-Prop $released 'keyName' '') }
            # L2: drop the mode assignment for this reservation (by token when
            # released by token, by agent id when released by agent) and
            # decrement that key's inFlight. No assignment => no-op.
            Remove-DispatchAssignment -State $state -Token ([string](Get-Prop $released 'token' '')) -AgentId $AgentId | Out-Null
            Save-State -State $state -StateFile $paths.StateFile
            Write-LogLine -Path $paths.SpawnLog -Record @{ ts = (Get-Date).ToString('o'); event = 'release'; pool = $poolId; role = $roleId; workRole = $workRoleId; keyName = $releasedKey; agentId = $AgentId; outcome = $Outcome; errorCode = $ErrorCode }
            return [pscustomobject]@{ Released = $true; Pool = $poolId; Role = $roleId; WorkRole = $workRoleId; KeyName = $releasedKey; Outcome = $Outcome }
        }
        if ($AsJson) { $result | ConvertTo-Json -Depth 10 } else { $result }
        break
    }

    'Canary' {
        # L3 dispatch canary (plan §3): session-start 5-parallel (no -KeyName)
        # or single-key on-failure re-canary (-KeyName). opencode-go only, under
        # waterfall|round-robin. Paid model first via the seam fast set (never
        # the deepseek full set); fixtures via $env:AGENT_CAPACITY_CANARY_STUB
        # in tests — never live keys there. -SkipCanary bypasses the probe and
        # writes nothing (never a spent state). The watch/cutover path owns any
        # active-pointer move; this mode never repoints.
        if ($Pool -and $Pool -ne 'opencode-go' -and $Pool -ne 'auto') { throw "-Mode Canary is opencode-go only (got -Pool '$Pool')." }
        if ($DispatchMode -eq 'single-active') { throw "-Mode Canary needs -DispatchMode waterfall|round-robin (single-active has no session canary)." }
        $result = Invoke-WithStateLock {
            $state = Get-State -StateFile $paths.StateFile
            if ($KeyName) {
                $rc = Invoke-DispatchKeyRecanary -State $state -KeyName $KeyName -Paths $paths -DispatchMode $DispatchMode -SkipCanary:$SkipCanary
                Save-State -State $state -StateFile $paths.StateFile
                return $rc
            }
            $sc = Invoke-DispatchSessionCanary -State $state -Paths $paths -DispatchMode $DispatchMode -SkipCanary:$SkipCanary
            Save-State -State $state -StateFile $paths.StateFile
            return $sc
        }
        if ($AsJson) { $result | ConvertTo-Json -Depth 10 } else { $result }
        break
    }

    'Clear' {
        if (-not $Pool) { throw '-Mode Clear requires -Pool (and usually -Role).' }
        $result = Invoke-WithStateLock {
            $state = Get-State -StateFile $paths.StateFile
            $roles = if ($Role -ne 'any') { @($Role) }
                     else { @(Get-Prop (Get-Prop (Get-Prop $registry 'pools' @{}) $Pool) 'routes' @() | ForEach-Object { Get-Prop $_ 'role' }) }
            $cleared = [System.Collections.Generic.List[string]]::new()
            foreach ($r in $roles) {
                $key = Get-RouteKey $Pool $r
                $health = Get-RouteHealth -State $state -Key $key
                $health['cooldownUntil'] = ''
                $health['failureWindows'] = @()
                $cleared.Add($key)
                Write-LogLine -Path $paths.ErrorLog -Record @{ ts = (Get-Date).ToString('o'); event = 'cooldown-clear'; pool = $Pool; role = $r; detail = 'operator override' }
            }
            if ($Force) {
                foreach ($keyName in (Get-KeyNames -Pool (Get-Prop (Get-Prop $registry 'pools' @{}) $Pool))) {
                    $ks = Get-KeyState -State $state -KeyName $keyName
                    if (-not [string]::IsNullOrWhiteSpace([string](Get-Prop $ks 'disabledUntil' ''))) {
                        $ks['disabledUntil'] = ''
                        $ks['reason'] = ''
                        $cleared.Add("$keyName day-exhaustion")
                        Write-LogLine -Path $paths.ErrorLog -Record @{ ts = (Get-Date).ToString('o'); event = 'key-quota-clear'; pool = $Pool; keyName = $keyName; detail = 'operator override (-Force)' }
                    }
                }
                $ps = Get-PoolState -State $state -PoolId $Pool
                if ([string]::IsNullOrWhiteSpace([string](Get-Prop $ps 'disabledUntil' ''))) {
                    Write-Host "Pool '$Pool' has no calendar-day disable to clear." -ForegroundColor DarkGray
                }
                else {
                    $ps['disabledUntil'] = ''
                    $ps['reason'] = ''
                    $cleared.Add("$Pool calendar-day disable")
                    Write-LogLine -Path $paths.ErrorLog -Record @{ ts = (Get-Date).ToString('o'); event = 'pool-quota-clear'; pool = $Pool; detail = 'operator override (-Force); a spent daily allowance normally stands until the next calendar day' }
                }
            }
            Save-State -State $state -StateFile $paths.StateFile
            return [pscustomobject]@{ Cleared = @($cleared) }
        }
        if ($AsJson) { $result | ConvertTo-Json -Depth 10 } else { $result }
        break
    }

    'Config' {
        # The single source for "what are you spawning on, and how exhausted are
        # the keys". Every line is recorded state or a direct count; nothing is
        # inferred, and the not-knowable is named as such.
        if ($AsJson) { throw '-Mode Config emits a human report; use -Mode Status -AsJson for the machine view.' }
        $state = Get-State -StateFile $paths.StateFile
        $poolTable = Get-Prop $registry 'pools' @{}
        $now = Get-Date
        $start = Resolve-SinceStart -Registry $registry -Since $Since -Now $now

        Write-Output ''
        Write-Output "SPAWN CONFIGURATION  (owner: agent-spawn-capacity registry; state read $($now.ToString('yyyy-MM-dd HH:mm:ss')))"
        Write-Output ''
        Write-Output 'DISPATCH PRIORITY - Acquire -Pool auto walks this order and takes the first that fits'
        $rank = 1
        foreach ($poolId in (Get-PoolOrder -PoolTable $poolTable)) {
            $pd = $poolTable[$poolId]
            $enabled = if ([bool](Get-Prop $pd 'enabled' $false)) { 'ENABLED' } else { 'disabled' }
            $cap = Get-Prop $pd 'cap' 0
            $keys = @(Get-KeyNames -Pool $pd)
            $budget = if ($keys.Count -gt 0) { "$($keys.Count) key(s), one agent per key" } else { 'shared wallet' }
            Write-Output ("  {0}  {1,-13} cap {2,-3} {3,-9} {4}" -f $rank, $poolId, $cap, $enabled, $budget)
            $rank++
        }
        Write-Output ''
        Write-Output 'MODELS BY WORK ROLE - -Role names the work; the registry picks route AND effort'
        $workRoles = @('recon', 'review', 'fix', 'code', 'refactor', 'simple', 'merge')
        Write-Output ("  {0,-30} {1,-52} {2}" -f 'pool/route', 'provider / model', ($workRoles -join '  '))
        foreach ($poolId in (Get-PoolOrder -PoolTable $poolTable)) {
            $pd = $poolTable[$poolId]
            foreach ($route in @(Get-Prop $pd 'routes' @())) {
                $routeRole = [string](Get-Prop $route 'role' '')
                $provider = [string](Get-Prop $route 'provider' '')
                # Show the route's DECLARED effort only: routes[].thinking is the
                # Acquire-time fallback for an undeclared role, not a claim about
                # what this route does for every role.
                $declaredEfforts = Get-Prop $route 'efforts' @{}
                $cells = foreach ($wr in $workRoles) {
                    $preferred = (Resolve-RouteForWorkRole -Registry $registry -PoolId $poolId -WorkRole $wr) -eq $routeRole
                    $declared = if ($declaredEfforts.Contains($wr)) { [string](Get-Prop $declaredEfforts $wr '') } else { '' }
                    if ($declared) { if ($preferred) { "$declared*" } else { $declared } }
                    elseif ($preferred) { 'none*' }
                    else { '-' }
                }
                $short = if ($provider.Length -gt 50) { $provider.Substring(0, 47) + '...' } else { $provider }
                Write-Output ("  {0,-30} {1,-52} {2}" -f "$poolId/$routeRole", $short, (@($cells) -join '  '))
            }
        }
        Write-Output '  (* = this work role''s preferred route. An unstarred value is the effort that route'
        Write-Output '   uses as the FAILOVER. A dash means the route declares no effort for that role.)'
        Write-Output ''
        Write-Output 'KEYS - recorded state (fact, not estimate)'
        $anyKeys = $false
        foreach ($poolId in (Get-PoolOrder -PoolTable $poolTable)) {
            $pd = $poolTable[$poolId]
            $names = @(Get-KeyNames -Pool $pd)
            if ($names.Count -eq 0) { continue }
            $anyKeys = $true
            $parts = foreach ($n in $names) {
                $until = Get-KeyDisabledUntil -State $state -KeyName $n
                if ($until -gt $now) { "$n=SPENT until $($until.ToString('yyyy-MM-dd HH:mm'))" } else { "$n=ok" }
            }
            Write-Output ("  {0,-13} {1}" -f $poolId, (@($parts) -join '   '))
        }
        if (-not $anyKeys) { Write-Output '  (no pool declares per-key state)' }
        Write-Output ''
        Write-Output 'DISPATCH - per-key load under waterfall/round-robin (opencode-go; counts are spawns, never requests)'
        $goPoolForDispatch = Get-Prop $poolTable 'opencode-go' $null
        if ($null -eq $goPoolForDispatch) { Write-Output '  (no opencode-go pool in the registry)' }
        else {
            $dispatchSurface = Get-DispatchKeyEntries -State $state -Pool $goPoolForDispatch
            if (-not $dispatchSurface.Found) { Write-Output '  (cutover seam unreadable; per-key caps unknown)' }
            foreach ($dk in @($dispatchSurface.Keys)) {
                $eligTxt = if ([bool]$dk.eligible) { 'eligible' } else { 'withheld' }
                $canTxt = if ([string]$dk.canaryVerdict) { "$($dk.canaryVerdict) @ $($dk.canaryAt)" } else { 'no verdict this session' }
                $spentTxt = if ([string]$dk.disabledUntil) {
                    try { "spent until $(([DateTime]$dk.disabledUntil).ToString('yyyy-MM-dd HH:mm'))" } catch { "spent until $($dk.disabledUntil)" }
                } else { 'not spent' }
                Write-Output ("  {0}  {1}  in-flight {2}/{3}  canary: {4}  {5}  assigned today: {6}" -f $dk.name, $eligTxt, $dk.inFlight, $dk.keyMaxConcurrent, $canTxt, $spentTxt, $dk.assignedThisSession)
            }
            $dispatchBucketView = Get-DispatchBucket -State $state
            Write-Output ("  last mode: {0}; cursor: {1}; effective order: {2}" -f ([string](Get-Prop $dispatchBucketView 'lastMode' 'single-active')), ([int](Get-Prop $dispatchBucketView 'cursor' 0)), ((@($dispatchBucketView['effectiveOrder']) -join ' -> ')))
        }
        Write-Output ''
        Write-Output 'FAILURE STATE - recorded state (fact)'
        $cooling = @()
        foreach ($key in (Get-Prop $state 'routes' @{}).Keys) {
            $until = [string](Get-Prop (Get-Prop (Get-Prop $state 'routes' @{}) $key) 'cooldownUntil' '')
            if ($until -and [DateTime]::Parse($until) -gt $now) { $cooling += "$key until $until" }
        }
        $poolOut = @()
        foreach ($poolKey in (Get-Prop $state 'pools' @{}).Keys) {
            $du = Get-PoolDisabledUntil -State $state -PoolId $poolKey
            if ($du -gt $now) { $poolOut += "$poolKey until $($du.ToString('yyyy-MM-dd HH:mm'))" }
        }
        Write-Output "  routes in error state   : $(if ($cooling.Count) { $cooling -join '; ' } else { 'none' })"
        Write-Output "  pools out of circulation: $(if ($poolOut.Count) { $poolOut -join '; ' } else { 'none' })"
        $errCount = 0
        if (Test-Path -LiteralPath $paths.ErrorLog) {
            $errCount = @(Get-Content -LiteralPath $paths.ErrorLog | Where-Object { $_.Trim() } | ForEach-Object {
                    try { $_ | ConvertFrom-Json -AsHashtable } catch { $null }
                } | Where-Object {
                    if (-not $_) { return $false }
                    $ts = [DateTime]::MinValue
                    [DateTime]::TryParse([string](Get-Prop $_ 'ts' ''), [ref]$ts) | Out-Null
                    $ts -ge $start -and (Get-Prop $_ 'event') -in @('provider-error', 'canary-fail', 'key-daily-exhausted', 'pool-daily-exhausted')
                }).Count
        }
        Write-Output "  provider errors in window: $errCount"
        Write-Output ''
        Write-Output 'NOT KNOWN - do not guess or fabricate'
        Write-Output '  Remaining budget per key. The gate counts AGENT SPAWNS, not provider'
        Write-Output '  requests (Gemini: 15/min and 1500/day per key; opencode-go: a weekly'
        Write-Output '  pool cap), so a percent-used figure cannot be derived from it. Say it is'
        Write-Output '  unknown rather than estimating consumption.'
        Write-Output ''
        Write-Output "OBSERVED IN WINDOW - spawns acquired since $($start.ToString('yyyy-MM-dd HH:mm')), counted from the spawn log"
        $usage = @{}
        if (Test-Path -LiteralPath $paths.SpawnLog) {
            Get-Content -LiteralPath $paths.SpawnLog | Where-Object { $_.Trim() } | ForEach-Object {
                try { $r = $_ | ConvertFrom-Json -AsHashtable } catch { return }
                if ((Get-Prop $r 'event') -ne 'acquire') { return }
                $ts = [DateTime]::MinValue
                [DateTime]::TryParse([string](Get-Prop $r 'ts' ''), [ref]$ts) | Out-Null
                if ($ts -lt $start) { return }
                $slot = if ((Get-Prop $r 'keyName' '')) { "$(Get-Prop $r 'pool')/$(Get-Prop $r 'keyName')" } else { "$(Get-Prop $r 'pool')/$(Get-Prop $r 'role')" }
                $usage[$slot] = 1 + [int]($usage[$slot])
            }
        }
        if ($usage.Count -eq 0) { Write-Output '  none' }
        else {
            $total = 0
            foreach ($slot in ($usage.Keys | Sort-Object)) { Write-Output ("  {0,-34} {1}" -f $slot, $usage[$slot]); $total += [int]$usage[$slot] }
            Write-Output "  total: $total"
        }
        Write-Output ''
        Write-Output 'CONFIDENCE - every line above is recorded state or a direct count; none of it is estimated.'
        break
    }

    'Report' {
        if ($LastNight) { $Since = 'lastnight' }
        $now = Get-Date
        $start = Resolve-SinceStart -Registry $registry -Since $Since -Now $now

        if (-not (Test-Path -LiteralPath $paths.ErrorLog)) {
            Write-Output "No spawn errors logged at all ($($paths.ErrorLog) does not exist)."
            break
        }
        $records = @(Get-Content -LiteralPath $paths.ErrorLog | Where-Object { $_.Trim() } | ForEach-Object {
                try { $_ | ConvertFrom-Json -AsHashtable } catch { $null }
            } | Where-Object { $_ })
        $inWindow = @($records | Where-Object {
                $ts = [DateTime]::MinValue
                [DateTime]::TryParse([string](Get-Prop $_ 'ts' ''), [ref]$ts) | Out-Null
                $ts -ge $start
            })

        $problems = @($inWindow | Where-Object { (Get-Prop $_ 'event') -in @('provider-error', 'canary-fail', 'spawn-refused', 'pool-daily-exhausted', 'key-daily-exhausted') })
        Write-Output "Spawn events since $($start.ToString('yyyy-MM-dd HH:mm')) (local): $($inWindow.Count) total, $($problems.Count) problem event(s)."
        if ($problems.Count -eq 0) {
            Write-Output 'No provider errors, canary failures, or capacity refusals in this window.'
        }
        else {
            $problems | Group-Object { "$(Get-Prop $_ 'pool')/$(Get-Prop $_ 'role')" } | Sort-Object Name | ForEach-Object {
                $codes = ($_.Group | ForEach-Object { [string](Get-Prop $_ 'errorCode' '') } | Sort-Object -Unique) -join ','
                $first = ($_.Group | ForEach-Object { [string](Get-Prop $_ 'ts' '') } | Sort-Object | Select-Object -First 1)
                $last = ($_.Group | ForEach-Object { [string](Get-Prop $_ 'ts' '') } | Sort-Object | Select-Object -Last 1)
                Write-Output ''
                Write-Output "  $($_.Name)  x$($_.Count)  [$codes]"
                Write-Output "      first $first   last $last"
                $_.Group | ForEach-Object {
                    $msg = [string](Get-Prop $_ 'message' '')
                    if ([string]::IsNullOrWhiteSpace($msg)) { $msg = '(no message recorded)' }
                    Write-Output "      - $([string](Get-Prop $_ 'event')): $msg"
                }
            }
        }
        $cooldowns = @($inWindow | Where-Object { (Get-Prop $_ 'event') -eq 'cooldown-start' })
        if ($cooldowns.Count -gt 0) {
            Write-Output ''
            Write-Output 'Cooldowns started in this window:'
            $cooldowns | ForEach-Object { Write-Output "  $(Get-Prop $_ 'pool')/$(Get-Prop $_ 'role') until $([string](Get-Prop $_ 'cooldownUntil'))" }
        }
        $state = Get-State -StateFile $paths.StateFile
        $active = @()
        foreach ($key in (Get-Prop $state 'routes' @{}).Keys) {
            $health = Get-Prop (Get-Prop $state 'routes' @{}) $key
            $until = [string](Get-Prop $health 'cooldownUntil' '')
            if ($until -and [DateTime]::Parse($until) -gt $now) { $active += "$key until $until" }
        }
        $poolOut = @()
        $poolStates = Get-Prop $state 'pools' @{}
        foreach ($poolKey in $poolStates.Keys) {
            $disabled = Get-PoolDisabledUntil -State $state -PoolId $poolKey
            if ($disabled -gt $now) {
                $reason = [string](Get-Prop $poolStates[$poolKey] 'reason' '')
                $poolOut += "$poolKey until $($disabled.ToString('yyyy-MM-dd HH:mm'))$(if ($reason) { " ($reason)" })"
            }
        }
        if ($poolOut.Count -gt 0) {
            Write-Output ''
            Write-Output "Pools out of circulation (calendar-day allowance): $($poolOut -join '; ')"
        }
        $keyOut = @()
        foreach ($keyName in (Get-Prop $state 'keys' @{}).Keys) {
            $until = Get-KeyDisabledUntil -State $state -KeyName $keyName
            if ($until -gt $now) { $keyOut += "$keyName until $($until.ToString('yyyy-MM-dd HH:mm'))" }
        }
        if ($keyOut.Count -gt 0) {
            Write-Output "Keys spent for the day: $($keyOut -join '; ')"
        }
        Write-Output ''
        if ($active.Count -gt 0) {
            Write-Output "Routes still in error state: $($active -join '; ')"
        }
        else {
            Write-Output 'No route is currently in an error state.'
        }
        break
    }
}
