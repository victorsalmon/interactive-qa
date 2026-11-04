#Requires -Version 7
<#
    Regression proof for Get-HubCadence.ps1 (bead cl-common-cuz).

    THE DEFECT THIS PINS. A Hub turn started by its own heartbeat ran the cadence
    gate without a `-NextFireAt` (a heartbeat rung is not in the schedule store
    the caller reads), so the helper answered CREATE - "no rung is known for this
    turn; create at 1 min" - while exactly one ACTIVE MERGE-TICK rung was live for
    the repo. Obeying that line arms a SECOND active rung; the very tick that just
    fired is the rung it cannot see.

    Measured 2026-11-04 on two consecutive heartbeat runs (67a17dd8, 99d6cfc0):
    `-State prompt -Name hub-cl-common-heartbeat` printed
    `... - CREATE: no rung is known for this turn; create at 1 min` at the same
    moment `Test-SingleHubRung.ps1 -Repo cl-common` PASSed on schedule b3fdf56a
    (cron `*/4`).

    The three cases the fix must keep apart:

      (a) a rung EXISTS (the turn is that rung firing, or the caller proved one
          active rung) => never CREATE, never a create instruction;
      (b) a rung genuinely does NOT exist => CREATE, with a reason naming what
          was absent;
      (c) the helper cannot evaluate the rung it knows exists (no armed cron, no
          next fire) => `cannot-evaluate`, a named reason, NO creation
          instruction and no guessed cadence - exit 2.

    Run: pwsh -NoProfile -File vendor/interactive-qa/vendor/iqa-merge/Tests/Get-HubCadence.Tests.ps1
#>
[CmdletBinding()]
param()

BeforeAll {
    $script:Helper = Join-Path (Split-Path -Parent $PSScriptRoot) 'Get-HubCadence.ps1'
    if (-not (Test-Path -LiteralPath $script:Helper -PathType Leaf)) {
        throw "Get-HubCadence.ps1 not found beside the Tests folder: $($script:Helper)"
    }
    $script:Pwsh = (Get-Command pwsh -ErrorAction Stop).Source

    # The helper is a process, not a dot-sourced function: it exits 0/2 by design,
    # and the exit code is part of the contract (a cannot-evaluate is non-zero).
    function Invoke-Cadence {
        param([Parameter(Mandatory)][string[]]$Arguments)

        $stdout = & $script:Pwsh -NoProfile -File $script:Helper @Arguments 2>&1
        $exitCode = $LASTEXITCODE
        $text = @($stdout | ForEach-Object { [string]$_ }) -join "`n"

        $json = $null
        if ($Arguments -contains '-Json') {
            try { $json = $text | ConvertFrom-Json -Depth 6 } catch { $json = $null }
        }

        [pscustomobject]@{
            ExitCode = $exitCode
            Text     = $text
            Json     = $json
        }
    }

    function Get-CreationText {
        param([Parameter(Mandatory)][string]$Text)
        # A creation instruction is any line that tells the turn to arm a rung,
        # in either the JSON or the host form.
        return [bool]($Text -match 'create at|"Action":\s*"CREATE"|- CREATE:')
    }
}

Describe 'Get-HubCadence rung evidence (cl-common-cuz)' {

    Context '(a) a heartbeat rung is present for this repo' {

        It 'is HOLD, never CREATE, when the firing heartbeat is armed at the gear' {
            $result = Invoke-Cadence -Arguments @(
                '-State', 'healthy', '-FiredByHeartbeat', '-HeldCron', '*/2 * * * *', '-Json'
            )

            $result.ExitCode | Should -Be 0
            $result.Json.Action | Should -Be 'HOLD'
            $result.Json.Action | Should -Not -Be 'CREATE'
            $result.Json.CreationInstruction | Should -BeFalse
            $result.Json.RungKnown | Should -BeTrue
            Get-CreationText -Text $result.Text | Should -BeFalse
        }

        It 'is never CREATE when the caller proved one active rung exists' {
            $result = Invoke-Cadence -Arguments @(
                '-State', 'prompt', '-RungExists', '-HeldCron', '*/2 * * * *', '-Json'
            )

            $result.ExitCode | Should -Be 0
            $result.Json.Action | Should -Not -Be 'CREATE'
            $result.Json.CreationInstruction | Should -BeFalse
            $result.Text | Should -Not -Match 'create at'
        }

        It 'treats a held cron alone as a rung that already exists' {
            $result = Invoke-Cadence -Arguments @(
                '-State', 'healthy', '-HeldCron', '*/2 * * * *', '-Json'
            )

            $result.ExitCode | Should -Be 0
            $result.Json.RungKnown | Should -BeTrue
            $result.Json.Action | Should -Not -Be 'CREATE'
            $result.Json.CreationInstruction | Should -BeFalse
        }

        It 'names the satisfiable cron on a RECREATE instead of creating a second rung' {
            # Armed coarser than the gear: the answer is delete+create at the
            # satisfiable gear (one rung), never a bare CREATE beside the live one.
            $result = Invoke-Cadence -Arguments @(
                '-State', 'healthy', '-FiredByHeartbeat', '-HeldCron', '*/10 * * * *', '-Json'
            )

            $result.ExitCode | Should -Be 0
            $result.Json.Action | Should -Be 'RECREATE'
            $result.Json.CreationInstruction | Should -BeFalse
            $result.Json.SatisfiableCron | Should -Not -BeNullOrEmpty
        }

        It 'evaluates the armed gear when the caller supplies the next fire too' {
            $result = Invoke-Cadence -Arguments @(
                '-State', 'healthy',
                '-FiredByHeartbeat',
                '-HeldCron', '*/2 * * * *',
                '-NextFireAt', '2026-11-04T00:34:00-07:00',
                '-Now', '2026-11-04T00:33:00-07:00',
                '-Json'
            )

            $result.ExitCode | Should -Be 0
            $result.Json.Action | Should -Be 'HOLD'
            $result.Json.RungEvidence | Should -Be 'held-fire'
            $result.Json.CreationInstruction | Should -BeFalse
        }
    }

    Context '(b) a rung genuinely does not exist' {

        It 'answers CREATE with the reason naming the absent evidence' {
            $result = Invoke-Cadence -Arguments @('-State', 'healthy', '-Json')

            $result.ExitCode | Should -Be 0
            $result.Json.Action | Should -Be 'CREATE'
            $result.Json.CreationInstruction | Should -BeTrue
            $result.Json.RungKnown | Should -BeFalse
            $result.Json.Reason | Should -Match 'no rung'
            $result.Text | Should -Match 'CREATE'
        }
    }

    Context '(c) the helper cannot evaluate the rung it knows exists' {

        It 'says cannot-evaluate with a reason and no creation instruction' {
            # The heartbeat fired (so a rung exists) but the caller supplied
            # neither its armed cron nor its next fire.
            $result = Invoke-Cadence -Arguments @('-State', 'healthy', '-FiredByHeartbeat', '-Json')

            $result.ExitCode | Should -Be 2
            $result.Json.Action | Should -Be 'CANNOT-EVALUATE'
            $result.Json.CreationInstruction | Should -BeFalse
            $result.Json.RungKnown | Should -BeTrue
            $result.Json.Reason | Should -Match 'cannot be evaluated'
            $result.Text | Should -Match 'cannot-evaluate'
            $result.Text | Should -Not -Match 'create at'
            Get-CreationText -Text $result.Text | Should -BeFalse
        }

        It 'says cannot-evaluate rather than guessing when only existence is known' {
            $result = Invoke-Cadence -Arguments @('-State', 'prompt', '-RungExists', '-Json')

            $result.ExitCode | Should -Be 2
            $result.Json.Action | Should -Be 'CANNOT-EVALUATE'
            $result.Json.CreationInstruction | Should -BeFalse
            $result.Text | Should -Not -Match 'create at'
        }

        It 'still lapses on stand-down without a creation instruction' {
            $result = Invoke-Cadence -Arguments @('-State', 'stand-down', '-FiredByHeartbeat', '-Json')

            $result.ExitCode | Should -Be 0
            $result.Json.Action | Should -Be 'LAPSE'
            $result.Json.CreationInstruction | Should -BeFalse
        }
    }
}
