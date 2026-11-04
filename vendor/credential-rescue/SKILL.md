---
name: credential-rescue
description: Credentials Rescue — the fleet plugin for machine-level credential repair. Two tracks off one seam: salmon-run (Salmon-track key cutover for lanes), paseo-rescue (single-entry Repair-Paseo: classify, pin, worker/app restart, verify), plus aws-store restore and the unattended watch (cutover + Paseo repair on EXHAUSTED only). Pick the runbook that matches the symptom and load only that one.
triggers:
  - user
  - model
---

Canonical content lives at `interactive-qa-agent/members/key-cutover/SKILL.md`.
