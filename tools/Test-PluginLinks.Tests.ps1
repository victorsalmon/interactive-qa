#Requires -Version 7.0
<#
    Proof for tools/Test-PluginLinks.ps1.

    A fixture tree with one planted dead link MUST exit non-zero and name the
    dead link. A clean fixture MUST exit 0. Both are proven from the exit code
    of the script run as a child process, because the exit code is what CI and
    the package gate read.

    Self-containment is the default, so it is pinned as the primary contract: an
    in-package-only tree MUST pass, a link resolving outside the root MUST fail
    and say so, and a dead relative link MUST still fail. `-ResolvableOnly`
    restores the historical resolvability-only judging and MUST NOT be mistaken
    for a self-containment proof - the text of its own verdict line says so.
    Finally, the real package root MUST pass in the default mode: that is the
    regression pin for D10 (bead cl-common-1v5), where the gate reported OK while
    ten links escaped into the sibling `Skills/` tree.

    Run: pwsh -File interactive-qa/tools/Test-PluginLinks.Tests.ps1
#>

BeforeAll {
    $script:GateScript = Join-Path $PSScriptRoot 'Test-PluginLinks.ps1'
    $script:PwshPath = (Get-Command pwsh -ErrorAction Stop).Source

    if (-not (Test-Path -LiteralPath $script:GateScript)) {
        throw "Gate script not found: $script:GateScript"
    }

    function Invoke-Gate {
        param(
            [Parameter(Mandatory)][string] $RootPath,
            [switch] $SelfContained,
            [switch] $ResolvableOnly
        )

        $arguments = @('-NoProfile', '-NonInteractive', '-File', $script:GateScript, '-Root', $RootPath)
        if ($SelfContained) { $arguments += '-SelfContained' }
        if ($ResolvableOnly) { $arguments += '-ResolvableOnly' }

        $output = & $script:PwshPath @arguments 2>&1
        return [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Output   = ($output | Out-String)
        }
    }

    function New-Fixture {
        param(
            [Parameter(Mandatory)][string] $Path,
            [Parameter(Mandatory)][hashtable] $Files
        )

        foreach ($name in $Files.Keys) {
            $full = Join-Path $Path $name
            $parent = Split-Path -Parent $full
            if (-not (Test-Path -LiteralPath $parent)) {
                New-Item -ItemType Directory -Path $parent -Force | Out-Null
            }
            Set-Content -LiteralPath $full -Value $Files[$name] -Encoding utf8
        }
    }
}

Describe 'Test-PluginLinks gate' {

    Context 'a clean tree' {

        BeforeEach {
            $script:cleanRoot = Join-Path $TestDrive 'clean'
            New-Fixture -Path $script:cleanRoot -Files @{
                'README.md'          = "# Root`n`nSee [front door](SKILL.md) and [core](core/INVARIANTS.md).`n"
                'SKILL.md'           = "# Front door`n`nBack to [README](README.md).`n"
                'core/INVARIANTS.md' = "# Invariants`n`nSee [profile](PROFILE.template.md) and [member](../members/iqa-hub/SKILL.md).`n"
                'core/PROFILE.template.md' = "# Profile`n"
                'members/iqa-hub/SKILL.md' = "# Hub`n`n[core](../../core/INVARIANTS.md)`n"
            }
        }

        It 'exits 0' {
            $result = Invoke-Gate -RootPath $script:cleanRoot
            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match 'OK'
        }
    }

    Context 'a tree with one planted dead link' {

        BeforeEach {
            $script:deadRoot = Join-Path $TestDrive 'dead'
            New-Fixture -Path $script:deadRoot -Files @{
                'README.md'          = "# Root`n`nSee [front door](SKILL.md) and [gone](core/MISSING.md).`n"
                'SKILL.md'           = "# Front door`n`nBack to [README](README.md).`n"
                'core/INVARIANTS.md' = "# Invariants`n"
            }
        }

        It 'exits non-zero' {
            $result = Invoke-Gate -RootPath $script:deadRoot
            $result.ExitCode | Should -Not -Be 0
        }

        It 'names the dead link and its source file' {
            $result = Invoke-Gate -RootPath $script:deadRoot
            $result.Output | Should -Match 'core/MISSING\.md'
            $result.Output | Should -Match 'README\.md'
        }
    }

    Context 'link forms that must not count as dead' {

        BeforeEach {
            $script:formRoot = Join-Path $TestDrive 'forms'
            New-Fixture -Path $script:formRoot -Files @{
                'README.md' = @'
# Forms

- external: [site](https://example.com/x)
- mailto: [mail](mailto:a@example.com)
- anchor: [top](#forms)
- titled: [core](core/INVARIANTS.md "the core")
- image: ![logo](core/logo.png)
- fenced example: see below

```
[broken example](does-not-exist.md)
```
'@
                'core/INVARIANTS.md' = "# Invariants`n"
                'core/logo.png'      = 'not really a png'
            }
        }

        It 'exits 0' {
            $result = Invoke-Gate -RootPath $script:formRoot
            $result.ExitCode | Should -Be 0
        }
    }

    Context 'an absolute path link' {

        BeforeEach {
            $script:absRoot = Join-Path $TestDrive 'absolute'
            New-Fixture -Path $script:absRoot -Files @{
                'README.md' = "# Root`n`n[elsewhere](/some/absolute/file.md)`n"
            }
        }

        It 'is dead even when the target happens to exist' {
            $result = Invoke-Gate -RootPath $script:absRoot
            $result.ExitCode | Should -Not -Be 0
            $result.Output | Should -Match 'absolute path'
        }
    }

    Context 'a self-contained tree, default mode' {

        BeforeEach {
            $script:containedRoot = Join-Path $TestDrive 'contained'
            New-Fixture -Path $script:containedRoot -Files @{
                'README.md'          = "# Root`n`nSee [front door](SKILL.md) and [core](core/INVARIANTS.md).`n"
                'SKILL.md'           = "# Front door`n`nBack to [README](README.md).`n"
                'core/INVARIANTS.md' = "# Invariants`n`nSee [member](../members/iqa-hub/SKILL.md).`n"
                'members/iqa-hub/SKILL.md' = "# Hub`n`n[core](../../core/INVARIANTS.md)`n"
            }
        }

        It 'exits 0' {
            $result = Invoke-Gate -RootPath $script:containedRoot
            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match 'OK'
            $result.Output | Should -Match 'self-contained'
        }
    }

    Context 'a link resolving outside the package root' {

        BeforeEach {
            $script:escapeRoot = Join-Path $TestDrive 'boundary/package'
            New-Fixture -Path $script:escapeRoot -Files @{
                'README.md' = "# Root`n`nSee [outside](../../outside/README.md).`n"
            }
            New-Fixture -Path (Join-Path $TestDrive 'outside') -Files @{
                'README.md' = "# Outside`n"
            }
        }

        It 'fails by default even though the outside path exists' {
            $result = Invoke-Gate -RootPath $script:escapeRoot
            $result.ExitCode | Should -Not -Be 0
            $result.Output | Should -Match 'escapes package root'
        }

        It 'fails the same way under the explicit -SelfContained spelling' {
            $result = Invoke-Gate -RootPath $script:escapeRoot -SelfContained
            $result.ExitCode | Should -Not -Be 0
            $result.Output | Should -Match 'escapes package root'
            $result.Output | Should -Match 'README\.md'
        }

        It 'passes under -ResolvableOnly, whose verdict denies being a proof' {
            $result = Invoke-Gate -RootPath $script:escapeRoot -ResolvableOnly
            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match 'NOT a self-containment proof'
        }
    }

    Context 'a dead relative link, default mode' {

        BeforeEach {
            $script:containedDeadRoot = Join-Path $TestDrive 'contained-dead'
            New-Fixture -Path $script:containedDeadRoot -Files @{
                'README.md'          = "# Root`n`nSee [gone](core/MISSING.md).`n"
                'core/INVARIANTS.md' = "# Invariants`n"
            }
        }

        It 'exits non-zero and names the dead link' {
            $result = Invoke-Gate -RootPath $script:containedDeadRoot
            $result.ExitCode | Should -Not -Be 0
            $result.Output | Should -Match 'core/MISSING\.md'
        }
    }

    Context 'the real package root (D10 regression pin)' {

        It 'is self-contained in the default mode' {
            $packageRoot = Split-Path -Parent $PSScriptRoot
            $result = Invoke-Gate -RootPath $packageRoot
            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match 'OK'
            $result.Output | Should -Not -Match 'escapes package root'
        }
    }
}
