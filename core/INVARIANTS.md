# Core invariants

The shared rules of every member. Each rule is stated **once, here**. A member
that needs one cites it by number and adds only what is specific to that member.
If a member contradicts this file, this file wins.

## 1. Prove, don't assert

A claim is evidence or it is not made. "Done", "landed", "clean" and "passing"
are conclusions, never inputs: derive them from an artefact that another agent
can re-run — a landing test, a re-derived count, a content diff, a fetched page.
A number in a report is either recomputed in that session or labelled
`copied from <where>`. Enforced today by the landing test (`landing_test`
adapter; vendored at `vendor/iqa-merge/Test-Landed.ps1`); the contract is stated in
[core/TASK-MODEL.md](TASK-MODEL.md) → `## Closing a unit of work`.

## 2. A gate that cannot pass is a defect

A gate that cannot pass on a clean checkout is a defect to record, own and fix —
never a baseline to normalise. "Known red", "pre-existing" and "passes
elsewhere" are defect reports. When a gate genuinely cannot run, it is
*skipped-with-waiver*: visible, non-blocking, carrying its reason. An absent
input produces a named `cannot-evaluate`, never a silent pass — a false green is
worse than a red, because it is trusted.

Corollary: greening a gate by supplying the exact values it compares is
silencing. Fix the software, then the artefact producer, then the gate; never
delete, disable or exempt the check.

## 3. Two-condition sweep

Two separate conditions, never merged into one tick:

1. **Landing** closes the merge bead — proven by the landing test, on the trunk.
2. **Sweeping** the source worktree and branch additionally requires the owning
   worker to be **terminal**: a completion ping, or the ping-timeout elapsed with
   the worker idle/parked and its done file present.

A branch whose bead is closed but whose worker is still running is not
sweepable. A worker that is terminal but whose landing is unproven is not
sweepable either. Normative detail in
[members/iqa-hub/REFERENCE.md](../members/iqa-hub/REFERENCE.md) -> `## Merge
landing proof`.

## 4. One writer per worktree

One process writes a checkout at a time. Additional work goes in
`.worktrees/<name>`; a trunk lock is not a licence to write the trunk from a
second process, it is permission for *this* one to hold it while it writes.
Foreign uncommitted work is inviolable: no reset, checkout, clean or stash-drop
over it. Stage explicit paths only — never `git add -A` in a shared tree.

## 5. Receipts

Receipts — a hand-off is delivered only when the receiver acknowledges; see
[members/iqa-handoff](../members/iqa-handoff/SKILL.md).

## 6. Secrets by shape

Never print a value. Name the field, show its length or a fingerprint prefix,
and compare by hash. Mask by value shape, not by field name: a key named
`username` can itself be the credential. A printed value is a logged disclosure
and triggers a rotation recommendation — and is recorded as such in the
credential-change log, not quietly retried.

## 7. The user never waits

The interactive agent stays with the user. A blocked branch — a failed worker, a
missing secret, an unavailable pool, a permission gate — is **isolated and
reported** while every other branch continues. It is never a reason to stall the
session, and never a TODO the session will do inline later. What the user must
decide is asked once, in a batch, recommendation first.

Corollaries, binding on every member:

- **Orchestrator, not worker.** A session does not edit product code, skills,
  docs or tests, run a test or mutation battery, or take a long investigation
  pass inline. It dispatches them and reads the report. A worker's context is
  disposable; the session's stays free for the user. "Fix this", "update the
  skill" and "run the QA battery" are dispatches, not TODOs.
- **Detached only.** Workers are spawned detached by default
  ([dispatch](../members/dispatch/SKILL.md)); an attached run blocks the chat and
  needs an explicit operator ask.
- **The session's own commands are answered by the session, never delegated** —
  configuration, catch-up, the validate list, "mark validated", and close
  ([iqa-hub](../members/iqa-hub/SKILL.md) -> `## QA mode`). Everything else
  execution-shaped is dispatched.

## 8. No invented approvals

Money-moving, production-mutating, legal, destructive and cross-repo actions are
operator-gated. An approval exists when the operator gave it, for that action,
in this session. It cannot be inferred from a prior approval, from a plan that
describes the action, or from silence. A gate that is waiting is reported as
waiting.
