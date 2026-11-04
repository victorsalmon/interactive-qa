---
name: iqa-sub
description: >
  IQA sub member - executes one unit of built work on its own branch in its own
  worktree, then parks the branch queued for the hub and optionally watches the
  queue until it merges. Never merges, never deploys, never cleans up, never
  sweeps. Use when the user says "sub mode", "IQA Sub Mode", "watch the queue",
  "sub watch", "wait for Hub", or when a hub assigns one bead to one lane.
---

# iqa-sub

## When to use

Exactly one unit of work has been assigned to this lane: the lane builds it,
pushes the branch, enqueues it for the hub, and stops - or, when asked to wait,
watches the queue until the merge lands. Not for planning a session
([iqa-hub](../iqa-hub/SKILL.md)), and not for deciding whether the hand-off
arrived ([iqa-handoff](../iqa-handoff/SKILL.md)).

> **Reconstructed body.** `sub-mode` and `sub-watch` lived only in
> `currents-bookkeeping/Skills/` and are foreign-anchored pointers from this
> repo. Their text was **not moved**; this member is written from those two
> skills' descriptions plus the Sub half of the former `iqa-merge`, generalized
> so a non-SaaS repo fits the same contract. The originals stay in their repo
> untouched; the cross-harness pointers now resolve here.

## What this member owns

- **One bead, one branch, one worktree.** The branch is the deliverable; the
  report says where it is and what proves it.
- **Staying inside the lane.** No merge, no deploy, no trunk write, no branch or
  worktree cleanup, no sweep of anything - those belong to the hub, and doing
  them here is how two writers end up in one trunk
  ([INVARIANTS](../../core/INVARIANTS.md) -> `## 4. One writer per worktree`).
- **Parking, not waiting.** When the branch is ready the lane reports it queued.
  Waiting on the merge is **opt-in**; the default is to finish, because the hub
  cuts follow-up beads from the lane's `needs:` list and actions them itself.
- **Blockers in the two buckets that matter**: an operator action (`manual`) or
  an operator decision (`needs-decision`) - reported, never waited on.

## The Sub contract

Run the completion checklist's build steps normally - trunk resolve -> branch ->
work -> verify -> push -> park. Its merge, deploy and cleanup steps are
**forbidden** in this member: the hub owns them.

Order inside the park is load-bearing:

1. **Freeze.** `git status --short`, `git branch --show-current`,
   `git log --oneline -5`, `git diff --stat`, ahead/behind of the trunk. No
   further edits to the branch after this point.
2. **Push the branch** to `origin`. This backs the work up and lets CI see it.
3. **Enqueue** the frozen SHA as one merge-queue row - repo, branch, SHA,
   worktree, `--owner <this agent's id>` so the hub can join rows to live lanes,
   `--base <trunk>`. The note carries the complete instructions: the evidence
   actually run, one `needs:` line per piece of residual work, and the return
   contact. A vague note mints nothing; the hub relays it back as a question.
4. **Ring the doorbell**: one `MERGE-READY <branch> @ <sha>` prompt to the live
   hub, plus the `needs:` list. The ping is a doorbell - the queue row is truth.
   No resend loops.
5. **Stop**, unless the operator asked for a watch (below).

**Done means queued.** A lane is not done until its row exists, the branch is
pushed, and the `needs:` list is declared - even when it says `none`. Die
mid-work and the push backs you up; die after enqueue and the row routes to any
hub, present or future. Never report completion with the row missing: an
unqueued branch is invisible to every hub.

**Code freeze.** After enqueue, no more commits on that branch. Further work
means a new SHA and a re-enqueue - which supersedes the old row rather than
replacing it.

**Never touch the trunk checkout.** Never merge, never move it, never run gates
in it. All work stays in the lane's own `.worktrees/<name>` checkout.

**Rescue.** If the hub marks the row `rescue`, the lane has a head start, not a
veto: rebase onto the current trunk, re-run the same gates, re-register the fresh
SHA and ping `MERGE-READY` again. If the fresh row exists at the next hub poll
the hub takes it; otherwise the hub adopts the rebase itself and lands it. Either
way the work lands; rebasing first just keeps the rebase yours.

**Ping before the row, and the row is truth.** A `MERGE-READY` that arrives while
the row does not exist yet is a doorbell to nowhere. Enqueue first, verify with a
`list` read, then ping.

## Park report

`Status: Parked for hub - <branch> @ <sha> pushed, queued`, plus the report
artefact written at the path the brief names, with every gate and its exit code.
Do not report a subset as green.

## The watch (opt-in: "watch the queue", "sub watch", "park and watch")

One watch per parked branch, one round every 5 minutes, read-only, from the
lane's own checkout. The watch **never** merges, deploys, touches the trunk
checkout, or edits foreign work - it observes, maintains queue truth, and
escalates.

Each round runs the same probes, in order:

1. **Trunk:** fetch; record the trunk tip SHA and subject.
2. **Queue:** read the lane's own row (`queued` / `merging` / `merged` /
   `dropped`) and whether any hub batch worktree moved.
3. **Merge proof:** is the frozen SHA an ancestor of `origin/<trunk>`? Exit 0
   means merged - verify and stop.
4. **Drop check:** a `dropped` row means one Sub-legal repair that round - verify
   the drop reason against evidence, then either re-enqueue the same SHA with the
   counter-evidence, or re-cut (rebase, re-verify, push) and re-enqueue on the
   new SHA.

One line per round: `R<n> tip=<sha7> merged=<0|1> q=<status> drop=<bool>`. No
other output unless a verdict fires.

- **Doorbell re-ring** when the row has been `queued` with no batch movement for
  **6 consecutive rounds (~30 min)** AND the hub looks dead (no live hub answer;
  a `merging` row younger than 30 min counts as alive). One ping per 6-round
  window - never a resend loop.
- **Urgent** after **12 consecutive queued rounds (~60 min)**: re-enqueue the same
  SHA with `--urgent` and a note stating the wait and why it is time-sensitive.
  Urgency is per-enqueue and never inherited. A second escalation goes to the
  operator as a hand-off line, not a third queue write.
- **Stop** on merged (verified), operator recall, a re-cut (which restarts the
  loop on the new SHA), or trunk-side evidence the branch is obsolete - then
  report; never self-delete, the hub owns cleanup.

**The chain to the hub is a hand-off, so a ping is not a delivery.** The lane does
not treat its own ping as proof the hub received it; the row's `merging` state
with a bead id is the ack, and an unacked row is reported as unacknowledged, never
archived ([iqa-handoff](../iqa-handoff/SKILL.md)).

## Read first

[INVARIANTS](../../core/INVARIANTS.md) · [TASK-MODEL](../../core/TASK-MODEL.md) ·
[ADAPTERS](../../core/ADAPTERS.md) · [PROFILE](../../core/PROFILE.template.md)
