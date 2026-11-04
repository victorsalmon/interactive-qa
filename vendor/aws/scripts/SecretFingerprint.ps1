#Requires -Version 7
<#
.SYNOPSIS
    Shared secret fingerprint / comparison helpers. Dot-source this file; it
    defines functions only and has no side effects.

.DESCRIPTION
    The fleet rule is "print keys, never values" (saas-modules/AGENTS.md rule 7).
    Verifying that two credential sources agree used to tempt agents into
    printing the value; these helpers make the safe form the easy form:

      - Get-SecretFingerprint  -> { Present, Length, Sha256, Prefix }
      - Test-SecretEqual       -> ordinal equality, no output
      - Get-EnvSecretValue     -> Machine/User/Process env lookup
      - Get-PaseoProviderEnvValue -> ~/.paseo/config.json agents.providers.<p>.env
      - Get-FileSecretValue    -> trim-read a one-line key file
      - Get-JsonFieldValue     -> dotted field lookup on a parsed object

    A SHA-256 of a high-entropy secret is a fingerprint, not the secret: it
    cannot be reversed, and it is the only value-derived thing any caller should
    print (short prefix by default). Nothing here writes to disk or the console.

    Trap this file exists to prevent (2026-10-23): a helper function named `H`
    resolves to the built-in Get-History alias, so `(H $secret)` binds the
    secret as an -Id argument and PowerShell echoes it in the parameter-binding
    error. Never name a function or variable a single letter that collides with
    an alias; never pass a secret to a command that is not a comparison.
#>

function Get-SecretFingerprint {
    <#
    .SYNOPSIS
        SHA-256 fingerprint of a value, safe to print.
    .PARAMETER Value
        The secret value. Only its length and hash are returned.
    .PARAMETER PrefixChars
        Characters of the hex digest to expose as Prefix (default 12).
    #>
    param(
        [AllowEmptyString()][string]$Value,
        [ValidateRange(6, 64)][int]$PrefixChars = 12
    )

    if ([string]::IsNullOrEmpty($Value)) {
        return [pscustomobject]@{ Present = $false; Length = 0; Sha256 = ''; Prefix = '' }
    }
    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $algorithm.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Value))
    }
    finally { $algorithm.Dispose() }
    $hex = -join ($bytes | ForEach-Object { $_.ToString('x2') })
    [pscustomobject]@{
        Present = $true
        Length  = $Value.Length
        Sha256  = $hex
        Prefix  = $hex.Substring(0, [Math]::Min($PrefixChars, $hex.Length))
    }
}

function Test-SecretEqual {
    <#
    .SYNOPSIS
        Ordinal equality of two values. Empty on either side is never equal.
    #>
    param(
        [AllowEmptyString()][string]$A,
        [AllowEmptyString()][string]$B
    )

    if ([string]::IsNullOrEmpty($A) -or [string]::IsNullOrEmpty($B)) { return $false }
    return [string]::Equals($A, $B, [System.StringComparison]::Ordinal)
}

function Get-EnvSecretValue {
    <#
    .SYNOPSIS
        Read an environment variable by scope. The value is returned to the
        caller, never printed here.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [ValidateSet('Machine', 'User', 'Process')][string]$Scope = 'Process'
    )

    if ([string]::IsNullOrWhiteSpace($Name)) { return '' }
    if ($Scope -eq 'Process') { return [string][Environment]::GetEnvironmentVariable($Name, 'Process') }
    return [string][Environment]::GetEnvironmentVariable($Name, $Scope)
}

function Read-JsonFileQuiet {
    <#
    .SYNOPSIS
        Parse a JSON file, returning $null instead of throwing.
    #>
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json) } catch { return $null }
}

function Get-JsonFieldValue {
    <#
    .SYNOPSIS
        Dotted field lookup on a parsed object (`agents.providers.opencode.env`).
        Returns the string value or '' when any segment is absent.
    #>
    param(
        $Object,
        [Parameter(Mandatory)][string]$Field
    )

    $current = $Object
    foreach ($segment in ($Field -split '\.')) {
        if ($null -eq $current) { return '' }
        $property = $current.PSObject.Properties[$segment]
        if ($null -eq $property) { return '' }
        $current = $property.Value
    }
    if ($null -eq $current) { return '' }
    if ($current -is [string]) { return $current }
    return [string]$current
}

function Get-PaseoProviderEnvValue {
    <#
    .SYNOPSIS
        Read one env value from Paseo's provider config without echoing the
        config. Missing provider or env block returns ''.
    #>
    param(
        [Parameter(Mandatory)][string]$Provider,
        [Parameter(Mandatory)][string]$EnvName,
        [string]$ConfigPath = (Join-Path $HOME '.paseo\config.json')
    )

    $config = Read-JsonFileQuiet -Path $ConfigPath
    if (-not $config) { return '' }
    return Get-JsonFieldValue -Object $config -Field "agents.providers.$Provider.env.$EnvName"
}

function Get-FileSecretValue {
    <#
    .SYNOPSIS
        Trim-read a single-line key file (e.g. ~/.machine/secrets/x.key).
        Missing file returns ''.
    #>
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    return ([string](Get-Content -LiteralPath $Path -Raw)).Trim()
}
