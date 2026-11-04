# Phase 3 gate remediation — lane B2 (D3, D5, D6, D9)

Gate bead: `cl-common-1v5`. Branch: `fix/iqa-gate-b2` (based on `dev` at
`29e4d6e7`). Worktree: `E:\repos\cl-common\.worktrees\lane-gate-fix-b2`.
Date: 2026-11-03. Scope: the four defects this lane owns — the QA numbering
vocabulary (D3), severity (D5), adoption (D6), and the executable QA procedure
(D9) from `gate/PHASE3-GATE-EVIDENCE.md` in the gate worktree.

Method: the vocabulary was **derived from the three live graphs first** and the
package rewritten to match. Nothing in this lane was written from the brief's
summary of the vocabulary.

---

## 1. Vocabulary findings — measured, per repo

Commands (read-only, run in each repo):

```powershell
bd label list-all 2>&1 | Select-String 'iqa:|severity:' -CaseSensitive
bd list --all -n 0 --json
```

Snapshot 2026-11-03:

| Shape | `upscale-havens` (405 beads, 164 labels) | `currents-bookkeeping` (298 beads, 198 labels) | `cl-common` (128 beads, 66 labels) |
| :--- | ---: | ---: | ---: |
| `iqa:list=<list>` | 71 | 65 | 0 |
| `iqa:id=<list>-<n>` | 71 | 65 | 0 |
| `iqa:session-item=<list>-<n>` | 22 | 0 | 0 |
| `iqa:awaiting-validation` | 26 | 0 | 0 |
| `iqa:validated:<date>` | 3 | 0 | 0 |
| `iqa:open` | 1 | 0 | 0 |
| `severity:blocker` | 3 | 0 | 0 |
| `severity:major` | 58 | 0 | 0 |
| `severity:minor` | 30 | 0 | 0 |
| `iqa:carried-into=<next>` | 0 | 0 | 0 |
| deprecated run/item shapes (§3.1) | 0 | 0 | 0 |
| Distinct list ids | `2A`, `6`, `7` | `2A` | none |

### Verdict on agreement

**They agree on the core, and disagree only on the optional half.**

- **Agree (authoritative, both graphs):** a run is `iqa:list=<list>`; an item key
  is `iqa:id=<list>-<n>`; list ids are short numeric-leading tokens (`6`, `7`,
  and the legacy follow-up `2A`); list ids are **per-graph** (both graphs use
  `2A` independently); user-block ids run `1`–`99` and agent ids `100+`.
- **Disagree (optional, UH only):** `iqa:session-item=<list>-<n>`,
  `iqa:awaiting-validation`, `iqa:validated:<date>` and `severity:*` exist only
  in `upscale-havens`. `currents-bookkeeping` runs the list/id pair alone;
  `cl-common` has no run yet.
- **Both graphs agree that the deprecated run/item shapes are absent** — 0
  occurrences in all three, confirming D3's finding that the package's prescribed
  vocabulary was invented, not in use.

### Two findings the brief did not anticipate

1. **There is no roll-up bead.** The brief (and `iqa-hub` → `## QA mode`) describe
   `iqa:list` as a label "on the roll-up bead". Measured: `iqa:list` appears on
   **every member bead** (71 lists = 71 ids in UH; 65 = 65 in CBK), and a query
   for beads carrying `iqa:list` without an `iqa:id` returns **zero** in both
   graphs. A list id is therefore claimed by the first member's labels, and the
   session-level roll-up is a computed filter, not a bead. The package now states
   that, and the claim rule was rewritten to "claimed by the session's single
   writer in the same write that labels the run's first member".
2. **`iqa:list` is membership, not identity.** In `currents-bookkeeping`, 65
   beads carry `iqa:list=2A` but the label is also on landing/merge beads that
   carry **no** `iqa:id`; and a bead can carry **two** `iqa:id` labels
   (`currents-bookkeeping-vrn.7.3.16` carries `iqa:id=2A-160` and
   `iqa:id=2A-163`). That measurement is the evidence behind the adoption rule
   "a bead already in another run joins it, it is not cloned".

---

## 2. What changed

| File | Change |
| :--- | :--- |
| `core/TASK-MODEL.md` | `## QA numbering` rewritten to the live vocabulary (+153/−19 lines): a six-row label table, the no-roll-up-bead finding with its measurement, the computed roll-up command, the discovery command for the next free list id and the next free work-bead number, the claim/never-reuse rules, `### Deprecated aliases` (four rows, mapped, never minted again), new `## Severity` (+28), new `## Adoption (a bead that already exists)` (+41). |
| `references/vendored/qa-procedure.md` | **New (437 lines).** The executable procedure: provenance header (absolute sources, 2026-11-03, "this file is the package's copy, the canonical sources still own the rules"); four phases (blocker analysis → populate tracker → live dual-lane → summary/hand-off) and three passes (interactive → close → nightly), each with entry condition, exit condition and the command that proves the exit; the tracker dual-write with its authoritative sides and four divergence shapes; the close pass and the `iqa:awaiting-validation` → `iqa:validated:<date>` handshake; the evidence rule with what does *not* count; the graph-vs-tracker repair sequence; the two slots (`gates`, `deploy`) this file deliberately does not own. |
| `members/iqa-hub/SKILL.md` | `## QA mode` numbering bullet rewritten to the live labels and the adoption rule; the three-pass bullet now points at the in-package procedure (+10/−5). No other change — lane A owns the dead-link lines in this file. |
| `core/PROFILE.template.md` | `beads_epic` slot description changed from "the epic that rolls this repo's work up" to the run's list label (1 line) — required by the no-roll-up finding. |
| `profiles/currents-bookkeeping.md` | `beads_epic` value changed from the deprecated run epic to `iqa:list=<list>` (1 line). |

Deliberately unchanged: every other `iqa:list` / `iqa:id` consumer, the taxonomy
detail (`iqa:phase`, `iqa:surface`, `iqa:deferred`, `iqa:operator-closed`), the
merge-hub sections, `scripts/` and `ADAPTERS.md` (lane B1), and all links lane A
is fixing.

Every command published in the two files was run read-only before it was
written; the three measured outputs are quoted in the files themselves (`next
free: 8` for UH, `3` for CBK, `1` for cl-common; `next free item number: 103` for
UH list 6; the list-6 roll-up `awaiting validation 17 / closed 12 / open 1`).

---

## 3. Proofs

### 3.1 No deprecated run/item label outside the alias table

Scope: every rule-bearing Markdown file in the package (16 files: `SKILL.md`,
`README.md`, `core/`, `members/`, `profiles/`, `references/`). `gate/` — this
report — is excluded and declares itself evidence: it necessarily names the
defect it repairs.

```powershell
$files = Get-ChildItem -Recurse -Filter *.md | Where-Object { $_.FullName -notmatch '\\gate\\' }
Select-String -Path $files.FullName -Pattern 'qa-run:|qa-item:' |
  ForEach-Object { "$($_.Path.Replace((Get-Location).Path,'')):$($_.LineNumber): $($_.Line.Trim())" }
```

```
\core\TASK-MODEL.md:140: | `qa-run:<n>` | `iqa:list=<list>` on each member bead (the run id is the list id) |
\core\TASK-MODEL.md:141: | `qa-item:<i>` | `iqa:id=<list>-<n>` on the item bead |
```

Two hits, both inside `core/TASK-MODEL.md` → `### Deprecated aliases`. The three
pre-existing hit sites (`members/iqa-hub/SKILL.md:44`,
`profiles/currents-bookkeeping.md:23`, and the whole old `## QA numbering`
section) are gone.

### 3.2 All three severities present, defined

Same scope, same command shape:

```powershell
Select-String -Path $files.FullName -Pattern 'severity:blocker|severity:major|severity:minor' |
  Group-Object Path | ForEach-Object { "$($_.Name.Replace((Get-Location).Path,'')) : $($_.Count)" }
"total severity hits: $((Select-String -Path $files.FullName -Pattern 'severity').Count)"
```

```
\core\TASK-MODEL.md : 6
\references\vendored\qa-procedure.md : 5
total severity hits: 24
```

D5's baseline was **0** occurrences of `severity` in the whole package; it is now
defined (`core/TASK-MODEL.md` → `## Severity`: three testable values, who sets
it, the incomplete-item rule, the priority-vs-severity axis) and used
(`references/vendored/qa-procedure.md`).

### 3.3 Adoption section present

```
$ Select-String -Path core\TASK-MODEL.md -Pattern '^## ' | ForEach-Object { "$($_.LineNumber): $($_.Line)" }
8: ## Where the backlog lives
26: ## Bead identity
36: ## Epics are roll-ups, never dispatched
43: ## Labels the fleet relies on
54: ## QA numbering: ordinary beads, never a second graph
145: ## Severity: impact, set at triage
173: ## Adoption (a bead that already exists)
214: ## Closing a unit of work
224: ## Hand-offs are not backlog
231: ## Adapter contract
```

### 3.4 Link check — package-wide, then escape check

```powershell
pwsh -NoProfile -File interactive-qa-agent\tools\Test-PluginLinks.ps1
```

```
Test-PluginLinks: OK - 121 relative link(s) resolved across 17 file(s) under E:\Repos\cl-common\.worktrees\lane-gate-fix-b2\interactive-qa-agent
```

(Was `110 links / 15 files` on the base branch — the delta is the new procedure
file and this report, and the procedure's own links.)

Escape check (lane A's hardening, run to prove my additions stay inside):

```powershell
$pkg = (Resolve-Path 'interactive-qa-agent').Path
Get-ChildItem interactive-qa-agent -Recurse -Filter *.md | ForEach-Object {
  $dir = $_.DirectoryName
  foreach ($m in [regex]::Matches((Get-Content $_.FullName -Raw), '\]\((?!https?:)([^)#]+)')) {
    $t = [System.IO.Path]::GetFullPath((Join-Path $dir $m.Groups[1].Value))
    if (-not $t.StartsWith($pkg, 'OrdinalIgnoreCase')) { "$($_.FullName): ESCAPES -> $t" }
  }
}
```

```
...\members\dispatch\SKILL.md: ESCAPES -> ...\Skills\iqa-common\REFERENCE.md
...\members\iqa-hub\REFERENCE.md: ESCAPES -> ...\Skills\iqa-beads\REFERENCE.md
...\members\iqa-hub\REFERENCE.md: ESCAPES -> ...\Skills\iqa-beads-saas\SKILL.md
...\members\iqa-hub\REFERENCE.md: ESCAPES -> ...\Skills\iqa-beads-saas\SKILL.md
...\members\iqa-hub\REFERENCE.md: ESCAPES -> ...\Skills\iqa-beads-saas\REFERENCE.md
...\members\iqa-hub\REFERENCE.md: ESCAPES -> ...\Skills\development-philosophy\SKILL.md
...\members\iqa-hub\SKILL.md: ESCAPES -> ...\Skills\iqa-common\REFERENCE.md
...\members\iqa-hub\SKILL.md: ESCAPES -> ...\Skills\iqa-merge\ENROLMENT.md
...\members\iqa-hub\SKILL.md: ESCAPES -> ...\Skills\development-philosophy\SKILL.md
...\members\iqa-hub\SKILL.md: ESCAPES -> ...\Skills\iqa-merge\Test-Landed.ps1
```

**All ten are the pre-existing D10 escapes**, on lines this lane did not touch
(`members/dispatch/SKILL.md:81`, `members/iqa-hub/REFERENCE.md:10,12,795,835,1101`,
`members/iqa-hub/SKILL.md:66,71,113,180`). Zero escapes point at a link added
here: `core/TASK-MODEL.md` → `../references/vendored/qa-procedure.md` and
`members/iqa-hub/SKILL.md` → `../../references/vendored/qa-procedure.md` both
resolve inside the package. Lane A owns the fixes; this lane reports them and
does not touch them.

---

## 4. Gaps this lane left, and why

1. **The brief's "label the roll-up bead" claim is not implemented as written**
   (see §1). The live graphs have no roll-up bead, and inventing one would be the
   same defect D3 is about — a rule the sources contradict. The claim rule is
   preserved in substance (single writer, claimed once, never reused) and the
   divergence is stated in `core/TASK-MODEL.md` and here.
2. **`issue:<ref>` has no live label to map to.** No `issue:`-shaped label exists
   in any of the three graphs, so the alias table maps it to the bead's
   `external_ref` field plus a note line — the adapter's own capability
   (`bd list --external-ref`), not a new label. Recorded as a mapping, not a
   procedure.
3. **The tracker-row count in `Phase 1 → Prove` cannot be executed against a
   committed fixture.** No repo commits an `*-iqa-test-tracker.md` today (both
   `IQA2/` dirs hold session logs only), so the regex is written against the
   documented tracker contract ("ID column carries the Session-Item id") and run
   against an empty set — it returns `0` rather than an error
   (`-ErrorAction SilentlyContinue`). It is the one command in the procedure whose
   *matching* half has not been exercised on real data.
4. **No line-number claim for lane A's merge.** `members/iqa-hub/SKILL.md` is
   edited by both lanes on disjoint lines (`## QA mode` here; the dead-link lines
   there). The merge should be a clean 3-way, but this lane cannot prove that
   without lane A's tree, so it is flagged rather than asserted.
5. **`iqa:open`, `iqa:validated:<date>`, `iqa:deferred:<reason>` and
   `iqa:operator-closed:<reason>` are described in the label table only where the
   procedure writes them;** the full closed taxonomy stays where it is (outside
   this package) and was not copied in — copying it is a Phase 6 packaging job,
   not a D3/D5/D6/D9 repair.
6. **`bd` write paths were verified by `--help` and by the sources, not
   executed.** Executing `bd label add` / `bd create` / `bd close` would have
   written to `upscale-havens` or `currents-bookkeeping`, which this lane must not
   touch. The read-only queries in both files were all executed against the live
   graphs; the write commands were not.
