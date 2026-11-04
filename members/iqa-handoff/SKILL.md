---
name: iqa-handoff
description: >
  IQA hand-off member - carries data and context between agents, and decides
  whether a hand-off was actually delivered. Sole owner of the receipt rule: a
  hand-off is delivered only when the receiver acknowledges it, silence is not
  delivery, and a rejection with a reason is a receipt. Use when passing work to
  another agent, when asked whether a hand-off landed, when a sender needs to
  know if its message was received, or when a worker's start receipt is missing.
---

# iqa-handoff

## When to use

Work or context must move from one agent to another, or someone asks "did they
get it?". Not for spawning the worker - that is [dispatch](../dispatch/SKILL.md) -
and not for a QA session's own bookkeeping ([iqa-hub](../iqa-hub/SKILL.md)).

## What this member owns

The hand-off record, the receipt rule, and the start receipt. **This file is the
only place either rule is stated.** Every other surface - core, hub, sub,
dispatch - cites it
([INVARIANTS](../../core/INVARIANTS.md) -> `## 5. Receipts`).

### The receipt rule

A hand-off is **delivered only when the receiver acknowledges receipt**. Sending
is not delivering. A message that was queued, written, pinged, or fired into a
channel with no reply is not delivered - it is `pending-delivery`, and the sender
still owns the follow-up.

- **The receiver acks before starting the work.** The first act of a receiving
  agent is the receipt, not the first step of the task. A receiver that starts
  work silently is undetectable: the sender cannot tell a busy agent from a dead
  one.
- **A receipt is a reply from the receiver**, in the receiver's own channel,
  naming what it received. An automated "message accepted" is transport
  acknowledgement, not a receipt.
- **A rejection with a reason is a receipt.** `rejected` with a reason is
  delivery; it tells the sender to re-plan. Silence is not delivery, with no
  grace period inferred from elapsed time.
- **The timeout is 15 minutes.** An unacked hand-off gets exactly **one** re-ping
  carrying the **same `handoffId`** - never a new record, never a second hand-off -
  and if that is unacked too, it **escalates** to the operator as a reported
  blocker. Escalation is a report, not a re-dispatch.
- **Re-delivery is a new attempt against the same record**, not a new record. The
  record keeps its attempts, so a later reader can see it was tried N times and
  never acknowledged.
- **A hand-off carries data, not backlog.** Anything describing work to do is
  minted as a bead and the record cites the bead id
  ([TASK-MODEL](../../core/TASK-MODEL.md) -> `## Hand-offs are not backlog`).
- **A receipt is not an approval.** Acknowledging that a request arrived grants
  nothing; operator-gated actions still need the operator
  ([INVARIANTS](../../core/INVARIANTS.md) -> `## 8. No invented approvals`).

### The record schema

One record per hand-off, in the durable record the sender writes:

```
handoffId        stable id, minted once and reused by every re-ping attempt
from             sending agent id
to               receiving agent id (or hub label)
beadRef          bead id this hand-off is about, <project>-<n>; required when
                 the hand-off concerns work that already exists
receivedAt       the receiver's ack timestamp; absent means pending-delivery
decision         pending-delivery | adopted | rejected
adopted[]        items the receiver took on
rejected[]       [{ item, reason }] - a rejection without a reason is not a receipt
nextAction       what the receiver will do next, in one line
eta              when the sender should expect the next report
receiptMessageId the transport id of the ack, so the sender can prove it
```

`receivedAt` is the only field that proves delivery. Everything else describes
what was agreed; a record with `decision` and no `receivedAt` is still
`pending-delivery`.

`decision` values:

- `pending-delivery` — no ack has arrived. `receivedAt` is absent, and a
  `receiptMessageId` with no `receivedAt` is a transport acknowledgement, not a
  receipt. The sender owns the follow-up: one re-ping carrying the same
  `handoffId`, then escalation. Never a delivery.
- `adopted` / `rejected` — a receipt exists (`receivedAt` set, and
  `receiptMessageId` where the transport supplies one).

`beadRef` earns its place because ids, not titles, are the citation handle
([TASK-MODEL](../../core/TASK-MODEL.md) -> `## Bead identity`, `## Hand-offs are
not backlog`). A hand-off about new work mints the bead first and cites it here -
the Hub mints, claims and closes, so a worker-sender sends the description to its
parent and cites the id it is given rather than writing the graph itself. A
hand-off of pure context, with no bead behind it, omits the field and says so
in `nextAction`. An absent `beadRef` on a hand-off that does concern existing
work makes the record incomplete — the receiver acks the gap, it does not infer
the bead.

### The start receipt

A dispatched worker's first act is a **start receipt** - one line before its
first step, carrying the agent id, the brief path, and the first intended
action - so a silent worker is detectable in minutes rather than at completion
or death. [dispatch](../dispatch/SKILL.md) requires that it is sent; the shape
above is what it looks like.

### What a receipt is not

- Not a status word. "Got it" without what was received is not a receipt.
- Not a completion ping. The completion ping carries the result
  ([dispatch](../dispatch/SKILL.md) -> `## Rule 3`); the receipt proves the task
  was accepted.
- Not a merge ack. A merge-queue row moving to `merging` with a bead id is the
  hub's ack of a parked branch
  ([iqa-sub](../iqa-sub/SKILL.md)) - the same rule, a different carrier.

## Read first

[INVARIANTS](../../core/INVARIANTS.md) · [TASK-MODEL](../../core/TASK-MODEL.md) ·
[ADAPTERS](../../core/ADAPTERS.md) · [PROFILE](../../core/PROFILE.template.md)
