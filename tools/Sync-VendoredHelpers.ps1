#Requires -Version 7
<#
.SYNOPSIS
    Owns every vendored tree in this package: one manifest, one writer, one
    drift gate.

.DESCRIPTION
    The members prescribe helpers and machinery by name. A package that
    prescribes a capability it does not ship cannot be exercised in isolation,
    so the files are vendored under scripts/ and vendor/ and this script is the
    only owner of where each copy comes from.

    The manifest has five kinds of row, all written to a single generated file,
    tools/vendored-helpers.manifest.json:

      copy rows       a canonical file under the canonical Skills root and its
                      byte-identical vendored copy. One row per file, including
                      every file of a declared subtree (so a 60-file tree still
                      prints and drifts one line per file).
      snapshot rows   a vendored document whose canonical source is a composite
                      or an excerpt, so byte-equality is impossible. The hash is
                      of the vendored file itself; it makes an edit visible and
                      is re-recorded only by -UpdateSnapshots.
      not-vendored    a named helper the package deliberately does not ship,
                      with the owner that keeps it and the reason a copy would
                      be wrong.
      patched rows    a vendored file that deliberately differs from its
                      canonical source, because the package copy must resolve
                      outside the package. Records the vendored hash AND the
                      canonical hash it was patched from, so a canonical change
                      is a DRIFT that names the patch rather than a silent fork.
                      The tree copy never overwrites a patched file.

    A declared tree exclusion is machine state, not content (provider-lock.json):
    the tree copy skips it, the manifest lists it as not-vendored with the reason,
    and -Check does not call the missing copy a MISSING row.

    There is one more kind for the docs this repo archived:

      archived rows   a vendored copy whose canonical source was moved out of
                      the live Skills root into Skills/_archive/<archive>/.
                      The row keeps the old source path, the archived path and
                      the archived file's sha256, so the provenance survives the
                      move. -Check verifies the archived file's hash against the
                      row, and does not report MISSING just because the old
                      canonical path is gone. An archived row is verified, never
                      waived: a deleted or edited archived file is a hard
                      failure, and so is the old source reappearing beside it (two
                      owners for one body). The archived path and hash are read
                      from the archive's own manifest.json, which stays the
                      record of the move; this manifest only mirrors it.

    Default mode copies every copy row over its vendored path, re-hashes, writes
    the manifest, and prints one entry per file: name, source, destination and
    byte length. It refuses to re-record a changed snapshot without
    -UpdateSnapshots, because silently re-hashing an edited snapshot is the same
    false green as editing a vendored helper in place.

    -Check writes nothing and prints one row per file: MATCH / DRIFT / MISSING /
    ORPHAN / CONFLICT. It compares the vendored file to its recorded hash always,
    and to the canonical file whenever the canonical tree is reachable - so a copy
    of the package outside its checkout still proves the files it ships, and a
    checkout additionally proves they still match their source. A patched row is
    compared to its recorded canonical hash as well as its own, and an archived row
    is compared to the archived file instead of a canonical one, and a CONFLICT
    row means the old canonical path came back while the row still says archived
    (one body, two owners). Orphans (a file under vendor/, scripts/ or
    references/vendored/ that has no manifest row) are reported by name. Exit 1
    when any row is not MATCH; exit 2 when the manifest itself is absent or
    unreadable (a named non-verdict, never a pass).

    Canonical root: <repo>/Skills derived from this script's own location
    (tools/ -> package -> repo) when that directory exists, otherwise
    $env:CL_REPOS_ROOT\cl-common\Skills. The owning checkout wins because a
    package must prove the tree it ships from; the fleet variable is the fallback
    for a copy made outside a checkout.

    Archive root: always <repo>/Skills/_archive, derived from this script's own
    location, never from $env:CL_REPOS_ROOT. An archive row describes the tree
    that owns this package, so it must be proven against that tree; a package
    copied out of its checkout has no archive to prove and says so per row
    instead of passing quietly.

    Copies are byte-identical on purpose: each vendored file keeps its own
    `#Requires -Version 7` header and help block intact, and
    tools/Test-VendoredHelpers.ps1 parser-checks every vendored script so a
    truncated copy cannot ride a hash claim. A vendored file that still names a
    fleet Skills path is declared in the residuals list with a reason, so the
    remaining out-of-package references are visible instead of assumed absent.

    Exit codes
      0  copied every row and wrote the manifest (default); or every row MATCH (-Check)
      1  a canonical file was missing, a snapshot changed without -UpdateSnapshots,
         or at least one row is DRIFT / MISSING / ORPHAN (-Check)
      2  CANNOT-EVALUATE - the manifest is absent or unreadable (-Check, -ListManifest)

.PARAMETER Check
    Compare recorded and canonical hashes, detect orphans. No writes.

.PARAMETER ListManifest
    Print the manifest as JSON and exit. No writes.

.PARAMETER UpdateSnapshots
    Allow default mode to re-record a snapshot row whose hash changed.

.PARAMETER PackageRoot
    Package root whose vendored paths are written or measured. Defaults to the
    parent directory of this script.

.EXAMPLE
    pwsh -NoProfile -File interactive-qa/tools/Sync-VendoredHelpers.ps1

.EXAMPLE
    pwsh -NoProfile -File interactive-qa/tools/Sync-VendoredHelpers.ps1 -Check

.EXAMPLE
    pwsh -NoProfile -File interactive-qa/tools/Sync-VendoredHelpers.ps1 -ListManifest
#>
[CmdletBinding()]
param(
    [switch] $Check,

    [switch] $ListManifest,

    [switch] $UpdateSnapshots,

    # A patched row whose canonical source moved is refused by default: recording
    # the new canonical hash against an old patched body would report MATCH while
    # the patch silently skipped an upstream change. Pass this only AFTER copying
    # the new canonical and re-applying the patch, so the acceptance is a
    # deliberate act rather than a way to silence the check.
    [switch] $AcceptCanonicalMove,

    [string] $PackageRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ManifestRelativePath = 'tools/vendored-helpers.manifest.json'

# --- the one table ------------------------------------------------------------
# Subtree rows: a canonical directory mirrored recursively under a vendored
# directory. Every file becomes its own manifest row, so -Check still names
# each file and an orphan is still detectable.
$script:VendoredTrees = @(
    [pscustomobject]@{
        Canonical = 'credential-rescue'
        Vendored  = 'vendor/credential-rescue'
        Why       = 'The Key family (cutover, watch, Key Check, provider lock, ~/.aws restore) with scripts/lib internals and its own Tests. The key-* members execute these paths, so the package ships them.'
    }
)

# Excluded from a vendored tree: a canonical file that is MACHINE STATE, not
# content. Vendoring it guarantees permanent drift, because the tool that owns it
# rewrites it with this machine's fingerprints - and running that tool then dirties
# the package tree it was published from. The tool resolves it from the profile
# state root instead (declared per row below).
$script:VendoredTreeExclusions = @(
    [pscustomobject]@{
        Canonical = 'credential-rescue/assets/provider-lock.json'
        Owner     = 'the provider-lock tool itself, at the machine state root'
        Reason    = 'runtime state written by the tool, resolved from the profile state root'
    }
)

# Patched rows: a vendored file that deliberately differs from its canonical
# source. Used only where the package copy must resolve outside the package (the
# canonical owner still points into a fleet checkout). The row records BOTH hashes
# - the vendored bytes and the canonical source they were patched from - so a
# canonical change is still a DRIFT that names the patch, never a silent fork.
$script:PatchedFiles = @(
    [pscustomobject]@{
        Canonical = 'credential-rescue/scripts/Invoke-ProviderLock.ps1'
        Vendored  = 'vendor/credential-rescue/scripts/Invoke-ProviderLock.ps1'
        Patch     = 'lock-path-outside-package'
        Why       = 'The lock is machine state written on this machine, so the package copy resolves it from the profile state root ($env:MACHINE_STATE_HOME/credential-rescue/provider-lock.json, or ~/.machine/state/credential-rescue) with a read-only legacy fallback to the old in-tree asset, and -Mode Lock writes the state root. The canonical script keeps its in-tree default until the fleet tool is retired.'
    }
    [pscustomobject]@{
        Canonical = 'credential-rescue/scripts/Switch-OpencodeGoKey.ps1'
        Vendored  = 'vendor/credential-rescue/scripts/Switch-OpencodeGoKey.ps1'
        Patch     = 'state-root-log-fallback'
        Why       = 'The canonical script throws when CL_REPOS_ROOT is unset, which made an installed copy unable to plan a cutover. The package copy falls back to the machine logs root (~/.machine/logs) for the credential-change log and the legacy Tools paths; a fleet run is unchanged.'
    }
)

# File rows: one canonical file -> one vendored file. Every vendored file lives
# under vendor/, mirroring the canonical Skills layout, exactly once. The layout
# is not cosmetic: the vendored Key scripts resolve their siblings and their
# cross-skill helpers by relative path (../../aws/scripts/SecretFingerprint.ps1,
# ../../iqa-merge/HubRegistry.ps1, ../../git-operations/Invoke-WorktreeLease.ps1),
# so those two locations are where a package run must find them.
$script:VendoredFiles = @(
    # iqa-merge/ and iqa-mode/ helpers are NOT here: their fleet sources were
    # retired at Phase 5, so they are owned in-package rows (see OwnedFiles above).
    [pscustomobject]@{ Canonical = 'git-operations/Invoke-WorktreeLease.ps1'; Vendored = 'vendor/git-operations/Invoke-WorktreeLease.ps1' }

    [pscustomobject]@{ Canonical = 'agent-spawn-capacity/scripts/AgentCapacity.ps1';          Vendored = 'vendor/agent-spawn-capacity/scripts/AgentCapacity.ps1' }
    [pscustomobject]@{ Canonical = 'agent-spawn-capacity/scripts/AgentCapacity.Registry.ps1'; Vendored = 'vendor/agent-spawn-capacity/scripts/AgentCapacity.Registry.ps1' }
    [pscustomobject]@{ Canonical = 'agent-spawn-capacity/assets/agent-capacity.json';         Vendored = 'vendor/agent-spawn-capacity/assets/agent-capacity.json' }

    [pscustomobject]@{ Canonical = 'paseo-child-agents/iqa-done.schema.json'; Vendored = 'vendor/paseo-child-agents/iqa-done.schema.json' }
    [pscustomobject]@{ Canonical = 'paseo-child-agents/validate-done.mjs';    Vendored = 'vendor/paseo-child-agents/validate-done.mjs' }
    [pscustomobject]@{ Canonical = 'paseo-child-agents/lane-watch.mjs';       Vendored = 'vendor/paseo-child-agents/lane-watch.mjs' }

    # Dot-sourced by Invoke-ProviderLock / Invoke-KeyCheck / Invoke-KeyCheckCutover
    # / Invoke-KeyCheckWitness at ../../aws/scripts/SecretFingerprint.ps1. Found by
    # running the prescribed ProviderLock command from an isolated copy, where it
    # failed on the missing file.
    [pscustomobject]@{ Canonical = 'aws/scripts/SecretFingerprint.ps1';       Vendored = 'vendor/aws/scripts/SecretFingerprint.ps1' }
)

# Owned rows: files whose canonical owner is THIS PACKAGE.
#
# The IQA family (iqa-merge, iqa-mode) and the package's own lib/ resolvers were
# retired out of the fleet Skills tree at Phase 5 - the live IQA text moved into
# this plugin. A row that still named a canonical source under Skills/ therefore
# pointed at nothing: -Check could only ever report MISSING, and no re-sync could
# ever make it MATCH. Ownership is a fact about where the body lives, so the
# manifest records it rather than pretending an upstream still exists.
#
# An owned row is checked against its own recorded hash (an unrecorded edit is a
# DRIFT) and nothing else. There is no upstream to compare, so the row must say
# in its Why that this package is the owner - a silent "no source" is exactly the
# fake-green this manifest exists to prevent.
$script:OwnedFiles = @(
    [pscustomobject]@{ Vendored = 'vendor/iqa-merge/AtomicRecordWrite.ps1';          Why = 'Atomic JSON publish policy; the fleet source was retired at Phase 5 and this copy is now the owner every other vendored helper dot-sources.' }
    [pscustomobject]@{ Vendored = 'vendor/iqa-merge/Get-HubCadence.ps1';             Why = 'Hub cadence derivation; the fleet source was retired at Phase 5 and the iqa-hub member cites this copy.' }
    [pscustomobject]@{ Vendored = 'vendor/iqa-merge/HubRegistry.ps1';                Why = 'Hub registry; the fleet source was retired at Phase 5 and this copy is what a Hub registers and a monitor finds.' }
    [pscustomobject]@{ Vendored = 'vendor/iqa-merge/Invoke-HubProbe.ps1';            Why = 'Hub-start probe; the fleet source was retired at Phase 5 and the iqa-hub member cites this copy.' }
    [pscustomobject]@{ Vendored = 'vendor/iqa-merge/Invoke-ScheduleRecordWrite.ps1'; Why = 'Schedule-record write policy; the fleet source was retired at Phase 5 and the one-rung rule is enforced through this copy.' }
    [pscustomobject]@{ Vendored = 'vendor/iqa-merge/Test-Landed.ps1';                Why = 'Landing proof; the fleet source was retired at Phase 5 and the merge close-out rule cites this copy.' }
    [pscustomobject]@{ Vendored = 'vendor/iqa-merge/Test-ScheduleDispatch.ps1';      Why = 'Schedule dispatch check; the fleet source was retired at Phase 5 and the one-rung rule cites this copy.' }
    [pscustomobject]@{ Vendored = 'vendor/iqa-merge/Test-SingleHubRung.ps1';         Why = 'One-rung-per-repo guard; the fleet source was retired at Phase 5 and the iqa-hub member cites this copy.' }
    [pscustomobject]@{ Vendored = 'vendor/iqa-merge/Tests/Get-HubCadence.Tests.ps1'; Why = 'Pins the cadence gate (cl-common-cuz: a rung that exists is never re-created); this package is the owner because the fleet Skills/iqa-merge/Tests that used to hold it was retired at Phase 5.' }
    [pscustomobject]@{ Vendored = 'vendor/iqa-merge/Tests/Test-SingleHubRung.Tests.ps1'; Why = 'Pins the one-rung-per-repo guard (cl-common-5wy: a spent one-shot lane dispatch cannot fire again, so it is tolerated rather than counted as a competing rung); the package owns the guard, so the pin ships beside it.' }
    [pscustomobject]@{ Vendored = 'vendor/dispatch/scripts/run-iqa-worker.ps1';      Why = 'Detached worker dispatch; the fleet source (iqa-mode) was retired at Phase 5 and the dispatch member cites this copy.' }
    [pscustomobject]@{ Vendored = 'vendor/dispatch/scripts/Test-OpencodeProvider.ps1'; Why = 'Provider reachability pre-check for a dispatch; the fleet source (iqa-mode) was retired at Phase 5.' }
    [pscustomobject]@{ Vendored = 'vendor/dispatch/assets/no-approvals.json';        Why = 'Worker config that denies approval prompts; the fleet source (iqa-mode) was retired at Phase 5.' }
    [pscustomobject]@{ Vendored = 'lib/Resolve-ClCommon.ps1';                        Why = 'Package-owned resolver for the cl-common checkout. The package must not bundle cl-common, and must not guess its absence either.' }
    [pscustomobject]@{ Vendored = 'lib/Resolve-PrimaryRepos.ps1';                    Why = 'Package-owned resolver for the machine primary-repo registry, so no member hardcodes which repos are primary.' }
)

# Archived rows: vendored documents whose canonical source was moved out of the
# live Skills root into Skills/_archive/<archive>/ (Phase 5 of the plugin
# migration, bead cl-common-fel). The old path is provenance, not a location: it
# is recorded so a reader can see where the body used to live, and -Check proves
# the archived file instead of looking for it there. Archived path and hash come
# from the archive's own manifest.json - the record of the move - never from a
# value typed here.
$script:ArchiveManifestRelativePath = '_archive/iqa-superseded-2026-11-03/manifest.json'

$script:ArchivedFiles = @(
    [pscustomobject]@{
        Source   = 'credential-rescue/REFERENCE.md'
        Vendored = 'vendor/credential-rescue/REFERENCE.md'
        Why      = 'The long-form Key runbook, now owned by this package copy; the live skill resolves the vendored body.'
    }
    [pscustomobject]@{
        Source   = 'credential-rescue/skills/paseo-rescue/REFERENCE.md'
        Vendored = 'vendor/credential-rescue/skills/paseo-rescue/REFERENCE.md'
        Why      = 'The paseo-rescue reference body, now owned by this package copy.'
    }
    [pscustomobject]@{
        Source   = 'credential-rescue/skills/watch/REFERENCE.md'
        Vendored = 'vendor/credential-rescue/skills/watch/REFERENCE.md'
        Why      = 'The key-watch reference body, now owned by this package copy; the key-watch member cites the vendored path.'
    }
    [pscustomobject]@{
        Source   = 'credential-rescue/assets/opencode-go-seam-projection-2026-10-16.md'
        Vendored = 'vendor/credential-rescue/assets/opencode-go-seam-projection-2026-10-16.md'
        Why      = 'A dated seam-projection record, now owned by this package copy.'
    }
    [pscustomobject]@{
        Source   = 'credential-rescue/assets/paseo-muse-spark-resolution-2026-10-15.md'
        Vendored = 'vendor/credential-rescue/assets/paseo-muse-spark-resolution-2026-10-15.md'
        Why      = 'A dated model-resolution record, now owned by this package copy.'
    }
)

# Snapshot rows: vendored documents whose canonical source is a composite of
# several sections, so no single canonical file can be byte-compared. The hash
# is of the vendored file and exists to make an edit visible.
$script:SnapshotFiles = @(
    [pscustomobject]@{
        Vendored = 'references/vendored/qa-procedure.md'
        Owner    = 'Skills/iqa-common/REFERENCE.md + Skills/iqa-beads/REFERENCE.md + Skills/iqa-mode/REFERENCE.md + Skills/iqa-beads-saas/SKILL.md'
        Why      = 'Composite snapshot of several canonical sections (see the file''s own ## Provenance table). No single canonical file is byte-identical to it, so the recorded hash measures edits to the snapshot itself; re-take the snapshot from those sources rather than patching it.'
    }
    [pscustomobject]@{
        Vendored = 'references/vendored/iqa-common-contracts.md'
        Owner    = 'Skills/iqa-common/REFERENCE.md'
        Why      = 'Excerpt snapshot of two normative sections (completion-report contract, session-log contract) from one canonical file. The excerpt cannot equal its source byte-for-byte, so the recorded hash measures edits to the excerpt.'
    }
)

function New-NotVendoredRow {
    param(
        [Parameter(Mandatory)][string] $Owner,
        [Parameter(Mandatory)][string] $Reason,
        [Parameter(Mandatory)][string[]] $Names
    )

    foreach ($name in $Names) {
        [pscustomobject]@{ Name = $name; Owner = $Owner; Reason = $Reason }
    }
}

# Deliberately not vendored: every helper the package's Markdown names that the
# package does not ship, with the owner that keeps it and why a copy would be
# wrong. A row here is a decision, not an oversight - silence is what
# tools/Test-VendoredHelpers.ps1 fails on.
$script:NotVendoredHelpers = @(
    New-NotVendoredRow -Owner 'Skills/currents-bookkeeping/scripts' -Names @(
        'merge-queue.mjs'
    ) -Reason ('The fleet merge-queue tool. This package ships its own queue ' +
        '(tools/Invoke-IqaQueue.ps1) with the IDENTICAL row format, so a session never needs a ' +
        'checkout of another product repo to park or drain work; the fleet tool is named only as ' +
        'the compatibility counterpart that reads and writes the same files.')

    New-NotVendoredRow -Owner 'the repo under test (scripts/gate)' -Names @(
        'registry.mjs'
    ) -Reason ('A gate registry that lives in the repo being merged, discovered per repo. It is ' +
        'not a skill helper, so vendoring it would pin one product repo''s gate ids into the package.')

    New-NotVendoredRow -Owner 'the fleet merge ledger' -Names @(
        'merge-ledger.mjs'
    ) -Reason ('The cross-repo merge ledger, run by path from the fleet checkout that owns the ' +
        'ledger DB. A Hub on a machine without that checkout records the ledger follow-up as a bead ' +
        'instead and says so; a vendored copy with no ledger DB would be a dead tool.')

    New-NotVendoredRow -Owner 'the shared-dependency gate' -Names @(
        'Test-SharedDepAgreement.mjs'
    ) -Reason ('Compares a pending branch against the FLEET tree (--root <fleet> --ref <trunk>), ' +
        'so it needs the fleet checkout to have anything to compare. Named by the Hub probe as a ' +
        'development-override step, not as part of the Hub-start contract.')

    New-NotVendoredRow -Owner 'the provider-lock tool' -Names @(
        'provider-lock.json'
    ) -Reason ('Runtime state written by the tool, resolved from the profile state root ' +
        '($env:MACHINE_STATE_HOME\credential-rescue\provider-lock.json, or ~/.machine/state/credential-rescue) with a read-only ' +
        'legacy fallback to the old in-tree copy. Vendoring it would drift on every -Mode Lock run ' +
        'and make the tool write into its own package.')

    New-NotVendoredRow -Owner 'Skills/git-operations' -Names @(
        'Invoke-SafeCommit.ps1', 'Invoke-TrunkMergeLock.ps1', 'Invoke-GitPullSafe.ps1'
    ) -Reason ('Operate the checkout and trunk lock of the repo being worked, so they are resolved from the ' +
        'checkout they guard. The Hub-start contract needs the worktree lease only, and that one is vendored.')

    New-NotVendoredRow -Owner 'Skills/repo-clean' -Names @(
        'Invoke-RepoClean.ps1'
    ) -Reason ('The periodic deep groom, run by name on a schedule; a Hub session probes with the vendored ' +
        'Invoke-HubProbe.ps1 and never runs a full groom inside a turn.')

    New-NotVendoredRow -Owner 'Skills/iqa-merge/Tests' -Names @(
        'HubRegistry.Tests.ps1', 'Invoke-HubProbe.Tests.ps1', 'Test-Landed.Tests.ps1',
        'Test-ScheduleDispatch.Tests.ps1', 'Invoke-ScheduleRecordWrite.Tests.ps1',
        'AtomicRecordWrite.Tests.ps1'
    ) -Reason ('Pin the canonical helpers against a bare-remote and registry fixture. The vendored copies are ' +
        'byte-identical and drift is caught by this package''s own Sync-VendoredHelpers.ps1 -Check, so a ' +
        'second pinning suite inside the package would duplicate ownership without adding proof. ' +
        'Get-HubCadence.Tests.ps1 is the exception: it is an owned in-package row (cl-common-cuz) because ' +
        'the cadence gate is now owned here and the no-CREATE rule needs a shipped pin.')

    New-NotVendoredRow -Owner 'Skills/iqa-merge' -Names @(
        'Test-VendoredSync.ps1'
    ) -Reason ('Merge-acceptance gate for the repo being merged: it reads that repo''s trunk refs, ' +
        'diff and throwaway worktrees and runs this package''s vendored Sync-VendoredHelpers.ps1 against ' +
        'them. A copy inside the package would have no trunk to measure, so the fleet checkout keeps it.')

    New-NotVendoredRow -Owner 'Skills/iqa-mode/scripts' -Names @(
        'iqa-hub.ps1'
    ) -Reason ('Legacy iqa-mode Hub record helper, superseded by the vendored HubRegistry.ps1; named only in ' +
        'the Phase-0 inventory as history.')

    New-NotVendoredRow -Owner 'Skills/paseo-child-agents' -Names @(
        'Get-PaseoSelfAgentId.ps1', 'Send-PaseoMessage.ps1', 'Receive-PaseoMail.ps1'
    ) -Reason ('Paseo transport helpers: they need a live Paseo surface and are named by the dispatch member ' +
        'as the executor adapter, which is a profile value rather than a package dependency.')

    New-NotVendoredRow -Owner 'Skills/branch-worktree-hygiene' -Names @(
        'Invoke-BranchWorktreeHygiene.ps1'
    ) -Reason ('Hygiene sweep behind the Hub probe''s hygiene part; it runs against the repo it grooms and ' +
        'needs that repo''s refs, not a copy.')

    New-NotVendoredRow -Owner 'Skills/install-harness' -Names @(
        'Invoke-HarnessInstall.ps1'
    ) -Reason ('Installs the cross-harness skill pointers on the machine - a deployment step, not a session ' +
        'helper a member calls mid-turn.')

    New-NotVendoredRow -Owner 'Skills/iqa-beads/scripts' -Names @(
        'Export-Iqa2Beads.ps1', 'Invoke-Iqa2BeadsInit.ps1'
    ) -Reason ('Legacy iqa2 beads export/init shape; graph writes go through bd, and no Hub-start path needs ' +
        'either script.')

    New-NotVendoredRow -Owner 'Public/IQA-beads/scripts (canonical plugin)' -Names @(
        'Get-Iqa2CollectionQueue.ps1', 'Get-Iqa2CollectionStatus.ps1'
    ) -Reason ('The collection dispatch queue and census are owned by the canonical IQA-beads plugin, which ' +
        'the Hub runs from that checkout (`-Workdir <repo>`); they read the repo graph through bd and are ' +
        'read-only. Vendoring them would create a second copy of a contract the plugin is the single owner ' +
        'of, so the Hub prescribes the command by name and resolves it at run time.')
    New-NotVendoredRow -Owner 'Skills/cl-paseo/scripts' -Names @(
        'Get-PaseoWorkspaceRecordReport.ps1'
    ) -Reason ('Reads this machine''s Paseo workspace records. Named as the diagnostic a dispatch prints when ' +
        'a workspace record conflicts; it is machine state, not a package helper.')

    New-NotVendoredRow -Owner 'Public/salmon-run/Tools' -Names @(
        'Install-PaseoDeepSeekHarness.ps1', 'Sync-SalmonRunCodingKeys.ps1'
    ) -Reason ('Salmon Run installs the DeepSeek harness and syncs its own coding-keys file from Secret Manager; ' +
        'named in the key-cutover prose as the repair route for a BINARY(DSH) classification and the follow-up ' +
        'after an IAM-key rotation, which belongs to that repo.''s tooling.')

    New-NotVendoredRow -Owner '(operator-held bundle asset)' -Names @(
        'restore.ps1'
    ) -Reason ('The ~/.aws restore bundle script: untracked from the tree by ca236ac6 and absent by design. ' +
        'REFERENCE.md says to take the copy from the operator and never to copy its contents into logs, chat, ' +
        'memory or commits - so vendoring it would be the disclosure the runbook forbids.')

    New-NotVendoredRow -Owner 'Public/salmon-run/skills/operator-git-operations' -Names @(
        'Invoke-TrunkPrep.ps1'
    ) -Reason ('Trunk preparation that the Hub probe runs as one of its parts; owned by the orchestrator repo ' +
        'and resolved from the fleet root at run time.')

    New-NotVendoredRow -Owner 'currents-bookkeeping/scripts' -Names @(
        'auto-deploy-dev.ps1'
    ) -Reason ('Repo-local post-merge deploy hook named by the currents-bookkeeping profile; it belongs to ' +
        'that product repo, not to any skill.')

    New-NotVendoredRow -Owner '(historical - superseded)' -Names @(
        'Invoke-HubPreflight.ps1'
    ) -Reason ('HISTORICAL, not a live command: the name appears only in the v7 changelog entry of ' +
        'members/iqa-hub/REFERENCE.md, where it was the Step 0 preflight before v8 renamed and folded it ' +
        'into Repo Clean (Invoke-RepoClean.ps1). The changelog is a record of what happened and is never ' +
        'rewritten, so the old name stays there as history; nothing prescribes running it.')
)

# Declared residuals: a vendored file that still names a fleet Skills path. Each
# row is an admission with a reason, not a waiver of the drift gate. The gate
# fails when a declared residual no longer matches (a stale excuse) AND when an
# undeclared one appears, so the list can only shrink deliberately.
$script:Residuals = @(
    [pscustomobject]@{
        Path   = 'lib/Resolve-ClCommon.ps1'
        Reason = 'The integration seam itself: this resolver exists to FIND the fleet cl-common checkout, so it must name the convention ($env:CL_REPOS_ROOT\cl-common) plus the explicit $env:CL_COMMON_PATH override. It resolves nothing else and degrades to a named absence; removing the reference would remove the only way the package can locate the machine skills it references but must not bundle.'
    }
    [pscustomobject]@{
        Path   = 'vendor/credential-rescue/scripts/Invoke-CredentialRescueWatch.ps1'
        Reason = 'Watch driver: resolves Switch-OpencodeGoKey.ps1 and the opencode CLI from CL_REPOS_ROOT instead of beside itself. A package run of the LOOP therefore needs that machine value; every Key command the members prescribe (Test-GoKey, ProviderLock, Repair-Paseo, the Key Check entry points) resolves in-package. Fix belongs in the canonical script ($PSScriptRoot sibling), then re-sync.'
    }
    [pscustomobject]@{
        Path   = 'vendor/credential-rescue/scripts/Switch-OpencodeGoKey.ps1'
        Reason = 'Names CL_REPOS_ROOT as the fleet ledger root (help block, and the default when it is set). The package copy falls back to the profile state root when it is unset, so an installed copy can plan and perform a cutover; machine state, not a package path.'
    }
    [pscustomobject]@{
        Path   = 'vendor/credential-rescue/scripts/Restore-AwsStore.ps1'
        Reason = 'Default restore-bundle directory and credential-change log. Machine state (where this box keeps its bundles); the script itself is in-package.'
    }
    [pscustomobject]@{
        Path   = 'vendor/credential-rescue/scripts/Test-GoKey.ps1'
        Reason = 'Last-resort opencode CLI fallback when PATH and OPENCODE_CLI_PATH are empty. Machine tool location, not a skill dependency; the seam it reads resolves beside the script.'
    }
    [pscustomobject]@{
        Path   = 'vendor/credential-rescue/scripts/Test-PaseoMuseSparkCanary.ps1'
        Reason = 'Same opencode CLI fallback as Test-GoKey.ps1.'
    }
    [pscustomobject]@{
        Path   = 'vendor/credential-rescue/scripts/Invoke-ProviderLock.ps1'
        Reason = 'Help-block examples only (documentation of the canonical invocation). No resolution depends on it.'
    }
    [pscustomobject]@{
        Path   = 'vendor/dispatch/scripts/Test-OpencodeProvider.ps1'
        Reason = 'Prefers the fleet seam path when CL_REPOS_ROOT is set (the tracked seam is mutated in the main checkout, and a lane worktree carries a stale copy). A machine fact the profile supplies; the script''s own fallback resolves ../../credential-rescue inside vendor/, so an isolated copy still resolves in-package.'
    }
    [pscustomobject]@{
        Path   = 'vendor/agent-spawn-capacity/scripts/AgentCapacity.ps1'
        Reason = 'Expands %CL_REPOS% / %CL_COMMON_HOME% in the capacity registry and defaults the spawn log under the fleet Tasks/Logs. Machine layout, and the registry value the profile owns; the script itself is in-package.'
    }
    [pscustomobject]@{
        Path   = 'vendor/iqa-merge/Invoke-HubProbe.ps1'
        Reason = 'Composes commands for OTHER skills helpers from the fleet root by design (documented in core/ADAPTERS.md -> ## Vendored helpers). Its part statuses come from repo-local git state; only a printed command depends on the fleet root.'
    }
    [pscustomobject]@{
        Path   = 'vendor/credential-rescue/REFERENCE.md'
        Reason = 'Documentation: the long-form runbook spells commands with the fleet Skills root. No resolution depends on it, and the copy is byte-identical so the canonical prose stays the owner.'
    }
    [pscustomobject]@{
        Path   = 'vendor/credential-rescue/skills/salmon-run/SKILL.md'
        Reason = 'Documentation: the salmon-run runbook spells its commands with the fleet Skills root.'
    }
    [pscustomobject]@{
        Path   = 'vendor/credential-rescue/skills/aws-store/SKILL.md'
        Reason = 'Documentation: the aws-store runbook names the fleet restore-bundle directory.'
    }
    [pscustomobject]@{
        Path   = 'vendor/credential-rescue/skills/watch/REFERENCE.md'
        Reason = 'Documentation: the watch reference names the fleet Skills root in an example command.'
    }
    [pscustomobject]@{
        Path   = 'vendor/credential-rescue/skills/paseo-rescue/REFERENCE.md'
        Reason = 'Documentation: the Paseo reference names the fleet Skills root in an example command.'
    }
    [pscustomobject]@{
        Path   = 'vendor/credential-rescue/Tests/Switch-OpencodeGoKey.Tests.ps1'
        Reason = 'Test fixture: sets CL_REPOS_ROOT in the child environment it launches, which is the machine contract the switch requires.'
    }
    [pscustomobject]@{
        Path   = 'vendor/git-operations/Invoke-WorktreeLease.ps1'
        Reason = 'Help-block examples only (the canonical invocation is spelled with a fleet-root path). The checkout lease itself is machine state; this single copy is the one both a Hub session and Resume-KeyCheckRoster / Invoke-CutoverRecovery resolve.'
    }
    [pscustomobject]@{
        Path   = 'references/vendored/qa-procedure.md'
        Reason = 'Documentation: the snapshot spells the fleet root in one example command (`$env:CL_REPOS_ROOT\upscale-havens`, the repo under test), not in a resolution path.'
    }
)

function Resolve-RepoSkillsRoot {
    # tools/ -> package -> repo root
    $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $candidate = Join-Path $repoRoot 'Skills'
    if (Test-Path -LiteralPath $candidate -PathType Container) { return $candidate }
    return $null
}

function Resolve-CanonicalSkillsRoot {
    # The tree that OWNS this package wins: a lane worktree must prove the tree it
    # is editing, not the machine trunk. Preferring $env:CL_REPOS_ROOT is what let
    # the archived bodies read green in a lane while MISSING on dev - the lane
    # checked the trunk and said nothing about its own tree.
    $repoSkills = Resolve-RepoSkillsRoot
    if ($repoSkills) { return [pscustomobject]@{ Path = $repoSkills; Origin = 'repo' } }

    if ($env:CL_REPOS_ROOT) {
        $candidate = Join-Path $env:CL_REPOS_ROOT 'cl-common\Skills'
        if (Test-Path -LiteralPath $candidate -PathType Container) {
            return [pscustomobject]@{ Path = $candidate; Origin = 'fleet' }
        }
    }

    return $null
}

# The archive belongs to the checkout that owns this package, so it is resolved
# from this script's own location - never from $env:CL_REPOS_ROOT, which names a
# machine's trunk and can be a checkout that has not taken the move yet.
function Resolve-ArchiveManifestPath {
    $skillsRoot = Resolve-RepoSkillsRoot
    if (-not $skillsRoot) { return $null }
    $candidate = Join-Path $skillsRoot $script:ArchiveManifestRelativePath
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    return $null
}

# StrictMode makes a missing property a throw, and a hand-edited manifest is the
# one input that can be missing one. A missing field is empty here, which the
# archived branch then treats as an unverifiable row rather than a pass.
function Get-RowField {
    param([object] $Row, [Parameter(Mandatory)][string] $Name)

    $property = $Row.PSObject.Properties[$Name]
    if ($property) { return [string]$property.Value }
    return ''
}

# The archive's manifest.json spells paths repo-relative ('Skills/credential-rescue/REFERENCE.md')
# because that is how a git mv is read; every row here is relative to the Skills
# root, so the leading segment is dropped once and the separator normalized.
function ConvertTo-SkillsRelativePath {
    param([Parameter(Mandatory)][string] $Path)

    $trimmed = $Path.Trim() -replace '\\', '/'
    $trimmed = $trimmed -replace '^\./', ''
    $trimmed = $trimmed -replace '^Skills/', ''
    return $trimmed
}

function Get-Sha256 {
    param([Parameter(Mandatory)][string] $Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

# Line-ending transport is git's business, not content: core.autocrlf rewrites
# CRLF on checkout, so a recorded raw hash would false-red on a checkout with a
# different setting. The normalized hash is the same file with CRLF folded to LF;
# a row matches when either hash matches, so a content change is still always a
# DRIFT and only the transport difference is forgiven.
function Get-Sha256Normalized {
    param([Parameter(Mandatory)][string] $Path)

    $bytes = [System.IO.File]::ReadAllBytes($Path)

    # Fast path: no carriage return at all means the raw bytes are already the
    # normalized form (this is the common case in a git checkout that stores LF).
    if ([Array]::IndexOf($bytes, [byte]13) -lt 0) {
        return [System.Convert]::ToHexString(
            [System.Security.Cryptography.SHA256]::HashData($bytes)
        )
    }

    $text = [System.Text.Encoding]::UTF8.GetString($bytes).Replace("`r`n", "`n")
    [System.Convert]::ToHexString(
        [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($text))
    )
}

function Get-FilesUnder {
    param([Parameter(Mandatory)][string] $Root, [Parameter(Mandatory)][string] $Relative)

    $directory = Join-Path $Root $Relative
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { return @() }

    Get-ChildItem -LiteralPath $directory -Recurse -File | Sort-Object FullName | ForEach-Object {
        $_.FullName.Substring($Root.Length).TrimStart('\', '/') -replace '\\', '/'
    }
}
if (-not $PackageRoot) {
    $PackageRoot = Split-Path -Parent $PSScriptRoot
}

if (-not (Test-Path -LiteralPath $PackageRoot -PathType Container)) {
    Write-Host "Sync-VendoredHelpers: package root not found: $PackageRoot" -ForegroundColor Red
    exit 1
}

$packageFull = (Resolve-Path -LiteralPath $PackageRoot).Path
$manifestPath = Join-Path $packageFull $script:ManifestRelativePath

function Read-ManifestFile {
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { return $null }
    try {
        return Get-Content -LiteralPath $manifestPath -Raw -Encoding utf8 | ConvertFrom-Json
    }
    catch {
        Write-Host "Sync-VendoredHelpers: the manifest is unreadable: $manifestPath - $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }
}

if ($ListManifest) {
    $stored = Read-ManifestFile
    if (-not $stored) {
        Write-Host "Sync-VendoredHelpers: CANNOT-EVALUATE - no readable manifest at $manifestPath (run this script with no argument to write it)" -ForegroundColor Yellow
        exit 2
    }

    [pscustomobject]@{
        schemaVersion = 2
        generatedAt   = $stored.generatedAt
        canonicalRoot = $stored.canonicalRoot
        trees         = @($script:VendoredTrees)
        vendored      = @($stored.vendored)
        notVendored   = @($script:NotVendoredHelpers)
        residuals     = @($script:Residuals)
    } | ConvertTo-Json -Depth 6
    exit 0
}

$canonicalRoot = $null
$canonicalOrigin = ''
$resolvedCanonical = Resolve-CanonicalSkillsRoot
if ($resolvedCanonical) {
    $canonicalRoot = $resolvedCanonical.Path
    $canonicalOrigin = $resolvedCanonical.Origin
}

if ($Check) {
    $canonicalHint = if ($env:CL_REPOS_ROOT) {
        "$env:CL_REPOS_ROOT\cl-common\Skills"
    } else {
        "$(Split-Path -Parent (Split-Path -Parent $PSScriptRoot))\Skills"
    }

    $stored = Read-ManifestFile
    if (-not $stored) {
        Write-Host "Sync-VendoredHelpers -Check: CANNOT-EVALUATE - no readable manifest at $manifestPath" -ForegroundColor Yellow
        Write-Host 'The manifest is generated output: run this script with no argument in a checkout that can see the canonical Skills root.' -ForegroundColor Yellow
        exit 2
    }

    $sourceMode = [bool]$canonicalRoot
    $archiveSkillsRoot = Resolve-RepoSkillsRoot
    $archiveManifest = Resolve-ArchiveManifestPath
    $modeLine = if ($sourceMode) {
        "source: $canonicalRoot (recorded hashes + canonical files)"
    } else {
        "source: recorded hashes only - canonical tree not reachable (looked for $canonicalHint); set CL_REPOS_ROOT to also prove source equality"
    }
    if ($archiveManifest) {
        $modeLine = "$modeLine; archive: $archiveManifest"
    }
    elseif ($archiveSkillsRoot) {
        $modeLine = "$modeLine; archive: no manifest at $(Join-Path $archiveSkillsRoot $script:ArchiveManifestRelativePath)"
    }
    else {
        $modeLine = "$modeLine; archive: not reachable from this copy"
    }
    Write-Output "Sync-VendoredHelpers -Check: $modeLine"

    $rows = [System.Collections.Generic.List[string]]::new()
    $manifestIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $canonicalIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($entry in @($stored.vendored)) {
        [void]$manifestIds.Add($entry.Vendored)

        # Register the canonical path BEFORE any hash verdict. A copy row that
        # drifts on its recorded hash used to skip this registration, so the
        # second pass then reported the very file the row already names as
        # "canonical file has no manifest row" - two defects reported for one
        # stale hash. The row exists whatever the hash says.
        if ($entry.Kind -eq 'copy' -and -not [string]::IsNullOrWhiteSpace([string]$entry.Canonical)) {
            [void]$canonicalIds.Add([string]$entry.Canonical)
        }

        $vendoredPath = Join-Path $packageFull $entry.Vendored
        $status = 'MISSING'
        $detail = ''

        if (-not (Test-Path -LiteralPath $vendoredPath -PathType Leaf)) {
            $status = 'MISSING'
            $detail = "vendored absent: $($entry.Vendored)"
        }
        else {
            $vendoredHash = Get-Sha256 -Path $vendoredPath
            $vendoredHashLf = Get-Sha256Normalized -Path $vendoredPath
            $vendoredLength = (Get-Item -LiteralPath $vendoredPath).Length
            $recordedHash = [string]$entry.Sha256
            $recordedHashLf = [string]$entry.Sha256Lf
            $recordedOk = [string]::IsNullOrWhiteSpace($recordedHash) -or
                ($vendoredHash -eq $recordedHash) -or
                (-not [string]::IsNullOrWhiteSpace($recordedHashLf) -and $vendoredHashLf -eq $recordedHashLf)

            if ($entry.Kind -eq 'snapshot') {
                if ($recordedOk) {
                    $status = 'MATCH'
                    $detail = "snapshot sha256 $($vendoredHash.Substring(0, 12)) bytes=$vendoredLength"
                }
                else {
                    $status = 'DRIFT'
                    $detail = "snapshot edited: recorded=$($recordedHash.Substring(0, 12)) now=$($vendoredHash.Substring(0, 12))"
                }
            }
            elseif ($entry.Kind -eq 'owned') {
                # An owned row's canonical owner is this package, so there is no
                # upstream to compare. The recorded hash is the whole check: a
                # body edited without re-recording is a DRIFT, and a row with no
                # recorded hash is unprovable rather than fine.
                if ([string]::IsNullOrWhiteSpace($recordedHash)) {
                    $status = 'MISSING'
                    $detail = 'owned row records no Sha256 - the body is unprovable, run this script with no argument'
                }
                elseif ($recordedOk) {
                    $status = 'MATCH'
                    $detail = "owned in-package sha256 $($vendoredHash.Substring(0, 12)) bytes=$vendoredLength (this package is the owner)"
                }
                else {
                    $status = 'DRIFT'
                    $detail = "owned in-package body edited: recorded=$($recordedHash.Substring(0, 12)) now=$($vendoredHash.Substring(0, 12)) - re-record with a no-argument run"
                }
            }
            elseif (-not $recordedOk) {
                $status = 'DRIFT'
                $detail = "recorded=$($recordedHash.Substring(0, 12)) now=$($vendoredHash.Substring(0, 12)) bytes=$vendoredLength"
            }
            elseif ($entry.Kind -eq 'archived') {
                # An archived row has no canonical file to compare: the source is
                # recorded as provenance, and the archived copy is what must still
                # hold these exact bytes. Silence here would be a waiver, so a row
                # that cannot name its archived path is a failure, not a pass.
                $archivedRelative = Get-RowField -Row $entry -Name 'Archived'
                $archivedFrom = Get-RowField -Row $entry -Name 'ArchivedFrom'

                if ([string]::IsNullOrWhiteSpace($archivedRelative)) {
                    $status = 'MISSING'
                    $detail = "archived row records no Archived path - provenance is unprovable, run this script with no argument"
                }
                elseif (-not $archiveSkillsRoot) {
                    $status = 'MATCH'
                    $detail = "sha256 $($vendoredHash.Substring(0, 12)) recorded bytes=$vendoredLength; archive not reachable from this copy, so provenance is recorded only"
                }
                else {
                    $archivedPath = Join-Path $archiveSkillsRoot $archivedRelative
                    $sourcePath = if ([string]::IsNullOrWhiteSpace($archivedFrom)) { $null } else { Join-Path $archiveSkillsRoot $archivedFrom }

                    if ($sourcePath -and (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
                        $status = 'CONFLICT'
                        $detail = "archived row, but the old canonical path is back: $archivedFrom - one body, two owners; delete the restored file or regenerate the manifest"
                    }
                    elseif (-not (Test-Path -LiteralPath $archivedPath -PathType Leaf)) {
                        $status = 'MISSING'
                        $detail = "archived file absent: $archivedRelative (source was $archivedFrom)"
                    }
                    else {
                        $archivedHash = Get-Sha256 -Path $archivedPath
                        $archivedHashLf = Get-Sha256Normalized -Path $archivedPath

                        if (($archivedHash -eq $recordedHash) -or
                            (-not [string]::IsNullOrWhiteSpace($recordedHashLf) -and $archivedHashLf -eq $recordedHashLf)) {
                            $status = 'MATCH'
                            $detail = "archived sha256 $($archivedHash.Substring(0, 12)) bytes=$((Get-Item -LiteralPath $archivedPath).Length) source=$archivedFrom"
                        }
                        else {
                            $status = 'DRIFT'
                            $detail = "archived file is not the recorded body: recorded=$($recordedHash.Substring(0, 12)) now=$($archivedHash.Substring(0, 12))"
                        }
                    }
                }
            }
            elseif ($entry.Kind -eq 'patched') {
                # A patched row is proven two ways: the vendored bytes against the
                # recorded hash (above) AND the canonical source against the hash
                # recorded when the patch was taken. A canonical change is a DRIFT
                # that names the patch, so the fork can never drift silently.
                $patchName = Get-RowField -Row $entry -Name 'Patch'
                $recordedCanonical = Get-RowField -Row $entry -Name 'CanonicalSha256'
                $recordedCanonicalLf = Get-RowField -Row $entry -Name 'CanonicalSha256Lf'
                $canonicalRelative = Get-RowField -Row $entry -Name 'Canonical'

                if ([string]::IsNullOrWhiteSpace($patchName) -or [string]::IsNullOrWhiteSpace($recordedCanonical) -or [string]::IsNullOrWhiteSpace($canonicalRelative)) {
                    $status = 'MISSING'
                    $detail = 'patched row records no Canonical/Patch/CanonicalSha256 - the patch is unprovable, run this script with no argument'
                }
                elseif (-not $sourceMode) {
                    $status = 'MATCH'
                    $detail = "patched ($patchName) sha256 $($vendoredHash.Substring(0, 12)) recorded only; canonical tree not reachable"
                }
                else {
                    [void]$canonicalIds.Add($canonicalRelative)
                    $canonicalPath = Join-Path $canonicalRoot $canonicalRelative
                    if (-not (Test-Path -LiteralPath $canonicalPath -PathType Leaf)) {
                        $status = 'MISSING'
                        $detail = "patched row, canonical source absent: $canonicalRelative"
                    }
                    else {
                        $canonicalHash = Get-Sha256 -Path $canonicalPath
                        $canonicalHashLf = Get-Sha256Normalized -Path $canonicalPath
                        $canonicalRecordedOk = ($canonicalHash -eq $recordedCanonical) -or
                            (-not [string]::IsNullOrWhiteSpace($recordedCanonicalLf) -and $canonicalHashLf -eq $recordedCanonicalLf)
                        if ($canonicalRecordedOk) {
                            $status = 'MATCH'
                            $detail = "patched ($patchName) vendored=$($vendoredHash.Substring(0, 12)) canonical=$($canonicalHash.Substring(0, 12)) bytes=$vendoredLength"
                        }
                        else {
                            $status = 'DRIFT'
                            $detail = "canonical moved since the patch was recorded: recorded=$($recordedCanonical.Substring(0, 12)) now=$($canonicalHash.Substring(0, 12)) - re-apply the patch and re-sync"
                        }
                    }
                }
            }
            elseif (-not $sourceMode) {
                $status = 'MATCH'
                $transport = if ($vendoredHash -eq $recordedHash) { 'recorded' } else { 'recorded/eol-normalized' }
                $detail = "sha256 $($vendoredHash.Substring(0, 12)) ($transport) bytes=$vendoredLength"
            }
            else {
                [void]$canonicalIds.Add($entry.Canonical)
                $canonicalPath = Join-Path $canonicalRoot $entry.Canonical

                if (-not (Test-Path -LiteralPath $canonicalPath -PathType Leaf)) {
                    $status = 'MISSING'
                    $detail = "canonical absent: $($entry.Canonical)"
                }
                else {
                    $canonicalHash = Get-Sha256 -Path $canonicalPath
                    $canonicalHashLf = Get-Sha256Normalized -Path $canonicalPath

                    if ($canonicalHash -eq $vendoredHash) {
                        $status = 'MATCH'
                        $detail = "sha256 $($vendoredHash.Substring(0, 12)) canonical=$((Get-Item -LiteralPath $canonicalPath).Length) vendored=$vendoredLength"
                    }
                    elseif ($canonicalHashLf -eq $vendoredHashLf) {
                        $status = 'MATCH'
                        $detail = "sha256(LF) $($vendoredHashLf.Substring(0, 12)) canonical=$((Get-Item -LiteralPath $canonicalPath).Length) vendored=$vendoredLength (line endings only)"
                    }
                    else {
                        $status = 'DRIFT'
                        $detail = "canonical=$($canonicalHash.Substring(0, 12)) vendored=$($vendoredHash.Substring(0, 12))"
                    }
                }
            }
        }

        $rows.Add(('{0,-8} {1,-72} {2}' -f $status, $entry.Vendored, $detail))
    }

    # --- orphans: a vendored file with no manifest row -------------------------
    $orphanScanRoots = @('vendor', 'scripts', 'references/vendored')
    foreach ($scanRoot in $orphanScanRoots) {
        foreach ($relative in (Get-FilesUnder -Root $packageFull -Relative $scanRoot)) {
            if (-not $manifestIds.Contains($relative)) {
                $rows.Add(('{0,-8} {1,-72} {2}' -f 'ORPHAN', $relative, 'no manifest row - every file under vendor/, scripts/ and references/vendored/ is vendored and must be listed'))
            }
        }
    }

    # --- a canonical file with no manifest row (the manifest is behind source) --
    if ($sourceMode) {
        # A declared tree exclusion is a decision, not a missing row: provider-lock
        # is machine state and is never vendored.
        foreach ($exclusion in $script:VendoredTreeExclusions) { [void]$canonicalIds.Add($exclusion.Canonical) }
        foreach ($tree in $script:VendoredTrees) {
            foreach ($relative in (Get-FilesUnder -Root $canonicalRoot -Relative $tree.Canonical)) {
                if (-not $canonicalIds.Contains($relative)) {
                    $rows.Add(('{0,-8} {1,-72} {2}' -f 'MISSING', $relative, 'canonical file has no manifest row - run this script with no argument to vendor it'))
                }
            }
        }
    }

    $rows | ForEach-Object { Write-Output $_ }

    $bad = @($rows | Where-Object { -not $_.StartsWith('MATCH') })
    if ($bad.Count -gt 0) {
        Write-Host "Sync-VendoredHelpers -Check: $($bad.Count) of $($rows.Count) row(s) are not MATCH ($modeLine)" -ForegroundColor Red
        exit 1
    }

    Write-Host "Sync-VendoredHelpers -Check: MATCH - $($rows.Count) vendored file(s) identical ($modeLine)" -ForegroundColor Green
    exit 0
}

# --- default mode: copy, then write the manifest ------------------------------
$declaredCanonical = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($file in $script:VendoredFiles) {
    if (-not $declaredCanonical.Add($file.Canonical)) {
        Write-Host "Sync-VendoredHelpers: '$($file.Canonical)' is declared twice - one canonical file gets one vendored copy" -ForegroundColor Red
        exit 1
    }
}

if (-not $canonicalRoot) {
    $hint = if ($env:CL_REPOS_ROOT) {
        "$env:CL_REPOS_ROOT\cl-common\Skills"
    } else {
        "$(Split-Path -Parent (Split-Path -Parent $PSScriptRoot))\Skills"
    }
    Write-Host "Sync-VendoredHelpers: CANNOT-EVALUATE - canonical Skills root not found (looked for $hint)" -ForegroundColor Yellow
    Write-Host 'Set CL_REPOS_ROOT, or run this script from a cl-common checkout that has a Skills/ sibling.' -ForegroundColor Yellow
    exit 2
}

$previous = Read-ManifestFile
$previousSnapshots = @{}
if ($previous) {
    foreach ($entry in @($previous.vendored)) {
        if ($entry.Kind -eq 'snapshot') { $previousSnapshots[$entry.Vendored] = [string]$entry.Sha256 }
    }
}

$copied = 0
$missingCanonical = 0
$newRows = [System.Collections.Generic.List[object]]::new()

# A declared exclusion is machine state, never content: skip it in the tree copy
# and say so, so a re-sync cannot quietly recreate the drifting file. A patched
# file is skipped for the same reason - its vendored bytes are the deliverable,
# a plain copy would silently revert the patch.
$copySkips = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($exclusion in $script:VendoredTreeExclusions) { $copySkips[$exclusion.Canonical] = $exclusion.Reason }
foreach ($patched in $script:PatchedFiles) { $copySkips[$patched.Canonical] = "patched vendored copy ($($patched.Patch)) - a re-sync never overwrites it" }

# trees
foreach ($tree in $script:VendoredTrees) {
    $canonicalFiles = @(Get-FilesUnder -Root $canonicalRoot -Relative $tree.Canonical)
    if ($canonicalFiles.Count -eq 0) {
        $missingCanonical++
        Write-Host "Sync-VendoredHelpers: canonical subtree not found or empty: $(Join-Path $canonicalRoot $tree.Canonical)" -ForegroundColor Red
        continue
    }

    foreach ($relative in $canonicalFiles) {
        if ($copySkips.ContainsKey($relative)) {
            Write-Output ('skip     {0}  ({1})' -f $relative, $copySkips[$relative])
            continue
        }
        $suffix = $relative.Substring($tree.Canonical.Length).TrimStart('/')
        $vendoredRelative = "$($tree.Vendored)/$suffix"
        $canonicalPath = Join-Path $canonicalRoot $relative
        $vendoredPath = Join-Path $packageFull $vendoredRelative
        $vendoredDir = Split-Path -Parent $vendoredPath

        if (-not (Test-Path -LiteralPath $vendoredDir -PathType Container)) {
            New-Item -ItemType Directory -Path $vendoredDir -Force | Out-Null
        }

        Copy-Item -LiteralPath $canonicalPath -Destination $vendoredPath -Force
        $length = (Get-Item -LiteralPath $vendoredPath).Length
        $copied++

        Write-Output ('{0}  {1} bytes' -f $vendoredRelative, $length)
        Write-Output ("  from {0}" -f $canonicalPath)
        Write-Output ("  to   {0}" -f $vendoredPath)

        $newRows.Add([pscustomobject]@{
            Kind      = 'copy'
            Name      = Split-Path -Leaf $relative
            Canonical = $relative
            Vendored  = $vendoredRelative
            Sha256    = (Get-Sha256 -Path $vendoredPath)
            Sha256Lf  = (Get-Sha256Normalized -Path $vendoredPath)
            Bytes     = $length
            Tree      = $tree.Canonical
        })
    }
}

# single files
foreach ($file in $script:VendoredFiles) {
    $canonicalPath = Join-Path $canonicalRoot $file.Canonical
    $vendoredPath = Join-Path $packageFull $file.Vendored
    $vendoredDir = Split-Path -Parent $vendoredPath

    if (-not (Test-Path -LiteralPath $canonicalPath -PathType Leaf)) {
        $missingCanonical++
        Write-Host "Sync-VendoredHelpers: canonical file not found: $canonicalPath" -ForegroundColor Red
        continue
    }

    if (-not (Test-Path -LiteralPath $vendoredDir -PathType Container)) {
        New-Item -ItemType Directory -Path $vendoredDir -Force | Out-Null
    }

    Copy-Item -LiteralPath $canonicalPath -Destination $vendoredPath -Force
    $length = (Get-Item -LiteralPath $vendoredPath).Length
    $copied++

    Write-Output ('{0}  {1} bytes' -f $file.Vendored, $length)
    Write-Output ("  from {0}" -f $canonicalPath)
    Write-Output ("  to   {0}" -f $vendoredPath)

    $newRows.Add([pscustomobject]@{
        Kind      = 'copy'
        Name      = Split-Path -Leaf $file.Canonical
        Canonical = $file.Canonical
        Vendored  = $file.Vendored
        Sha256    = (Get-Sha256 -Path $vendoredPath)
        Sha256Lf  = (Get-Sha256Normalized -Path $vendoredPath)
        Bytes     = $length
        Tree      = ''
    })
}

if ($missingCanonical -gt 0) {
    Write-Host "Sync-VendoredHelpers: $missingCanonical canonical path(s) missing - nothing was vendored for those rows" -ForegroundColor Red
    exit 1
}

# archived rows: provenance comes from the archive's own manifest, and the hash
# is measured from the archived file. A row is written only when the record and
# the bytes agree, so the archive cannot rot behind a passing manifest.
$archivedRows = [System.Collections.Generic.List[object]]::new()
if ($script:ArchivedFiles.Count -gt 0) {
    $archiveManifest = Resolve-ArchiveManifestPath
    $archiveSkillsRoot = Resolve-RepoSkillsRoot

    if (-not $archiveManifest -or -not $archiveSkillsRoot) {
        # The archive lives in the cl-common checkout that performed the move. A
        # copy installed anywhere else has no such tree, and refusing to re-sync
        # there would make the package unmaintainable from its own repository.
        # So the row is CARRIED FORWARD from the previous manifest: the vendored
        # body is re-hashed (a real edit is still caught) and the recorded
        # provenance is preserved, never re-invented and never silently dropped.
        $previousArchived = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($entry in @($previous.vendored)) {
            if ($entry.Kind -eq 'archived') { $previousArchived[[string]$entry.Vendored] = $entry }
        }

        Write-Host 'Sync-VendoredHelpers: archive tree not reachable from this copy - carrying recorded archived provenance forward.' -ForegroundColor Yellow

        foreach ($file in $script:ArchivedFiles) {
            $vendoredPath = Join-Path $packageFull $file.Vendored
            if (-not (Test-Path -LiteralPath $vendoredPath -PathType Leaf)) {
                Write-Host "Sync-VendoredHelpers: archived vendored file not found: $($file.Vendored)" -ForegroundColor Red
                $missingCanonical++
                continue
            }

            $recorded = $null
            if (-not $previousArchived.TryGetValue($file.Vendored, [ref]$recorded)) {
                Write-Host "Sync-VendoredHelpers: '$($file.Vendored)' is declared archived but the previous manifest has no archived row - provenance cannot be carried forward" -ForegroundColor Red
                $missingCanonical++
                continue
            }
            if ([string]::IsNullOrWhiteSpace([string]$recorded.Archived)) {
                Write-Host "Sync-VendoredHelpers: '$($file.Vendored)' previous archived row records no Archived path - provenance is unprovable" -ForegroundColor Red
                $missingCanonical++
                continue
            }

            $hash = Get-Sha256 -Path $vendoredPath
            $length = (Get-Item -LiteralPath $vendoredPath).Length
            Write-Output ('{0}  {1} bytes (archived from {2}; provenance carried forward)' -f $file.Vendored, $length, $file.Source)

            $archivedRows.Add([pscustomobject]@{
                Kind         = 'archived'
                Name         = Split-Path -Leaf $file.Source
                Canonical    = ''
                ArchivedFrom = [string]$recorded.ArchivedFrom
                Archived     = [string]$recorded.Archived
                Vendored     = $file.Vendored
                Sha256       = $hash
                Sha256Lf     = (Get-Sha256Normalized -Path $vendoredPath)
                Bytes        = $length
                Tree         = ''
                ArchivedAt   = [string]$recorded.ArchivedAt
                Phase        = [string]$recorded.Phase
                Why          = $file.Why
            })
        }
    }
    else {

    $archiveRows = @((Get-Content -LiteralPath $archiveManifest -Raw -Encoding utf8 | ConvertFrom-Json).rows)
    $archiveBySource = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($archiveRow in $archiveRows) {
        $archiveBySource[(ConvertTo-SkillsRelativePath -Path ([string]$archiveRow.source))] = $archiveRow
    }

    $declaredArchivedSources = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $declaredVendoredPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($row in $newRows) { [void]$declaredVendoredPaths.Add([string]$row.Vendored) }

    foreach ($file in $script:ArchivedFiles) {
        if (-not $declaredArchivedSources.Add($file.Source)) {
            Write-Host "Sync-VendoredHelpers: '$($file.Source)' is declared twice - one archived body gets one row" -ForegroundColor Red
            exit 1
        }
        if (-not $declaredVendoredPaths.Add($file.Vendored)) {
            Write-Host "Sync-VendoredHelpers: '$($file.Vendored)' already has a row - a vendored file cannot be both live and archived" -ForegroundColor Red
            exit 1
        }

        $archiveRow = $null
        if (-not $archiveBySource.TryGetValue($file.Source, [ref]$archiveRow)) {
            Write-Host "Sync-VendoredHelpers: '$($file.Source)' is declared archived but $archiveManifest has no row for it - the archive record is the owner; fix one of the two" -ForegroundColor Red
            exit 1
        }

        $archivedRelative = ConvertTo-SkillsRelativePath -Path ([string]$archiveRow.archived)
        $archivedPath = Join-Path $archiveSkillsRoot $archivedRelative
        if (-not (Test-Path -LiteralPath $archivedPath -PathType Leaf)) {
            Write-Host "Sync-VendoredHelpers: archived file not found: $archivedRelative (recorded in $archiveManifest)" -ForegroundColor Red
            exit 1
        }

        $archivedHash = Get-Sha256 -Path $archivedPath
        $recordedArchivedHash = ([string]$archiveRow.sha256).ToUpperInvariant()
        if ($archivedHash -ne $recordedArchivedHash -and (Get-Sha256Normalized -Path $archivedPath) -ne ([string]$archiveRow.sha256).ToUpperInvariant()) {
            Write-Host "Sync-VendoredHelpers: the archived bytes are not the body $archiveManifest records: $archivedRelative" -ForegroundColor Red
            Write-Host "  recorded=$($recordedArchivedHash.Substring(0, 12)) now=$($archivedHash.Substring(0, 12)) - restore the archived file, or move the row to wherever the body now lives" -ForegroundColor Red
            exit 1
        }

        $length = (Get-Item -LiteralPath $archivedPath).Length
        Write-Output ('{0}  {1} bytes (archived from {2})' -f $file.Vendored, $length, $file.Source)

        $archivedRows.Add([pscustomobject]@{
            Kind        = 'archived'
            Name        = Split-Path -Leaf $file.Source
            Canonical   = ''
            ArchivedFrom = $file.Source
            Archived    = $archivedRelative
            Vendored    = $file.Vendored
            Sha256      = $recordedArchivedHash
            Sha256Lf    = (Get-Sha256Normalized -Path $archivedPath)
            Bytes       = $length
            Tree        = ''
            ArchivedAt  = [string]$archiveRow.archivedAt
            Phase       = [string]$archiveRow.phase
            Why         = $file.Why
        })
    }
    }
}

# snapshots: hash what is on disk, but never re-record silently
$snapshotDrift = 0
foreach ($snapshot in $script:SnapshotFiles) {
    $vendoredPath = Join-Path $packageFull $snapshot.Vendored
    if (-not (Test-Path -LiteralPath $vendoredPath -PathType Leaf)) {
        $missingCanonical++
        Write-Host "Sync-VendoredHelpers: snapshot file not found: $($snapshot.Vendored)" -ForegroundColor Red
        continue
    }

    $hash = Get-Sha256 -Path $vendoredPath
    $length = (Get-Item -LiteralPath $vendoredPath).Length
    $previousHash = if ($previousSnapshots.ContainsKey($snapshot.Vendored)) { $previousSnapshots[$snapshot.Vendored] } else { '' }

    if ($previousHash -and $previousHash -ne $hash -and -not $UpdateSnapshots) {
        $snapshotDrift++
        Write-Host "Sync-VendoredHelpers: snapshot changed since it was recorded: $($snapshot.Vendored)" -ForegroundColor Red
        Write-Host "  recorded=$($previousHash.Substring(0, 12)) now=$($hash.Substring(0, 12)) - re-take it from $($snapshot.Owner), or pass -UpdateSnapshots if the edit is the new snapshot" -ForegroundColor Red
    }
    elseif ($previousHash -and $previousHash -ne $hash) {
        Write-Host "Sync-VendoredHelpers: SNAPSHOT RE-RECORDED $($snapshot.Vendored) ($($previousHash.Substring(0, 12)) -> $($hash.Substring(0, 12)))" -ForegroundColor Yellow
    }

    $newRows.Add([pscustomobject]@{
        Kind      = 'snapshot'
        Name      = Split-Path -Leaf $snapshot.Vendored
        Canonical = ''
        Vendored  = $snapshot.Vendored
        Sha256    = $hash
        Sha256Lf  = (Get-Sha256Normalized -Path $vendoredPath)
        Bytes     = $length
        Tree      = ''
    })
}

if ($missingCanonical -gt 0 -or $snapshotDrift -gt 0) {
    exit 1
}

# owned rows: the package IS the canonical owner, so there is nothing to copy.
# The row records the body's current hash; an edit that is not re-recorded shows
# up as a DRIFT on -Check, which is the only integrity claim an owned file can
# make. A missing file is a failure, never a silent drop.
$ownedRowCount = 0
foreach ($owned in $script:OwnedFiles) {
    $vendoredPath = Join-Path $packageFull $owned.Vendored
    if (-not (Test-Path -LiteralPath $vendoredPath -PathType Leaf)) {
        Write-Host "Sync-VendoredHelpers: owned file not found: $($owned.Vendored)" -ForegroundColor Red
        $missingCanonical++
        continue
    }

    $hash = Get-Sha256 -Path $vendoredPath
    $length = (Get-Item -LiteralPath $vendoredPath).Length
    Write-Output ('{0}  {1} bytes (owned in-package)' -f $owned.Vendored, $length)

    $newRows.Add([pscustomobject]@{
        Kind      = 'owned'
        Name      = Split-Path -Leaf $owned.Vendored
        Canonical = ''
        Vendored  = $owned.Vendored
        Owner     = 'this package'
        Why       = $owned.Why
        Sha256    = $hash
        Sha256Lf  = (Get-Sha256Normalized -Path $vendoredPath)
        Bytes     = $length
        Tree      = ''
    })
    $ownedRowCount++
}

foreach ($row in $archivedRows) { $newRows.Add($row) }

# patched rows: vendored bytes + the canonical source they were patched from.
# Both hashes are recorded, so the fork is proven and its upstream is watched.
foreach ($patched in $script:PatchedFiles) {
    $vendoredPath = Join-Path $packageFull $patched.Vendored
    $canonicalPath = Join-Path $canonicalRoot $patched.Canonical

    if (-not (Test-Path -LiteralPath $vendoredPath -PathType Leaf)) {
        Write-Host "Sync-VendoredHelpers: patched vendored file not found: $($patched.Vendored)" -ForegroundColor Red
        $missingCanonical++
        continue
    }
    if (-not (Test-Path -LiteralPath $canonicalPath -PathType Leaf)) {
        Write-Host "Sync-VendoredHelpers: patched row's canonical source not found: $($patched.Canonical)" -ForegroundColor Red
        $missingCanonical++
        continue
    }

    $vendoredHash = Get-Sha256 -Path $vendoredPath
    $canonicalHash = Get-Sha256 -Path $canonicalPath
    if ($vendoredHash -eq $canonicalHash) {
        Write-Host "Sync-VendoredHelpers: '$($patched.Vendored)' is byte-identical to its canonical source - the patch is gone; re-apply it ($($patched.Patch)) or delete the patched row" -ForegroundColor Red
        $missingCanonical++
        continue
    }

    # A patched body is only a patch of the canonical revision it was taken from.
    # Recording a NEW canonical hash against an OLD patched body would make -Check
    # report MATCH while the patch silently skipped an upstream change - a false
    # green on the one row the manifest deliberately forks. So a moved canonical
    # stops the sync: re-apply the patch to the new source, then re-run.
    $previousPatched = $null
    foreach ($entry in @($previous.vendored)) {
        if ($entry.Kind -eq 'patched' -and [string]$entry.Vendored -eq $patched.Vendored) { $previousPatched = $entry }
    }
    if ($previousPatched) {
        $recordedCanonical = [string]$previousPatched.CanonicalSha256
        $recordedCanonicalLf = [string]$previousPatched.CanonicalSha256Lf
        $canonicalMoved = $recordedCanonical -and
            $canonicalHash -ne $recordedCanonical -and
            (-not $recordedCanonicalLf -or (Get-Sha256Normalized -Path $canonicalPath) -ne $recordedCanonicalLf)
        if ($canonicalMoved) {
            if (-not $AcceptCanonicalMove) {
                Write-Host "Sync-VendoredHelpers: '$($patched.Vendored)' canonical source moved since the patch was recorded" -ForegroundColor Red
                Write-Host "  recorded=$($recordedCanonical.Substring(0, 12)) now=$($canonicalHash.Substring(0, 12)) - copy the new canonical, re-apply patch '$($patched.Patch)', then re-run with -AcceptCanonicalMove" -ForegroundColor Red
                $missingCanonical++
                continue
            }
            Write-Host "Sync-VendoredHelpers: accepting the moved canonical for '$($patched.Vendored)' (patch '$($patched.Patch)' re-applied): $($recordedCanonical.Substring(0, 12)) -> $($canonicalHash.Substring(0, 12))" -ForegroundColor Yellow
        }
    }

    $length = (Get-Item -LiteralPath $vendoredPath).Length
    $copied++

    Write-Output ('{0}  {1} bytes (patched: {2})' -f $patched.Vendored, $length, $patched.Patch)
    Write-Output ("  from {0}" -f $canonicalPath)
    Write-Output ("  to   {0}" -f $vendoredPath)

    $newRows.Add([pscustomobject]@{
        Kind             = 'patched'
        Name             = Split-Path -Leaf $patched.Canonical
        Canonical        = $patched.Canonical
        Vendored         = $patched.Vendored
        Patch            = $patched.Patch
        Why              = $patched.Why
        Sha256           = $vendoredHash
        Sha256Lf         = Get-Sha256Normalized -Path $vendoredPath
        CanonicalSha256  = $canonicalHash
        CanonicalSha256Lf = Get-Sha256Normalized -Path $canonicalPath
        Bytes            = $length
        Tree             = ''
    })
}

if ($missingCanonical -gt 0) {
    Write-Host "Sync-VendoredHelpers: $missingCanonical row(s) could not be recorded - the manifest was NOT written" -ForegroundColor Red
    exit 1
}

$document = [pscustomobject]@{
    schemaVersion = 2
    generatedAt   = (Get-Date).ToString('o')
    # Repo-derived runs record the portable name so the committed manifest does not
    # point at whichever worktree generated it; a fleet run records the absolute
    # root it actually read. Nothing resolves from this field - it is provenance.
    # The committed manifest is SHIPPED, so it records only the portable name. A
    # fleet run used to write the absolute root it read, which made the artifact
    # machine-specific and tripped the publish gate. Which tree produced a sync is
    # a fact about the run, not about the package: it is printed by this script and
    # belongs in the commit message, never in a shipped file.
    canonicalRoot = 'Skills'
    trees         = @($script:VendoredTrees | ForEach-Object { [pscustomobject]@{ canonicalRoot = $_.Canonical; vendoredRoot = $_.Vendored } })
    vendored      = @($newRows | Sort-Object Vendored)
    # The two decision lists belong in the ARTIFACT, not only in this script.
    # MANIFEST.md tells a consumer the not-vendored and residual choices are
    # recorded with a reason; a written manifest that carries only `vendored` makes
    # that promise true of the tool and false of the file. The gate reads
    # -ListManifest and never noticed the omission.
    notVendored   = @($script:NotVendoredHelpers)
    residuals     = @($script:Residuals)
}

$manifestDir = Split-Path -Parent $manifestPath
if (-not (Test-Path -LiteralPath $manifestDir -PathType Container)) {
    New-Item -ItemType Directory -Path $manifestDir -Force | Out-Null
}

$document | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifestPath -Encoding utf8 -NoNewline

$copyRows = @($newRows | Where-Object { $_.Kind -eq 'copy' }).Count
$ownedRows = @($newRows | Where-Object { $_.Kind -eq 'owned' }).Count
$snapshotRows = @($newRows | Where-Object { $_.Kind -eq 'snapshot' }).Count
$archivedRowCount = @($newRows | Where-Object { $_.Kind -eq 'archived' }).Count
$patchedRowCount = @($newRows | Where-Object { $_.Kind -eq 'patched' }).Count
Write-Host "Sync-VendoredHelpers: $copied file(s) synced from $canonicalRoot; manifest written with $copyRows copy row(s), $ownedRows owned row(s), $patchedRowCount patched row(s), $snapshotRows snapshot row(s) and $archivedRowCount archived row(s) -> $manifestPath" -ForegroundColor Green
exit 0
