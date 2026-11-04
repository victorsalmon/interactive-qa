---
name: key-check
description: Runbook — deadline-bounded Key Check for the opencode-go pool. Polls the live usage meters, escalates through heartbeat → discover → near when a key approaches its cap, and moves Paseo onto a proven, eligible replacement BEFORE the active key dies, on a fixed wall-clock budget. Use when the operator says "Key Check", "key check", "watch the key", "key usage", or "near exhaustion".
triggers:
  - user
  - model
---

Canonical content lives at `interactive-qa/members/key-watch/SKILL.md`.
