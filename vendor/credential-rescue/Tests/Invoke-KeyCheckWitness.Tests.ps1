#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0.0' }

<#
.SYNOPSIS
    Pester tests for Invoke-KeyCheckWitness.ps1 - the shipped witness.

.DESCRIPTION
    The witness reports what is actually true after a cutover and derives ONE
    verdict. The contract:

      - verified-by-helper when the outcome says `verified: true`;
      - verified-by-witness only when the seam, User and Paseo pin labels all
        agree AND the daemon is alive;
      - applied-but-unproven / cutover-failed / no-evidence otherwise;
      - exit 0 only for the two verified verdicts;
      - a witness file plus one `cutover-witness` audit line;
      - the seam's `activeKey` is resolved to its VALUE and labelled by
        comparison. Labelling by stripping `_KEY` produced `OPENCODE_GO3`
        compared against `GO3` and a false `no-evidence` on a verified machine:
        that regression is pinned here.
#>

BeforeAll {
    $script:SkillRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
    $script:ScriptPath = Join-Path $script:SkillRoot 'scripts\Invoke-KeyCheckWitness.ps1'
    $script:PwshExe = Join-Path $PSHOME 'pwsh.exe'
    . (Join-Path $PSScriptRoot 'fixtures\RosterTestKit.ps1')

    function Invoke-Witness {
        param($Fixture, [string[]]$ExtraArgs = @())
        $args = @(
            '-NoProfile', '-File', $script:ScriptPath,
            '-RunId', 'run-w1',
            '-OutcomePath', $Fixture.OutcomePath,
            '-StateDir', $Fixture.StateDir,
            '-AuditPath', $Fixture.AuditPath,
            '-SeamPath', $Fixture.SeamPath,
            '-PaseoConfig', $Fixture.PaseoConfig,
            '-KeyValuesFile', $Fixture.KeysPath,
            '-DaemonPidFile', $Fixture.DaemonPid
        ) + $ExtraArgs
        $output = & $script:PwshExe @args 2>&1 | Out-String
        $report = $null
        if (Test-Path -LiteralPath $Fixture.WitnessPath) {
            $report = Get-Content -LiteralPath $Fixture.WitnessPath -Raw | ConvertFrom-Json
        }
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output; Report = $report }
    }
}

Describe 'Invoke-KeyCheckWitness' {

    It 'reports verified-by-helper when the outcome says verified' {
        $fixture = New-WitnessFixture -Root $TestDrive
        Set-WitnessOutcome -Fixture $fixture -Applied $true -Verified $true -Reason 'verified'

        $run = Invoke-Witness -Fixture $fixture

        $run.ExitCode | Should -Be 0 -Because $run.Output
        $run.Report.verdict | Should -Be 'verified-by-helper'
        $run.Report.outcome.present | Should -BeTrue
        $run.Report.outcome.applied | Should -BeTrue
        $run.Report.outcome.verified | Should -BeTrue
        $run.Report.outcome.reason | Should -Be 'verified'
    }

    It 'reports verified-by-witness when seam, User and pin labels all agree and the daemon is alive' {
        $fixture = New-WitnessFixture -Root $TestDrive

        $run = Invoke-Witness -Fixture $fixture

        $run.ExitCode | Should -Be 0 -Because $run.Output
        $run.Report.verdict | Should -Be 'verified-by-witness'
        $run.Report.outcome.present | Should -BeFalse
        $run.Report.surfaces.seam.label | Should -Be 'GO3'
        $run.Report.surfaces.user.label | Should -Be 'GO3'
        $run.Report.surfaces.pin.label | Should -Be 'GO3'
        $run.Report.daemonAlive | Should -BeTrue
        $run.Report.allAgree | Should -BeTrue
    }

    It 'compares GO labels to GO labels - the false no-evidence regression' {
        # The bug: the seam names `OPENCODE_GO3_KEY`, and the witness compared
        # `OPENCODE_GO3` (name minus `_KEY`) to `GO3` (value label). Every
        # verified machine read as no-evidence. The seam is resolved to its
        # VALUE and labelled, so both sides are GO3.
        $fixture = New-WitnessFixture -Root $TestDrive -SeamActiveKey 'OPENCODE_GO3_KEY'

        $run = Invoke-Witness -Fixture $fixture

        $run.Report.surfaces.seam.label | Should -BeExactly 'GO3'
        $run.Report.surfaces.seam.label | Should -Not -BeExactly 'OPENCODE_GO3'
        $run.Report.surfaces.seam.label | Should -BeExactly $run.Report.surfaces.user.label
        $run.Report.verdict | Should -Be 'verified-by-witness'
    }

    It 'reports applied-but-unproven when the surfaces disagree' {
        $fixture = New-WitnessFixture -Root $TestDrive -PinValue 'witness-value-alpha'
        Set-WitnessOutcome -Fixture $fixture -Applied $true -Verified $false -Reason 'surface-disagrees'

        $run = Invoke-Witness -Fixture $fixture

        $run.ExitCode | Should -Be 1 -Because $run.Output
        $run.Report.verdict | Should -Be 'applied-but-unproven'
        $run.Report.surfaces.pin.label | Should -Be 'GO1'
        $run.Report.allAgree | Should -BeFalse
    }

    It 'reports applied-but-unproven when a dead daemon is the only disagreement' {
        # The labels agree, so something moved; the daemon is gone, so the
        # machine cannot be proven. That is unproven, never "no evidence".
        $fixture = New-WitnessFixture -Root $TestDrive -DaemonDead

        $run = Invoke-Witness -Fixture $fixture

        $run.ExitCode | Should -Be 1 -Because $run.Output
        $run.Report.verdict | Should -Be 'applied-but-unproven'
        $run.Report.daemonAlive | Should -BeFalse
        $run.Report.allAgree | Should -BeTrue
    }

    It 'reports cutover-failed when the outcome applied=false' {
        $fixture = New-WitnessFixture -Root $TestDrive
        Set-WitnessOutcome -Fixture $fixture -Applied $false -Verified $false -Reason 'switch-failed'

        $run = Invoke-Witness -Fixture $fixture

        $run.ExitCode | Should -Be 1 -Because $run.Output
        $run.Report.verdict | Should -Be 'cutover-failed'
        $run.Report.outcome.reason | Should -Be 'switch-failed'
    }

    It 'reports no-evidence when there is no outcome and the surfaces disagree' {
        $fixture = New-WitnessFixture -Root $TestDrive -UserValue 'witness-value-alpha'

        $run = Invoke-Witness -Fixture $fixture

        $run.ExitCode | Should -Be 1 -Because $run.Output
        $run.Report.verdict | Should -Be 'no-evidence'
        $run.Report.outcome.present | Should -BeFalse
    }

    It 'writes one cutover-witness audit line and refreshes last-cutover.json' {
        $fixture = New-WitnessFixture -Root $TestDrive
        Set-WitnessOutcome -Fixture $fixture -Applied $true -Verified $true

        $run = Invoke-Witness -Fixture $fixture

        $run.ExitCode | Should -Be 0 -Because $run.Output
        $audit = @()
        if (Test-Path -LiteralPath $fixture.AuditPath) {
            $audit = @(Get-Content -LiteralPath $fixture.AuditPath | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
        }
        @($audit | Where-Object { $_.kind -eq 'cutover-witness' }).Count | Should -Be 1
        (@($audit | Where-Object { $_.kind -eq 'cutover-witness' })[0]).verdict | Should -Be 'verified-by-helper'

        Test-Path -LiteralPath $fixture.MarkerPath | Should -BeTrue
        $marker = Get-Content -LiteralPath $fixture.MarkerPath -Raw | ConvertFrom-Json
        $marker.runId | Should -Be 'run-w1'
        $marker.verdict | Should -Be 'verified-by-helper'
        $marker.witnessPath | Should -Be $fixture.WitnessPath
    }

    It 'never stores a key value' {
        $fixture = New-WitnessFixture -Root $TestDrive
        Set-WitnessOutcome -Fixture $fixture -Applied $true -Verified $true

        $run = Invoke-Witness -Fixture $fixture
        $raw = Get-Content -LiteralPath $fixture.WitnessPath -Raw

        $run.ExitCode | Should -Be 0 -Because $run.Output
        $raw | Should -Not -Match 'witness-value-'
        $run.Output | Should -Not -Match 'witness-value-'
        $raw | Should -Match 'GO3'
    }
}
