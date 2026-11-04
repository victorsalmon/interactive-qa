#Requires -Version 7
<#
    Proof for Skills/iqa-merge/Test-VendoredSync.ps1 (bead cl-common-e93).

    The guard is the merge acceptance for the vendored-helper seam: a branch that
    edits a canonical Skills file with a vendored manifest row must carry the
    matching vendored copy and manifest hash, or it cannot land.

    Every case drives a real git fixture (trunk dev, a throwaway branch, a real
    detached worktree) and judges the guard by the exit code AND the message text
    it prints, because the failure message is the deliverable - it names the ROW
    and the CANONICAL file a merge worker must fix.

    Run: pwsh -NoProfile -File Skills/iqa-merge/Tests/Test-VendoredSync.Tests.ps1
#>
[CmdletBinding()]
param()

BeforeAll {
    # The guard lives BESIDE this test in the package's tools/ directory. It used to
    # live in Skills/iqa-merge/Tests/ with the guard one level up, and this lookup
    # kept pointing one level up after the move - so BeforeAll threw and Pester
    # reported an unrelated loop-label error. Prefer the sibling, keep the old
    # location as a fallback so the test still runs from a fleet checkout.
    $guardCandidates = @(
        (Join-Path $PSScriptRoot 'Test-VendoredSync.ps1'),
        (Join-Path (Split-Path -Parent $PSScriptRoot) 'Test-VendoredSync.ps1')
    )
    $script:GuardScript = $null
    foreach ($candidate in $guardCandidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { $script:GuardScript = (Resolve-Path -LiteralPath $candidate).Path; break }
    }
    $script:PwshPath = (Get-Command pwsh -ErrorAction Stop).Source

    if (-not $script:GuardScript) {
        throw "Guard script not found. Looked in: $($guardCandidates -join '; ')"
    }

    # A tiny but faithful stand-in for interactive-qa/tools/Sync-VendoredHelpers.ps1:
    # same command line (-Check -PackageRoot), same row contract (STATUS<2+spaces>vendored),
    # same exit codes (0 MATCH, 1 not in sync). The guard under test owns the diff,
    # the intersection, the worktree and the message; the mapping owner is stubbed
    # so the fixture stays small and the case stays deterministic.
    #
    # The repo root is the nearest ancestor of the package that carries Skills/,
    # because a fixture must resolve its OWN canonical tree in either layout: the
    # package sits at <root>/interactive-qa/tools in one and at
    # <root>/vendor/interactive-qa/tools in the other.
    $script:StubSync = @'
#Requires -Version 7
[CmdletBinding()]
param([switch] $Check, [string] $PackageRoot)

if (-not $PackageRoot) { $PackageRoot = Split-Path -Parent $PSScriptRoot }
$manifestPath = Join-Path $PackageRoot 'tools/vendored-helpers.manifest.json'
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$repoRoot = Split-Path -Parent $PackageRoot
while ($repoRoot -and -not (Test-Path -LiteralPath (Join-Path $repoRoot 'Skills') -PathType Container)) {
    $parent = Split-Path -Parent $repoRoot
    if ($parent -eq $repoRoot -or -not $parent) { break }
    $repoRoot = $parent
}
$bad = 0

foreach ($row in @($manifest.vendored)) {
    $vendoredPath = Join-Path $PackageRoot $row.Vendored
    $canonicalPath = Join-Path $repoRoot ("Skills/" + $row.Canonical)

    if (-not (Test-Path -LiteralPath $vendoredPath -PathType Leaf)) {
        Write-Output ('MISSING  {0}   vendored absent' -f $row.Vendored)
        $bad++
        continue
    }
    if (-not (Test-Path -LiteralPath $canonicalPath -PathType Leaf)) {
        Write-Output ('MISSING  {0}   canonical absent: {1}' -f $row.Vendored, $row.Canonical)
        $bad++
        continue
    }

    $vendoredHash = (Get-FileHash -LiteralPath $vendoredPath -Algorithm SHA256).Hash
    $canonicalHash = (Get-FileHash -LiteralPath $canonicalPath -Algorithm SHA256).Hash

    if ($canonicalHash -ne $vendoredHash) {
        Write-Output ('DRIFT    {0}   canonical={1} vendored={2}' -f $row.Vendored, $canonicalHash.Substring(0, 12), $vendoredHash.Substring(0, 12))
        $bad++
        continue
    }
    if ($row.Sha256 -and $row.Sha256 -ne $vendoredHash) {
        Write-Output ('DRIFT    {0}   manifest hash stale: recorded={1} now={2}' -f $row.Vendored, $row.Sha256.Substring(0, 12), $vendoredHash.Substring(0, 12))
        $bad++
        continue
    }

    Write-Output ('MATCH    {0}   sha256 {1}' -f $row.Vendored, $vendoredHash.Substring(0, 12))
}

if ($bad -gt 0) { exit 1 }
exit 0
'@

    function Get-Sha256Hex {
        param([Parameter(Mandatory)][string] $Path)
        (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    }

    function New-VendoredRow {
        param(
            [Parameter(Mandatory)][string] $Canonical,
            [Parameter(Mandatory)][string] $Vendored,
            [Parameter(Mandatory)][string] $Path
        )
        $hash = Get-Sha256Hex -Path $Path
        [pscustomobject]@{
            Kind      = 'copy'
            Name      = Split-Path -Leaf $Vendored
            Canonical = $Canonical
            Vendored  = $Vendored
            Sha256    = $hash
            Sha256Lf  = $hash
            Bytes     = (Get-Item -LiteralPath $Path).Length
            Tree      = 'demo'
        }
    }

    function New-SyncFixture {
        param(
            [Parameter(Mandatory)][string] $Name,
            [switch] $ManifestIntroducedLater,
            # The two layouts the gate must find a manifest in: the package at
            # <root>/interactive-qa/ (package-root) or vendored into a host repo at
            # <root>/vendor/interactive-qa/ (how cl-common carries it).
            [switch] $VendoredLayout
        )

        $root = Join-Path $TestDrive $Name
        New-Item -ItemType Directory -Path $root -Force | Out-Null

        # The two governed canonical files, their vendored copies, and the owner.
        $canonicalDir = Join-Path $root 'Skills/demo'
        $packageDir = if ($VendoredLayout) {
            Join-Path $root 'vendor/interactive-qa'
        } else {
            Join-Path $root 'interactive-qa'
        }
        $toolsDir = Join-Path $packageDir 'tools'
        $vendoredDir = Join-Path $packageDir 'vendor/demo'
        New-Item -ItemType Directory -Path $canonicalDir, $toolsDir, $vendoredDir -Force | Out-Null

        Set-Content -LiteralPath (Join-Path $canonicalDir 'Alpha.ps1') -Value "#Requires -Version 7`n# alpha canonical" -Encoding utf8 -NoNewline
        Set-Content -LiteralPath (Join-Path $canonicalDir 'Beta.ps1') -Value "#Requires -Version 7`n# beta canonical" -Encoding utf8 -NoNewline
        Copy-Item -LiteralPath (Join-Path $canonicalDir 'Alpha.ps1') -Destination (Join-Path $vendoredDir 'Alpha.ps1')
        Copy-Item -LiteralPath (Join-Path $canonicalDir 'Beta.ps1') -Destination (Join-Path $vendoredDir 'Beta.ps1')

        Set-Content -LiteralPath (Join-Path $toolsDir 'Sync-VendoredHelpers.ps1') -Value $script:StubSync -Encoding utf8

        $manifest = [pscustomobject]@{
            schemaVersion = 2
            package       = 'interactive-qa'
            vendored      = @(
                New-VendoredRow -Canonical 'demo/Alpha.ps1' -Vendored 'vendor/demo/Alpha.ps1' -Path (Join-Path $vendoredDir 'Alpha.ps1')
                New-VendoredRow -Canonical 'demo/Beta.ps1' -Vendored 'vendor/demo/Beta.ps1' -Path (Join-Path $vendoredDir 'Beta.ps1')
            )
        }
        $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $toolsDir 'vendored-helpers.manifest.json') -Encoding utf8 -NoNewline

        Set-Content -LiteralPath (Join-Path $root 'README.md') -Value '# fixture' -Encoding utf8

        # Model a branch cut BEFORE bead cl-common-e93: the first commit carries the
        # canonical tree but no package at all, the second commit adds the whole
        # vendored-helper mapping. A branch at the first commit is therefore a
        # genuine pre-manifest branch (absent, not malformed).
        $holding = $null
        if ($ManifestIntroducedLater) {
            $holding = Join-Path $TestDrive ("hold-{0}" -f [guid]::NewGuid().ToString('N'))
            Move-Item -LiteralPath $packageDir -Destination $holding
        }

        & git -C $root init --initial-branch=dev --quiet 2>&1 | Out-Null
        & git -C $root config user.email 'fixture@example.com'
        & git -C $root config user.name 'Fixture'
        # Byte-exact fixtures: line-ending transport is not what these cases measure.
        & git -C $root config core.autocrlf false
        & git -C $root add -- . 2>&1 | Out-Null
        & git -C $root commit --quiet -m 'init' 2>&1 | Out-Null

        if ($LASTEXITCODE -ne 0) { throw "fixture commit failed in $root" }

        if ($ManifestIntroducedLater) {
            Move-Item -LiteralPath $holding -Destination $packageDir
            & git -C $root add -- . 2>&1 | Out-Null
            & git -C $root commit --quiet -m 'add the vendored-helper mapping' 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "fixture mapping commit failed in $root" }
        }

        return $root
    }

    function New-Branch {
        param(
            [Parameter(Mandatory)][string] $Repo,
            [Parameter(Mandatory)][string] $Name
        )
        & git -C $Repo checkout --quiet -b $Name 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "could not create branch $Name in $Repo" }
    }

    function Save-BranchCommit {
        param(
            [Parameter(Mandatory)][string] $Repo,
            [Parameter(Mandatory)][string] $Message
        )
        & git -C $Repo add -- . 2>&1 | Out-Null
        & git -C $Repo commit --quiet -m $Message 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "commit failed in $Repo" }
        & git -C $Repo checkout --quiet dev 2>&1 | Out-Null
    }

    function Invoke-Guard {
        param(
            [Parameter(Mandatory)][string] $Repo,
            [string[]] $Branch,
            [string[]] $Paths,
            [string] $GuardPath,
            [string] $ManifestPath,
            [switch] $Json
        )

        $guard = if ($GuardPath) { $GuardPath } else { $script:GuardScript }
        $arguments = @('-NoProfile', '-NonInteractive', '-File', $guard, '-RepoPath', $Repo, '-Trunk', 'dev')
        if ($Branch) { $arguments += @('-Branch', ($Branch -join ',')) }
        if ($Paths) { $arguments += @('-Paths', ($Paths -join ',')) }
        if ($ManifestPath) { $arguments += @('-ManifestPath', $ManifestPath) }
        if ($Json) { $arguments += '-Json' }

        $output = & $script:PwshPath @arguments 2>&1
        return [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Output   = ($output | Out-String)
        }
    }

    # The exact assertions the FAIL case makes. The negative control reuses them so
    # a neutered guard is caught by MESSAGE absence, not only by an exit code.
    $script:FailPatterns = @(
        'Test-VendoredSync: FAIL'
        'ROW\s+demo/Alpha\.ps1'
        'CANONICAL Skills/demo/Alpha\.ps1'
        'VENDORED\s+vendor/demo/Alpha\.ps1'
        'STATUS\s+DRIFT'
        'TOUCHED\s+yes'
    )
}

Describe 'Test-VendoredSync merge gate' {

    Context 'a canonical edit whose vendored row is not synced' {

        It 'fails and names the row, the canonical file and the vendored path' {
            $repo = New-SyncFixture -Name "drift-$(Get-Random)"
            New-Branch -Repo $repo -Name 'feat/drift'
            Set-Content -LiteralPath (Join-Path $repo 'Skills/demo/Alpha.ps1') -Value "#Requires -Version 7`n# alpha CANONICAL EDIT" -Encoding utf8 -NoNewline
            Save-BranchCommit -Repo $repo -Message 'edit canonical only'

            $result = Invoke-Guard -Repo $repo -Branch 'feat/drift'

            $result.ExitCode | Should -Be 1 -Because $result.Output
            foreach ($pattern in $script:FailPatterns) {
                $result.Output | Should -Match $pattern
            }
            $result.Output | Should -Match 'not in sync'
            $result.Output | Should -Match 'then git add the vendored copies and the manifest'
        }
    }

    Context 'a diff that touches no governed canonical' {

        It 'passes without opening the branch' {
            $repo = New-SyncFixture -Name "unrelated-$(Get-Random)"
            New-Branch -Repo $repo -Name 'feat/unrelated'
            Set-Content -LiteralPath (Join-Path $repo 'README.md') -Value '# unrelated change' -Encoding utf8
            Set-Content -LiteralPath (Join-Path $repo 'Skills/demo/NotVendored.ps1') -Value '# no manifest row' -Encoding utf8
            Save-BranchCommit -Repo $repo -Message 'change unrelated files'

            $result = Invoke-Guard -Repo $repo -Branch 'feat/unrelated'

            $result.ExitCode | Should -Be 0 -Because $result.Output
            $result.Output | Should -Match 'Test-VendoredSync: OK'
            $result.Output | Should -Match 'none is a canonical file with a vendored manifest row'
        }
    }

    Context 'a canonical edit re-vendored in the same branch' {

        It 'passes when the vendored copy and the manifest hash are both updated' {
            $repo = New-SyncFixture -Name "synced-$(Get-Random)"
            New-Branch -Repo $repo -Name 'feat/synced'
            $canonical = Join-Path $repo 'Skills/demo/Alpha.ps1'
            Set-Content -LiteralPath $canonical -Value "#Requires -Version 7`n# alpha canonical v2" -Encoding utf8 -NoNewline
            Copy-Item -LiteralPath $canonical -Destination (Join-Path $repo 'interactive-qa/vendor/demo/Alpha.ps1') -Force

            $manifestPath = Join-Path $repo 'interactive-qa/tools/vendored-helpers.manifest.json'
            $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
            $hash = Get-Sha256Hex -Path (Join-Path $repo 'interactive-qa/vendor/demo/Alpha.ps1')
            ($manifest.vendored | Where-Object { $_.Canonical -eq 'demo/Alpha.ps1' }).Sha256 = $hash
            ($manifest.vendored | Where-Object { $_.Canonical -eq 'demo/Alpha.ps1' }).Sha256Lf = $hash
            $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifestPath -Encoding utf8 -NoNewline
            Save-BranchCommit -Repo $repo -Message 're-vendor alpha'

            $result = Invoke-Guard -Repo $repo -Branch 'feat/synced'

            $result.ExitCode | Should -Be 0 -Because $result.Output
            $result.Output | Should -Match 'Test-VendoredSync: OK'
            $result.Output | Should -Match 'vendored row\(s\) in sync'
        }

        It 'still fails when the copy is updated but the manifest hash is stale' {
            $repo = New-SyncFixture -Name "stale-manifest-$(Get-Random)"
            New-Branch -Repo $repo -Name 'feat/stale'
            $canonical = Join-Path $repo 'Skills/demo/Alpha.ps1'
            Set-Content -LiteralPath $canonical -Value "#Requires -Version 7`n# alpha canonical v3" -Encoding utf8 -NoNewline
            Copy-Item -LiteralPath $canonical -Destination (Join-Path $repo 'interactive-qa/vendor/demo/Alpha.ps1') -Force
            Save-BranchCommit -Repo $repo -Message 'copy updated, manifest not'

            $result = Invoke-Guard -Repo $repo -Branch 'feat/stale'

            $result.ExitCode | Should -Be 1 -Because $result.Output
            $result.Output | Should -Match 'CANONICAL Skills/demo/Alpha\.ps1'
            $result.Output | Should -Match 'manifest hash stale'
        }
    }

    Context 'the layout probe: package-root and vendor/<pkg>' {
        # bead cl-common-ttr: the gate probed only <root>/interactive-qa/, so on a
        # host repository that vendors the package (cl-common carries it at
        # vendor/interactive-qa/) it found no manifest and printed SKIP - a false
        # green on every branch of that repository. Both layouts must resolve, and
        # the resolved one must be the one the vendored copies are checked against.

        It 'resolves the package-root layout and names the watched rows' {
            $repo = New-SyncFixture -Name "layout-package-root-$(Get-Random)"

            $result = Invoke-Guard -Repo $repo -Branch 'dev' -Json

            $result.ExitCode | Should -Be 0 -Because $result.Output
            $result.Output | Should -Not -Match 'SKIP'
            $report = $result.Output | ConvertFrom-Json
            $report.verdict | Should -Be 'ok'
            $report.watchedRows | Should -Be 2 -Because 'the manifest at <root>/interactive-qa/tools declares two rows'
        }

        It 'resolves the vendor/<pkg> layout and names the watched rows' {
            $repo = New-SyncFixture -Name "layout-vendored-$(Get-Random)" -VendoredLayout

            $result = Invoke-Guard -Repo $repo -Branch 'dev' -Json

            $result.ExitCode | Should -Be 0 -Because $result.Output
            $result.Output | Should -Not -Match 'SKIP'
            $report = $result.Output | ConvertFrom-Json
            $report.verdict | Should -Be 'ok'
            $report.watchedRows | Should -Be 2 -Because 'the manifest at <root>/vendor/interactive-qa/tools declares two rows'
        }

        It 'passes a re-vendored canonical edit under vendor/<pkg>' {
            $repo = New-SyncFixture -Name "vendored-synced-$(Get-Random)" -VendoredLayout
            New-Branch -Repo $repo -Name 'feat/vendored-synced'
            $canonical = Join-Path $repo 'Skills/demo/Alpha.ps1'
            Set-Content -LiteralPath $canonical -Value "#Requires -Version 7`n# alpha canonical v2" -Encoding utf8 -NoNewline
            $vendoredAlpha = Join-Path $repo 'vendor/interactive-qa/vendor/demo/Alpha.ps1'
            Copy-Item -LiteralPath $canonical -Destination $vendoredAlpha -Force

            $manifestPath = Join-Path $repo 'vendor/interactive-qa/tools/vendored-helpers.manifest.json'
            $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
            $hash = Get-Sha256Hex -Path $vendoredAlpha
            ($manifest.vendored | Where-Object { $_.Canonical -eq 'demo/Alpha.ps1' }).Sha256 = $hash
            ($manifest.vendored | Where-Object { $_.Canonical -eq 'demo/Alpha.ps1' }).Sha256Lf = $hash
            $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifestPath -Encoding utf8 -NoNewline
            Save-BranchCommit -Repo $repo -Message 're-vendor alpha under vendor/<pkg>'

            $result = Invoke-Guard -Repo $repo -Branch 'feat/vendored-synced'

            $result.ExitCode | Should -Be 0 -Because $result.Output
            $result.Output | Should -Not -Match 'SKIP'
            $result.Output | Should -Match 'Test-VendoredSync: OK'
            $result.Output | Should -Match 'vendored row\(s\) in sync'
        }

        It 'really runs the check under vendor/<pkg>, not just a row count' {
            $repo = New-SyncFixture -Name "vendored-drift-$(Get-Random)" -VendoredLayout
            New-Branch -Repo $repo -Name 'feat/vendored-drift'
            Set-Content -LiteralPath (Join-Path $repo 'Skills/demo/Alpha.ps1') -Value "#Requires -Version 7`n# alpha CANONICAL EDIT" -Encoding utf8 -NoNewline
            Save-BranchCommit -Repo $repo -Message 'edit canonical only'

            $result = Invoke-Guard -Repo $repo -Branch 'feat/vendored-drift'

            $result.ExitCode | Should -Be 1 -Because $result.Output
            $result.Output | Should -Not -Match 'SKIP'
            foreach ($pattern in $script:FailPatterns) {
                $result.Output | Should -Match $pattern
            }
        }
    }

    Context 'an explicit -ManifestPath' {

        It 'honours the same manifest named relative and absolute' {
            $repo = New-SyncFixture -Name "explicit-manifest-$(Get-Random)" -VendoredLayout
            New-Branch -Repo $repo -Name 'feat/explicit-manifest'
            $canonical = Join-Path $repo 'Skills/demo/Beta.ps1'
            Set-Content -LiteralPath $canonical -Value "#Requires -Version 7`n# beta canonical v2" -Encoding utf8 -NoNewline
            $vendoredBeta = Join-Path $repo 'vendor/interactive-qa/vendor/demo/Beta.ps1'
            Copy-Item -LiteralPath $canonical -Destination $vendoredBeta -Force

            $manifestPath = Join-Path $repo 'vendor/interactive-qa/tools/vendored-helpers.manifest.json'
            $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
            $hash = Get-Sha256Hex -Path $vendoredBeta
            ($manifest.vendored | Where-Object { $_.Canonical -eq 'demo/Beta.ps1' }).Sha256 = $hash
            ($manifest.vendored | Where-Object { $_.Canonical -eq 'demo/Beta.ps1' }).Sha256Lf = $hash
            $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifestPath -Encoding utf8 -NoNewline
            Save-BranchCommit -Repo $repo -Message 're-vendor beta'

            # Relative: resolved against -RepoPath, not the caller's cwd.
            $relative = Invoke-Guard -Repo $repo -Branch 'feat/explicit-manifest' -ManifestPath 'vendor/interactive-qa/tools/vendored-helpers.manifest.json'
            $relative.ExitCode | Should -Be 0 -Because $relative.Output
            $relative.Output | Should -Match 'Test-VendoredSync: OK'
            $relative.Output | Should -Match 'vendored row\(s\) in sync'

            # Absolute: the same file, same verdict.
            $absolute = Invoke-Guard -Repo $repo -Branch 'feat/explicit-manifest' -ManifestPath $manifestPath
            $absolute.ExitCode | Should -Be 0 -Because $absolute.Output
            $absolute.Output | Should -Match 'vendored row\(s\) in sync'
        }

        It 'refuses an explicit manifest that is not inside the repository' {
            $repo = New-SyncFixture -Name "explicit-outside-$(Get-Random)"
            $outside = Join-Path $TestDrive ("outside-{0}/tools/vendored-helpers.manifest.json" -f (Get-Random))
            New-Item -ItemType Directory -Path (Split-Path -Parent $outside) -Force | Out-Null
            Set-Content -LiteralPath $outside -Value '{"vendored":[]}' -Encoding utf8

            $result = Invoke-Guard -Repo $repo -Branch 'dev' -ManifestPath $outside

            $result.ExitCode | Should -Be 2 -Because $result.Output
            $result.Output | Should -Match 'CANNOT-EVALUATE'
            $result.Output | Should -Match 'outside the measured repository'
        }
    }

    Context 'the satisfiable baseline' {

        It 'passes when the branch has no diff against the trunk' {
            $repo = New-SyncFixture -Name "no-diff-$(Get-Random)"

            $result = Invoke-Guard -Repo $repo -Branch 'dev'

            $result.ExitCode | Should -Be 0 -Because $result.Output
            $result.Output | Should -Match '0 changed path\(s\)'
        }

        It 'passes with a named skip when the repository has no vendored manifest' {
            $root = Join-Path $TestDrive "no-manifest-$(Get-Random)"
            New-Item -ItemType Directory -Path $root -Force | Out-Null
            & git -C $root init --initial-branch=dev --quiet 2>&1 | Out-Null
            & git -C $root config user.email 'fixture@example.com'
            & git -C $root config user.name 'Fixture'
            Set-Content -LiteralPath (Join-Path $root 'README.md') -Value '# no vendoring here' -Encoding utf8
            & git -C $root add -- . 2>&1 | Out-Null
            & git -C $root commit --quiet -m 'init' 2>&1 | Out-Null

            $result = Invoke-Guard -Repo $root -Branch 'dev'

            $result.ExitCode | Should -Be 0 -Because $result.Output
            $result.Output | Should -Match 'SKIP - no vendored-helper manifest'
            $result.Output | Should -Match 'does not vendor canonical Skills helpers'
        }
    }

    Context 'an explicit path list' {

        It 'fails on the listed governed canonical even when asked by path' {
            $repo = New-SyncFixture -Name "paths-$(Get-Random)"
            New-Branch -Repo $repo -Name 'feat/by-path'
            Set-Content -LiteralPath (Join-Path $repo 'Skills/demo/Beta.ps1') -Value "#Requires -Version 7`n# beta CANONICAL EDIT" -Encoding utf8 -NoNewline
            Save-BranchCommit -Repo $repo -Message 'edit beta only'

            $result = Invoke-Guard -Repo $repo -Branch 'feat/by-path' -Paths 'Skills/demo/Beta.ps1'

            $result.ExitCode | Should -Be 1 -Because $result.Output
            $result.Output | Should -Match 'ROW\s+demo/Beta\.ps1'
            $result.Output | Should -Match 'CANONICAL Skills/demo/Beta\.ps1'
        }
    }

    Context 'an unreadable manifest on the branch' {

        It 'returns a named cannot-evaluate instead of a pass' {
            $repo = New-SyncFixture -Name "bad-manifest-$(Get-Random)"
            New-Branch -Repo $repo -Name 'feat/bad-manifest'
            Set-Content -LiteralPath (Join-Path $repo 'Skills/demo/Alpha.ps1') -Value "#Requires -Version 7`n# edited" -Encoding utf8 -NoNewline
            Set-Content -LiteralPath (Join-Path $repo 'interactive-qa/tools/vendored-helpers.manifest.json') -Value '{ not json' -Encoding utf8
            Save-BranchCommit -Repo $repo -Message 'break the manifest'

            $result = Invoke-Guard -Repo $repo -Branch 'feat/bad-manifest'

            $result.ExitCode | Should -Be 2 -Because $result.Output
            $result.Output | Should -Match 'CANNOT-EVALUATE'
            $result.Output | Should -Match 'unreadable'
        }

        It 'returns a named cannot-evaluate when the branch deletes a manifest its merge base already had' {
            $repo = New-SyncFixture -Name "deleted-manifest-$(Get-Random)"
            New-Branch -Repo $repo -Name 'feat/deletes-manifest'
            Set-Content -LiteralPath (Join-Path $repo 'Skills/demo/Alpha.ps1') -Value "#Requires -Version 7`n# edited" -Encoding utf8 -NoNewline
            Remove-Item -LiteralPath (Join-Path $repo 'interactive-qa/tools/vendored-helpers.manifest.json') -Force
            Save-BranchCommit -Repo $repo -Message 'delete the manifest'

            $result = Invoke-Guard -Repo $repo -Branch 'feat/deletes-manifest'

            $result.ExitCode | Should -Be 2 -Because $result.Output
            $result.Output | Should -Match 'CANNOT-EVALUATE'
            $result.Output | Should -Match 'deletes the mapping'
        }
    }

    Context 'a branch older than the vendored-helper manifest' {
        # bead cl-common-7cu: the guard read the manifest from the branch under
        # test and called a null result unevaluable, so every branch cut before
        # cl-common-e93 could never be folded. Absent is a predate and falls back
        # to the trunk manifest; malformed (above) stays a non-verdict.

        It 'passes and names the watched row count when it touches no governed canonical' {
            $repo = New-SyncFixture -Name "pre-manifest-clean-$(Get-Random)" -ManifestIntroducedLater
            $oldTip = (& git -C $repo rev-parse 'HEAD~1').Trim()
            & git -C $repo checkout --quiet -b 'feat/pre-manifest-clean' $oldTip 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'could not branch from the pre-manifest commit' }

            $null = & git -C $repo cat-file -e 'HEAD:interactive-qa/tools/vendored-helpers.manifest.json' 2>&1
            $LASTEXITCODE | Should -Be 128 -Because 'the fixture branch must genuinely predate the manifest'

            Set-Content -LiteralPath (Join-Path $repo 'README.md') -Value '# a change that is not a vendored canonical' -Encoding utf8
            Save-BranchCommit -Repo $repo -Message 'change README only'

            $result = Invoke-Guard -Repo $repo -Branch 'feat/pre-manifest-clean'

            $result.ExitCode | Should -Be 0 -Because $result.Output
            $result.Output | Should -Match 'Test-VendoredSync: OK'
            $result.Output | Should -Match 'none is a canonical file with a vendored manifest row'
            $result.Output | Should -Match '2 row\(s\) watched'
            $result.Output | Should -Match 'predates the mapping'
        }

        It 'fails naming the row when it touches a governed canonical' {
            $repo = New-SyncFixture -Name "pre-manifest-drift-$(Get-Random)" -ManifestIntroducedLater
            $oldTip = (& git -C $repo rev-parse 'HEAD~1').Trim()
            & git -C $repo checkout --quiet -b 'feat/pre-manifest-drift' $oldTip 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'could not branch from the pre-manifest commit' }

            Set-Content -LiteralPath (Join-Path $repo 'Skills/demo/Alpha.ps1') -Value "#Requires -Version 7`n# alpha edited on a pre-manifest branch" -Encoding utf8 -NoNewline
            Save-BranchCommit -Repo $repo -Message 'edit a governed canonical before the mapping existed'

            $result = Invoke-Guard -Repo $repo -Branch 'feat/pre-manifest-drift'

            $result.ExitCode | Should -Be 1 -Because $result.Output
            $result.Output | Should -Match 'Test-VendoredSync: FAIL'
            $result.Output | Should -Match 'ROW\s+demo/Alpha\.ps1'
            $result.Output | Should -Match 'CANONICAL Skills/demo/Alpha\.ps1'
            $result.Output | Should -Match 'VENDORED\s+vendor/demo/Alpha\.ps1'
            $result.Output | Should -Match 'TOUCHED\s+yes'
            $result.Output | Should -Match 'predates the vendored-helper mapping'
        }
    }

    Context 'negative control' {

        It 'is red on the drift fixture and a neutered copy is not, so the message assertions are load-bearing' {
            $repo = New-SyncFixture -Name "control-$(Get-Random)"
            New-Branch -Repo $repo -Name 'feat/control'
            Set-Content -LiteralPath (Join-Path $repo 'Skills/demo/Alpha.ps1') -Value "#Requires -Version 7`n# alpha CANONICAL EDIT" -Encoding utf8 -NoNewline
            Save-BranchCommit -Repo $repo -Message 'edit canonical only'

            $real = Invoke-Guard -Repo $repo -Branch 'feat/control'
            $real.ExitCode | Should -Be 1 -Because $real.Output
            foreach ($pattern in $script:FailPatterns) {
                $real.Output | Should -Match $pattern
            }

            # Neuter the guard exactly where it decides the verdict: the branch
            # always takes the pass path, so it can no longer name the drift.
            $neuteredPath = Join-Path $repo 'Skills/iqa-merge/Neutered-VendoredSync.ps1'
            New-Item -ItemType Directory -Path (Split-Path -Parent $neuteredPath) -Force | Out-Null
            $guardText = Get-Content -LiteralPath $script:GuardScript -Raw
            $needle = 'if ($offending.Count -eq 0) {'
            $guardText.Contains($needle) | Should -BeTrue -Because 'the negative control must neuter a real decision point'
            $neutered = $guardText.Replace($needle, 'if ($true) {')
            $neutered | Should -Not -Be $guardText
            Set-Content -LiteralPath $neuteredPath -Value $neutered -Encoding utf8

            $fake = Invoke-Guard -Repo $repo -Branch 'feat/control' -GuardPath $neuteredPath
            $fake.ExitCode | Should -Be 0 -Because $fake.Output
            $fake.Output | Should -Not -Match 'Test-VendoredSync: FAIL'
            $fake.Output | Should -Not -Match 'CANONICAL Skills/demo/Alpha\.ps1'
            $fake.Output | Should -Not -Match 'ROW\s+demo/Alpha\.ps1'
        }
    }
}
