# The QA procedure

The procedure a QA session executes, end to end, from this package alone. Four
phases, three passes, one graph, one tracker, one evidence rule. Every command
below is meant to be pasted and run.

## Provenance

| | |
| :--- | :--- |
| Snapshot taken | 2026-11-03 |
| Source | `cl-common/Skills/iqa-common/REFERENCE.md` - `## The three passes in detail`, `## Session-log contract (user-gated validation)`, `## Validate List command`, `## Mark validated command`, `## Close Session command` |
| Source | `cl-common/Skills/iqa-beads/REFERENCE.md` - `## Pass deltas (Beads additions)`, `## Beads field mapping` (`### Identity`, `### Status mapping (normative)`, `### Priority / type`, `### Edges`, `### Labels`, `### Ready vs Validate definitions`, `### Carry-over at roll`), `## Phase 0`-`## Phase 3`, `### Tracker table contract` |
| Source | `cl-common/Skills/iqa-mode/REFERENCE.md` - `## Phase 0 - Blocker Analysis` (the health-check steps) |
| Source | `cl-common/Skills/iqa-beads-saas/SKILL.md` - the SaaS slots this procedure resolves through the repo profile |
| Source | `currents-bookkeeping/Skills/hub-mode/REFERENCE.md` - merge batching, deploy verification, and the done-evidence line |

This file is **the package's copy** of that procedure. The canonical sources
above still own the rules; when they change, this snapshot is re-taken, never
patched from memory. A session executes this file and does not need to open any
of them.

## Set once per session

Resolve these values, then run everything else unchanged. `$list` comes from
the discovery query in [core/TASK-MODEL.md](../../core/TASK-MODEL.md) ->
`## QA numbering`; `$sessionDir` is the profile's `session_log_dir`.

```powershell
$repoRoot   = $env:CL_REPOS_ROOT\upscale-havens     # the repo under test
$list       = '8'                                  # the run's list id
$sessionDir = "$repoRoot/IQA2"                     # profile slot: session_log_dir
$trunk      = 'dev'                                # profile slot: trunk
$portalRoot = '<portal root URL from the profile>'
$portalPage = '<one key page URL>'
$apiHealth  = '<backend health URL>'
Set-Location $repoRoot
```

The vocabulary this procedure writes is defined once in
[core/TASK-MODEL.md](../../core/TASK-MODEL.md) -> `## QA numbering`: membership
`iqa:list=<list>`, item key `iqa:id=<list>-<n>`, work-bead handle
`iqa:session-item=<list>-<n>`, validation `iqa:awaiting-validation` ->
`iqa:validated:<date>`, impact `severity:blocker|major|minor`. User reports take
`1`–`99` in report order; agent finds take `100+` in the same list.

---

## Phase 0 — Blocker analysis

**Entry.** The operator has opened a session and named the product. Nothing has
been written to the graph yet.

**Do.** Five health checks and one graph check. Record each PASS / FAIL / N/A in
the blocker report; a FAIL names the flow it blocks.

1. **Deploy reachability.** Probe the portal root, two or three key pages, and
   the backend health endpoint. A non-200 is a blocker. Take the URLs from the
   repo profile / `AGENTS.md`, never from memory.

   ```powershell
   foreach ($u in @($portalRoot, $portalPage, $apiHealth)) {
     "$u -> " + (curl.exe -s -o NUL -w "%{http_code}" $u)
   }
   ```

2. **Secrets and config.** Verify *existence* only (never print a value, never
   list contents): a missing secret is a blocker; a live-vs-test mode choice is
   an operator decision, which is a `manual` bead, not a blocker.
3. **Build state.** Build in the worktree, not in a deploy-output checkout:

   ```powershell
   git worktree list
   git status --porcelain
   ```

4. **Known outages and open blockers.** Anything already recorded as an
   unresolved outage or a `severity:blocker` bead is a blocker until it is
   closed:

   ```powershell
   bd list --label severity:blocker --all -n 0 --json |
     ConvertFrom-Json | Select-Object id, status, title
   ```

5. **Branch and worktree state.** Confirm a clean place to land fixes. Foreign
   uncommitted work is noted, never blamed and never touched.
6. **Graph health.** `bd status` must answer. A schema-skew error means BLOCKED
   for the graph; continuing calls it BLOCKED-even-semantics-only and needs the
   operator's explicit words, recorded in the session log.

   ```powershell
   bd status
   ```

Bugs found during this scan are triaged immediately as Phase 2 items — they do
not wait for the tracker.

**Exit.** One verdict — **READY**, **DEGRADED** (with the unusable flows named
out loud), or **BLOCKED** (with the one thing that unblocks it).

**Prove.** The verdict, the printed status codes, and a `bd status` that
answered. A DEGRADED session that cannot name its unusable flows is BLOCKED.

---

## Phase 1 — Populate the tracker

**Entry.** Phase 0 is not BLOCKED, and the list id is claimed.

**Do.**

1. **Inventory the real surfaces** — pages and routes, JS entry points, backend
   routes, deployed API endpoints.
2. **Import existing QA docs** — prior matrices are reused, never redone.
3. **Reconcile** — `scan ∖ matrix` gives the new rows; `matrix ∖ scan` gives
   stale flags (flag them; never silently rewrite the source doc).
4. **Write the tracker** to `$sessionDir\<date>-<repo>-iqa-test-tracker.md`: one
   row per verifiable surface, with the columns the tracker contract requires —
   ID, Status, Severity, Blocker, Symptom, **Beads** (comma-separated work-bead
   ids, empty at populate time).
5. **Populate the graph** — for every known symptom, either **adopt** the bead
   that already describes it or **mint** one, then label it. Adoption is the
   normal case and mints nothing
   ([core/TASK-MODEL.md](../../core/TASK-MODEL.md) -> `## Adoption`):

   ```powershell
   # adopt (the bead exists)
   bd label add <bead-id> "iqa:list=$list,iqa:id=$list-1,severity:major"

   # mint (no bead exists) — bd prints the new id; use it as <new-id>
   bd create "$list-1 — <one-line symptom>" -t bug -p 1
   bd label add <new-id> "iqa:list=$list,iqa:id=$list-1,severity:major"
   bd note <new-id> "<verbatim report>`nExpected: <x>`nActual: <y>`nSteps: <z>"
   ```

No work beads at populate time: work beads are minted during Phase 2 triage,
under their item.

**Exit.** Every tracker row has a real bead id, and every item bead in the graph
has a tracker row.

**Prove.** The two counts agree — item ids in the graph (user block `1`–`99`
only; work beads are `100+` and are not tracker rows) against the tracker's item
rows:

```powershell
$graphItems = bd list --label "iqa:list=$list" --all -n 0 --json | ConvertFrom-Json |
  ForEach-Object {
    $_.labels | Where-Object { $_ -like "iqa:id=$list-*" } | ForEach-Object {
      if ([int](($_ -split '-')[-1]) -le 99) { $_ }
    }
  }
$trackerRows = (Select-String -Path "$sessionDir\*-iqa-test-tracker.md" -Pattern "\|\s*$list-([1-9][0-9]?)\s*\|" -ErrorAction SilentlyContinue).Count
"graph item ids: $($graphItems.Count) / tracker item rows: $trackerRows"
```

---

## Phase 2 — Live dual-lane session

**Entry.** The tracker is populated. The operator is testing.

**Do.** The loop, per report, without leaving the operator waiting:

1. **Capture** (≤ 1 minute, on the critical path). Record the report verbatim
   plus expected vs actual plus steps. Ask at most two or three clarifying
   questions; if it is clear enough to triage, move on. Adopt-or-mint the item
   as in Phase 1, and update its tracker row in the same step.
2. **Severity** — one decision, from evidence, never from tone
   ([core/TASK-MODEL.md](../../core/TASK-MODEL.md) -> `## Severity`). Map it to
   scheduling priority in the same breath: Blocker → `p0`, Major → `p1`, Minor →
   `p2` (trivial copy or CSS may be `p3`). A question, an operator action, or an
   external dependency is a `manual` bead (`manual` + `origin:human`), not an
   item.
3. **Split the work.** One implementation unit per work bead (`100+`), each
   labelled `iqa:session-item=<list>-<n>` and linked `discovered-from` its item.
   A work bead without that handle is a defect — fix the edge before dispatch.
4. **Claim, then dispatch.** The session is the only graph writer; the worker
   reads ids from its brief and never runs `bd`:

   ```powershell
   bd update <work-bead-id> --claim -a <agent-id>
   bd label add <work-bead-id> "lane:<branch>"
   ```

   Dispatch detached, from [members/dispatch/SKILL.md](../../members/dispatch/SKILL.md).
5. **Land, deploy, ping.** Merge reviewed work to the trunk in small batches,
   verify the deploy by its evidence line (never an exit code), then tell the
   operator to re-test:

   ```
   REDEPLOYED <sha(s)> -> <dev-url> — hard-reload (Ctrl+Shift+R) and re-test:
   "<verbatim report>" [<list>-<n>]
   ```

**Exit.** Nothing is untriaged: every item carries a severity, every item has at
least one work bead or is closed, and the Validate List renders.

**Prove.** This query must print nothing — a returned id is an item that cannot
enter the close pass until it is triaged:

```powershell
# every member of the run must carry a severity
bd list --label "iqa:list=$list" --all -n 0 --json | ConvertFrom-Json |
  Where-Object { -not ($_.labels | Where-Object { $_ -like 'severity:*' }) } |
  Select-Object id, title
```

---

## Phase 3 — Summary and hand-off

**Entry.** The operator stops testing, or asks for the summary.

**Do.** Print the roll-up from the graph (not from memory), write the session
log, and hand off anything that crosses agents or sessions
([members/iqa-handoff/SKILL.md](../../members/iqa-handoff/SKILL.md)). Only the
operator rolls the list; the session never rolls it on its own initiative.

```powershell
bd list --label "iqa:list=$list" --all -n 0 --json |
  ConvertFrom-Json |
  Group-Object { if ($_.labels -contains 'iqa:awaiting-validation') { 'awaiting validation' } elseif ($_.labels -match 'iqa:validated:') { 'validated' } elseif ($_.status -eq 'closed') { 'closed' } else { 'open' } } |
  Select-Object Name, Count
```

Each session-log entry carries four fields per item: the item id; the report in
the operator's own words; what was done (commits, deploy refs, plan refs, or
"no fix yet"); and the user status — `open`, `fix live, awaiting validation`,
`validated resolved`, or `deferred` with the operator's reason.

**Exit.** The roll-up is printed, the log is written, and every open or awaiting
item is named with an owner.

**Prove.** The counts equal the tracker tally, and the log file exists at the
printed path.

---

## The three passes

### Pass 1 — Interactive

**Entry.** Phase 2 is open.

**Do.** Per item, in this order: capture → code (worker, focused suite, one
commit per concern, push) → review (read-only, against the acceptance criteria;
a fix on the wrong seam or a duplicated shared behaviour fails review; style is
routed, never failed) → merge (`git merge --no-ff` from the trunk worktree,
explicit paths only) → deploy (the trunk push, or the repo's deploy skill) →
ping (`REDEPLOYED`).

Never in pass 1: the full regression battery, property runs, mutation runs,
doc/drift grooming, pipeline refactors.

**Exit.** Every capture has a bead, a disposition and a tracker row; every landed
fix has a deploy ref.

**Prove.** The `REDEPLOYED` lines plus the deploy log's verification line, and
the Validate List query.

### Pass 2 — Close

**Entry.** The operator's Close command, and only inside it.

**Do.** A Step-0 gate, then three steps, in order.

- **Step 0 — pre-close readiness (session-owned, read-only).** Answer two
  questions from the reconciled tracker and log: (1) is any decision or operator
  action needed for the active list to complete correctly, and (2) is there any
  reason the session should not close yet? Name the evidence — items still
  `open` or awaiting validation, items blocked on an operator or an external
  fact. If (2) is yes, do not start Step 1.
- **Step 1 — maintain.** A dispatched worker eliminates stale items first (with
  the superseding commit or item id) and then drift over the groomed list: code,
  docs, indexes, manifests. Testing is explicitly out of scope.
- **Step 2 — QA.** A second worker takes the maintain report verbatim and audits
  the tests and testing pipelines for staleness over exactly that list, building
  or refactoring pipelines where none could catch the defect class. The full
  regression suite is green at the end of this step.
- **Step 3 — nightly queue.** Any testing infrastructure that step 2 created or
  changed, over non-stale items, is queued on that evening's nightly run — one
  entry, never a duplicate — into the profile's `nightly_queue` destination (or
  `none — <reason>` if the slot is none).

Then roll the active list: the next session takes the next identity and its user
items start at `1`. The roll needs no separate active-list file — the next free
list id is the discovery query in [core/TASK-MODEL.md](../../core/TASK-MODEL.md)
-> `## QA numbering`, computed from the graph itself; if the deployment does keep
an active-list record, it changes in the same commit.

**Exit.** The export is reconciled against the tracker, the session log and
tally are written, the roll is recorded, and nothing still `open` or awaiting
validation is silently closed — it is named.

**Prove.** The export and the tracker agree (see `## The tracker dual-write`),
and the printed tally matches both.

### Pass 3 — Nightly

**Entry.** An explicit request only. It is off by default.

**Do.** Run the mutation battery (and the full FEQA / API run) over the testing
infrastructure that pass 2 changed. Below-threshold scores and surviving mutants
are **evidence, not a panic**: record them against the shipped commits and repair
test-only in the next session, at most two iterations, never by weakening an
assertion.

**Exit.** Every changed item has exactly one queued entry, and any survivor has
a minted fix bead (`discovered-from` the run bead) rather than an inline patch.

**Prove.** The queued entry exists in the `nightly_queue` destination and the
survivor is a bead id.

---

## The tracker dual-write

The session writes **two** things for every item, in the same step: a row in the
markdown tracker, and a bead in the repo's one graph. Neither is a cache of the
other.

| The question | The authoritative side |
| :--- | :--- |
| What the operator decided (user status: open / fix live, awaiting validation / validated resolved / deferred) | The **session log**, then the tracker row. |
| What is true of the graph (ids, labels, edges, blockers, work-bead membership) | The **beads graph**. |

So: **log wins on user status, graph wins on edges and refs.** `bd closed` never
means validated, and a tracker row is never evidence that work moved.

A **divergence** looks like one of these, and each has one repair:

- The tracker says `fix live, awaiting validation` and the bead lacks
  `iqa:awaiting-validation` (or the item carries no `severity:*` label): the graph
  is right about labels, the log is right about status — repair the label from
  the evidence, then repair the row.
- An item is in the tracker with no bead, or the bead's `iqa:session-item` points
  at an item that does not exist: the graph is right, the row is stale — repair
  the row.
- A work bead sits in the tracker's Beads cell for one item but carries another
  item's handle: the graph is right — repair the cell.
- A closed bead whose evidence path no longer exists: this is `stale`, not a
  divergence — re-open or re-mint, per triage.

**Reconcile before you answer.** Export, diff, repair, then answer — never carry
a divergence silently into a Validate List answer or into the close pass:

```powershell
bd export -o "$sessionDir\beads-$(Get-Date -Format yyyy-MM-dd).jsonl"
bd list --label "iqa:list=$list" --all -n 0 --json | ConvertFrom-Json |
  Select-Object id, status, @{n='labels';e={$_.labels -join ','}}
```

## The close pass and the awaiting-validation handshake

One handshake, in this order. The agent never flips the last step.

1. A work bead closes when its own evidence exists (merged, focused gate green,
   deploy verified). It carries **no** validation label.
2. When every work bead under an item is closed **and** the portal probe is
   green, the session closes the item and labels it:

   ```powershell
   bd close <item-id> --reason "<what landed> — evidence: <path/ref>"
   bd label add <item-id> 'iqa:awaiting-validation'
   ```

3. The Validate List renders exactly those items — items only, never work beads:

   ```powershell
   bd list --label iqa:awaiting-validation --label origin:user --all -n 0 --json |
     ConvertFrom-Json |
     Where-Object { -not ($_.labels | Where-Object { $_ -like 'iqa:validated:*' }) } |
     Select-Object id, title
   ```

4. The operator re-tests and says it, in their own words. Only then:

   ```powershell
   bd label remove <item-id> 'iqa:awaiting-validation'
   bd label add <item-id> "iqa:validated:$(Get-Date -Format yyyy-MM-dd)"
   bd note <item-id> "validated by the operator <date>: <what they re-tested>"
   ```

   followed immediately by a fresh Validate List answer, not a bare
   acknowledgement.

A shipped fix moves an item to `awaiting validation`, never to `validated`. A
passing suite is not a validation, and retest chatter is not an explicit
acceptance.

## The evidence rule

**A close needs an evidence path.** No path, no close — the item stays open and
the missing evidence is reported as the blocker it is.

An **evidence path** is a location or ref the next agent can re-open:

- a landing test result on the trunk (the commit is an ancestor of
  `origin/<trunk>`, and the claimed paths are in the remote tree);
- an HTTP status **plus** the served bytes (or a fetched page showing the change
  and its old behaviour gone);
- the deploy log's verification line (an artefact, never a hook's exit code);
- a test, property or mutation run's log path;
- a screenshot or capture saved at a path, for a copy or layout item;
- the `REDEPLOYED <sha> -> <url>` ping.

**Not** evidence: a worker's prose ("pushed", "done", "should be fine"), a green
chat message, a plan that describes the fix, or an uncommitted working tree. The
path goes into the close reason and the bead's notes, and the same fix is
described in the session log's "what was done" field.

## When the graph and the tracker disagree

Run this sequence; do not improvise a fourth option.

1. **Export first.** Render the graph before touching the tracker.
2. **Diff by item id**, not by title.
3. **Repair from the rule above** — log wins on user status, graph wins on ids,
   labels and edges — and make the repair in the session, which is the only
   writer. A worker never repairs the graph.
4. **Record the repair** in the session log as one line: what disagreed, which
   side won, what changed.
5. **Never** delete a bead, renumber an item, or rewrite the tracker to match a
   guess. If the disagreement cannot be resolved from evidence, it is a
   `needs-decision` bead for the operator, and the affected item is reported as
   blocked rather than closed.

## What this file does not own

Two things are deliberately outside it and resolve through the repo profile
([core/PROFILE.template.md](../../core/PROFILE.template.md)): the exact gates
(`focused_gate`, `full_gate`, `landing_test`) and the deploy path
(`deploy_skill`, `deploy_verify`, `close_proof`). Where a profile slot is
`none — <reason>`, the procedure records a `cannot-evaluate` for that step; it
never substitutes an exit code or a claim for the missing artefact.
