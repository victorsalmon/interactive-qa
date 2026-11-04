# Phase 0 — counted inventory (epic `cl-common-yas`, Interactive-QA-Agent plugin)

Read-only census taken 2026-11-03 on branch `docs/iqa-phase0` at the `cl-common`
worktree. Nothing in the existing tree was edited, moved or renamed; the only
file this phase adds is this one.

## How every number was derived (re-runnable)

Working directory: the cl-common checkout root. `$env:CL_REPOS_ROOT` is the
fleet repos root, normalized as `//Repos` in text.

```powershell
# SKILL.md line counts (one number per source)
(Get-Content Skills/<skill>/SKILL.md).Count

# support files per folder family (scripts/, references/, Tests/, assets/)
Get-ChildItem Skills/<skill> -Directory | ForEach-Object {
  "$($_.Name)=$((Get-ChildItem $_.FullName -Recurse -File).Count)" }

# all harness pointers (a SKILL.md that is a one-line pointer, not canon)
Get-ChildItem -Recurse -Filter SKILL.md -File |
  Where-Object { $_.Directory.Name -in $names }        # then inspect body

# pointer resolution (an env-var target is resolved, then Test-Path)
$t -match '(?i)read and follow `([^`]+)`'; Test-Path $Matches[1].Replace('$env:CL_REPOS_ROOT', $env:CL_REPOS_ROOT)

# duplication matrix (file:line for each rule phrase)
Select-String -Path <scope> -Pattern '<phrase>' -SimpleMatch -CaseSensitive:$false

# retirement risk (tracked files only, own directory + own pointer excluded)
git ls-files | Where-Object { $_ -match '\.(md|ps1|mjs|json|js|ts|yml|yaml|cmd|txt)$' }
  ... Select-String -SimpleMatch -CaseSensitive:$false -Pattern '<skill-name>' ...
```

Counting caveat: reference counts are **substring** counts, so `iqa-beads`
includes occurrences of `iqa-beads-saas`, and `key-check` includes its own
`SKILL.md`. Both are called out where they matter.

## 1. Per-source table

`support` = files under `scripts/`, `references/`, `Tests/`, `assets/` (counted,
not estimated). `pointers` = harness `SKILL.md` files that only point at the
source (canonical file excluded; plugin-member copies that *are* pointers are
included).

| # | source | canonical path | `SKILL.md` lines | support files | harness pointers | canonical exists |
| :-- | :-- | :-- | --: | --: | --: | :-- |
| 1 | `iqa-merge` | `Skills/iqa-merge/SKILL.md` | 66 | 5 (`assets` 1, `Tests` 4) | 1 | yes |
| 2 | `iqa-beads` | `Skills/iqa-beads/SKILL.md` | 86 | 5 (`scripts` 5) | 4 | yes |
| 3 | `iqa-beads-saas` | `Skills/iqa-beads-saas/SKILL.md` | 105 | 0 | 1 | yes |
| 4 | `iqa-mode` | `Skills/iqa-mode/SKILL.md` | 39 (deprecated alias, not a shell) | 19 (`assets` 1, `scripts` 10, `Tests` 8) | 6 | yes |
| 5 | `iqa-common` | `Skills/iqa-common/SKILL.md` | 104 | 0 (all detail in `REFERENCE.md`) | 1 | yes |
| 6 | `sub-mode` | `//Repos/currents-bookkeeping/Skills/sub-mode/SKILL.md` | 117 | 0 | 1 | yes, **but not in `cl-common`** |
| 7 | `sub-watch` | `//Repos/currents-bookkeeping/Skills/sub-watch/SKILL.md` | 100 | 0 | 1 | yes, **but not in `cl-common`** |
| 8 | `key-check` | `Skills/credential-rescue/skills/key-check/SKILL.md` | 629 | 0 own — its 9 runbook scripts live in the parent's `Skills/credential-rescue/scripts/` | 1 | yes |
| 9 | `credential-rescue` | `Skills/credential-rescue/SKILL.md` | 143 | 46 (`assets` 4, `scripts` 28, `Tests` 14) + 7 nested under `skills/` | 3 | yes |
| 10 | `paseo-child-agents` | `Skills/paseo-child-agents/SKILL.md` | 112 | 1 (`references` 1) | 3 | yes |
| 11 | `agent-spawn-capacity` | `Skills/agent-spawn-capacity/SKILL.md` | 124 | 6 (`assets` 1, `scripts` 3, `Tests` 2) | 2 | yes |

Totals: **1625 canon `SKILL.md` lines**, **82 support files** (46 of them
`credential-rescue`, 19 `iqa-mode` — both carry the plugin-style payloads),
**24 harness pointers**.

Pointer-resolution facts (all 24 checked):

- 24/24 pointer targets exist today → **0 literally dangling pointers**.
- 4 pointers are anchored to a **different repository**: `.agents/skills/{hub-mode,
  hub-watch, sub-mode, sub-watch}/SKILL.md` → `//Repos/currents-bookkeeping/Skills/<name>/SKILL.md`.
  They resolve on this machine because the sibling checkout exists; a published
  plugin, or a machine without `currents-bookkeeping`, dangles 4 pointers.
  These are the "known suspects" and the suspicion is right in substance, wrong
  in mechanism: **not missing files, foreign-anchored files**.
- 2 pointers are **name-mismatched**: `saas-modules/.devin/skills/iqa-beads/SKILL.md`
  and `saas-modules/Plugins/IQA/skills/iqa-beads/SKILL.md` are named `iqa-beads`
  but target `Skills/iqa-beads-saas/SKILL.md`. A reader asking for the core
  `iqa-beads` from the Devin/plugin surface silently lands on the SaaS adapter.
- `key-check` (629 lines) is the largest single canonical file in the set and
  the only one whose scripts are physically outside its own folder.

## 2. Duplication matrix

Owner = the skill/contract file that holds a statement of the rule (multiple
files inside one skill count once). `2+` owners is a later-phase finding.

| rule | statements (file:line) | owners | finding |
| :-- | :-- | --: | :-- |
| receipt / hand-off acknowledgment | `Skills/iqa-common/SKILL.md:36-39` ("No receipt, no delivery"); `Skills/iqa-merge/SKILL.md:24`, `:53`; `Skills/iqa-merge/ENROLMENT.md:60-135`; `Skills/iqa-merge/REFERENCE.md:124,976,998,1319,1387,1502`; `Skills/paseo-child-agents/SKILL.md:68-70` (dispatch start receipt); `Skills/work-now/SKILL.md:26-27` | 4 | **duplicated** |
| one writer per worktree / trunk lock | `AGENTS.md:279-281` (invariant 9); `Skills/iqa-common/REFERENCE.md:108,997` (rule 3 — *generated file*, a different rule); `:114,1001` (rule 7 — one merge writer per trunk); `Skills/cl-paseo/REFERENCE.md:37`; `Skills/cl-orchestration/REFERENCE.md:27`; `Skills/iqa-merge/SKILL.md:52` ("under the trunk lock"); `Skills/iqa-mode/scripts/iqa-hub.ps1` (2 lock sites, code) | 5 | **duplicated** (and two distinct rules share the phrase) |
| two-condition sweep gate | `Skills/iqa-merge/REFERENCE.md:435-447` (normative); restated `Skills/iqa-merge/SKILL.md:58`; cross-referenced `Skills/iqa-merge/REFERENCE.md:853` | 1 | single owner, 3 statements |
| `Test-Landed` / prove-before-close | `Skills/iqa-merge/SKILL.md:57`; `Skills/iqa-merge/REFERENCE.md:392-431,439`; `Skills/iqa-merge/ENROLMENT.md` (6 hits); `Skills/work-now/SKILL.md:57`; helper `Skills/iqa-merge/Test-Landed.ps1`; `Skills/iqa-merge/Tests/Test-Landed.Tests.ps1`; `docs/iqa/reports/merge-1h2-landing.md` | 2 | **duplicated** |
| five receipts for assuming the Hub role | `Skills/iqa-merge/SKILL.md:24`; `Skills/iqa-merge/ENROLMENT.md:60-136`; `Skills/iqa-merge/REFERENCE.md:124,976,998,1319,1502`; `Skills/work-now/SKILL.md:26-27` | 2 | **duplicated** |
| never merge inline / Hub must not run suites | `Skills/iqa-common/SKILL.md:61-75` (hard rule); `Skills/iqa-common/REFERENCE.md:226-270,982,1153`; `Skills/iqa-merge/SKILL.md:52`; `Skills/iqa-merge/REFERENCE.md:160,1197,1209`; `Skills/iqa-merge/ENROLMENT.md:17,274`; `Skills/iqa-beads-saas/REFERENCE.md:187,218`; `Skills/work-now/SKILL.md:58,102` | 5 | **duplicated** |
| secrets-by-shape / never print a value | `AGENTS.md:205-215`; `Skills/credential-rescue/SKILL.md:20`; `Skills/credential-rescue/REFERENCE.md:20`; `Skills/cl-qa/SKILL.md:104-105`; `Skills/iqa-mode/REFERENCE.md:49`; `Skills/agent-spawn-capacity/REFERENCE.md:362,595` | 5 | **duplicated** |
| gate integrity ("a gate that cannot pass is a defect") | `AGENTS.md:306-327`; `Skills/iqa-merge/REFERENCE.md:1132`; `saas-modules/docs/adr/0012-satisfiable-gates.md:79`; `saas-modules/docs/adr/0016-feqa-v2-evidence.md:34` | 3 | **duplicated** |

**7 of 8 rules have 2+ owners.** The cumulative worst case is the Hub start
contract: `work-now` restates the five receipts, `Test-Landed` and "never merge
inline / never run suites" in 112 lines of its own prose, so an edit to
`iqa-merge` cannot be trusted to reach a `work-now` session.

Additional (outside the eight, noted because it is the same class of drift):
`iqa-mode` routing is restated in 5 places — `Skills/iqa-common/SKILL.md:47-52`,
`Skills/iqa-beads/SKILL.md:43-63`, `Skills/iqa-beads-saas/SKILL.md`,
`Skills/iqa-mode/SKILL.md:37`, `Skills/work-now/SKILL.md` — plus the 6 alias
pointers.

## 3. Alias state

| alias | where it lives | points at | target resolves today |
| :-- | :-- | :-- | :-- |
| `iqa-mode` | canonical-but-deprecated `Skills/iqa-mode/SKILL.md` (39 lines, still owns the dispatch assets) + 6 pointers (`.agents`, `saas-modules/.devin`, `saas-modules/Plugins/IQA`, `Skills/cl-audit`, `Skills/cl-product`, `Skills/cl-qa`) | `Skills/iqa-beads/SKILL.md` | yes |
| `hub-mode` | pointer only: `.agents/skills/hub-mode/SKILL.md` (9 lines) | `//Repos/currents-bookkeeping/Skills/hub-mode/SKILL.md` (29 lines) | yes on this machine; **no in `cl-common`** |
| `hub-watch` | pointer only: `.agents/skills/hub-watch/SKILL.md` (9 lines) | `//Repos/currents-bookkeeping/Skills/hub-watch/SKILL.md` (25 lines) | yes on this machine; **no in `cl-common`** |
| `sub-mode` | pointer only: `.agents/skills/sub-mode/SKILL.md` (8 lines) | `//Repos/currents-bookkeeping/Skills/sub-mode/SKILL.md` (117 lines) | yes on this machine; **no in `cl-common`** |
| `sub-watch` | pointer only: `.agents/skills/sub-watch/SKILL.md` (9 lines) | `//Repos/currents-bookkeeping/Skills/sub-watch/SKILL.md` (100 lines) | yes on this machine; **no in `cl-common`** |

Additional state facts:

- `Skills/skills-index.json` lists `iqa-mode`, `iqa-merge`, `iqa-beads`,
  `iqa-beads-saas`, `iqa-common`, `credential-rescue`, `paseo-child-agents`,
  `agent-spawn-capacity` as `active`; it does **not** list `hub-mode`,
  `hub-watch`, `sub-mode`, `sub-watch`, or `key-check` (nested skills are
  unregistered).
- `iqa-mode-saas` is retired (2026-10-10) yet still cited in **14 tracked
  files** (`git grep -l iqa-mode-saas` → 14), including `saas-modules/AGENTS.md`,
  `saas-modules/ORIENTATION.md`, `saas-modules/glossary.md` and
  `saas-modules/vision.md`.
- `iqa-merge`'s own triggers still include `Sub Mode`/`sub mode`, so two live
  names (`iqa-merge`, `sub-mode`) claim the same phrase.

## 4. Retirement risk (rename-it-tomorrow)

Counts are tracked-file references to the name, excluding the skill's own
folder and its own pointer. Top three referencing paths listed.

| source | files | refs | top three referring paths | risk |
| :-- | --: | --: | :-- | :-- |
| `iqa-merge` | 26 | 50 | `Skills/work-now/SKILL.md` (4), `Skills/skills-index.json` (4), `Skills/create-bead/REFERENCE.md` (4) | medium — name is cited widely but always as a path |
| `iqa-beads` | 50 | 175 | `Skills/iqa-common/REFERENCE.md` (21), `Skills/iqa-beads-saas/SKILL.md` (17), `Skills/iqa-merge/REFERENCE.md` (14) | **high** — counts include `iqa-beads-saas` substring hits, still the most-cited name |
| `iqa-beads-saas` | 25 | 44 | `Skills/iqa-merge/REFERENCE.md` (8), `Skills/skills-index.json` (4), `Skills/cl-qa/SKILL.md` (3) | medium |
| `iqa-mode` | 50 | 145 | `Skills/iqa-common/REFERENCE.md` (14), `Skills/iqa-beads/REFERENCE.md` (11), `docs/iqa/reports/vrn.36.1-36.3-detached-bootstrap.md` (10) | **high** — deprecated yet the second most-cited name; 6 pointers + 19 asset files ride on it |
| `iqa-common` | 26 | 105 | `Skills/iqa-mode/REFERENCE.md` (25), `Skills/iqa-beads/REFERENCE.md` (22), `docs/iqa/reports/skills-mvp-completion-report.md` (6) | **high** — it is the normative core every shell names |
| `sub-mode` | 1 | 1 | `Skills/iqa-merge/REFERENCE.md` (1) | **critical** — nothing in `cl-common` would notice its removal |
| `sub-watch` | 0 | 0 | — | **critical** — zero inbound references; only the foreign pointer names it |
| `key-check` | 19 | 63 | (own `SKILL.md` 18 — self-citations), `Skills/credential-rescue/scripts/Invoke-KeyCheck.ps1` (7), `Skills/credential-rescue/scripts/Switch-OpencodeGoKey.ps1` (5) | medium — 9 scripts call it by name from the parent folder |
| `credential-rescue` | 52 | 146 | `docs/iqa/reports/cl-common-0il-key-check.md` (10), `Skills/agent-manager/skills-index.json` (8), `Skills/agent-spawn-capacity/scripts/AgentCapacity.ps1` (7) | **high** — named from operator tooling, not just docs |
| `paseo-child-agents` | 38 | 65 | `Skills/cl-paseo/skills-index.json` (4), `Skills/cl-orchestration/skills-index.json` (4), `AGENTS.md` (3) | medium |
| `agent-spawn-capacity` | 37 | 66 | `dispatch-modes-plan.md` (5), `Skills/iqa-mode/scripts/run-iqa-worker.ps1` (4), `Skills/cl-paseo/skills-index.json` (4) | medium — an executable (`run-iqa-worker.ps1`) depends on the name |

## 5. Proposed member map

Basis: the epic title (`Interactive-QA-Agent`), the existing `IQA` plugin
manifest (`saas-modules/Plugins/IQA/.devin-plugin/plugin.json`, whose `skills`
already renames/publishes only 5 of these), and the pointer/duplication facts
above. No epic design document was findable in-tree (searched
`interactive-qa-agent`, `cl-common-yas`, `publishable`, `plugin member`), so
the dispositions below are **proposed, not decided** — counted: uncertain.

| # | source skill | plugin member | disposition |
| :-- | :-- | :-- | :-- |
| 1 | `iqa-common` | `core` | **content moves** — the plugin's one normative core; `REFERENCE.md` becomes `references/core.md` |
| 2 | `iqa-beads` | `iqa-beads` | **content moves** — the sole active mode shell |
| 3 | `iqa-beads-saas` | `iqa-beads-saas` | **content moves** — SaaS adapter slots |
| 4 | `iqa-merge` | `iqa-merge` | **content moves** — SKILL + REFERENCE + ENROLMENT + `Test-Landed.ps1` + its 4 tests |
| 5 | `iqa-mode` | `iqa-mode` (alias) | **becomes a pointer** — one line to `iqa-beads`; its 19 dispatch assets are already load-bearing and must move with `iqa-merge`, not stay behind |
| 6 | `hub-mode` | `hub-mode` (alias) | **becomes a pointer** — to `iqa-merge`; today's pointer is foreign-anchored |
| 7 | `hub-watch` | `hub-watch` (alias) | **becomes a pointer** — to `iqa-merge`'s merge-tick section |
| 8 | `sub-mode` | `iqa-merge` (role) | **absorbed into core** — the Sub role is `iqa-merge`'s forwarder half, not a plugin member |
| 9 | `sub-watch` | `iqa-merge` (role) | **absorbed into core** — the parked watch loop belongs beside the merge-tick |
| 10 | `key-check` | — (out of plugin) | **becomes a pointer** — credential-ops capability; a QA plugin must not vendor a 629-line operator runbook, but `iqa-merge`/`key-check` cross-references must resolve |
| 11 | `credential-rescue` | — (out of plugin) | **becomes a pointer** — prerequisite capability, referenced by name, not vendored |
| 12 | `paseo-child-agents` | `dispatch` | **content moves** — the detached-dispatch contract is a precondition of every IQA session and is cited from `iqa-common` |
| 13 | `agent-spawn-capacity` | `dispatch` (reference) | **becomes a pointer** — supply/capacity policy stays in the fleet; only the route-and-effort contract is cited |

## 6. What could not be measured (honest gaps)

- **Epic design/disposition text**: not present in this repo
  (`git grep` for `interactive-qa-agent`, `cl-common-yas`, `publishable` = 0
  hits). Section 5 is therefore a proposal; a Phase-1 owner should diff it
  against the epic's own decision before moving content.
- **`counted: uncertain`** — the two-condition sweep gate is stated once
  normatively (`REFERENCE.md:435`) and twice by cross-reference (`SKILL.md:58`,
  `REFERENCE.md:853`); it is also illustrated in a code block
  (`REFERENCE.md:436-447`). Owner count is 1 either way, statement count is
  "1 normative + 2 pointers".
- **Reference counts are substring counts**, so `iqa-beads` (175) and
  `key-check` (63) overstate true name references; both are annotated above.
- **Non-markdown carriers not counted as duplication**: the same rules also
  exist inside scripts (`iqa-hub.ps1` trunk lock, `run-iqa-worker.ps1` route
  table, `AgentCapacity.ps1`) — counted only where a rule is *stated*, not where
  it is *implemented*. A later phase auditing executable enforcement will find
  more.
- **Harness surfaces outside this repo** (`%APPDATA%`/`~/.codex`/`~/.devin`
  installed pointers) were not counted; only in-repo pointers are in the 24.
