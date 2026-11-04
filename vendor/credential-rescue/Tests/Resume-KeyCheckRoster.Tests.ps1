#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0.0' }

<#
.SYNOPSIS
    Pester tests for Resume-KeyCheckRoster.ps1.

.DESCRIPTION
    A cutover strands lanes and Hubs. The contract:

      - a running lane is nudged with the exact lane text, a Hub with the exact
        Hub text (enumerate YOUR children, resume the non-terminal ones, do not
        re-dispatch committed work);
      - finished / closed / self / merge-* / missing / over-cap agents are
        skipped with the named decision, one audit line each;
      - a second pass is idempotent: `skipped-already-nudged`, no second send;
      - -LogOnly decides and logs but sends nothing, and does not consume the
        idempotency slot; -DryRun writes nothing at all;
      - `last-cutover.json` is written with runId, at, from, to, rosterPath,
        witnessPath and verdict.
#>

BeforeAll {
    $script:SkillRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
    $script:CapturePath = Join-Path $script:SkillRoot 'scripts\Capture-KeyCheckRoster.ps1'
    $script:ResumePath = Join-Path $script:SkillRoot 'scripts\Resume-KeyCheckRoster.ps1'
    $script:PwshExe = Join-Path $PSHOME 'pwsh.exe'
    . (Join-Path $PSScriptRoot 'fixtures\RosterTestKit.ps1')

    $script:LaneMessage = 'Continue working — a key cutover just occurred (GO1 → GO2) and your session may have been restarted. Re-read your brief and carry on; report to your parent as usual.'
    $script:HubMessage = 'A key cutover just occurred (GO1 → GO2) and your session may have been restarted. You are a Hub: enumerate YOUR child agents, resume every non-terminal one with its exact missing artifacts (report, done file, gate lines), and do not re-dispatch work that already has commits on its branch. Then continue your own queue.'

    function New-RosterRun {
        param($Fixture, [hashtable]$Options = @{})
        $agentList = Save-RosterAgentList -Fixture $Fixture
        if (-not $Options.ContainsKey('SkipCapture')) {
            $captureArgs = @(
                '-NoProfile', '-File', $script:CapturePath, '-RunId', 'run-r1',
                '-FromKeyNumber', '1', '-ToKeyNumber', '2',
                '-OutPath', $Fixture.RosterPath, '-AgentListFile', $agentList, '-AgentsDir', $Fixture.AgentsDir
            )
            $null = & $script:PwshExe @captureArgs 2>&1 | Out-String
        }

        $resumeArgs = @(
            '-NoProfile', '-File', $script:ResumePath,
            '-RosterPath', $Fixture.RosterPath,
            '-StateDir', $Fixture.StateDir,
            '-AuditPath', $Fixture.AuditPath,
            '-AgentListFile', $agentList,
            '-SendScript', $Fixture.SendStub
        )
        if ($Options.ContainsKey('MaxAgents')) { $resumeArgs += @('-MaxAgents', [string]$Options.MaxAgents) }
        if ($Options.ContainsKey('LogOnly')) { $resumeArgs += '-LogOnly' }
        if ($Options.ContainsKey('DryRun')) { $resumeArgs += '-DryRun' }
        if ($Options.ContainsKey('SelfAgentId')) { $resumeArgs += @('-SelfAgentId', [string]$Options.SelfAgentId) }
        $output = & $script:PwshExe @resumeArgs 2>&1 | Out-String
        [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Output   = $output
            Sends    = @(Get-RosterSendLog -Fixture $Fixture)
            Audit    = @(Get-RosterAuditRows -Fixture $Fixture)
        }
    }
}

Describe 'Resume-KeyCheckRoster decisions' {

    It 'nudges a running lane with the exact lane message' {
        $fixture = New-RosterFixture -Root $TestDrive
        $null = New-RosterSendStub -Fixture $fixture
        Add-RosterAgent -Fixture $fixture -Id 'agent-lane-1' -Title '266 adaptive cadence'

        $run = New-RosterRun -Fixture $fixture

        $run.ExitCode | Should -Be 0 -Because $run.Output
        $run.Sends.Count | Should -Be 1
        $run.Sends[0].agentId | Should -Be 'agent-lane-1'
        $run.Sends[0].variant | Should -Be 'lane'
        $run.Sends[0].message | Should -BeExactly $script:LaneMessage

        $line = @($run.Audit | Where-Object { $_.kind -eq 'roster-resume' })[0]
        $line.decision | Should -Be 'resumed'
        $line.variant | Should -Be 'lane'
        $line.runId | Should -Be 'run-r1'
        $line.agentId | Should -Be 'agent-lane-1'
        $line.at | Should -Not -BeNullOrEmpty
    }

    It 'nudges a labelled Hub with the Hub message, and an unlabelled agent with the lane message' {
        $fixture = New-RosterFixture -Root $TestDrive
        $null = New-RosterSendStub -Fixture $fixture
        Add-RosterAgent -Fixture $fixture -Id 'agent-hub-1' -Title 'Hub cl-common' -Labels @{ 'hub-common' = 'cl-common' }
        Add-RosterAgent -Fixture $fixture -Id 'agent-lane-1' -Title 'lane work'

        $run = New-RosterRun -Fixture $fixture

        $run.ExitCode | Should -Be 0 -Because $run.Output
        $hub = @($run.Sends | Where-Object { $_.agentId -eq 'agent-hub-1' })[0]
        $lane = @($run.Sends | Where-Object { $_.agentId -eq 'agent-lane-1' })[0]
        $hub.variant | Should -Be 'hub'
        # the headline is stable; the role-restore block follows it
        $hub.message | Should -BeLike "$script:HubMessage*"
        $hub.message | Should -Match 'Role re-assert'
        $hub.message | Should -Match 'Invoke-WorktreeLease\.ps1'
        $lane.variant | Should -Be 'lane'
        $lane.message | Should -BeExactly $script:LaneMessage

        $hubLine = @($run.Audit | Where-Object { $_.kind -eq 'roster-resume' -and $_.agentId -eq 'agent-hub-1' })[0]
        $hubLine.variant | Should -Be 'hub'
        $hubLine.isHub | Should -BeTrue
    }

    It 'skips a finished lane - it already has its own done evidence' {
        $fixture = New-RosterFixture -Root $TestDrive
        $null = New-RosterSendStub -Fixture $fixture
        $doneCwd = Join-Path $fixture.Dir 'done-lane'
        $null = New-Item -ItemType Directory -Path $doneCwd -Force
        # `agent-done` has the short id `agent-d`: the file must be its own.
        Set-Content -LiteralPath (Join-Path $doneCwd '.iqa-done-agent-d.json') -Value '{}'
        Add-RosterAgent -Fixture $fixture -Id 'agent-done' -Cwd $doneCwd
        Add-RosterAgent -Fixture $fixture -Id 'agent-open'

        $run = New-RosterRun -Fixture $fixture

        $run.ExitCode | Should -Be 0 -Because $run.Output
        @($run.Sends | ForEach-Object { $_.agentId }) | Should -Be @('agent-open')
        (@($run.Audit | Where-Object { $_.agentId -eq 'agent-done' })[0]).decision | Should -Be 'skipped-finished'
    }

    It 'resumes a Hub whose cwd is a shared trunk holding merge workers done files' {
        # The cutover on 2026-11-03: the cl-common Hub sat on the shared trunk,
        # which accumulated .iqa-report.md and .iqa-done-merge-*.json from its
        # merge workers. That cwd is NOT the Hub's own completion evidence.
        $fixture = New-RosterFixture -Root $TestDrive
        $null = New-RosterSendStub -Fixture $fixture
        $trunk = Join-Path $fixture.Dir 'cl-common'
        $null = New-Item -ItemType Directory -Path (Join-Path $trunk '.git') -Force
        Set-Content -LiteralPath (Join-Path $trunk '.iqa-report.md') -Value 'merge worker report'
        Set-Content -LiteralPath (Join-Path $trunk '.iqa-done-merge-cl-common-1dq.json') -Value '{}'
        Set-Content -LiteralPath (Join-Path $trunk '.iqa-done-merge-cl-common-6yr.json') -Value '{}'
        Add-RosterAgent -Fixture $fixture -Id 'agent-hub-trunk-1' -Title 'Hub cl-common' -Cwd $trunk `
            -Labels @{ 'hub-common' = 'cl-common' }

        $run = New-RosterRun -Fixture $fixture

        $run.ExitCode | Should -Be 0 -Because $run.Output
        @($run.Sends | ForEach-Object { $_.agentId }) | Should -Be @('agent-hub-trunk-1')
        $run.Sends[0].variant | Should -Be 'hub'
        $run.Sends[0].message | Should -BeLike "$script:HubMessage*"
        $run.Sends[0].message | Should -Match 'HubRegistry\.ps1'
        (@($run.Audit | Where-Object { $_.kind -eq 'roster-resume' -and $_.agentId -eq 'agent-hub-trunk-1' })[0]).decision | Should -Be 'resumed'
    }

    It 'does not inherit another agent done file from its cwd' {
        $fixture = New-RosterFixture -Root $TestDrive
        $null = New-RosterSendStub -Fixture $fixture
        $cwd = Join-Path $fixture.Dir 'shared-worktree'
        $null = New-Item -ItemType Directory -Path $cwd -Force
        Set-Content -LiteralPath (Join-Path $cwd '.iqa-done-someone-else.json') -Value '{}'
        Add-RosterAgent -Fixture $fixture -Id 'agent-lane-own' -Cwd $cwd

        $run = New-RosterRun -Fixture $fixture

        $run.ExitCode | Should -Be 0 -Because $run.Output
        @($run.Sends | ForEach-Object { $_.agentId }) | Should -Be @('agent-lane-own')
        (@($run.Audit | Where-Object { $_.agentId -eq 'agent-lane-own' })[0]).decision | Should -Be 'resumed'
    }

    It 'skips an agent whose status is closed and names the status' {
        $fixture = New-RosterFixture -Root $TestDrive
        $null = New-RosterSendStub -Fixture $fixture
        Add-RosterAgent -Fixture $fixture -Id 'agent-closed-1'
        $agentList = Save-RosterAgentList -Fixture $fixture
        @{
            runId  = 'run-r1'; from = 'GO1'; to = 'GO2'; source = 'fixture'; capturedAt = (Get-Date).ToString('o')
            agents = @(
                [ordered]@{ id = 'agent-closed-1'; title = 'lane'; cwd = $fixture.Dir; status = 'closed'; hasDoneFile = $false; isHub = $false; labels = @{} }
            )
        } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $fixture.RosterPath

        $run = New-RosterRun -Fixture $fixture -Options @{ SkipCapture = $true }

        $run.ExitCode | Should -Be 0 -Because $run.Output
        $run.Sends.Count | Should -Be 0
        $line = @($run.Audit | Where-Object { $_.kind -eq 'roster-resume' -and $_.agentId -eq 'agent-closed-1' })[0]
        $line.decision | Should -Be 'skipped-finished'
        $line.reason | Should -Match 'closed'
    }

    It 'skips an agent whose cwd is gone, sends nothing and records no failure' {
        $fixture = New-RosterFixture -Root $TestDrive
        $null = New-RosterSendStub -Fixture $fixture
        $swept = Join-Path $fixture.Dir 'swept-worktree'
        $null = New-Item -ItemType Directory -Path $swept -Force
        Add-RosterAgent -Fixture $fixture -Id 'agent-swept-lane' -Cwd $swept
        $null = & $script:PwshExe -NoProfile -File $script:CapturePath -RunId 'run-r1' `
            -FromKeyNumber 1 -ToKeyNumber 2 -OutPath $fixture.RosterPath `
            -AgentListFile (Save-RosterAgentList -Fixture $fixture) -AgentsDir $fixture.AgentsDir 2>&1
        # the worktree was swept between capture and recovery
        Remove-Item -LiteralPath $swept -Recurse -Force

        $run = New-RosterRun -Fixture $fixture -Options @{ SkipCapture = $true }

        $run.ExitCode | Should -Be 0 -Because $run.Output
        $run.Sends.Count | Should -Be 0
        (@($run.Audit | Where-Object { $_.kind -eq 'roster-resume' -and $_.agentId -eq 'agent-swept-lane' })[0]).decision | Should -Be 'skipped-missing-cwd'
        @($run.Audit | Where-Object { $_.kind -eq 'roster-resume-failed' }).Count | Should -Be 0
    }

    It 'never nudges this process or a merge-* worker' {
        $fixture = New-RosterFixture -Root $TestDrive
        $null = New-RosterSendStub -Fixture $fixture
        Add-RosterAgent -Fixture $fixture -Id 'agent-lane-1' -Title 'lane'
        # hand-written roster: capture would have filtered these out already
        Add-RosterAgent -Fixture $fixture -Id 'agent-merge-1' -Title 'merge-cl-common-1dq'
        $agentList = Save-RosterAgentList -Fixture $fixture
        @{
            runId  = 'run-r1'; from = 'GO1'; to = 'GO2'; source = 'fixture'; capturedAt = (Get-Date).ToString('o')
            agents = @(
                [ordered]@{ id = 'agent-lane-1'; title = 'lane'; cwd = $fixture.Dir; status = 'running'; hasDoneFile = $false; isHub = $false; labels = @{} }
                [ordered]@{ id = 'agent-merge-1'; title = 'merge-cl-common-1dq'; cwd = $fixture.Dir; status = 'running'; hasDoneFile = $false; isHub = $false; labels = @{} }
                [ordered]@{ id = 'agent-self'; title = 'self lane'; cwd = $fixture.Dir; status = 'running'; hasDoneFile = $false; isHub = $false; labels = @{} }
            )
        } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $fixture.RosterPath

        $run = New-RosterRun -Fixture $fixture -Options @{ SelfAgentId = 'agent-self'; SkipCapture = $true }

        $run.ExitCode | Should -Be 0 -Because $run.Output
        @($run.Sends | ForEach-Object { $_.agentId }) | Should -Be @('agent-lane-1')
        (@($run.Audit | Where-Object { $_.agentId -eq 'agent-merge-1' })[0]).decision | Should -Be 'skipped-self'
        (@($run.Audit | Where-Object { $_.agentId -eq 'agent-self' })[0]).decision | Should -Be 'skipped-self'
    }

    It 'is idempotent per runId+agentId: the second pass sends nothing' {
        $fixture = New-RosterFixture -Root $TestDrive
        $null = New-RosterSendStub -Fixture $fixture
        Add-RosterAgent -Fixture $fixture -Id 'agent-lane-1'

        $first = New-RosterRun -Fixture $fixture
        $second = New-RosterRun -Fixture $fixture

        $first.Sends.Count | Should -Be 1
        $second.Sends.Count | Should -Be 1 -Because 'the second pass must not send again'
        $resumeLines = @($second.Audit | Where-Object { $_.kind -eq 'roster-resume' -and $_.agentId -eq 'agent-lane-1' })
        $resumeLines.Count | Should -Be 2
        $resumeLines[-1].decision | Should -Be 'skipped-already-nudged'
        @($resumeLines | Where-Object { $_.decision -eq 'resumed' }).Count | Should -Be 1
    }

    It 'skips an agent that no longer exists' {
        $fixture = New-RosterFixture -Root $TestDrive
        $null = New-RosterSendStub -Fixture $fixture
        Add-RosterAgent -Fixture $fixture -Id 'agent-gone'
        Add-RosterAgent -Fixture $fixture -Id 'agent-here'
        # roster captured while both existed
        $agentList = Save-RosterAgentList -Fixture $fixture
        $null = & $script:PwshExe -NoProfile -File $script:CapturePath -RunId 'run-r1' `
            -FromKeyNumber 1 -ToKeyNumber 2 -OutPath $fixture.RosterPath `
            -AgentListFile $agentList -AgentsDir $fixture.AgentsDir 2>&1
        # only one is still live
        $fixture.Rows.RemoveAt(0)
        $agentList = Save-RosterAgentList -Fixture $fixture

        $run = New-RosterRun -Fixture $fixture -Options @{ SkipCapture = $true }

        $run.ExitCode | Should -Be 0 -Because $run.Output
        @($run.Sends | ForEach-Object { $_.agentId }) | Should -Be @('agent-here')
        (@($run.Audit | Where-Object { $_.agentId -eq 'agent-gone' })[0]).decision | Should -Be 'skipped-missing'
    }

    It 'stops at the cap and names the agents it left alone' {
        $fixture = New-RosterFixture -Root $TestDrive
        $null = New-RosterSendStub -Fixture $fixture
        Add-RosterAgent -Fixture $fixture -Id 'agent-one'
        Add-RosterAgent -Fixture $fixture -Id 'agent-two'

        $run = New-RosterRun -Fixture $fixture -Options @{ MaxAgents = 1 }

        $run.ExitCode | Should -Be 0 -Because $run.Output
        @($run.Sends | ForEach-Object { $_.agentId }) | Should -Be @('agent-one')
        (@($run.Audit | Where-Object { $_.agentId -eq 'agent-two' })[0]).decision | Should -Be 'skipped-over-cap'
    }

    It 'logs decisions without sending under -LogOnly, and a later real pass still sends' {
        $fixture = New-RosterFixture -Root $TestDrive
        $null = New-RosterSendStub -Fixture $fixture
        Add-RosterAgent -Fixture $fixture -Id 'agent-lane-1'

        $logOnly = New-RosterRun -Fixture $fixture -Options @{ LogOnly = $true }
        $real = New-RosterRun -Fixture $fixture

        $logOnly.ExitCode | Should -Be 0 -Because $logOnly.Output
        $logOnly.Sends.Count | Should -Be 0
        (@($logOnly.Audit | Where-Object { $_.kind -eq 'roster-resume' -and $_.agentId -eq 'agent-lane-1' })[0]).decision | Should -Be 'resumed'
        $real.Sends.Count | Should -Be 1 -Because 'a log-only decision must not consume the idempotency slot'
    }

    It 'writes nothing at all under -DryRun' {
        $fixture = New-RosterFixture -Root $TestDrive
        $null = New-RosterSendStub -Fixture $fixture
        Add-RosterAgent -Fixture $fixture -Id 'agent-lane-1'

        $run = New-RosterRun -Fixture $fixture -Options @{ DryRun = $true }

        $run.ExitCode | Should -Be 0 -Because $run.Output
        $run.Sends.Count | Should -Be 0
        Test-Path -LiteralPath $fixture.AuditPath | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $fixture.StateDir 'last-cutover.json') | Should -BeFalse
    }

    It 'leaves a durable last-cutover.json so a late Hub can discover the cutover' {
        $fixture = New-RosterFixture -Root $TestDrive
        $null = New-RosterSendStub -Fixture $fixture
        Add-RosterAgent -Fixture $fixture -Id 'agent-hub-1' -Labels @{ 'hub-common' = 'cl-common' }

        $run = New-RosterRun -Fixture $fixture

        $run.ExitCode | Should -Be 0 -Because $run.Output
        $markerPath = Join-Path $fixture.StateDir 'last-cutover.json'
        Test-Path -LiteralPath $markerPath | Should -BeTrue
        $marker = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
        $marker.runId | Should -Be 'run-r1'
        $marker.from | Should -Be 'GO1'
        $marker.to | Should -Be 'GO2'
        $marker.rosterPath | Should -Be (Resolve-Path -LiteralPath $fixture.RosterPath).Path
        $marker.at | Should -Not -BeNullOrEmpty
        $marker.PSObject.Properties.Name | Should -Contain 'witnessPath'
        $marker.PSObject.Properties.Name | Should -Contain 'verdict'
    }

    It 'fails honestly when the roster is missing' {
        $fixture = New-RosterFixture -Root $TestDrive
        $output = & $script:PwshExe -NoProfile -File $script:ResumePath `
            -RosterPath (Join-Path $fixture.Dir 'nope.json') -StateDir $fixture.StateDir `
            -AuditPath $fixture.AuditPath 2>&1 | Out-String

        $LASTEXITCODE | Should -Be 1
        $output | Should -Match 'roster-resume-failed'
        $rows = Get-RosterAuditRows -Fixture $fixture
        (@($rows | Where-Object { $_.kind -eq 'roster-resume-failed' })).Count | Should -Be 1
    }
}
