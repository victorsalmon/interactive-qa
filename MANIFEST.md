# Publish manifest

Version **1.0.0**. What ships, what does not, and why. The machine-readable copy
is [tools/publish-manifest.json](tools/publish-manifest.json); the publish gate
[tools/Test-PackagePaths.ps1](tools/Test-PackagePaths.ps1) reads it, so this
decision is enforced rather than described.

## Ships

| Path | Why |
| :--- | :--- |
| `SKILL.md` | The front door. It is the only entry point and it routes to one member. |
| `core/` | The normative contracts every member reads: invariants, task model, adapters, profile template. |
| `lib/` | The resolvers the tools share: cl-common presence and the machine's primary-repo registry. |
| `members/` | The seven members. Each is a thin shell around the core. |
| `profiles/` | A worked repo profile. It resolves slots; it states no rule. |
| `references/` | The vendored procedure and contract excerpts the members cite. |
| `tools/` | The gates, the merge queue, the monitor, the manifest and their tests. Shipping them lets a consumer re-prove the package instead of trusting it. |
| `vendor/` | Every executable a member prescribes, byte-identical to its canonical source. This is what makes a cold start possible. |
| `README.md` | Install, use, verify. |
| `MANIFEST.md` | This decision. |
| `LICENSE` | MIT. |

## Does not ship

| Path | Why |
| :--- | :--- |
| `gate/` | Dated per-lane gate evidence: run transcripts, machine paths and the defects of a past lane. It is history for the repository that built the package, not content for an installed one. Publishing it would ship internal paths and stale proof. It stays in the repository. |
| `PHASE0-INVENTORY.md` | The Phase-0 census of the fleet tree (counts, derivation commands, migration inventory). It describes a tree an installer does not have. |

Both exclusions are reported by the publish gate on every run, so "not shipped"
is visible rather than silent.

## Vendored row kinds

The machine-readable manifest is
[tools/vendored-helpers.manifest.json](tools/vendored-helpers.manifest.json) and
every row is one of five kinds, each with its own proof:

| Kind | Proof |
| :--- | :--- |
| `copy` | byte-identical to its canonical file in the fleet Skills tree |
| `patched` | deliberately divergent; **both** hashes recorded, and a moved canonical is a DRIFT |
| `snapshot` | a composite excerpt; hash proves the snapshot file itself was not edited |
| `archived` | the canonical source was retired; hash proves the body, and the archive manifest carries provenance |
| `owned` | **this package is the canonical owner**; the recorded hash is the whole check, so an unre-recorded edit is a DRIFT |

`owned` exists because the IQA family (`iqa-merge/*`, `iqa-mode/*`) was retired out
of the fleet tree at Phase 5. Rows that still named a source there could only ever
report `MISSING`, and no re-sync could make them pass; ownership is a fact about
where the body lives, so the manifest records it instead of pretending an upstream
still exists.

## Absolute paths

No shipped file may name a machine path. Two owned hits were removed in Phase 6
(a provider log path became the `provider_log` adapter; a provenance table became
repo-relative). What remains is declared, per file, in
`tools/publish-manifest.json` -> `pathAllowlist`, with a class and a reason:
vendored documentation of this box's machine facts, a machine default that takes
a parameter, or a test fixture. An undeclared hit fails the gate, and so does a
justification whose file no longer has one.

## Runtime state (never package content)

- **Provider lock** - `provider-lock.json` is machine state written by
  `Invoke-ProviderLock.ps1 -Mode Lock`. It is declared **not vendored**: the tool
  resolves it at the profile state root
  (`$env:USERPROFILE/.machine/state/credential-rescue/provider-lock.json`, or
  `-StateRoot`), with a read-only legacy fallback to the old in-tree copy.
- **Cutover seam** - `vendor/credential-rescue/assets/opencode-go-cutover.json` is
  a *projection* of the machine's seam record, kept in the package because the Key
  members must be able to read a seam on a machine with no fleet checkout. It is
  **config only** (activeKey, poolOrder, caps, canary, hygiene, metering windows):
  the per-key freshness OBSERVATIONS are runtime state written on every watch
  cycle, so they live at the seam's `observationsPath` in the profile state root
  (`$env:USERPROFILE/.machine/state/credential-rescue/seam-observations.json`) and
  never in this file. That split keeps the vendored row stable between commits: a
  Key Watch write changes no tracked file and cannot redden `-Check`. A deliberate
  config change (an operator cutover) still makes `-Check` report DRIFT until the
  package is re-synced - that DRIFT is a true signal and is deliberately not
  silenced.

## Gates that prove the artifact

```
pwsh -NoProfile -File tools/Test-PluginLinks.ps1              # links resolve and stay inside the package
pwsh -NoProfile -File tools/Sync-VendoredHelpers.ps1 -Check   # vendored files match their recorded/canonical hashes
pwsh -NoProfile -File tools/Test-VendoredHelpers.ps1          # no orphans, no unexcused helper, patches carry both hashes
pwsh -NoProfile -File tools/Test-PackagePaths.ps1             # no unexplained absolute path in a shipped file
```

The first three also pass from a copy of the package anywhere on disk, with no
`Skills/` tree beside it and `CL_REPOS_ROOT` unset; the fourth reads its own
manifest and needs nothing outside the copy either.
