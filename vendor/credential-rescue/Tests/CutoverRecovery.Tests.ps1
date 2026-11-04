#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0.0' }

<#
.SYNOPSIS
    Pester tests for post-cutover recovery: backstop reconciliation, role
    restoration, dead-lease release, gate stamping and the recovery report.

.DESCRIPTION
    The 2026-11-02 cutover (runId 20261102-172700) left the UH Hub with a
    backstop that had registered a Hub row and taken the worktree lease while
    the original Hub was still recovering, a lease whose holder pid was dead,
    gate batteries killed mid-run that looked like red gates, and no record of
    any of it.

    The contract under test:

      - a Hub row or lease acquired INSIDE the cutover window produces exactly
        one stand-down naming the runId and the original Hub; outside the
        window produces none; the lease is never seized unless -ForceRevoke is
        given, and then the release is logged with its owner and generation;
      - the recovery tool re-registers the original Hub (safe) and says the
        lease must be re-acquired from a fresh shell;
      - a lease whose recorded pid is dead and whose repo was in the window is
        released with `reason: cutover`, preserving owner and generation; a
        live holder is never touched;
      - `.gate-runs/<stamp>` modified inside the kill window gets
        `killed-by-cutover.json`, and one outside it does not;
      - a second recovery for the same runId is a no-op (one report, one
        stand-down set);
      - the report classifies every roster agent and flags an uncommitted
        worktree and a missing report/done file.

    Every fixture is a file on disk: no live cutover, no live Paseo.
#>

BeforeAll {
    $script:SkillRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
    $script:RecoveryPath = Join-Path $script:SkillRoot 'scripts\Invoke-CutoverRecovery.ps1'
    $script:StampPath = Join-Path $script:SkillRoot 'scripts\Stamp-InterruptedGates.ps1'
    $script:PwshExe = Join-Path $PSHOME 'pwsh.exe'

    function New-CutoverRecoveryFixture {
        param(
            [string]$RunId = 'run-cut1',
            [int]$StartedMinutesAgo = 10,
            [int]$EndedMinutesAgo = 5
        )
        $dir = Join-Path $TestDrive ("kc-rec-{0}" -f ([guid]::NewGuid().ToString('N')))
        $null = New-Item -ItemType Directory -Path $dir -Force
        $stateDir = Join-Path $dir 'state'
        $hubRoot = Join-Path $dir 'hubs'
        $leaseRoot = Join-Path $dir 'leases'
        foreach ($p in @($stateDir, $hubRoot, $leaseRoot)) { $null = New-Item -ItemType Directory -Path $p -Force }

        $now = Get-Date
        $startedAt = $now.AddMinutes(-1 * $StartedMinutesAgo)
        $endedAt = $now.AddMinutes(-1 * $EndedMinutesAgo)
        @{ runId = $RunId; startedAt = $startedAt.ToString('o'); endedAt = $endedAt.ToString('o') } |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $stateDir 'cutover-kill-window.json')

        $sendLog = Join-Path $dir 'sends.jsonl'
        $sendStub = Join-Path $dir 'send-stub.ps1'
        @"
param([string]`$AgentId, [string]`$Variant, [string]`$MessageFile)
`$message = Get-Content -LiteralPath `$MessageFile -Raw
[ordered]@{ agentId = `$AgentId; variant = `$Variant; message = `$message } |
    ConvertTo-Json -Compress | Add-Content -LiteralPath '$sendLog'
exit 0
"@ | Set-Content -LiteralPath $sendStub

        [pscustomobject]@{
            Dir        = $dir
            StateDir   = $stateDir
            HubRoot    = $hubRoot
            LeaseRoot  = $leaseRoot
            AuditPath  = Join-Path $dir 'keycheck.jsonl'
            SendLog    = $sendLog
            SendStub   = $sendStub
            RosterPath = Join-Path $dir 'roster.json'
            ReportPath = Join-Path $stateDir "cutover-report-$RunId.json"
            RunId      = $RunId
            StartedAt  = $startedAt
            EndedAt    = $endedAt
        }
    }

    function New-CutoverGitCheckout {
        param([string]$Path, [string]$FileName = 'README.md')
        $null = New-Item -ItemType Directory -Path $Path -Force
        & git -C $Path init --quiet 2>&1 | Out-Null
        & git -C $Path config user.email 'fixture@example.invalid' 2>&1 | Out-Null
        & git -C $Path config user.name 'Fixture' 2>&1 | Out-Null
        Set-Content -LiteralPath (Join-Path $Path $FileName) -Value 'fixture'
        & git -C $Path add -- $FileName 2>&1 | Out-Null
        & git -C $Path commit --quiet -m 'fixture' 2>&1 | Out-Null
        return $Path
    }

    function Save-CutoverRoster {
        param($Fixture, $Agents, [string]$RunId = '')
        $id = if ($RunId) { $RunId } else { $Fixture.RunId }
        @{
            version = 1; capturedAt = (Get-Date).ToString('o'); runId = $id
            from = 'GO6'; to = 'GO3'; source = 'fixture'; agents = @($Agents)
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Fixture.RosterPath
        return $Fixture.RosterPath
    }

    function Add-HubRegistryEntry {
        param($Fixture, [string]$Repo, [string]$AgentId, [datetime]$RegisteredAt, [string]$RepoPath = '')
        $path = Join-Path $Fixture.HubRoot "$Repo.json"
        $record = [ordered]@{ schemaVersion = 2; helperVersion = 3; repo = $Repo; hubs = @() }
        if (Test-Path -LiteralPath $path) {
            $record = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            $record = [ordered]@{
                schemaVersion = 2; helperVersion = 3; repo = $Repo; hubs = @($record.hubs)
            }
        }
        $entry = [ordered]@{
            agentId = $AgentId; machine = $env:COMPUTERNAME; pid = $PID
            repoPath = $RepoPath; trunk = 'dev'; helperVersion = 3
            registeredAt = $RegisteredAt.ToString('o'); heartbeatAt = $RegisteredAt.ToString('o')
        }
        $record.hubs = @(@($record.hubs) + @($entry))
        $record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $path
        return $path
    }

    function Add-LeaseRecord {
        param(
            $Fixture,
            [string]$Path,
            [string]$Owner,
            [int]$ProcessId = $PID,
            [datetime]$AcquiredAt = ([datetime]::UtcNow),
            [int]$Generation = 1,
            [int]$TtlMinutes = 30
        )
        $normalized = ([System.IO.Path]::GetFullPath($Path)).TrimEnd('\', '/')
        $sha1 = [System.Security.Cryptography.SHA1]::Create()
        try {
            $hash = $sha1.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($normalized.ToLowerInvariant()))
        } finally { $sha1.Dispose() }
        $name = (($hash | ForEach-Object { $_.ToString('x2') }) -join '') + '.json'
        $leasePath = Join-Path $Fixture.LeaseRoot $name
        $stamp = [datetimeoffset]$AcquiredAt.ToUniversalTime()
        [ordered]@{
            schemaVersion = 1; path = $normalized; repoRoot = $normalized; branch = 'dev'
            owner = $Owner; agentId = $Owner; pid = $ProcessId; host = $env:COMPUTERNAME
            taskId = 'fixture'; acquiredAt = $stamp.ToString('o'); heartbeatAt = $stamp.ToString('o')
            expiresAt = $stamp.AddMinutes($TtlMinutes).ToString('o'); generation = $Generation
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $leasePath
        return $leasePath
    }

    function Get-CutoverFixtureLeases {
        param($Fixture)
        return @(Get-ChildItem -LiteralPath $Fixture.LeaseRoot -Filter '*.json' -File -ErrorAction SilentlyContinue)
    }

    function Get-CutoverFixtureSends {
        param($Fixture)
        if (-not (Test-Path -LiteralPath $Fixture.SendLog)) { return @() }
        return @(Get-Content -LiteralPath $Fixture.SendLog | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
    }

    function Get-CutoverFixtureAudit {
        param($Fixture)
        if (-not (Test-Path -LiteralPath $Fixture.AuditPath)) { return @() }
        return @(Get-Content -LiteralPath $Fixture.AuditPath | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
    }

    function Invoke-CutoverRecoveryRun {
        param($Fixture, [string[]]$ExtraArgs = @())
        $recoveryArgs = @(
            '-NoProfile', '-File', $script:RecoveryPath,
            '-RunId', $Fixture.RunId,
            '-StateDir', $Fixture.StateDir,
            '-RosterPath', $Fixture.RosterPath,
            '-HubRegistryRoot', $Fixture.HubRoot,
            '-LeaseRoot', $Fixture.LeaseRoot,
            '-AuditPath', $Fixture.AuditPath,
            '-SendScript', $Fixture.SendStub,
            '-Json'
        ) + $ExtraArgs
        $output = & $script:PwshExe @recoveryArgs 2>&1 | Out-String
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($output.Trim()) }
    }
}

Describe 'backstop reconciliation' {

    It 'stands down a Hub row registered inside the cutover window, exactly once' {
        $fixture = New-CutoverRecoveryFixture
        $repo = New-CutoverGitCheckout -Path (Join-Path $fixture.Dir 'cl-common')
        Save-CutoverRoster -Fixture $fixture -Agents @(
            [ordered]@{ id = 'hub-original'; title = 'Hub cl-common'; cwd = $repo; status = 'running'; isHub = $true; hasDoneFile = $false; labels = [ordered]@{ 'hub-common' = 'cl-common' } }
        ) | Out-Null
        Add-HubRegistryEntry -Fixture $fixture -Repo 'cl-common' -AgentId 'backstop-1' `
            -RegisteredAt ((Get-Date).AddMinutes(-7)) -RepoPath $repo | Out-Null

        $run = Invoke-CutoverRecoveryRun -Fixture $fixture

        $run.ExitCode | Should -Be 0 -Because $run.Output
        $stands = @(Get-CutoverFixtureSends -Fixture $fixture | Where-Object { $_.variant -eq 'standdown' })
        $stands.Count | Should -Be 1
        $stands[0].agentId | Should -Be 'backstop-1'
        $stands[0].message | Should -Match 'run-cut1'
        $stands[0].message | Should -Match 'hub-original'
        @(Get-CutoverFixtureAudit -Fixture $fixture | Where-Object { $_.kind -eq 'cutover-standdown' }).Count | Should -Be 1
    }

    It 'stands down nothing for a Hub row registered outside the window' {
        $fixture = New-CutoverRecoveryFixture
        $repo = New-CutoverGitCheckout -Path (Join-Path $fixture.Dir 'cl-common')
        Save-CutoverRoster -Fixture $fixture -Agents @(
            [ordered]@{ id = 'hub-original'; title = 'Hub cl-common'; cwd = $repo; status = 'running'; isHub = $true; hasDoneFile = $false; labels = [ordered]@{ 'hub-common' = 'cl-common' } }
        ) | Out-Null
        Add-HubRegistryEntry -Fixture $fixture -Repo 'cl-common' -AgentId 'long-lived' `
            -RegisteredAt ((Get-Date).AddMinutes(-90)) -RepoPath $repo | Out-Null

        $run = Invoke-CutoverRecoveryRun -Fixture $fixture

        $run.ExitCode | Should -Be 0 -Because $run.Output
        @(Get-CutoverFixtureSends -Fixture $fixture | Where-Object { $_.variant -eq 'standdown' }).Count | Should -Be 0
    }

    It 'never seizes a live backstop lease without -ForceRevoke, and logs owner+generation when it does' {
        $fixture = New-CutoverRecoveryFixture
        $repo = New-CutoverGitCheckout -Path (Join-Path $fixture.Dir 'cl-common')
        Save-CutoverRoster -Fixture $fixture -Agents @(
            [ordered]@{ id = 'hub-original'; title = 'Hub cl-common'; cwd = $repo; status = 'running'; isHub = $true; hasDoneFile = $false; labels = [ordered]@{ 'hub-common' = 'cl-common' } }
        ) | Out-Null
        $inside = Add-LeaseRecord -Fixture $fixture -Path $repo -Owner 'backstop-1' -ProcessId $PID `
            -AcquiredAt (Get-Date).AddMinutes(-7) -Generation 4
        $outsideRepo = New-CutoverGitCheckout -Path (Join-Path $fixture.Dir 'other-repo')
        $outside = Add-LeaseRecord -Fixture $fixture -Path $outsideRepo -Owner 'backstop-2' -ProcessId $PID `
            -AcquiredAt (Get-Date).AddMinutes(-90) -Generation 2

        $first = Invoke-CutoverRecoveryRun -Fixture $fixture

        $first.ExitCode | Should -Be 0 -Because $first.Output
        Test-Path -LiteralPath $inside | Should -BeTrue -Because 'a live holder is never seized without -ForceRevoke'
        @(Get-CutoverFixtureSends -Fixture $fixture | Where-Object { $_.variant -eq 'standdown' }).Count | Should -Be 1

        $second = Invoke-CutoverRecoveryRun -Fixture $fixture -ExtraArgs @('-ForceRevoke', '-Force')

        $second.ExitCode | Should -Be 0 -Because $second.Output
        Test-Path -LiteralPath $inside | Should -BeFalse -Because '-ForceRevoke releases a lease inside the window'
        Test-Path -LiteralPath $outside | Should -BeTrue -Because 'a lease outside the window is never revoked'
        $line = @(Get-CutoverFixtureAudit -Fixture $fixture | Where-Object { $_.kind -eq 'cutover-lease-revoked' })
        $line.Count | Should -Be 1
        $line[0].owner | Should -Be 'backstop-1'
        $line[0].generation | Should -Be 4
        $line[0].runId | Should -Be 'run-cut1'
    }
}

Describe 'role restoration and dead leases' {

    It 're-registers the original Hub and releases a dead-pid lease with reason cutover' {
        $fixture = New-CutoverRecoveryFixture
        $repo = New-CutoverGitCheckout -Path (Join-Path $fixture.Dir 'cl-common')
        Save-CutoverRoster -Fixture $fixture -Agents @(
            [ordered]@{ id = 'hub-original'; title = 'Hub cl-common'; cwd = $repo; status = 'running'; isHub = $true; hasDoneFile = $false; labels = [ordered]@{ 'hub-common' = 'cl-common' } }
            [ordered]@{ id = 'lane-live'; title = 'lane'; cwd = $repo; status = 'running'; isHub = $false; hasDoneFile = $false; labels = [ordered]@{} }
        ) | Out-Null
        $deadLease = Add-LeaseRecord -Fixture $fixture -Path $repo -Owner 'hub-original' -ProcessId 999999 `
            -AcquiredAt (Get-Date).AddMinutes(-8) -Generation 7
        $liveRepo = New-CutoverGitCheckout -Path (Join-Path $fixture.Dir 'live-repo')
        $liveLease = Add-LeaseRecord -Fixture $fixture -Path $liveRepo -Owner 'lane-live' -ProcessId $PID `
            -AcquiredAt (Get-Date).AddMinutes(-7) -Generation 3

        $run = Invoke-CutoverRecoveryRun -Fixture $fixture

        $run.ExitCode | Should -Be 0 -Because $run.Output
        # the dead lease is released, the live one is untouched
        Test-Path -LiteralPath $deadLease | Should -BeFalse
        Test-Path -LiteralPath $liveLease | Should -BeTrue

        $released = @(Get-CutoverFixtureAudit -Fixture $fixture | Where-Object { $_.kind -eq 'cutover-lease-released' })
        $released.Count | Should -Be 1
        $released[0].reason | Should -Be 'cutover'
        $released[0].owner | Should -Be 'hub-original'
        $released[0].generation | Should -Be 7

        # the registry Register is attempted by the tool itself
        $recordPath = Join-Path $fixture.HubRoot 'cl-common.json'
        Test-Path -LiteralPath $recordPath | Should -BeTrue -Because 'the tool re-registers the original Hub'
        $record = Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json
        @($record.hubs | Where-Object { $_.agentId -eq 'hub-original' }).Count | Should -Be 1

        $register = @(Get-CutoverFixtureAudit -Fixture $fixture | Where-Object { $_.kind -eq 'cutover-role-register' })
        $register.Count | Should -Be 1
        $register[0].ok | Should -BeTrue
        @($register | Where-Object { $_.note -match 'lease' }).Count | Should -Be 1
    }
}

Describe 'gate stamping' {

    It 'stamps a gate run modified inside the kill window and leaves one outside alone' {
        $dir = Join-Path $TestDrive ("kc-gates-{0}" -f ([guid]::NewGuid().ToString('N')))
        $repo = Join-Path $dir 'cl-common'
        $gateRuns = Join-Path $repo '.gate-runs'
        $inside = Join-Path $gateRuns '20261102-172900'
        $outside = Join-Path $gateRuns '20261101-090000'
        foreach ($p in @($inside, $outside)) { $null = New-Item -ItemType Directory -Path $p -Force }
        Set-Content -LiteralPath (Join-Path $inside 'run.log') -Value "starting`npester: 41 passed`nvitest: running"
        Set-Content -LiteralPath (Join-Path $outside 'run.log') -Value 'all green'
        $started = (Get-Date).AddMinutes(-10)
        $ended = (Get-Date).AddMinutes(-5)
        (Get-Item -LiteralPath $inside).LastWriteTime = (Get-Date).AddMinutes(-7)
        (Get-Item -LiteralPath $outside).LastWriteTime = (Get-Date).AddDays(-1)

        $output = & $script:PwshExe -NoProfile -File $script:StampPath `
            -Root $repo -RunId 'run-cut1' `
            -WindowStart $started.ToString('o') -WindowEnd $ended.ToString('o') 2>&1 | Out-String

        $LASTEXITCODE | Should -Be 0 -Because $output
        $marker = Join-Path $inside 'killed-by-cutover.json'
        Test-Path -LiteralPath $marker | Should -BeTrue
        $record = Get-Content -LiteralPath $marker -Raw | ConvertFrom-Json
        $record.runId | Should -Be 'run-cut1'
        $record.at | Should -Not -BeNullOrEmpty
        $record.lastLogLine | Should -Be 'vitest: running'
        Test-Path -LiteralPath (Join-Path $outside 'killed-by-cutover.json') | Should -BeFalse
    }

    It 'reads the window from cutover-kill-window.json when it is not passed' {
        $fixture = New-CutoverRecoveryFixture
        $repo = New-CutoverGitCheckout -Path (Join-Path $fixture.Dir 'cl-common')
        $gate = Join-Path $repo '.gate-runs\20261102-172900'
        $null = New-Item -ItemType Directory -Path $gate -Force
        Set-Content -LiteralPath (Join-Path $gate 'run.log') -Value 'interrupted'
        (Get-Item -LiteralPath $gate).LastWriteTime = (Get-Date).AddMinutes(-7)

        $output = & $script:PwshExe -NoProfile -File $script:StampPath `
            -Root $repo -RunId $fixture.RunId `
            -KillWindowPath (Join-Path $fixture.StateDir 'cutover-kill-window.json') 2>&1 | Out-String

        $LASTEXITCODE | Should -Be 0 -Because $output
        Test-Path -LiteralPath (Join-Path $gate 'killed-by-cutover.json') | Should -BeTrue
    }
}

Describe 'recovery report and idempotence' {

    It 'writes one report per runId and a second recovery sends nothing' {
        $fixture = New-CutoverRecoveryFixture
        $repo = New-CutoverGitCheckout -Path (Join-Path $fixture.Dir 'cl-common')
        Save-CutoverRoster -Fixture $fixture -Agents @(
            [ordered]@{ id = 'hub-original'; title = 'Hub cl-common'; cwd = $repo; status = 'running'; isHub = $true; hasDoneFile = $false; labels = [ordered]@{ 'hub-common' = 'cl-common' } }
        ) | Out-Null
        Add-HubRegistryEntry -Fixture $fixture -Repo 'cl-common' -AgentId 'backstop-1' `
            -RegisteredAt ((Get-Date).AddMinutes(-7)) -RepoPath $repo | Out-Null

        $first = Invoke-CutoverRecoveryRun -Fixture $fixture
        $second = Invoke-CutoverRecoveryRun -Fixture $fixture

        $first.ExitCode | Should -Be 0 -Because $first.Output
        $second.ExitCode | Should -Be 0 -Because $second.Output
        $second.Output | Should -Match 'already-recovered'
        @(Get-CutoverFixtureSends -Fixture $fixture | Where-Object { $_.variant -eq 'standdown' }).Count | Should -Be 1
        @(Get-ChildItem -LiteralPath $fixture.StateDir -Filter 'cutover-report-run-cut1.json' -File).Count | Should -Be 1
        @(Get-ChildItem -LiteralPath $fixture.StateDir -Filter 'cutover-report-run-cut1.md' -File).Count | Should -Be 1
    }

    It 'classifies every agent and flags an uncommitted worktree and a missing report' {
        $fixture = New-CutoverRecoveryFixture
        $gitRepo = New-CutoverGitCheckout -Path (Join-Path $fixture.Dir 'cl-common')
        $lane = New-CutoverGitCheckout -Path (Join-Path $fixture.Dir 'lane-worktree')
        # uncommitted work, no .iqa-report.md, no done file
        Set-Content -LiteralPath (Join-Path $lane 'uncommitted.txt') -Value 'wip'
        Save-CutoverRoster -Fixture $fixture -Agents @(
            [ordered]@{ id = 'hub-original'; title = 'Hub cl-common'; cwd = $gitRepo; status = 'running'; isHub = $true; hasDoneFile = $false; labels = [ordered]@{ 'hub-common' = 'cl-common' } }
            [ordered]@{ id = 'lane-resumed'; title = 'lane resumed'; cwd = $lane; status = 'running'; isHub = $false; hasDoneFile = $true; labels = [ordered]@{} }
            [ordered]@{ id = 'lane-finished'; title = 'lane finished'; cwd = $lane; status = 'running'; isHub = $false; hasDoneFile = $true; labels = [ordered]@{} }
        ) | Out-Null
        @(
            [ordered]@{ kind = 'roster-resume'; runId = 'run-cut1'; agentId = 'lane-resumed'; decision = 'resumed'; reason = 'live'; variant = 'lane'; isHub = $false }
            [ordered]@{ kind = 'roster-resume'; runId = 'run-cut1'; agentId = 'lane-finished'; decision = 'skipped-finished'; reason = 'its own done file'; variant = 'lane'; isHub = $false }
            [ordered]@{ kind = 'roster-resume-failed'; runId = 'run-cut1'; agentId = 'lane-gap'; reason = 'send failed: active run cancellation was not acknowledged'; unhandled = $true }
        ) | ForEach-Object { ($_ | ConvertTo-Json -Compress) } | Add-Content -LiteralPath $fixture.AuditPath

        $run = Invoke-CutoverRecoveryRun -Fixture $fixture

        $run.ExitCode | Should -Be 0 -Because $run.Output
        Test-Path -LiteralPath $fixture.ReportPath | Should -BeTrue
        $report = Get-Content -LiteralPath $fixture.ReportPath -Raw | ConvertFrom-Json
        $report.runId | Should -Be 'run-cut1'
        @($report.closed | ForEach-Object { $_.id }) | Should -Contain 'lane-resumed'
        $closed = @($report.closed | Where-Object { $_.id -eq 'lane-resumed' })[0]
        $closed.repo | Should -Be 'lane-worktree'
        $closed.cwd | Should -Be $lane
        $closed.branch | Should -Be 'master'
        $closed.head | Should -Not -BeNullOrEmpty
        @($report.resumed | ForEach-Object { $_.id }) | Should -Be @('lane-resumed')
        @($report.unresumed | ForEach-Object { $_.id }) | Should -Contain 'lane-finished'
        (@($report.unresumed | Where-Object { $_.id -eq 'lane-finished' })[0]).reason | Should -Match 'done file'
        @($report.worktrees | Where-Object { $_.path -eq $lane }).Count | Should -Be 1
        $wt = @($report.worktrees | Where-Object { $_.path -eq $lane })[0]
        $wt.uncommitted | Should -BeTrue
        $wt.missingReport | Should -BeTrue
        $wt.missingDone | Should -BeTrue
        @($report.unhandled | ForEach-Object { $_.agentId }) | Should -Be @('lane-gap')
        Test-Path -LiteralPath ([System.IO.Path]::ChangeExtension($fixture.ReportPath, '.md')) | Should -BeTrue
    }
}
