#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0.0' }

<#
.SYNOPSIS
    Pester tests for Invoke-KeyCheckCutover.ps1 - the cutover helper.

.DESCRIPTION
    The helper exists because the cutover restarts Paseo, which kills whatever
    Paseo-hosted process performs it. Key Check therefore delegates the cutover
    to this helper, created outside its own process tree, and reads the outcome
    file it writes.

    The contract under test:

      - the Salmon switch runs FIRST, then the Paseo repair, never in parallel;
      - a failed switch stops the sequence before the repair runs;
      - a switch whose own surfaces disagree is refused before the repair (4);
      - a pending outcome is on disk BEFORE the repair, so a killed helper
        leaves evidence instead of silence;
      - the outcome is `verified` only when all three surfaces agree
        (seam activeKey, User OPENCODE_GO_KEY, Paseo config pin);
      - a spawn/step failure is `applied=false` (cutover failed), never
        `verified` and never a silent success;
      - no key value ever appears in the outcome JSON or the console output.

    Every script here is a fixture: no test touches a real credential, a real
    cutover, or a real Paseo restart.
#>

BeforeAll {
    $script:SkillRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
    $script:HelperPath = Join-Path $script:SkillRoot 'scripts\Invoke-KeyCheckCutover.ps1'
    $script:PwshExe = Join-Path $PSHOME 'pwsh.exe'

    function New-CutoverFixture {
        param(
            [string]$SeamActiveKey = 'OPENCODE_GO2_KEY',
            [int]$SwitchExit = 0,
            [int]$RepairExit = 0,
            [switch]$SwitchMissing
        )
        $dir = Join-Path $TestDrive ("kc-cutover-{0}" -f ([guid]::NewGuid().ToString('N')))
        $null = New-Item -ItemType Directory -Path $dir -Force

        $seamPath = Join-Path $dir 'seam.json'
        @{ activeKey = $SeamActiveKey; updated = '2026-11-02' } | ConvertTo-Json | Set-Content -LiteralPath $seamPath

        $keysPath = Join-Path $dir 'keys.json'
        @{
            inUse = 'cutover-value-bravo'
            keys  = @{ GO1 = 'cutover-value-alpha'; GO2 = 'cutover-value-bravo' }
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $keysPath

        $paseoConfig = Join-Path $dir 'paseo-config.json'
        @{
            agents = @{
                providers = @{
                    opencode = @{ env = @{ OPENCODE_GO_KEY = 'cutover-value-bravo'; OPENCODE_API_KEY = 'cutover-value-bravo' } }
                }
            }
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $paseoConfig

        $logPath = Join-Path $dir 'steps.log'
        New-Item -ItemType File -Path $logPath -Force | Out-Null

        $switchPath = Join-Path $dir 'switch-stub.ps1'
        @"
param([int]`$KeyNumber = 0)
Add-Content -LiteralPath '$logPath' -Value "switch GO`$KeyNumber"
exit $SwitchExit
"@ | Set-Content -LiteralPath $switchPath

        $repairPath = Join-Path $dir 'repair-stub.ps1'
        @"
param([int]`$KeyNumber = 0)
Add-Content -LiteralPath '$logPath' -Value "repair GO`$KeyNumber"
exit $RepairExit
"@ | Set-Content -LiteralPath $repairPath

        if ($SwitchMissing) { $switchPath = Join-Path $dir 'no-such-switch.ps1' }

        [pscustomobject]@{
            Dir         = $dir
            SeamPath    = $seamPath
            KeysPath    = $keysPath
            PaseoConfig = $paseoConfig
            LogPath     = $logPath
            SwitchPath  = $switchPath
            RepairPath  = $repairPath
            MarkerPath  = Join-Path $dir 'partial-cutover.json'
            OutcomePath = Join-Path $dir 'outcome.json'
        }
    }

    function Invoke-CutoverHelper {
        param($Fixture, [int]$KeyNumber = 2)
        $helperArgs = @(
            '-NoProfile', '-File', $script:HelperPath,
            '-KeyNumber', "$KeyNumber",
            '-OutcomePath', $Fixture.OutcomePath,
            '-RunId', 'run-kc2',
            '-SwitchScript', $Fixture.SwitchPath,
            '-RepairScript', $Fixture.RepairPath,
            '-SeamPath', $Fixture.SeamPath,
            '-KeyValuesFile', $Fixture.KeysPath,
            '-PaseoConfig', $Fixture.PaseoConfig,
            '-PartialMarkerPath', $Fixture.MarkerPath,
            '-NoRoster',
            '-TimeoutSeconds', '60'
        )
        $output = & $script:PwshExe @helperArgs 2>&1 | Out-String
        $outcome = $null
        if (Test-Path -LiteralPath $Fixture.OutcomePath) {
            $outcome = Get-Content -LiteralPath $Fixture.OutcomePath -Raw | ConvertFrom-Json
        }
        $steps = @()
        if (Test-Path -LiteralPath $Fixture.LogPath) {
            $steps = @(Get-Content -LiteralPath $Fixture.LogPath | Where-Object { $_.Trim() })
        }
        [pscustomobject]@{
            ExitCode   = $LASTEXITCODE
            Output     = $output
            Outcome    = $outcome
            RawOutcome = if ($outcome) { Get-Content -LiteralPath $Fixture.OutcomePath -Raw } else { '' }
            Steps      = $steps
        }
    }

    function Get-Surface {
        param($Outcome, [string]$Name)
        return @($Outcome.surfaces | Where-Object { $_.name -eq $Name })[0]
    }
}

Describe 'Invoke-KeyCheckCutover' {

    It 'runs the Salmon switch before the Paseo repair and verifies all three surfaces' {
        $fixture = New-CutoverFixture

        $run = Invoke-CutoverHelper -Fixture $fixture

        $run.ExitCode | Should -Be 0 -Because $run.Output
        $run.Steps.Count | Should -Be 2
        $run.Steps[0] | Should -Be 'switch GO2'
        $run.Steps[1] | Should -Be 'repair GO2'

        $run.Outcome.applied | Should -BeTrue
        $run.Outcome.verified | Should -BeTrue
        $run.Outcome.keyNumber | Should -Be 2
        $run.Outcome.runId | Should -Be 'run-kc2'
        $run.Outcome.at | Should -Not -BeNullOrEmpty
        @($run.Outcome.steps).Count | Should -Be 2
        ($run.Outcome.steps | ForEach-Object { $_.name }) | Should -Be @('switch', 'repair')
        ($run.Outcome.steps | ForEach-Object { $_.exitCode }) | Should -Be @(0, 0)

        (Get-Surface -Outcome $run.Outcome -Name 'seam').ok | Should -BeTrue
        (Get-Surface -Outcome $run.Outcome -Name 'user-env').ok | Should -BeTrue
        (Get-Surface -Outcome $run.Outcome -Name 'paseo-pin').ok | Should -BeTrue
        (Get-Surface -Outcome $run.Outcome -Name 'paseo-pin').actual | Should -Be 'GO2'
    }

    It 'stops before the repair when the switch fails, and reports cutover-failed' {
        $fixture = New-CutoverFixture -SwitchExit 1

        $run = Invoke-CutoverHelper -Fixture $fixture

        $run.ExitCode | Should -Be 4 -Because $run.Output
        $run.Steps.Count | Should -Be 1
        $run.Steps[0] | Should -Be 'switch GO2'
        $run.Outcome.applied | Should -BeFalse
        $run.Outcome.verified | Should -BeFalse
        ($run.Outcome.steps | Where-Object { $_.name -eq 'switch' }).exitCode | Should -Be 1
        @($run.Outcome.steps | Where-Object { $_.name -eq 'repair' }).Count | Should -Be 0
    }

    It 'refuses to repair when the switch left its own surfaces disagreeing (4, nothing moved)' {
        # The seam is the switch's OWN surface. If it did not move, nothing
        # usable moved: repairing on top of that only split-brains the machine.
        $fixture = New-CutoverFixture -SeamActiveKey 'OPENCODE_GO1_KEY'

        $run = Invoke-CutoverHelper -Fixture $fixture

        $run.ExitCode | Should -Be 4 -Because $run.Output
        $run.Steps.Count | Should -Be 1
        $run.Steps[0] | Should -Be 'switch GO2'
        $run.Outcome.applied | Should -BeFalse
        $run.Outcome.verified | Should -BeFalse
        $run.Outcome.restartPending | Should -BeFalse
        $run.Outcome.reason | Should -Be 'surface-disagrees'
        $seam = Get-Surface -Outcome $run.Outcome -Name 'seam'
        $seam.ok | Should -BeFalse
        $seam.expected | Should -Be 'OPENCODE_GO2_KEY'
        $seam.actual | Should -Be 'OPENCODE_GO1_KEY'
        (Get-Surface -Outcome $run.Outcome -Name 'user-env').ok | Should -BeTrue
        @($run.Outcome.surfaces | Where-Object { $_.name -eq 'paseo-pin' }).Count | Should -Be 0
    }

    It 'reports applied-but-unproven when the Paseo pin still names another key (5)' {
        $fixture = New-CutoverFixture
        # seam + User moved, but the repair left the provider pin on GO1.
        @{
            agents = @{ providers = @{ opencode = @{ env = @{ OPENCODE_GO_KEY = 'cutover-value-alpha' } } } }
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $fixture.PaseoConfig

        $run = Invoke-CutoverHelper -Fixture $fixture

        $run.ExitCode | Should -Be 5 -Because $run.Output
        $run.Outcome.applied | Should -BeTrue
        $run.Outcome.verified | Should -BeFalse
        $run.Outcome.restartPending | Should -BeFalse
        (Get-Surface -Outcome $run.Outcome -Name 'seam').ok | Should -BeTrue
        (Get-Surface -Outcome $run.Outcome -Name 'user-env').ok | Should -BeTrue
        $pin = Get-Surface -Outcome $run.Outcome -Name 'paseo-pin'
        $pin.ok | Should -BeFalse
        $pin.actual | Should -Be 'GO1'
    }

    It 'reports cutover-failed (not unproven) when a step script cannot be spawned' {
        $fixture = New-CutoverFixture -SwitchMissing

        $run = Invoke-CutoverHelper -Fixture $fixture

        $run.ExitCode | Should -Be 4 -Because $run.Output
        $run.Outcome.applied | Should -BeFalse
        $run.Outcome.verified | Should -BeFalse
        $run.Steps.Count | Should -Be 0
    }

    It 'never prints or stores a key value, only the key number' {
        $fixture = New-CutoverFixture

        $run = Invoke-CutoverHelper -Fixture $fixture

        $run.ExitCode | Should -Be 0 -Because $run.Output
        $run.Output | Should -Not -Match 'cutover-value-alpha'
        $run.Output | Should -Not -Match 'cutover-value-bravo'
        $run.RawOutcome | Should -Not -Match 'cutover-value-alpha'
        $run.RawOutcome | Should -Not -Match 'cutover-value-bravo'
        $run.RawOutcome | Should -Match 'GO2'
    }

    It 'writes the pending outcome BEFORE the restart, then rewrites it verified' {
        # The restart can kill this helper. The evidence must already be on disk,
        # or a killed helper looks exactly like "nothing happened".
        $fixture = New-CutoverFixture
        $snapshot = Join-Path $fixture.Dir 'outcome-at-repair.json'
        @"
param([int]`$KeyNumber = 0)
Copy-Item -LiteralPath '$($fixture.OutcomePath)' -Destination '$snapshot' -Force -ErrorAction SilentlyContinue
Add-Content -LiteralPath '$($fixture.LogPath)' -Value "repair GO`$KeyNumber"
exit 0
"@ | Set-Content -LiteralPath $fixture.RepairPath

        $run = Invoke-CutoverHelper -Fixture $fixture

        $run.ExitCode | Should -Be 0 -Because $run.Output
        $run.Steps.Count | Should -Be 2
        $run.Steps[1] | Should -Be 'repair GO2'

        # what was on disk while the destructive step ran
        Test-Path -LiteralPath $snapshot | Should -BeTrue -Because 'the outcome must exist before the restart'
        $pending = Get-Content -LiteralPath $snapshot -Raw | ConvertFrom-Json
        $pending.applied | Should -BeTrue
        $pending.verified | Should -Be 'pending'
        $pending.restartPending | Should -BeTrue
        $pending.reason | Should -Be 'restart-pending'
        ($pending.surfaces | ForEach-Object { $_.name }) | Should -Be @('seam', 'user-env')

        # and what is on disk afterwards
        $run.Outcome.verified | Should -BeTrue
        $run.Outcome.restartPending | Should -BeFalse
        $run.Outcome.reason | Should -Be 'verified'
        ($run.Outcome.surfaces | ForEach-Object { $_.name }) | Should -Be @('seam', 'user-env', 'paseo-pin')
    }

    It 'leaves a pending outcome behind when the restart kills the helper' {
        # Simulated kill: the repair step ends the helper's own process. The
        # pending file must survive as the only evidence, with no 'verified'.
        $fixture = New-CutoverFixture
        @"
param([int]`$KeyNumber = 0)
Add-Content -LiteralPath '$($fixture.LogPath)' -Value "repair GO`$KeyNumber"
`$parentPid = (Get-CimInstance Win32_Process -Filter "ProcessId=`$PID").ParentProcessId
Stop-Process -Id `$parentPid -Force -ErrorAction SilentlyContinue
exit 0
"@ | Set-Content -LiteralPath $fixture.RepairPath

        $run = Invoke-CutoverHelper -Fixture $fixture

        $run.ExitCode | Should -Not -Be 0
        $run.Outcome.applied | Should -BeTrue
        $run.Outcome.verified | Should -Be 'pending'
        $run.Outcome.restartPending | Should -BeTrue
        $run.Steps | Should -Be @('switch GO2', 'repair GO2')
    }
}

Describe 'Invoke-KeyCheckCutover partial-cutover marker' {
    # A partial cutover means the switch wrote some surfaces and its rollback
    # failed. A fresh switch on top of that split-brains the machine, so the
    # helper resolves the recorded cutover first and reads the decision off the
    # switch's exit code: 0 completed, 1 reverted, 6 still split.

    It 'completes the recorded partial cutover before any fresh switch' {
        $fixture = New-CutoverFixture
        @{
            from = 'GO1'; to = 'GO2'; surfaces = @('seam', 'user-env', 'auth.json', 'salmon-config')
            at = '2026-11-02T00:00:00Z'; runId = 'run-prev'
        } | ConvertTo-Json | Set-Content -LiteralPath $fixture.MarkerPath
        @"
param([int]`$KeyNumber = 0, [switch]`$ResumePartial)
Add-Content -LiteralPath '$($fixture.LogPath)' -Value "resume GO`$KeyNumber"
Remove-Item -LiteralPath '$($fixture.MarkerPath)' -Force -ErrorAction SilentlyContinue
exit 0
"@ | Set-Content -LiteralPath $fixture.SwitchPath

        $run = Invoke-CutoverHelper -Fixture $fixture

        $run.ExitCode | Should -Be 0 -Because $run.Output
        $run.Steps | Should -Be @('resume GO2', 'repair GO2')
        $run.Output | Should -Match 'partial-cutover marker found'
        $run.Outcome.applied | Should -BeTrue
        $run.Outcome.verified | Should -BeTrue
    }

    It 'reports nothing moved when the recorded partial cutover was reverted' {
        $fixture = New-CutoverFixture
        @{ from = 'GO1'; to = 'GO1'; surfaces = @('seam'); at = '2026-11-02T00:00:00Z'; runId = 'run-prev' } |
            ConvertTo-Json | Set-Content -LiteralPath $fixture.MarkerPath
        @"
param([int]`$KeyNumber = 0, [switch]`$ResumePartial)
Add-Content -LiteralPath '$($fixture.LogPath)' -Value "resume GO`$KeyNumber"
Remove-Item -LiteralPath '$($fixture.MarkerPath)' -Force -ErrorAction SilentlyContinue
exit 1
"@ | Set-Content -LiteralPath $fixture.SwitchPath

        $run = Invoke-CutoverHelper -Fixture $fixture

        $run.ExitCode | Should -Be 4 -Because $run.Output
        $run.Steps | Should -Be @('resume GO2')
        $run.Outcome.applied | Should -BeFalse
        $run.Outcome.verified | Should -BeFalse
        $run.Outcome.reason | Should -Be 'partial-reverted'
    }

    It 'reports applied-but-unproven (5) while the partial cutover is still unresolved' {
        $fixture = New-CutoverFixture
        @{ from = 'GO1'; to = 'GO2'; surfaces = @('seam'); at = '2026-11-02T00:00:00Z'; runId = 'run-prev' } |
            ConvertTo-Json | Set-Content -LiteralPath $fixture.MarkerPath
        @"
param([int]`$KeyNumber = 0, [switch]`$ResumePartial)
Add-Content -LiteralPath '$($fixture.LogPath)' -Value "resume GO`$KeyNumber"
exit 6
"@ | Set-Content -LiteralPath $fixture.SwitchPath

        $run = Invoke-CutoverHelper -Fixture $fixture

        $run.ExitCode | Should -Be 5 -Because $run.Output
        $run.Steps | Should -Be @('resume GO2')
        $run.Outcome.applied | Should -BeTrue
        $run.Outcome.verified | Should -BeFalse
        $run.Outcome.reason | Should -Be 'partial-cutover'
        Test-Path -LiteralPath $fixture.MarkerPath | Should -BeTrue
    }

    It 'reports applied-but-unproven when a fresh switch leaves a partial marker' {
        $fixture = New-CutoverFixture
        @"
param([int]`$KeyNumber = 0)
Add-Content -LiteralPath '$($fixture.LogPath)' -Value "switch GO`$KeyNumber"
Set-Content -LiteralPath '$($fixture.MarkerPath)' -Value '{"from":"GO1","to":"GO2"}'
exit 6
"@ | Set-Content -LiteralPath $fixture.SwitchPath

        $run = Invoke-CutoverHelper -Fixture $fixture

        $run.ExitCode | Should -Be 5 -Because $run.Output
        $run.Steps | Should -Be @('switch GO2')
        $run.Outcome.applied | Should -BeTrue
        $run.Outcome.verified | Should -BeFalse
        $run.Outcome.reason | Should -Be 'partial-cutover'
    }
}
