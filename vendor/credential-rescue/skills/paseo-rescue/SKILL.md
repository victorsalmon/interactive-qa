---
name: paseo-rescue
description: Runbook — repair Paseo's opencode credential and daemon via the single-entry Repair-Paseo.ps1 (classify BINARY/NAME/KEY, pin provider env, worker restart with FullApp fallback, verify). Use when Paseo conversations use the OLD key, report "Model not found: opencode/muse-spark-1.3-contributor", or the provider shows Not installed / OpenCode binary not found.
triggers:
  - user
  - model
---

Read and follow `$env:CL_REPOS_ROOT\cl-common\vendor\interactive-qa\members\key-cutover\SKILL.md`.
