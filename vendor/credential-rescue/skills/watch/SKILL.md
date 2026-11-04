---
name: watch
description: Runbook — unattended overnight watch for opencode-go key exhaustion. Canary the ACTIVE pool key against a standby every unit of time, cut over only on proven EXHAUSTED, make Paseo use the new key, then send "Continue" to the agents that were running. Use when the operator says "watch the key", "rescue agents overnight", "monitor the key while I sleep", or when a key is near its weekly cap and agents must survive unattended.
triggers:
  - user
  - model
---

Canonical content lives at `interactive-qa-agent/members/key-cutover/SKILL.md`.
