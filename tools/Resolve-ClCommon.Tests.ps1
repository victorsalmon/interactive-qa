#Requires -Version 7
<#
    Proof for lib/Resolve-ClCommon.ps1 - the plugin's one contract for finding
    the cl-common install without bundling it.

    The resolver had to learn a second name. The machine sets CL_COMMON_HOME when
    cl-common is installed as a first-class dependency, but the code only ever
    read CL_COMMON_PATH, so an installed machine still resolved by accident
    through CL_REPOS_ROOT and an operator override on CL_COMMON_HOME did
    nothing. These tests pin the order and the legacy alias, because a resolver
    that silently picks the wrong checkout points the hub at the wrong fleet.

    Run: pwsh -NoProfile -File tools/Resolve-ClCommon.Tests.ps1
#>
[CmdletBinding()]
param()

BeforeAll {
    $script:Resolver = Join-Path (Split-Path -Parent $PSScriptRoot) 'lib/Resolve-ClCommon.ps1'

    function New-CommonRoot {
        param([string]$Parent, [string]$Name)
        $root = Join-Path $Parent $Name
        New-Item -ItemType Directory -Path (Join-Path $root 'Skills') -Force | Out-Null
        return $root
    }

    function New-NotCommonRoot {
        param([string]$Parent, [string]$Name)
        $root = Join-Path $Parent $Name
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        return $root
    }

    $script:Base = Join-Path $TestDrive 'resolve'
    New-Item -ItemType Directory -Path $script:Base -Force | Out-Null
    $script:HomeRoot = New-CommonRoot -Parent $script:Base -Name 'home-common'
    $script:LegacyRoot = New-CommonRoot -Parent $script:Base -Name 'legacy-common'
    $script:FleetRoot = Join-Path $script:Base 'fleet'
    New-Item -ItemType Directory -Path $script:FleetRoot -Force | Out-Null
    $script:FleetCommon = New-CommonRoot -Parent $script:FleetRoot -Name 'cl-common'
    $script:Decoy = New-NotCommonRoot -Parent $script:Base -Name 'decoy-common'

    $script:Saved = @{
        HOME  = $env:CL_COMMON_HOME
        PATHV = $env:CL_COMMON_PATH
        REPOS = $env:CL_REPOS_ROOT
    }
}

AfterAll {
    $env:CL_COMMON_HOME = $script:Saved.HOME
    $env:CL_COMMON_PATH = $script:Saved.PATHV
    $env:CL_REPOS_ROOT = $script:Saved.REPOS
}

Describe 'Resolve-ClCommon resolution order' {
    BeforeEach {
        $env:CL_COMMON_HOME = $null
        $env:CL_COMMON_PATH = $null
        $env:CL_REPOS_ROOT = $null
    }

    It 'finds the install through CL_COMMON_HOME' {
        $env:CL_COMMON_HOME = $script:HomeRoot
        $common = & $script:Resolver
        $common.Available | Should -BeTrue
        $common.Source | Should -Be 'CL_COMMON_HOME'
        $common.Path | Should -Be (Resolve-Path -LiteralPath $script:HomeRoot).Path
    }

    It 'prefers CL_COMMON_HOME over CL_REPOS_ROOT when both resolve' {
        $env:CL_COMMON_HOME = $script:HomeRoot
        $env:CL_REPOS_ROOT = $script:FleetRoot
        $common = & $script:Resolver
        $common.Source | Should -Be 'CL_COMMON_HOME' -Because 'an explicit machine variable outranks the conventional layout'
        $common.Path | Should -Be (Resolve-Path -LiteralPath $script:HomeRoot).Path
    }

    It 'still honours CL_COMMON_PATH as the legacy alias' {
        $env:CL_COMMON_PATH = $script:LegacyRoot
        $common = & $script:Resolver
        $common.Available | Should -BeTrue
        $common.Source | Should -Be 'CL_COMMON_PATH'
        $common.Path | Should -Be (Resolve-Path -LiteralPath $script:LegacyRoot).Path
    }

    It 'falls back to CL_REPOS_ROOT\cl-common' {
        $env:CL_REPOS_ROOT = $script:FleetRoot
        $common = & $script:Resolver
        $common.Available | Should -BeTrue
        $common.Source | Should -Be 'CL_REPOS_ROOT'
        $common.Path | Should -Be (Resolve-Path -LiteralPath $script:FleetCommon).Path
    }

    It 'rejects a directory that is not a cl-common checkout and keeps looking' {
        $env:CL_COMMON_HOME = $script:Decoy
        $env:CL_REPOS_ROOT = $script:FleetRoot
        $common = & $script:Resolver
        $common.Source | Should -Be 'CL_REPOS_ROOT' -Because 'a bare directory named like cl-common has no Skills root'
        $common.Path | Should -Be (Resolve-Path -LiteralPath $script:FleetCommon).Path
    }

    It 'reports a named absence instead of throwing when nothing is set' {
        { & $script:Resolver } | Should -Not -Throw
        $common = & $script:Resolver
        $common.Available | Should -BeFalse
        $common.Path | Should -BeNullOrEmpty
        $common.Reason | Should -Match 'CL_COMMON_HOME'
        $common.Reason | Should -Match 'CL_REPOS_ROOT'
    }
}
