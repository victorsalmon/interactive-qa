#Requires -Version 7
<#
    Proof for tools/Test-VendoredHelpers.ps1.

    Every case is judged by the exit code of the gate run as a child process,
    because the exit code is what CI and the package gate read. A clean copy of
    this package MUST exit 0; each planted defect MUST exit non-zero AND name the
    defect, so a green gate cannot be green by not looking.

    Run: pwsh -File interactive-qa/tools/Test-VendoredHelpers.Tests.ps1

    The archived-row cases prove the repository's archive linkage and need the
    canonical Skills tree beside the package; on an isolated copy of the package
    they are skipped-with-waiver, named as such in the run output. Every other
    case runs everywhere.
#>

BeforeAll {
    $script:GateScript = Join-Path $PSScriptRoot 'Test-VendoredHelpers.ps1'
    $script:PackageRoot = Split-Path -Parent $PSScriptRoot
    $script:PwshPath = (Get-Command pwsh -ErrorAction Stop).Source

    if (-not (Test-Path -LiteralPath $script:GateScript)) {
        throw "Gate script not found: $script:GateScript"
    }

    function Invoke-Gate {
        param([Parameter(Mandatory)][string] $RootPath)

        # The gate must be judged against the fixture, never against whatever
        # checkout $env:CL_REPOS_ROOT happens to name: a stale trunk would turn a
        # clean copy red, and a fresh one would hide a defect. A copy with no
        # sibling Skills proves its recorded hashes only, which is the isolation
        # case this suite has always meant to pin.
        $savedFleetRoot = $env:CL_REPOS_ROOT
        try {
            Remove-Item Env:CL_REPOS_ROOT -ErrorAction SilentlyContinue
            $output = & $script:PwshPath -NoProfile -NonInteractive -File $script:GateScript -PackageRoot $RootPath 2>&1
            $exitCode = $LASTEXITCODE
        }
        finally {
            if ($null -ne $savedFleetRoot) { $env:CL_REPOS_ROOT = $savedFleetRoot }
        }

        return [pscustomobject]@{
            ExitCode = $exitCode
            Output   = ($output | Out-String)
        }
    }

    function New-PackageCopy {
        param([Parameter(Mandatory)][string] $Name)

        $destination = Join-Path $TestDrive $Name
        Copy-Item -LiteralPath $script:PackageRoot -Destination $destination -Recurse -Force
        return $destination
    }
}

Describe 'Test-VendoredHelpers gate' {

    Context 'a clean copy of this package' {

        It 'exits 0 and reports the counts' {
            $copy = New-PackageCopy -Name 'clean'
            $result = Invoke-Gate -RootPath $copy
            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match 'Test-VendoredHelpers: OK'
            $result.Output | Should -Match 'vendored file\(s\) present'
        }
    }

    Context 'an orphan copy planted at the vendored root' {

        It 'exits non-zero and names the orphan' {
            $copy = New-PackageCopy -Name 'orphan'
            Set-Content -LiteralPath (Join-Path $copy 'vendor/Orphan-Helper.ps1') -Value '#Requires -Version 7' -Encoding utf8

            $result = Invoke-Gate -RootPath $copy
            $result.ExitCode | Should -Not -Be 0
            $result.Output | Should -Match 'Orphan-Helper\.ps1'
            $result.Output | Should -Match 'orphan'
        }
    }

    Context 'an orphan planted inside a vendored subtree' {

        It 'exits non-zero and names the unlisted file' {
            $copy = New-PackageCopy -Name 'orphan-tree'
            Set-Content -LiteralPath (Join-Path $copy 'vendor/credential-rescue/scripts/Orphan-Key-Helper.ps1') -Value '#Requires -Version 7' -Encoding utf8

            $result = Invoke-Gate -RootPath $copy
            $result.ExitCode | Should -Not -Be 0
            $result.Output | Should -Match 'Orphan-Key-Helper\.ps1'
            $result.Output | Should -Match 'vendor/credential-rescue/scripts/Orphan-Key-Helper\.ps1'
        }
    }

    Context 'a manifest row with no vendored file' {

        It 'exits non-zero and names the missing helper' {
            $copy = New-PackageCopy -Name 'missing'
            Remove-Item -LiteralPath (Join-Path $copy 'vendor/iqa-merge/Test-Landed.ps1') -Force

            $result = Invoke-Gate -RootPath $copy
            $result.ExitCode | Should -Not -Be 0
            $result.Output | Should -Match 'vendored file missing: vendor/iqa-merge/Test-Landed\.ps1'
        }
    }

    Context 'a vendored copy that no longer matches its canonical source' {

        It 'exits non-zero and names the drift' {
            $copy = New-PackageCopy -Name 'drift'
            Add-Content -LiteralPath (Join-Path $copy 'vendor/iqa-merge/Get-HubCadence.ps1') -Value '# planted drift' -Encoding utf8

            $result = Invoke-Gate -RootPath $copy
            $result.ExitCode | Should -Not -Be 0
            $result.Output | Should -Match 'DRIFT'
            $result.Output | Should -Match 'Check exited 1'
        }
    }

    Context 'a vendored file that names the fleet root without a declared residual' {

        It 'exits non-zero and names the undeclared residual' {
            $copy = New-PackageCopy -Name 'residual'
            Add-Content -LiteralPath (Join-Path $copy 'vendor/credential-rescue/SKILL.md') -Value 'Planted: $env:CL_REPOS_ROOT\cl-common\Skills\credential-rescue' -Encoding utf8

            $result = Invoke-Gate -RootPath $copy
            $result.ExitCode | Should -Not -Be 0
            $result.Output | Should -Match 'no residual row declares it'
            $result.Output | Should -Match 'vendor/credential-rescue/SKILL\.md'
        }
    }

    Context 'a declared residual whose file no longer names the fleet root' {

        It 'exits non-zero and calls the excuse stale' {
            $copy = New-PackageCopy -Name 'stale-residual'
            Set-Content -LiteralPath (Join-Path $copy 'vendor/credential-rescue/scripts/Restart-PaseoDaemon.ps1') -Value '#Requires -Version 7' -Encoding utf8

            $result = Invoke-Gate -RootPath $copy
            $result.ExitCode | Should -Not -Be 0
            $result.Output | Should -Match 'no longer names CL_REPOS_ROOT'
        }
    }

    Context 'a manifest that vendors the same canonical file twice' {

        It 'exits non-zero and says one location is required' {
            $copy = New-PackageCopy -Name 'double-owner'
            $manifestPath = Join-Path $copy 'tools/vendored-helpers.manifest.json'
            $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json

            # Pick the row from the manifest instead of naming a file: a fixture
            # pinned to one path stops testing anything the moment that file changes
            # kind (this one did - iqa-merge went from copy to owned).
            $original = @($manifest.vendored) |
                Where-Object { $_.Kind -eq 'copy' -and -not [string]::IsNullOrWhiteSpace([string]$_.Canonical) } |
                Select-Object -First 1
            $original | Should -Not -BeNullOrEmpty -Because 'the package must vendor at least one copy row'

            $second = [pscustomobject]@{
                Kind      = 'copy'
                Name      = $original.Name
                Canonical = $original.Canonical
                Vendored  = 'vendor/credential-rescue/scripts/Duplicate-Owner-Probe.ps1'
                Sha256    = $original.Sha256
                Sha256Lf  = $original.Sha256Lf
                Bytes     = $original.Bytes
                Tree      = ''
            }
            $manifest.vendored = @($manifest.vendored) + $second
            $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifestPath -Encoding utf8 -NoNewline
            Copy-Item -LiteralPath (Join-Path $copy $original.Vendored) -Destination (Join-Path $copy 'vendor/credential-rescue/scripts/Duplicate-Owner-Probe.ps1')

            $result = Invoke-Gate -RootPath $copy
            $result.ExitCode | Should -Not -Be 0
            $result.Output | Should -Match 'vendored more than once'
            $result.Output | Should -Match ([regex]::Escape([string]$original.Canonical))
        }
    }

    Context 'an owned row whose body was edited without re-recording' {

        It 'exits non-zero and calls the body edited' {
            $copy = New-PackageCopy -Name 'owned-edited'
            $ownedPath = Join-Path $copy 'vendor/iqa-merge/Test-Landed.ps1'
            Add-Content -LiteralPath $ownedPath -Value "`n# an edit nobody re-recorded"

            $result = Invoke-Gate -RootPath $copy
            $result.ExitCode | Should -Not -Be 0
            $result.Output | Should -Match 'owned in-package body edited'
        }
    }

    Context 'a member naming a helper the package neither ships nor excuses' {

        It 'exits non-zero and names the undocumented dependency' {
            $copy = New-PackageCopy -Name 'unnamed'
            Set-Content -LiteralPath (Join-Path $copy 'members/iqa-hub/PLANTED.md') -Value @'
# Planted member note

This note prescribes `Ghost-Helper.ps1`, which the package does not ship.
'@ -Encoding utf8

            $result = Invoke-Gate -RootPath $copy
            $result.ExitCode | Should -Not -Be 0
            $result.Output | Should -Match 'Ghost-Helper\.ps1'
            $result.Output | Should -Match 'not-vendored manifest'
        }
    }

    Context 'an archived row stripped of its provenance' {

        It 'exits non-zero and refuses the waiver' {
            $copy = New-PackageCopy -Name 'archived-waiver'
            $manifestPath = Join-Path $copy 'tools/vendored-helpers.manifest.json'
            $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json

            $archived = @($manifest.vendored) | Where-Object { $_.Kind -eq 'archived' } | Select-Object -First 1
            $archived.ArchivedFrom = ''
            $archived.Archived = ''
            $archived.ArchivedAt = ''
            $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifestPath -Encoding utf8 -NoNewline

            $result = Invoke-Gate -RootPath $copy
            $result.ExitCode | Should -Not -Be 0
            $result.Output | Should -Match 'an archived row carries its provenance, it is never waived'
        }
    }
}

Describe 'Sync-VendoredHelpers archived rows' {

    BeforeAll {
        $script:SyncScript = Join-Path $PSScriptRoot 'Sync-VendoredHelpers.ps1'
        $script:RepoRoot = Split-Path -Parent $script:PackageRoot
        $script:ArchivedFile = '_archive/iqa-superseded-2026-11-03/credential-rescue/skills/watch/REFERENCE.md'
        $script:OldCanonical = 'Skills/credential-rescue/skills/watch/REFERENCE.md'

        # These cases prove the REPOSITORY's archive linkage: they need the canonical
        # Skills tree, its _archive and the archive manifest beside the package. An
        # isolated copy of the package has none of that by design, so the case is
        # skipped-with-waiver there and named as such - never passed, and never a
        # red that says the package is broken. In the repository it always runs.
        $script:HasRepoSkills = Test-Path -LiteralPath (Join-Path $script:RepoRoot 'Skills') -PathType Container

        function Skip-WithoutRepoSkills {
            if ($script:HasRepoSkills) { return $false }
            Set-ItResult -Skipped -Because "the archived-row fixture needs the repository's Skills tree beside the package (looked for $(Join-Path $script:RepoRoot 'Skills')); an isolated copy proves recorded hashes only"
            return $true
        }

        # A fixture repo: the Skills tree (so copy rows and the archive are both
        # real) plus a copy of this package beside it. The generator resolves the
        # archive from the package's own location, so this is the isolated proof.
        function New-ArchiveFixture {
            param([Parameter(Mandatory)][string] $Name)

            $root = Join-Path $TestDrive $Name
            New-Item -ItemType Directory -Path $root -Force | Out-Null
            Copy-Item -LiteralPath (Join-Path $script:RepoRoot 'Skills') -Destination (Join-Path $root 'Skills') -Recurse -Force
            Copy-Item -LiteralPath $script:PackageRoot -Destination (Join-Path $root 'pkg') -Recurse -Force
            return $root
        }

        function Invoke-SyncCheck {
            param([Parameter(Mandatory)][string] $FixtureRoot)

            # The fixture's own copy is the one under test: the generator resolves
            # canonical and archive roots from its own location, so running the
            # real script here would prove the real repo instead of the fixture.
            $fixtureScript = Join-Path $FixtureRoot 'pkg/tools/Sync-VendoredHelpers.ps1'
            $output = & $script:PwshPath -NoProfile -NonInteractive -File $fixtureScript -Check 2>&1
            return [pscustomobject]@{
                ExitCode = $LASTEXITCODE
                Output   = ($output | Out-String)
            }
        }
    }

    It 'exits 0 and proves each archived body against the archived file' {
        if (Skip-WithoutRepoSkills) { return }
        $fixture = New-ArchiveFixture -Name 'archive-intact'

        $result = Invoke-SyncCheck -FixtureRoot $fixture
        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match 'archived sha256'
        $result.Output | Should -Match 'source=credential-rescue/skills/watch/REFERENCE\.md'
    }

    It 'fails, naming the archived path, when an archived file is gone' {
        if (Skip-WithoutRepoSkills) { return }
        $fixture = New-ArchiveFixture -Name 'archive-deleted'
        $archivedPath = Join-Path $fixture "Skills\$($script:ArchivedFile -replace '/', '\')"
        Move-Item -LiteralPath $archivedPath -Destination "$archivedPath.moved" -Force

        $result = Invoke-SyncCheck -FixtureRoot $fixture
        $result.ExitCode | Should -Be 1
        $result.Output | Should -Match 'MISSING'
        $result.Output | Should -Match 'archived file absent'
        $result.Output | Should -Match ([regex]::Escape($script:ArchivedFile))
    }

    It 'fails when the archived bytes are no longer the recorded body' {
        if (Skip-WithoutRepoSkills) { return }
        $fixture = New-ArchiveFixture -Name 'archive-edited'
        $archivedPath = Join-Path $fixture "Skills\$($script:ArchivedFile -replace '/', '\')"
        Add-Content -LiteralPath $archivedPath -Value 'planted edit' -Encoding utf8

        $result = Invoke-SyncCheck -FixtureRoot $fixture
        $result.ExitCode | Should -Be 1
        $result.Output | Should -Match 'DRIFT'
        $result.Output | Should -Match 'archived file is not the recorded body'
    }

    It 'fails with CONFLICT when the old canonical path reappears beside the archive' {
        if (Skip-WithoutRepoSkills) { return }
        $fixture = New-ArchiveFixture -Name 'archive-two-owners'
        $archivedPath = Join-Path $fixture "Skills\$($script:ArchivedFile -replace '/', '\')"
        $restoredPath = Join-Path $fixture ($script:OldCanonical -replace '/', '\')
        Copy-Item -LiteralPath $archivedPath -Destination $restoredPath -Force

        $result = Invoke-SyncCheck -FixtureRoot $fixture
        $result.ExitCode | Should -Be 1
        $result.Output | Should -Match 'CONFLICT'
        $result.Output | Should -Match 'one body, two owners'
    }

    It 'keeps the archived provenance in the manifest instead of dropping the rows' {
        if (Skip-WithoutRepoSkills) { return }
        $fixture = New-ArchiveFixture -Name 'archive-rows'
        $manifestPath = Join-Path $fixture 'pkg/tools/vendored-helpers.manifest.json'
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json

        $archivedRows = @($manifest.vendored | Where-Object { $_.Kind -eq 'archived' })
        $archivedRows.Count | Should -Be 5
        foreach ($row in $archivedRows) {
            $row.ArchivedFrom | Should -Not -BeNullOrEmpty
            $row.Archived | Should -Match '^_archive/iqa-superseded-2026-11-03/'
            $row.Sha256 | Should -Match '^[0-9A-F]{64}$'
            $row.Canonical | Should -BeNullOrEmpty
        }
    }
}
