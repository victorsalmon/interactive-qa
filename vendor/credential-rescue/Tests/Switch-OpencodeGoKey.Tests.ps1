#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0.0' }

<#
.SYNOPSIS
    Pester tests for Switch-OpencodeGoKey.ps1 - the Salmon-track cutover.

.DESCRIPTION
    Two defects are pinned here, both measured on this box (2026-11-02):

      1. THE CANARY TESTED THE WRONG KEY. The switch's caller holds the
         pre-switch key in its process environment, and `opencode run` talks to
         a long-lived background service that froze its own environment at
         spawn, so a canary could answer with a quota error from a key that is
         not the one just written. The canary must therefore receive the NEW
         key explicitly (and run on a private server) and must name the key
         label it exercised.

      2. A FAILED CANARY LEFT A SPLIT MACHINE. The switch wrote the seam, the
         User env, auth.json and ~/.salmon/config.json, then exited 1 with the
         surfaces disagreeing. A post-write canary failure must restore the
         pre-switch state byte-for-byte; only a rollback that itself fails may
         leave a partial application, and then it leaves a label-only marker
         (partial-cutover.json) and a distinct exit code.

    Every fixture key value is a plain marker string - no test touches a real
    credential, the real registry, or a real Paseo restart.
#>

BeforeAll {
    $script:SkillRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
    $script:SwitchPath = Join-Path $script:SkillRoot 'scripts\Switch-OpencodeGoKey.ps1'
    $script:PwshExe = Join-Path $PSHOME 'pwsh.exe'

    $script:OldKey = 'switch-fixture-old'
    $script:NewKey = 'switch-fixture-new'

    function New-SwitchFixture {
        param([string]$SeamActiveKey = 'OPENCODE_GO1_KEY')
        $dir = Join-Path $TestDrive ("switch-{0}" -f ([guid]::NewGuid().ToString('N')))
        $null = New-Item -ItemType Directory -Path $dir -Force

        $seam = Join-Path $dir 'seam.json'
        @{
            activeKey = $SeamActiveKey
            updated   = '2026-11-01'
            poolOrder = @('OPENCODE_GO1_KEY', 'OPENCODE_GO3_KEY')
            canary    = @{ defaultMode = 'fast'; fast = @(@{ model = 'opencode-go/deepseek-v4.1-flash'; variant = 'low' }) }
            hygiene   = @{ mode = 'never' }
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $seam

        $auth = Join-Path $dir 'auth.json'
        @{ 'opencode-go' = @{ type = 'api'; key = $script:OldKey } } |
            ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $auth -NoNewline

        $runtime = Join-Path $dir 'salmon-config.json'
        @{
            execution = @{
                defaultCodingKey      = 'OPENCODE_GO1_KEY'
                keyMaxConcurrent      = @{ OPENCODE_GO3_KEY = 4 }
                providerMaxConcurrent = @{ 'opencode-go' = 4 }
            }
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $runtime -NoNewline

        $state = Join-Path $dir 'state.json'
        @{
            pool = @{ OPENCODE_GO1_KEY = $script:OldKey; OPENCODE_GO3_KEY = $script:NewKey }
            user = @{ OPENCODE_GO_KEY = $script:OldKey; OPENCODE_API_KEY = $script:OldKey }
        } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $state

        $stateDir = Join-Path $dir 'key-check'
        $record = Join-Path $dir 'canary-record.json'
        $kept = Join-Path $dir 'snapshot-kept'

        # The stub is the "sender". It records the key it was given (never
        # printing it), and on demand breaks the rollback the only way a real
        # one breaks: the pre-switch snapshot becomes unreadable.
        $canary = Join-Path $dir 'canary-stub.ps1'
        @"
param([string]`$Model, [string]`$Variant, [string]`$KeyLabel)
[ordered]@{
    key     = `$env:OPENCODE_GO_KEY
    api     = `$env:OPENCODE_API_KEY
    label   = `$KeyLabel
    model   = `$Model
    variant = `$Variant
} | ConvertTo-Json | Set-Content -LiteralPath '$record'
if (`$env:CANARY_STUB_KEEP_SNAPSHOT -eq '1') {
    Copy-Item -LiteralPath '$stateDir\cutover-snapshot' -Destination '$kept' -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath '$stateDir\cutover-snapshot' -Recurse -Force -ErrorAction SilentlyContinue
}
exit [int]`$env:CANARY_STUB_EXIT
"@ | Set-Content -LiteralPath $canary

        [pscustomobject]@{
            Dir         = $dir
            SeamPath    = $seam
            AuthJson    = $auth
            Runtime     = $runtime
            State       = $state
            StateDir    = $stateDir
            MarkerPath  = Join-Path $stateDir 'partial-cutover.json'
            SnapshotDir = Join-Path $stateDir 'cutover-snapshot'
            KeptDir     = $kept
            Record      = $record
            Canary      = $canary
            Log         = Join-Path $dir 'cred-changes.jsonl'
            ConfigPath  = Join-Path $dir 'no-opencode-config.jsonc'
        }
    }

    function Invoke-Switch {
        param(
            $Fixture,
            [int]$KeyNumber = 3,
            [int]$CanaryExit = 0,
            [switch]$KeepSnapshot,
            [switch]$ResumePartial,
            [string]$ParentKey = 'stale-parent-value'
        )
        $savedGo = $env:OPENCODE_GO_KEY
        $savedApi = $env:OPENCODE_API_KEY
        $savedRoot = $env:CL_REPOS_ROOT
        $savedExit = $env:CANARY_STUB_EXIT
        $savedKeep = $env:CANARY_STUB_KEEP_SNAPSHOT
        try {
            # The caller's process env holds the PRE-switch key - the exact
            # condition that made the old in-process canary test the old key.
            $env:OPENCODE_GO_KEY = $ParentKey
            $env:OPENCODE_API_KEY = $ParentKey
            if (-not $env:CL_REPOS_ROOT) { $env:CL_REPOS_ROOT = $Fixture.Dir }
            $env:CANARY_STUB_EXIT = "$CanaryExit"
            $env:CANARY_STUB_KEEP_SNAPSHOT = if ($KeepSnapshot) { '1' } else { '0' }

            $switchArgs = @(
                '-NoProfile', '-File', $script:SwitchPath,
                '-KeyNumber', "$KeyNumber",
                '-SeamPath', $Fixture.SeamPath,
                '-AuthJson', $Fixture.AuthJson,
                '-RuntimeConfig', $Fixture.Runtime,
                '-ConfigPath', $Fixture.ConfigPath,
                '-FixtureState', $Fixture.State,
                '-CanaryScript', $Fixture.Canary,
                '-StateDir', $Fixture.StateDir,
                '-LogPath', $Fixture.Log,
                '-RunId', 'run-switch-test',
                '-SkipSessionCleanup', '-SkipHygiene',
                '-Actor', 'test', '-Reason', 'pester'
            )
            if ($ResumePartial) { $switchArgs += '-ResumePartial' }

            $output = & $script:PwshExe @switchArgs 2>&1 | Out-String
            $exit = $LASTEXITCODE
        } finally {
            $env:OPENCODE_GO_KEY = $savedGo
            $env:OPENCODE_API_KEY = $savedApi
            $env:CL_REPOS_ROOT = $savedRoot
            $env:CANARY_STUB_EXIT = $savedExit
            $env:CANARY_STUB_KEEP_SNAPSHOT = $savedKeep
        }
        [pscustomobject]@{
            ExitCode = $exit
            Output   = $output
            Record   = if (Test-Path -LiteralPath $Fixture.Record) { Get-Content -LiteralPath $Fixture.Record -Raw | ConvertFrom-Json } else { $null }
            State    = Get-Content -LiteralPath $Fixture.State -Raw | ConvertFrom-Json
            Seam     = Get-Content -LiteralPath $Fixture.SeamPath -Raw | ConvertFrom-Json
            Auth     = Get-Content -LiteralPath $Fixture.AuthJson -Raw | ConvertFrom-Json
            Runtime  = Get-Content -LiteralPath $Fixture.Runtime -Raw | ConvertFrom-Json
        }
    }

    function Get-FileFingerprint {
        param([string]$Path)
        if (-not (Test-Path -LiteralPath $Path)) { return '<absent>' }
        (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash + ":" + (Get-Item -LiteralPath $Path).Length
    }
}

Describe 'Switch-OpencodeGoKey canary' {

    It 'canaries the key it just wrote, not the caller''s stale process key' {
        $fixture = New-SwitchFixture

        $run = Invoke-Switch -Fixture $fixture -KeyNumber 3 -CanaryExit 0

        $run.ExitCode | Should -Be 0 -Because $run.Output
        # the sender received the NEW key explicitly, plus its label
        $run.Record.key | Should -Be $script:NewKey
        $run.Record.api | Should -Be $script:NewKey
        $run.Record.key | Should -Not -Be 'stale-parent-value'
        $run.Record.label | Should -Be 'GO3'
        # and the output names the key it exercised, so this cannot regress silently
        $run.Output | Should -Match 'key GO3'
        $run.Output | Should -Match 'PASS'
        $run.Output | Should -Not -Match ([regex]::Escape($script:NewKey))
    }

    It 'writes every surface of the new key on success' {
        $fixture = New-SwitchFixture

        $run = Invoke-Switch -Fixture $fixture -KeyNumber 3 -CanaryExit 0

        $run.ExitCode | Should -Be 0 -Because $run.Output
        $run.Seam.activeKey | Should -Be 'OPENCODE_GO3_KEY'
        $run.Auth.'opencode-go'.key | Should -Be $script:NewKey
        $run.Runtime.execution.defaultCodingKey | Should -Be 'OPENCODE_GO3_KEY'
        $run.State.user.OPENCODE_GO_KEY | Should -Be $script:NewKey
        $run.State.user.OPENCODE_API_KEY | Should -Be $script:NewKey
        # a decided cutover leaves no rollback snapshot and no marker behind
        Test-Path -LiteralPath $fixture.SnapshotDir | Should -BeFalse
        Test-Path -LiteralPath $fixture.MarkerPath | Should -BeFalse
    }
}

Describe 'Switch-OpencodeGoKey rollback' {

    It 'restores every pre-switch surface byte-identically when the canary fails' {
        $fixture = New-SwitchFixture
        $before = @{
            seam    = Get-FileFingerprint -Path $fixture.SeamPath
            auth    = Get-FileFingerprint -Path $fixture.AuthJson
            runtime = Get-FileFingerprint -Path $fixture.Runtime
        }

        $run = Invoke-Switch -Fixture $fixture -KeyNumber 3 -CanaryExit 1

        $run.ExitCode | Should -Be 1 -Because $run.Output
        $run.Output | Should -Match 'rolled-back'
        # it did test the new key before deciding to roll back
        $run.Record.key | Should -Be $script:NewKey
        $run.Record.label | Should -Be 'GO3'
        $run.Output | Should -Match 'FAIL'

        # byte-identical restoration of all three file surfaces
        (Get-FileFingerprint -Path $fixture.SeamPath) | Should -Be $before.seam
        (Get-FileFingerprint -Path $fixture.AuthJson) | Should -Be $before.auth
        (Get-FileFingerprint -Path $fixture.Runtime) | Should -Be $before.runtime

        # and the User values are back on the old key: no surface disagrees
        $run.State.user.OPENCODE_GO_KEY | Should -Be $script:OldKey
        $run.State.user.OPENCODE_API_KEY | Should -Be $script:OldKey
        $run.Seam.activeKey | Should -Be 'OPENCODE_GO1_KEY'
        $run.Auth.'opencode-go'.key | Should -Be $script:OldKey
        $run.Runtime.execution.defaultCodingKey | Should -Be 'OPENCODE_GO1_KEY'

        # a rolled-back run is a decided state: no marker, no snapshot
        Test-Path -LiteralPath $fixture.MarkerPath | Should -BeFalse
        Test-Path -LiteralPath $fixture.SnapshotDir | Should -BeFalse
    }
}

Describe 'Switch-OpencodeGoKey partial application' {

    It 'writes a label-only marker and exits 6 when the rollback itself fails' {
        $fixture = New-SwitchFixture

        $run = Invoke-Switch -Fixture $fixture -KeyNumber 3 -CanaryExit 1 -KeepSnapshot

        $run.ExitCode | Should -Be 6 -Because $run.Output
        $run.Output | Should -Match 'partial-cutover'
        Test-Path -LiteralPath $fixture.MarkerPath | Should -BeTrue

        $rawMarker = Get-Content -LiteralPath $fixture.MarkerPath -Raw
        $marker = $rawMarker | ConvertFrom-Json
        $marker.from | Should -Be 'GO1'
        $marker.to | Should -Be 'GO3'
        $marker.runId | Should -Be 'run-switch-test'
        @($marker.surfaces) | Should -Contain 'seam'
        @($marker.surfaces) | Should -Contain 'auth.json'
        @($marker.surfaces) | Should -Contain 'salmon-config'
        $marker.at | Should -Not -BeNullOrEmpty
        # never a value, only labels
        $rawMarker | Should -Not -Match ([regex]::Escape($script:NewKey))
        $rawMarker | Should -Not -Match ([regex]::Escape($script:OldKey))
    }

    It 'reverts to the recorded from key when the recorded target is not the requested one' {
        $fixture = New-SwitchFixture
        $null = Invoke-Switch -Fixture $fixture -KeyNumber 3 -CanaryExit 1 -KeepSnapshot
        # The rollback failed only because the snapshot was unreadable; put the
        # recorded pre-switch snapshot back so the revert path has its source.
        Copy-Item -LiteralPath $fixture.KeptDir -Destination $fixture.SnapshotDir -Recurse -Force

        $run = Invoke-Switch -Fixture $fixture -KeyNumber 1 -CanaryExit 0 -ResumePartial

        $run.ExitCode | Should -Be 1 -Because $run.Output
        $run.Output | Should -Match 'reverted'
        Test-Path -LiteralPath $fixture.MarkerPath | Should -BeFalse
        Test-Path -LiteralPath $fixture.SnapshotDir | Should -BeFalse
        $run.State.user.OPENCODE_GO_KEY | Should -Be $script:OldKey
        $run.Seam.activeKey | Should -Be 'OPENCODE_GO1_KEY'
        $run.Auth.'opencode-go'.key | Should -Be $script:OldKey
        $run.Runtime.execution.defaultCodingKey | Should -Be 'OPENCODE_GO1_KEY'
    }

    It 'completes the recorded target when it is still the requested key and its canary passes' {
        $fixture = New-SwitchFixture
        $null = Invoke-Switch -Fixture $fixture -KeyNumber 3 -CanaryExit 1 -KeepSnapshot
        Copy-Item -LiteralPath $fixture.KeptDir -Destination $fixture.SnapshotDir -Recurse -Force

        $run = Invoke-Switch -Fixture $fixture -KeyNumber 3 -CanaryExit 0 -ResumePartial

        $run.ExitCode | Should -Be 0 -Because $run.Output
        $run.Output | Should -Match 'completing the cutover'
        Test-Path -LiteralPath $fixture.MarkerPath | Should -BeFalse
        $run.Seam.activeKey | Should -Be 'OPENCODE_GO3_KEY'
        $run.Auth.'opencode-go'.key | Should -Be $script:NewKey
        $run.Runtime.execution.defaultCodingKey | Should -Be 'OPENCODE_GO3_KEY'
        $run.State.user.OPENCODE_GO_KEY | Should -Be $script:NewKey
        $run.Record.key | Should -Be $script:NewKey
    }
}
