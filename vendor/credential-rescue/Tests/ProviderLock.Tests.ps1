#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

<#
.SYNOPSIS
    Pester tests for Invoke-ProviderLock.ps1 and the shared secret-fingerprint
    helpers.

.DESCRIPTION
    The provider lock exists so "is this consumer using the right key?" can be
    answered without ever printing a value. The contract under test:

      - Lock records a SHA-256 fingerprint and length, never the value;
      - Status reports MATCH when a consumer equals the authoritative value;
      - Status reports DRIFT and exits 1 when it differs;
      - required targets that are missing fail, optional ones do not;
      - an absent Paseo provider reports NOT-CONFIGURED, not a crash;
      - a seam expands `${activeKey}` in target names;
      - no test output ever contains the secret values.
#>

BeforeAll {
    $script:ScriptPath = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..' 'scripts\Invoke-ProviderLock.ps1')).Path
    $script:PwshExe = Join-Path $PSHOME 'pwsh.exe'
    $script:LibPath = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..' '..\aws\scripts\SecretFingerprint.ps1')).Path
    . $script:LibPath

    function New-Fixture {
        <#
        .SYNOPSIS
            Build a lock asset, a file source, a seam and a deterministic Paseo
            config in TestDrive. No AWS access is needed (-NoAws).
        #>
        param(
            [string]$Value = 'test-provider-key-0001',
            [string]$TargetName = 'PROVLOCK_TEST_TARGET',
            [switch]$UseSeam,
            [switch]$Required,
            [switch]$PaseoConfigured
        )

        $dir = Join-Path $TestDrive ("provlock-{0}" -f ([guid]::NewGuid().ToString('N')))
        $null = New-Item -ItemType Directory -Path $dir -Force
        $sourcePath = Join-Path $dir 'source.key'
        Set-Content -LiteralPath $sourcePath -Value $Value -NoNewline

        # Seam: activeKey names the env var to compare (exercises ${activeKey}).
        $seamName = if ($UseSeam) {
            @{ activeKey = $TargetName } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $dir 'seam.json')
            'seam.json'
        }
        else { '' }

        # A config that exists but has no 'paseotest' provider -> NOT-CONFIGURED.
        $paseoConfig = Join-Path $dir 'paseo-config.json'
        $providers = @{ opencode = @{ env = @{ OPENCODE_GO_KEY = 'unrelated-value' } } }
        if ($PaseoConfigured) { $providers['paseotest'] = @{ env = @{ PROVLOCK_PASEO_KEY = $Value } } }
        @{ agents = @{ providers = $providers } } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $paseoConfig

        $lockPath = Join-Path $dir 'provider-lock.json'
        @{
            version   = 1
            providers = @{
                fixture = @{
                    label       = 'fixture provider'
                    source      = @{ kind = 'file'; path = $sourcePath; seamPath = $seamName }
                    targets     = @(
                        @{ kind = 'env'; scope = 'Process'; name = $(if ($UseSeam) { '${activeKey}' } else { $TargetName }); required = [bool]$Required }
                        @{ kind = 'paseo'; provider = 'paseotest'; envName = 'PROVLOCK_PASEO_KEY'; configPath = $paseoConfig; required = $false }
                    )
                    fingerprint = @{ sha256 = ''; length = 0; lockedAt = ''; lockedBy = '' }
                }
            }
        } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $lockPath

        [pscustomobject]@{
            Dir        = $dir
            LockPath   = $lockPath
            Value      = $Value
            TargetName = $TargetName
        }
    }

    function Invoke-Lock {
        param($Fixture, [ValidateSet('Status', 'Lock')][string]$Mode = 'Status')
        $output = & $script:PwshExe -NoProfile -File $script:ScriptPath -Mode $Mode -LockPath $Fixture.LockPath -NoAws 2>&1 | Out-String
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
    }
}

Describe 'Secret fingerprint helpers' {
    It 'fingerprints without exposing the value and is stable' {
        $one = Get-SecretFingerprint -Value 'abc-123'
        $two = Get-SecretFingerprint -Value 'abc-123'
        $one.Sha256 | Should -Be $two.Sha256
        $one.Length | Should -Be 7
        $one.Prefix.Length | Should -Be 12
        $one.Sha256 | Should -Not -Match 'abc-123'
    }

    It 'treats empty as absent and empty never equals empty' {
        (Get-SecretFingerprint -Value '').Present | Should -BeFalse
        Test-SecretEqual -A '' -B '' | Should -BeFalse
        Test-SecretEqual -A 'x' -B 'x' | Should -BeTrue
    }
}

Describe 'Invoke-ProviderLock' {

    Context 'Lock mode' {
        It 'records a fingerprint and length, never the value' {
            $fixture = New-Fixture -Value 'lock-value-abc-999'
            $result = Invoke-Lock -Fixture $fixture -Mode Lock

            $result.ExitCode | Should -Be 0 -Because $result.Output
            $result.Output | Should -Match 'LOCKED'
            $result.Output | Should -Not -Match 'lock-value-abc-999'

            $asset = Get-Content -LiteralPath $fixture.LockPath -Raw | ConvertFrom-Json
            $stored = $asset.providers.fixture.fingerprint
            $stored.length | Should -Be 'lock-value-abc-999'.Length
            $stored.sha256 | Should -Be (Get-SecretFingerprint -Value 'lock-value-abc-999').Sha256
            $stored.lockedBy | Should -Not -BeNullOrEmpty
        }
    }

    Context 'Status mode' {
        It 'reports MATCH for a consumer equal to the authoritative value' {
            $fixture = New-Fixture -Value 'match-value-777'
            $env:PROVLOCK_TEST_TARGET = 'match-value-777'
            try {
                $null = Invoke-Lock -Fixture $fixture -Mode Lock
                $result = Invoke-Lock -Fixture $fixture

                $result.ExitCode | Should -Be 0 -Because $result.Output
                $result.Output | Should -Match 'MATCH'
                $result.Output | Should -Not -Match 'match-value-777'
            }
            finally { Remove-Item Env:PROVLOCK_TEST_TARGET -ErrorAction SilentlyContinue }
        }

        It 'reports DRIFT and exits 1 when the consumer differs' {
            $fixture = New-Fixture -Value 'authoritative-111'
            $env:PROVLOCK_TEST_TARGET = 'authoritative-111'
            try { $null = Invoke-Lock -Fixture $fixture -Mode Lock }
            finally { Remove-Item Env:PROVLOCK_TEST_TARGET -ErrorAction SilentlyContinue }

            $env:PROVLOCK_TEST_TARGET = 'different-222'
            try {
                $result = Invoke-Lock -Fixture $fixture
                $result.ExitCode | Should -Be 1 -Because $result.Output
                $result.Output | Should -Match 'DRIFT'
                $result.Output | Should -Not -Match 'authoritative-111'
                $result.Output | Should -Not -Match 'different-222'
            }
            finally { Remove-Item Env:PROVLOCK_TEST_TARGET -ErrorAction SilentlyContinue }
        }

        It 'fails a required target that is missing' {
            $fixture = New-Fixture -Value 'required-333' -Required
            Remove-Item Env:PROVLOCK_TEST_TARGET -ErrorAction SilentlyContinue
            $null = Invoke-Lock -Fixture $fixture -Mode Lock

            $status = Invoke-Lock -Fixture $fixture
            $status.ExitCode | Should -Be 1 -Because $status.Output
            $status.Output | Should -Match 'MISSING'
        }

        It 'does not fail an optional target that is missing' {
            $fixture = New-Fixture -Value 'optional-444'
            Remove-Item Env:PROVLOCK_TEST_TARGET -ErrorAction SilentlyContinue
            $null = Invoke-Lock -Fixture $fixture -Mode Lock

            $status = Invoke-Lock -Fixture $fixture
            $status.ExitCode | Should -Be 0 -Because $status.Output
            $status.Output | Should -Match 'OPTIONAL-MISSING'
        }

        It 'reports NOT-CONFIGURED when Paseo has no provider block' {
            $fixture = New-Fixture -Value 'paseo-555'
            $env:PROVLOCK_TEST_TARGET = 'paseo-555'
            try {
                $null = Invoke-Lock -Fixture $fixture -Mode Lock
                $status = Invoke-Lock -Fixture $fixture

                $status.ExitCode | Should -Be 0 -Because $status.Output
                $status.Output | Should -Match 'NOT-CONFIGURED'
                $status.Output | Should -Not -Match 'paseo-555'
            }
            finally { Remove-Item Env:PROVLOCK_TEST_TARGET -ErrorAction SilentlyContinue }
        }

        It 'matches a configured Paseo provider' {
            $fixture = New-Fixture -Value 'paseo-666' -PaseoConfigured
            $env:PROVLOCK_TEST_TARGET = 'paseo-666'
            try {
                $null = Invoke-Lock -Fixture $fixture -Mode Lock
                $status = Invoke-Lock -Fixture $fixture

                $status.ExitCode | Should -Be 0 -Because $status.Output
                $status.Output | Should -Match 'paseo:paseotest\.PROVLOCK_PASEO_KEY\s+MATCH'
            }
            finally { Remove-Item Env:PROVLOCK_TEST_TARGET -ErrorAction SilentlyContinue }
        }

        It 'expands ${activeKey} from a seam into target names' {
            $fixture = New-Fixture -Value 'seam-value-888' -UseSeam
            $env:PROVLOCK_TEST_TARGET = 'seam-value-888'
            try {
                $null = Invoke-Lock -Fixture $fixture -Mode Lock
                $status = Invoke-Lock -Fixture $fixture

                $status.ExitCode | Should -Be 0 -Because $status.Output
                $status.Output | Should -Match 'Process:PROVLOCK_TEST_TARGET\s+MATCH'
                $status.Output | Should -Not -Match 'seam-value-888'
            }
            finally { Remove-Item Env:PROVLOCK_TEST_TARGET -ErrorAction SilentlyContinue }
        }
    }
}
