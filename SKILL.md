---
name: interactive-qa
description: >
  Front door for the Interactive QA plugin - an interactive
  quality-assurance session against a product, with a merge hub, single-unit
  worker lanes, a repo-owned merge queue, hand-off receipts, detached worker
  dispatch, key watch and cutover, and a deterministic progress monitor. Routes
  to exactly one member and nothing else. Use when the user says "IQA",
  "interactive QA", "run a QA session", "hub mode", "sub mode", "work now",
  "watch the key", or asks to test a product interactively.
---

# Interactive QA Agent — front door

Read this file, then read **one** member. This file defines no procedure.

| The work is | Member | Read |
| :--- | :--- | :--- |
| Running the session: intake, QA run and item numbering, triage, close, and owning the merge | `iqa-hub` | [members/iqa-hub/SKILL.md](members/iqa-hub/SKILL.md) |
| Executing one unit of built work on a branch and parking it for the hub | `iqa-sub` | [members/iqa-sub/SKILL.md](members/iqa-sub/SKILL.md) |
| Moving context between agents, or deciding whether a hand-off was delivered | `iqa-handoff` | [members/iqa-handoff/SKILL.md](members/iqa-handoff/SKILL.md) |
| Spawning, briefing, or recovering a worker | `dispatch` | [members/dispatch/SKILL.md](members/dispatch/SKILL.md) |
| Watching credential health while work is running | `key-watch` | [members/key-watch/SKILL.md](members/key-watch/SKILL.md) |
| Moving the fleet onto a replacement credential | `key-cutover` | [members/key-cutover/SKILL.md](members/key-cutover/SKILL.md) |
| Checking whether work is progressing, or waking a stalled Hub | `iqa-monitor` | [members/iqa-monitor/SKILL.md](members/iqa-monitor/SKILL.md) |

All members read the same core:
[INVARIANTS](core/INVARIANTS.md) · [TASK-MODEL](core/TASK-MODEL.md) ·
[ADAPTERS](core/ADAPTERS.md) · [PROFILE template](core/PROFILE.template.md).

If two members both seem to apply, the session owner (the member the user's
words name first) picks; the other becomes its subordinate step. Never load
two members as peers.
