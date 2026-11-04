#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0.0' }

<#
.SYNOPSIS
    cl-common-6j7: the cutover seam is committed CONFIG; its observations are
    runtime state outside the tracked/vendored file.

.DESCRIPTION
    `assets/opencode-go-cutover.json` is tracked in git AND vendored as a
    manifest copy row. When the per-key freshness ledger lived inside it, every
    Key Watch cycle rewrote a tracked file and drifted its own vendored row, so
    the package gate went red on a timer. The split (the same fix the provider
    lock already got):

      config        tracked seam: activeKey, poolOrder, caps, windows;
      observations  run state: asOf + per-key state/usage/resetsOn/observedAt/
                    evidence/meters, at the seam's `observationsPath`
                    (profile state root), written by Set-OpencodeGoFreshness.

    Contract pinned here:

      - a watch write leaves the tracked seam byte-identical;
      - the write lands in the observations file, not in the seam;
      - a cold start (no observations file) still resolves the config's
        activeKey and reports an empty ledger instead of failing;
      - the reader prefers observations, falls back to a legacy embedded
        ledger read-only, then to empty;
      - the writer imports a legacy embedded ledger on its first write, so the
        split loses no recorded reading;
      - a fixture seam never touches the live profile state.

    Every test works on a temp copy. The live seam is never written.
#>

BeforeAll {
    $script:SkillRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
    $script:Scripts = Join-Path $script:SkillRoot 'scripts'
    $script:PwshExe = Join-Path $PSHOME 'pwsh.exe'

    function New-TempSeam {
        param([switch]$LegacyKeys)

        $dir = Join-Path $TestDrive ("6j7-{0}" -f ([guid]::NewGuid().ToString('N')))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $seamPath = Join-Path $dir 'opencode-go-cutover.json'

        $config = [ordered]@{
            version          = 1
            updated          = '2026-11-03'
            activeKey        = 'OPENCODE_GO3_KEY'
            observationsPath = '~/.machine/state/credential-rescue/seam-observations.json'
            poolOrder        = @('OPENCODE_GO1_KEY', 'OPENCODE_GO3_KEY')
            freshness        = [ordered]@{
                asOf    = $null
                windows = [ordered]@{
                    weekly  = [ordered]@{ label = 'weekly'; lengthDays = 7; percentOfMonthly = 50; tracked = $true }
                    monthly = [ordered]@{ label = 'monthly'; lengthDays = $null; percentOfMonthly = 100; tracked = $true }
                }
                keys    = $null
            }
        }

        if ($LegacyKeys) {
            $config.freshness.asOf = '2026-11-01'
            $config.freshness.keys = [ordered]@{
                OPENCODE_GO3_KEY = [ordered]@{
                    state        = 'fresh'
                    trippedMeter = $null
                    usage        = [ordered]@{ used = 41; of = 100 }
                    resetsOn     = '2026-11-20T18:06:52'
                    observedAt   = '2026-11-01'
                    evidence     = 'legacy embedded reading'
                    meters       = [ordered]@{
                        weekly  = [ordered]@{ used = 22; of = 100; resetsOn = '2026-11-09T00:00:00'; observedAt = '2026-11-01' }
                        monthly = [ordered]@{ used = 41; of = 100; resetsOn = '2026-11-20T18:06:52'; observedAt = '2026-11-01' }
                    }
                }
            }
        } else {
            $config.freshness.Remove('asOf')
            $config.freshness.Remove('keys')
        }

        [System.IO.File]::WriteAllText($seamPath, (($config | ConvertTo-Json -Depth 10).TrimEnd() + "`n"),
            (New-Object System.Text.UTF8Encoding($false)))
        $seamPath
    }

    function Get-ObservationsPath([string]$SeamPath) {
        Join-Path (Split-Path -Parent $SeamPath) 'seam-observations.json'
    }

    function Invoke-Child {
        param([Parameter(Mandatory)][string]$ScriptPath, [string[]]$ScriptArgs = @())
        $argsText = (@($ScriptArgs) | ForEach-Object {
                if ("$_" -match '^-') { $_ } else { "'" + ([string]$_ -replace "'", "''") + "'" }
            }) -join ' '
        $output = & $script:PwshExe -NoProfile -Command "& '$ScriptPath' $argsText" 2>&1 | Out-String
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
    }
}

Describe 'cl-common-6j7 cutover seam config/observation split' {

    Context 'config seam' {

        It 'carries no runtime observations in the tracked asset' {
            $asset = Join-Path $script:SkillRoot 'assets\opencode-go-cutover.json'
            $seam = Get-Content -LiteralPath $asset -Raw | ConvertFrom-Json

            $seam.activeKey | Should -Match '^OPENCODE_GO\d+_KEY$'
            $seam.PSObject.Properties['observationsPath'] | Should -Not -BeNullOrEmpty
            $seam.freshness.PSObject.Properties.Name | Should -Contain 'windows'
            $seam.freshness.PSObject.Properties.Name | Should -Not -Contain 'keys'
            $seam.freshness.PSObject.Properties.Name | Should -Not -Contain 'asOf'
            (Get-Content -LiteralPath $asset -Raw) | Should -Not -Match '"observedAt"\s*:'
        }
    }

    Context 'writer' {

        It 'records into the observations file and leaves the config seam byte-identical' {
            $seam = New-TempSeam
            $observations = Get-ObservationsPath $seam
            $before = (Get-FileHash -LiteralPath $seam -Algorithm SHA256).Hash

            $run = Invoke-Child -ScriptPath (Join-Path $script:Scripts 'Set-OpencodeGoFreshness.ps1') `
                -ScriptArgs @('-SeamPath', $seam, '-KeyNumber', '3', '-WeeklyUsed', '12', '-MonthlyUsed', '34',
                '-MonthlyResets', '2026-11-20', '-ObservedAt', '2026-11-03', '-NoLog')

            $run.ExitCode | Should -Be 0 -Because $run.Output
            (Get-FileHash -LiteralPath $seam -Algorithm SHA256).Hash | Should -Be $before
            Test-Path -LiteralPath $observations | Should -BeTrue

            $ledger = Get-Content -LiteralPath $observations -Raw | ConvertFrom-Json
            $ledger.asOf | Should -Be '2026-11-03'
            $ledger.keys.OPENCODE_GO3_KEY.meters.weekly.used | Should -Be 12
            $ledger.keys.OPENCODE_GO3_KEY.meters.monthly.used | Should -Be 34
            $ledger.keys.OPENCODE_GO3_KEY.state | Should -Be 'fresh'
        }

        It 'imports a legacy embedded ledger on the first write, losing no reading' {
            $seam = New-TempSeam -LegacyKeys
            $observations = Get-ObservationsPath $seam

            $run = Invoke-Child -ScriptPath (Join-Path $script:Scripts 'Set-OpencodeGoFreshness.ps1') `
                -ScriptArgs @('-SeamPath', $seam, '-KeyNumber', '3', '-MonthlyUsed', '55', '-ObservedAt', '2026-11-03', '-NoLog')

            $run.ExitCode | Should -Be 0 -Because $run.Output
            $ledger = Get-Content -LiteralPath $observations -Raw | ConvertFrom-Json
            $ledger.keys.OPENCODE_GO3_KEY.meters.weekly.used | Should -Be 22 -Because 'the legacy weekly reading must survive'
            $ledger.keys.OPENCODE_GO3_KEY.meters.monthly.used | Should -Be 55
            $ledger.asOf | Should -Be '2026-11-03'
        }
    }

    Context 'reader' {

        It 'cold-starts with no observations file: empty ledger, config activeKey, exit 0' {
            $seam = New-TempSeam
            $run = Invoke-Child -ScriptPath (Join-Path $script:Scripts 'Get-OpencodeGoFreshness.ps1') `
                -ScriptArgs @('-SeamPath', $seam, '-Json')

            $run.ExitCode | Should -Be 0 -Because $run.Output
            $view = $run.Output | ConvertFrom-Json
            $view.activeKey | Should -Be 'OPENCODE_GO3_KEY'
            $view.ledgerSource | Should -Be 'none'
            @($view.keys).Count | Should -Be 0
            (Get-ObservationsPath $seam) | Should -Not -BeNullOrEmpty
            Test-Path -LiteralPath (Get-ObservationsPath $seam) | Should -BeFalse -Because 'a read must not create state'
        }

        It 'reads observations when present' {
            $seam = New-TempSeam
            $observations = Get-ObservationsPath $seam
            $payload = [ordered]@{
                version = 1
                asOf    = '2026-11-03'
                keys    = [ordered]@{
                    OPENCODE_GO3_KEY = [ordered]@{
                        state      = 'exhausted'
                        usage      = [ordered]@{ used = 100; of = 100 }
                        observedAt = '2026-11-03'
                        meters     = [ordered]@{
                            weekly  = [ordered]@{ used = 0; of = 100; observedAt = '2026-11-03' }
                            monthly = [ordered]@{ used = 100; of = 100; resetsOn = '2026-11-20T18:06:52'; observedAt = '2026-11-03' }
                        }
                    }
                }
            }
            [System.IO.File]::WriteAllText($observations, ($payload | ConvertTo-Json -Depth 8),
                (New-Object System.Text.UTF8Encoding($false)))

            $run = Invoke-Child -ScriptPath (Join-Path $script:Scripts 'Get-OpencodeGoFreshness.ps1') `
                -ScriptArgs @('-SeamPath', $seam, '-Json')

            $run.ExitCode | Should -Be 0 -Because $run.Output
            $view = $run.Output | ConvertFrom-Json
            $view.ledgerSource | Should -Be 'observations'
            $view.asOf | Should -Be '2026-11-03'
            (@($view.keys)[0]).state | Should -Be 'exhausted'
        }

        It 'falls back read-only to a legacy embedded ledger, then observations win' {
            $seam = New-TempSeam -LegacyKeys
            $legacy = Invoke-Child -ScriptPath (Join-Path $script:Scripts 'Get-OpencodeGoFreshness.ps1') `
                -ScriptArgs @('-SeamPath', $seam, '-Json')
            $legacy.ExitCode | Should -Be 0 -Because $legacy.Output
            ($legacy.Output | ConvertFrom-Json).ledgerSource | Should -Be 'legacy-embedded'

            $observations = Get-ObservationsPath $seam
            [System.IO.File]::WriteAllText($observations,
                ([ordered]@{ version = 1; asOf = '2026-11-03'; keys = [ordered]@{} } | ConvertTo-Json -Depth 5),
                (New-Object System.Text.UTF8Encoding($false)))

            $current = Invoke-Child -ScriptPath (Join-Path $script:Scripts 'Get-OpencodeGoFreshness.ps1') `
                -ScriptArgs @('-SeamPath', $seam, '-Json')
            $current.ExitCode | Should -Be 0 -Because $current.Output
            $view = $current.Output | ConvertFrom-Json
            $view.ledgerSource | Should -Be 'observations'
            @($view.keys).Count | Should -Be 0 -Because 'the state file is authoritative once it exists'
        }

        It 'a non-canonical seam resolves observations beside itself, never the live profile' {
            $seam = New-TempSeam
            $run = Invoke-Child -ScriptPath (Join-Path $script:Scripts 'Get-OpencodeGoFreshness.ps1') `
                -ScriptArgs @('-SeamPath', $seam, '-Json')

            $run.ExitCode | Should -Be 0 -Because $run.Output
            $view = $run.Output | ConvertFrom-Json
            $view.observationsPath | Should -Be (Get-ObservationsPath $seam)
            $view.observationsPath | Should -Not -Match '\.machine\\State'
        }
    }
}
