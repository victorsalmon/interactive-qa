# Adapters

Three independent axes. A deployment picks one value per axis; the combination
is its **profile** ([PROFILE.template.md](PROFILE.template.md)). Members read the
profile, never assume a value, and never branch on a value that is missing —
a missing slot is `cannot-evaluate` (Invariant 2), not a default.

The axes are independent: any executor can run against any provider pool, on any
repo profile. Do not collapse them into a single "mode" name.

## Axis 1 — executor: `paseo` | `generic`

*How a worker is spawned, supervised and observed.*

| Slot | `paseo` | `generic` |
| :--- | :--- | :--- |
| Spawn | Detached background child agent with a durable brief; survives the parent turn. | Whatever the environment offers — CI job, container, separate terminal. |
| Parent linkage | Explicit parent identity carried in the brief, not assumed from the environment. | Recorded in the brief's header and in the log line that starts the worker. |
| Completion signal | A completion ping to the parent id named in the brief. | Polled exit state plus the worker's own written report artefact. |
| Observation | Agent status and timeline reads. | The worker's log file is the only truth. |

Rules that hold on **both** executors: dispatch is detached by default; a worker
is briefed durably (the brief is the contract, chat is not); the parent never
blocks waiting on a worker; and a worker that cannot report is treated as failed,
not as still running.

`paseo` specifics — spawn flags, the parent-id rule, the fallback when a worker
drops out of the parent's child list — stay in `Skills/paseo-child-agents/`.

## Axis 2 — provider pool: `pool` | `single key`

*What supplies model capacity, and therefore what "exhausted" means.*

| Slot | `pool` | `single key` |
| :--- | :--- | :--- |
| Capacity source | Several keys with per-key caps, ordered as a pool. | One key with one cap. |
| Exhaustion | Per-key: the pool routes around a spent key. Whole-pool exhaustion is a separate, rarer state. | Whole-system: the next call fails. |
| Routing | Route by work role and effort, with a defined order of preference. | No routing decision exists; there is one destination. |
| Recovery | Cut over to a proven replacement key, then resume the interrupted workers. | Rotate the key, then resume. Same seam, fewer moving parts. |
| Who notices | [members/key-watch/SKILL.md](../members/key-watch/SKILL.md) canaries on a cadence and cuts over before the cap. | The first failure. Watch `key-watch` still applies, on a shorter cadence. |

Never print key material on either value — Invariant 6. Per-key caps, cooldowns
and the route-and-effort matrix stay in `Skills/agent-spawn-capacity/`; the
cutover seam, its scripts and its runbooks are vendored at
`<package>/vendor/credential-rescue/`, with the fleet tree as a development
override. The seam's *machine* copy is a profile value (`seam_path`): a write
names it, a read may use the in-package snapshot.

The **provider lock** (`Invoke-ProviderLock.ps1`) is machine state by design: it
records fingerprints of *this* machine's credentials, so it resolves its lock
file outside the package at `$env:MACHINE_STATE_HOME/credential-rescue/provider-lock.json`
(or `~/.machine/state/credential-rescue/provider-lock.json`; `-StateRoot` or
`$env:PROVIDER_LOCK_STATE_ROOT` overrides the directory), with a read-only
fallback to a legacy in-tree copy. `-Mode Lock` always writes
the state root and seeds it from the legacy copy on the first run. A machine with
neither file is `cannot-evaluate`: the provider definitions (source secret and
field, consumer targets) are deployment configuration and cannot be invented -
seed the state root once from the deployment's lock asset. The package therefore
ships no `provider-lock.json` (declared not-vendored in the manifest), and the
vendored resolver is a **patched** row: its canonical owner still defaults in
tree until that tool is retired.

## Axis 3 — repo profile

*Where the work physically happens: trunks, gates, deploy, secrets and logging.*

A repo profile is one filled-in [PROFILE.template.md](PROFILE.template.md). It
answers, for one repository: which trunk integrates, which branches are
permanent, what command proves the change, what command proves a landing, how a
deploy is verified, which secret profile to use, and where session logs live.

Rules:

- **One profile per repository.** A branch is not a profile; a session is not a
  profile.
- **Values are verified, not guessed.** A profile that instructs a test command
  nobody has run is a defect (Invariant 2). Where a repo has no value for a slot,
  the profile says `none` with the reason — never a plausible-looking guess,
  because a wrong secret profile looks exactly like a provisioning failure.
- **A profile never states a rule.** It resolves a slot in a rule owned by a
  member or by the core. If a profile needs prose, the prose belongs in
  [INVARIANTS](INVARIANTS.md) or the member, and the profile links to it.

## External adapters

A member sometimes needs a capability or a document whose owner lives
**outside** this package. The member cites the adapter name; the location is a
deployment value the profile supplies, never a path written into the member.
A member that hard-codes an outside path - or links to a file that only exists
while a sibling tree sits beside the package - stops resolving the moment the
package is installed on its own. That is a false green, not a packaging detail
(Invariant 2).

Two shapes:

- **Helper adapter** - an executable. Resolved from the profile's `scripts_root`,
  which defaults to the **in-package** `<package>/vendor` (see
  `## Vendored helpers (in-package)` below).
- **Reference adapter** - a document. Resolved from the profile's `skills_root`.

Every adapter states what it provides, how it resolves, and what a member does
when the value is missing. Absent is always `cannot-evaluate` with a reason -
never a default, never a re-derived copy.

The resolution rule for helper adapters, in one place:

> `scripts_root` defaults to `<package>/vendor` (in-package); the fleet path is a
> development override only; drift is caught by
> `tools/Sync-VendoredHelpers.ps1 -Check`; a missing vendored helper is a
> tool-gate failure, not a waiver.

An adapter whose owner genuinely sits outside the package keeps the **fleet**
path as its value - the repo being worked, a product repo's scripts, the
orchestrator's tools. That is a profile *value*, not a package dependency, and no
member may treat it as a requirement. The Key Watch / Key Cutover machinery is
**not** in that class any more: it is vendored (see
`## Vendored helpers (in-package)`), and the fleet tree is only its development
override.

### `landing_test` (helper)

| | |
| :--- | :--- |
| Provides | The merge landing proof: fresh fetch, the SHA is an ancestor of `origin/<trunk>`, the claimed paths exist in the remote tree; exit 0, or there is no landing. |
| Resolved from | `Test-Landed.ps1` under the profile's `scripts_root`, whose default is the in-package [vendor/iqa-merge/Test-Landed.ps1](../vendor/iqa-merge/Test-Landed.ps1) (vendored - see `## Vendored helpers (in-package)`). The fleet path `$env:CL_REPOS_ROOT\cl-common\Skills\iqa-merge` is a **development override only**, never the required location. |
| When absent | `cannot-evaluate`. The row is never marked `merged` and the merge bead stays open - a landing nobody tested is an unproven landing. |

### `rung_cadence` (helper)

| | |
| :--- | :--- |
| Provides | Session state -> required gear -> the cron that realizes it -> the `Rung:` line that proves the wake-up exists. |
| Resolved from | `Get-HubCadence.ps1` under the profile's `scripts_root`, whose default is the in-package [vendor/iqa-merge/Get-HubCadence.ps1](../vendor/iqa-merge/Get-HubCadence.ps1) (vendored - see `## Vendored helpers (in-package)`). The fleet path `$env:CL_REPOS_ROOT\cl-common\Skills\iqa-merge` is a **development override only**, never the required location. |
| When absent | `cannot-evaluate` (Invariant 2). The member prints `Rung: cannot-evaluate (<reason>)` and reports the turn incomplete. No inferred cadence, no default gear, no fallback: a guessed rung is a false receipt, and a rung the deployment cannot create must stay visible rather than be fabricated. |

State names, cadence values and the pinned helper tests stay with the helper;
this package states only the contract above.

### `provider_log` (reference)

| | |
| :--- | :--- |
| Provides | The harness/provider log a member reads for usage-limit and auth evidence (`Go usage limit exceeded`, `Weekly usage limit reached. Resets in N days`, `rate_limit_exceeded`). |
| Resolved from | The profile's `provider_log` value: one log file path for the deployment. It is a deployment value, never a path written into a member - the harness decides where it writes, and a different executor writes somewhere else. |
| When absent | `cannot-evaluate`. The member does not guess a log location and does not substitute a sibling product's log: it says the log is unconfigured and continues with the evidence it actually has (a canary result, a live error). |

### `beads_skill` (reference)

| | |
| :--- | :--- |
| Provides | The bead graph the session writes to: id shape, edge types, ready/claim rules, and - in a SaaS repo - the deployment's IQA slots and merge slots. |
| Resolved from | The profile's `skills_root`; the fleet deployment value is `iqa-beads` for the bead deltas and `iqa-beads-saas` for the SaaS slots. |
| When absent | `cannot-evaluate`. No bead is minted, claimed or closed from a guessed schema, and the session reports the gap instead of inventing ids. |

### `on_ramp` (reference)

| | |
| :--- | :--- |
| Provides | The ordered on-ramp a Hub reads top to bottom before its first tool call: the start receipts, the first tick, the dispatch contract, the merge-and-prove path, and the traps already paid for. |
| Resolved from | The profile's `skills_root`. The fleet deployment value is `$env:CL_REPOS_ROOT\cl-common\Skills\iqa-merge\ENROLMENT.md`; an installed package supplies its own value through the profile, and this path is that **deployment value**, never a requirement to sit beside the package. |
| When absent | `cannot-evaluate`. The role is not assumed and the drain does not start: report the missing on-ramp rather than on-ramp yourself from memory. |

## Vendored helpers (in-package)

`scripts_root` resolves to **`<package>/vendor`** by default. The fleet path
(`$env:CL_REPOS_ROOT\cl-common\Skills\iqa-merge`) is a **development override**
supplied by a profile, never a requirement: a session must be able to start a Hub
with no `Skills/` tree anywhere in its resolved surface. The **vendored copies are
the deployment truth**; the fleet path is where they were taken from.

| Helper | Vendored at | Canonical owner |
| :--- | :--- | :--- |
| `Test-Landed.ps1` | [vendor/iqa-merge/Test-Landed.ps1](../vendor/iqa-merge/Test-Landed.ps1) | `Skills/iqa-merge/Test-Landed.ps1` |
| `Get-HubCadence.ps1` | [vendor/iqa-merge/Get-HubCadence.ps1](../vendor/iqa-merge/Get-HubCadence.ps1) | `Skills/iqa-merge/Get-HubCadence.ps1` |
| `HubRegistry.ps1` | [vendor/iqa-merge/HubRegistry.ps1](../vendor/iqa-merge/HubRegistry.ps1) | `Skills/iqa-merge/HubRegistry.ps1` |
| `Invoke-HubProbe.ps1` | [vendor/iqa-merge/Invoke-HubProbe.ps1](../vendor/iqa-merge/Invoke-HubProbe.ps1) | `Skills/iqa-merge/Invoke-HubProbe.ps1` |
| `Invoke-WorktreeLease.ps1` | [vendor/git-operations/Invoke-WorktreeLease.ps1](../vendor/git-operations/Invoke-WorktreeLease.ps1) | `Skills/git-operations/Invoke-WorktreeLease.ps1` |
| The **Key family** (cutover, watch, Key Check, provider lock, `~/.aws` restore, plus `scripts/lib/`, `skills/*`, `assets/`, `Tests/`) | [vendor/credential-rescue/](../vendor/credential-rescue) | `Skills/credential-rescue/**` (60 files) |
| The **dispatch closure** (`run-iqa-worker.ps1`, `Test-OpencodeProvider.ps1`, `no-approvals.json`) | [vendor/dispatch/](../vendor/dispatch) | `Skills/iqa-mode/scripts/**`, `Skills/iqa-mode/assets/no-approvals.json` |
| The **capacity gate** (`AgentCapacity.ps1`, `AgentCapacity.Registry.ps1`, `agent-capacity.json`) | [vendor/agent-spawn-capacity/](../vendor/agent-spawn-capacity) | `Skills/agent-spawn-capacity/scripts/**`, `assets/agent-capacity.json` |
| The **done-file contract** (`iqa-done.schema.json`, `validate-done.mjs`) and `lane-watch.mjs` | [vendor/paseo-child-agents/](../vendor/paseo-child-agents) | `Skills/paseo-child-agents/**` |

**One owner.** [tools/Sync-VendoredHelpers.ps1](../tools/Sync-VendoredHelpers.ps1)
holds the canonical -> vendored table (subtree rows and single-file rows) in the
generated manifest
[tools/vendored-helpers.manifest.json](../tools/vendored-helpers.manifest.json),
holds the reasoned list of helpers deliberately *not* vendored and the declared
residuals, and is the only writer of `vendor/`. Run it with no
argument to re-copy after a canonical change; run it with `-Check` to compare
hashes without writing (recorded hashes always, canonical files too when the
Skills tree is reachable):

```
pwsh -NoProfile -File interactive-qa/tools/Sync-VendoredHelpers.ps1 -Check
```

Drift — a canonical helper that changed while the vendored copy did not — is
caught by that `-Check`, and
[tools/Test-VendoredHelpers.ps1](../tools/Test-VendoredHelpers.ps1) is the gate
that fails on it:

- every manifest row is present, every file under `vendor/` and
  `references/vendored/` is a row (no orphan copies), and one canonical file has
  exactly one vendored copy (a second copy is a second place to drift, and only
  one of them can be proven);
- every vendored file parses, so a truncated copy cannot ride a hash claim;
- `-Check` exits 0 (a `-Check` that cannot evaluate is a **failure**, never a
  waiver);
- every `<name>.ps1` token the package's Markdown names is vendored, one of the
  package's own `tools/`, or excused in the manifest with a reason. An
  undocumented helper reference fails the gate — that is what stops this package
  growing the same out-of-package dependency a second time.

Rules:

- A **missing helper** is `cannot-evaluate` for the session: report it and print
  nothing invented (Invariant 2). The **tool** gate is stricter — a missing
  vendored helper is a **failure**, not a waiver, because absence is exactly the
  defect the vendoring exists to make impossible.
- Vendored files are **byte-identical**; never edit one in place. Change the
  canonical helper, re-run the sync, commit both sides.
- `Invoke-HubProbe.ps1` still composes commands for *other* skills' helpers by
  design (`Invoke-SafeCommit.ps1`, `Invoke-TrunkPrep.ps1`,
  `Invoke-BranchWorktreeHygiene.ps1`), resolved from the fleet
  root. Its fallback when `CL_REPOS_ROOT` is unset is derived from the script's own
  location - right for the canonical copy under `Skills/iqa-merge`, one level off
  for a package copy under `<package>/vendor`. The part **statuses** come from
  repo-local git state and stay valid; a printed command is only meaningful when
  the development override is set. Never run one whose helper path does not exist.
  This is the development-override seam, not part of the Hub-start contract.
- The **merge queue** is not one of those helpers: it ships here as
  `tools/Invoke-IqaQueue.ps1`, because parking a branch is the Sub's core promise
  and must not depend on a checkout of another product repo. Its row format is
  identical to the fleet's `merge-queue.mjs`, so either tool reads either queue.
