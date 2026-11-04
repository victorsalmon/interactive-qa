#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

<#
.SYNOPSIS
    Pester tests for the opencode-go key canary, Test-GoKey.ps1.

.DESCRIPTION
    There are two copies of this canary: the canonical one under
    Skills/credential-rescue/scripts (used by agent-spawn-capacity,
    Repair-Paseo, Invoke-KeyCheck, Get-OpencodeGoFreshness) and the copy under
    Skills/credential-rescue-watch/scripts (used only by that skill's own
    Invoke-CredentialRescueWatch.ps1). The two drifted once: the watch copy
    kept passing a flag the installed CLI no longer accepts, so it exited 1
    for EVERY key while the canonical copy answered fine — a blind canary is
    worse than none, because "key died" and "my probe is broken" look the same.

    The contract pinned here, against BOTH entry points:

      - the argument list handed to the opencode CLI carries no unsupported
        flag (specifically no `--variant`; the operative CLI -- opencode
        2.1.2 -- expresses a variant inside `--model provider/model#variant`);
      - the attempt asks for `--standalone` so a long-lived background server's
        frozen env can never answer for the key being probed;
      - a healthy key returns exit 0 and prints the `OK <model>/<variant>`
        first token.

    The CLI is stubbed with a .cmd shim that records its own command line, so
    these tests never touch the network and never spend a real key.
#>

BeforeAll {
    $script:PwshExe = Join-Path $PSHOME 'pwsh.exe'
    $script:SkillsRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..' '..')).Path
    $script:CanonicalScript = Join-Path $script:SkillsRoot 'credential-rescue\scripts\Test-GoKey.ps1'
    $script:WatchScript = Join-Path $script:SkillsRoot 'credential-rescue-watch\scripts\Test-GoKey.ps1'

    # A stub CLI: records the exact argument string it was handed, then answers
    # like a healthy provider. Nothing here reaches the network.
    function New-StubCli {
        param([string]$Reply = 'pong')

        $stub = Join-Path $TestDrive 'opencode-stub.cmd'
        $argLog = Join-Path $TestDrive 'opencode-stub-args.txt'
        @(
            '@echo off'
            ">`"$argLog`" echo %*"
            "echo $Reply"
            'exit /b 0'
        ) | Set-Content -LiteralPath $stub -Encoding ascii

        [pscustomobject]@{ Path = $stub; ArgLog = $argLog }
    }

    function Invoke-GoKey {
        param(
            [Parameter(Mandatory)][string]$ScriptPath,
            [Parameter(Mandatory)][string]$StubPath,
            [string[]]$Extra = @()
        )

        $argList = @(
            '-NoProfile', '-File', $ScriptPath,
            '-KeyValue', 'stub-key-not-secret',
            '-OpencodeCli', $StubPath,
            '-TimeoutSeconds', '45',
            '-MaxRetries', '1'
        ) + $Extra

        $output = & $script:PwshExe @argList 2>&1 | Out-String
        [pscustomobject]@{ Output = $output; ExitCode = $LASTEXITCODE }
    }
}

Describe 'Test-GoKey canary: CLI argument contract' -Tag 'canary' {

    Context '<_>' -ForEach @(
        @{ Name = 'canonical copy (credential-rescue)'; Script = 'CanonicalScript' }
        @{ Name = 'watch copy (credential-rescue-watch)'; Script = 'WatchScript' }
    ) {

        It 'does not pass the unsupported --variant flag to the CLI' {
            $stub = New-StubCli
            $result = Invoke-GoKey -ScriptPath (Get-Variable -Name $Script -Scope Script -ValueOnly) -StubPath $stub.Path

            Test-Path -LiteralPath $stub.ArgLog | Should -BeTrue -Because 'the stub must have run; a canary that never reaches the CLI proves nothing'
            $cliArgs = (Get-Content -LiteralPath $stub.ArgLog -Raw).Trim()
            $cliArgs | Should -Not -Match '--variant' -Because 'opencode 2.1.2 rejects --variant and prints help, so every key would look dead'
        }

        It 'asks for a standalone run and folds the variant into the model id' {
            $stub = New-StubCli
            $result = Invoke-GoKey -ScriptPath (Get-Variable -Name $Script -Scope Script -ValueOnly) -StubPath $stub.Path -Extra @('-Variant', 'low')

            $cliArgs = (Get-Content -LiteralPath $stub.ArgLog -Raw).Trim()
            $cliArgs | Should -Match '--standalone' -Because 'without it a background server answers with its own key verdict'
            $cliArgs | Should -Match '--model\s+opencode-go/deepseek-v4\.1-flash#low'
            $result.ExitCode | Should -Be 0
        }

        It 'returns exit 0 and the OK token for a healthy key' {
            $stub = New-StubCli
            $result = Invoke-GoKey -ScriptPath (Get-Variable -Name $Script -Scope Script -ValueOnly) -StubPath $stub.Path

            $result.ExitCode | Should -Be 0
            ($result.Output -split "`n")[0].Trim() | Should -Be 'OK opencode-go/deepseek-v4.1-flash/low'
        }
    }
}

Describe 'Test-GoKey canary: no second implementation' -Tag 'canary' {

    It 'keeps exactly one implementation of the CLI invocation' {
        $canonical = Get-Content -LiteralPath $script:CanonicalScript -Raw
        $watch = Get-Content -LiteralPath $script:WatchScript -Raw

        @($canonical -split "`n" | Where-Object { $_ -match '& \$cli run' }).Count |
            Should -Be 1 -Because 'the canonical copy owns the CLI invocation'

        @($watch -split "`n" | Where-Object { $_ -match '& \$cli run' }).Count |
            Should -Be 0 -Because 'the watch copy must forward to the canonical script, never re-implement the CLI call'

        @($watch -split "`n" | Where-Object { $_ -match 'credential-rescue[\\/]scripts[\\/]Test-GoKey\.ps1' }).Count |
            Should -BeGreaterThan 0 -Because 'the forwarder names the canonical script it delegates to'
    }
}
