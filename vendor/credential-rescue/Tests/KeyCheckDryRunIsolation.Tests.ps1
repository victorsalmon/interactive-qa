#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0.0' }

<#
.SYNOPSIS
    cl-common-jqm: a -DryRun probe must be physically incapable of mutating a
    LIVE run's state.

.DESCRIPTION
    Measured incident (2026-11-03 11:09:10 PT, live run 20261103-080748): a
    dry-run probe resumed the live runId and appended a `resume` row plus a
    terminal `end` row (decision=end, reason=max-checks, checks=5, dryRun=true)
    to the live ledger, then rewrote the live state.json with endedAt/endReason/
    exitCode. The real watch (pid 47628, no -DryRun) was still alive and beating,
    so every reader of state.json saw `ended` for a watch that had not ended.

    The contract pinned here:

      - a dry run has its OWN run id (never the live run's) and writes its
        state/audit only under `<state dir>\dryrun\`;
      - the live state.json, lock.json and audit ledger are byte-identical
        before and after a dry probe - even a run that clears max-checks;
      - the live run keeps its ledger semantics: it still records its own
        `end` normally after a dry probe has happened;
      - a reader of the live state (Test-KeyCheckLiveness) still sees the live
        run's real phase and cadence, never the rehearsal.

    Every test works in TestDrive. The live ~/.machine/state/key-check files are
    never read or written.
#>

BeforeAll {
    $script:SkillRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
    $script:ScriptPath = Join-Path $script:SkillRoot 'scripts\Invoke-KeyCheck.ps1'
    $script:LivenessPath = Join-Path $script:SkillRoot 'scripts\Test-KeyCheckLiveness.ps1'
    $script:PwshExe = Join-Path $PSHOME 'pwsh.exe'
    $script:LiveRunId = '20261103-080748'

    function New-DryRunFixture {
        <#
        .SYNOPSIS
            A temp fixture whose LIVE run is mid-flight: state + lock + one
            already-written ledger row, all inside TestDrive.
        #>
        param(
            [int]$LivePid = $PID,
            [switch]$NoLock
        )
        $dir = Join-Path $TestDrive ("jqm-{0}" -f ([guid]::NewGuid().ToString('N')))
        $null = New-Item -ItemType Directory -Path $dir -Force

        $keysPath = Join-Path $dir 'keys.json'
        @{ inUse = 'live-key-1'; keys = @{ GO1 = 'live-key-1'; GO2 = 'live-key-2'; GO3 = 'live-key-3' } } |
            ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $keysPath

        $usagePath = Join-Path $dir 'usage.json'
        @{
            GO1 = @{ weekly = @{ percent = 10; status = 'ok'; resetsAt = '2026-11-09T00:00' }
                monthly = @{ percent = 20; status = 'ok'; resetsAt = '2026-11-20' } }
            GO2 = @{ weekly = @{ percent = 5; status = 'ok'; resetsAt = '2026-11-09T00:00' }
                monthly = @{ percent = 15; status = 'ok'; resetsAt = '2026-11-20' } }
            GO3 = @{ weekly = @{ percent = 0; status = 'ok'; resetsAt = '2026-11-09T00:00' }
                monthly = @{ percent = 10; status = 'ok'; resetsAt = '2026-11-09' } }
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $usagePath

        $statePath = Join-Path $dir 'state.json'
        $auditPath = Join-Path $dir 'keycheck.jsonl'
        $lockPath = Join-Path $dir 'lock.json'
        $now = Get-Date

        $liveState = [ordered]@{
            runId                     = $script:LiveRunId
            startedAt                 = $now.AddMinutes(-10).ToString('o')
            deadline                  = $now.AddMinutes(20).ToString('o')
            deadlineAt                = $now.AddMinutes(20).ToString('o')
            intervalMinutes           = 15
            durationHours             = 0.5
            phase                     = 'heartbeat'
            activeKeyNumber           = 1
            replacementKeyNumber      = 0
            replacementKey            = 0
            simulatedActiveKeyNumber  = 0
            generation                = 0
            checks                    = 4
            lastCheckAt               = $now.AddMinutes(-2).ToString('o')
            lastResult                = 'heartbeat (watching)'
            consecutiveRateLimited    = 0
            consecutiveCannotEvaluate = 0
            consecutiveBelowThreshold = 0
            armed                     = $false
            evidence                  = @('live run mid-flight')
            dryRun                    = $false
            cutovers                  = @()
            usageSource               = 'fixture'
            endedAt                   = $null
            endReason                 = ''
            exitCode                  = 0
        }
        ($liveState | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $statePath -Encoding utf8NoBOM

        if (-not $NoLock) {
            @{
                pid         = [int]$LivePid
                host        = $env:COMPUTERNAME
                runId       = $script:LiveRunId
                startedAt   = $now.AddMinutes(-10).ToString('o')
                heartbeatAt = $now.ToString('o')
            } | ConvertTo-Json -Compress | Set-Content -LiteralPath $lockPath -Encoding utf8NoBOM
        }

        # The live run has already written its own ledger row.
        @{
            ts = $now.AddMinutes(-2).ToString('s'); runId = $script:LiveRunId; kind = 'check'
            phase = 'heartbeat'; generation = 0; key = 'GO1'; wk = 10; mo = 20
            decision = 'heartbeat'; reason = 'watching'; dryRun = $false
        } | ConvertTo-Json -Compress | Set-Content -LiteralPath $auditPath -Encoding utf8NoBOM

        [pscustomobject]@{
            Dir         = $dir
            KeysPath    = $keysPath
            UsagePath   = $usagePath
            StatePath   = $statePath
            AuditPath   = $auditPath
            LockPath    = $lockPath
            DryDir      = Join-Path $dir 'dryrun'
            DryState    = Join-Path (Join-Path $dir 'dryrun') 'state.json'
            DryAudit    = Join-Path (Join-Path $dir 'dryrun') 'keycheck.jsonl'
        }
    }

    function Invoke-KeyCheckCli {
        param($Fixture, [string[]]$ExtraArgs = @(), [string]$StatePathOverride = '')
        $cliArgs = @(
            '-NoProfile', '-File', $script:ScriptPath,
            '-UsageFile', $Fixture.UsagePath,
            '-KeyValuesFile', $Fixture.KeysPath,
            '-StatePath', $(if ($StatePathOverride) { $StatePathOverride } else { $Fixture.StatePath }),
            '-AuditPath', $Fixture.AuditPath,
            '-SkipDrift', '-NoWait', '-NoRecovery',
            '-IntervalMinutes', '15', '-DurationHours', '0.5'
        )
        $cliArgs += $ExtraArgs
        $output = & $script:PwshExe @cliArgs 2>&1 | Out-String
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
    }

    function Get-BytesHash {
        param([string]$Path)
        if (-not (Test-Path -LiteralPath $Path)) { return '<absent>' }
        return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    }

    function Read-Jsonl {
        param([string]$Path)
        if (-not (Test-Path -LiteralPath $Path)) { return @() }
        return @(Get-Content -LiteralPath $Path | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
    }
}

Describe 'Key Check dry-run isolation (cl-common-jqm)' {

    It 'leaves the live state, lock and ledger byte-identical when a dry probe resumes the live run' {
        $fixture = New-DryRunFixture
        $stateBefore = Get-BytesHash -Path $fixture.StatePath
        $lockBefore = Get-BytesHash -Path $fixture.LockPath
        $auditBefore = Get-BytesHash -Path $fixture.AuditPath
        $liveAuditRowsBefore = @(Read-Jsonl -Path $fixture.AuditPath).Count

        $run = Invoke-KeyCheckCli -Fixture $fixture -ExtraArgs @('-DryRun', '-SkipCanary', '-MaxChecks', '2')

        $run.ExitCode | Should -Be 0 -Because $run.Output

        # 1. the LIVE artefacts are untouched, byte for byte
        (Get-BytesHash -Path $fixture.StatePath) | Should -Be $stateBefore `
            -Because 'a dry run must never rewrite the live run state'
        (Get-BytesHash -Path $fixture.LockPath) | Should -Be $lockBefore `
            -Because 'a dry run must never take or rewrite the live lock'
        (Get-BytesHash -Path $fixture.AuditPath) | Should -Be $auditBefore `
            -Because 'a dry run must never append to the live ledger'
        @(Read-Jsonl -Path $fixture.AuditPath).Count | Should -Be $liveAuditRowsBefore

        # 2. the live state still describes a watch in flight
        $live = Get-Content -LiteralPath $fixture.StatePath -Raw | ConvertFrom-Json
        $live.runId | Should -Be $script:LiveRunId
        $live.phase | Should -Be 'heartbeat'
        $live.endReason | Should -Be ''
        $live.endedAt | Should -BeNullOrEmpty
        $live.checks | Should -Be 4 -Because 'the dry probe did not advance the live run'
    }

    It 'writes its own artefact under dryrun/, labelled dryRun with its own run id' {
        $fixture = New-DryRunFixture
        $run = Invoke-KeyCheckCli -Fixture $fixture -ExtraArgs @('-DryRun', '-SkipCanary', '-MaxChecks', '2')
        $run.ExitCode | Should -Be 0 -Because $run.Output

        Test-Path -LiteralPath $fixture.DryState | Should -BeTrue `
            -Because 'the probe still has to leave evidence of what it decided'
        Test-Path -LiteralPath $fixture.DryAudit | Should -BeTrue

        $dry = Get-Content -LiteralPath $fixture.DryState -Raw | ConvertFrom-Json
        $dry.dryRun | Should -BeTrue
        $dry.runId | Should -Not -Be $script:LiveRunId `
            -Because 'a dry run may not share the live run id'
        $dry.runId | Should -Match '\-dryrun$'
        $dry.endReason | Should -Be 'max-checks'

        $dryRows = @(Read-Jsonl -Path $fixture.DryAudit)
        $dryRows.Count | Should -BeGreaterThan 0
        @($dryRows | Where-Object { $_.runId -eq $script:LiveRunId }).Count | Should -Be 0 `
            -Because 'no dry row may be written as the live run'
        @($dryRows | Where-Object { $_.dryRun -ne $true }).Count | Should -Be 0 `
            -Because 'every dry-run row must be self-labelled'

        # The rehearsal still reuses the live run as CONTEXT (same window, same phase).
        ([datetime]$dry.startedAt).ToString('o') |
            Should -Be ([datetime](Get-Content -LiteralPath $fixture.StatePath -Raw | ConvertFrom-Json).startedAt).ToString('o')
    }

    It 'never creates a live artefact when a fresh dry run is the only run' {
        $fixture = New-DryRunFixture -NoLock
        Remove-Item -LiteralPath $fixture.StatePath, $fixture.AuditPath -Force

        $run = Invoke-KeyCheckCli -Fixture $fixture -ExtraArgs @('-DryRun', '-SkipCanary', '-MaxChecks', '1')
        $run.ExitCode | Should -Be 0 -Because $run.Output

        Test-Path -LiteralPath $fixture.StatePath | Should -BeFalse
        Test-Path -LiteralPath $fixture.AuditPath | Should -BeFalse
        Test-Path -LiteralPath $fixture.DryState | Should -BeTrue
    }

    It 'still lets the live run record its own end after a dry probe' {
        $fixture = New-DryRunFixture -NoLock

        $dry = Invoke-KeyCheckCli -Fixture $fixture -ExtraArgs @('-DryRun', '-SkipCanary', '-MaxChecks', '2')
        $dry.ExitCode | Should -Be 0 -Because $dry.Output

        $live = Invoke-KeyCheckCli -Fixture $fixture -ExtraArgs @('-SkipCanary', '-NoLedger', '-MaxChecks', '2')
        $live.ExitCode | Should -Be 0 -Because $live.Output

        $state = Get-Content -LiteralPath $fixture.StatePath -Raw | ConvertFrom-Json
        $state.runId | Should -Be $script:LiveRunId
        $state.endReason | Should -Be 'max-checks'
        $state.exitCode | Should -Be 0
        $state.dryRun | Should -BeFalse

        $end = @(Read-Jsonl -Path $fixture.AuditPath | Where-Object { $_.kind -eq 'end' })
        $end.Count | Should -Be 1
        $end[0].runId | Should -Be $script:LiveRunId
        $end[0].dryRun | Should -BeFalse
        Test-Path -LiteralPath $fixture.LockPath | Should -BeFalse -Because 'a finished run releases its lock'
    }

    It 'keeps liveness reading the live run, never the dry artefact' {
        $fixture = New-DryRunFixture
        $dry = Invoke-KeyCheckCli -Fixture $fixture -ExtraArgs @('-DryRun', '-SkipCanary', '-MaxChecks', '2')
        $dry.ExitCode | Should -Be 0 -Because $dry.Output

        $raw = & $script:PwshExe -NoProfile -File $script:LivenessPath -StatePath $fixture.StatePath -Json 2>&1 | Out-String
        $report = $raw | ConvertFrom-Json

        $report.status | Should -Be 'live'
        $report.runId | Should -Be $script:LiveRunId
        $report.phase | Should -Be 'heartbeat'
        $report.endReason | Should -Be ''
        $report.lock.runId | Should -Be $script:LiveRunId
    }

    It 'refuses to answer liveness from a dry artefact even when pointed at one' {
        $fixture = New-DryRunFixture
        $dry = Invoke-KeyCheckCli -Fixture $fixture -ExtraArgs @('-DryRun', '-SkipCanary', '-MaxChecks', '2')
        $dry.ExitCode | Should -Be 0 -Because $dry.Output

        $raw = & $script:PwshExe -NoProfile -File $script:LivenessPath -StatePath $fixture.DryState -Json 2>&1 | Out-String
        $exit = $LASTEXITCODE
        $report = $raw | ConvertFrom-Json

        $exit | Should -Be 2 -Because 'cannot-evaluate is a non-zero, never a pass'
        $report.status | Should -Be 'cannot-evaluate'
        $report.reason | Should -Be 'dry-run-state'
        $report.detail | Should -Match 'dryRun'
    }
}
