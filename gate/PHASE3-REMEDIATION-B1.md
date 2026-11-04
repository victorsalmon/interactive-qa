# Phase 3 gate remediation — lane B1: vendor the Hub helpers (D1, D2)

Bead `cl-common-1v5`. Branch `fix/iqa-gate-b1`, based on `dev` at `29e4d6e7`.
Source of truth for the defects: `gate/PHASE3-GATE-EVIDENCE.md` §3 entries **D1**
and **D2** in the gate lane's worktree (a read-only gate session that used this
package alone against `upscale-havens`).

The verdict was PARTIAL, not PASS, because the package prescribed capabilities it
did not ship:

- **D1** — the Hub-start helpers (`HubRegistry.ps1`, `Get-HubCadence.ps1`,
  `Test-Landed.ps1`, `Invoke-HubProbe.ps1`) and the worktree lease lived only in
  `Skills/iqa-merge` / `Skills/git-operations`, which the gate's isolation
  deliberately excludes. The five-receipt Hub-start contract could not be
  completed from inside the package.
- **D2** — the one prescribed per-turn report line needs `Get-HubCadence.ps1`,
  which the package did not ship, so the gate had to run an out-of-package copy to
  print `Rung:`.

Fix: **vendor them now**, not in Phase 6. Absence must be impossible, not merely
honest.

## 1. What changed

| File | Status | Lines | Purpose |
| :--- | :--- | ---: | :--- |
| `scripts/Get-HubCadence.ps1` | added (vendored, byte-identical) | 229 | the `Rung:` line (D2) |
| `scripts/HubRegistry.ps1` | added (vendored, byte-identical) | 894 | Hub register / find / list (D1) |
| `scripts/Invoke-HubProbe.ps1` | added (vendored, byte-identical) | 501 | Hub start probe (D1) |
| `scripts/Test-Landed.ps1` | added (vendored, byte-identical) | 132 | landing proof against the remote (D1) |
| `scripts/Invoke-WorktreeLease.ps1` | added (vendored, byte-identical) | 389 | worktree lease, receipt 1 of 5 (D1) |
| [tools/Sync-VendoredHelpers.ps1](../tools/Sync-VendoredHelpers.ps1) | added | 329 | single owner of the mapping; only writer of `scripts/` |
| [tools/Test-VendoredHelpers.ps1](../tools/Test-VendoredHelpers.ps1) | added | 255 | the gate that must stay green |
| [tools/Test-VendoredHelpers.Tests.ps1](../tools/Test-VendoredHelpers.Tests.ps1) | added | 108 | planted-defect proof of that gate (5 cases) |
| [core/ADAPTERS.md](../core/ADAPTERS.md) | appended only (65 -> 124 lines) | +59 | `## Vendored helpers (in-package)` contract |

Nothing else was edited: no `Skills/` change, no member prose change, no other
worktree touched.

## 2. The vendored set and its provenance

| Vendored | Canonical source | sha256 (12) | bytes |
| :--- | :--- | :--- | ---: |
| `Get-HubCadence.ps1` | `Skills/iqa-merge/Get-HubCadence.ps1` | `F69467F2375F` | 8706 |
| `HubRegistry.ps1` | `Skills/iqa-merge/HubRegistry.ps1` | `2F32F5D254CB` | 43413 |
| `Invoke-HubProbe.ps1` | `Skills/iqa-merge/Invoke-HubProbe.ps1` | `5039678B98D7` | 23298 |
| `Test-Landed.ps1` | `Skills/iqa-merge/Test-Landed.ps1` | `55DE023AB045` | 5386 |
| `Invoke-WorktreeLease.ps1` | `Skills/git-operations/Invoke-WorktreeLease.ps1` | `A210F61C6C43` | 16104 |

A copy, not a rewrite: each file keeps its own `#Requires -Version 7` header and
help block. Verified before vendoring that all five are standalone — no
dot-sourcing, no `Import-Module`.

**No vendored file was diverged from its canonical source.** The one hidden path
assumption found (`Invoke-HubProbe.ps1`'s fleet-root fallback, §6) is recorded
rather than patched, because a byte-divergent copy would make `-Check` permanently
red and destroy the only cheap proof that the copy is the shipped semantics.

## 3. Commands and their output

### 3.1 Vendoring (default mode)

```
pwsh -NoProfile -File interactive-qa-agent\tools\Sync-VendoredHelpers.ps1
```

```
Get-HubCadence.ps1  8706 bytes
  from E:\Repos\cl-common\Skills\iqa-merge\Get-HubCadence.ps1
  to   E:\Repos\cl-common\.worktrees\lane-gate-fix-b1\interactive-qa-agent\scripts\Get-HubCadence.ps1
HubRegistry.ps1  43413 bytes
  from E:\Repos\cl-common\Skills\iqa-merge\HubRegistry.ps1
  to   E:\Repos\cl-common\.worktrees\lane-gate-fix-b1\interactive-qa-agent\scripts\HubRegistry.ps1
Invoke-HubProbe.ps1  23298 bytes
  from E:\Repos\cl-common\Skills\iqa-merge\Invoke-HubProbe.ps1
  to   E:\Repos\cl-common\.worktrees\lane-gate-fix-b1\interactive-qa-agent\scripts\Invoke-HubProbe.ps1
Test-Landed.ps1  5386 bytes
  from E:\Repos\cl-common\Skills\iqa-merge\Test-Landed.ps1
  to   E:\Repos\cl-common\.worktrees\lane-gate-fix-b1\interactive-qa-agent\scripts\Test-Landed.ps1
Invoke-WorktreeLease.ps1  16104 bytes
  from E:\Repos\cl-common\Skills\git-operations\Invoke-WorktreeLease.ps1
  to   E:\Repos\cl-common\.worktrees\lane-gate-fix-b1\interactive-qa-agent\scripts\Invoke-WorktreeLease.ps1
Sync-VendoredHelpers: 5 helper(s) synced from E:\Repos\cl-common\Skills into ...
```

Canonical root resolution: `CL_REPOS_ROOT` was set, so the source was
`$env:CL_REPOS_ROOT\cl-common\Skills`. Checked independently that the same five
files are byte-identical between the fleet checkout (`E:\repos\cl-common\Skills`,
at `29e4d6e7`) and this lane's worktree, so both resolution rules agree today.

### 3.2 Drift check (`-Check`, no writes)

```
pwsh -NoProfile -File interactive-qa-agent\tools\Sync-VendoredHelpers.ps1 -Check
```

```
MATCH    Get-HubCadence.ps1         sha256 F69467F2375F canonical=8706 vendored=8706
MATCH    HubRegistry.ps1            sha256 2F32F5D254CB canonical=43413 vendored=43413
MATCH    Invoke-HubProbe.ps1        sha256 5039678B98D7 canonical=23298 vendored=23298
MATCH    Test-Landed.ps1            sha256 55DE023AB045 canonical=5386 vendored=5386
MATCH    Invoke-WorktreeLease.ps1   sha256 A210F61C6C43 canonical=16104 vendored=16104
Sync-VendoredHelpers -Check: MATCH - 5 vendored helper(s) identical to E:\Repos\cl-common\Skills
```

### 3.3 The package gates, in the repo

```
pwsh -NoProfile -File interactive-qa-agent\tools\Test-PluginLinks.ps1
```
```
Test-PluginLinks: OK - 126 relative link(s) resolved across 16 file(s) under ...\interactive-qa-agent
```

```
pwsh -NoProfile -File interactive-qa-agent\tools\Test-VendoredHelpers.ps1
```
```
--- Sync-VendoredHelpers.ps1 -Check
MATCH    Get-HubCadence.ps1         sha256 F69467F2375F canonical=8706 vendored=8706
MATCH    HubRegistry.ps1            sha256 2F32F5D254CB canonical=43413 vendored=43413
MATCH    Invoke-HubProbe.ps1        sha256 5039678B98D7 canonical=23298 vendored=23298
MATCH    Test-Landed.ps1            sha256 55DE023AB045 canonical=5386 vendored=5386
MATCH    Invoke-WorktreeLease.ps1   sha256 A210F61C6C43 canonical=16104 vendored=16104
Sync-VendoredHelpers -Check: MATCH - 5 vendored helper(s) identical to E:\Repos\cl-common\Skills
Test-VendoredHelpers: OK - 5 vendored helper(s) present, covered and byte-identical; 0 orphan(s); 58 helper name(s) in 16 markdown file(s) resolved (5 in scripts/, 5 in tools/, 48 deliberately not vendored, 1 of those a stale reference)
```

Proof the gate can fail — five planted defects, each asserted on the gate's exit
code as a child process:

```
pwsh -NoProfile -File interactive-qa-agent\tools\Test-VendoredHelpers.Tests.ps1
```
```
[+] ...\Test-VendoredHelpers.Tests.ps1  20.48s (5 tests)
Tests Passed: 5, Failed: 0, Skipped: 0, Inconclusive: 0, NotRun: 0
```

Cases: a clean copy exits 0; an orphan `scripts/*.ps1` fails and is named; a
manifest row with no file fails and is named; a byte of drift fails and is named;
a member naming an unshipped, unexcused helper fails and is named.

## 4. Isolation proof, run literally

The package was copied **out of the repository** and exercised there:

```powershell
$dst = Join-Path $env:TEMP ('iqa-pkg-isolation-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
Copy-Item -Recurse E:\repos\cl-common\.worktrees\lane-gate-fix-b1\interactive-qa-agent $dst
pwsh -NoProfile -File "$dst\tools\Test-PluginLinks.ps1"
pwsh -NoProfile -File "$dst\tools\Test-VendoredHelpers.ps1"
pwsh -NoProfile -File "$dst\scripts\Get-HubCadence.ps1" -State dispatched -Name smoke -Json
```

Copy: `C:\Users\RDP\AppData\Local\Temp\iqa-pkg-isolation-20261103-011222`,
27 files, outside `E:\repos`.

**1. `tools/Test-PluginLinks.ps1` — exit 1, 10 dead links.** Unchanged from the
gate's own finding **D10** (dead `../../../Skills/...` links in `members/**`).
This lane did not touch member prose, so the number is identical to the gate's
recorded 10; it is not a regression:

```
Test-PluginLinks: 10 dead link(s) in 16 file(s) under C:\Users\RDP\AppData\Local\Temp\iqa-pkg-isolation-20261103-011222
  members/dispatch/SKILL.md:81        ../../../Skills/iqa-common/REFERENCE.md
  members/iqa-hub/REFERENCE.md:10     ../../../Skills/iqa-beads/REFERENCE.md
  members/iqa-hub/REFERENCE.md:12     ../../../Skills/iqa-beads-saas/SKILL.md
  members/iqa-hub/REFERENCE.md:795    ../../../Skills/iqa-beads-saas/SKILL.md
  members/iqa-hub/REFERENCE.md:835    ../../../Skills/iqa-beads-saas/REFERENCE.md
  members/iqa-hub/REFERENCE.md:1101   ../../../Skills/development-philosophy/SKILL.md
  members/iqa-hub/SKILL.md:66         ../../../Skills/iqa-common/REFERENCE.md
  members/iqa-hub/SKILL.md:71         ../../../Skills/iqa-merge/ENROLMENT.md
  members/iqa-hub/SKILL.md:113        ../../../Skills/development-philosophy/SKILL.md
  members/iqa-hub/SKILL.md:180        ../../../Skills/iqa-merge/Test-Landed.ps1
exit=1
```

**2. `tools/Test-VendoredHelpers.ps1` — exit 0.** The B1 gate is green on the
copy, including the vendored-helper presence, orphan, parse and drift layers:

```
--- Sync-VendoredHelpers.ps1 -Check
MATCH    Get-HubCadence.ps1         sha256 F69467F2375F canonical=8706 vendored=8706
MATCH    HubRegistry.ps1            sha256 2F32F5D254CB canonical=43413 vendored=43413
MATCH    Invoke-HubProbe.ps1        sha256 5039678B98D7 canonical=23298 vendored=23298
MATCH    Test-Landed.ps1            sha256 55DE023AB045 canonical=5386 vendored=5386
MATCH    Invoke-WorktreeLease.ps1   sha256 A210F61C6C43 canonical=16104 vendored=16104
Sync-VendoredHelpers -Check: MATCH - 5 vendored helper(s) identical to E:\Repos\cl-common\Skills
Test-VendoredHelpers: OK - 5 vendored helper(s) present, covered and byte-identical; 0 orphan(s); 58 helper name(s) in 16 markdown file(s) resolved (5 in scripts/, 5 in tools/, 48 deliberately not vendored, 1 of those a stale reference)
exit=0
```

**3. `scripts/Get-HubCadence.ps1` — exit 0, and the `Rung:` line comes out of the
copy** (this is D2's acceptance):

```
{
  "State": "dispatched",
  ...
  "RequiredMinutes": 2,
  "Cron": "*/2 * * * *",
  "Action": "CREATE",
  "Reason": "no rung is known for this turn; create at 2 min",
  "RungLine": "Rung: smoke next 2026-11-03 01:14 -07:00 (*/2 * * * *) - required 2 min - CREATE: no rung is known for this turn; create at 2 min"
}
exit=0
```

and the plain host line:

```
Rung: smoke next 2026-11-03 01:14 -07:00 (*/2 * * * *) - required 2 min - CREATE: no rung is known for this turn; create at 2 min
Cadence: state=dispatched action=CREATE required=2min cron=*/2 * * * *
exit=0
```

**4. Harder case — the same call with `CL_REPOS_ROOT` deleted from the
environment.** Still `exit=0` and the same `Rung:` line, which is the proof that
the reported line needs nothing outside the package:

```
Rung: smoke next 2026-11-03 01:14 -07:00 (*/2 * * * *) - required 2 min - CREATE: no rung is known for this turn; create at 2 min
Cadence: state=dispatched action=CREATE required=2min cron=*/2 * * * *
exit=0
```

With `CL_REPOS_ROOT` deleted, `Test-VendoredHelpers.ps1` reports exactly one
named failure — the drift layer cannot see its source — and no pass:

```
Sync-VendoredHelpers: CANNOT-EVALUATE - canonical Skills root not found (looked for C:\Users\RDP\AppData\Local\Temp\Skills)
Test-VendoredHelpers: FAILED - 1 reason(s)
  - drift cannot be evaluated: Sync-VendoredHelpers.ps1 -Check found no canonical Skills root ...
exit=1
```

That is deliberate and is what the ADAPTERS section states: an absent input is a
named non-verdict, never a pass. Presence, orphan, parse and name-coverage all
pass without the fleet tree; only the drift comparison is a development gate.

## 5. Nothing in the copy resolves outside itself

Grepped the copied tree for both spellings, counting every file. Re-counted on a
second fresh copy of the same tree (`iqa-pkg-isolation-20261103-011120`):

`Skills/iqa-merge` (forward slashes): **39 line matches**; `Skills\iqa-merge`
(backslashes): **11** — 50 matches over 49 lines, across 12 files, of which **2
are inside `scripts/`**. Every remaining hit is prose, a citation or a comment:

| Kind | Where (line matches) | Verdict |
| :--- | :--- | :--- |
| the new adapter contract, naming the canonical owner column and the dev override | `core/ADAPTERS.md` (6) | intended |
| "cited, never copied" citations of the landing test | `core/INVARIANTS.md` (1), `core/TASK-MODEL.md` (1), `profiles/currents-bookkeeping.md` (2) | intended |
| Phase-0 inventory evidence tables | `PHASE0-INVENTORY.md` (11) | history |
| "moved in Phase 3" note and key-watch cross-references | `members/iqa-hub/REFERENCE.md` (5), `members/key-watch/SKILL.md` (2) | prose |
| `scripts_root` prose and the on-ramp citations | `README.md` (2), `members/iqa-hub/SKILL.md` (3) | **still stale — see §6** |
| this report's own evidence | `gate/PHASE3-REMEDIATION-B1.md` (13) | the proof itself |
| manifest row naming the canonical owner | `tools/Sync-VendoredHelpers.ps1` (1) | intended |
| comment-based help examples inside the vendored probe | `scripts/Invoke-HubProbe.ps1` (2) | help text, not resolution logic |

So: **no member calls the outside path as its resolution inside a vendored
script.** The only outward reach in code is `Invoke-HubProbe.ps1:225`, which
composes *other* skills' helper paths from the fleet root for its optional groom
parts — the development-override seam described in §6 and in ADAPTERS.

## 6. Not fixed here, and why

1. **D10's 10 dead links and the stale `scripts_root` call sites** —
   `members/iqa-hub/SKILL.md:71,180,204-208`, `members/iqa-hub/REFERENCE.md:211,312,414,1232`,
   `README.md § Scripts / § Status`, `profiles/currents-bookkeeping.md:74` still
   say the fleet path is `scripts_root` "today" and that Phase 6 vendors the
   helpers. They are the member-prose rewrite (a different lane is editing those
   files concurrently), and the brief scoped this lane to the additive adapter
   section. `core/ADAPTERS.md` now states the binding default
   (`<package>/scripts`), so the contract exists ahead of the prose; the prose
   must follow or the two disagree.
2. **`Invoke-HubProbe.ps1` fleet-root fallback is one level off when vendored.**
   Canonical: `Skills/iqa-merge` -> up 3 -> fleet root. Vendored:
   `<package>/scripts` -> up 3 -> `<repo>/.worktrees`. Consequence, measured with
   `CL_REPOS_ROOT` unset and the probe run from the temp copy: the JSON verdict and
   every part status are still correct (they come from repo-local git state), but
   the **command strings** it prints for other skills' helpers point at
   `C:\Users\RDP\AppData\Local\cl-common\Skills\...`, which does not exist. It does
   not fail to run, so per the brief's rule it was **not** diverged — patching the
   copy would break byte-identity and permanently redden `-Check`. Recorded here
   and in ADAPTERS; the correct fix is in the canonical helper (exist-check the
   derived root and report `cannot-evaluate` instead of composing a path), which is
   outside this lane's write scope by the brief's rules.
3. **One stale helper reference excused in the manifest**:
   `Invoke-HubPreflight.ps1` is named in `members/iqa-hub/REFERENCE.md:1416` and no
   file of that name exists in `cl-common\Skills`, `Public\salmon-run` or this
   package (searched 2026-11-03). The gate counts it separately as
   `1 stale reference` rather than letting it pass silently.

## 7. Commits on `fix/iqa-gate-b1`

See the branch log; three commits, staged by explicit path:
`feat(iqa-gate)` the vendored helpers + sync owner, `test(iqa-gate)` the vendored
gate and its proof, `docs(iqa-gate)` the adapter contract + this report.
