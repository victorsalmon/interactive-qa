#Requires -Version 7
<#
    Regression proof for Test-SingleHubRung.ps1 (bead cl-common-5wy).

    THE DEFECT THIS PINS. The guard counted every row with `status = active` as a
    competing rung, including a SPENT one-shot lane dispatch - a schedule whose
    `maxRuns` is reached, so it cannot fire again. A repo with exactly one live
    MERGE-TICK rung plus one finished lane dispatch therefore reported a duplicate
    and REFUSEd, which is a false alarm on the safest possible store: the lane it
    accuses has already run and is not a writer any more.

    The classification the fix must hold, measured against the real store shape
    (`%USERPROFILE%\.paseo\schedules`: `status`, `maxRuns`, `runs[]`):

      a rung COUNTS only while it can still fire
        => status active AND not spent (maxRuns > 0 and runs.Count >= maxRuns);
      a spent / paused / completed one-shot is TOLERATED
        => named in `tolerated`, never in `active`, never causes a refusal;
      a rung that is active and still has fires left KEEPS COUNTING
        => two of those still REFUSE, naming both ids.

    Run: pwsh -NoProfile -File vendor/iqa-merge/Tests/Test-SingleHubRung.Tests.ps1
#>
[CmdletBinding()]
param()

BeforeAll {
    $script:Guard = Join-Path (Split-Path -Parent $PSScriptRoot) 'Test-SingleHubRung.ps1'
    if (-not (Test-Path -LiteralPath $script:Guard -PathType Leaf)) {
        throw "Test-SingleHubRung.ps1 not found beside the Tests folder: $($script:Guard)"
    }
    $script:Pwsh = (Get-Command pwsh -ErrorAction Stop).Source

    function New-SpendedStore {
        param(
            [Parameter(Mandatory)][object[]]$Schedules
        )

        # One JSON record per file, the shape the daemon's store holds. The guard
        # reads a directory through the same reader the real store uses, so the
        # fixture exercises the path a Hub actually runs.
        $path = Join-Path $TestDrive ('schedules-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $path -Force | Out-Null
        $index = 0
        foreach ($schedule in $Schedules) {
            $index++
            $schedule | ConvertTo-Json -Depth 8 |
                Set-Content -LiteralPath (Join-Path $path ('{0:D2}-{1}.json' -f $index, $schedule.id)) -Encoding utf8
        }
        return $path
    }

    function Invoke-Rung {
        param([Parameter(Mandatory)][string[]]$Arguments)

        $stdout = & $script:Pwsh -NoProfile -File $script:Guard @Arguments -Json 2>&1
        $exitCode = $LASTEXITCODE
        $text = @($stdout | ForEach-Object { [string]$_ }) -join "`n"
        $json = $null
        try { $json = $text | ConvertFrom-Json -Depth 8 } catch { $json = $null }

        [pscustomobject]@{
            ExitCode = $exitCode
            Text     = $text
            Json     = $json
        }
    }

    function New-Rung {
        param(
            [Parameter(Mandatory)][string]$Id,
            [Parameter(Mandatory)][string]$Name,
            [string]$Status = 'active',
            [string]$Cron = '*/4 * * * *',
            [string]$Prompt = 'MERGE-TICK. Repo root: E:/Repos/cl-common',
            [AllowNull()][object]$MaxRuns = $null,
            [int]$RunCount = 0
        )

        $runs = @()
        for ($i = 1; $i -le $RunCount; $i++) {
            $runs += [ordered]@{ id = "run-$Id-$i"; status = 'succeeded' }
        }

        [ordered]@{
            id       = $Id
            name     = $Name
            status   = $Status
            cadence  = [ordered]@{ expression = $Cron }
            prompt   = $Prompt
            maxRuns  = $MaxRuns
            runs     = @($runs)
        }
    }
}

Describe 'Test-SingleHubRung: a spent one-shot is not a competing rung (cl-common-5wy)' {

    It 'PASSes and names only the live rung when a finished one-shot lane dispatch is in the store' {
        $store = New-SpendedStore -Schedules @(
            (New-Rung -Id 'aaaaaaa1' -Name 'hub-watch-cl-common' -Cron '*/4 * * * *')
            (New-Rung -Id 'bbbbbbb2' -Name 'lane-vendored-gate-m2' -Cron '0 3 * * *' -MaxRuns 1 -RunCount 1 `
                -Prompt 'One-shot lane dispatch. Read the MERGE-TICK contract, then run the gate. Repo root: E:/Repos/cl-common')
        )

        $result = Invoke-Rung -Arguments @('-Repo', 'cl-common', '-SchedulesPath', $store)

        $result.ExitCode | Should -Be 0 -Because 'one live rung is one writer; the spent one-shot cannot fire again'
        $result.Json.verdict | Should -Be 'PASS'
        @($result.Json.active.id) | Should -Be @('aaaaaaa1')
        @($result.Json.tolerated.id) | Should -Contain 'bbbbbbb2'
        $result.Text | Should -Not -Match 'duplicate'
    }

    It 'still REFUSEs and names both ids when two rungs are genuinely active' {
        $store = New-SpendedStore -Schedules @(
            (New-Rung -Id 'aaaaaaa1' -Name 'hub-watch-cl-common' -Cron '*/4 * * * *')
            (New-Rung -Id 'ccccccc3' -Name 'hub-watch-cl-common-backstop' -Cron '*/15 * * * *')
        )

        $result = Invoke-Rung -Arguments @('-Repo', 'cl-common', '-SchedulesPath', $store)

        $result.ExitCode | Should -Be 1 -Because 'two live rungs are two writers on one trunk'
        $result.Json.verdict | Should -Be 'REFUSE'
        $result.Text | Should -Match 'aaaaaaa1'
        $result.Text | Should -Match 'ccccccc3'
    }

    It 'keeps counting a one-shot that still has fires left' {
        $store = New-SpendedStore -Schedules @(
            (New-Rung -Id 'aaaaaaa1' -Name 'hub-watch-cl-common' -Cron '*/4 * * * *')
            (New-Rung -Id 'ddddddd4' -Name 'checkback-merge-kbt-109' -Cron '*/10 * * * *' -MaxRuns 3 -RunCount 2 `
                -Prompt 'MERGE-TICK checkback. Repo root: E:/Repos/cl-common')
        )

        $result = Invoke-Rung -Arguments @('-Repo', 'cl-common', '-SchedulesPath', $store)

        $result.ExitCode | Should -Be 1 -Because 'maxRuns 3 with 2 runs is still armed: it can fire again'
        @($result.Json.active.id) | Should -Contain 'ddddddd4'
    }

    It 'tolerates a paused and a completed one-shot without counting either' {
        $store = New-SpendedStore -Schedules @(
            (New-Rung -Id 'aaaaaaa1' -Name 'hub-watch-cl-common' -Cron '*/4 * * * *')
            (New-Rung -Id 'eeeeeee5' -Name 'hub-watch-cl-common-backstop' -Status 'paused')
            (New-Rung -Id 'fffffff6' -Name 'lane-jqf-keywatch-r2' -Status 'completed' -MaxRuns 1 -RunCount 1 `
                -Prompt 'One-shot lane. MERGE-TICK contract. Repo root: E:/Repos/cl-common')
        )

        $result = Invoke-Rung -Arguments @('-Repo', 'cl-common', '-SchedulesPath', $store)

        $result.ExitCode | Should -Be 0
        @($result.Json.active.id) | Should -Be @('aaaaaaa1')
        @($result.Json.tolerated.id) | Should -Contain 'eeeeeee5'
        @($result.Json.tolerated.id) | Should -Contain 'fffffff6'
    }

    It 'answers NO-RUNG when the only rung-class row left is spent' {
        $store = New-SpendedStore -Schedules @(
            (New-Rung -Id 'bbbbbbb2' -Name 'lane-vendored-gate-m2' -Cron '0 3 * * *' -MaxRuns 1 -RunCount 1 `
                -Prompt 'One-shot lane dispatch. MERGE-TICK contract. Repo root: E:/Repos/cl-common')
        )

        $result = Invoke-Rung -Arguments @('-Repo', 'cl-common', '-SchedulesPath', $store)

        $result.ExitCode | Should -Be 3 -Because 'a spent rung is not live coverage; the Hub must arm one'
        $result.Json.verdict | Should -Be 'NO-RUNG'
        @($result.Json.tolerated.id) | Should -Contain 'bbbbbbb2'
    }
}
