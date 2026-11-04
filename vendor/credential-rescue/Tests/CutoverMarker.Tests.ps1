#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0.0' }

<#
.SYNOPSIS
    Pester tests for the cutover-in-progress marker and Test-CutoverInProgress.

.DESCRIPTION
    A cutover restarts Paseo. A backstop (a scheduled agent, or a Hub revived by
    a watchdog) that runs INSIDE that window cannot see the restart, so it
    happily takes the role the cutover just vacated - which is how the UH Hub
    ended up with two live Hubs and a lease held by the wrong one
    (runId 20261102-172700).

    The contract under test:

      - `cutover-in-progress.json` is on disk BEFORE the switch runs, so a
        killed helper still leaves the fact behind;
      - it is removed when the cutover ends - after success AND after failure;
      - Test-CutoverInProgress answers 3 while a marker exists, or while
        `last-cutover.json` is inside -WindowMinutes, 0 when clear, and 2 when
        the state cannot be evaluated (never a silent "clear").

    Every fixture here is a file on disk: no live cutover, no Paseo.
#>

BeforeAll {
    $script:SkillRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
    $script:HelperPath = Join-Path $script:SkillRoot 'scripts\Invoke-KeyCheckCutover.ps1'
    $script:TestPath = Join-Path $script:SkillRoot 'scripts\Test-CutoverInProgress.ps1'
    $script:PwshExe = Join-Path $PSHOME 'pwsh.exe'

    function New-MarkerFixture {
        param([int]$SwitchExit = 0, [switch]$SwitchMissing)
        $dir = Join-Path $TestDrive ("kc-marker-{0}" -f ([guid]::NewGuid().ToString('N')))
        $null = New-Item -ItemType Directory -Path $dir -Force

        $seamPath = Join-Path $dir 'seam.json'
        @{ activeKey = 'OPENCODE_GO2_KEY' } | ConvertTo-Json | Set-Content -LiteralPath $seamPath
        $keysPath = Join-Path $dir 'keys.json'
        @{
            inUse = 'marker-value-bravo'
            keys  = @{ GO1 = 'marker-value-alpha'; GO2 = 'marker-value-bravo' }
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $keysPath
        $paseoConfig = Join-Path $dir 'paseo-config.json'
        @{ agents = @{ providers = @{ opencode = @{ env = @{ OPENCODE_GO_KEY = 'marker-value-bravo' } } } } } |
            ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $paseoConfig

        $logPath = Join-Path $dir 'steps.log'
        New-Item -ItemType File -Path $logPath -Force | Out-Null
        $markerPath = Join-Path $dir 'cutover-in-progress.json'
        $killWindowPath = Join-Path $dir 'cutover-kill-window.json'

        $switchPath = Join-Path $dir 'switch-stub.ps1'
        @"
param([int]`$KeyNumber = 0, [switch]`$ResumePartial)
Add-Content -LiteralPath '$logPath' -Value 'switch'
if (Test-Path -LiteralPath '$markerPath') {
    Copy-Item -LiteralPath '$markerPath' -Destination '$dir\marker-at-switch.json' -Force
}
exit $SwitchExit
"@ | Set-Content -LiteralPath $switchPath

        $repairPath = Join-Path $dir 'repair-stub.ps1'
        @"
param([int]`$KeyNumber = 0)
Add-Content -LiteralPath '$logPath' -Value 'repair'
exit 0
"@ | Set-Content -LiteralPath $repairPath

        if ($SwitchMissing) { $switchPath = Join-Path $dir 'no-such-switch.ps1' }

        [pscustomobject]@{
            Dir             = $dir
            SeamPath        = $seamPath
            KeysPath        = $keysPath
            PaseoConfig     = $paseoConfig
            LogPath         = $logPath
            SwitchPath      = $switchPath
            RepairPath      = $repairPath
            MarkerPath      = $markerPath
            KillWindowPath  = $killWindowPath
            PartialPath     = Join-Path $dir 'partial-cutover.json'
            OutcomePath     = Join-Path $dir 'outcome.json'
            MarkerSnapshot  = Join-Path $dir 'marker-at-switch.json'
        }
    }

    function Invoke-MarkerCutover {
        param($Fixture, [string]$RunId = 'run-m1')
        $helperArgs = @(
            '-NoProfile', '-File', $script:HelperPath,
            '-KeyNumber', '2',
            '-OutcomePath', $Fixture.OutcomePath,
            '-RunId', $RunId,
            '-SwitchScript', $Fixture.SwitchPath,
            '-RepairScript', $Fixture.RepairPath,
            '-SeamPath', $Fixture.SeamPath,
            '-KeyValuesFile', $Fixture.KeysPath,
            '-PaseoConfig', $Fixture.PaseoConfig,
            '-PartialMarkerPath', $Fixture.PartialPath,
            '-MarkerPath', $Fixture.MarkerPath,
            '-KillWindowPath', $Fixture.KillWindowPath,
            '-NoRoster',
            '-TimeoutSeconds', '60'
        )
        $output = & $script:PwshExe @helperArgs 2>&1 | Out-String
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
    }

    function Invoke-CutoverProbe {
        param([string]$StateDir, [int]$WindowMinutes = 60)
        $output = & $script:PwshExe -NoProfile -File $script:TestPath `
            -StateDir $StateDir -WindowMinutes $WindowMinutes 2>&1 | Out-String
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($output.Trim()) }
    }
}

Describe 'cutover-in-progress marker' {

    It 'is on disk before the switch runs' {
        $fixture = New-MarkerFixture

        $run = Invoke-MarkerCutover -Fixture $fixture

        $run.ExitCode | Should -Be 0 -Because $run.Output
        Test-Path -LiteralPath $fixture.MarkerSnapshot | Should -BeTrue -Because 'the marker must exist before the switch moves anything'
        $marker = Get-Content -LiteralPath $fixture.MarkerSnapshot -Raw | ConvertFrom-Json
        $marker.runId | Should -Be 'run-m1'
        $marker.startedAt | Should -Not -BeNullOrEmpty
        $marker.phase | Should -Be 'switch'
        $marker.host | Should -Not -BeNullOrEmpty
    }

    It 'is removed once the cutover succeeds' {
        $fixture = New-MarkerFixture

        $run = Invoke-MarkerCutover -Fixture $fixture

        $run.ExitCode | Should -Be 0 -Because $run.Output
        Test-Path -LiteralPath $fixture.MarkerPath | Should -BeFalse
    }

    It 'is removed once the cutover fails' {
        $fixture = New-MarkerFixture -SwitchExit 1

        $run = Invoke-MarkerCutover -Fixture $fixture

        $run.ExitCode | Should -Be 4 -Because $run.Output
        Test-Path -LiteralPath $fixture.MarkerPath | Should -BeFalse
    }

    It 'is removed when the cutover never spawned a switch' {
        $fixture = New-MarkerFixture -SwitchMissing

        $run = Invoke-MarkerCutover -Fixture $fixture

        $run.ExitCode | Should -Be 4 -Because $run.Output
        Test-Path -LiteralPath $fixture.MarkerPath | Should -BeFalse
    }
}

Describe 'Test-CutoverInProgress' {

    It 'answers 3 while a marker exists and prints one loggable line' {
        $dir = Join-Path $TestDrive ("kc-probe-{0}" -f ([guid]::NewGuid().ToString('N')))
        $null = New-Item -ItemType Directory -Path $dir -Force
        @{
            runId = 'run-live'; startedAt = (Get-Date).ToString('o'); phase = 'repair'; host = 'HOST-1'
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $dir 'cutover-in-progress.json')

        $probe = Invoke-CutoverProbe -StateDir $dir

        $probe.ExitCode | Should -Be 3 -Because $probe.Output
        $probe.Output | Should -Match 'cutover-in-progress'
        $probe.Output | Should -Match 'run-live'
    }

    It 'answers 3 while last-cutover.json is inside the window' {
        $dir = Join-Path $TestDrive ("kc-probe-{0}" -f ([guid]::NewGuid().ToString('N')))
        $null = New-Item -ItemType Directory -Path $dir -Force
        @{ runId = 'run-recent'; at = (Get-Date).AddMinutes(-5).ToString('o') } |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $dir 'last-cutover.json')

        $probe = Invoke-CutoverProbe -StateDir $dir -WindowMinutes 60

        $probe.ExitCode | Should -Be 3 -Because $probe.Output
        $probe.Output | Should -Match 'run-recent'
    }

    It 'answers 0 once the marker is gone and the last cutover is outside the window' {
        $dir = Join-Path $TestDrive ("kc-probe-{0}" -f ([guid]::NewGuid().ToString('N')))
        $null = New-Item -ItemType Directory -Path $dir -Force
        @{ runId = 'run-old'; at = (Get-Date).AddMinutes(-120).ToString('o') } |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $dir 'last-cutover.json')

        $probe = Invoke-CutoverProbe -StateDir $dir -WindowMinutes 60

        $probe.ExitCode | Should -Be 0 -Because $probe.Output
        $probe.Output | Should -Match 'cutover-in-progress: no'
    }

    It 'answers 0 when there is no state at all' {
        $dir = Join-Path $TestDrive ("kc-probe-{0}" -f ([guid]::NewGuid().ToString('N')))
        $null = New-Item -ItemType Directory -Path $dir -Force

        $probe = Invoke-CutoverProbe -StateDir $dir

        $probe.ExitCode | Should -Be 0 -Because $probe.Output
    }

    It 'answers 2 when the marker cannot be evaluated' {
        $dir = Join-Path $TestDrive ("kc-probe-{0}" -f ([guid]::NewGuid().ToString('N')))
        $null = New-Item -ItemType Directory -Path $dir -Force
        Set-Content -LiteralPath (Join-Path $dir 'cutover-in-progress.json') -Value '{ not json'

        $probe = Invoke-CutoverProbe -StateDir $dir

        $probe.ExitCode | Should -Be 2 -Because $probe.Output
        $probe.Output | Should -Match 'cannot-evaluate'
    }
}
