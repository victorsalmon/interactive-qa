#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0.0' }

<#
.SYNOPSIS
    Pester tests for Capture-KeyCheckRoster.ps1.

.DESCRIPTION
    The roster is the only record of who a cutover stranded. The contract:

      - one entry per live agent, with id, title, cwd, status, sessionId,
        lastActivityAt, labels, isHub and hasDoneFile;
      - this process and `merge-*` workers are never in it;
      - an agent whose checkout already holds `.iqa-report.md` or an
        `.iqa-done-*.json` is recorded as finished, so nobody nudges it;
      - a Hub is an agent whose labels carry a `hub-*` key or `iqa-role=merge`;
      - no key value is ever read or written.
#>

BeforeAll {
    $script:SkillRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
    $script:ScriptPath = Join-Path $script:SkillRoot 'scripts\Capture-KeyCheckRoster.ps1'
    $script:PwshExe = Join-Path $PSHOME 'pwsh.exe'
    . (Join-Path $PSScriptRoot 'fixtures\RosterTestKit.ps1')

    function Invoke-Capture {
        param($Fixture, [hashtable]$Options = @{})
        $agentList = Save-RosterAgentList -Fixture $Fixture
        $args = @(
            '-NoProfile', '-File', $script:ScriptPath,
            '-RunId', 'run-c1',
            '-FromKeyNumber', '1',
            '-ToKeyNumber', '2',
            '-OutPath', $Fixture.RosterPath,
            '-AgentListFile', $agentList,
            '-AgentsDir', $Fixture.AgentsDir,
            '-SelfAgentId', $env:PASEO_AGENT_ID
        )
        if ($Options.ContainsKey('Json')) { $args += '-Json' }
        $output = & $script:PwshExe @args 2>&1 | Out-String
        $roster = $null
        if (Test-Path -LiteralPath $Fixture.RosterPath) {
            $roster = Get-Content -LiteralPath $Fixture.RosterPath -Raw | ConvertFrom-Json
        }
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output; Roster = $roster }
    }
}

Describe 'Capture-KeyCheckRoster' {

    It 'records one entry per live agent with identity, labels and done-file evidence' {
        $fixture = New-RosterFixture -Root $TestDrive
        Add-RosterAgent -Fixture $fixture -Id 'agent-lane-1' -Title '266 adaptive cadence' -Cwd (Join-Path $fixture.Dir 'lane1')
        Add-RosterAgent -Fixture $fixture -Id 'agent-hub-1' -Title 'Hub cl-common' -Cwd (Join-Path $fixture.Dir 'hub1') `
            -Labels @{ 'hub-common' = 'cl-common' }

        $run = Invoke-Capture -Fixture $fixture

        $run.ExitCode | Should -Be 0 -Because $run.Output
        $run.Roster.version | Should -Be 1
        $run.Roster.runId | Should -Be 'run-c1'
        $run.Roster.from | Should -Be 'GO1'
        $run.Roster.to | Should -Be 'GO2'
        $run.Roster.capturedAt | Should -Not -BeNullOrEmpty
        $run.Roster.source | Should -Match '^fixture:'
        @($run.Roster.agents).Count | Should -Be 2

        $lane = @($run.Roster.agents | Where-Object { $_.id -eq 'agent-lane-1' })[0]
        $lane.title | Should -Be '266 adaptive cadence'
        $lane.status | Should -Be 'running'
        $lane.cwd | Should -Be (Join-Path $fixture.Dir 'lane1')
        $lane.sessionId | Should -Be 'sess-0001'
        $lane.lastActivityAt | Should -Not -BeNullOrEmpty
        $lane.hasDoneFile | Should -BeFalse
        $lane.isHub | Should -BeFalse

        $hub = @($run.Roster.agents | Where-Object { $_.id -eq 'agent-hub-1' })[0]
        $hub.isHub | Should -BeTrue
        $hub.labels.'hub-common' | Should -Be 'cl-common'
    }

    It 'treats iqa-role=merge as a Hub and any other iqa-role as a lane' {
        $fixture = New-RosterFixture -Root $TestDrive
        Add-RosterAgent -Fixture $fixture -Id 'agent-merge' -Title 'hub worker' -Labels @{ 'iqa-role' = 'merge' }
        Add-RosterAgent -Fixture $fixture -Id 'agent-lane' -Title 'lane worker' -Labels @{ 'iqa-role' = 'code' }

        $run = Invoke-Capture -Fixture $fixture

        $run.ExitCode | Should -Be 0 -Because $run.Output
        (@($run.Roster.agents | Where-Object { $_.id -eq 'agent-merge' })[0]).isHub | Should -BeTrue
        (@($run.Roster.agents | Where-Object { $_.id -eq 'agent-lane' })[0]).isHub | Should -BeFalse
    }

    It 'marks an agent finished when its checkout already holds completion evidence' {
        $fixture = New-RosterFixture -Root $TestDrive
        $doneCwd = Join-Path $fixture.Dir 'done-lane'
        $null = New-Item -ItemType Directory -Path $doneCwd -Force
        Set-Content -LiteralPath (Join-Path $doneCwd '.iqa-report.md') -Value 'finished'
        $jsonCwd = Join-Path $fixture.Dir 'done-json-lane'
        $null = New-Item -ItemType Directory -Path $jsonCwd -Force
        Set-Content -LiteralPath (Join-Path $jsonCwd '.iqa-done-agent-d.json') -Value '{}'
        Add-RosterAgent -Fixture $fixture -Id 'agent-report' -Cwd $doneCwd
        Add-RosterAgent -Fixture $fixture -Id 'agent-done-json' -Cwd $jsonCwd
        Add-RosterAgent -Fixture $fixture -Id 'agent-open' -Cwd (Join-Path $fixture.Dir 'open-lane')

        $run = Invoke-Capture -Fixture $fixture

        $run.ExitCode | Should -Be 0 -Because $run.Output
        (@($run.Roster.agents | Where-Object { $_.id -eq 'agent-report' })[0]).hasDoneFile | Should -BeTrue
        (@($run.Roster.agents | Where-Object { $_.id -eq 'agent-done-json' })[0]).hasDoneFile | Should -BeTrue
        (@($run.Roster.agents | Where-Object { $_.id -eq 'agent-open' })[0]).hasDoneFile | Should -BeFalse
    }

    It 'never treats a repository root as one agent completion evidence' {
        $fixture = New-RosterFixture -Root $TestDrive
        $trunk = Join-Path $fixture.Dir 'cl-common'
        $null = New-Item -ItemType Directory -Path (Join-Path $trunk '.git') -Force
        Set-Content -LiteralPath (Join-Path $trunk '.iqa-report.md') -Value 'merge worker report'
        Set-Content -LiteralPath (Join-Path $trunk '.iqa-done-merge-cl-common-1dq.json') -Value '{}'
        Add-RosterAgent -Fixture $fixture -Id 'agent-hub-trunk-1' -Title 'Hub cl-common' -Cwd $trunk `
            -Labels @{ 'hub-common' = 'cl-common' }

        $run = Invoke-Capture -Fixture $fixture

        $run.ExitCode | Should -Be 0 -Because $run.Output
        $hub = @($run.Roster.agents | Where-Object { $_.id -eq 'agent-hub-trunk-1' })[0]
        $hub.isHub | Should -BeTrue
        $hub.hasDoneFile | Should -BeFalse
    }

    It 'only counts a done file that names this agent or its bead' {
        $fixture = New-RosterFixture -Root $TestDrive
        $ownCwd = Join-Path $fixture.Dir 'own-worktree'
        $null = New-Item -ItemType Directory -Path $ownCwd -Force
        Set-Content -LiteralPath (Join-Path $ownCwd '.iqa-done-agent-o.json') -Value '{}'
        $beadCwd = Join-Path $fixture.Dir 'bead-worktree'
        $null = New-Item -ItemType Directory -Path $beadCwd -Force
        Set-Content -LiteralPath (Join-Path $beadCwd '.iqa-done-cl-common-qz8.json') -Value '{}'
        $foreignCwd = Join-Path $fixture.Dir 'foreign-worktree'
        $null = New-Item -ItemType Directory -Path $foreignCwd -Force
        Set-Content -LiteralPath (Join-Path $foreignCwd '.iqa-done-someone-else.json') -Value '{}'

        Add-RosterAgent -Fixture $fixture -Id 'agent-own-1' -Cwd $ownCwd
        Add-RosterAgent -Fixture $fixture -Id 'agent-bead-1' -Title 'cl-common-qz8 lane' -Cwd $beadCwd
        Add-RosterAgent -Fixture $fixture -Id 'agent-foreign-1' -Cwd $foreignCwd

        $run = Invoke-Capture -Fixture $fixture

        $run.ExitCode | Should -Be 0 -Because $run.Output
        (@($run.Roster.agents | Where-Object { $_.id -eq 'agent-own-1' })[0]).hasDoneFile | Should -BeTrue
        (@($run.Roster.agents | Where-Object { $_.id -eq 'agent-bead-1' })[0]).hasDoneFile | Should -BeTrue
        (@($run.Roster.agents | Where-Object { $_.id -eq 'agent-foreign-1' })[0]).hasDoneFile | Should -BeFalse
    }

    It 'never records this process or a merge-* worker' {
        $fixture = New-RosterFixture -Root $TestDrive
        Add-RosterAgent -Fixture $fixture -Id 'agent-lane-1' -Title 'lane'
        Add-RosterAgent -Fixture $fixture -Id 'agent-merge-worker' -Title 'merge-cl-common-1dq'
        Add-RosterAgent -Fixture $fixture -Id 'agent-self' -Title 'self lane'
        $agentList = Save-RosterAgentList -Fixture $fixture

        $output = & $script:PwshExe -NoProfile -File $script:ScriptPath -RunId 'run-c1' `
            -OutPath $fixture.RosterPath -AgentListFile $agentList -AgentsDir $fixture.AgentsDir `
            -SelfAgentId 'agent-self' 2>&1 | Out-String

        $LASTEXITCODE | Should -Be 0 -Because $output
        $roster = Get-Content -LiteralPath $fixture.RosterPath -Raw | ConvertFrom-Json
        @($roster.agents | ForEach-Object { $_.id }) | Should -Be @('agent-lane-1')
    }

    It 'skips a closed agent - it is not live' {
        $fixture = New-RosterFixture -Root $TestDrive
        Add-RosterAgent -Fixture $fixture -Id 'agent-running' -Status 'running'
        Add-RosterAgent -Fixture $fixture -Id 'agent-closed' -Status 'closed'

        $run = Invoke-Capture -Fixture $fixture

        $run.ExitCode | Should -Be 0 -Because $run.Output
        @($run.Roster.agents | ForEach-Object { $_.id }) | Should -Be @('agent-running')
    }

    It 'never writes a key value - only GO labels' {
        $fixture = New-RosterFixture -Root $TestDrive
        Add-RosterAgent -Fixture $fixture -Id 'agent-lane-1'

        $run = Invoke-Capture -Fixture $fixture
        $raw = Get-Content -LiteralPath $fixture.RosterPath -Raw

        $run.ExitCode | Should -Be 0 -Because $run.Output
        $raw | Should -Not -Match 'OPENCODE_GO\d+_KEY='
        $raw | Should -Not -Match 'sk-[A-Za-z0-9]'
        $raw | Should -Match '"from":\s*"GO1"'
        $raw | Should -Match '"to":\s*"GO2"'
    }

    It 'fails honestly when the agent list cannot be read' {
        $fixture = New-RosterFixture -Root $TestDrive
        $output = & $script:PwshExe -NoProfile -File $script:ScriptPath -RunId 'run-c1' `
            -OutPath $fixture.RosterPath -AgentListFile (Join-Path $fixture.Dir 'nope.json') `
            -AgentsDir $fixture.AgentsDir 2>&1 | Out-String

        $LASTEXITCODE | Should -Not -Be 0
        Test-Path -LiteralPath $fixture.RosterPath | Should -BeFalse
    }
}
