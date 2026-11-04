#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

<#
.SYNOPSIS
    Hermetic test for the per-agent key bridge in run-iqa-worker.ps1.

.DESCRIPTION
    The bridge is the thing that makes waterfall/round-robin real: the gate
    selects OPENCODE_GO<n>_KEY, and the worker must inject that value into the
    agent's OWN process as OPENCODE_GO_KEY. Before this test, an absent
    bridgeEnv silently defaulted to GEMINI_API_KEY, so the selected key never
    reached OpenCode and every agent shared the machine-pinned key.

    The worker script has top-level dispatch code, so this test extracts only
    Resolve-AgentKeyEnv via AST instead of dot-sourcing the script.
#>

BeforeAll {
    $script:WorkerPath = (Resolve-Path (Join-Path $PSScriptRoot '..' 'vendor/dispatch/scripts/run-iqa-worker.ps1')).Path
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:WorkerPath, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw "Parse failed: $($errors[0].Message)" }

    $fn = @($ast.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $n.Name -eq 'Resolve-AgentKeyEnv'
            }, $false))[0]
    if (-not $fn) { throw 'Resolve-AgentKeyEnv not found in run-iqa-worker.ps1' }

    function global:Get-Prop {
        param($Object, $Name, $Default)
        if ($null -eq $Object) { return $Default }
        if ($Object -is [System.Collections.IDictionary]) {
            if ($Object.Contains($Name)) { return $Object[$Name] }
            return $Default
        }
        $prop = $Object.PSObject.Properties[$Name]
        if ($prop -and $null -ne $prop.Value) { return $prop.Value }
        return $Default
    }

    Invoke-Expression ($fn.Extent.Text -replace '^\s*function\s+', 'function global:')

    $script:OriginalGoKey = $env:OPENCODE_GO1_KEY
    $script:OriginalGeminiKey = $env:TEST_GEMINI_KEY
}

AfterAll {
    if ($null -eq $script:OriginalGoKey) {
        Remove-Item Env:OPENCODE_GO1_KEY -ErrorAction SilentlyContinue
    }
    else {
        $env:OPENCODE_GO1_KEY = $script:OriginalGoKey
    }
    if ($null -eq $script:OriginalGeminiKey) {
        Remove-Item Env:TEST_GEMINI_KEY -ErrorAction SilentlyContinue
    }
    else {
        $env:TEST_GEMINI_KEY = $script:OriginalGeminiKey
    }
    Remove-Item function:global:Get-Prop -ErrorAction SilentlyContinue
    Remove-Item function:global:Resolve-AgentKeyEnv -ErrorAction SilentlyContinue
}

Describe 'Resolve-AgentKeyEnv (per-agent key bridge)' {

    It 'bridges an opencode-go selection into OPENCODE_GO_KEY' {
        $env:OPENCODE_GO1_KEY = 'test-value'
        $slot = [pscustomobject]@{
            Pool      = 'opencode-go'
            Provider  = 'opencode/opencode-go/deepseek-v4.1-flash'
            KeyEnv    = 'OPENCODE_GO1_KEY'
            KeyScope  = 'Process'
            BridgeEnv = 'OPENCODE_GO_KEY'
        }

        $result = Resolve-AgentKeyEnv -Slot $slot

        $result.Pairs | Should -Be @('OPENCODE_GO_KEY=test-value')
        $result.BridgeEnv | Should -Be 'OPENCODE_GO_KEY'
        $result.KeyName | Should -Be 'OPENCODE_GO1_KEY'
        $result.Value | Should -Be 'test-value'
    }

    It 'refuses a non-Gemini keyed pool that declares no bridgeEnv' {
        $env:OPENCODE_GO1_KEY = 'test-value'
        $slot = [pscustomobject]@{
            Pool      = 'opencode-go'
            Provider  = 'opencode/opencode-go/deepseek-v4.1-flash'
            KeyEnv    = 'OPENCODE_GO1_KEY'
            KeyScope  = 'Process'
            BridgeEnv = ''
        }

        { Resolve-AgentKeyEnv -Slot $slot } | Should -Throw '*declares no bridgeEnv*'
    }

    It 'keeps GEMINI_API_KEY for the legacy Gemini pool' {
        $env:TEST_GEMINI_KEY = 'gemini-value'
        $slot = [pscustomobject]@{
            Pool      = 'gemini'
            Provider  = 'gemini/gemini-3.8-flash'
            KeyEnv    = 'TEST_GEMINI_KEY'
            KeyScope  = 'Process'
            BridgeEnv = ''
        }

        $result = Resolve-AgentKeyEnv -Slot $slot

        $result.Pairs | Should -Be @('GEMINI_API_KEY=gemini-value')
    }
}
