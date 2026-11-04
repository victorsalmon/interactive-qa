#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0.0' }

<#
.SYNOPSIS
    Pester tests for Invoke-KeyCheck.ps1 (Key Check) and the pure decision
    helpers in lib/KeyCheck.Decision.ps1.

.DESCRIPTION
    Key Check exists so a key is replaced BEFORE it dies, on a fixed wall-clock
    budget, without ever printing a key value. The contract under test:

      - the deadline is fixed at start and never extended by a phase;
      - a replacement is eligible only at wk < 80 AND mo < 90 (both metres);
      - eligible targets rank by soonest MONTHLY reset; weekly resets are shared
        and never rank; ties break on the lowest key number;
      - the near phase escalates at wk > 96 / mo > 98 / rate-limited;
      - rescue is idempotent (active == replacement => no cutover);
      - post-rescue: final reading recorded, new active key, SAME deadline,
        generation + 1;
      - -DryRun decides and audits but never cuts over and never writes the
        ledger;
      - no run output, state or audit line ever contains a key value.

    No test performs a real cutover or writes the freshness ledger.
#>

BeforeAll {
    $script:SkillRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
    $script:ScriptPath = Join-Path $script:SkillRoot 'scripts\Invoke-KeyCheck.ps1'
    $script:SeamPath = Join-Path $script:SkillRoot 'assets\opencode-go-cutover.json'
    $script:PwshExe = Join-Path $PSHOME 'pwsh.exe'

    . (Join-Path $script:SkillRoot 'scripts\lib\KeyCheck.Decision.ps1')
    . (Join-Path $script:SkillRoot 'scripts\lib\KeyCheck.State.ps1')
    . (Join-Path $script:SkillRoot '..\aws\scripts\SecretFingerprint.ps1')

    function New-Reading {
        param(
            [int]$KeyNumber,
            $Weekly = 0,
            $Monthly = 0,
            [string]$WeeklyResets = '2026-11-09T00:00',
            [string]$MonthlyResets = '2026-11-20',
            [string]$WeeklyStatus = 'ok',
            [string]$MonthlyStatus = 'ok'
        )
        [pscustomobject]@{
            KeyNumber = $KeyNumber
            Label     = "GO$KeyNumber"
            Weekly    = [pscustomobject]@{ Percent = $Weekly; Status = $WeeklyStatus; ResetsAt = $WeeklyResets }
            Monthly   = [pscustomobject]@{ Percent = $Monthly; Status = $MonthlyStatus; ResetsAt = $MonthlyResets }
        }
    }

    function New-KeyCheckFixture {
        <#
        .SYNOPSIS
            Write a key-value fixture, a usage-map fixture, and unique state /
            audit paths into TestDrive.
        #>
        param(
            [hashtable]$Keys,
            [string]$InUse,
            [hashtable]$Usage,
            [string]$CanaryScript,
            [string]$RepairScript,
            [string]$SwitchScript,
            [string]$CutoverScript
        )
        $dir = Join-Path $TestDrive ("kc-{0}" -f ([guid]::NewGuid().ToString('N')))
        $null = New-Item -ItemType Directory -Path $dir -Force

        $keysPath = Join-Path $dir 'keys.json'
        @{ inUse = $InUse; keys = $Keys } | ConvertTo-Json -Depth 5 |
            Set-Content -LiteralPath $keysPath

        $usagePath = Join-Path $dir 'usage.json'
        $map = @{}
        foreach ($k in $Usage.Keys) { $map[$k] = $Usage[$k] }
        $map | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $usagePath

        [pscustomobject]@{
            Dir         = $dir
            KeysPath    = $keysPath
            UsagePath   = $usagePath
            StatePath   = Join-Path $dir 'state.json'
            AuditPath   = Join-Path $dir 'keycheck.jsonl'
            CanaryPath  = $CanaryScript
            RepairPath  = $RepairScript
            SwitchPath  = $SwitchScript
            CutoverPath = $CutoverScript
            CutoverLog  = Join-Path $dir 'cutover-occurred.txt'
            MarkerPath  = Join-Path $dir 'repair-marker.txt'
        }
    }

    function New-CanaryStub {
        param([string]$Dir, [string]$Verdict = 'OK')
        $path = Join-Path $Dir 'canary-stub.ps1'
        @"
param([int]`$KeyNumber = 0)
if ('$Verdict' -eq 'OK') { Write-Output 'OK opencode-go/deepseek-v4.1-flash'; exit 0 }
Write-Output '$Verdict opencode-go/deepseek-v4.1-flash: stub'; exit 1
"@ | Set-Content -LiteralPath $path
        return $path
    }

    function New-RepairStub {
        param([string]$Dir)
        $path = Join-Path $Dir 'repair-stub.ps1'
        @'
param([int]$KeyNumber = 0)
if ($env:KEYCHECK_TEST_MARKER) { "GO$KeyNumber" | Set-Content -LiteralPath $env:KEYCHECK_TEST_MARKER }
Write-Output "repair-stub: pinned GO$KeyNumber"
exit 0
'@ | Set-Content -LiteralPath $path
        return $path
    }

    function New-SwitchStub {
        param([string]$Dir)
        $path = Join-Path $Dir 'switch-stub.ps1'
        @'
param([int]$KeyNumber = 0)
Write-Output "switch-stub: repointed GO$KeyNumber"
exit 0
'@ | Set-Content -LiteralPath $path
        return $path
    }

    function New-CutoverStub {
        <#
        .SYNOPSIS
            A detached-cutover stand-in: writes the outcome JSON the real helper
            writes, so the watch's delegation path can be exercised without a
            credential change or a Paseo restart.
        .DESCRIPTION
            The log path is baked into the script text because the helper is now
            created through Win32_Process.Create, which does NOT inherit this
            process's environment - an env-var seam would silently stop proving
            that the helper ran.
        #>
        param([string]$Dir, [switch]$Applied, [switch]$Verified, [string]$LogPath = '')
        $path = Join-Path $Dir 'cutover-stub.ps1'
        $appliedValue = if ($Applied) { '$true' } else { '$false' }
        $verifiedValue = if ($Verified) { '$true' } else { '$false' }
        $logLine = if ($LogPath) { "`"cutover GO`$KeyNumber (pid `$PID)`" | Set-Content -LiteralPath '$LogPath'" } else { '' }
        @"
param(
    [int]`$KeyNumber = 0,
    [string]`$OutcomePath = '',
    [string]`$RunId = '',
    [string]`$SwitchScript = '',
    [string]`$RepairScript = '',
    [int]`$TimeoutSeconds = 0
)
$logLine
Start-Sleep -Milliseconds 50
`$outcome = [ordered]@{
    applied   = $appliedValue
    verified  = $verifiedValue
    at        = (Get-Date).ToString('o')
    runId     = `$RunId
    keyNumber = `$KeyNumber
    steps     = @()
    surfaces  = @(
        [ordered]@{ name = 'seam'; expected = "OPENCODE_GO`${KeyNumber}_KEY"; actual = "OPENCODE_GO`${KeyNumber}_KEY"; ok = $verifiedValue }
    )
}
`$outcome | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath `$OutcomePath
if ($verifiedValue) { exit 0 } else { exit 5 }
"@ | Set-Content -LiteralPath $path
        return $path
    }

    function Invoke-KeyCheck {
        param(
            $Fixture,
            [string[]]$ExtraArgs = @(),
            [int]$IntervalMinutes = 1,
            [double]$DurationHours = 0.02
        )

        $cliArgs = @(
            '-NoProfile', '-File', $script:ScriptPath,
            '-UsageFile', $Fixture.UsagePath,
            '-KeyValuesFile', $Fixture.KeysPath,
            '-StatePath', $Fixture.StatePath,
            '-AuditPath', $Fixture.AuditPath,
            '-SkipDrift', '-NoWait',
            '-IntervalMinutes', "$IntervalMinutes", '-DurationHours', "$DurationHours"
        )
        if ($Fixture.CanaryPath) { $cliArgs += @('-CanaryScript', $Fixture.CanaryPath) }
        if ($Fixture.RepairPath) { $cliArgs += @('-RepairScript', $Fixture.RepairPath) }
        if ($Fixture.SwitchPath) { $cliArgs += @('-SwitchScript', $Fixture.SwitchPath) }
        if ($Fixture.CutoverPath) { $cliArgs += @('-CutoverScript', $Fixture.CutoverPath) }
        $cliArgs += $ExtraArgs

        $output = & $script:PwshExe @cliArgs 2>&1 | Out-String
        # A -DryRun probe writes its own artefact under <dir>\dryrun\ (cl-common-jqm);
        # the run's State/Audit are that probe's output, and StatePath/AuditPath
        # stay the LIVE paths so a test can prove they were left untouched.
        $isDry = ($ExtraArgs -contains '-DryRun')
        $stateFile = if ($isDry) { Join-Path (Join-Path $Fixture.Dir 'dryrun') 'state.json' } else { $Fixture.StatePath }
        $auditFile = if ($isDry) { Join-Path (Join-Path $Fixture.Dir 'dryrun') 'keycheck.jsonl' } else { $Fixture.AuditPath }
        $state = $null
        if (Test-Path -LiteralPath $stateFile) {
            $state = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
        }
        $audit = @()
        if (Test-Path -LiteralPath $auditFile) {
            $audit = @(Get-Content -LiteralPath $auditFile | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
        }
        [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Output   = $output
            State    = $state
            Audit    = $audit
            RawState = if ($state) { Get-Content -LiteralPath $stateFile -Raw } else { '' }
        }
    }

    function Get-SeamHash { (Get-FileHash -LiteralPath $script:SeamPath -Algorithm SHA256).Hash }

    function Get-ProtectedSurfaces {
        <#
        .SYNOPSIS
            Fingerprints of every surface a cutover may touch, so a -DryRun can
            be proven to have changed none of them. Values never leave this
            function - only hashes and line counts.
        #>
        $auth = '<absent>'
        $dataHome = [Environment]::GetEnvironmentVariable('XDG_DATA_HOME', 'User')
        if (-not $dataHome) { $dataHome = [Environment]::GetEnvironmentVariable('XDG_DATA_HOME', 'Process') }
        if ($dataHome) {
            $authPath = Join-Path $dataHome 'opencode\auth.json'
            if (Test-Path -LiteralPath $authPath) { $auth = (Get-FileHash -LiteralPath $authPath -Algorithm SHA256).Hash }
        }
        $credLog = if ($env:CL_REPOS_ROOT) { Join-Path $env:CL_REPOS_ROOT 'Tasks\Logs\credential-changes.jsonl' } else { '' }
        $credLogLines = if ($credLog -and (Test-Path -LiteralPath $credLog)) { (Get-Content -LiteralPath $credLog | Measure-Object -Line).Lines } else { -1 }
        [pscustomobject]@{
            Seam             = Get-SeamHash
            AuthJson         = $auth
            UserGoKey        = (Get-SecretFingerprint ([Environment]::GetEnvironmentVariable('OPENCODE_GO_KEY', 'User'))).Sha256
            UserApiKey       = (Get-SecretFingerprint ([Environment]::GetEnvironmentVariable('OPENCODE_API_KEY', 'User'))).Sha256
            CredentialLogLen = $credLogLines
        } | ConvertTo-Json -Compress
    }
}

Describe 'Key Check decisions' {

    It 'fixes the deadline at start and ends the run on it' {
        $start = [datetime]'2026-11-02T10:00:00'
        $deadline = Get-KeyCheckDeadline -Start $start -DurationHours 2
        $deadline | Should -Be $start.AddHours(2)

        $imminent = New-Reading -KeyNumber 1 -Weekly 99 -Monthly 99
        (Get-KeyCheckNextPhase -Phase 'near' -Now $deadline -Deadline $deadline `
                -Reading $imminent -ReplacementKeyNumber 2).Phase | Should -Be 'end'
        (Get-KeyCheckNextPhase -Phase 'near' -Now $deadline.AddSeconds(-1) -Deadline $deadline `
                -Reading $imminent -ReplacementKeyNumber 2).Phase | Should -Be 'trigger'
    }

    It 'never treats a spent monthly term as an eligible target (GO5 0wk/100mo)' {
        Test-KeyCheckEligible -Reading (New-Reading -KeyNumber 5 -Weekly 0 -Monthly 100 -MonthlyStatus 'rate-limited') |
            Should -BeFalse
    }

    It 'requires BOTH metres under the caps' {
        Test-KeyCheckEligible -Reading (New-Reading -KeyNumber 1 -Weekly 79.9 -Monthly 89.9) | Should -BeTrue
        Test-KeyCheckEligible -Reading (New-Reading -KeyNumber 1 -Weekly 80 -Monthly 0) | Should -BeFalse
        Test-KeyCheckEligible -Reading (New-Reading -KeyNumber 1 -Weekly 0 -Monthly 90) | Should -BeFalse
        Test-KeyCheckEligible -Reading (New-Reading -KeyNumber 1 -Weekly $null -Monthly 10) | Should -BeFalse
    }

    It 'names the HTTP fact that excluded a key, never a bare meter-not-reported' {
        # A 429/403/5xx row measures nothing, so the exclusion reason must name
        # what the endpoint said. "meter-not-reported" is reserved for a 200.
        $cases = @(
            @{ Code = 429; Rule = 'rate-limited' }
            @{ Code = 401; Rule = 'usage-FORBIDDEN' }
            @{ Code = 403; Rule = 'usage-FORBIDDEN' }
            @{ Code = 500; Rule = 'usage-HTTP500' }
            @{ Code = 502; Rule = 'usage-HTTP502' }
        )
        foreach ($case in $cases) {
            $row = [pscustomobject]@{ Key = 'GO7'; Http = $case.Code; Verdict = "HTTP $($case.Code)"; Weekly = $null; Monthly = $null }
            $reading = ConvertTo-KeyCheckReading -Row $row
            (Get-KeyCheckExclusionReason -Reading $reading) | Should -Be $case.Rule -Because "HTTP $($case.Code)"
        }

        $ok = [pscustomobject]@{ Key = 'GO7'; Http = 200; Verdict = ''; Weekly = $null; Monthly = $null }
        (Get-KeyCheckExclusionReason -Reading (ConvertTo-KeyCheckReading -Row $ok)) | Should -Be 'meter-not-reported'
    }

    It 'ranks eligible targets by the soonest monthly reset' {
        $readings = @(
            (New-Reading -KeyNumber 2 -Weekly 10 -Monthly 40 -MonthlyResets '2026-11-20'),
            (New-Reading -KeyNumber 3 -Weekly 0 -Monthly 20 -MonthlyResets '2026-11-09'),
            (New-Reading -KeyNumber 4 -Weekly 5 -Monthly 30 -MonthlyResets '2026-11-13')
        )
        (Get-KeyCheckReplacement -Readings $readings -ExcludeKeyNumber 1).KeyNumber | Should -Be 3
    }

    It 'breaks a monthly-reset tie on the lowest key number' {
        $readings = @(
            (New-Reading -KeyNumber 5 -Weekly 0 -Monthly 10 -MonthlyResets '2026-11-09'),
            (New-Reading -KeyNumber 2 -Weekly 0 -Monthly 10 -MonthlyResets '2026-11-09')
        )
        (Get-KeyCheckReplacement -Readings $readings).KeyNumber | Should -Be 2
    }

    It 'ignores the weekly reset when ranking (it is a shared boundary)' {
        $baseline = @(
            (New-Reading -KeyNumber 2 -Weekly 0 -Monthly 20 -MonthlyResets '2026-11-20' -WeeklyResets '2026-11-09T00:00'),
            (New-Reading -KeyNumber 3 -Weekly 0 -Monthly 20 -MonthlyResets '2026-11-09' -WeeklyResets '2026-11-09T00:00')
        )
        $noisy = @(
            (New-Reading -KeyNumber 2 -Weekly 0 -Monthly 20 -MonthlyResets '2026-11-20' -WeeklyResets '2026-11-01T00:00'),
            (New-Reading -KeyNumber 3 -Weekly 0 -Monthly 20 -MonthlyResets '2026-11-09' -WeeklyResets '2026-12-01T00:00')
        )
        (Get-KeyCheckReplacement -Readings $baseline).KeyNumber | Should -Be 3
        (Get-KeyCheckReplacement -Readings $noisy).KeyNumber | Should -Be 3
    }

    It 'escalates the heartbeat at 80 wk / 90 mo and the near loop at 96 wk / 98 mo' {
        $deadline = [datetime]'2026-11-02T12:00:00'
        $now = [datetime]'2026-11-02T10:00:00'
        (Get-KeyCheckNextPhase -Phase 'heartbeat' -Now $now -Deadline $deadline `
                -Reading (New-Reading -KeyNumber 1 -Weekly 79 -Monthly 10)).Phase | Should -Be 'heartbeat'
        (Get-KeyCheckNextPhase -Phase 'heartbeat' -Now $now -Deadline $deadline `
                -Reading (New-Reading -KeyNumber 1 -Weekly 80 -Monthly 10)).Phase | Should -Be 'discover'
        (Get-KeyCheckNextPhase -Phase 'heartbeat' -Now $now -Deadline $deadline `
                -Reading (New-Reading -KeyNumber 1 -Weekly 0 -Monthly 90)).Phase | Should -Be 'discover'

        (Get-KeyCheckNextPhase -Phase 'near' -Now $now -Deadline $deadline `
                -Reading (New-Reading -KeyNumber 1 -Weekly 96 -Monthly 98) -ReplacementKeyNumber 3).Phase | Should -Be 'near'
        (Get-KeyCheckNextPhase -Phase 'near' -Now $now -Deadline $deadline `
                -Reading (New-Reading -KeyNumber 1 -Weekly 97 -Monthly 10) -ReplacementKeyNumber 3).Phase | Should -Be 'trigger'
        # E2: ONE rate-limited read is pressure, not death. Only the second
        # consecutive one may move the machine onto a fresh key.
        (Get-KeyCheckNextPhase -Phase 'near' -Now $now -Deadline $deadline `
                -Reading (New-Reading -KeyNumber 1 -Weekly 0 -Monthly 0 -MonthlyStatus 'rate-limited') `
                -ReplacementKeyNumber 3 -ConsecutiveRateLimited 1).Phase | Should -Be 'near'
        (Get-KeyCheckNextPhase -Phase 'near' -Now $now -Deadline $deadline `
                -Reading (New-Reading -KeyNumber 1 -Weekly 0 -Monthly 0 -MonthlyStatus 'rate-limited') `
                -ReplacementKeyNumber 3 -ConsecutiveRateLimited 2).Phase | Should -Be 'trigger'
    }

    It 'is idempotent when the active key already is the replacement' {
        (Get-KeyCheckTriggerDecision -ActiveKeyNumber 3 -ReplacementKeyNumber 3).Action | Should -Be 'none'
        (Get-KeyCheckTriggerDecision -ActiveKeyNumber 1 -ReplacementKeyNumber 3).Action | Should -Be 'cutover'
        (Get-KeyCheckTriggerDecision -ActiveKeyNumber 1 -ReplacementKeyNumber 0).Action | Should -Be 'none'
    }

    It 'records post-rescue bookkeeping on a copy and keeps the deadline verbatim' {
        $before = [pscustomobject]@{
            runId = 'r1'; startedAt = '2026-11-02T10:00:00.0000000-07:00'
            deadline = '2026-11-02T12:00:00.0000000-07:00'
            phase = 'trigger'; activeKeyNumber = 1; replacementKeyNumber = 3
            generation = 0; checks = 7; evidence = @('started')
        }
        $final = New-Reading -KeyNumber 1 -Weekly 100 -Monthly 99
        $after = Update-KeyCheckAfterCutover -State $before -FromKeyNumber 1 -ToKeyNumber 3 -Reading $final

        $after.generation | Should -Be 1
        $after.activeKeyNumber | Should -Be 3
        $after.replacementKeyNumber | Should -Be 0
        ([datetimeoffset]$after.deadline).UtcTicks | Should -Be ([datetimeoffset]$before.deadline).UtcTicks
        $after.lastReading.KeyNumber | Should -Be 1
        $after.evidence[-1] | Should -Match 'cutover GO1 -> GO3'
        $before.generation | Should -Be 0
        $before.activeKeyNumber | Should -Be 1
    }

    It 'normalizes a JSON-retyped timestamp back to ISO (never a locale date)' {
        $row = [pscustomobject]@{
            Key     = 'GO5'
            Weekly  = [pscustomobject]@{ percent = 0; status = 'ok'; resetsAt = [datetime]'2026-11-09T00:00:00' }
            Monthly = [pscustomobject]@{ percent = 99; status = 'ok'; resetsAt = [datetime]'2026-12-02T00:18:32' }
        }
        $reading = ConvertTo-KeyCheckReading -Row $row
        $reading.Weekly.ResetsAt | Should -Be '2026-11-09T00:00:00'
        $reading.Monthly.ResetsAt | Should -Be '2026-12-02T00:18:32'
    }

    It 'abbreviates the metres as wk and mo, never w or m' {
        (Format-KeyCheckReading -Reading (New-Reading -KeyNumber 6 -Weekly 47 -Monthly 23) -Tag 'active') |
            Should -Be 'GO6 (active) 47wk/23mo - healthy'
        (Format-KeyCheckReading -Reading (New-Reading -KeyNumber 4 -Weekly 0 -Monthly 97)) |
            Should -Be 'GO4 0wk/97mo - near-cap'
    }
}

Describe 'Invoke-KeyCheck' {

    It 'rejects invalid grammar with exit 2' {
        $output = & $script:PwshExe -NoProfile -File $script:ScriptPath -IntervalMinutes 0 -DurationHours 0 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 2 -Because $output
        $output | Should -Match 'Key Check \[minutes\] \[hours\]'
    }

    It 'runs the escalation ladder under -DryRun without a cutover or a ledger write' {
        $seamBefore = Get-SeamHash
        $fixture = New-KeyCheckFixture -InUse 'dry-key-1' -Keys @{
            GO1 = 'dry-key-1'; GO2 = 'dry-key-2'; GO3 = 'dry-key-3'
        } -Usage @{
            GO1 = @{ weekly = @{ percent = 99; status = 'ok'; resetsAt = '2026-11-09T00:00' }
                monthly = @{ percent = 99; status = 'ok'; resetsAt = '2026-11-20' } }
            GO2 = @{ weekly = @{ percent = 10; status = 'ok'; resetsAt = '2026-11-09T00:00' }
                monthly = @{ percent = 40; status = 'ok'; resetsAt = '2026-11-20' } }
            GO3 = @{ weekly = @{ percent = 0; status = 'ok'; resetsAt = '2026-11-09T00:00' }
                monthly = @{ percent = 20; status = 'ok'; resetsAt = '2026-11-09' } }
        }

        $run = Invoke-KeyCheck -Fixture $fixture -ExtraArgs @('-DryRun', '-SkipCanary', '-MaxChecks', '8')

        $run.ExitCode | Should -Be 0 -Because $run.Output
        $run.State.dryRun | Should -BeTrue
        $run.State.activeKeyNumber | Should -Be 1
        $run.State.simulatedActiveKeyNumber | Should -Be 3
        $run.State.evidence -join ' ' | Should -Match 'hash-match'
        $run.State.cutovers.Count | Should -Be 1
        $run.State.cutovers[0].to | Should -Be 3
        $run.State.cutovers[0].applied | Should -BeFalse
        $run.State.generation | Should -Be 1
        # the deadline is fixed at start and untouched by the rescue
        ([datetime]$run.State.deadline).ToString('o') |
            Should -Be ([datetime]$run.State.startedAt).AddHours(0.02).ToString('o')

        $phases = @($run.Audit | ForEach-Object { $_.phase })
        $phases | Should -Contain 'initial'
        $phases | Should -Contain 'discover'
        $phases | Should -Contain 'near'
        $phases | Should -Contain 'trigger'
        @($run.Audit | Where-Object { $_.kind -eq 'cutover' -and $_.dryRun -eq $true }).Count | Should -Be 1

        Get-SeamHash | Should -Be $seamBefore
    }

    It 'leaves every cutover surface byte-identical under -DryRun' {
        $before = Get-ProtectedSurfaces
        $fixture = New-KeyCheckFixture -InUse 'dry-key-1' -Keys @{
            GO1 = 'dry-key-1'; GO3 = 'dry-key-3'
        } -Usage @{
            GO1 = @{ weekly = @{ percent = 99; status = 'ok'; resetsAt = '2026-11-09T00:00' }
                monthly = @{ percent = 99; status = 'ok'; resetsAt = '2026-11-20' } }
            GO3 = @{ weekly = @{ percent = 0; status = 'ok'; resetsAt = '2026-11-09T00:00' }
                monthly = @{ percent = 20; status = 'ok'; resetsAt = '2026-11-09' } }
        }

        $run = Invoke-KeyCheck -Fixture $fixture -ExtraArgs @('-DryRun', '-SkipCanary', '-MaxChecks', '8')

        $run.ExitCode | Should -Be 0 -Because $run.Output
        $run.State.cutovers.Count | Should -Be 1
        (Get-ProtectedSurfaces) | Should -Be $before -Because 'a dry run must not touch the seam, User env, auth.json or the credential log'
    }

    It 'warns and audits when the budget cannot hold one full interval' {
        $fixture = New-KeyCheckFixture -InUse 'budget-key-1' -Keys @{
            GO1 = 'budget-key-1'; GO2 = 'budget-key-2'
        } -Usage @{
            GO1 = @{ weekly = @{ percent = 10; status = 'ok'; resetsAt = '2026-11-09T00:00' }
                monthly = @{ percent = 20; status = 'ok'; resetsAt = '2026-11-20' } }
            GO2 = @{ weekly = @{ percent = 0; status = 'ok'; resetsAt = '2026-11-09T00:00' }
                monthly = @{ percent = 10; status = 'ok'; resetsAt = '2026-11-09' } }
        }

        # 60 minutes * 60 s = 3600 s >= 1 hour * 3600 s: the run can only ever
        # perform one scheduled check, so say so instead of pretending to watch.
        $run = Invoke-KeyCheck -Fixture $fixture -IntervalMinutes 60 -DurationHours 1 `
            -ExtraArgs @('-DryRun', '-SkipCanary', '-MaxChecks', '3')

        $run.ExitCode | Should -Be 0 -Because $run.Output
        $run.Output | Should -Match 'budget'
        $notes = @($run.Audit | Where-Object { $_.kind -eq 'note' })
        $notes.Count | Should -Be 1
        $notes[0].reason | Should -Match 'effectively one check'
    }

    It 'delegates the cutover to a detached helper and continues when all three surfaces agree' {
        $fixture = New-KeyCheckFixture -InUse 'live-key-1' -Keys @{
            GO1 = 'live-key-1'; GO2 = 'live-key-2'; GO3 = 'live-key-3'
        } -Usage @{
            GO1 = @{ weekly = @{ percent = 100; status = 'rate-limited'; resetsAt = '2026-11-09T00:00' }
                monthly = @{ percent = 99; status = 'ok'; resetsAt = '2026-11-20' } }
            GO2 = @{ weekly = @{ percent = 10; status = 'ok'; resetsAt = '2026-11-09T00:00' }
                monthly = @{ percent = 40; status = 'ok'; resetsAt = '2026-11-20' } }
            GO3 = @{ weekly = @{ percent = 0; status = 'ok'; resetsAt = '2026-11-09T00:00' }
                monthly = @{ percent = 20; status = 'ok'; resetsAt = '2026-11-09' } }
        }
        $fixture.CanaryPath = New-CanaryStub -Dir $fixture.Dir -Verdict 'OK'
        $fixture.SwitchPath = New-SwitchStub -Dir $fixture.Dir
        $fixture.RepairPath = New-RepairStub -Dir $fixture.Dir
        $fixture.CutoverPath = New-CutoverStub -Dir $fixture.Dir -Applied -Verified -LogPath $fixture.CutoverLog

        # Deterministic budget (cl-common-5vg): the run is bounded by its CHECK
        # COUNT, and the deadline is a safety net far outside that bound. The old
        # fixture used the suite default DurationHours 0.02 (~72 s) with
        # MaxChecks 8, so under CPU contention the helper's spawn + poll could
        # reach the DEADLINE before the eighth check - the case then asserted
        # max-checks and observed deadline. A gate that reddens with machine load
        # is not a gate (ADR-0012/0013). Five checks is the whole declared path
        # (initial, discover, near->trigger, trigger/cutover, one near read) and
        # every check is bounded work: three `pwsh` canary spawns plus one
        # detached helper, all reading an in-process usage fixture. The 1-hour
        # deadline therefore cannot win unless the box is orders of magnitude
        # slower than any measured run (5.4 s under six CPU burners). Raising the
        # timeout alone would keep the race, so the count is what bounds the run.
        $maxChecks = 5
        $run = Invoke-KeyCheck -Fixture $fixture -DurationHours 1 -ExtraArgs @(
            '-NoLedger', '-MaxChecks', "$maxChecks", '-CutoverTimeoutMinutes', '1', '-CutoverPollSeconds', '0.1'
        )

        # The helper ran, so the cutover happened out of process; the run then
        # continued to the near loop instead of re-deriving the answer itself.
        $run.ExitCode | Should -Be 0 -Because $run.Output
        # The reason is decided by the CHECK COUNT, not by the clock.
        $run.State.checks | Should -Be $maxChecks
        $run.State.endReason | Should -Be 'max-checks'
        # The delegation contract: a detached helper (not this process) performed
        # the cutover and its outcome is what the run recorded.
        $run.State.cutovers[0].launchMethod | Should -Be 'Win32_Process.Create'
        $run.State.cutovers[0].launchPid | Should -BeGreaterThan 0
        Test-Path -LiteralPath $fixture.CutoverLog | Should -BeTrue
        Test-Path -LiteralPath $run.State.cutovers[0].outcomePath | Should -BeTrue
        $run.State.cutovers.Count | Should -Be 1
        $run.State.cutovers[0].applied | Should -BeTrue
        $run.State.cutovers[0].verified | Should -BeTrue
        $run.State.cutovers[0].to | Should -Be 3
        $run.State.generation | Should -Be 1
        $run.State.replacementKeyNumber | Should -Be 0
        $run.State.evidence -join ' ' | Should -Match 'cutover verified'
        @($run.Audit | Where-Object { $_.kind -eq 'cutover' }).Count | Should -Be 1
    }

    It 'ends 5 cutover-unproven when the helper applied the change but a surface disagrees' {
        $fixture = New-KeyCheckFixture -InUse 'live-key-1' -Keys @{
            GO1 = 'live-key-1'; GO3 = 'live-key-3'
        } -Usage @{
            GO1 = @{ weekly = @{ percent = 100; status = 'rate-limited'; resetsAt = '2026-11-09T00:00' }
                monthly = @{ percent = 99; status = 'ok'; resetsAt = '2026-11-20' } }
            GO3 = @{ weekly = @{ percent = 0; status = 'ok'; resetsAt = '2026-11-09T00:00' }
                monthly = @{ percent = 20; status = 'ok'; resetsAt = '2026-11-09' } }
        }
        $fixture.CanaryPath = New-CanaryStub -Dir $fixture.Dir -Verdict 'OK'
        $fixture.SwitchPath = New-SwitchStub -Dir $fixture.Dir
        $fixture.RepairPath = New-RepairStub -Dir $fixture.Dir
        $fixture.CutoverPath = New-CutoverStub -Dir $fixture.Dir -Applied

        # Same deterministic budget as the success-path case (cl-common-5vg):
        # the helper launch + outcome poll must not race a 72 s fixture deadline
        # under CPU contention. The run is bounded by check count, not the clock.
        $run = Invoke-KeyCheck -Fixture $fixture -DurationHours 1 -ExtraArgs @(
            '-NoLedger', '-MaxChecks', '8', '-CutoverTimeoutMinutes', '1', '-CutoverPollSeconds', '0.1'
        )

        $run.ExitCode | Should -Be 5 -Because $run.Output
        $run.State.endReason | Should -Be 'cutover-unproven'
        $run.State.cutovers[0].applied | Should -BeTrue
        $run.State.cutovers[0].verified | Should -BeFalse
        $run.State.generation | Should -Be 0
    }

    It 'ends 4 cutover-failed when the helper reports the cutover did not apply' {
        $fixture = New-KeyCheckFixture -InUse 'live-key-1' -Keys @{
            GO1 = 'live-key-1'; GO3 = 'live-key-3'
        } -Usage @{
            GO1 = @{ weekly = @{ percent = 100; status = 'rate-limited'; resetsAt = '2026-11-09T00:00' }
                monthly = @{ percent = 99; status = 'ok'; resetsAt = '2026-11-20' } }
            GO3 = @{ weekly = @{ percent = 0; status = 'ok'; resetsAt = '2026-11-09T00:00' }
                monthly = @{ percent = 20; status = 'ok'; resetsAt = '2026-11-09' } }
        }
        $fixture.CanaryPath = New-CanaryStub -Dir $fixture.Dir -Verdict 'OK'
        $fixture.SwitchPath = New-SwitchStub -Dir $fixture.Dir
        $fixture.RepairPath = New-RepairStub -Dir $fixture.Dir
        $fixture.CutoverPath = New-CutoverStub -Dir $fixture.Dir

        # Same deterministic budget as the success-path case (cl-common-5vg):
        # the helper launch + outcome poll must not race a 72 s fixture deadline
        # under CPU contention. The run is bounded by check count, not the clock.
        $run = Invoke-KeyCheck -Fixture $fixture -DurationHours 1 -ExtraArgs @(
            '-NoLedger', '-MaxChecks', '8', '-CutoverTimeoutMinutes', '1', '-CutoverPollSeconds', '0.1'
        )

        $run.ExitCode | Should -Be 4 -Because $run.Output
        $run.State.endReason | Should -Be 'cutover-failed'
        $run.State.cutovers[0].applied | Should -BeFalse
        $run.State.generation | Should -Be 0
    }

    It 'ends 4 cutover-failed (never "unproven") when the helper cannot be spawned' {
        $fixture = New-KeyCheckFixture -InUse 'live-key-1' -Keys @{
            GO1 = 'live-key-1'; GO3 = 'live-key-3'
        } -Usage @{
            GO1 = @{ weekly = @{ percent = 100; status = 'rate-limited'; resetsAt = '2026-11-09T00:00' }
                monthly = @{ percent = 99; status = 'ok'; resetsAt = '2026-11-20' } }
            GO3 = @{ weekly = @{ percent = 0; status = 'ok'; resetsAt = '2026-11-09T00:00' }
                monthly = @{ percent = 20; status = 'ok'; resetsAt = '2026-11-09' } }
        }
        $fixture.CanaryPath = New-CanaryStub -Dir $fixture.Dir -Verdict 'OK'
        $fixture.SwitchPath = New-SwitchStub -Dir $fixture.Dir
        $fixture.RepairPath = New-RepairStub -Dir $fixture.Dir
        $fixture.CutoverPath = Join-Path $fixture.Dir 'no-such-cutover-helper.ps1'

        # Same deterministic budget as the success-path case (cl-common-5vg):
        # the helper launch + outcome poll must not race a 72 s fixture deadline
        # under CPU contention. The run is bounded by check count, not the clock.
        $run = Invoke-KeyCheck -Fixture $fixture -DurationHours 1 -ExtraArgs @(
            '-NoLedger', '-MaxChecks', '8', '-CutoverTimeoutMinutes', '1', '-CutoverPollSeconds', '0.1'
        )

        $run.ExitCode | Should -Be 4 -Because $run.Output
        $run.State.endReason | Should -Be 'cutover-failed'
        $run.State.cutovers[0].applied | Should -BeFalse
        $run.State.endReason | Should -Not -Be 'cutover-unproven'
    }

    It 'ends with exit 3 rather than moving onto an ineligible key' {
        $fixture = New-KeyCheckFixture -InUse 'spent-key-1' -Keys @{
            GO1 = 'spent-key-1'; GO2 = 'spent-key-2'; GO3 = 'spent-key-3'
        } -Usage @{
            GO1 = @{ weekly = @{ percent = 100; status = 'rate-limited'; resetsAt = '2026-11-09T00:00' }
                monthly = @{ percent = 100; status = 'rate-limited'; resetsAt = '2026-11-20' } }
            GO2 = @{ weekly = @{ percent = 0; status = 'ok'; resetsAt = '2026-11-09T00:00' }
                monthly = @{ percent = 100; status = 'rate-limited'; resetsAt = '2026-11-20' } }
            GO3 = @{ weekly = @{ percent = 0; status = 'ok'; resetsAt = '2026-11-09T00:00' }
                monthly = @{ percent = 95; status = 'ok'; resetsAt = '2026-11-09' } }
        }

        $run = Invoke-KeyCheck -Fixture $fixture -ExtraArgs @('-DryRun', '-SkipCanary', '-MaxChecks', '8')

        $run.ExitCode | Should -Be 3 -Because $run.Output
        $run.State.endReason | Should -Be 'no-eligible-replacement'
        $run.State.cutovers.Count | Should -Be 0
        $run.State.generation | Should -Be 0
    }

    It 'never prints or stores a key value, only the key number' {
        $secret1 = 'sk-fixture-value-alpha-001'
        $secret2 = 'sk-fixture-value-bravo-002'
        $fixture = New-KeyCheckFixture -InUse $secret1 -Keys @{
            GO1 = $secret1; GO2 = $secret2
        } -Usage @{
            GO1 = @{ weekly = @{ percent = 99; status = 'ok'; resetsAt = '2026-11-09T00:00' }
                monthly = @{ percent = 99; status = 'ok'; resetsAt = '2026-11-20' } }
            GO2 = @{ weekly = @{ percent = 5; status = 'ok'; resetsAt = '2026-11-09T00:00' }
                monthly = @{ percent = 25; status = 'ok'; resetsAt = '2026-11-09' } }
        }

        $run = Invoke-KeyCheck -Fixture $fixture -ExtraArgs @('-DryRun', '-SkipCanary', '-MaxChecks', '6')
        # A dry probe audits to its own artefact (cl-common-jqm): scan THAT file,
        # never the absent live ledger, or this check passes on nothing.
        $auditPath = Join-Path (Join-Path $fixture.Dir 'dryrun') 'keycheck.jsonl'
        $auditRaw = Get-Content -LiteralPath $auditPath -Raw
        $auditRaw | Should -Not -BeNullOrEmpty -Because 'the secrecy check must read real audit lines'

        $run.Output | Should -Not -Match ([regex]::Escape($secret1))
        $run.Output | Should -Not -Match ([regex]::Escape($secret2))
        $run.RawState | Should -Not -Match ([regex]::Escape($secret1))
        $run.RawState | Should -Not -Match ([regex]::Escape($secret2))
        $auditRaw | Should -Not -Match ([regex]::Escape($secret1))
        $auditRaw | Should -Not -Match ([regex]::Escape($secret2))
        $run.State.evidence -join ' ' | Should -Match 'active key: GO1 via hash-match'
    }
}

Describe 'Key Check discovery reporting' {

    BeforeAll {
        function New-IncidentFixture {
            # The 2026-11-02 census that produced the defect, verbatim: GO6 is
            # the near-cap active key, GO3 and GO1 are eligible, GO2/GO5 have
            # spent their monthly term, GO4 clears weekly but not monthly.
            New-KeyCheckFixture -InUse 'incident-key-6' -Keys @{
                GO1 = 'incident-key-1'; GO2 = 'incident-key-2'; GO3 = 'incident-key-3'
                GO4 = 'incident-key-4'; GO5 = 'incident-key-5'; GO6 = 'incident-key-6'
            } -Usage @{
                GO1 = @{ weekly = @{ percent = 0; status = 'ok'; resetsAt = '2026-11-09T00:00' }
                    monthly = @{ percent = 49; status = 'ok'; resetsAt = '2026-11-23' } }
                GO2 = @{ weekly = @{ percent = 0; status = 'ok'; resetsAt = '2026-11-09T00:00' }
                    monthly = @{ percent = 100; status = 'rate-limited'; resetsAt = '2026-11-10' } }
                GO3 = @{ weekly = @{ percent = 0; status = 'ok'; resetsAt = '2026-11-09T00:00' }
                    monthly = @{ percent = 53; status = 'ok'; resetsAt = '2026-11-20' } }
                GO4 = @{ weekly = @{ percent = 1; status = 'ok'; resetsAt = '2026-11-09T00:00' }
                    monthly = @{ percent = 99; status = 'ok'; resetsAt = '2026-11-13' } }
                GO5 = @{ weekly = @{ percent = 0; status = 'ok'; resetsAt = '2026-11-09T00:00' }
                    monthly = @{ percent = 100; status = 'rate-limited'; resetsAt = '2026-11-15' } }
                GO6 = @{ weekly = @{ percent = 80; status = 'ok'; resetsAt = '2026-11-09T00:00' }
                    monthly = @{ percent = 40; status = 'ok'; resetsAt = '2026-12-02' } }
            }
        }

        function Get-DiscoverRow {
            param($Run)
            return @($Run.Audit | Where-Object { $_.phase -eq 'discover' })[0]
        }
    }

    It 'names the armed replacement with both metres and the monthly reset that justified it' {
        $fixture = New-IncidentFixture
        $run = Invoke-KeyCheck -Fixture $fixture -ExtraArgs @('-DryRun', '-SkipCanary', '-MaxChecks', '3')

        $run.ExitCode | Should -Be 0 -Because $run.Output
        $run.State.replacementKeyNumber | Should -Be 3

        $discover = Get-DiscoverRow -Run $run
        $discover | Should -Not -BeNullOrEmpty
        $discover.key | Should -Be 'GO3'
        $discover.wk | Should -Be 0
        $discover.mo | Should -Be 53
        $discover.reason | Should -Match 'replacement-armed GO3'
        $discover.reason | Should -Match '0wk/53mo'
        $discover.reason | Should -Match 'monthly resets 2026-11-20'
        # GO1 was eligible too (monthly resets 11-23, so it ranked second).
        $discover.reason | Should -Match 'GO1'

        # The defect in user-visible form: the phase line said "no reading" and
        # the reason named no key at all.
        $line = @($run.Output -split "`n" | Where-Object { $_ -match '^\[discover\]' })
        $line.Count | Should -Be 1 -Because $run.Output
        $line[0] | Should -Match 'GO3'
        $line[0] | Should -Not -Match 'no reading'
    }

    It 'names every excluded candidate when no replacement qualifies' {
        $fixture = New-KeyCheckFixture -InUse 'spent-key-1' -Keys @{
            GO1 = 'spent-key-1'; GO2 = 'spent-key-2'; GO4 = 'spent-key-4'; GO5 = 'spent-key-5'
        } -Usage @{
            GO1 = @{ weekly = @{ percent = 100; status = 'rate-limited'; resetsAt = '2026-11-09T00:00' }
                monthly = @{ percent = 100; status = 'rate-limited'; resetsAt = '2026-11-20' } }
            GO2 = @{ weekly = @{ percent = 0; status = 'ok'; resetsAt = '2026-11-09T00:00' }
                monthly = @{ percent = 100; status = 'rate-limited'; resetsAt = '2026-11-20' } }
            GO4 = @{ weekly = @{ percent = 1; status = 'ok'; resetsAt = '2026-11-09T00:00' }
                monthly = @{ percent = 99; status = 'ok'; resetsAt = '2026-11-13' } }
            GO5 = @{ weekly = @{ percent = 95; status = 'ok'; resetsAt = '2026-11-09T00:00' }
                monthly = @{ percent = 10; status = 'ok'; resetsAt = '2026-11-15' } }
        }

        $run = Invoke-KeyCheck -Fixture $fixture -ExtraArgs @('-DryRun', '-SkipCanary', '-MaxChecks', '3')

        $run.ExitCode | Should -Be 3 -Because $run.Output
        $run.State.endReason | Should -Be 'no-eligible-replacement'
        $run.State.replacementKeyNumber | Should -Be 0
        $run.State.cutovers.Count | Should -Be 0

        $discover = Get-DiscoverRow -Run $run
        $discover.reason | Should -Match 'no-eligible-replacement'
        $discover.reason | Should -Match 'GO1=active-key'
        $discover.reason | Should -Match 'GO2=rate-limited'
        $discover.reason | Should -Match 'GO4=monthly>=90'
        $discover.reason | Should -Match 'GO5=weekly>=80'
    }

    It 'reports cannot-evaluate, never "no eligible replacement", when the discovery read fails' {
        # The active canary runs AFTER the initial census and BEFORE discover, so
        # it is the honest way to make the second read fail while the first one
        # succeeded: discovery must say the read broke, not that no key qualifies.
        $fixture = New-KeyCheckFixture -InUse 'gone-key-1' -Keys @{
            GO1 = 'gone-key-1'; GO2 = 'gone-key-2'
        } -Usage @{
            GO1 = @{ weekly = @{ percent = 99; status = 'ok'; resetsAt = '2026-11-09T00:00' }
                monthly = @{ percent = 99; status = 'ok'; resetsAt = '2026-11-20' } }
            GO2 = @{ weekly = @{ percent = 0; status = 'ok'; resetsAt = '2026-11-09T00:00' }
                monthly = @{ percent = 10; status = 'ok'; resetsAt = '2026-11-09' } }
        }
        $canary = Join-Path $fixture.Dir 'canary-breaks-usage.ps1'
        @"
param([int]`$KeyNumber = 0)
Remove-Item -LiteralPath '$($fixture.UsagePath)' -Force -ErrorAction SilentlyContinue
Write-Output 'OK opencode-go/deepseek-v4.1-flash'
exit 0
"@ | Set-Content -LiteralPath $canary
        $fixture.CanaryPath = $canary

        $run = Invoke-KeyCheck -Fixture $fixture -ExtraArgs @('-DryRun', '-MaxChecks', '3')

        $run.ExitCode | Should -Be 1 -Because $run.Output
        $run.State.endReason | Should -Be 'cannot-evaluate'
        $run.State.replacementKeyNumber | Should -Be 0
        $run.State.cutovers.Count | Should -Be 0

        $discover = Get-DiscoverRow -Run $run
        $discover.reason | Should -Match 'cannot-evaluate'
        $discover.reason | Should -Match 'usage fixture not found'
        $discover.reason | Should -Not -Match 'no-eligible-replacement'
    }

    It 'names a failed read at initial instead of a shrug' {
        # The census is healthy but the in-use key is absent from it: the check
        # row must say so, not print the generic "no reading".
        $fixture = New-KeyCheckFixture -InUse 'absent-key-6' -Keys @{
            GO1 = 'present-key-1'; GO6 = 'absent-key-6'
        } -Usage @{
            GO1 = @{ weekly = @{ percent = 0; status = 'ok'; resetsAt = '2026-11-09T00:00' }
                monthly = @{ percent = 10; status = 'ok'; resetsAt = '2026-11-20' } }
        }

        $run = Invoke-KeyCheck -Fixture $fixture -ExtraArgs @('-DryRun', '-SkipCanary', '-MaxChecks', '1')

        $run.State.activeKeyNumber | Should -Be 6
        $initial = @($run.Audit | Where-Object { $_.phase -eq 'initial' })[0]
        $initial.reason | Should -Match 'cannot-evaluate: active key GO6 not in the census'
    }

    It 'reports the exclusion rule per key without a network read' {
        $readings = @(
            (New-Reading -KeyNumber 1 -Weekly 100 -Monthly 100),
            (New-Reading -KeyNumber 2 -Weekly 0 -Monthly 100 -MonthlyStatus 'rate-limited'),
            (New-Reading -KeyNumber 4 -Weekly 1 -Monthly 99),
            (New-Reading -KeyNumber 5 -Weekly 95 -Monthly 10),
            (New-Reading -KeyNumber 6 -Weekly 80 -Monthly 40)
        )
        $report = Get-KeyCheckCandidateReport -Readings $readings -ExcludeKeyNumber 6

        $report.Eligible.Count | Should -Be 0
        ($report.Rejected | Where-Object { $_.KeyNumber -eq 6 }).Rule | Should -Be 'active-key'
        ($report.Rejected | Where-Object { $_.KeyNumber -eq 2 }).Rule | Should -Be 'rate-limited'
        ($report.Rejected | Where-Object { $_.KeyNumber -eq 4 }).Rule | Should -Be 'monthly>=90'
        ($report.Rejected | Where-Object { $_.KeyNumber -eq 5 }).Rule | Should -Be 'weekly>=80'
        ($report.Rejected | Where-Object { $_.KeyNumber -eq 1 }).Rule | Should -Be 'weekly>=80'
    }
}

Describe 'Key Check hysteresis and tolerances' {

    It 'arms at 96 and disarms only after two consecutive readings in the band' {
        $now = [datetime]'2026-11-02T10:00:00'
        $deadline = $now.AddHours(2)

        # arm: 96 wk with a replacement already found
        (Get-KeyCheckNextPhase -Phase 'near' -Now $now -Deadline $deadline `
                -Reading (New-Reading -KeyNumber 1 -Weekly 96 -Monthly 95) -ReplacementKeyNumber 3).Phase | Should -Be 'near'

        # one cool reading (75 wk) is NOT enough to leave the fast loop: the
        # decision needs the streak, which the run keeps in state.
        (Get-KeyCheckNextPhase -Phase 'near' -Now $now -Deadline $deadline `
                -Reading (New-Reading -KeyNumber 1 -Weekly 75 -Monthly 75) -ReplacementKeyNumber 3 `
                -ConsecutiveBelowThreshold 1).Phase | Should -Be 'near'

        # two in a row inside the band -> heartbeat
        (Get-KeyCheckNextPhase -Phase 'near' -Now $now -Deadline $deadline `
                -Reading (New-Reading -KeyNumber 1 -Weekly 69 -Monthly 79) -ReplacementKeyNumber 3 `
                -ConsecutiveBelowThreshold 2).Phase | Should -Be 'heartbeat'
        (Get-KeyCheckNextPhase -Phase 'near' -Now $now -Deadline $deadline `
                -Reading (New-Reading -KeyNumber 1 -Weekly 69 -Monthly 79) -ReplacementKeyNumber 3 `
                -ConsecutiveBelowThreshold 2).Reason | Should -Be 'disarmed'

        # the band needs BOTH meters: 69 wk with 85 mo is still armed
        Test-KeyCheckDisarm -Reading (New-Reading -KeyNumber 1 -Weekly 69 -Monthly 85) | Should -BeFalse
        Test-KeyCheckDisarm -Reading (New-Reading -KeyNumber 1 -Weekly 69 -Monthly 79) | Should -BeTrue
        Test-KeyCheckDisarm -Reading (New-Reading -KeyNumber 1 -Weekly $null -Monthly 10) | Should -BeFalse
    }

    It 'caps the polling by phase: an hour for heartbeat, 15 min for near' {
        # A quiet key is checked hourly; a key inside the band every 15 min.
        Get-KeyCheckCadenceSeconds -Phase 'near' -IntervalMinutes 15 | Should -Be 900
        Get-KeyCheckCadenceSeconds -Phase 'heartbeat' -IntervalMinutes 15 | Should -Be 900
        Get-KeyCheckCadenceSeconds -Phase 'heartbeat' -IntervalMinutes 60 | Should -Be 3600
        Get-KeyCheckCadenceSeconds -Phase 'heartbeat' -IntervalMinutes 1 | Should -Be 60
    }

    It 'treats one rate-limited read as pressure and two consecutive ones as the trigger' {
        $now = [datetime]'2026-11-02T10:00:00'
        $deadline = $now.AddHours(2)
        $limited = New-Reading -KeyNumber 1 -Weekly 0 -Monthly 0 -WeeklyStatus 'rate-limited'

        Test-KeyCheckRateLimited -Reading $limited | Should -BeTrue
        Test-KeyCheckPercentImminent -Reading $limited | Should -BeFalse

        foreach ($streak in 1, 2) {
            (Get-KeyCheckNextPhase -Phase 'near' -Now $now -Deadline $deadline -Reading $limited `
                    -ReplacementKeyNumber 3 -ConsecutiveRateLimited $streak).Phase |
                Should -Be $(if ($streak -ge 2) { 'trigger' } else { 'near' })
        }

        # a 429 with no meters at all is a rate-limited read, not a 0 % key
        $http429 = ConvertTo-KeyCheckReading -Row ([pscustomobject]@{ Key = 'GO1'; Http = 429; Verdict = 'HTTP 429'; Weekly = $null; Monthly = $null })
        Test-KeyCheckRateLimited -Reading $http429 | Should -BeTrue
    }
}

Describe 'Key Check locale-safe reset parsing' {

    It 'parses ISO and both producer local shapes under a fixed culture' {
        ConvertTo-KeyCheckResetTime -Text '2026-11-23T23:43:24' | Should -Be ([datetime]'2026-11-23T23:43:24')
        ConvertTo-KeyCheckResetTime -Text '11/23/2026 23:43:24' | Should -Be ([datetime]'2026-11-23T23:43:24')
        ConvertTo-KeyCheckResetTime -Text '23/11/2026 23:43:24' | Should -Be ([datetime]'2026-11-23T23:43:24')
        ConvertTo-KeyCheckResetTime -Text '11/23/2026 11:43:24 PM' | Should -Be ([datetime]'2026-11-23T23:43:24')
        ConvertTo-KeyCheckResetTime -Text '23/11/2026 11:43:24 PM' | Should -Be ([datetime]'2026-11-23T23:43:24')
        ConvertTo-KeyCheckResetTime -Text '2026-11-23' | Should -Be ([datetime]'2026-11-23')
    }

    It 'returns $null for garbage instead of throwing' {
        foreach ($garbage in @('', '   ', 'not a date', '2026-13-45T99:99:99', 'next tuesday')) {
            { ConvertTo-KeyCheckResetTime -Text $garbage } | Should -Not -Throw
            ConvertTo-KeyCheckResetTime -Text $garbage | Should -BeNullOrEmpty
        }
        ConvertTo-KeyCheckResetTime -Text $null | Should -BeNullOrEmpty
    }

    It 'parses identically under en-US and en-GB without changing machine state' {
        $original = [System.Threading.Thread]::CurrentThread.CurrentCulture
        try {
            foreach ($culture in @('en-US', 'en-GB')) {
                [System.Threading.Thread]::CurrentThread.CurrentCulture = [cultureinfo]::GetCultureInfo($culture)
                ConvertTo-KeyCheckResetTime -Text '11/23/2026 23:43:24' | Should -Be ([datetime]'2026-11-23T23:43:24') -Because $culture
                ConvertTo-KeyCheckResetTime -Text '23/11/2026 23:43:24' | Should -Be ([datetime]'2026-11-23T23:43:24') -Because $culture
                ConvertTo-KeyCheckResetTime -Text '2026-11-23T23:43:24' | Should -Be ([datetime]'2026-11-23T23:43:24') -Because $culture
                # and a shape neither calendar reads as a date stays unknown
                ConvertTo-KeyCheckResetTime -Text '23/23/2026 23:43:24' | Should -BeNullOrEmpty -Because $culture
            }
        } finally {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = $original
        }
    }

    It 'ranks an unknown monthly reset last and names the raw value without failing' {
        $known = New-Reading -KeyNumber 2 -Weekly 0 -Monthly 10 -MonthlyResets '2026-11-09'
        $unknown = New-Reading -KeyNumber 3 -Weekly 0 -Monthly 10 -MonthlyResets 'whenever'
        (Get-KeyCheckReplacement -Readings @($unknown, $known)).KeyNumber | Should -Be 2
        Get-KeyCheckWindowUnknownNote -Reading $unknown | Should -Match 'whenever'
        Get-KeyCheckWindowUnknownNote -Reading $known | Should -Be ''
    }
}


Describe 'Key Check run lock' {

    BeforeAll {
        function Get-LockPath { param($Fixture) return (Join-Path (Split-Path -Parent $Fixture.StatePath) 'lock.json') }

        function New-LockFile {
            param($Fixture, [int]$ProcessId = $PID, [int]$HeartbeatAgeSeconds = 0, [string]$RunId = '20260101-000000')
            $lockPath = Get-LockPath -Fixture $Fixture
            $now = Get-Date
            [pscustomobject]@{
                pid         = $ProcessId
                host        = $env:COMPUTERNAME
                runId       = $RunId
                startedAt   = $now.AddMinutes(-5).ToString('o')
                heartbeatAt = $now.AddSeconds(-$HeartbeatAgeSeconds).ToString('o')
            } | ConvertTo-Json | Set-Content -LiteralPath $lockPath
            return $lockPath
        }

        function New-HealthyFixture {
            New-KeyCheckFixture -InUse 'lock-key-1' -Keys @{ GO1 = 'lock-key-1'; GO3 = 'lock-key-3' } -Usage @{
                GO1 = @{ weekly = @{ percent = 10; status = 'ok'; resetsAt = '2026-11-09T00:00' }
                    monthly = @{ percent = 20; status = 'ok'; resetsAt = '2026-11-20' } }
                GO3 = @{ weekly = @{ percent = 0; status = 'ok'; resetsAt = '2026-11-09T00:00' }
                    monthly = @{ percent = 10; status = 'ok'; resetsAt = '2026-11-09' } }
            }
        }
    }

    It 'refuses a second live run with exit 2 and names the holder' {
        $fixture = New-HealthyFixture
        $null = New-LockFile -Fixture $fixture -ProcessId $PID -RunId 'the-other-run'

        $run = Invoke-KeyCheck -Fixture $fixture -ExtraArgs @('-SkipCanary', '-NoLedger', '-MaxChecks', '2')

        $run.ExitCode | Should -Be 2 -Because $run.Output
        $run.Output | Should -Match 'locked-by-run'
        $run.Output | Should -Match 'the-other-run'
        $run.State | Should -BeNullOrEmpty -Because 'a refused run must not touch the run state'

        $lock = @($run.Audit | Where-Object { $_.kind -eq 'lock' })
        $lock.Count | Should -Be 1
        $lock[0].reason | Should -Be 'locked-by-run'
        $lock[0].holderRunId | Should -Be 'the-other-run'
        $lock[0].holderAgeSeconds | Should -BeGreaterThan 0
    }

    It 'takes over a stale lock whose pid is dead, and audits the takeover' {
        $fixture = New-HealthyFixture
        $lockPath = New-LockFile -Fixture $fixture -ProcessId 999999 -RunId 'crashed-run'

        $run = Invoke-KeyCheck -Fixture $fixture -ExtraArgs @('-SkipCanary', '-NoLedger', '-MaxChecks', '2')

        $run.ExitCode | Should -Be 0 -Because $run.Output
        $run.State | Should -Not -BeNullOrEmpty
        $lock = @($run.Audit | Where-Object { $_.kind -eq 'lock' })
        $lock.Count | Should -Be 1
        $lock[0].reason | Should -Match 'lock-stale-taken-over'
        $lock[0].reason | Should -Match 'crashed-run'
        $lock[0].holderRunId | Should -Be 'crashed-run'
        # released on the way out
        Test-Path -LiteralPath $lockPath | Should -BeFalse
    }

    It 'steals a live lock only with -Force, and says so' {
        $fixture = New-HealthyFixture
        $lockPath = New-LockFile -Fixture $fixture -ProcessId $PID -RunId 'still-running'

        $run = Invoke-KeyCheck -Fixture $fixture -ExtraArgs @('-SkipCanary', '-NoLedger', '-MaxChecks', '2', '-Force')

        $run.ExitCode | Should -Be 0 -Because $run.Output
        $lock = @($run.Audit | Where-Object { $_.kind -eq 'lock' })
        $lock.Count | Should -Be 1
        $lock[0].reason | Should -Match 'lock-forced'
        Test-Path -LiteralPath $lockPath | Should -BeFalse
    }

    It 'never takes the lock under -DryRun' {
        $fixture = New-HealthyFixture
        $lockPath = New-LockFile -Fixture $fixture -ProcessId $PID -RunId 'a-live-holder'
        $before = Get-Content -LiteralPath $lockPath -Raw

        $run = Invoke-KeyCheck -Fixture $fixture -ExtraArgs @('-SkipCanary', '-DryRun', '-MaxChecks', '2')

        $run.ExitCode | Should -Be 0 -Because $run.Output
        (Get-Content -LiteralPath $lockPath -Raw) | Should -Be $before -Because '-DryRun is a rehearsal and must not touch the machine'
        @($run.Audit | Where-Object { $_.kind -eq 'lock' }).Count | Should -Be 0
    }
}

Describe 'Key Check resume' {

    BeforeAll {
        function New-ResumeFixture {
            param([string]$InUse = 'resume-key-1')
            New-KeyCheckFixture -InUse $InUse -Keys @{
                GO1 = 'resume-key-1'; GO3 = 'resume-key-3'
            } -Usage @{
                GO1 = @{ weekly = @{ percent = 85; status = 'ok'; resetsAt = '2026-11-09T00:00' }
                    monthly = @{ percent = 92; status = 'ok'; resetsAt = '2026-11-20' } }
                GO3 = @{ weekly = @{ percent = 0; status = 'ok'; resetsAt = '2026-11-09T00:00' }
                    monthly = @{ percent = 10; status = 'ok'; resetsAt = '2026-11-09' } }
            }
        }

        function New-RunStateFile {
            param($Fixture, [hashtable]$Overrides = @{}, [datetime]$StartedAt = (Get-Date).AddMinutes(-5), [int]$DurationMinutes = 30)
            $state = [ordered]@{
                runId                        = '20260101-090000'
                startedAt                    = $StartedAt.ToString('o')
                deadline                     = $StartedAt.AddMinutes($DurationMinutes).ToString('o')
                deadlineAt                   = $StartedAt.AddMinutes($DurationMinutes).ToString('o')
                intervalMinutes              = 1
                durationHours                = 0.5
                phase                        = 'near'
                activeKeyNumber              = 1
                replacementKeyNumber         = 3
                replacementKey               = 3
                simulatedActiveKeyNumber     = 0
                generation                   = 1
                checks                       = 4
                lastReading                  = $null
                lastCheckAt                  = $StartedAt.AddMinutes(4).ToString('o')
                lastResult                   = 'near (watching)'
                consecutiveRateLimited       = 0
                consecutiveCannotEvaluate    = 0
                consecutiveBelowThreshold    = 0
                armed                        = $true
                evidence                     = @('armed GO3')
                dryRun                       = $false
                cutovers                     = @()
                drift                        = $null
                canary                       = $null
                usageSource                  = 'fixture'
                endedAt                      = $null
                endReason                    = ''
                exitCode                     = 0
            }
            foreach ($key in $Overrides.Keys) { $state[$key] = $Overrides[$key] }
            $state | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Fixture.StatePath
            return [pscustomobject]$state
        }

        function New-CutoverOutcome {
            param($Fixture, [string]$RunId, [switch]$Applied, [switch]$Verified, [switch]$Pending, [int]$KeyNumber = 3)
            $path = Join-Path $Fixture.Dir "$RunId-cutover.json"
            $verifiedValue = if ($Pending) { "'pending'" } elseif ($Verified) { '$true' } else { '$false' }
            [ordered]@{
                applied        = [bool]$Applied
                verified       = $(if ($Pending) { 'pending' } else { [bool]$Verified })
                restartPending = [bool]$Pending
                at             = (Get-Date).ToString('o')
                runId          = $RunId
                keyNumber      = $KeyNumber
                reason         = if ($Pending) { 'restart-pending' } elseif ($Verified) { '' } else { 'stub: surface disagreed' }
            } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $path
            return $path
        }

        function New-PendingFixture {
            <#
            .SYNOPSIS
                A fixture whose switch has ALREADY moved: seam names GO3, the
                in-use value is GO3's, and the Paseo pin either agrees (default)
                or is left on GO1.
            #>
            param([switch]$PinStillOnGo1)
            $fixture = New-KeyCheckFixture -InUse 'resume-key-3' -Keys @{
                GO1 = 'resume-key-1'; GO3 = 'resume-key-3'
            } -Usage @{
                GO1 = @{ weekly = @{ percent = 85; status = 'ok'; resetsAt = '2026-11-09T00:00' }
                    monthly = @{ percent = 92; status = 'ok'; resetsAt = '2026-11-20' } }
                GO3 = @{ weekly = @{ percent = 10; status = 'ok'; resetsAt = '2026-11-09T00:00' }
                    monthly = @{ percent = 20; status = 'ok'; resetsAt = '2026-11-09' } }
            }
            $fixture | Add-Member -NotePropertyName SeamFile -NotePropertyValue (Join-Path $fixture.Dir 'seam.json')
            @{ activeKey = 'OPENCODE_GO3_KEY' } | ConvertTo-Json | Set-Content -LiteralPath $fixture.SeamFile
            $fixture | Add-Member -NotePropertyName PaseoConfigPath -NotePropertyValue (Join-Path $fixture.Dir 'paseo-config.json')
            $pin = if ($PinStillOnGo1) { 'resume-key-1' } else { 'resume-key-3' }
            @{
                agents = @{ providers = @{ opencode = @{ env = @{ OPENCODE_GO_KEY = $pin } } } }
            } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $fixture.PaseoConfigPath
            return $fixture
        }
    }

    It 'round-trips every persisted field and keeps the ORIGINAL deadline' {
        $fixture = New-ResumeFixture
        $written = New-RunStateFile -Fixture $fixture

        $run = Invoke-KeyCheck -Fixture $fixture -ExtraArgs @('-SkipCanary', '-NoLedger', '-MaxChecks', '5')

        $run.ExitCode | Should -Be 0 -Because $run.Output
        $run.State.runId | Should -Be $written.runId
        ([datetimeoffset]$run.State.deadline).UtcTicks | Should -Be ([datetimeoffset]$written.deadline).UtcTicks
        ([datetimeoffset]$run.State.deadlineAt).UtcTicks | Should -Be ([datetimeoffset]$written.deadline).UtcTicks
        $run.State.generation | Should -Be 1
        $run.State.phase | Should -Be 'near'
        $run.State.armed | Should -BeTrue
        $run.State.replacementKeyNumber | Should -Be 3
        $run.State.replacementKey | Should -Be 3
        foreach ($field in @('runId', 'startedAt', 'deadlineAt', 'phase', 'generation', 'replacementKey',
                'consecutiveRateLimited', 'consecutiveCannotEvaluate', 'consecutiveBelowThreshold',
                'armed', 'lastCheckAt', 'lastResult')) {
            $run.State.PSObject.Properties[$field] | Should -Not -BeNullOrEmpty -Because "state.json must round-trip $field"
        }

        $resume = @($run.Audit | Where-Object { $_.kind -eq 'resume' })
        $resume.Count | Should -Be 1
        $resume[0].runId | Should -Be $written.runId
        ([datetimeoffset]$resume[0].deadlineKept).UtcTicks | Should -Be ([datetimeoffset]$written.deadline).UtcTicks
        # the resumed run continued from `near`, it did not start over at `initial`
        @($run.Audit | Where-Object { $_.phase -eq 'initial' }).Count | Should -Be 0
    }

    It 'ends window-expired-while-down when the deadline passed while nothing ran' {
        $fixture = New-ResumeFixture
        $written = New-RunStateFile -Fixture $fixture -StartedAt (Get-Date).AddHours(-3) -DurationMinutes 60

        $run = Invoke-KeyCheck -Fixture $fixture -ExtraArgs @('-SkipCanary', '-NoLedger', '-MaxChecks', '5')

        $run.ExitCode | Should -Be 0 -Because $run.Output
        $run.State.endReason | Should -Be 'window-expired-while-down'
        $run.State.runId | Should -Be $written.runId
        ([datetimeoffset]$run.State.deadline).UtcTicks | Should -Be ([datetimeoffset]$written.deadline).UtcTicks
        # no fresh window was invented: no checks ran
        @($run.Audit | Where-Object { $_.kind -eq 'check' }).Count | Should -Be 0
        $end = @($run.Audit | Where-Object { $_.kind -eq 'end' })[0]
        $end.reason | Should -Be 'window-expired-while-down'
    }

    It 'consumes a verified cutover outcome written while the run was down' {
        # A verified cutover moved the in-use value too (the switch helper does),
        # so the live key agrees with the outcome. An outcome the LIVE key
        # contradicts is the cl-common-o1t case and must never be re-asserted.
        $fixture = New-ResumeFixture -InUse 'resume-key-3'
        $written = New-RunStateFile -Fixture $fixture -Overrides @{ phase = 'trigger' }
        $null = New-CutoverOutcome -Fixture $fixture -RunId $written.runId -Applied -Verified

        $run = Invoke-KeyCheck -Fixture $fixture -ExtraArgs @('-SkipCanary', '-NoLedger', '-MaxChecks', '4')

        $run.ExitCode | Should -Be 0 -Because $run.Output
        $run.State.runId | Should -Be $written.runId
        $run.State.generation | Should -Be 2
        $run.State.activeKeyNumber | Should -Be 3
        $run.State.replacementKeyNumber | Should -Be 0
        $run.State.phase | Should -Be 'near'
        $resume = @($run.Audit | Where-Object { $_.kind -eq 'resume' })[0]
        $resume.reason | Should -Match 'resumed-cutover-verified'
        @($run.State.cutovers | Where-Object { $_.to -eq 3 -and $_.verified -eq $true }).Count | Should -Be 1
    }

    It 'ends 4 cutover-failed when the outcome written while the run was down failed' {
        $fixture = New-ResumeFixture
        $written = New-RunStateFile -Fixture $fixture -Overrides @{ phase = 'trigger' }
        $null = New-CutoverOutcome -Fixture $fixture -RunId $written.runId -KeyNumber 3

        $run = Invoke-KeyCheck -Fixture $fixture -ExtraArgs @('-SkipCanary', '-NoLedger', '-MaxChecks', '4')

        $run.ExitCode | Should -Be 4 -Because $run.Output
        $run.State.endReason | Should -Be 'cutover-failed'
        $run.State.generation | Should -Be 1
    }

    It 're-resolves the active key when a trigger was interrupted with NO outcome file' {
        # A killed helper may have moved the seam and never run the repair: the
        # state file cannot be trusted as a clean switch.
        $fixture = New-ResumeFixture
        $written = New-RunStateFile -Fixture $fixture -Overrides @{ phase = 'trigger' }

        $run = Invoke-KeyCheck -Fixture $fixture -ExtraArgs @('-SkipCanary', '-NoLedger', '-MaxChecks', '1')

        $run.ExitCode | Should -Be 0 -Because $run.Output
        $run.State.runId | Should -Be $written.runId
        $resume = @($run.Audit | Where-Object { $_.kind -eq 'resume' })[0]
        $resume.reason | Should -Match 'resumed-unverified-cutover'
        $resume.phase | Should -Be 'initial'
        @($run.Audit | Where-Object { $_.phase -eq 'initial' }).Count | Should -BeGreaterThan 0
    }

    It 'finishes a restart-pending cutover on resume by re-verifying the Paseo pin' {
        $fixture = New-PendingFixture
        $written = New-RunStateFile -Fixture $fixture -Overrides @{ phase = 'trigger' }
        $outcomePath = New-CutoverOutcome -Fixture $fixture -RunId $written.runId -Applied -Pending -KeyNumber 3

        $run = Invoke-KeyCheck -Fixture $fixture -ExtraArgs @(
            '-SkipCanary', '-NoLedger', '-MaxChecks', '3', '-PaseoConfig', $fixture.PaseoConfigPath, '-SeamPath', $fixture.SeamFile
        )

        $run.ExitCode | Should -Be 0 -Because $run.Output
        $run.State.runId | Should -Be $written.runId
        $run.State.generation | Should -Be 2
        $run.State.activeKeyNumber | Should -Be 3
        $run.State.phase | Should -Be 'near'
        $resume = @($run.Audit | Where-Object { $_.kind -eq 'resume' })[0]
        $resume.reason | Should -Match 'resumed-cutover-verified-after-restart'
        $resume.reason | Should -Match 'pin=GO3'

        # the pending fact is upgraded on disk, so a third invocation is not asked
        # to prove the same cutover again
        $upgraded = Get-Content -LiteralPath $outcomePath -Raw | ConvertFrom-Json
        $upgraded.verified | Should -BeTrue
        $upgraded.restartPending | Should -BeFalse
        $upgraded.reason | Should -Be 'verified-after-restart'
    }

    It 'ends 4 cutover-failed when a restart-pending outcome does not verify' {
        $fixture = New-PendingFixture -PinStillOnGo1
        $written = New-RunStateFile -Fixture $fixture -Overrides @{ phase = 'trigger' }
        $null = New-CutoverOutcome -Fixture $fixture -RunId $written.runId -Applied -Pending -KeyNumber 3

        $run = Invoke-KeyCheck -Fixture $fixture -ExtraArgs @(
            '-SkipCanary', '-NoLedger', '-MaxChecks', '3', '-PaseoConfig', $fixture.PaseoConfigPath, '-SeamPath', $fixture.SeamFile
        )

        $run.ExitCode | Should -Be 4 -Because $run.Output
        $run.State.endReason | Should -Be 'cutover-failed'
        $run.State.evidence -join ' ' | Should -Match 'restart-pending'
        @($run.Audit | Where-Object { $_.kind -eq 'resume' }).Count | Should -Be 0
    }
}

Describe 'Key Check active-key resolution (cl-common-o1t)' {

    BeforeAll {
        function New-KeyChangeStateFile {
            <#
            .SYNOPSIS
                A resumable run that is watching GO3, with the meters and the
                sample ring it recorded for GO3.
            #>
            param($Fixture, [int]$ActiveKeyNumber = 3, [int]$Generation = 3, [int]$Checks = 12)
            $startedAt = (Get-Date).AddMinutes(-5)
            $state = [ordered]@{
                runId                       = '20260101-120000'
                startedAt                   = $startedAt.ToString('o')
                deadline                    = $startedAt.AddMinutes(55).ToString('o')
                deadlineAt                  = $startedAt.AddMinutes(55).ToString('o')
                intervalMinutes             = 1
                durationHours               = 1
                phase                       = 'near'
                activeKeyNumber             = $ActiveKeyNumber
                replacementKeyNumber        = 0
                replacementKey              = 0
                simulatedActiveKeyNumber    = 0
                generation                  = $Generation
                checks                      = $Checks
                # The meters and the ring the OLD key produced: weekly 42 % /
                # monthly 74 % were the numbers the blind watch kept reporting
                # while the fleet ran on GO1.
                lastReading                 = [ordered]@{
                    KeyNumber = 3; Label = 'GO3'
                    Weekly    = [ordered]@{ Percent = 42; Status = 'ok'; ResetsAt = '2026-11-09T00:00' }
                    Monthly   = [ordered]@{ Percent = 74; Status = 'ok'; ResetsAt = '2026-11-20' }
                }
                lastCheckAt                 = $startedAt.AddMinutes(4).ToString('o')
                lastResult                  = 'near (watching)'
                cadenceSeconds              = 60
                cadenceGear                 = 'ett-1min'
                cadenceReason               = 'ett'
                burnPerMinute               = 1.2
                ettMinutes                  = 30
                sampleAt                    = $startedAt.AddMinutes(4).ToString('o')
                cadenceChanges              = @()
                cadenceLoosenStreak         = 0
                cadenceFloorTicks           = 0
                cadenceSamples              = @(
                    [ordered]@{ at = $startedAt.ToString('yyyy-MM-ddTHH:mm:ss'); wk = 40; mo = 72 },
                    [ordered]@{ at = $startedAt.AddMinutes(2).ToString('yyyy-MM-ddTHH:mm:ss'); wk = 41; mo = 73 },
                    [ordered]@{ at = $startedAt.AddMinutes(4).ToString('yyyy-MM-ddTHH:mm:ss'); wk = 42; mo = 74 }
                )
                cadenceSampleSignature      = 'sig-go3'
                cadenceSampleGeneration     = 3
                consecutiveRateLimited      = 1
                consecutiveCannotEvaluate   = 0
                consecutiveBelowThreshold   = 1
                armed                       = $true
                evidence                    = @('armed GO3')
                dryRun                      = $false
                cutovers                    = @()
                drift                       = $null
                canary                      = $null
                usageSource                 = 'fixture'
                endedAt                     = $null
                endReason                   = ''
                exitCode                    = 0
            }
            $state | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Fixture.StatePath
            return [pscustomobject]$state
        }

        function New-KeyChangeFixture {
            <#
            .SYNOPSIS
                The operator switched the fleet to GO1: the seam names GO1, the
                in-use value matches no pool entry (it is the operator's new
                value), and GO1's meters are quiet while GO3's are hot.
            #>
            param()
            $fixture = New-KeyCheckFixture -InUse 'live-key-value-not-in-the-fixture-pool' -Keys @{
                GO1 = 'keycheck-go1-value'; GO3 = 'keycheck-go3-value'
            } -Usage @{
                GO1 = @{ weekly = @{ percent = 10; status = 'ok'; resetsAt = '2026-11-09T00:00' }
                    monthly = @{ percent = 20; status = 'ok'; resetsAt = '2026-11-20' } }
                GO3 = @{ weekly = @{ percent = 42; status = 'ok'; resetsAt = '2026-11-09T00:00' }
                    monthly = @{ percent = 74; status = 'ok'; resetsAt = '2026-11-20' } }
            }
            $fixture | Add-Member -NotePropertyName SeamFile -NotePropertyValue (Join-Path $fixture.Dir 'seam.json')
            @{ activeKey = 'OPENCODE_GO1_KEY' } | ConvertTo-Json | Set-Content -LiteralPath $fixture.SeamFile
            return $fixture
        }
    }

    It 'follows the live in-use key on resume instead of the key the state remembers' {
        # MEASURED DEFECT: after an operator GO3 -> GO1 switch the resumed watch
        # kept state.activeKeyNumber = 3, audited `resumed: resumed-cutover-verified
        # GO3 -> GO3` against a seam that says GO1, and measured GO3's 42wk/74mo.
        # A real GO1 cap would never have triggered a cutover.
        $fixture = New-KeyChangeFixture
        $written = New-KeyChangeStateFile -Fixture $fixture

        $run = Invoke-KeyCheck -Fixture $fixture -ExtraArgs @(
            '-SkipCanary', '-NoLedger', '-SeamPath', $fixture.SeamFile, '-MaxChecks', '13'
        )

        $run.ExitCode | Should -Be 0 -Because $run.Output
        # the state follows the LIVE key, not the previous run
        $run.State.activeKeyNumber | Should -Be 1
        $run.State.generation | Should -Be ($written.generation + 1)
        # the false history: no `verified GO3 -> GO3` may be written at all
        $run.State.evidence -join ' ' | Should -Not -Match 'verified GO3 -> GO3'
        @($run.Audit | Where-Object { $_.reason -match 'verified GO3 -> GO3' }).Count | Should -Be 0
        @($run.Audit | Where-Object { $_.reason -match 'active-key-changed GO3 -> GO1' }).Count |
            Should -BeGreaterThan 0
        # the sample ring and the meters read for the old key are discarded
        @($run.State.cadenceSamples).Count | Should -Be 1
        $run.State.cadenceSamples[0].wk | Should -Be 10
        $run.State.cadenceSamples[0].mo | Should -Be 20
        $run.State.lastReading.KeyNumber | Should -Be 1
        # and every reading taken is GO1's, never the old key's
        @($run.Audit | Where-Object { $_.kind -eq 'check' }).Count | Should -BeGreaterThan 0
        @($run.Audit | Where-Object { $_.kind -eq 'check' -and $_.key -eq 'GO3' }).Count | Should -Be 0
        @($run.Audit | Where-Object { $_.kind -eq 'check' } | Select-Object -Last 1).key | Should -Be 'GO1'
    }

    It 'discards a verified cutover outcome the live key contradicts (the measured incident)' {
        # The measured incident: the helper's verified outcome said GO3, the
        # operator then moved the fleet to GO1, and the resumed watch audited
        # `resumed: resumed-cutover-verified GO3 -> GO3` against a seam that says
        # GO1. The live key now wins, and the line is the live change.
        $fixture = New-KeyChangeFixture
        $written = New-KeyChangeStateFile -Fixture $fixture
        [ordered]@{
            applied = $true; verified = $true; restartPending = $false
            at = (Get-Date).ToString('o'); runId = $written.runId; keyNumber = 3
            reason = ''; surfaces = @()
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $fixture.Dir "$($written.runId)-cutover.json")

        $run = Invoke-KeyCheck -Fixture $fixture -ExtraArgs @(
            '-SkipCanary', '-NoLedger', '-SeamPath', $fixture.SeamFile, '-MaxChecks', '13'
        )

        $run.ExitCode | Should -Be 0 -Because $run.Output
        $run.State.activeKeyNumber | Should -Be 1
        $run.State.generation | Should -Be ($written.generation + 1)
        @($run.Audit | Where-Object { $_.reason -match 'resumed-cutover-verified' }).Count | Should -Be 0
        @($run.Audit | Where-Object { $_.reason -match 'verified GO3 -> GO3' }).Count | Should -Be 0
        $resume = @($run.Audit | Where-Object { $_.kind -eq 'resume' })[0]
        $resume.reason | Should -Match 'active-key-changed GO3 -> GO1'
        $resume.reason | Should -Match 'verified outcome for GO3 no longer describes this machine'
        # the bogus from=3/to=3 cutover bookkeeping is not written
        @($run.State.cutovers | Where-Object { $_.from -eq 3 -and $_.to -eq 3 }).Count | Should -Be 0
    }

    It 'increments the generation and discards the old key history in one state write' {
        $state = [pscustomobject]@{
            runId = 'r1'; phase = 'near'; activeKeyNumber = 3; replacementKeyNumber = 0
            replacementKey = 0; generation = 3; checks = 12
            lastReading = [pscustomobject]@{ KeyNumber = 3; Label = 'GO3' }
            cadenceSamples = @([pscustomobject]@{ at = '2026-11-02T10:00:00'; wk = 42; mo = 74 })
            cadenceSampleSignature = 'sig-go3'; cadenceSampleGeneration = 3
            cadenceSeconds = 60; cadenceGear = 'ett-1min'; cadenceReason = 'ett'
            burnPerMinute = 1.2; ettMinutes = 30; cadenceLoosenStreak = 2; cadenceFloorTicks = 3
            consecutiveRateLimited = 1; consecutiveCannotEvaluate = 1; consecutiveBelowThreshold = 1
            armed = $true; evidence = @('armed GO3'); cadenceChanges = @()
        }

        $after = Update-KeyCheckActiveKeyState -State $state -LiveKeyNumber 1 -How 'seam-activeKey'

        $after.Changed | Should -BeTrue
        $after.FromKeyNumber | Should -Be 3
        $after.ToKeyNumber | Should -Be 1
        $after.Reason | Should -Be 'active-key-changed GO3 -> GO1'
        $after.State.generation | Should -Be 4
        $after.State.activeKeyNumber | Should -Be 1
        $after.State.lastReading | Should -BeNullOrEmpty
        @($after.State.cadenceSamples).Count | Should -Be 0
        @($after.State.consecutiveRateLimited, $after.State.consecutiveCannotEvaluate,
            $after.State.consecutiveBelowThreshold) | Should -Be @(0, 0, 0)
        $after.State.armed | Should -BeFalse
        # no change when the live key already is the state's key, or is unknown
        (Update-KeyCheckActiveKeyState -State $state -LiveKeyNumber 3).Changed | Should -BeFalse
        (Update-KeyCheckActiveKeyState -State $state -LiveKeyNumber 0).Changed | Should -BeFalse
        $state.generation | Should -Be 3
    }
}

Describe 'Key Check fail-fast' {

    It 'ends 1 active-key-unresolved rather than watching a key it cannot name' {
        $fixture = New-KeyCheckFixture -InUse 'not-a-pool-key' -Keys @{ GO1 = 'pool-key-1' } -Usage @{
            GO1 = @{ weekly = @{ percent = 10; status = 'ok'; resetsAt = '2026-11-09T00:00' }
                monthly = @{ percent = 20; status = 'ok'; resetsAt = '2026-11-20' } }
        }
        $seam = Join-Path $fixture.Dir 'seam-empty.json'
        '{}' | Set-Content -LiteralPath $seam

        $run = Invoke-KeyCheck -Fixture $fixture -ExtraArgs @('-SkipCanary', '-NoLedger', '-SeamPath', $seam, '-MaxChecks', '4')

        $run.ExitCode | Should -Be 1 -Because $run.Output
        $run.State.endReason | Should -Be 'active-key-unresolved'
        $run.State.checks | Should -Be 1 -Because 'it must not poll for the whole duration'
        @($run.Audit | Where-Object { $_.kind -eq 'check' })[0].reason | Should -Match 'active-key-unresolved'
    }

    It 'ends 1 meter-unreadable after three consecutive unreadable reads' {
        $fixture = New-KeyCheckFixture -InUse 'unreadable-key-1' -Keys @{ GO1 = 'unreadable-key-1' } -Usage @{
            GO1 = @{ weekly = @{ percent = 10; status = 'ok'; resetsAt = '2026-11-09T00:00' }
                monthly = @{ percent = 20; status = 'ok'; resetsAt = '2026-11-20' } }
        }
        Remove-Item -LiteralPath $fixture.UsagePath -Force

        $run = Invoke-KeyCheck -Fixture $fixture -ExtraArgs @('-SkipCanary', '-NoLedger')

        $run.ExitCode | Should -Be 1 -Because $run.Output
        $run.State.endReason | Should -Be 'meter-unreadable' -Because $run.Output
        $run.State.consecutiveCannotEvaluate | Should -BeGreaterThan 2
        $run.State.evidence -join ' ' | Should -Match 'meter-unreadable'
    }

    It 'does not fail after only two unreadable reads' {
        $fixture = New-KeyCheckFixture -InUse 'unreadable-key-1' -Keys @{ GO1 = 'unreadable-key-1' } -Usage @{
            GO1 = @{ weekly = @{ percent = 10; status = 'ok'; resetsAt = '2026-11-09T00:00' }
                monthly = @{ percent = 20; status = 'ok'; resetsAt = '2026-11-20' } }
        }
        Remove-Item -LiteralPath $fixture.UsagePath -Force

        $run = Invoke-KeyCheck -Fixture $fixture -ExtraArgs @('-SkipCanary', '-NoLedger', '-MaxChecks', '2')

        $run.ExitCode | Should -Be 0 -Because $run.Output
        $run.State.consecutiveCannotEvaluate | Should -Be 2
        $run.State.endReason | Should -Be 'max-checks'
    }
}

Describe 'Key Check cutover launch policy' {

    It 'refuses to silently fall back to Start-Process when Win32_Process.Create fails' {
        # A Start-Process child may inherit the agent's job membership, and the
        # run must not quietly swap the mechanism the operator did not ask for.
        $bad = '"' + (Join-Path $TestDrive 'no-such-executable.exe') + '"'

        $launch = Start-KeyCheckDetachedProcess -CommandLine $bad

        $launch.Spawned | Should -BeFalse
        $launch.Method | Should -Be 'none'
        $launch.Detail | Should -Match 'cim-launch-failed'
        $launch.Detail | Should -Match 'AllowProcessFallback'
    }

    It 'takes the fallback only when -AllowProcessFallback is explicit, and records why it still works' {
        $marker = Join-Path $TestDrive ("fallback-{0}.txt" -f ([guid]::NewGuid().ToString('N')))
        $child = Join-Path $TestDrive 'fallback-child.ps1'
        @"
param([string]`$Marker)
'spawned' | Set-Content -LiteralPath `$Marker
"@ | Set-Content -LiteralPath $child
        $bad = '"' + (Join-Path $TestDrive 'no-such-executable.exe') + '"'

        $launch = Start-KeyCheckDetachedProcess -CommandLine $bad `
            -FallbackArgumentList @('-NoProfile', '-File', $child, '-Marker', $marker) -AllowProcessFallback

        $launch.Spawned | Should -BeTrue
        $launch.Method | Should -Be 'Start-Process'
        $launch.Detail | Should -Match 'pre-restart outcome'
        $deadline = (Get-Date).AddSeconds(15)
        while (-not (Test-Path -LiteralPath $marker) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 200 }
        Test-Path -LiteralPath $marker | Should -BeTrue
    }

    It 'keeps polling past a restart-pending outcome instead of reading it as success' {
        $fixture = New-KeyCheckFixture -InUse 'pending-key-1' -Keys @{
            GO1 = 'pending-key-1'; GO3 = 'pending-key-3'
        } -Usage @{
            GO1 = @{ weekly = @{ percent = 100; status = 'rate-limited'; resetsAt = '2026-11-09T00:00' }
                monthly = @{ percent = 99; status = 'ok'; resetsAt = '2026-11-20' } }
            GO3 = @{ weekly = @{ percent = 0; status = 'ok'; resetsAt = '2026-11-09T00:00' }
                monthly = @{ percent = 20; status = 'ok'; resetsAt = '2026-11-09' } }
        }
        $fixture.CanaryPath = New-CanaryStub -Dir $fixture.Dir -Verdict 'OK'
        $stub = Join-Path $fixture.Dir 'cutover-pending-stub.ps1'
        @"
param(
    [int]`$KeyNumber = 0,
    [string]`$OutcomePath = '',
    [string]`$RunId = '',
    [string]`$SwitchScript = '',
    [string]`$RepairScript = '',
    [int]`$TimeoutSeconds = 0
)
`$pending = [ordered]@{ applied = `$true; verified = 'pending'; restartPending = `$true; reason = 'restart-pending'; keyNumber = `$KeyNumber; runId = `$RunId; surfaces = @(); steps = @() }
`$pending | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath `$OutcomePath
Start-Sleep -Milliseconds 900
`$final = [ordered]@{ applied = `$true; verified = `$true; restartPending = `$false; reason = 'verified'; keyNumber = `$KeyNumber; runId = `$RunId; surfaces = @(); steps = @() }
`$final | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath `$OutcomePath
exit 0
"@ | Set-Content -LiteralPath $stub
        $fixture.CutoverPath = $stub

        # The helper's pending->verified transition is bounded work (write, sleep
        # 900 ms, write), so give the wait a margin that machine load cannot eat
        # (cl-common-5vg): the old 0.2 min (12 s) wait raced helper startup and
        # produced a spurious cutover-timeout in a full-suite run at 110/1.
        $run = Invoke-KeyCheck -Fixture $fixture -DurationHours 1 -ExtraArgs @(
            '-NoLedger', '-MaxChecks', '8', '-CutoverTimeoutMinutes', '1', '-CutoverPollSeconds', '0.1'
        )

        $run.ExitCode | Should -Be 0 -Because $run.Output
        $run.State.cutovers[0].verified | Should -BeTrue
        $run.State.generation | Should -Be 1
        $pendingRows = @($run.Audit | Where-Object { $_.kind -eq 'cutover' -and [string]$_.verified -eq 'pending' })
        $pendingRows.Count | Should -Be 1 -Because 'the watch must notice the pre-restart outcome without accepting it'
    }
}

Describe 'Key Check detached cutover launch' {

    It 'builds the helper argv as one quoted command line' {        $cmd = Get-KeyCheckHelperCommandLine -PowerShellPath 'C:\Program Files\PowerShell\pwsh.exe' `
            -HelperPath 'C:\a b\Invoke-KeyCheckCutover.ps1' -KeyNumber 3 `
            -OutcomePath 'C:\state dir\r1-cutover.json' -RunId 'r1' -TimeoutSeconds 300 `
            -SwitchScript 'C:\s\switch.ps1'

        $cmd | Should -Match '^"C:\\Program Files\\PowerShell\\pwsh.exe" "-NoProfile" "-File" "C:\\a b\\Invoke-KeyCheckCutover.ps1"'
        $cmd | Should -Match '"-KeyNumber" "3"'
        $cmd | Should -Match '"-OutcomePath" "C:\\state dir\\r1-cutover.json"'
        $cmd | Should -Match '"-RunId" "r1"'
        $cmd | Should -Match '"-TimeoutSeconds" "300"'
        $cmd | Should -Match '"-SwitchScript" "C:\\s\\switch.ps1"'
        $cmd | Should -Not -Match 'RepairScript'
    }

    It 'creates the helper through Win32_Process.Create and it outlives its launcher' -Skip:($env:KEYCHECK_SKIP_PROCESS_SURVIVAL -eq '1') {
        # The launch path is real (not asserted by reading the script): a runner
        # creates the child the same way the cutover does, the runner is killed,
        # and the child must still write its marker. This proves the MECHANISM on
        # this host; it is not proof about a real `paseo restart`.
        $dir = Join-Path $TestDrive ("survive-{0}" -f ([guid]::NewGuid().ToString('N')))
        $null = New-Item -ItemType Directory -Path $dir -Force
        $marker = Join-Path $dir 'marker.txt'
        $pidFile = Join-Path $dir 'child-pid.txt'
        $child = Join-Path $dir 'child.ps1'
        $runner = Join-Path $dir 'runner.ps1'

        @'
param([string]$Marker)
Start-Sleep -Seconds 3
"survived" | Set-Content -LiteralPath $Marker
'@ | Set-Content -LiteralPath $child

        @"
param([string]`$Lib, [string]`$Child, [string]`$Marker, [string]`$PidFile)
. `$Lib
`$exe = Join-Path `$PSHOME 'pwsh.exe'
`$cmd = @(
    (ConvertTo-KeyCheckCommandLineArg `$exe)
    (ConvertTo-KeyCheckCommandLineArg '-NoProfile')
    (ConvertTo-KeyCheckCommandLineArg '-File')
    (ConvertTo-KeyCheckCommandLineArg `$Child)
    (ConvertTo-KeyCheckCommandLineArg `$Marker)
) -join ' '
`$launch = Start-KeyCheckDetachedProcess -CommandLine `$cmd
"`$(`$launch.Method)|`$(`$launch.ProcessId)" | Set-Content -LiteralPath `$PidFile
Start-Sleep -Seconds 30
"@ | Set-Content -LiteralPath $runner

        $lib = Join-Path $script:SkillRoot 'scripts\lib\KeyCheck.State.ps1'
        $runnerProc = Start-Process -FilePath $script:PwshExe -ArgumentList @(
            '-NoProfile', '-File', $runner, '-Lib', $lib, '-Child', $child, '-Marker', $marker, '-PidFile', $pidFile
        ) -PassThru -WindowStyle Hidden

        $childPid = 0
        try {
            $deadline = (Get-Date).AddSeconds(15)
            while (-not (Test-Path -LiteralPath $pidFile) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 200 }
            Test-Path -LiteralPath $pidFile | Should -BeTrue -Because 'the runner must report how it launched the helper'
            $parts = (Get-Content -LiteralPath $pidFile -Raw).Trim() -split '\|'
            $parts[0] | Should -Be 'Win32_Process.Create'
            $childPid = [int]$parts[1]

            Stop-Process -Id $runnerProc.Id -Force -ErrorAction SilentlyContinue

            $deadline = (Get-Date).AddSeconds(15)
            while (-not (Test-Path -LiteralPath $marker) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 250 }
            Test-Path -LiteralPath $marker | Should -BeTrue -Because 'the helper must outlive the process that created it'
            (Get-Content -LiteralPath $marker -Raw).Trim() | Should -Be 'survived'
        } finally {
            if (-not $runnerProc.HasExited) { Stop-Process -Id $runnerProc.Id -Force -ErrorAction SilentlyContinue }
            if ($childPid -gt 0) { Stop-Process -Id $childPid -Force -ErrorAction SilentlyContinue }
        }
    }
}



Describe 'Key Check adaptive cadence' {
    # The cadence is a PURE function: every case below fixes the clock, so no
    # test mocks time or touches the network. `Previous*` fields hold the gear
    # the run was on; the base gear is 3600 s (60 min) unless stated.

    BeforeAll {
        $script:T0 = [datetime]'2026-11-02T10:00:00'

        function New-CadenceCall {
            <#
            .SYNOPSIS
                Call the pure gear function with a one-hour-old previous sample and
                the weekly meter driven to `burn` points/hour, `remaining` short of
                the weekly trigger (96).
            #>
            param(
                [double]$Burn = 0,
                [double]$Remaining = 7,
                [int]$PreviousSeconds = 0,
                [string]$PreviousGear = '',
                [int]$BaseSeconds = 3600,
                [int]$LoosenStreak = 0,
                [int]$FloorTicks = 0,
                [hashtable]$PreviousOverride = $null,
                [hashtable]$CurrentOverride = $null,
                [string]$LastCheckAt = ''
            )
            $currentWk = 96 - $Remaining
            $previousWk = $currentWk - $Burn
            $previous = if ($PreviousOverride) { $PreviousOverride } else {
                New-Reading -KeyNumber 1 -Weekly $previousWk -Monthly 10
            }
            $current = if ($CurrentOverride) { $CurrentOverride } else {
                New-Reading -KeyNumber 1 -Weekly $currentWk -Monthly 10
            }
            $lastCheck = if ($LastCheckAt) { [datetime]$LastCheckAt } else { $script:T0.AddHours(-1) }
            Get-KeyCheckCadenceGear -Previous $previous -Current $current `
                -LastCheckAt $lastCheck -Now $script:T0 `
                -PreviousGear $PreviousGear -PreviousSeconds $PreviousSeconds `
                -BaseSeconds $BaseSeconds -LoosenStreak $LoosenStreak -FloorTicks $FloorTicks
        }
    }

    It 'keeps the base interval and no burn number on the first sample' {
        # no previous reading at all: the function must not invent a burn
        $g = Get-KeyCheckCadenceGear -Previous $null -Current (New-Reading -KeyNumber 1 -Weekly 89 -Monthly 10) `
            -LastCheckAt $null -Now $script:T0 -PreviousGear '' -PreviousSeconds 0 -BaseSeconds 3600
        $g.Seconds | Should -Be 3600
        $g.Gear | Should -Be '60m'
        $g.BurnPerMinute | Should -BeNullOrEmpty
        $g.EttMinutes | Should -BeNullOrEmpty -Because 'one sample is no burn: ETT is null, never infinity'
        $g.Reason | Should -Be 'first-sample'
    }

    It 'selects 60 min at 840 min to the trigger (0.5 %/h, 7 remaining)' {
        $g = New-CadenceCall -Burn 0.5 -Remaining 7
        $g.Seconds | Should -Be 3600
        $g.BurnPerMinute | Should -Be ([double](0.5 / 60))
        $g.EttMinutes | Should -Be 840
        $g.Remaining | Should -Be 7
    }

    It 'reads the minute ladder: 300 -> 60, 180 -> 30, 90 -> 15, 40 -> 5, 12 -> 1' {
        # One sample hour apart, 7 points short of the weekly trigger; the burn
        # is chosen so that ETT (in MINUTES) lands on each rung of the ladder.
        $cases = @(
            @{ Ett = 300; Burn = 7 / 5 }
            @{ Ett = 180; Burn = 7 / 3 }
            @{ Ett = 90; Burn = 7 / 1.5 }
            @{ Ett = 40; Burn = 7 / (40 / 60) }
            @{ Ett = 12; Burn = 7 / (12 / 60) }
        )
        $expected = @{ 300 = 3600; 180 = 1800; 90 = 900; 40 = 300; 12 = 60 }
        foreach ($case in $cases) {
            $g = New-CadenceCall -Burn $case.Burn -Remaining 7
            $g.EttMinutes | Should -BeGreaterThan ($case.Ett - 1) -Because "ETT $($case.Ett) min"
            $g.EttMinutes | Should -BeLessThan ($case.Ett + 1) -Because "ETT $($case.Ett) min"
            $g.Seconds | Should -Be $expected[$case.Ett] -Because "ETT $($case.Ett) min"
        }
    }

    It 'selects 30 min at 3.5 h to the trigger (2 %/h)' {
        (New-CadenceCall -Burn 2 -Remaining 7).Seconds | Should -Be 1800
    }

    It 'selects 15 min at 1.75 h to the trigger (4 %/h)' {
        (New-CadenceCall -Burn 4 -Remaining 7).Seconds | Should -Be 900
    }

    It 'selects 5 min at 52 min to the trigger (8 %/h)' {
        (New-CadenceCall -Burn 8 -Remaining 7).Seconds | Should -Be 300
    }

    It 'holds 5 min at 21 min and drops to the 1 min floor at 16 min' {
        (New-CadenceCall -Burn 20 -Remaining 7).Seconds | Should -Be 300
        (New-CadenceCall -Burn 15 -Remaining 4).Seconds | Should -Be 60
    }

    It 'picks the binding meter: monthly drives when weekly is quiet' {
        $previous = New-Reading -KeyNumber 1 -Weekly 20 -Monthly 93
        $current = New-Reading -KeyNumber 1 -Weekly 20 -Monthly 95
        $g = Get-KeyCheckCadenceGear -Previous $previous -Current $current `
            -LastCheckAt $script:T0.AddHours(-1) -Now $script:T0 -PreviousSeconds 3600
        $g.EttMinutes | Should -Be 90
        $g.Remaining | Should -Be 3
        $g.Seconds | Should -Be 900
    }

    It 'never reads an unreported weekly meter as 0 %' {
        $previous = New-Reading -KeyNumber 1 -Weekly $null -Monthly 95
        $current = New-Reading -KeyNumber 1 -Weekly $null -Monthly 96
        $g = Get-KeyCheckCadenceGear -Previous $previous -Current $current `
            -LastCheckAt $script:T0.AddHours(-1) -Now $script:T0 -PreviousSeconds 3600
        $g.Remaining | Should -Be 2
        $g.EttMinutes | Should -Be 120
        $g.Seconds | Should -Be 1800
    }

    It 'keeps the previous gear and leaves ETT null when the meters did not move' {
        $same = New-Reading -KeyNumber 1 -Weekly 89 -Monthly 10
        $g = Get-KeyCheckCadenceGear -Previous $same -Current $same `
            -LastCheckAt $script:T0.AddHours(-1) -Now $script:T0 `
            -PreviousGear '15m' -PreviousSeconds 900
        $g.Seconds | Should -Be 900
        $g.Gear | Should -Be '15m'
        # A flat window does not change the gear on the first tick; it only starts
        # the loosen streak (two consecutive flat ticks are needed to loosen).
        $g.Reason | Should -BeLike 'loosen-pending*'
        $g.EttMinutes | Should -BeNullOrEmpty -Because 'zero measured burn yields null, never infinity'
    }

    It 'discards burn history for a tick when a reset crossed between samples' {
        $previous = New-Reading -KeyNumber 1 -Weekly 80 -Monthly 10 -WeeklyResets '2026-11-02T09:30:00'
        $current = New-Reading -KeyNumber 1 -Weekly 5 -Monthly 10 -WeeklyResets '2026-11-09T09:30:00'
        $g = Get-KeyCheckCadenceGear -Previous $previous -Current $current `
            -LastCheckAt $script:T0.AddHours(-1) -Now $script:T0 `
            -PreviousGear '15m' -PreviousSeconds 900
        $g.Seconds | Should -Be 900
        $g.Reason | Should -Be 'window-reset'
    }

    It 'measures a short fallback window and names it when the history is younger than the guard' {
        # Two samples 5 minutes apart cannot PROVE an hourly burn, but they are
        # all the history there is: measure them and say `window-short` rather
        # than freeze the gear until a 15-minute pair appears.
        $previous = New-Reading -KeyNumber 1 -Weekly 85 -Monthly 10
        $current = New-Reading -KeyNumber 1 -Weekly 89 -Monthly 10
        $g = Get-KeyCheckCadenceGear -Previous $previous -Current $current `
            -LastCheckAt $script:T0.AddMinutes(-5) -Now $script:T0 `
            -PreviousGear '15m' -PreviousSeconds 900
        # 4 points / 5 min leaves 7 points -> 8.75 min to trigger -> the 1-min rung.
        $g.Seconds | Should -Be 60
        $g.Reason | Should -BeLike 'tightened*window-short*'
        $g.BurnPerMinute | Should -Not -BeNullOrEmpty
    }

    It 'tightens immediately in heartbeat and loosens there on the same tick (near keeps two ticks)' {
        $tighten = New-CadenceCall -Burn 30 -Remaining 7 -PreviousSeconds 900 -PreviousGear '15m'
        $tighten.Seconds | Should -Be 60
        $tighten.LoosenStreak | Should -Be 0

        # Heartbeat RE-DERIVES from ETT every tick: ETT 840 min must reach the top
        # gear on the tick that measured it, not after a two-tick wait - keeping
        # the fast gear across that wait is exactly the cl-common-8yq defect.
        $better = New-CadenceCall -Burn 0.5 -Remaining 7 -PreviousSeconds 60 -PreviousGear '1m'
        $better.Seconds | Should -Be 3600
        $better.Reason | Should -BeLike 'loosened*'
        $better.LoosenStreak | Should -Be 0

        # `near` keeps the anti-flap hysteresis: one quiet tick cannot stretch a
        # key inside the escalation band to its ceiling.
        $nearFirst = Get-KeyCheckCadenceGear -Previous (New-Reading -KeyNumber 1 -Weekly 89.5 -Monthly 10) `
            -Current (New-Reading -KeyNumber 1 -Weekly 90 -Monthly 10) `
            -LastCheckAt $script:T0.AddHours(-1) -Now $script:T0 `
            -PreviousGear '1m' -PreviousSeconds 60 -Phase 'near'
        $nearFirst.Seconds | Should -Be 60
        $nearFirst.Reason | Should -BeLike 'loosen-pending*'
        $nearFirst.LoosenStreak | Should -Be 1

        $nearSecond = Get-KeyCheckCadenceGear -Previous (New-Reading -KeyNumber 1 -Weekly 89.5 -Monthly 10) `
            -Current (New-Reading -KeyNumber 1 -Weekly 90 -Monthly 10) `
            -LastCheckAt $script:T0.AddHours(-1) -Now $script:T0 `
            -PreviousGear '1m' -PreviousSeconds 60 -LoosenStreak 1 -Phase 'near'
        $nearSecond.Seconds | Should -Be 900            # the near ceiling
        $nearSecond.LoosenStreak | Should -Be 0
    }

    It 'caps the one-minute ticks at 20 per run and holds at 5 min' {
        $spinning = New-CadenceCall -Burn 30 -Remaining 7 -PreviousSeconds 60 -PreviousGear '1m' -FloorTicks 20
        $spinning.Seconds | Should -Be 300
        $spinning.Reason | Should -BeLike 'cadence-floor-cap*'
        $spinning.FloorTick | Should -BeFalse

        $stillCounting = New-CadenceCall -Burn 30 -Remaining 7 -PreviousSeconds 60 -PreviousGear '1m' -FloorTicks 5
        $stillCounting.Seconds | Should -Be 60
        $stillCounting.FloorTick | Should -BeTrue
    }

    It 'clamps each phase at its ceiling: near 15 min, heartbeat 60 min, floor 1 min' {
        # GO6 on 2026-11-02: 92 wk burning ~1 %/h -> 4 points left -> 240 min
        # ETT. The ladder says 30 min, but `near` owns a 15-minute ceiling, so a
        # key already inside the band is looked at every quarter hour - not
        # hourly, and not every 2 minutes.
        $previous = New-Reading -KeyNumber 6 -Weekly 91 -Monthly 20
        $current = New-Reading -KeyNumber 6 -Weekly 92 -Monthly 20
        $gear = Get-KeyCheckCadenceGear -Previous $previous -Current $current `
            -LastCheckAt $script:T0.AddHours(-1) -Now $script:T0 -PreviousSeconds 3600
        $gear.EttMinutes | Should -Be 240
        $gear.Seconds | Should -Be 1800              # the ladder's gear
        Get-KeyCheckCadenceSeconds -Phase 'heartbeat' -CadenceSeconds $gear.Seconds | Should -Be 1800
        Get-KeyCheckCadenceSeconds -Phase 'near' -CadenceSeconds $gear.Seconds | Should -Be 900

        # Below an hour the same ladder applies in both phases.
        Get-KeyCheckCadenceSeconds -Phase 'near' -CadenceSeconds 300 | Should -Be 300
        # And the floor holds everywhere: never faster than a minute.
        Get-KeyCheckCadenceSeconds -Phase 'near' -CadenceSeconds 60 | Should -Be 60
        Get-KeyCheckCadenceSeconds -Phase 'heartbeat' -CadenceSeconds 30 | Should -Be 60

        # A 15-minute base gear is not stretched by either ceiling.
        Get-KeyCheckCadenceSeconds -Phase 'heartbeat' -CadenceSeconds 900 | Should -Be 900
    }

    It 'writes exactly one audit line per gear change and none when unchanged' {
        $state = [pscustomobject]@{
            cadenceGear         = ''
            cadenceSeconds      = 0
            cadenceReason       = ''
            cadenceChanges      = @()
            burnPerMinute       = $null
            ettMinutes          = $null
            cadenceLoosenStreak = 0
            cadenceFloorTicks   = 0
        }

        $base = [pscustomobject]@{ Seconds = 3600; Gear = '60m'; Reason = 'first-sample'; BurnPerMinute = $null; EttMinutes = $null; Remaining = $null; LoosenStreak = 0; FloorTick = $false }
        (Update-KeyCheckCadence -State $state -Decision $base -Now $script:T0 -RunId 'r1') |
            Should -BeNullOrEmpty -Because 'establishing the base gear is not a change'

        $fast = [pscustomobject]@{ Seconds = 60; Gear = '1m'; Reason = 'tightened'; BurnPerMinute = 0.3333333333333333; EttMinutes = 21; Remaining = 7; LoosenStreak = 0; FloorTick = $true }
        $entry = Update-KeyCheckCadence -State $state -Decision $fast -Now $script:T0.AddMinutes(1) -RunId 'r1'
        $entry | Should -Not -BeNullOrEmpty
        $entry.kind | Should -Be 'cadence'
        $entry.fromSeconds | Should -Be 3600
        $entry.toSeconds | Should -Be 60
        $entry.remaining | Should -Be 7
        $entry.reason | Should -Be 'tightened'
        $entry.ettMinutes | Should -Be 21
        $entry.PSObject.Properties['hoursToTrigger'] | Should -BeNullOrEmpty -Because 'the renamed unit is the only one audited'
        $entry.burnPerMinute | Should -BeGreaterThan 0.33

        (Update-KeyCheckCadence -State $state -Decision $fast -Now $script:T0.AddMinutes(2) -RunId 'r1') |
            Should -BeNullOrEmpty -Because 'an unchanged gear must not write a line'

        @($state.cadenceChanges).Count | Should -Be 1
        $state.cadenceGear | Should -Be '1m'
        $state.cadenceSeconds | Should -Be 60
        $state.cadenceFloorTicks | Should -Be 2
    }

    It 'migrates a legacy hoursToTrigger state once, in minutes, and drops the old field' {
        # A run that died on the old code keeps its cadence: the read-time shim
        # converts hours -> minutes so a resumed run does not restart the ladder.
        $legacy = [pscustomobject]@{
            runId           = 'r-legacy'
            cadenceSeconds  = 3600
            cadenceGear     = '60m'
            burnPerHour     = 1
            hoursToTrigger  = 6
            cadenceChanges  = @()
        }
        $completed = Complete-KeyCheckState -State $legacy -Defaults ([ordered]@{ ettMinutes = $null })
        $completed.ettMinutes | Should -Be 360
        $completed.PSObject.Properties['hoursToTrigger'] | Should -BeNullOrEmpty -Because 'the shim converts, it does not keep two units'

        # Same samples as before the rename: the gear is the one the migrated
        # ETT (360 min) implies, so a resumed run continues where it left off.
        $previous = New-Reading -KeyNumber 6 -Weekly 89 -Monthly 20
        $current = New-Reading -KeyNumber 6 -Weekly 90 -Monthly 20
        $gear = Get-KeyCheckCadenceGear -Previous $previous -Current $current `
            -LastCheckAt $script:T0.AddHours(-1) -Now $script:T0 -PreviousSeconds 3600
        $gear.EttMinutes | Should -Be 360
        $gear.Seconds | Should -Be 3600

        # And the next write carries only the minutes field.
        $path = Join-Path $TestDrive 'state-legacy-migrated.json'
        Write-KeyCheckState -Path $path -State $completed
        $written = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $written.ettMinutes | Should -Be 360
        $written.PSObject.Properties['hoursToTrigger'] | Should -BeNullOrEmpty -Because 'the old field is dropped on the next write'
    }
}



Describe 'Key Check ETT sample window' {
    # The defect (cl-common-6yr): ETT needed two samples at least 15 minutes
    # apart, but a 5-minute gear produces consecutive polls closer than the
    # guard, so a qualifying pair never formed and ETT stayed null FOREVER -
    # the gear froze and could neither tighten toward the trigger nor loosen.
    # The fix keeps a bounded history per meter and measures over the oldest
    # sample that is at least the guard window old.

    BeforeAll {
        $script:W0 = [datetime]'2026-11-02T10:00:00'

        function New-Sample {
            param([datetime]$At, [double]$Wk = 0, [double]$Mo = 10)
            [pscustomobject]@{ at = $At.ToString('yyyy-MM-ddTHH:mm:ss'); wk = $Wk; mo = $Mo }
        }
    }

    It 'keeps ETT non-null when three samples five minutes apart span the guard window' {
        # 89 -> 90 -> 91 -> 92 wk over 15 minutes: the live 5-minute gear never
        # produced a qualifying pair from "the previous poll" (it is 5 min old).
        $samples = @(
            (New-Sample -At $script:W0.AddMinutes(-15) -Wk 89)
            (New-Sample -At $script:W0.AddMinutes(-10) -Wk 90)
            (New-Sample -At $script:W0.AddMinutes(-5) -Wk 91)
            (New-Sample -At $script:W0 -Wk 92)
        )
        $current = New-Reading -KeyNumber 1 -Weekly 92 -Monthly 10

        $g = Get-KeyCheckCadenceGear -Samples $samples -Current $current -Now $script:W0 `
            -PreviousGear '5m' -PreviousSeconds 300 -BaseSeconds 3600

        # 3 points / 15 min = 0.2 %/min, 4 points left -> 20 min to trigger.
        $g.EttMinutes | Should -Be 20
        $g.BurnPerMinute | Should -BeGreaterThan 0.19
        $g.BurnPerMinute | Should -BeLessThan 0.21
        $g.Reason | Should -BeLike '*window-15m*' -Because 'the window used is named'
        $g.Seconds | Should -Be 300
    }

    It 'tightens 5 -> 1 when the windowed burn implies under 20 minutes to the trigger' {
        $samples = @(
            (New-Sample -At $script:W0.AddMinutes(-15) -Wk 89)
            (New-Sample -At $script:W0 -Wk 92.5)
        )
        $current = New-Reading -KeyNumber 1 -Weekly 92.5 -Monthly 10

        $g = Get-KeyCheckCadenceGear -Samples $samples -Current $current -Now $script:W0 `
            -PreviousGear '5m' -PreviousSeconds 300 -BaseSeconds 3600

        # 3.5 points / 15 min -> 15 min to trigger, below the 20-minute rung.
        $g.EttMinutes | Should -Be 15
        $g.Seconds | Should -Be 60
        $g.Reason | Should -BeLike 'tightened*'
    }

    It 'loosens only after two consecutive flat windowed ticks' {
        $flat = @(
            (New-Sample -At $script:W0.AddMinutes(-20) -Wk 92)
            (New-Sample -At $script:W0.AddMinutes(-15) -Wk 92)
            (New-Sample -At $script:W0.AddMinutes(-5) -Wk 92)
            (New-Sample -At $script:W0 -Wk 92)
        )
        $current = New-Reading -KeyNumber 1 -Weekly 92 -Monthly 10

        $first = Get-KeyCheckCadenceGear -Samples $flat -Current $current -Now $script:W0 `
            -PreviousGear '5m' -PreviousSeconds 300 -BaseSeconds 3600
        $first.Seconds | Should -Be 300 -Because 'the first flat tick only starts the streak'
        $first.Reason | Should -BeLike 'loosen-pending*'
        $first.EttMinutes | Should -BeNullOrEmpty

        $second = Get-KeyCheckCadenceGear -Samples $flat -Current $current -Now $script:W0 `
            -PreviousGear '5m' -PreviousSeconds 300 -BaseSeconds 3600 -LoosenStreak 1
        $second.Seconds | Should -Be 3600
        $second.Reason | Should -BeLike 'loosened*'
        $second.LoosenStreak | Should -Be 0
    }

    It 'keeps the previous gear and leaves ETT null with a single sample' {
        $samples = @( (New-Sample -At $script:W0.AddMinutes(-5) -Wk 89) )
        $current = New-Reading -KeyNumber 1 -Weekly 92 -Monthly 10
        $g = Get-KeyCheckCadenceGear -Samples $samples -Current $current -Now $script:W0 `
            -PreviousGear '15m' -PreviousSeconds 900 -BaseSeconds 3600

        $g.Seconds | Should -Be 900
        $g.Gear | Should -Be '15m'
        $g.EttMinutes | Should -BeNullOrEmpty
        $g.Reason | Should -Be 'first-sample'
    }

    It 'bounds the sample ring and keeps the newest samples' {
        $ring = @()
        for ($i = 0; $i -lt 20; $i++) {
            $step = Add-KeyCheckCadenceSample -Samples $ring `
                -Reading (New-Reading -KeyNumber 1 -Weekly (70 + $i) -Monthly 10) `
                -Now $script:W0.AddMinutes($i)
            $ring = @($step.Samples)
        }
        # 12 entries, oldest pruned, newest retained - the ring never grows.
        $ring.Count | Should -Be 12
        $ring[0].wk | Should -Be 78
        $ring[-1].wk | Should -Be 89
    }

    It 'clears the ring on a generation change and on a resetsAt crossing' {
        $current = New-Reading -KeyNumber 1 -Weekly 92 -Monthly 10
        $signature = Get-KeyCheckCadenceResetsSignature -Reading $current
        $ring = @(
            (New-Sample -At $script:W0.AddMinutes(-15) -Wk 89)
            (New-Sample -At $script:W0.AddMinutes(-5) -Wk 91)
        )

        $kept = Add-KeyCheckCadenceSample -Samples $ring -Reading $current -Now $script:W0 `
            -Generation 2 -PreviousGeneration 2 -PreviousSignature $signature
        $kept.Cleared | Should -BeFalse
        @($kept.Samples).Count | Should -Be 3

        $newGeneration = Add-KeyCheckCadenceSample -Samples $ring -Reading $current -Now $script:W0 `
            -Generation 3 -PreviousGeneration 2 -PreviousSignature $signature
        $newGeneration.Cleared | Should -BeTrue -Because 'a cutover is a different key: no cross-key delta'
        @($newGeneration.Samples).Count | Should -Be 1

        $resetted = New-Reading -KeyNumber 1 -Weekly 3 -Monthly 10 -WeeklyResets '2026-11-16T00:00'
        $afterReset = Add-KeyCheckCadenceSample -Samples $ring -Reading $resetted -Now $script:W0 `
            -Generation 2 -PreviousGeneration 2 -PreviousSignature $signature
        $afterReset.Cleared | Should -BeTrue -Because 'a window reset invalidates the old pairs'
        @($afterReset.Samples).Count | Should -Be 1
    }

    It 'carries non-null ettMinutes into state and names the window in the audit reason' {
        $samples = @(
            (New-Sample -At $script:W0.AddMinutes(-15) -Wk 89)
            (New-Sample -At $script:W0.AddMinutes(-5) -Wk 91)
            (New-Sample -At $script:W0 -Wk 92)
        )
        $current = New-Reading -KeyNumber 1 -Weekly 92 -Monthly 10
        $g = Get-KeyCheckCadenceGear -Samples $samples -Current $current -Now $script:W0 `
            -PreviousGear '60m' -PreviousSeconds 3600 -BaseSeconds 3600

        $state = [pscustomobject]@{
            cadenceGear = '60m'; cadenceSeconds = 3600; cadenceReason = ''
            cadenceChanges = @(); cadenceLoosenStreak = 0; cadenceFloorTicks = 0
            ettMinutes = $null; burnPerMinute = $null
        }
        $entry = Update-KeyCheckCadence -State $state -Decision $g -Now $script:W0 -RunId 'r-window'

        $entry | Should -Not -BeNullOrEmpty
        $entry.reason | Should -BeLike '*window-15m*' -Because 'the cadence audit line names the window used'
        $state.ettMinutes | Should -Not -BeNullOrEmpty
        $state.ettMinutes | Should -Be 20 -Because '3 points over the 15-minute window, 4 left -> 20 min'
    }
}



Describe 'Key Check post-cutover cadence (cl-common-8yq)' {
    # Measured defect (state runId 20261102-172700, generation 1 / GO3):
    #   ettMinutes 488.7, cadenceSeconds 60, cadenceGear 1m
    # after an audit line `300 -> 60 (tightened/window-short, ETT -8.11, remaining -1)`.
    # Three rules were missing and every case below is stated in SECONDS so a
    # unit slip cannot pass.

    BeforeAll {
        $script:T0 = [datetime]'2026-11-02T10:00:00'

        function New-GearProbe {
            <#
            .SYNOPSIS
                Drive the pure gear function to a specific ETT (minutes) with one
                hour of history and 7 points of weekly headroom.
            #>
            param(
                [double]$EttMinutes,
                [int]$PreviousSeconds = 0,
                [string]$PreviousGear = '',
                [string]$Phase = 'heartbeat',
                [int]$BaseSeconds = 3600,
                $PriorEttMinutes = $null
            )
            $remaining = 7.0
            $burnPerHour = $remaining / ($EttMinutes / 60)
            $previous = New-Reading -KeyNumber 1 -Weekly (96 - $remaining - $burnPerHour) -Monthly 10
            $current = New-Reading -KeyNumber 1 -Weekly (96 - $remaining) -Monthly 10
            Get-KeyCheckCadenceGear -Previous $previous -Current $current `
                -LastCheckAt $script:T0.AddHours(-1) -Now $script:T0 `
                -PreviousGear $PreviousGear -PreviousSeconds $PreviousSeconds `
                -BaseSeconds $BaseSeconds -Phase $Phase -PriorEttMinutes $PriorEttMinutes
        }
    }

    It 'clamps a crossed trigger to zero headroom instead of a negative ETT' {
        # 97 wk is PAST the 96 trigger: the old code computed remaining -1 and
        # ETT -8.11 min and audited them as real numbers.
        $previous = New-Reading -KeyNumber 1 -Weekly 96 -Monthly 10
        $current = New-Reading -KeyNumber 1 -Weekly 97 -Monthly 10
        $g = Get-KeyCheckCadenceGear -Previous $previous -Current $current `
            -LastCheckAt $script:T0.AddHours(-1) -Now $script:T0 `
            -PreviousGear '15m' -PreviousSeconds 900
        $g.Remaining | Should -Be 0 -Because 'headroom is never negative'
        $g.EttMinutes | Should -Be 0
        $g.EttMinutes | Should -BeGreaterOrEqual 0
        $g.Seconds | Should -Be 60 -Because 'a crossed trigger is urgent for THIS reading'

        # ... and only for that reading: the ladder still works on the next one.
        $recovered = New-GearProbe -EttMinutes 660
        $recovered.Seconds | Should -Be 3600
    }

    It 'sets the phase ceiling on a generation change, naming the reset' {
        # A fresh key at 5 % with no history must not inherit the 1-minute gear.
        $fresh = New-Reading -KeyNumber 3 -Weekly 5 -Monthly 5
        $heartbeat = Get-KeyCheckCadenceGear -Samples @() -Current $fresh -Now $script:T0 `
            -PreviousSeconds 60 -PreviousGear '1m' -GenerationReset -Phase 'heartbeat' `
            -PriorEttMinutes 488.7
        $heartbeat.Seconds | Should -Be 3600
        $heartbeat.Gear | Should -Be '60m'
        $heartbeat.Reason | Should -BeLike '*generation-reset*'
        $heartbeat.EttMinutes | Should -BeNullOrEmpty -Because 'the old key''s ETT is not this key''s'

        $near = Get-KeyCheckCadenceGear -Samples @() -Current $fresh -Now $script:T0 `
            -PreviousSeconds 60 -PreviousGear '1m' -GenerationReset -Phase 'near'
        $near.Seconds | Should -Be 900
        $near.Gear | Should -Be '15m'
        $near.Reason | Should -BeLike '*generation-reset*near*'
    }

    It 'reads the ETT ladder in seconds: 488 -> 3600, 200 -> 1800, 90 -> 900, 40 -> 300, 12 -> 60' {
        $cases = @(
            @{ Ett = 488; Seconds = 3600 }
            @{ Ett = 200; Seconds = 1800 }
            @{ Ett = 90; Seconds = 900 }
            @{ Ett = 40; Seconds = 300 }
            @{ Ett = 12; Seconds = 60 }
        )
        foreach ($case in $cases) {
            $g = New-GearProbe -EttMinutes ([double]$case.Ett)
            $g.EttMinutes | Should -BeGreaterThan ($case.Ett - 1) -Because "ETT $($case.Ett) min"
            $g.EttMinutes | Should -BeLessThan ($case.Ett + 1) -Because "ETT $($case.Ett) min"
            $g.Seconds | Should -Be $case.Seconds -Because "ETT $($case.Ett) min must select $($case.Seconds) s"
        }
    }

    It 'reaches 3600 s even when the run interval (base gear) is 15 minutes' {
        # The live run was started with -IntervalMinutes 15, so the base gear was
        # 900; the ladder used to be capped by it, which is why 488 min of ETT
        # could never select the hourly gear.
        $g = New-GearProbe -EttMinutes 488 -BaseSeconds 900
        $g.Seconds | Should -Be 3600
        $g.Gear | Should -Be '60m'
    }

    It 'holds 3600 s across five heartbeat ticks at ETT ~ 480 (no drift back to 60)' {
        $base = [datetime]'2026-11-02T10:00:00'
        $seconds = 0
        $gear = ''
        $streak = 0
        $floor = 0
        $samples = @()
        $previous = $null
        $wk = 40.0                     # 56 points of headroom, 0.875/h -> ~64 h

        for ($tick = 0; $tick -lt 6; $tick++) {
            $now = $base.AddHours($tick)
            $current = New-Reading -KeyNumber 1 -Weekly $wk -Monthly 10
            $step = Add-KeyCheckCadenceSample -Samples $samples -Reading $current -Now $now -Previous $previous
            $g = Get-KeyCheckCadenceGear -Samples $step.Samples -Current $current -Previous $previous `
                -LastCheckAt $(if ($null -ne $previous) { $now.AddHours(-1) } else { $null }) -Now $now `
                -PreviousGear $gear -PreviousSeconds $seconds -BaseSeconds 900 `
                -LoosenStreak $streak -FloorTicks $floor -Phase 'heartbeat'
            if ($tick -gt 0) {
                $g.Seconds | Should -Be 3600 -Because "tick $tick must stay on the hourly gear"
                $g.Gear | Should -Be '60m'
            }
            $seconds = [int]$g.Seconds
            $gear = [string]$g.Gear
            $streak = [int]$g.LoosenStreak
            $floor = [int]$g.FloorTicks
            $samples = $step.Samples
            $previous = $current
            $wk += 0.875
        }
    }

    It 'never holds a fast gear on a keep path when the last measured ETT implies a slow one' {
        # A flat window cannot measure fresh burn, but the last ETT (480 min) is
        # still the best evidence there is: hold 3600 s, never the 60 s gear.
        $same = New-Reading -KeyNumber 1 -Weekly 89 -Monthly 10
        $g = Get-KeyCheckCadenceGear -Previous $same -Current $same `
            -LastCheckAt $script:T0.AddHours(-1) -Now $script:T0 `
            -PreviousGear '1m' -PreviousSeconds 60 -PriorEttMinutes 480
        $g.Seconds | Should -Be 3600
        $g.Reason | Should -BeLike '*ett-held*'
        $g.EttMinutes | Should -Be 480 -Because 'the last measured ETT is carried, not dropped'
    }

    It 'never seeds the sample ring from the exhausted key after a rescue' {
        $old = New-Reading -KeyNumber 6 -Weekly 97 -Monthly 99
        $fresh = New-Reading -KeyNumber 3 -Weekly 5 -Monthly 4
        $step = Add-KeyCheckCadenceSample -Samples @() -Reading $fresh -Now $script:T0 `
            -Previous $old -PreviousAt $script:T0.AddMinutes(-1) -Generation 1 -PreviousGeneration 1
        @($step.Samples).Count | Should -Be 1
        $step.Samples[0].wk | Should -Be 5 -Because 'a 97 -> 5 delta across keys would read as a huge negative burn'

        # A non-empty ring under an older generation is cleared and NAMED.
        $cleared = Add-KeyCheckCadenceSample -Samples @([pscustomobject]@{ at = '2026-11-02T09:00:00'; wk = 97; mo = 99 }) `
            -Reading $fresh -Now $script:T0 -Generation 1 -PreviousGeneration 0
        $cleared.Cleared | Should -BeTrue
        $cleared.ClearReason | Should -Be 'generation'
        @($cleared.Samples).Count | Should -Be 1
    }

    It 'resets the gear to the phase ceiling in the post-cutover state itself' {
        $state = [pscustomobject]@{
            runId             = 'r-cut'
            generation        = 0
            phase             = 'trigger'
            activeKeyNumber   = 6
            replacementKey    = 3
            cadenceSeconds    = 60
            cadenceGear       = '1m'
            cadenceReason     = 'loosened/window-short'
            burnPerMinute     = 0.088
            ettMinutes        = 488.69
            cadenceChanges    = @()
            cadenceLoosenStreak = 3
            cadenceFloorTicks = 7
            cadenceSamples    = @([pscustomobject]@{ at = '2026-11-02T17:20:00'; wk = 97; mo = 99 })
            cadenceSampleSignature = 'sig'
            cadenceSampleGeneration = 0
            evidence          = @()
            deadline          = '2026-11-02T19:27:00'
        }
        $after = Update-KeyCheckAfterCutover -State $state -FromKeyNumber 6 -ToKeyNumber 3 `
            -Reading (New-Reading -KeyNumber 6 -Weekly 97 -Monthly 99) -Now $script:T0
        $after.generation | Should -Be 1
        $after.cadenceSeconds | Should -Be 900 -Because 'a verified rescue continues in near'
        $after.cadenceGear | Should -Be '15m'
        $after.cadenceReason | Should -BeLike 'generation-reset*'
        $after.ettMinutes | Should -BeNullOrEmpty -Because 'burn and ETT described the exhausted key'
        $after.burnPerMinute | Should -BeNullOrEmpty
        @($after.cadenceSamples).Count | Should -Be 0
        $after.cadenceFloorTicks | Should -Be 0
        $after.cadenceLoosenStreak | Should -Be 0
        $after.cadenceSampleGeneration | Should -Be 0 -Because 'the next tick must still report the reset'
        @($after.cadenceChanges).Count | Should -Be 1
        ($after.cadenceChanges)[0].to | Should -Be 900
        ($after.cadenceChanges)[0].reason | Should -BeLike 'generation-reset*'
        ($after.evidence -join "`n") | Should -BeLike '*cadence reset 60s -> 900s*'
    }

    It 'audits the reset with the seconds, the ETT and the reason' {
        $state = [pscustomobject]@{
            cadenceSeconds = 60; cadenceGear = '1m'; cadenceReason = ''; cadenceChanges = @()
            burnPerMinute = $null; ettMinutes = 488.69; cadenceLoosenStreak = 0; cadenceFloorTicks = 0
        }
        $decision = [pscustomobject]@{
            Seconds = 3600; Gear = '60m'; Reason = 'generation-reset/phase-heartbeat-ceiling'
            BurnPerMinute = $null; EttMinutes = $null; Remaining = $null; LoosenStreak = 0; FloorTick = $false
        }
        $entry = Update-KeyCheckCadence -State $state -Decision $decision -Now $script:T0 -RunId 'r-c' -Phase 'heartbeat'
        $entry | Should -Not -BeNullOrEmpty
        $entry.toSeconds | Should -Be 3600
        $entry.fromSeconds | Should -Be 60
        $entry.reason | Should -BeLike 'generation-reset*'
        $entry.phase | Should -Be 'heartbeat'
        $entry.Keys | Should -Contain 'ettMinutes' -Because 'the audit line carries the ETT that justified the gear'
        $entry.fromSeconds | Should -Be 60
        $entry.toSeconds | Should -Be 3600
        $state.cadenceSeconds | Should -Be 3600
        $state.cadenceGear | Should -Be '60m'
        $state.ettMinutes | Should -BeNullOrEmpty
    }
}

Describe 'Key Check adaptive cadence wiring' {

    It 'audits the gear change the runner derives from the persisted history' {
        $fixture = New-KeyCheckFixture -InUse 'cad-key-1' -Keys @{
            GO1 = 'cad-key-1'; GO2 = 'cad-key-2'
        } -Usage @{
            GO1 = @{ weekly = @{ percent = 79; status = 'ok'; resetsAt = '2026-11-09T00:00' }
                monthly = @{ percent = 10; status = 'ok'; resetsAt = '2026-11-20' } }
            GO2 = @{ weekly = @{ percent = 10; status = 'ok'; resetsAt = '2026-11-09T00:00' }
                monthly = @{ percent = 10; status = 'ok'; resetsAt = '2026-11-20' } }
        }

        # A run that died an hour ago after 59 wk / 10 mo, holding the base gear.
        # The burn (20 points/h) leaves 17 points to the weekly trigger -> 0.85 h,
        # so the next tick must tighten 3600 s -> 300 s and audit exactly that.
        $now = Get-Date
        $seeded = [ordered]@{
            runId                    = 'r-cadence'
            startedAt                = $now.AddHours(-1).ToString('o')
            deadlineAt               = $now.AddHours(1).ToString('o')
            deadline                 = $now.AddHours(1).ToString('o')
            phase                    = 'heartbeat'
            generation               = 0
            checks                   = 0
            activeKeyNumber          = 1
            replacementKey           = 0
            replacementKeyNumber     = 0
            lastCheckAt              = $now.AddHours(-1).ToString('o')
            lastReading              = [ordered]@{
                KeyNumber = 1; Label = 'GO1'
                Weekly    = [ordered]@{ Percent = 59; Status = 'ok'; ResetsAt = '2026-11-09T00:00' }
                Monthly   = [ordered]@{ Percent = 10; Status = 'ok'; ResetsAt = '2026-11-20' }
            }
            consecutiveRateLimited    = 0
            consecutiveCannotEvaluate = 0
            consecutiveBelowThreshold = 0
            armed                    = $false
            evidence                 = @()
            cadenceGear              = '60m'
            cadenceSeconds           = 3600
        }
        ($seeded | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $fixture.StatePath

        $run = Invoke-KeyCheck -Fixture $fixture -IntervalMinutes 60 -DurationHours 4 `
            -ExtraArgs @('-DryRun', '-SkipCanary', '-MaxChecks', '2')

        $run.ExitCode | Should -Be 0 -Because $run.Output
        # 20 points/h leaves 17 points to the weekly trigger = 0.85 h (51 min).
        $run.State.cadenceSeconds | Should -Be 300
        $run.State.cadenceGear | Should -Be '5m'
        # The live defect (cl-common-6yr): the second tick, 5 minutes later, used
        # to answer `insufficient-samples` and quit measuring burn for the rest of
        # the run. It now keeps a windowed ETT (the 1-hour history is still in the
        # ring) and names the window it used.
        $run.State.cadenceReason | Should -BeLike '*window-15m*'
        $run.State.ettMinutes | Should -Not -BeNullOrEmpty
        @($run.State.cadenceSamples).Count | Should -Be 3

        # The measured burn lives on the transition, which is what a reviewer reads.
        $change = @($run.State.cadenceChanges)[0]
        $change.from | Should -Be 3600
        $change.to | Should -Be 300
        $change.burnPerMinute | Should -BeGreaterThan 0.3315
        $change.burnPerMinute | Should -BeLessThan 0.3350
        $change.ettMinutes | Should -BeGreaterThan 50
        $change.ettMinutes | Should -BeLessThan 52
        $change.remaining | Should -Be 17

        $cadence = @($run.Audit | Where-Object { $_.kind -eq 'cadence' })
        $cadence.Count | Should -Be 1 -Because 'one line per transition, never per tick'
        $cadence[0].fromSeconds | Should -Be 3600
        $cadence[0].toSeconds | Should -Be 300
        $cadence[0].remaining | Should -Be 17
        @($run.State.cadenceChanges).Count | Should -Be 1
    }

    It 'resets the gear to the ceiling on the first tick after a cutover (cl-common-8yq)' {
        # The measured defect: after GO6 -> GO3 the state carried generation 1,
        # ettMinutes 488.7 and cadenceSeconds 60; the ring was reset, ETT went
        # null for a tick, and "keep the previous gear" preserved 60 s against a
        # key 5 % used.
        $fixture = New-KeyCheckFixture -InUse 'cad-key-3' -Keys @{
            GO3 = 'cad-key-3'; GO6 = 'cad-key-6'
        } -Usage @{
            GO3 = @{ weekly = @{ percent = 5; status = 'ok'; resetsAt = '2026-11-09T00:00' }
                monthly = @{ percent = 4; status = 'ok'; resetsAt = '2026-11-20' } }
            GO6 = @{ weekly = @{ percent = 97; status = 'ok'; resetsAt = '2026-11-09T00:00' }
                monthly = @{ percent = 99; status = 'ok'; resetsAt = '2026-11-20' } }
        }

        $now = Get-Date
        $seeded = [ordered]@{
            runId                   = 'r-post-cutover'
            startedAt               = $now.AddHours(-1).ToString('o')
            deadlineAt              = $now.AddHours(1).ToString('o')
            deadline                = $now.AddHours(1).ToString('o')
            phase                   = 'near'
            generation              = 1
            checks                  = 0
            activeKeyNumber         = 3
            replacementKey          = 0
            replacementKeyNumber    = 0
            lastCheckAt             = $now.AddSeconds(-61).ToString('o')
            lastReading             = [ordered]@{
                KeyNumber = 6; Label = 'GO6'
                Weekly    = [ordered]@{ Percent = 97; Status = 'ok'; ResetsAt = '2026-11-09T00:00' }
                Monthly   = [ordered]@{ Percent = 99; Status = 'ok'; ResetsAt = '2026-11-20' }
            }
            consecutiveRateLimited    = 0
            consecutiveCannotEvaluate = 0
            consecutiveBelowThreshold = 0
            armed                     = $false
            evidence                  = @()
            cadenceGear               = '1m'
            cadenceSeconds            = 60
            cadenceReason             = 'loosened/window-short'
            ettMinutes                = 488.69
            burnPerMinute             = 0.088
            cadenceFloorTicks         = 3
            cadenceLoosenStreak       = 1
            cadenceSamples            = @([ordered]@{ at = $now.AddSeconds(-61).ToString('yyyy-MM-ddTHH:mm:ss'); wk = 97; mo = 99 })
            cadenceSampleSignature    = 'signature-of-the-old-key'
            cadenceSampleGeneration   = 0
        }
        ($seeded | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $fixture.StatePath

        $run = Invoke-KeyCheck -Fixture $fixture -IntervalMinutes 15 -DurationHours 2 `
            -ExtraArgs @('-DryRun', '-SkipCanary', '-MaxChecks', '1')

        $run.ExitCode | Should -Be 0 -Because $run.Output
        $run.State.cadenceSeconds | Should -Be 900 -Because 'the near ceiling, not the 60 s gear of the exhausted key'
        $run.State.cadenceGear | Should -Be '15m'
        $run.State.cadenceReason | Should -BeLike '*generation-reset*'
        @($run.State.cadenceSamples) | Where-Object { $_.wk -eq 97 } | Should -BeNullOrEmpty `
            -Because 'the exhausted key''s samples must not seed the fresh key'
        $cadence = @($run.Audit | Where-Object { $_.kind -eq 'cadence' })
        $cadence.Count | Should -Be 1 -Because 'the reset is a transition, and it is audited once'
        $cadence[0].fromSeconds | Should -Be 60
        $cadence[0].toSeconds | Should -Be 900
        $cadence[0].reason | Should -BeLike '*generation-reset*'
        $cadence[0].phase | Should -Be 'near'
    }
}

Describe 'Key Check first reading (cl-common-79y)' {
    # Measured defect: the heartbeat loop slept a FULL cadence before its first
    # reading. A watch restarted more often than its gear (measured: ~11 min
    # restart interval against a 15 min cadence) therefore produced ZERO checks:
    # started 20:53:10, `state.checks` still 56 and `lastCheckAt` still 20:48:49
    # at 21:05:33 while the process was alive and healthy.
    #
    # The contract: the FIRST metered reading of a process happens at t ~ 0
    # (a fresh start already reads in `initial`; a resume reads in its first loop
    # iteration), and only the readings AFTER it are spaced by the cadence.
    #
    # No test waits a real cadence in its green path: the clock is injected by
    # watching the audit/state timestamps and killing the process, so a passing
    # run proves ordering, not patience.

    BeforeAll {
        function New-HeartbeatResumeFixture {
            <#
            .SYNOPSIS
                A healthy GO1, a resumable run parked at `heartbeat` with a 60 s
                (1-minute) gear, and a deadline well in the future.
            #>
            param([int]$Checks = 4, [double]$AgeMinutes = 4, [double]$WindowMinutes = 30)
            $fixture = New-KeyCheckFixture -InUse 'fr-key-1' -Keys @{
                GO1 = 'fr-key-1'; GO3 = 'fr-key-3'
            } -Usage @{
                GO1 = @{ weekly = @{ percent = 10; status = 'ok'; resetsAt = '2026-11-09T00:00' }
                    monthly = @{ percent = 20; status = 'ok'; resetsAt = '2026-11-20' } }
                GO3 = @{ weekly = @{ percent = 0; status = 'ok'; resetsAt = '2026-11-09T00:00' }
                    monthly = @{ percent = 10; status = 'ok'; resetsAt = '2026-11-09' } }
            }
            $now = Get-Date
            $started = $now.AddMinutes(-$AgeMinutes)
            $seeded = [ordered]@{
                runId                     = '20260101-090000'
                startedAt                 = $started.ToString('o')
                deadline                  = $now.AddMinutes($WindowMinutes).ToString('o')
                deadlineAt                = $now.AddMinutes($WindowMinutes).ToString('o')
                intervalMinutes           = 1
                durationHours             = 0.5
                phase                     = 'heartbeat'
                activeKeyNumber           = 1
                replacementKey            = 0
                replacementKeyNumber      = 0
                generation                = 0
                checks                    = $Checks
                lastReading               = $null
                lastCheckAt               = $started.ToString('o')
                lastResult                = 'heartbeat (watching)'
                cadenceGear               = '1m'
                cadenceSeconds            = 60
                cadenceReason             = 'tightened'
                cadenceChanges            = @()
                cadenceSamples            = @()
                cadenceSampleSignature    = ''
                cadenceSampleGeneration   = 0
                consecutiveRateLimited    = 0
                consecutiveCannotEvaluate = 0
                consecutiveBelowThreshold = 0
                armed                     = $false
                evidence                  = @('seeded for the first-reading contract')
                dryRun                    = $false
                cutovers                  = @()
                drift                     = $null
                canary                    = $null
                usageSource               = 'fixture'
                endedAt                   = $null
                endReason                 = ''
                exitCode                  = 0
            }
            ($seeded | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $fixture.StatePath
            return $fixture
        }

        function Start-Watch {
            <#
            .SYNOPSIS
                Start a real watch process with NO -NoWait, so every wait the loop
                performs is a real wait and the ordering is observable.
            #>
            param($Fixture, [int]$IntervalMinutes = 1, [double]$DurationHours = 0.02, [int]$MaxChecks = 0)
            $cliArgs = @(
                '-NoProfile', '-File', $script:ScriptPath,
                '-UsageFile', $Fixture.UsagePath,
                '-KeyValuesFile', $Fixture.KeysPath,
                '-StatePath', $Fixture.StatePath,
                '-AuditPath', $Fixture.AuditPath,
                '-SkipDrift', '-SkipCanary', '-NoLedger',
                '-IntervalMinutes', "$IntervalMinutes", '-DurationHours', "$DurationHours"
            )
            if ($MaxChecks -gt 0) { $cliArgs += @('-MaxChecks', "$MaxChecks") }
            $tag = [guid]::NewGuid().ToString('N')
            $out = Join-Path $Fixture.Dir "watch-$tag.out.txt"
            $err = Join-Path $Fixture.Dir "watch-$tag.err.txt"
            [pscustomobject]@{
                Process   = Start-Process -FilePath $script:PwshExe -ArgumentList $cliArgs -PassThru `
                    -WindowStyle Hidden -RedirectStandardOutput $out -RedirectStandardError $err
                Output    = $out
                Error     = $err
                StartedAt = (Get-Date)
            }
        }

        function Get-WatchChecks {
            param($Fixture)
            if (-not (Test-Path -LiteralPath $Fixture.StatePath)) { return 0 }
            try { return [int](Get-Content -LiteralPath $Fixture.StatePath -Raw | ConvertFrom-Json).checks }
            catch { return 0 }
        }

        function Wait-WatchChecks {
            param($Fixture, [int]$Minimum, [int]$TimeoutSeconds = 25)
            $stopAt = (Get-Date).AddSeconds($TimeoutSeconds)
            while ((Get-Date) -lt $stopAt) {
                if ((Get-WatchChecks -Fixture $Fixture) -ge $Minimum) { return $true }
                Start-Sleep -Milliseconds 250
            }
            return ((Get-WatchChecks -Fixture $Fixture) -ge $Minimum)
        }

        function Get-WatchOutput {
            param($Watch)
            if (Test-Path -LiteralPath $Watch.Output) { Get-Content -LiteralPath $Watch.Output -Raw } else { '' }
        }

        function Get-HeartbeatCheckRows {
            param($Fixture)
            if (-not (Test-Path -LiteralPath $Fixture.AuditPath)) { return @() }
            return @(Get-Content -LiteralPath $Fixture.AuditPath | Where-Object { $_.Trim() } |
                ForEach-Object { $_ | ConvertFrom-Json } |
                Where-Object { $_.kind -eq 'check' -and $_.phase -in @('heartbeat', 'near') })
        }

        function Stop-Watch {
            param($Watch)
            try {
                if (-not $Watch.Process.HasExited) {
                    Stop-Process -Id $Watch.Process.Id -Force -ErrorAction SilentlyContinue
                }
            } catch { }
            try { $null = $Watch.Process.WaitForExit(5000) } catch { }
        }
    }

    It 'takes its first reading immediately instead of one cadence later (the measured zero-check failure)' {
        # 60 s cadence, and a hard 25 s budget: the read must not wait for the
        # gear. Red before the fix: nothing is read until t = 60 s.
        $fixture = New-HeartbeatResumeFixture -Checks 56
        $watch = Start-Watch -Fixture $fixture -DurationHours 0.02
        try {
            $read = Wait-WatchChecks -Fixture $fixture -Minimum 57 -TimeoutSeconds 25
            $elapsed = [Math]::Round(((Get-Date) - $watch.StartedAt).TotalSeconds, 1)
            $read | Should -BeTrue -Because "the first reading must not wait a 60 s cadence; elapsed ${elapsed}s; output: $(Get-WatchOutput -Watch $watch)"
            $elapsed | Should -BeLessThan 25

            $rows = Get-HeartbeatCheckRows -Fixture $fixture
            $rows.Count | Should -BeGreaterThan 0 -Because 'the reading is a real check row, not a state bump'
            $rows[-1].key | Should -Be 'GO1'
        } finally {
            Stop-Watch -Watch $watch
        }
    }

    It 'records a reading on every start inside one cadence window' {
        # The measured restart interval (~11 min) was shorter than the gear
        # (15 min), so NO incarnation ever read the meter. Two starts inside one
        # 60 s window must produce two readings.
        $fixture = New-HeartbeatResumeFixture -Checks 56
        $expected = 56
        for ($start = 1; $start -le 2; $start++) {
            $watch = Start-Watch -Fixture $fixture -DurationHours 0.01
            try {
                (Wait-WatchChecks -Fixture $fixture -Minimum ($expected + 1) -TimeoutSeconds 20) |
                    Should -BeTrue -Because "start $start must read before the cadence elapses; output: $(Get-WatchOutput -Watch $watch)"
            } finally {
                Stop-Watch -Watch $watch
                Start-Sleep -Milliseconds 400
            }
            $expected = Get-WatchChecks -Fixture $fixture
        }
        $expected | Should -Be 58 -Because 'two starts, two readings'
        @(Get-HeartbeatCheckRows -Fixture $fixture).Count | Should -Be 2
    }

    It 'still spaces subsequent readings by one cadence (a hot spin fails this)' {
        # The company the first-reading rule must keep: reading #2 is one full
        # gear (60 s here) after reading #1, and the run performs exactly the two
        # readings it was allowed. A loop that stopped waiting would pass the
        # first two tests and fail this one.
        $fixture = New-HeartbeatResumeFixture -Checks 0 -AgeMinutes 0
        $watch = Start-Watch -Fixture $fixture -DurationHours 0.05 -MaxChecks 2
        try {
            (Wait-WatchChecks -Fixture $fixture -Minimum 1 -TimeoutSeconds 25) |
                Should -BeTrue -Because "reading #1 must be immediate; output: $(Get-WatchOutput -Watch $watch)"
            (Wait-WatchChecks -Fixture $fixture -Minimum 2 -TimeoutSeconds 90) |
                Should -BeTrue -Because "reading #2 must arrive one cadence later; output: $(Get-WatchOutput -Watch $watch)"
        } finally {
            Stop-Watch -Watch $watch
        }

        $rows = Get-HeartbeatCheckRows -Fixture $fixture
        $rows.Count | Should -Be 2 -Because 'no extra reads (max-checks 2) and no hot spin'
        $first = [datetime]::Parse($rows[0].ts, [cultureinfo]::InvariantCulture)
        $second = [datetime]::Parse($rows[1].ts, [cultureinfo]::InvariantCulture)
        $gap = ($second - $first).TotalSeconds
        $gap | Should -BeGreaterThan 45 -Because "the second reading must be spaced by the 60 s cadence (gap ${gap}s)"
        $gap | Should -BeLessThan 120 -Because "it must not drift past the cadence (gap ${gap}s)"
        $toFirst = ($first - $watch.StartedAt).TotalSeconds
        $toFirst | Should -BeLessThan 25 -Because 'the first reading is at t ~ 0'
    }

    It 'resumes a near-phase run without a pre-reading wait either' {
        # Same rule for the other sleeping branch: `near` used to sleep first too.
        $fixture = New-HeartbeatResumeFixture -Checks 3 -AgeMinutes 3
        $state = Get-Content -LiteralPath $fixture.StatePath -Raw | ConvertFrom-Json
        $state.phase = 'near'
        $state.replacementKeyNumber = 3
        $state.replacementKey = 3
        $state.armed = $true
        ($state | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $fixture.StatePath

        $watch = Start-Watch -Fixture $fixture -DurationHours 0.02
        try {
            (Wait-WatchChecks -Fixture $fixture -Minimum 4 -TimeoutSeconds 25) |
                Should -BeTrue -Because "a resumed `near` run must read at t ~ 0, not after its gear; output: $(Get-WatchOutput -Watch $watch)"
            $rows = Get-HeartbeatCheckRows -Fixture $fixture
            $rows[0].phase | Should -Be 'near'
        } finally {
            Stop-Watch -Watch $watch
        }
    }
}


Describe 'Key Check successor decision (cl-common-0ai)' {
    # Measured defect: run 20261102-235920 ended at its 8 h deadline at 14:59:20Z
    # and NOTHING armed a successor, so the active key was unwatched until the
    # next Hub tick noticed ~9 minutes later. One rule answers "should something
    # be watching right now", and both the armed successor and the standing
    # supervisor consume it.

    It 'starts when nothing has ever run' {
        $decision = Get-KeyCheckSuccessorDecision -State $null -Lock $null
        $decision.Action | Should -Be 'start'
        $decision.Reason | Should -Be 'no-state'
    }

    It 'skips while a live lock is held, naming the holder' {
        $now = Get-Date
        $lock = [pscustomobject]@{
            Exists = $true; Stale = $false; Reason = 'held'; ProcessAlive = $true
            AgeSeconds = 30; HeartbeatAgeSeconds = 5
            Lock = [pscustomobject]@{
                pid = 4242; runId = 'live-run'
                startedAt = $now.AddMinutes(-5).ToString('o'); heartbeatAt = $now.ToString('o')
            }
        }
        $state = [pscustomobject]@{ runId = 'live-run'; phase = 'near'; endReason = ''; endedAt = $null }

        $decision = Get-KeyCheckSuccessorDecision -State $state -Lock $lock

        $decision.Action | Should -Be 'skip' -Because 'a duplicate watcher could cut over twice'
        $decision.Reason | Should -Be 'locked-by-run'
        $decision.HolderRunId | Should -Be 'live-run'
    }

    It 'starts on a stale lock instead of honouring a dead holder' {
        $lock = [pscustomobject]@{
            Exists = $true; Stale = $true; Reason = 'pid-dead'; ProcessAlive = $false
            AgeSeconds = 400; HeartbeatAgeSeconds = 400
            Lock = [pscustomobject]@{ pid = 999999; runId = 'crashed-run' }
        }
        $state = [pscustomobject]@{ runId = 'crashed-run'; phase = 'heartbeat'; endReason = ''; endedAt = $null }

        $decision = Get-KeyCheckSuccessorDecision -State $state -Lock $lock

        $decision.Action | Should -Be 'start'
        $decision.Reason | Should -Be 'run-not-live' -Because 'a stale lock is not a watcher'
    }

    It 'starts when the previous run ENDED - the measured lapse' {
        $state = [pscustomobject]@{
            runId = '20261102-235920'; phase = 'end'; endReason = 'deadline'
            endedAt = (Get-Date).ToString('o'); deadlineAt = (Get-Date).AddMinutes(-9).ToString('o')
        }

        $decision = Get-KeyCheckSuccessorDecision -State $state -Lock $null

        $decision.Action | Should -Be 'start'
        $decision.Reason | Should -Be 'run-ended'
        $decision.RunId | Should -Be '20261102-235920'
        $decision.EndReason | Should -Be 'deadline'
    }

    It 'starts (and therefore resumes) when a run is in flight with no live lock' {
        $state = [pscustomobject]@{
            runId = '20261103-080748'; phase = 'near'
            endedAt = $null; endReason = ''
            deadlineAt = (Get-Date).AddHours(6).ToString('o')
        }

        $decision = Get-KeyCheckSuccessorDecision -State $state -Lock $null

        $decision.Action | Should -Be 'start'
        $decision.Reason | Should -Be 'run-not-live'
    }

    It 'arms only on a deadline ending, and never under the seams' {
        Test-KeyCheckShouldArmSuccessor -EndReason 'deadline' | Should -BeTrue
        foreach ($reason in @('max-checks', 'window-expired-while-down', 'cutover-failed',
                'cutover-unproven', 'meter-unreadable', 'cannot-evaluate', 'no-eligible-replacement', '')) {
            Test-KeyCheckShouldArmSuccessor -EndReason $reason |
                Should -BeFalse -Because "'$reason' is a machine fault a fresh watch must not paper over"
        }
        Test-KeyCheckShouldArmSuccessor -EndReason 'deadline' -DryRun | Should -BeFalse
        Test-KeyCheckShouldArmSuccessor -EndReason 'deadline' -NoWait | Should -BeFalse
        Test-KeyCheckShouldArmSuccessor -EndReason 'deadline' -NoSuccessor | Should -BeFalse
    }

    It 'fires the successor at the deadline plus the grace beat' {
        $now = Get-Date

        (Get-KeyCheckSuccessorDelaySeconds -Deadline $now.AddSeconds(100) -Now $now -GraceSeconds 30) |
            Should -Be 130
        (Get-KeyCheckSuccessorDelaySeconds -Deadline $now.AddSeconds(-100) -Now $now -GraceSeconds 30) |
            Should -Be 30 -Because 'an already-passed deadline still leaves the grace beat'
    }

    It 'builds the successor argv as one quoted command line carrying its trigger source' {
        $cmd = Get-KeyCheckSuccessorCommandLine -PowerShellPath 'C:\Program Files\PowerShell\pwsh.exe' `
            -ScriptPath 'C:\a b\Invoke-KeyCheck.ps1' -DelaySeconds 28830 -ParentRunId '20261102-235920' `
            -IntervalMinutes 15 -DurationHours 8 -TriggeredBy 'successor-arm' `
            -Options ([ordered]@{ '-StatePath' = 'C:\s\state.json'; '-UsageFile' = '' })

        $cmd | Should -Match '^"C:\\Program Files\\PowerShell\\pwsh.exe" "-NoProfile" "-File" "C:\\a b\\Invoke-KeyCheck.ps1"'
        $cmd | Should -Match '"-StartAfterSeconds" "28830"'
        $cmd | Should -Match '"-TriggeredBy" "successor-arm"'
        $cmd | Should -Match '"-SuccessorOf" "20261102-235920"'
        $cmd | Should -Match '"-IntervalMinutes" "15"'
        $cmd | Should -Match '"-DurationHours" "8"'
        $cmd | Should -Match '"-StatePath" "C:\\s\\state.json"'
        $cmd | Should -Not -Match 'UsageFile' -Because 'an empty world value is not passed at all'
    }
}

Describe 'Key Check successor arm and liveness supervisor (cl-common-0ai)' {
    BeforeAll {
        function New-SuccessorStub {
            <#
            .SYNOPSIS
                A detached-successor stand-in: records the argv the real successor
                would receive, so the arm path is proven to have created a real
                process without starting a watch.
            #>
            param([string]$Dir)
            $marker = Join-Path $Dir 'successor-launched.txt'
            $path = Join-Path $Dir 'successor-stub.ps1'
            @"
param(
    [double]`$StartAfterSeconds = 0,
    [string]`$TriggeredBy = '',
    [string]`$SuccessorOf = '',
    [int]`$IntervalMinutes = 15,
    [double]`$DurationHours = 2,
    [string]`$StatePath = '',
    [string]`$AuditPath = ''
)
(`$TriggeredBy + '|' + `$SuccessorOf + '|' + `$StartAfterSeconds + '|' + `$IntervalMinutes + '|' + `$DurationHours + '|' + (Split-Path -Leaf `$StatePath)) |
    Add-Content -LiteralPath '$marker'
exit 0
"@ | Set-Content -LiteralPath $path
            [pscustomobject]@{ Script = $path; Marker = $marker }
        }

        function Wait-ForFile {
            param([string]$Path, [int]$TimeoutSeconds = 20)
            $stopAt = (Get-Date).AddSeconds($TimeoutSeconds)
            while (-not (Test-Path -LiteralPath $Path) -and (Get-Date) -lt $stopAt) { Start-Sleep -Milliseconds 200 }
            return (Test-Path -LiteralPath $Path)
        }

        function New-SuccessorFixture {
            New-KeyCheckFixture -InUse 'succ-key-1' -Keys @{ GO1 = 'succ-key-1'; GO3 = 'succ-key-3' } -Usage @{
                GO1 = @{ weekly = @{ percent = 10; status = 'ok'; resetsAt = '2026-11-09T00:00' }
                    monthly = @{ percent = 20; status = 'ok'; resetsAt = '2026-11-20' } }
                GO3 = @{ weekly = @{ percent = 0; status = 'ok'; resetsAt = '2026-11-09T00:00' }
                    monthly = @{ percent = 10; status = 'ok'; resetsAt = '2026-11-09' } }
            }
        }

        function Invoke-KeyCheckToDeadline {
            <#
            .SYNOPSIS
                Run the watch with NO -NoWait and a ~1 s budget, so it really
                reaches its deadline and really arms (or does not).
            #>
            param($Fixture, [string[]]$ExtraArgs = @(), [double]$DurationHours = 0.0003)
            $cliArgs = @(
                '-NoProfile', '-File', $script:ScriptPath,
                '-UsageFile', $Fixture.UsagePath,
                '-KeyValuesFile', $Fixture.KeysPath,
                '-StatePath', $Fixture.StatePath,
                '-AuditPath', $Fixture.AuditPath,
                '-SkipDrift', '-SkipCanary', '-NoLedger',
                '-IntervalMinutes', '1', '-DurationHours', "$DurationHours"
            )
            $cliArgs += $ExtraArgs
            $output = & $script:PwshExe @cliArgs 2>&1 | Out-String
            # A -DryRun probe writes under <dir>\dryrun\ (cl-common-jqm).
            $isDry = ($ExtraArgs -contains '-DryRun')
            $stateFile = if ($isDry) { Join-Path (Join-Path $Fixture.Dir 'dryrun') 'state.json' } else { $Fixture.StatePath }
            $auditFile = if ($isDry) { Join-Path (Join-Path $Fixture.Dir 'dryrun') 'keycheck.jsonl' } else { $Fixture.AuditPath }
            $state = $null
            if (Test-Path -LiteralPath $stateFile) {
                $state = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
            }
            $audit = @()
            if (Test-Path -LiteralPath $auditFile) {
                $audit = @(Get-Content -LiteralPath $auditFile | Where-Object { $_.Trim() } |
                    ForEach-Object { $_ | ConvertFrom-Json })
            }
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output; State = $state; Audit = $audit }
        }

        function New-TerminalStateFile {
            param(
                $Fixture,
                [string]$RunId = '20260101-090000',
                [datetime]$Deadline = (Get-Date).AddMinutes(-1),
                [string]$EndReason = 'deadline'
            )
            $state = [ordered]@{
                runId                     = $RunId
                startedAt                 = $Deadline.AddHours(-8).ToString('o')
                deadline                  = $Deadline.ToString('o')
                deadlineAt                = $Deadline.ToString('o')
                intervalMinutes           = 15
                durationHours             = 8
                phase                     = 'end'
                activeKeyNumber           = 1
                replacementKey            = 0
                replacementKeyNumber      = 0
                generation                = 0
                checks                    = 34
                lastReading               = $null
                lastCheckAt               = $Deadline.AddMinutes(-15).ToString('o')
                lastResult                = 'near (deadline)'
                consecutiveRateLimited    = 0
                consecutiveCannotEvaluate = 0
                consecutiveBelowThreshold = 0
                armed                     = $false
                evidence                  = @('seeded: a run that ended at its deadline')
                dryRun                    = $false
                cutovers                  = @()
                endedAt                   = $Deadline.ToString('o')
                endReason                 = $EndReason
                exitCode                  = 0
            }
            ($state | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $Fixture.StatePath
        }

        function New-LiveLockFile {
            param($Fixture, [int]$ProcessId = $PID, [string]$RunId = 'a-live-run')
            $lockPath = Join-Path (Split-Path -Parent $Fixture.StatePath) 'lock.json'
            $now = Get-Date
            [pscustomobject]@{
                pid         = $ProcessId
                host        = $env:COMPUTERNAME
                runId       = $RunId
                startedAt   = $now.AddMinutes(-2).ToString('o')
                heartbeatAt = $now.ToString('o')
            } | ConvertTo-Json | Set-Content -LiteralPath $lockPath
            return $lockPath
        }

        function Invoke-Liveness {
            param(
                $Fixture,
                [switch]$Restart,
                [string]$SuccessorScript,
                [string[]]$ExtraArgs = @()
            )
            $liveness = Join-Path $script:SkillRoot 'scripts\Test-KeyCheckLiveness.ps1'
            $cliArgs = @(
                '-NoProfile', '-File', $liveness,
                '-StatePath', $Fixture.StatePath,
                '-AuditPath', $Fixture.AuditPath,
                '-IntervalMinutes', '15', '-DurationHours', '8', '-Json'
            )
            if ($Restart) { $cliArgs += '-Restart' }
            if ($SuccessorScript) { $cliArgs += @('-SuccessorScript', $SuccessorScript) }
            $cliArgs += $ExtraArgs
            $output = & $script:PwshExe @cliArgs 2>&1 | Out-String
            $report = $null
            try { $report = $output | ConvertFrom-Json } catch { $report = $null }
            $audit = @()
            if (Test-Path -LiteralPath $Fixture.AuditPath) {
                $audit = @(Get-Content -LiteralPath $Fixture.AuditPath | Where-Object { $_.Trim() } |
                    ForEach-Object { $_ | ConvertFrom-Json })
            }
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output; Report = $report; Audit = $audit }
        }
    }

    It 'arms a one-shot successor at the deadline and records the trigger source' {
        $fixture = New-SuccessorFixture
        $stub = New-SuccessorStub -Dir $fixture.Dir

        $run = Invoke-KeyCheckToDeadline -Fixture $fixture -ExtraArgs @('-SuccessorScript', $stub.Script)

        $run.ExitCode | Should -Be 0 -Because $run.Output
        $run.State.endReason | Should -Be 'deadline'
        $run.State.successor.trigger | Should -Be 'successor-arm'
        $run.State.successor.armed | Should -BeTrue -Because "the successor must be armed, not merely noted: $($run.Output)"
        $run.State.successor.parentRunId | Should -Be $run.State.runId
        $run.State.successor.fireAt | Should -Not -BeNullOrEmpty

        $arm = @($run.Audit | Where-Object { $_.kind -eq 'successor' -and $_.action -eq 'armed' })
        $arm.Count | Should -Be 1 -Because $run.Output
        $arm[0].trigger | Should -Be 'successor-arm' -Because 'the audit must name the trigger source'
        $arm[0].runId | Should -Be $run.State.runId
        $arm[0].pid | Should -BeGreaterThan 0

        # A state flag is not an arm: a real detached process must exist, and it
        # must have been told to wait for the deadline.
        (Wait-ForFile -Path $stub.Marker) | Should -BeTrue -Because 'the successor must be a real process'
        $parts = (Get-Content -LiteralPath $stub.Marker -Raw).Trim() -split '\|'
        $parts[0] | Should -Be 'successor-arm'
        $parts[1] | Should -Be $run.State.runId
        [double]$parts[2] | Should -BeGreaterThan 0 -Because 'it fires at the deadline, not now'
        $parts[3] | Should -Be '1'
        [double]$parts[4] | Should -BeGreaterThan 0
        [double]$parts[4] | Should -BeLessThan 0.01
        $parts[5] | Should -Be 'state.json'
    }

    It 'never arms under -NoWait, -DryRun or -NoSuccessor' {
        $fixture = New-SuccessorFixture
        $stub = New-SuccessorStub -Dir $fixture.Dir

        # -NoWait is the existing test seam: it must never leave a process behind.
        $nowait = Invoke-KeyCheck -Fixture $fixture -ExtraArgs @('-SuccessorScript', $stub.Script, '-NoLedger') `
            -IntervalMinutes 1 -DurationHours 0.0001
        $nowait.State.endReason | Should -Be 'deadline' -Because $nowait.Output
        @($nowait.Audit | Where-Object { $_.kind -eq 'successor' }).Count |
            Should -Be 0 -Because '-NoWait spins and never arms'

        $dryFixture = New-SuccessorFixture
        $stub2 = New-SuccessorStub -Dir $dryFixture.Dir
        $dry = Invoke-KeyCheckToDeadline -Fixture $dryFixture -ExtraArgs @('-DryRun', '-SuccessorScript', $stub2.Script)
        $dry.State.endReason | Should -Be 'deadline' -Because $dry.Output
        @($dry.Audit | Where-Object { $_.kind -eq 'successor' }).Count |
            Should -Be 0 -Because '-DryRun is a rehearsal and must not start a real watch'

        $optOutFixture = New-SuccessorFixture
        $stub3 = New-SuccessorStub -Dir $optOutFixture.Dir
        $optOut = Invoke-KeyCheckToDeadline -Fixture $optOutFixture -ExtraArgs @('-NoSuccessor', '-SuccessorScript', $stub3.Script)
        @($optOut.Audit | Where-Object { $_.kind -eq 'successor' }).Count |
            Should -Be 0 -Because '-NoSuccessor is the operator opt-out'

        Test-Path -LiteralPath $stub.Marker | Should -BeFalse
        Test-Path -LiteralPath $stub2.Marker | Should -BeFalse
        Test-Path -LiteralPath $stub3.Marker | Should -BeFalse
    }

    It 'a triggered start SKIPS instead of duplicating a watcher that holds the lock' {
        $fixture = New-SuccessorFixture
        New-TerminalStateFile -Fixture $fixture
        $null = New-LiveLockFile -Fixture $fixture -ProcessId $PID -RunId 'the-live-watcher'
        $before = Get-Content -LiteralPath $fixture.StatePath -Raw

        # -StartAfterSeconds 0: fire immediately, as after a deadline that passed.
        $run = Invoke-KeyCheck -Fixture $fixture -ExtraArgs @(
            '-TriggeredBy', 'successor-arm', '-SuccessorOf', '20260101-090000', '-StartAfterSeconds', '0'
        )

        $run.ExitCode | Should -Be 0 -Because "a skip is not a failure: $($run.Output)"
        $skip = @($run.Audit | Where-Object { $_.kind -eq 'successor' })
        $skip.Count | Should -Be 1
        $skip[0].action | Should -Be 'skipped'
        $skip[0].trigger | Should -Be 'successor-arm'
        $skip[0].reason | Should -Be 'locked-by-run'
        $skip[0].holderRunId | Should -Be 'the-live-watcher'
        $skip[0].parentRunId | Should -Be '20260101-090000'

        @($run.Audit | Where-Object { $_.kind -eq 'lock' }).Count |
            Should -Be 0 -Because 'it must not even reach the lock: the pre-flight answer is final'
        (Get-Content -LiteralPath $fixture.StatePath -Raw) | Should -Be $before -Because 'a refused successor must not touch the run state'
    }

    It 'a triggered start RESUMES on the same deadline when the previous run is unfinished' {
        $fixture = New-SuccessorFixture
        # An in-flight state with no live lock: the run is unfinished, not ended.
        $state = [ordered]@{
            runId = '20260101-090000'; startedAt = (Get-Date).AddMinutes(-5).ToString('o')
            deadline = (Get-Date).AddMinutes(25).ToString('o'); deadlineAt = (Get-Date).AddMinutes(25).ToString('o')
            intervalMinutes = 1; durationHours = 0.5; phase = 'heartbeat'; activeKeyNumber = 1
            checks = 3; lastCheckAt = (Get-Date).AddMinutes(-2).ToString('o'); lastResult = 'heartbeat (watching)'
            evidence = @(); dryRun = $false; cutovers = @(); endReason = ''; endedAt = $null
        }
        ($state | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $fixture.StatePath
        $originalDeadline = [string]$state.deadlineAt

        $run = Invoke-KeyCheck -Fixture $fixture -ExtraArgs @(
            '-TriggeredBy', 'successor-arm', '-SuccessorOf', '20260101-090000', '-StartAfterSeconds', '0', '-MaxChecks', '1', '-NoLedger'
        )

        $run.ExitCode | Should -Be 0 -Because $run.Output
        $started = @($run.Audit | Where-Object { $_.kind -eq 'successor' -and $_.action -eq 'started' })
        $started.Count | Should -Be 1
        $started[0].reason | Should -Be 'run-not-live'
        $started[0].trigger | Should -Be 'successor-arm'
        $started[0].parentRunId | Should -Be '20260101-090000'
        $run.State.runId | Should -Be '20260101-090000' -Because 'a resumed run keeps its runId'
        # Compare the INSTANT, not the representation: ConvertFrom-Json re-types
        # an ISO string as [datetime], so a string compare is a type mismatch.
        ([datetime]$run.State.deadlineAt).Ticks | Should -Be ([datetime]$originalDeadline).Ticks -Because 'a resume never extends the deadline'
    }

    It 'the supervisor reports lapsed on a run that ended, without acting' {
        $fixture = New-SuccessorFixture
        New-TerminalStateFile -Fixture $fixture
        $stub = New-SuccessorStub -Dir $fixture.Dir

        $probe = Invoke-Liveness -Fixture $fixture

        $probe.ExitCode | Should -Be 3 -Because $probe.Output
        $probe.Report.status | Should -Be 'lapsed'
        $probe.Report.reason | Should -Be 'run-ended'
        $probe.Report.runId | Should -Be '20260101-090000'
        $probe.Report.action | Should -Be 'none'
        $probe.Report.restartCommand | Should -Match 'Invoke-KeyCheck\.ps1'
        @($probe.Audit | Where-Object { $_.kind -eq 'successor' }).Count |
            Should -Be 0 -Because 'a read-only assertion writes nothing to the watch ledger'
        Test-Path -LiteralPath $stub.Marker | Should -BeFalse
    }

    It 'the supervisor restarts a lapsed watch and records trigger supervisor' {
        $fixture = New-SuccessorFixture
        New-TerminalStateFile -Fixture $fixture
        $stub = New-SuccessorStub -Dir $fixture.Dir

        $probe = Invoke-Liveness -Fixture $fixture -Restart -SuccessorScript $stub.Script

        $probe.ExitCode | Should -Be 0 -Because $probe.Output
        $probe.Report.status | Should -Be 'lapsed'
        $probe.Report.action | Should -Be 'restarted'
        $probe.Report.pid | Should -BeGreaterThan 0

        $line = @($probe.Audit | Where-Object { $_.kind -eq 'successor' })
        $line.Count | Should -Be 1
        $line[0].trigger | Should -Be 'supervisor' -Because 'the record must distinguish supervisor from successor-arm'
        $line[0].action | Should -Be 'armed'
        $line[0].reason | Should -Be 'run-ended'

        (Wait-ForFile -Path $stub.Marker) | Should -BeTrue -Because 'the restart must be a real process'
        $parts = (Get-Content -LiteralPath $stub.Marker -Raw).Trim() -split '\|'
        $parts[0] | Should -Be 'supervisor'
        $parts[1] | Should -Be '20260101-090000'
        $parts[2] | Should -Be '0' -Because 'a lapsed watch is started now, not later'
        $parts[3] | Should -Be '15'
        $parts[4] | Should -Be '8'
    }

    It 'the supervisor NEVER restarts over a live lock' {
        $fixture = New-SuccessorFixture
        New-TerminalStateFile -Fixture $fixture
        $null = New-LiveLockFile -Fixture $fixture -ProcessId $PID -RunId 'the-live-watcher'
        $stub = New-SuccessorStub -Dir $fixture.Dir

        $probe = Invoke-Liveness -Fixture $fixture -Restart -SuccessorScript $stub.Script

        $probe.ExitCode | Should -Be 0 -Because $probe.Output
        $probe.Report.status | Should -Be 'live'
        $probe.Report.action | Should -Be 'none'
        $probe.Report.lock.runId | Should -Be 'the-live-watcher'
        Start-Sleep -Milliseconds 500
        Test-Path -LiteralPath $stub.Marker | Should -BeFalse -Because 'no duplicate watcher while a live run holds lock.json'
    }

    It 'the supervisor calls an unreadable state cannot-evaluate, never lapsed' {
        $fixture = New-SuccessorFixture
        Set-Content -LiteralPath $fixture.StatePath -Value '{ this is not json'
        $stub = New-SuccessorStub -Dir $fixture.Dir

        $probe = Invoke-Liveness -Fixture $fixture -Restart -SuccessorScript $stub.Script

        $probe.ExitCode | Should -Be 2 -Because $probe.Output
        $probe.Report.status | Should -Be 'cannot-evaluate'
        Test-Path -LiteralPath $stub.Marker | Should -BeFalse
    }
}
