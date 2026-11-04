---
name: iqa-hub
description: >
  IQA hub member - runs a beads-backed interactive QA session end to end
  (blocker analysis, tracker population, live dual-lane session, triage, close)
  and is the single merge owner for its repo, draining queued branches through
  merge beads with detached merge workers. Use when the user says "IQA",
  "interactive QA", "IQA Mode", "IQA-Beads", "IQA2", "IQA-Saas", "test the
  portal", "can I user-test today", "Hub Mode", "hub mode", "IQA-Merge",
  "IQA Merge Mode", or "work now".
---

# iqa-hub

## When to use

The user wants a session: they are going to report symptoms, or they want the
repo's backlog driven to empty through merge beads. Not for a single unit of work
(that is [iqa-sub](../iqa-sub/SKILL.md)), and not for the lone question of whether
a message arrived (that is [iqa-handoff](../iqa-handoff/SKILL.md)).

This member is the whole IQA session **and** the merge hub: `Hub Mode` and
`IQA-Merge` are the same role, the session wearing the repo Hub labels, so its own
lane beads and stray Sub branches both land through merge beads. Only `Sub Mode`
forwards; it never merges.

## QA mode

An interactive QA session against a deployed web product (or local full-stack) runs
in four phases - **blocker analysis -> populate tracker -> live dual-lane session
-> summary** - across **three passes** (interactive, close, nightly), with the live
tracker as the repo's **beads issue graph** dual-written with the markdown tracker.
`iqa-mode` is deprecated and resolves here; historical references to it (a
markdown-only tracker) mean this session.

- **One list per session, one bead per report.** A symptom is one item bead first;
  work beads split from it eagerly, carrying a `discovered-from` edge and a
  `split from <item>` note. An agent finding is a work bead under its item. Never
  a work bead without its item edge - the backend batch is the backstop.
- **Session identity, not calendar time.** A session is one list plus its
  tracker plus its epic. It rolls to the next identity only when the user closes
  it; a session may span days. The user decides when a tracker opens and when a
  session closes.
- **Numbering is a view, never a second graph.** The run is a list id carried by
  `iqa:list=<list>` on each member bead, the item by `iqa:id=<list>-<n>`, work
  beads by `iqa:session-item=<list>-<n>`, and impact by `severity:*` — exactly as
  [TASK-MODEL](../../core/TASK-MODEL.md) -> `## QA numbering` states. There is no
  roll-up bead to open (the roll-up is a computed filter), and a bead that
  already exists is adopted by labelling it, never re-minted
  ([TASK-MODEL](../../core/TASK-MODEL.md) -> `## Adoption`).
- **Three passes, in order.** Pass 1 (interactive) captures and dispatches on the
  user's critical path; pass 2 (close) runs only inside the user's Close
  workflow; pass 3 (nightly) is off by default and runs only on an explicit
  request. The executable procedure — four phases, three passes, each with its
  entry condition, exit condition and proving command — is
  [references/vendored/qa-procedure.md](../../references/vendored/qa-procedure.md).
- **Session commands are answered by the session, never delegated**:
  `Config`/`Configuration`, `Catch-up`, `Validate List`/`List`,
  `mark validated`, `UAT`/`UAT wiki`, `Close`/`Close session`. Everything else
  execution-shaped is dispatched ([dispatch](../dispatch/SKILL.md)).
- **Closeable / stale bead sweep.** A triage pass classifies each bead as
  `close-candidate` (its evidence path exists), `defer` (external fact or operator
  decision), `build` (work remains) or `stale` (a referenced path is gone), and
  closes only `close-candidate`, with the evidence in the reason. The helper is an
  adapter value (`scripts_root` below).
- **User-gated validation.** A session item is validated by the user, never by
  the agent's own reading of the code; work beads are summarized under their item
  and never separately validated.
- **Session log.** Committed history lives at the profile's `session_log_dir`, one
  file per session, profiling the
  [vendored iqa-common contracts](../../references/vendored/iqa-common-contracts.md)
  -> `## Session-log contract`.

## Hub role

**New to the role? Read the on-ramp top to bottom before the first tool call** -
ordered reading, the exact commands for the start receipts, the first tick, the
dispatch contract, the merge-and-prove path, and the traps that have already cost
Hubs a night. The document is the profile's `on_ramp` adapter value
([ADAPTERS](../../core/ADAPTERS.md) -> `## External adapters`); this member is the
contract, that document is the on-ramp. Role router, merge path and labels:
[REFERENCE.md](REFERENCE.md) -> `## Roles`, `## Hub labels`.

### Hub start contract (binding, every Hub-role session)

Claiming the Hub role needs **five printed receipts in one turn** - a promise is
not a receipt: (1) lease `Acquire` + `Status` -> `Live: true` from a persistent
shell; (2) the `HubRegistry.ps1 -Mode Register` result (repo, agent id, machine,
path); (3) `hub-<x>` + `iqa-role=merge` set and the Sub's own `Find` self-verdict
printed; (4) the `paseo_create_heartbeat` **tool result** printed (name, cron,
`expiresAt`); (5) a `new-agent` `hub-watch-<repo>` schedule (`*/15`, cwd = repo)
registered the same turn. Heartbeats have no list surface, so (5) is the only
auditable wake-up. No receipts means the role is **not** assumed: report the gap,
do not drain. Normative table: [REFERENCE.md](REFERENCE.md) ->
`## Hub start contract`.

**Every turn** - prompt reply, dispatch, close-out - ends by running the
`rung_cadence` adapter ([ADAPTERS](../../core/ADAPTERS.md) -> `## External
adapters`) and printing the returned `Rung:` line; a rung firing later than the
gear is recreated in the same turn, never trusted. An unresolvable adapter is
`Rung: cannot-evaluate (<reason>)`, never a guessed cadence.

**A durable dispatch is asserted, never assumed.** Arming a one-shot schedule is
not a dispatch until its record shows an agent: run
`Test-ScheduleDispatch.ps1 -ScheduleId <id>` after arming and at every
check-back. `failed-spawn` (exit 1) or `CANNOT-EVALUATE` (2) means the dispatch
did not happen - recreate the one-shot and write the failed run on the bead;
`pending-fire` (3) means wait and assert again, never report it delivered. Retry
a schedule write through `Invoke-ScheduleRecordWrite.ps1` rather than surfacing
one EPERM as a dead cadence. Contract:
[REFERENCE.md](REFERENCE.md) -> `## Dispatch durability` #11.

**The ladder's states, and what each means here:** `prompt` (an operator prompt
or worker ping just arrived), `dispatched` (a lane was just dispatched, or this
session owns the drain and is woken by pings), `healthy` (lanes running, none
needs attention), `blocked` (nothing runs and every open bead waits on an
operator or owner), `peer-hub` (another advertised Hub holds this repo's drain -
a liveness re-check, never a drain tick), `stand-down` (zero actionable work).
`peer-hub` prints `Rung: none (peer-hub: <peer-agent-short-id> owns <repo>)`, is
**not** a stand-down, and must not delete the standing heartbeat or the
`hub-watch-<repo>` backstop. The 15-minute gear, the definition and the three
corroboration reads: [REFERENCE.md](REFERENCE.md) -> `## Peer Hub (a live Hub
already holds this repo)`. The 15-minute gear, the definition and the three
corroboration reads: [REFERENCE.md](REFERENCE.md) -> `## Peer Hub (a live Hub
already holds this repo)`. `Get-HubCadence.ps1 -State peer-hub` returns that
15-minute liveness rung, so the ladder and the helper agree on every state: print
the ladder's `Rung: none (peer-hub: ...)` line for the drain, and the helper's
`required 15 min` rung as the backstop behind it - never a substituted state.

### Deprecated aliases

`hub-mode` and `hub-watch` are **not** sessions any more; both are absorbed here.
`Hub Mode` / `hub mode` routes to this member - never start a standing Hub session
from the old alias - and `hub-watch` / `hub heartbeat` / `drain the queue` route to
the merge tick in [REFERENCE.md](REFERENCE.md) -> `## Hub heartbeat (self-wake)`.
As part of a Hub **stand-down** - and only then; a `peer-hub` stand-down is not
one and deletes nothing - delete the standing `hub-watch` heartbeat, never leave
a second poll loop running. The batch/lock mechanics library at
`$env:CL_REPOS_ROOT\currents-bookkeeping\Skills\hub-mode\REFERENCE.md` is still
followed, never copied. **Plan-mode guard (mandatory):** if this member is invoked
in Plan mode, do not attempt the transition - advertising as Hub (trunk lease +
`{mode, repo, trunk}` / `hub-<x>` + `iqa-role=merge` labels), merge-tick, dispatch,
merge and deploy all require Build-mode writes. Tell the user verbatim that they
must switch to Build mode, and stop - leave queue rows, beads, leases and labels
untouched.

### Development philosophy (binding - it decides scope, not just style)

Canonical: [REFERENCE.md](REFERENCE.md) -> `## Development philosophy (long form)`
(the fleet skill it mirrors is named in that section). Read it; the Hub enforces
it in every dispatch and every merge verdict.

1. **MVP before roadmap.** The MVP is the product that already exists, made
   correct, isolated, priced and operable - not "the next feature". Anything
   outside that surface is roadmap *even if nearly built*. A dispatch receipt
   names the bucket and, for roadmap, the `roadmap.md` line it serves.
2. **Roadmap work ships dark:** flag off by default, user > org > default,
   unknown key `false`, **404 - never 403 - and an unroutable page** when off. A
   roadmap bead that "completes" without its flag is incomplete: send it back, do
   not merge. Turning one on is an operator act, never a deploy.
3. **Dev deploys continuously; prod is operator-manual** - as are money (prices,
   plans, refunds), prod migrations/RLS/roles, and deleting live data.
4. **"Deployed" is five proofs, in order:** artifact identity -> schema state ->
   surface shape (including 404/401 negatives) -> persisted effect (rows, files,
   signatures, mail read back) -> diff review. `UPDATE_COMPLETE` plus a green
   health check is "stack updated, artifact unverified" - say exactly that.
5. **Quality is evidence, not assertion.** Rows are the evidence, not status
   codes. Reproduction before repair (`4c-bugfix`); never lower a threshold, widen
   a policy or weaken a test to reach green; an equivalent mutant is deleted,
   never `Stryker disable`d; a gate measured under load is not a finding -
   re-measure quiet; mutation stays nightly work.
6. **Buy the cheapest sufficient evidence** (`docs/quality/evidence-tiers.md`):
   contract test -> PGlite -> deployed smoke -> journey -> full suite. A lane stops
   at the cheapest tier that answers its question and says why it climbed; a tier
   that could not run is `cannot-evaluate`, never a pass.
7. **Never invent an approval.** "A worker said it was fine" is not one, and a
   recommendation the operator has not answered is not one.
8. **Lanes are leases; the Hub merges and deploys, lanes never.** Beads first,
   then one detached lane per item set; decisions are grilled once at scope time
   and recorded on the bead (`bd note`), never left in the transcript.

Long form, per-surface guidance and anti-patterns: [REFERENCE.md](REFERENCE.md)
-> `## Development philosophy (long form)`.

### Wave continuity, and grill after recon (binding)

An approved epic is approved for its **whole queue**: a wave lands -> merge ->
prove -> dispatch the next wave **in the same turn**; never ask "shall I
continue?". The only stops are a named operator exception, a red gate the Hub
cannot fix, a missing credential/account, or an irreversible operator-gated act. A
BLOCKED lane is recorded on its bead while the rest of the wave keeps moving; only
an empty queue is a stand-down. On "complete this epic / all these beads", recon
first (graph, repo, live lanes - never memory), then grill the operator in
`grill-me` rounds: recommendation first, at most 10 per round, one dimension each,
every answer recorded with `bd note`.

### Standing grants (binding, operator 2026-11-01)

Two actions are pre-approved and never put back to the operator - **deploy `dev`
freely** after a wave (the surfaces that batch changed: `dev-front`, `dev-back`,
verified by `/api/health`, portal 200 and served bytes) and **sweep dead refs,
branches and worktrees** (merged / patch-equivalent / superseded only; never a
live lane, an unmerged branch with unique work, or a dirty worktree). Prod, money,
legal/compliance sign-off and destructive infrastructure removal keep their gates.

### Red lines

- One merge owner per repo graph. The Hub never merges inline - only a claimed
  detached merge worker merges, under the trunk lock. No blocking test batteries
  in the Hub's own session either: dispatch them and read the report
  ([INVARIANTS](../../core/INVARIANTS.md) -> `## 7. The user never waits`).
- No receipts means not a Hub. Stop the drain, advertise, register, then resume.
- Never end a turn without the rung check and its printed `Rung:` line.
- Workers never run `bd`; only the Hub mints, claims and closes (single writer).
- Never land a SHA the owner did not register (code-freeze rule); **prove a landing
  against the remote, never the checkout.** The landing test
  (`landing_test` adapter: the vendored `vendor/iqa-merge/Test-Landed.ps1`)
  must exit 0 - fresh fetch, ancestor of `origin/<trunk>`, claimed paths present in
  the remote tree - before a row is marked `merged`; `git log -1` in the shared
  trunk checkout is not trunk truth. Detail: [REFERENCE.md](REFERENCE.md) ->
  `## Merge landing proof`.
- **A proven landing closes the merge bead; it never sweeps the worker** - the two
  conditions are separate and core owns both
  ([INVARIANTS](../../core/INVARIANTS.md) -> `## 3. Two-condition sweep`).
- **Never merge past the philosophy gate:** a roadmap bead without its flag, a
  "done" that is a status code instead of a persisted effect, or evidence never
  tied to the change.
- Stage explicit paths only; never `git add -A` / `git commit -a`.
- After a drain that changed skill surfaces, complete the Harness Install until
  `-Verify` is clean ([REFERENCE.md](REFERENCE.md) -> `## Pointer convergence`).

## Reference

Continued in [REFERENCE.md](REFERENCE.md): `## Sub lookup`, `## Triage
procedure`, `## Watch-list format`, `## Changelog`; moved out to stay within the
progressive-disclosure budget (nothing removed): `## Lane suborchestrators`,
`## Work Shape Gate (Hub and Sub)` (mandatory before the first tool call),
`## Procedure` (Step 0 probe, Hub lifecycle, Sub handoff), and the long forms of
the sections above.

Adapters: `scripts_root` defaults to this package's own `vendor/` - the
in-package, vendored copy is the deployment truth, and the fleet path
(`$env:CL_REPOS_ROOT\cl-common\Skills\iqa-merge`) is a **development override
only**. Cite the adapter names, not a path: the rung helper is behind
`rung_cadence`, the landing proof behind `landing_test`
([ADAPTERS](../../core/ADAPTERS.md) -> `## External adapters`, and
`## Vendored helpers (in-package)` for the table and the drift gate
`tools/Sync-VendoredHelpers.ps1 -Check`). The four Hub helpers
(`Test-Landed.ps1`, `HubRegistry.ps1`, `Get-HubCadence.ps1`,
`Invoke-HubProbe.ps1`) and the lease helper are vendored under
`vendor/iqa-merge/` and `vendor/git-operations/`; the legacy `iqa-mode` helpers
are vendored under `vendor/dispatch/`, and the Key family machinery under
`vendor/credential-rescue/` with the fleet tree as its development override. No
symlink, no second copy, no shim stands in for a move. The
repo profile is `profiles/<repo>.md`, filled from
[PROFILE.template](../../core/PROFILE.template.md); a missing slot is
`cannot-evaluate`, never a default.

## Read first

[INVARIANTS](../../core/INVARIANTS.md) · [TASK-MODEL](../../core/TASK-MODEL.md) ·
[ADAPTERS](../../core/ADAPTERS.md) · [PROFILE](../../core/PROFILE.template.md)
