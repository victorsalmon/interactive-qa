#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0.0' }

<#
.SYNOPSIS
    cl-common-n42: the freshness ledger must carry round-trip ISO dates.

.DESCRIPTION
    `assets/opencode-go-cutover.json` is the single seam for opencode-go key
    state and every other surface is projected from it. The 2026-11-02 cutover
    recorded `resetsOn` values rendered by the ambient culture
    (`11/09/2026 00:00:00`), which reads as 9 November under en-US and
    11 September under en-GB. The reset instant is exactly what the eligibility
    ranking and the ETT arithmetic compare, so an ambiguous value can silently
    pick the wrong key.

    The contract this suite pins:

      - the producer (Get-GoKeyUsage -> Get-UsageWindow) emits ISO, not a
        locale string, whatever the process culture;
      - the writer (Set-OpencodeGoFreshness) normalises an unambiguous
        locale-shaped value, REFUSES an ambiguous one instead of persisting it,
        and leaves exactly one trailing newline;
      - the reader (Get-OpencodeGoFreshness) reports an ambiguous stored value
        as cannot-evaluate for that key rather than a confident wrong date,
        normalises an unambiguous one, and still resolves the real asset.

    Every test works on a temp copy. The live seam is never written.
#>

BeforeAll {
    $script:SkillRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
    $script:Scripts = Join-Path $script:SkillRoot 'scripts'
    $script:PwshExe = Join-Path $PSHOME 'pwsh.exe'

    $script:IsoValuePattern = '^\d{4}-\d{2}-\d{2}(T\d{2}:\d{2}(:\d{2})?)?$'
    $script:LocaleValuePattern = '\d{1,2}[./]\d{1,2}[./]\d{4}'

    function New-LedgerFixture {
        param(
            [Parameter(Mandatory)][string]$Path,
            [string]$RowResets = '2026-12-02T00:18:32',
            [string]$WeeklyResets = '2026-11-09T00:00:00',
            [string]$MonthlyResets = '2026-12-02T00:18:32',
            [string]$ObservedAt = '2026-11-02'
        )
        $fixture = [ordered]@{
            updated   = '2026-11-02'
            activeKey = 'OPENCODE_GO2_KEY'
            poolOrder = @('OPENCODE_GO2_KEY')
            freshness = [ordered]@{
                asOf    = $ObservedAt
                windows = [ordered]@{
                    weekly  = [ordered]@{ label = 'weekly'; lengthDays = 7; percentOfMonthly = 50 }
                    monthly = [ordered]@{ label = 'monthly'; lengthDays = $null; percentOfMonthly = 100 }
                }
                keys    = [ordered]@{
                    OPENCODE_GO2_KEY = [ordered]@{
                        state        = 'fresh'
                        trippedMeter = $null
                        usage        = [ordered]@{ used = 20; of = 100 }
                        resetsOn     = $RowResets
                        observedAt   = $ObservedAt
                        evidence     = 'fixture'
                        meters       = [ordered]@{
                            weekly  = [ordered]@{ used = 10; of = 100; resetsOn = $WeeklyResets; observedAt = $ObservedAt }
                            monthly = [ordered]@{ used = 20; of = 100; resetsOn = $MonthlyResets; observedAt = $ObservedAt }
                        }
                    }
                }
            }
        }
        $text = $fixture | ConvertTo-Json -Depth 10
        [System.IO.File]::WriteAllText($Path, $text + "`n", (New-Object System.Text.UTF8Encoding($false)))
        $Path
    }

    function New-FixturePath {
        param([string]$Name = 'opencode-go-cutover.json')
        $dir = Join-Path $TestDrive ("n42-{0}" -f ([guid]::NewGuid().ToString('N')))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Join-Path $dir $Name
    }

    function Get-ObservationsPath {
        param([string]$SeamPath)
        # cl-common-6j7: a fixture seam keeps its runtime observations beside
        # itself; the tracked seam never holds them.
        Join-Path (Split-Path -Parent $SeamPath) 'seam-observations.json'
    }

    function ConvertTo-PsLiteral {
        param($Value)
        "'" + ([string]$Value -replace "'", "''") + "'"
    }

    # Run a script in a child pwsh under a named culture, so the ambient
    # culture is genuinely different without touching this process.
    function Invoke-InCulture {
        param(
            [Parameter(Mandatory)][string]$Culture,
            [Parameter(Mandatory)][string]$ScriptPath,
            [string[]]$ScriptArgs = @()
        )
        # Parameter NAMES stay unquoted: a quoted '-Json' is a positional VALUE.
        $argsText = (@($ScriptArgs) | ForEach-Object {
                if ("$_" -match '^-') { $_ } else { ConvertTo-PsLiteral $_ }
            }) -join ' '
        $inner = @(
            "[System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('$Culture')"
            "[System.Threading.Thread]::CurrentThread.CurrentUICulture = [System.Globalization.CultureInfo]::GetCultureInfo('$Culture')"
            "& $(ConvertTo-PsLiteral $ScriptPath) $argsText"
            'exit $LASTEXITCODE'
        ) -join '; '
        $output = & $script:PwshExe -NoProfile -Command $inner 2>&1 | Out-String
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
    }

    function Get-JsonFieldValues {
        param([string]$Path, [string]$Field)
        $text = Get-Content -LiteralPath $Path -Raw
        @([regex]::Matches($text, ('"{0}":\s*"([^"]*)"' -f [regex]::Escape($Field))) | ForEach-Object { $_.Groups[1].Value })
    }
}

Describe 'cl-common-n42 ledger date seam' {

    Context 'producer: Get-GoKeyUsage' {

        It 'emits ISO reset instants whatever the process culture' {
            $fixture = New-FixturePath -Name 'usage.json'
            $body = '{"usage":{"rolling":{"status":"ok","percent":0,"resetsAt":"2026-11-09T00:00:00Z"},' +
                '"weekly":{"status":"ok","percent":10,"resetsAt":"2026-11-09T00:00:00Z"},' +
                '"monthly":{"status":"rate-limited","percent":100,"resetsAt":"2026-12-02T00:18:32Z"}}}'
            [System.IO.File]::WriteAllText($fixture, $body, (New-Object System.Text.UTF8Encoding($false)))

            $run = Invoke-InCulture -Culture 'de-DE' -ScriptPath (Join-Path $script:Scripts 'Get-GoKeyUsage.ps1') `
                -ScriptArgs @('-KeyNumber', '2', '-KeyValue', 'fixture-key-not-real', '-UsageJsonFile', $fixture, '-Json')

            $run.ExitCode | Should -Be 0 -Because $run.Output
            $run.Output | Should -Not -Match $script:LocaleValuePattern
            # Assert on the JSON TEXT (a parse would hide the defect: parsing is
            # exactly what makes `11/09/2026` a confident, wrong answer).
            $run.Output | Should -Match '"ResetsAt":\s*"2026-11-09T00:00:00"'
            $run.Output | Should -Match '"ResetsAt":\s*"2026-12-02T00:18:32"'
            $row = $run.Output | ConvertFrom-Json -DateKind String
            $row.Weekly.ResetsAt | Should -Be '2026-11-09T00:00:00'
            $row.Monthly.ResetsAt | Should -Be '2026-12-02T00:18:32'
        }

        It 'keeps month and day in order under en-GB' {
            $fixture = New-FixturePath -Name 'usage-gb.json'
            $body = '{"usage":{"rolling":{"status":"ok","percent":0,"resetsAt":"2026-11-09T00:00:00Z"},' +
                '"weekly":{"status":"ok","percent":10,"resetsAt":"2026-11-09T00:00:00Z"},' +
                '"monthly":{"status":"rate-limited","percent":100,"resetsAt":"2026-12-02T00:18:32Z"}}}'
            [System.IO.File]::WriteAllText($fixture, $body, (New-Object System.Text.UTF8Encoding($false)))

            $run = Invoke-InCulture -Culture 'en-GB' -ScriptPath (Join-Path $script:Scripts 'Get-GoKeyUsage.ps1') `
                -ScriptArgs @('-KeyNumber', '2', '-KeyValue', 'fixture-key-not-real', '-UsageJsonFile', $fixture, '-Json')

            $run.ExitCode | Should -Be 0 -Because $run.Output
            $row = $run.Output | ConvertFrom-Json -DateKind String
            $row.Weekly.ResetsAt | Should -Be '2026-11-09T00:00:00'
            $row.Monthly.ResetsAt | Should -Be '2026-12-02T00:18:32'
        }
    }

    Context 'writer: Set-OpencodeGoFreshness' {

        It 'writes ISO dates under a de-DE process culture' {
            $seam = New-LedgerFixture -Path (New-FixturePath)
            $observations = Get-ObservationsPath $seam
            $run = Invoke-InCulture -Culture 'de-DE' -ScriptPath (Join-Path $script:Scripts 'Set-OpencodeGoFreshness.ps1') `
                -ScriptArgs @('-SeamPath', $seam, '-KeyNumber', '2', '-WeeklyUsed', '11', '-WeeklyResets', '2026-12-02T00:18',
                '-MonthlyUsed', '22', '-MonthlyResets', '2026-12-02', '-ObservedAt', '2026-11-02', '-NoLog')

            $run.ExitCode | Should -Be 0 -Because $run.Output
            Test-Path -LiteralPath $observations | Should -BeTrue
            Get-JsonFieldValues -Path $observations -Field 'resetsOn' | ForEach-Object { $_ | Should -Match $script:IsoValuePattern }
            Get-JsonFieldValues -Path $observations -Field 'observedAt' | ForEach-Object { $_ | Should -Match $script:IsoValuePattern }
            Get-JsonFieldValues -Path $observations -Field 'resetsOn' | Should -Contain '2026-12-02T00:18:00'
            (Get-Content -LiteralPath $observations -Raw) | Should -Not -Match $script:LocaleValuePattern
        }

        It 'normalises an unambiguous locale-shaped date instead of storing it verbatim' {
            $seam = New-LedgerFixture -Path (New-FixturePath)
            $observations = Get-ObservationsPath $seam
            $run = Invoke-InCulture -Culture 'en-US' -ScriptPath (Join-Path $script:Scripts 'Set-OpencodeGoFreshness.ps1') `
                -ScriptArgs @('-SeamPath', $seam, '-KeyNumber', '2', '-MonthlyUsed', '33',
                '-MonthlyResets', '12/23/2026 23:43:24', '-NoLog')

            $run.ExitCode | Should -Be 0 -Because $run.Output
            Get-JsonFieldValues -Path $observations -Field 'resetsOn' | Should -Contain '2026-12-23T23:43:24'
            (Get-Content -LiteralPath $observations -Raw) | Should -Not -Match $script:LocaleValuePattern
        }

        It 'refuses an ambiguous locale-shaped date rather than persisting it' {
            $seam = New-LedgerFixture -Path (New-FixturePath)
            $observations = Get-ObservationsPath $seam
            $run = Invoke-InCulture -Culture 'en-US' -ScriptPath (Join-Path $script:Scripts 'Set-OpencodeGoFreshness.ps1') `
                -ScriptArgs @('-SeamPath', $seam, '-KeyNumber', '2', '-MonthlyUsed', '33',
                '-MonthlyResets', '11/09/2026 00:00:00', '-NoLog')

            $run.ExitCode | Should -Not -Be 0 -Because 'an ambiguous d/m value must be refused, never written'
            $run.Output | Should -Match 'ambiguous'
            Test-Path -LiteralPath $observations | Should -BeFalse -Because 'a refused write must not create an observations file'
        }

        It 'leaves exactly one trailing newline after a write' {
            $seam = New-LedgerFixture -Path (New-FixturePath)
            $observations = Get-ObservationsPath $seam
            $run = Invoke-InCulture -Culture 'en-US' -ScriptPath (Join-Path $script:Scripts 'Set-OpencodeGoFreshness.ps1') `
                -ScriptArgs @('-SeamPath', $seam, '-KeyNumber', '2', '-WeeklyUsed', '12', '-NoLog')

            $run.ExitCode | Should -Be 0 -Because $run.Output
            $bytes = [System.IO.File]::ReadAllBytes($observations)
            $bytes[-1] | Should -Be 10
            $bytes[-2] | Should -Not -Be 10
        }

        It 'leaves the tracked config seam byte-identical after a write' {
            $seam = New-LedgerFixture -Path (New-FixturePath)
            $before = (Get-FileHash -LiteralPath $seam -Algorithm SHA256).Hash
            $run = Invoke-InCulture -Culture 'en-US' -ScriptPath (Join-Path $script:Scripts 'Set-OpencodeGoFreshness.ps1') `
                -ScriptArgs @('-SeamPath', $seam, '-KeyNumber', '2', '-WeeklyUsed', '12', '-NoLog')

            $run.ExitCode | Should -Be 0 -Because $run.Output
            (Get-FileHash -LiteralPath $seam -Algorithm SHA256).Hash | Should -Be $before `
                -Because 'the seam is committed config and a vendored manifest row; a watch write must not modify it'
        }
    }

    Context 'reader: Get-OpencodeGoFreshness' {

        It 'reports an ambiguous stored date as cannot-evaluate, never a confident date' {
            $seam = New-LedgerFixture -Path (New-FixturePath) -RowResets '11/09/2026 00:00:00' `
                -MonthlyResets '11/09/2026 00:00:00'

            $run = Invoke-InCulture -Culture 'en-US' -ScriptPath (Join-Path $script:Scripts 'Get-OpencodeGoFreshness.ps1') `
                -ScriptArgs @('-SeamPath', $seam, '-Json')

            $run.ExitCode | Should -Be 0 -Because $run.Output
            $view = $run.Output | ConvertFrom-Json -DateKind String
            $key = @($view.keys)[0]

            # 11/09/2026 is 9 November under en-US and 11 September under en-GB:
            # the only honest answer is "cannot evaluate".
            $key.meters.monthly.resetsOnStatus | Should -Be 'ambiguous'
            $key.meters.monthly.cannotEvaluate | Should -BeTrue
            $key.meters.monthly.resetsOn | Should -BeNullOrEmpty
            $key.meters.monthly.resetsOnRaw | Should -Be '11/09/2026 00:00:00'
            $key.meters.monthly.nextRollover | Should -BeNullOrEmpty
            $key.meters.monthly.renewsInDays | Should -BeNullOrEmpty
            $key.cannotEvaluate | Should -BeTrue
            $key.resetsOnStatus | Should -Be 'ambiguous'
        }

        It 'normalises an unambiguous stored locale date' {
            $seam = New-LedgerFixture -Path (New-FixturePath) -RowResets '11/23/2026 23:43:24' `
                -MonthlyResets '11/23/2026 23:43:24' -ObservedAt '11/23/2026'

            $run = Invoke-InCulture -Culture 'en-US' -ScriptPath (Join-Path $script:Scripts 'Get-OpencodeGoFreshness.ps1') `
                -ScriptArgs @('-SeamPath', $seam, '-Json')

            $run.ExitCode | Should -Be 0 -Because $run.Output
            $key = @(($run.Output | ConvertFrom-Json -DateKind String).keys)[0]
            $key.meters.monthly.resetsOnStatus | Should -Be 'ok'
            $key.meters.monthly.resetsOn | Should -Be '2026-11-23T23:43:24'
            $key.meters.monthly.cannotEvaluate | Should -BeFalse
            $key.meters.monthly.nextRollover | Should -Not -BeNullOrEmpty
            $key.meters.monthly.observedAt | Should -Be '2026-11-23'
            $key.observedAt | Should -Be '2026-11-23'
        }

        It 'still resolves the real production asset' {
            $run = Invoke-InCulture -Culture 'en-US' -ScriptPath (Join-Path $script:Scripts 'Get-OpencodeGoFreshness.ps1') `
                -ScriptArgs @('-Json')

            $run.ExitCode | Should -Be 0 -Because $run.Output
            $view = $run.Output | ConvertFrom-Json -DateKind String
            $view.activeKey | Should -Match '^OPENCODE_GO\d+_KEY$'
            @($view.keys).Count | Should -BeGreaterOrEqual 1
            foreach ($k in @($view.keys)) {
                $k.state | Should -Not -BeNullOrEmpty
                $k.key | Should -Match '^OPENCODE_GO\d+_KEY$'
            }
        }
    }
}
