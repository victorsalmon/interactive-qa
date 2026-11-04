#Requires -Version 7.0
<#
.SYNOPSIS
    Fails when any relative Markdown link in the plugin package does not resolve.

.DESCRIPTION
    Walks every *.md file under -Root, extracts inline links and images, skips
    external targets (http/https/mailto/tel/data) and pure in-page anchors, then
    resolves each remaining target against the linking file's own directory.

    A link is dead when the resolved path does not exist. Absolute paths are
    always dead: a publishable package must resolve through relative links or
    through the environment, never through a machine path.

    Exit code 0  - every relative link resolved.
    Exit code 1  - at least one dead link; each is printed as
                   <file>:<line>: <target>

    -SelfContained additionally requires each resolved target to stay inside the
    package root. A link that resolves outside it is reported as
    <file>:<line>: <target> (escapes package root) and fails, even when the
    outside path exists on this machine.

    Self-containment is the DEFAULT, because a package whose links resolve only
    while a sibling tree sits beside it is not a package: the plain green proved
    nothing and the gate that said OK was the defect (D10, bead cl-common-1v5).
    -SelfContained is kept as an explicit, redundant spelling of the default.

    -ResolvableOnly restores the historical behaviour and judges only
    resolvability. It is a diagnostic for "what is dead", NEVER a
    self-containment proof, and no package gate may call it.

    Fenced code blocks are ignored, so an example link in a fence is not
    checked. Inline code spans are not stripped, so keep example links inside
    fences.

.PARAMETER Root
    Package root to scan. Defaults to the parent of this script's directory.

.PARAMETER SelfContained
    Explicit spelling of the default mode: fail when a resolved link points
    outside the package root.

.PARAMETER ResolvableOnly
    Judge resolvability only; outside-the-root links are allowed. Diagnostic
    mode, not a self-containment proof.

.EXAMPLE
    pwsh -File interactive-qa/tools/Test-PluginLinks.ps1

.EXAMPLE
    pwsh -File interactive-qa/tools/Test-PluginLinks.ps1 -ResolvableOnly
#>
[CmdletBinding()]
param(
    [string] $Root,
    [switch] $SelfContained,
    [switch] $ResolvableOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($SelfContained -and $ResolvableOnly) {
    Write-Host 'Test-PluginLinks: -SelfContained and -ResolvableOnly are mutually exclusive.' -ForegroundColor Red
    exit 2
}

$selfContainedMode = -not $ResolvableOnly

if (-not $Root) {
    $Root = Split-Path -Parent $PSScriptRoot
}

if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
    Write-Host "Test-PluginLinks: root not found: $Root" -ForegroundColor Red
    exit 1
}

$rootFull = (Resolve-Path -LiteralPath $Root).Path
$rootPrefix = $rootFull.TrimEnd(
    [System.IO.Path]::DirectorySeparatorChar,
    [System.IO.Path]::AltDirectorySeparatorChar
) + [System.IO.Path]::DirectorySeparatorChar
$modeLabel = if ($selfContainedMode) { 'self-contained' } else { 'resolvable-only (NOT a self-containment proof)' }
$skippedSchemes = @('http', 'https', 'mailto', 'tel', 'data', 'ftp')
$linkPattern = [regex]'!?\[(?<text>[^\]]*)\]\((?<target>[^)]*)\)'

$dead = [System.Collections.Generic.List[string]]::new()
$scanned = 0
$checked = 0

$files = Get-ChildItem -LiteralPath $rootFull -Recurse -File -Filter '*.md' | Where-Object {
    # Judge only segments inside the package root: the package itself may live
    # under a path that contains a skipped folder name.
    $relativePath = $_.FullName.Substring($rootFull.Length)
    -not ($relativePath -split '[\\/]' | Where-Object { $_ -in @('.git', 'node_modules') })
}

foreach ($file in $files) {
    $scanned++
    $lineNumber = 0
    $inFence = $false

    foreach ($line in (Get-Content -LiteralPath $file.FullName -Encoding utf8)) {
        $lineNumber++

        if ($line -match '^\s*(```|~~~)') {
            $inFence = -not $inFence
            continue
        }
        if ($inFence) { continue }

        foreach ($match in $linkPattern.Matches($line)) {
            $target = $match.Groups['target'].Value.Trim()

            # Drop an optional Markdown title: [text](path "title")
            if ($target -match '^(?<path>\S+)\s+["''(]') {
                $target = $Matches['path']
            }
            $target = $target.Trim('<', '>').Trim()

            if ([string]::IsNullOrWhiteSpace($target)) { continue }

            if ($target.StartsWith('#')) { continue }

            $scheme = ($target -split ':', 2)[0]
            if ($target.Contains(':') -and $skippedSchemes -contains $scheme.ToLowerInvariant()) { continue }

            # Strip fragment and query before resolving on disk.
            $pathPart = ($target -split '[#?]', 2)[0]
            if ([string]::IsNullOrWhiteSpace($pathPart)) { continue }

            if ([System.IO.Path]::IsPathRooted($pathPart)) {
                $dead.Add("$($file.FullName):$lineNumber`: $target (absolute path)")
                continue
            }

            $decoded = [System.Uri]::UnescapeDataString($pathPart) -replace '/', [System.IO.Path]::DirectorySeparatorChar
            $baseDirectory = Split-Path -Parent $file.FullName
            $resolved = Join-Path -Path $baseDirectory -ChildPath $decoded

            try {
                $resolvedFull = [System.IO.Path]::GetFullPath($resolved)
            }
            catch {
                $checked++
                $dead.Add("$($file.FullName):$lineNumber`: $target (unresolvable path)")
                continue
            }

            $checked++

            if ($selfContainedMode -and -not $resolvedFull.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                $dead.Add("$($file.FullName):$lineNumber`: $target (escapes package root)")
                continue
            }

            if (-not (Test-Path -LiteralPath $resolvedFull)) {
                $dead.Add("$($file.FullName):$lineNumber`: $target")
            }
        }
    }
}

if ($dead.Count -gt 0) {
    Write-Host "Test-PluginLinks ($modeLabel): $($dead.Count) dead link(s) in $scanned file(s) under $rootFull" -ForegroundColor Red
    foreach ($entry in $dead) { Write-Host "  $entry" }
    exit 1
}

Write-Host "Test-PluginLinks ($modeLabel): OK - $checked relative link(s) resolved across $scanned file(s) under $rootFull" -ForegroundColor Green
exit 0
