#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0.0' }

<#
.SYNOPSIS
    Pester tests for the two cutover-recovery call sites.

.DESCRIPTION
    The nudge is sent by whichever process survives, so the roster capture and
    the resume/witness pair are wired at two places:

      - the detached helper: capture BEFORE anything destructive (so a helper
        killed by the restart still leaves a roster), then resume + witness
        after a proven cutover;
      - the Key Check resume path: if `last-cutover.json` is newer than this
        run's start and names a roster, recover BEFORE any further checks and
        log `cutover-recovery` with counts.

    A failure in any of the three companion steps is audited and never fails
    the cutover (exit codes 4/5 keep their meaning).
#>

BeforeAll {
    $script:SkillRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
    $script:CutoverPath = Join-Path $script:SkillRoot 'scripts\Invoke-KeyCheckCutover.ps1'
    $script:KeyCheckPath = Join-Path $script:SkillRoot 'scripts\Invoke-KeyCheck.ps1'
    $script:ResumePath = Join-Path $script:SkillRoot 'scripts\Resume-KeyCheckRoster.ps1'
    $script:CapturePath = Join-Path $script:SkillRoot 'scripts\Capture-KeyCheckRoster.ps1'
    $script:PwshExe = Join-Path $PSHOME 'pwsh.exe'
    . (Join-Path $PSScriptRoot 'fixtures\RosterTestKit.ps1')

    function New-WiringFixture {
        param([int]$RosterExit = 0, [int]$WitnessExit = 0)
        $dir = Join-Path $TestDrive ("kc-wiring-{0}" -f ([guid]::NewGuid().ToString('N')))
        $null = New-Item -ItemType Directory -Path $dir -Force

        $seamPath = Join-Path $dir 'seam.json'
        @{ activeKey = 'OPENCODE_GO2_KEY' } | ConvertTo-Json | Set-Content -LiteralPath $seamPath
        $keysPath = Join-Path $dir 'keys.json'
        @{ inUse = 'wire-value-bravo'; keys = @{ GO1 = 'wire-value-alpha'; GO2 = 'wire-value-bravo' } } |
            ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $keysPath
        $paseoConfig = Join-Path $dir 'paseo-config.json'
        @{ agents = @{ providers = @{ opencode = @{ env = @{ OPENCODE_GO_KEY = 'wire-value-bravo' } } } } } |
            ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $paseoConfig

        $logPath = Join-Path $dir 'steps.log'
        New-Item -ItemType File -Path $logPath -Force | Out-Null

        $switchPath = Join-Path $dir 'switch-stub.ps1'
        "param([int]`$KeyNumber = 0, [switch]`$ResumePartial)`nAdd-Content -LiteralPath '$logPath' -Value 'switch'`nexit 0" |
            Set-Content -LiteralPath $switchPath
        $repairPath = Join-Path $dir 'repair-stub.ps1'
        "param([int]`$KeyNumber = 0)`nAdd-Content -LiteralPath '$logPath' -Value 'repair'`nexit 0" |
            Set-Content -LiteralPath $repairPath

        $rosterStub = Join-Path $dir 'roster-stub.ps1'
        @"
param([string]`$RunId = '', [int]`$FromKeyNumber = 0, [int]`$ToKeyNumber = 0, [string]`$OutPath = '')
Add-Content -LiteralPath '$logPath' -Value 'roster'
New-Item -ItemType Directory -Path (Split-Path -Parent `$OutPath) -Force | Out-Null
@{ runId = `$RunId; from = "GO`$FromKeyNumber"; to = "GO`$ToKeyNumber"; at = (Get-Date).ToString('o'); agents = @() } |
    ConvertTo-Json -Depth 5 | Set-Content -LiteralPath `$OutPath
exit $RosterExit
"@ | Set-Content -LiteralPath $rosterStub

        $resumeStub = Join-Path $dir 'resume-stub.ps1'
        @"
param([string]`$RosterPath = '', [string]`$StateDir = '', [string]`$AuditPath = '')
Add-Content -LiteralPath '$logPath' -Value 'resume'
@{ runId = 'run-x'; counts = @{ resumed = 0; hubsNudged = 0; lanesNudged = 0; skippedFinished = 0; skippedAlready = 0 } } |
    ConvertTo-Json -Depth 5
exit 0
"@ | Set-Content -LiteralPath $resumeStub

        $witnessStub = Join-Path $dir 'witness-stub.ps1'
        @"
param([string]`$RunId = '', [string]`$OutcomePath = '', [string]`$StateDir = '', [string]`$AuditPath = '')
Add-Content -LiteralPath '$logPath' -Value 'witness'
New-Item -ItemType Directory -Path `$StateDir -Force | Out-Null
@{ runId = `$RunId; verdict = 'verified-by-helper'; at = (Get-Date).ToString('o') } |
    ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path `$StateDir "witness-`$RunId.json")
exit $WitnessExit
"@ | Set-Content -LiteralPath $witnessStub

        [pscustomobject]@{
            Dir         = $dir
            SeamPath    = $seamPath
            KeysPath    = $keysPath
            PaseoConfig = $paseoConfig
            LogPath     = $logPath
            SwitchPath  = $switchPath
            RepairPath  = $repairPath
            RosterStub  = $rosterStub
            ResumeStub  = $resumeStub
            WitnessStub = $witnessStub
            MarkerPath  = Join-Path $dir 'partial.json'
            OutcomePath = Join-Path $dir 'outcome.json'
            RosterPath  = Join-Path $dir 'roster.json'
            AuditPath   = Join-Path $dir 'keycheck.jsonl'
        }
    }

    function Invoke-WiringCutover {
        param($Fixture, [switch]$NoRoster)
        $args = @(
            '-NoProfile', '-File', $script:CutoverPath, '-KeyNumber', '2',
            '-OutcomePath', $Fixture.OutcomePath, '-RunId', 'run-x',
            '-SwitchScript', $Fixture.SwitchPath, '-RepairScript', $Fixture.RepairPath,
            '-SeamPath', $Fixture.SeamPath, '-KeyValuesFile', $Fixture.KeysPath,
            '-PaseoConfig', $Fixture.PaseoConfig, '-PartialMarkerPath', $Fixture.MarkerPath,
            '-RosterScript', $Fixture.RosterStub, '-ResumeScript', $Fixture.ResumeStub,
            '-WitnessScript', $Fixture.WitnessStub, '-RosterPath', $Fixture.RosterPath,
            '-AuditPath', $Fixture.AuditPath, '-TimeoutSeconds', '60'
        )
        if ($NoRoster) { $args += '-NoRoster' }
        $output = & $script:PwshExe @args 2>&1 | Out-String
        $outcome = $null
        if (Test-Path -LiteralPath $Fixture.OutcomePath) {
            $outcome = Get-Content -LiteralPath $Fixture.OutcomePath -Raw | ConvertFrom-Json
        }
        [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Output   = $output
            Outcome  = $outcome
            Steps    = @(Get-Content -LiteralPath $Fixture.LogPath | Where-Object { $_.Trim() })
            Audit    = @(if (Test-Path -LiteralPath $Fixture.AuditPath) {
                    Get-Content -LiteralPath $Fixture.AuditPath | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json }
                })
        }
    }
}

Describe 'Cutover helper roster wiring' {

    It 'captures the roster before the switch and runs resume + witness after a proven cutover' {
        $fixture = New-WiringFixture

        $run = Invoke-WiringCutover -Fixture $fixture

        $run.ExitCode | Should -Be 0 -Because $run.Output
        $run.Steps | Should -Be @('roster', 'switch', 'repair', 'resume', 'witness')
        $run.Outcome.verified | Should -BeTrue
        $run.Outcome.rosterPath | Should -Be $fixture.RosterPath
        $run.Outcome.witnessVerdict | Should -Be 'verified-by-helper'
        $run.Outcome.witnessPath | Should -Be (Join-Path $fixture.Dir 'witness-run-x.json')
    }

    It 'records the roster in the pending outcome, before the restart' {
        $fixture = New-WiringFixture
        $snapshot = Join-Path $fixture.Dir 'outcome-at-repair.json'
        "param([int]`$KeyNumber = 0)`nCopy-Item -LiteralPath '$($fixture.OutcomePath)' -Destination '$snapshot' -Force -ErrorAction SilentlyContinue`nAdd-Content -LiteralPath '$($fixture.LogPath)' -Value 'repair'`nexit 0" |
            Set-Content -LiteralPath $fixture.RepairPath

        $run = Invoke-WiringCutover -Fixture $fixture

        $run.ExitCode | Should -Be 0 -Because $run.Output
        Test-Path -LiteralPath $snapshot | Should -BeTrue
        $pending = Get-Content -LiteralPath $snapshot -Raw | ConvertFrom-Json
        $pending.verified | Should -Be 'pending'
        $pending.rosterPath | Should -Be $fixture.RosterPath
    }

    It 'audits a roster-capture failure and still completes the cutover' {
        $fixture = New-WiringFixture -RosterExit 1

        $run = Invoke-WiringCutover -Fixture $fixture

        $run.ExitCode | Should -Be 0 -Because $run.Output
        $run.Outcome.verified | Should -BeTrue
        $run.Outcome.rosterPath | Should -BeNullOrEmpty
        @($run.Audit | Where-Object { $_.kind -eq 'roster-capture-failed' }).Count | Should -Be 1
        $run.Steps | Should -Not -Contain 'resume'
    }

    It 'audits a witness failure and still completes the cutover' {
        $fixture = New-WiringFixture -WitnessExit 7

        $run = Invoke-WiringCutover -Fixture $fixture

        $run.ExitCode | Should -Be 0 -Because $run.Output
        $run.Outcome.verified | Should -BeTrue
        @($run.Audit | Where-Object { $_.kind -eq 'witness-failed' }).Count | Should -Be 1
    }

    It 'does no roster work at all under -NoRoster' {
        $fixture = New-WiringFixture

        $run = Invoke-WiringCutover -Fixture $fixture -NoRoster

        $run.ExitCode | Should -Be 0 -Because $run.Output
        $run.Steps | Should -Be @('switch', 'repair')
        Test-Path -LiteralPath $fixture.AuditPath | Should -BeFalse
    }
}

Describe 'Key Check resume-path recovery' {
    BeforeAll {
        function New-RecoveryFixture {
            param([switch]$DaemonDead)
            $dir = Join-Path $TestDrive ("kc-recovery-{0}" -f ([guid]::NewGuid().ToString('N')))
            $null = New-Item -ItemType Directory -Path $dir -Force
            $keysPath = Join-Path $dir 'keys.json'
            @{ inUse = 'rec-value-1'; keys = @{ GO1 = 'rec-value-1'; GO3 = 'rec-value-3' } } |
                ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $keysPath
            $usagePath = Join-Path $dir 'usage.json'
            @{
                GO1 = @{ weekly = @{ percent = 10; status = 'ok'; resetsAt = '2026-11-09T00:00' }
                    monthly = @{ percent = 20; status = 'ok'; resetsAt = '2026-11-20' }
                }
            } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $usagePath
            $seamPath = Join-Path $dir 'seam.json'
            @{ activeKey = 'OPENCODE_GO1_KEY' } | ConvertTo-Json | Set-Content -LiteralPath $seamPath
            $paseoConfig = Join-Path $dir 'paseo-config.json'
            @{ agents = @{ providers = @{ opencode = @{ env = @{ OPENCODE_GO_KEY = 'rec-value-1' } } } } } |
                ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $paseoConfig

            [pscustomobject]@{
                Dir         = $dir
                KeysPath    = $keysPath
                UsagePath   = $usagePath
                SeamPath    = $seamPath
                PaseoConfig = $paseoConfig
                StatePath   = Join-Path $dir 'state.json'
                AuditPath   = Join-Path $dir 'keycheck.jsonl'
                MarkerPath  = Join-Path $dir 'last-cutover.json'
                RosterPath  = Join-Path $dir 'run-old-roster.json'
            }
        }

        function New-RecoveryState {
            param($Fixture, [datetime]$StartedAt)
            [ordered]@{
                runId = '20260101-090000'
                startedAt = $StartedAt.ToString('o')
                deadline = $StartedAt.AddMinutes(30).ToString('o')
                deadlineAt = $StartedAt.AddMinutes(30).ToString('o')
                intervalMinutes = 1; durationHours = 0.5
                phase = 'heartbeat'; activeKeyNumber = 1
                replacementKeyNumber = 0; replacementKey = 0; simulatedActiveKeyNumber = 0
                generation = 0; checks = 1; lastReading = $null
                lastCheckAt = $StartedAt.AddMinutes(1).ToString('o'); lastResult = 'heartbeat (watching)'
                consecutiveRateLimited = 0; consecutiveCannotEvaluate = 0; consecutiveBelowThreshold = 0
                armed = $false; evidence = @(); dryRun = $false; cutovers = @()
                drift = $null; canary = $null; usageSource = 'fixture'
                endedAt = $null; endReason = ''; exitCode = 0
            } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Fixture.StatePath
        }

        function New-RecoveryWitnessStub {
            <#
            .SYNOPSIS
                A witness stand-in: writes the witness file the caller reads, so
                the recovery test never reads this machine's credentials.
            #>
            param([string]$Dir)
            $path = Join-Path $Dir 'witness-stub.ps1'
            @"
param([string]`$RunId = '', [string]`$OutcomePath = '', [string]`$StateDir = '', [string]`$AuditPath = '')
New-Item -ItemType Directory -Path `$StateDir -Force | Out-Null
@{ runId = `$RunId; verdict = 'verified-by-helper'; at = (Get-Date).ToString('o') } |
    ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path `$StateDir "witness-`$RunId.json")
exit 0
"@ | Set-Content -LiteralPath $path
            return $path
        }

        function Invoke-RecoveryKeyCheck {
            param($Fixture, [string[]]$ExtraArgs = @())            $args = @(
                '-NoProfile', '-File', $script:KeyCheckPath,
                '-UsageFile', $Fixture.UsagePath, '-KeyValuesFile', $Fixture.KeysPath,
                '-StatePath', $Fixture.StatePath, '-AuditPath', $Fixture.AuditPath,
                '-SeamPath', $Fixture.SeamPath, '-PaseoConfig', $Fixture.PaseoConfig,
                '-SkipDrift', '-SkipCanary', '-NoWait', '-MaxChecks', '1',
                '-IntervalMinutes', '1', '-DurationHours', '0.02'
            ) + $ExtraArgs
            $output = & $script:PwshExe @args 2>&1 | Out-String
            [pscustomobject]@{
                ExitCode = $LASTEXITCODE
                Output   = $output
                Audit    = @(if (Test-Path -LiteralPath $Fixture.AuditPath) {
                        Get-Content -LiteralPath $Fixture.AuditPath | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json }
                    })
            }
        }
    }

    It 'recovers from last-cutover.json newer than the run start, once, with counts' {
        $fixture = New-RecoveryFixture
        $startedAt = (Get-Date).AddMinutes(-20)
        New-RecoveryState -Fixture $fixture -StartedAt $startedAt

        # a real roster captured by the real capture script, and a send stub
        $kit = New-RosterFixture -Root $TestDrive
        $null = New-RosterSendStub -Fixture $kit
        Add-RosterAgent -Fixture $kit -Id 'agent-lane-1' -Labels @{ 'hub-common' = 'cl-common' }
        Add-RosterAgent -Fixture $kit -Id 'agent-lane-2'
        $agentList = Save-RosterAgentList -Fixture $kit
        $null = & $script:PwshExe -NoProfile -File $script:CapturePath -RunId '20260101-090000' `
            -FromKeyNumber 1 -ToKeyNumber 2 -OutPath $fixture.RosterPath `
            -AgentListFile $agentList -AgentsDir $kit.AgentsDir 2>&1

        @{
            runId = '20260101-090000'; at = (Get-Date).ToString('o'); from = 'GO1'; to = 'GO2'
            rosterPath = $fixture.RosterPath; witnessPath = ''; verdict = ''
        } | ConvertTo-Json | Set-Content -LiteralPath $fixture.MarkerPath

        $first = Invoke-RecoveryKeyCheck -Fixture $fixture -ExtraArgs @(
            '-ResumeScript', $script:ResumePath, '-SendScript', $kit.SendStub,
            '-AgentListFile', $agentList, '-AgentsDir', $kit.AgentsDir,
            '-WitnessScript', (New-RecoveryWitnessStub -Dir $fixture.Dir)
        )

        $first.ExitCode | Should -Be 0 -Because $first.Output
        $recovery = @($first.Audit | Where-Object { $_.kind -eq 'cutover-recovery' })
        $recovery.Count | Should -Be 1
        $recovery[0].reason | Should -Be 'cutover-marker'
        $recovery[0].hubsNudged | Should -Be 1
        $recovery[0].lanesNudged | Should -Be 1
        @(Get-RosterSendLog -Fixture $kit).Count | Should -Be 2
    }

    It 'does nothing when the marker is older than the run start' {
        $fixture = New-RecoveryFixture
        New-RecoveryState -Fixture $fixture -StartedAt (Get-Date).AddMinutes(-2)
        Set-Content -LiteralPath $fixture.RosterPath -Value '{"runId":"x","from":"GO1","to":"GO2","agents":[]}'
        @{
            runId = '20251231-000000'; at = (Get-Date).AddHours(-3).ToString('o'); from = 'GO1'; to = 'GO2'
            rosterPath = $fixture.RosterPath; witnessPath = ''; verdict = ''
        } | ConvertTo-Json | Set-Content -LiteralPath $fixture.MarkerPath

        $run = Invoke-RecoveryKeyCheck -Fixture $fixture

        $run.ExitCode | Should -Be 0 -Because $run.Output
        @($run.Audit | Where-Object { $_.kind -eq 'cutover-recovery' }).Count | Should -Be 0
    }

    It 'does nothing when the marker names a roster that is gone' {
        $fixture = New-RecoveryFixture
        New-RecoveryState -Fixture $fixture -StartedAt (Get-Date).AddMinutes(-20)
        @{
            runId = 'r'; at = (Get-Date).ToString('o'); from = 'GO1'; to = 'GO2'
            rosterPath = (Join-Path $fixture.Dir 'missing-roster.json'); witnessPath = ''; verdict = ''
        } | ConvertTo-Json | Set-Content -LiteralPath $fixture.MarkerPath

        $run = Invoke-RecoveryKeyCheck -Fixture $fixture

        $run.ExitCode | Should -Be 0 -Because $run.Output
        @($run.Audit | Where-Object { $_.kind -eq 'cutover-recovery' }).Count | Should -Be 0
    }
}
