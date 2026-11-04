#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0.0' }

<#
.SYNOPSIS
    Pester tests for resuming a roster: the Hub role-restore block and the
    retry policy for an unacknowledged run cancellation.

.DESCRIPTION
    A cutover kills the persistent shells, so a resumed Hub's worktree lease
    (which records the shell pid) is dead and its Hub registry row can vanish.
    Restarting the Hub is not recovery; it has to be told, in copy-pasteable
    form, how to take the role back.

    The other half is the failure that stranded the UH Hub: `paseo send` failing
    with "active run cancellation was not acknowledged". One attempt must not
    turn into a silent omission - it is retried with backoff, then
    interrupt-then-prompt, and only then recorded as an unhandled gap.

    Fixtures only: no daemon, no credential.
#>

BeforeAll {
    $script:SkillRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
    $script:ResumePath = Join-Path $script:SkillRoot 'scripts\Resume-KeyCheckRoster.ps1'
    $script:PwshExe = Join-Path $PSHOME 'pwsh.exe'
    . (Join-Path $PSScriptRoot 'fixtures\RosterTestKit.ps1')

    function New-FlakySendStub {
        <#
        .SYNOPSIS
            A send seam that fails the first N calls, logging every attempt and
            every message, so retries are provable without a daemon.
        #>
        param($Fixture, [int]$FailCount = 0)
        $path = Join-Path $Fixture.Dir 'flaky-send-stub.ps1'
        $countFile = Join-Path $Fixture.Dir 'send-count.txt'
        @"
param([string]`$AgentId, [string]`$Variant, [string]`$MessageFile)
`$message = Get-Content -LiteralPath `$MessageFile -Raw
[ordered]@{ agentId = `$AgentId; variant = `$Variant; message = `$message } |
    ConvertTo-Json -Compress | Add-Content -LiteralPath '$($Fixture.SendLog)'
`$n = 0
if (Test-Path -LiteralPath '$countFile') { `$n = [int](Get-Content -LiteralPath '$countFile' -Raw) }
`$n++
Set-Content -LiteralPath '$countFile' -Value `$n
if (`$n -le $FailCount) {
    [Console]::Error.WriteLine('active run cancellation was not acknowledged')
    exit 1
}
exit 0
"@ | Set-Content -LiteralPath $path
        $Fixture.SendStub = $path
        return $path
    }

    function New-InterruptStub {
        param($Fixture)
        $path = Join-Path $Fixture.Dir 'interrupt-stub.ps1'
        $log = Join-Path $Fixture.Dir 'interrupts.jsonl'
        @"
param([string]`$AgentId)
[ordered]@{ agentId = `$AgentId } | ConvertTo-Json -Compress | Add-Content -LiteralPath '$log'
exit 0
"@ | Set-Content -LiteralPath $path
        return $path
    }

    function Invoke-ResumeRun {
        param($Fixture, [string[]]$ExtraArgs = @())
        $agentList = Save-RosterAgentList -Fixture $Fixture
        $resumeArgs = @(
            '-NoProfile', '-File', $script:ResumePath,
            '-RosterPath', $Fixture.RosterPath,
            '-StateDir', $Fixture.StateDir,
            '-AuditPath', $Fixture.AuditPath,
            '-AgentListFile', $agentList,
            '-SendScript', $Fixture.SendStub,
            '-RetryBackoffSeconds', '0,0,0'
        ) + $ExtraArgs
        $output = & $script:PwshExe @resumeArgs 2>&1 | Out-String
        [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Output   = $output
            Sends    = @(Get-RosterSendLog -Fixture $Fixture)
            Audit    = @(Get-RosterAuditRows -Fixture $Fixture)
        }
    }

    function New-CapturedRoster {
        param($Fixture)
        $agentList = Save-RosterAgentList -Fixture $Fixture
        $null = & $script:PwshExe -NoProfile -File (Join-Path $script:SkillRoot 'scripts\Capture-KeyCheckRoster.ps1') `
            -RunId 'run-r1' -FromKeyNumber 6 -ToKeyNumber 3 -OutPath $Fixture.RosterPath `
            -AgentListFile $agentList -AgentsDir $Fixture.AgentsDir 2>&1
        return $Fixture.RosterPath
    }
}

Describe 'Hub role-restore block' {

    It 'gives a Hub the three copy-pasteable role commands' {
        $fixture = New-RosterFixture -Root $TestDrive
        $repo = Join-Path $fixture.Dir 'cl-common'
        $null = New-Item -ItemType Directory -Path (Join-Path $repo '.git') -Force
        $null = New-RosterSendStub -Fixture $fixture
        Add-RosterAgent -Fixture $fixture -Id 'agent-hub-1' -Title 'Hub cl-common' -Cwd $repo `
            -Labels @{ 'hub-common' = 'cl-common' }
        $null = New-CapturedRoster -Fixture $fixture

        $run = Invoke-ResumeRun -Fixture $fixture

        $run.ExitCode | Should -Be 0 -Because $run.Output
        $run.Sends.Count | Should -Be 1
        $message = $run.Sends[0].message
        $message | Should -Match 'HubRegistry\.ps1'
        $message | Should -Match '-Mode Register'
        $message | Should -Match 'Invoke-WorktreeLease\.ps1'
        $message | Should -Match '-Mode Acquire'
        $message | Should -Match 'agent-hub-1'
        $message | Should -Match 'cl-common'
        # the label re-assert, and the dead-pid warning
        $message | Should -Match 'label'
        $message | Should -Match 'FRESH persistent shell|fresh persistent shell'
        $message | Should -Match 'pid'
    }

    It 'does not burden a lane with the Hub role block' {
        $fixture = New-RosterFixture -Root $TestDrive
        $null = New-RosterSendStub -Fixture $fixture
        Add-RosterAgent -Fixture $fixture -Id 'agent-lane-1'
        $null = New-CapturedRoster -Fixture $fixture

        $run = Invoke-ResumeRun -Fixture $fixture

        $run.ExitCode | Should -Be 0 -Because $run.Output
        $run.Sends[0].message | Should -Not -Match 'HubRegistry\.ps1'
    }
}

Describe 'unacknowledged cancellation retry' {

    It 'retries a failed send with backoff and succeeds on the third attempt' {
        $fixture = New-RosterFixture -Root $TestDrive
        $null = New-FlakySendStub -Fixture $fixture -FailCount 2
        Add-RosterAgent -Fixture $fixture -Id 'agent-lane-1'
        $null = New-CapturedRoster -Fixture $fixture

        $run = Invoke-ResumeRun -Fixture $fixture

        $run.ExitCode | Should -Be 0 -Because $run.Output
        $run.Sends.Count | Should -Be 3
        @($run.Audit | Where-Object { $_.kind -eq 'roster-resume-failed' }).Count | Should -Be 0
        (@($run.Audit | Where-Object { $_.kind -eq 'roster-resume' })[0]).decision | Should -Be 'resumed'
    }

    It 'falls back to interrupt-then-prompt and records one unhandled gap when every send fails' {
        $fixture = New-RosterFixture -Root $TestDrive
        $null = New-FlakySendStub -Fixture $fixture -FailCount 99
        $interrupt = New-InterruptStub -Fixture $fixture
        Add-RosterAgent -Fixture $fixture -Id 'agent-lane-1'
        $null = New-CapturedRoster -Fixture $fixture

        $run = Invoke-ResumeRun -Fixture $fixture -ExtraArgs @('-InterruptScript', $interrupt)

        $run.ExitCode | Should -Be 0 -Because $run.Output
        $run.Sends.Count | Should -Be 4 -Because 'three retries, then one interrupt-then-prompt'
        Test-Path -LiteralPath (Join-Path $fixture.Dir 'interrupts.jsonl') | Should -BeTrue
        $failed = @($run.Audit | Where-Object { $_.kind -eq 'roster-resume-failed' })
        $failed.Count | Should -Be 1
        $failed[0].unhandled | Should -BeTrue
        $failed[0].agentId | Should -Be 'agent-lane-1'
        $failed[0].reason | Should -Match 'cancellation'
    }
}
