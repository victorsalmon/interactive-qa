# Shared fixtures for the Key Check roster / witness suites.
# Everything here is a file on disk: no live Paseo, no network, no credential.

function New-RosterFixture {
    <#
    .SYNOPSIS
        A throwaway directory holding an agent-list fixture, a daemon state
        folder, the audit trail, the send log and the roster path.
    #>
    param([string]$Root, [string]$Name = 'kc-roster')

    $dir = Join-Path $Root ("{0}-{1}" -f $Name, ([guid]::NewGuid().ToString('N')))
    $null = New-Item -ItemType Directory -Path $dir -Force
    $agentsDir = Join-Path $dir 'agents'
    $null = New-Item -ItemType Directory -Path $agentsDir -Force
    $stateDir = Join-Path $dir 'state'
    $null = New-Item -ItemType Directory -Path $stateDir -Force

    [pscustomobject]@{
        Dir           = $dir
        AgentsDir     = $agentsDir
        AgentListPath = Join-Path $dir 'agents.json'
        RosterPath    = Join-Path $dir 'roster.json'
        StateDir      = $stateDir
        AuditPath     = Join-Path $dir 'keycheck.jsonl'
        SendLog       = Join-Path $dir 'sends.jsonl'
        SendStub      = ''
        Rows          = [System.Collections.Generic.List[object]]::new()
    }
}

function Add-RosterAgent {
    <#
    .SYNOPSIS
        Add one agent to the fixture: a `paseo ls --json` row plus the daemon
        state file that carries labels, lastActivityAt and the session id.
    #>
    param(
        $Fixture,
        [string]$Id,
        [string]$Title = 'lane work',
        [string]$Status = 'running',
        [string]$Cwd = '',
        [hashtable]$Labels = @{},
        [string]$SessionId = 'sess-0001',
        [string]$LastActivityAt = '2026-11-02T10:00:00Z',
        [switch]$NoStateFile
    )

    if ([string]::IsNullOrWhiteSpace($Cwd)) {
        $Cwd = Join-Path $Fixture.Dir "cwd-$Id"
        $null = New-Item -ItemType Directory -Path $Cwd -Force
    }

    if (-not $NoStateFile) {
        $workspace = Join-Path $Fixture.AgentsDir 'ws-fixture'
        if (-not (Test-Path -LiteralPath $workspace)) { $null = New-Item -ItemType Directory -Path $workspace -Force }
        $state = [ordered]@{
            id             = $Id
            title          = $Title
            cwd            = $Cwd
            lastActivityAt = $LastActivityAt
            labels         = $Labels
            persistence    = [ordered]@{ provider = 'opencode'; sessionId = $SessionId }
        }
        Set-Content -LiteralPath (Join-Path $workspace "$Id.json") -Value ($state | ConvertTo-Json -Depth 6)
    }

    $Fixture.Rows.Add([ordered]@{
            id       = $Id
            shortId  = $Id.Substring(0, [Math]::Min(7, $Id.Length))
            name     = $Title
            status   = $Status
            cwd      = $Cwd
            provider = 'opencode/opencode-go/deepseek-v4.1-flash'
        })
}

function Save-RosterAgentList {
    param($Fixture)
    Set-Content -LiteralPath $Fixture.AgentListPath -Value (@($Fixture.Rows) | ConvertTo-Json -Depth 5)
    return $Fixture.AgentListPath
}

function New-RosterSendStub {
    <#
    .SYNOPSIS
        The `-SendScript` seam: append the message it would send to the fixture's
        send log. Proves a send without a daemon.
    #>
    param($Fixture)
    $path = Join-Path $Fixture.Dir 'send-stub.ps1'
    @"
param([string]`$AgentId, [string]`$Variant, [string]`$MessageFile)
`$message = Get-Content -LiteralPath `$MessageFile -Raw
[ordered]@{ agentId = `$AgentId; variant = `$Variant; message = `$message } |
    ConvertTo-Json -Compress | Add-Content -LiteralPath '$($Fixture.SendLog)'
exit 0
"@ | Set-Content -LiteralPath $path
    $Fixture.SendStub = $path
    return $path
}

function Get-RosterSendLog {
    param($Fixture)
    if (-not (Test-Path -LiteralPath $Fixture.SendLog)) { return @() }
    return @(Get-Content -LiteralPath $Fixture.SendLog | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
}

function Get-RosterAuditRows {
    param($Fixture)
    if (-not (Test-Path -LiteralPath $Fixture.AuditPath)) { return @() }
    return @(Get-Content -LiteralPath $Fixture.AuditPath | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
}

function New-WitnessFixture {
    <#
    .SYNOPSIS
        A cutover fixture for the witness: seam, pool values, Paseo pin, daemon
        pid file and an outcome file, all on disk.
    #>
    param(
        [string]$Root,
        [string]$SeamActiveKey = 'OPENCODE_GO3_KEY',
        [string]$UserValue = 'witness-value-charlie',
        [string]$PinValue = 'witness-value-charlie',
        [switch]$DaemonDead
    )
    $dir = Join-Path $Root ("kc-witness-{0}" -f ([guid]::NewGuid().ToString('N')))
    $null = New-Item -ItemType Directory -Path $dir -Force

    $seamPath = Join-Path $dir 'seam.json'
    @{ activeKey = $SeamActiveKey } | ConvertTo-Json | Set-Content -LiteralPath $seamPath

    $keysPath = Join-Path $dir 'keys.json'
    @{
        inUse = $UserValue
        keys  = @{
            GO1 = 'witness-value-alpha'; GO2 = 'witness-value-bravo'; GO3 = 'witness-value-charlie'
        }
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $keysPath

    $paseoConfig = Join-Path $dir 'paseo-config.json'
    @{ agents = @{ providers = @{ opencode = @{ env = @{ OPENCODE_GO_KEY = $PinValue } } } } } |
        ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $paseoConfig

    $pidFile = Join-Path $dir 'paseo.pid'
    $pidValue = if ($DaemonDead) { 999999 } else { $PID }
    @{ pid = $pidValue } | ConvertTo-Json | Set-Content -LiteralPath $pidFile

    [pscustomobject]@{
        Dir         = $dir
        SeamPath    = $seamPath
        KeysPath    = $keysPath
        PaseoConfig = $paseoConfig
        DaemonPid   = $pidFile
        StateDir    = $dir
        AuditPath   = Join-Path $dir 'keycheck.jsonl'
        OutcomePath = Join-Path $dir 'run-w1-cutover.json'
        WitnessPath = Join-Path $dir 'witness-run-w1.json'
        MarkerPath  = Join-Path $dir 'last-cutover.json'
    }
}

function Set-WitnessOutcome {
    param(
        $Fixture,
        [bool]$Applied = $true,
        $Verified = $false,
        [bool]$RestartPending = $false,
        [string]$Reason = ''
    )
    $payload = [ordered]@{
        applied        = $Applied
        verified       = $Verified
        restartPending = $RestartPending
        reason         = $Reason
        runId          = 'run-w1'
        keyNumber      = 3
    }
    Set-Content -LiteralPath $Fixture.OutcomePath -Value ($payload | ConvertTo-Json -Depth 5)
}
