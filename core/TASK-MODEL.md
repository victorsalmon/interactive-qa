# Task model

How the plugin represents work. **`bd` (beads) is the reference adapter and the
required one in v1.** There is no optional store abstraction, no pluggable
backlog backend, and no second graph: a deployment that does not have a beads
graph is not a supported deployment.

## Where the backlog lives

Each repo owns its graph at `.beads/` in the repo root, driven by `bd` — the
three fleet repos are `upscale-havens`, `currents-bookkeeping` and `cl-common`.
Blocked work and manual/human work are beads in that same graph: a manual task is
a bead labelled `manual` / `origin:human`, never a separate queue file.

- **Salmon Run is deprecated for task management.** It remains a valid project
  (its own repo, engine and docs), but no session uses its ponds, queues or
  `Tasks/` tree as a backlog any more.
- **Legacy trees are migration input only.** Never enqueue new work into
  `~/.machine/state/tasks/{00Intake,02Code,00Manual,...}`; a live item found there is
  minted as a bead and the file moves to
  `~/.machine/state/tasks/09Archive/Moved to Beads/`. A repo-local `Tasks/` dir is never
  written.
- **Minting** follows the `create-bead` skill (graph resolution, decomposition,
  write paths), never an ad-hoc title.

## Bead identity

A bead is one addressable unit of work with a stable id (`<project>-<n>`), a
state, a type, labels and notes. The id is the only handle any member may use in
a report, a hand-off or a commit message. Titles are for humans; ids are for
references, because titles are edited and ids are not.

A bead's **state transitions are the only progress record**. Nothing else
(chat, a tracker paragraph, a plan file) is evidence that work moved.

## Epics are roll-ups, never dispatched

An epic groups beads and rolls their state up for a human reading the graph. An
epic is **never claimed, never dispatched, never worked directly**: it has no
branch, no worker and no landing test of its own. If an epic looks actionable,
the gap is its missing child beads — mint them, then dispatch the children.

## Labels the fleet relies on

| Label | Meaning |
| :--- | :--- |
| `manual` | The bead needs a human act (console step, DNS, payment, signature). |
| `origin:human` | The bead was reported by the operator, not by an agent. |
| `needs-decision` | The bead cannot proceed until the operator chooses. Not a blocker on work that does not depend on it. |

A `manual` or `needs-decision` bead is *reported* by the owning member, never
waited on (Invariant 7). A blocked parent does not block unrelated siblings.

## QA numbering: ordinary beads, never a second graph

A QA session's numbering is **labels on beads that already exist**, in the shape
the fleet's graphs actually carry. The run is a **list id**; the item key is
derived from it.

| Label | On | Meaning |
| :--- | :--- | :--- |
| `iqa:list=<list>` | every member bead | The run. `<list>` is the repo's list id (`6`, `7`, `2A`, …). Membership, nothing else. |
| `iqa:id=<list>-<n>` | every item | The item's stable human key. User reports take `1`–`99` in report order; agent finds take `100+` in the same list. |
| `iqa:session-item=<list>-<n>` | work beads only | The item this work bead serves — the in-session handle. A label, not an edge: the typed edge for the pair is already taken by `discovered-from`. |
| `iqa:awaiting-validation` | items only, never work beads | Shipped and live, not yet accepted by the operator. |
| `iqa:validated:<YYYY-MM-DD>` | items only | The operator accepted it, on that date, in their own words. |
| `severity:blocker` / `severity:major` / `severity:minor` | items and work beads | Impact, set at triage — see `## Severity` below. |

**There is no roll-up bead to open.** Measured on 2026-11-03, all three fleet
graphs (`upscale-havens` 405 beads, `currents-bookkeeping` 298, `cl-common` 128)
carry list membership on the member beads themselves and hold **zero** labels in
either deprecated shape (`### Deprecated aliases` below); `iqa:list` count equals
`iqa:id` count exactly in both graphs that use the scheme (71/71 and 65/65). A
run is therefore **discovered by filtering, not by opening a bead** — the
session-level roll-up is a computed line:

```powershell
bd list --label 'iqa:list=6' --all -n 0 --json |
  ConvertFrom-Json |
  Group-Object { if ($_.labels -contains 'iqa:awaiting-validation') { 'awaiting validation' } elseif ($_.status -eq 'closed') { 'closed' } else { 'open' } } |
  Select-Object Name, Count
```

**The list id is a view.** It lets a human say "list 6" and lets a tool filter;
it is a label on ordinary beads in the repo's one graph. It is never a separate
database, never a re-sequenced id space, and never a reason to renumber or
re-mint a bead that already exists. Two runs open at once share one graph; their
members differ by label, not by store.

**Discover the ids in use before claiming one.** Run this in the target repo:

```powershell
$used = @(
  bd label list-all |
    Select-String '\biqa:list=' |
    ForEach-Object { ($_.Line.Trim() -split '\s+')[0] -replace '^iqa:list=','' } |
    ForEach-Object { [int]($_ -replace '\D','') }
)
$next = if ($used.Count) { ($used | Measure-Object -Maximum).Maximum + 1 } else { 1 }
"list ids in use: $($used -join ', ') -> next free: $next"
```

Measured output on 2026-11-03: `upscale-havens` → `list ids in use: 2, 6, 7 ->
next free: 8`; `currents-bookkeeping` → `2 -> 3`; `cl-common` → `-> 1` (no run
yet). The same query keyed on the item labels gives the next free **work-bead**
number (`100+`); the next free user-report number is the lowest unused in `1`–`99`:

```powershell
$list = '6'
$itemIds = bd label list-all |
  Select-String "\biqa:id=$list-" |
  ForEach-Object { ($_.Line.Trim() -split '\s+')[0] -replace "^iqa:id=$list-",'' } |
  ForEach-Object { [int]($_ -replace '\D','') }
if ($itemIds) { "next free item number: $((($itemIds | Measure-Object -Maximum).Maximum) + 1)" } else { 'next free item number: 1' }
```

Numbering rules:

- **The list id is claimed by the session's single writer** — the Hub — in the
  same write that labels the run's first member (`iqa:list=<list>` +
  `iqa:id=<list>-<n>`). There is no separate claim object and no roll-up bead to
  label; the first member's labels *are* the claim. A list id is named once and
  never reused, including after a run is closed or abandoned.
- An item number is unique within its list. Gaps are normal; backfilling a gap
  is not, and a work bead never takes a user-block number.
- A carried-over item **keeps its original id** and gains
  `iqa:carried-into=<next-list>`. Only genuinely new reports take new numbers in
  the new list.

Execution of the numbering — the four phases, the three passes, and where each
label is written — is [references/vendored/qa-procedure.md](../references/vendored/qa-procedure.md).

### Deprecated aliases

Earlier plugin text prescribed four shapes that the deployed graphs never used.
They are read for historical records and are **never minted again**:

| Deprecated | Live shape it maps to |
| :--- | :--- |
| `qa-run:<n>` | `iqa:list=<list>` on each member bead (the run id is the list id) |
| `qa-item:<i>` | `iqa:id=<list>-<n>` on the item bead |
| `issue:<ref>` | no label exists — the bead's `external_ref` field (`bd list --external-ref <ref>`), or a line in the bead's notes |
| `carried-into:<run>` | `iqa:carried-into=<list>` |

## Severity: impact, set at triage

Three values, no others. Each is testable against what the operator can do:

| Value | Testable definition |
| :--- | :--- |
| `severity:blocker` | The surface cannot be used at all, or data / money is at risk. There is no workaround: the user is stopped, or continuing produces a wrong financial or legal record. |
| `severity:major` | A real function is wrong or missing, and a workaround exists — another route, a manual step, a different account. The user notices and is slowed, not stopped. |
| `severity:minor` | Cosmetic, copy, or a single-path edge: a wrong word, spacing, a label, one rare branch. The flow completes correctly without the fix. |

**Who sets it.** The item's owner at triage — the session, from evidence
(the report's artefact and the reproduction), **never from the reporter's tone**.
A shouted report of a typo is `minor`; a calm "the totals don't add up" is
`blocker`. When two values are arguable, take the one the evidence supports and
say why in one line; do not interview the user for a feeling.

**An item without a severity is incomplete**: it cannot enter a close pass. The
tracker's fallback parser treats a blank Severity cell as `minor`; that is a
parser default for a legacy file, never permission to omit the label — the label
is what the graph query reads.

**Priority is not severity.** A bead's `p0`–`p3` priority is *scheduling* (what
`bd ready` proposes next); severity is *impact*. They correlate by default —
Blocker → `p0`, Major → `p1`, Minor → `p2` — and neither substitutes for the
other: a `p2` can still be `severity:blocker` in impact while a genuinely minor
defect sits at `p0` because it blocks the session's critical path. Record both,
and when they disagree, say which one is doing the work in the note.

## Adoption (a bead that already exists)

This is the normal entry path, not the exception: a graph with hundreds of beads
usually holds the defect already. **An existing bead is adopted into a run by
labelling it — never by minting a copy.**

Added by adoption, and nothing else:

- `iqa:list=<list>` — run membership.
- `iqa:id=<list>-<n>` — the item key (1–99 for a user report, `100+` for an
  agent find).
- `severity:blocker|major|minor` — if it does not already carry one.
- On a work bead: `iqa:session-item=<list>-<n>`, plus a `discovered-from` edge to
  its item (the item itself takes no such edge and no `iqa:session-item`).

Never changed by adoption: the bead **id**, its **title**, its **type**, its
existing labels, and its existing edges. A `bug` stays a `bug`; a lane label
stays; a blocker stays a blocker. Adoption adds, it never rewrites.

**Adoption is idempotent**: labels and edges are sets, so adopting the same bead
twice changes nothing — the second write adds no label and no edge, and the
bead's id, title, type, labels and edges after it are the same as before it.

**Mint only when absent.** The one-line check that decides it, run before any
`bd create`:

```powershell
bd show <bead-id> --json | ConvertFrom-Json | Select-Object id, status, @{n='labels';e={$_.labels -join ','}}
```

A returned bead means **adopt**; a failed lookup means the report is new and is
minted by the session (`bd create`), then labelled as above. Never mint a second
bead for a symptom the graph already addresses — two beads for one defect split
the evidence and the close.

**Already adopted into another run: join it, do not clone it.** A bead may
belong to more than one list — the CBK graph carries beads with two `iqa:id`
labels — so add the new `iqa:list` + `iqa:id` pair and leave the existing pair in
place. Cloning would fork the evidence; a shared bead is a shared fix, and the
second run's close cites the same landing.

## Closing a unit of work

Closing a bead requires **proven landing** (Invariant 1). The proof is derived
on the trunk the work landed on; a worker's own claim that it pushed is not a
proof. The landing test is a runnable check, not a paragraph — it is the
`landing_test` adapter, vendored at `vendor/iqa-merge/Test-Landed.ps1` (canonical owner
`Skills/iqa-merge/Test-Landed.ps1`), cited by adapter name, never copied.

Sweeping the worktree and branch after the close is the second, separate
condition in Invariant 3.

## Hand-offs are not backlog

A hand-off carries data and context, plus a pointer to a bead id. Anything that
describes *work to do* is minted as a bead in the target repo's graph, and the
hand-off cites it. A hand-off file is never a queue. Delivery requires a receipt
(Invariant 5, owned by [members/iqa-handoff/SKILL.md](../members/iqa-handoff/SKILL.md)).

## Adapter contract

`bd` is required, and the contract a deployment must satisfy is four
capabilities — no more:

1. **Mint** a bead with a title, type and labels.
2. **Link** beads with typed edges (parent/child, blocked-by, discovered-from).
3. **Claim** a bead atomically, so two workers cannot both own it.
4. **Query** the graph by state and label, so a ready list is computed rather
   than remembered.

Everything else (views, export, markdown mirrors) is derived and disposable. A
derived artefact that disagrees with the graph is stale by definition; refresh
it, never reconcile the graph to it.
