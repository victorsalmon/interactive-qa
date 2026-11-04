---
name: iqa-monitor
description: >
  Deterministic supervisor for the primary repos: writes a compact beads-graph
  snapshot only when something changed or a cadence interval has elapsed, raises
  named stall findings when merges, dispatches or closures stop happening, and
  reports completion rate against token burn on demand. Runs as a plain script
  from Windows Task Scheduler - no model, no tokens. Use when asking whether work
  is actually progressing, when a Hub may be idle or dead, when you need a
  beads-graph history or a rate-vs-burn comparison, or when wiring the hourly
  graph log for the primary repos.
triggers:
  - user
  - model
  - iqa monitor
  - work rate
  - is work progressing
  - beads snapshot
  - graph history
  - completion rate
  - token burn rate
---

# IQA monitor — supervision without model calls

The Hub decides; the monitor *notices*. Everything here is deterministic shell
work, so a snapshot costs CPU and nothing else. The only token spend in this
design is a Hub turn that a **finding** causes — and that turn receives one
compact line, not a graph dump.

**Which repos it watches is not decided here.** It reads
`~/.machine/state/primary-repos.json` through `lib/Resolve-PrimaryRepos.ps1`
(see cl-common `Skills/machine-state`). An absent registry is a **named
absence**, never a guessed list.

## Why this shape

| Approach | Per-repo per-read |
| :--- | ---: |
| raw `bd list --json` (20 beads) | ~98 KB (~25k tokens) |
| `bd list --all --brief --json` | ~220 KB, but parsed locally only |
| **one snapshot line** | **~220 B (~55 tokens)** |

A day of history for all primary repos is ~10 KB. Reading a day costs a few
thousand tokens; reading one raw graph costs ~25k.

## Modes

| Mode | Writes | Purpose |
| :--- | :--- | :--- |
| `Snapshot` (default) | `monitor/<repo>.jsonl` + `.latest.json` | write only when the graph changed or the cadence interval elapsed |
| `Check` | `monitor/findings.json` | named stall findings; **exit 1** when any exist |
| `Report` | nothing | completion rate vs token burn over `-ReportHours` |
| `Rollup` | collapses old lines | keep `-RetainDays` raw, fold older into daily rows |
| `Status` | nothing | last write/change/interval per repo |

## Adaptive cadence

A state change always writes. Otherwise the interval follows **activity age**:

| Activity age | Snapshot interval |
| :--- | :--- |
| ≤ 1 h | 15 min |
| ≤ 6 h | 60 min |
| ≤ 24 h | 360 min |
| older | 720 min |

The check still runs every 15 min (it is free); it just declines to write. An
idle repo therefore produces ~1–4 lines a day instead of 24.

## Measured vs assumed

- **Measured:** open/blocked/in-progress/closed counts, trunk sha, lane worktree
  count, and the weekly-quota percentage (tail of
  `~/.machine/logs/keycheck.jsonl`).
- **Assumed:** estimate-minutes. `bd create -e` accepts them, but
  `bd show --list --json` does **not expose** an estimate and no bead carries
  one, so minutes come from the declared priority table
  (P1 120 · P2 60 · P3 30 · P4 15) and every line records
  `"basis":"priority-table"`. `Report` prints that basis with the numbers — a
  rate resting on an assumption must say so.

## Findings

| Code | Condition |
| :--- | :--- |
| `STALL-GRAPH` | unfinished beads exist and the graph has not changed for ≥ 6 h |
| `STALL-MERGE` | lane worktrees exist and the trunk has not moved for ≥ 2 h |

Each finding carries `code`, `repo`, a one-line `detail` and its `evidence`
counts, so a Hub can act without re-reading anything. `Check` exits **1** when
findings exist, **0** when clean.

## Scheduling

```powershell
$script = 'E:\Repos\Public\interactive-qa\tools\Invoke-IqaMonitor.ps1'
Register-ScheduledTask -TaskName 'IQA-Monitor-Snapshot' `
  -Action @(
    New-ScheduledTaskAction -Execute (Get-Command pwsh).Source -Argument "-NoProfile -File `"$script`" -Mode Snapshot",
    New-ScheduledTaskAction -Execute (Get-Command pwsh).Source -Argument "-NoProfile -File `"$script`" -Mode Check") `
  -Trigger (New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 15)) `
  -Settings (New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew)
```

Rollup belongs on a weekly schedule (`-Mode Rollup -RetainDays 7`), not the
15-minute one.

## Deliberately not done yet

**Waking a Hub.** The findings contract is complete, but *delivering* a wake
needs the live Hub's agent id (from `HubRegistry -Mode Find`) and a verified
non-interactive send. Until that is wired, the monitor writes `findings.json`
and exits non-zero — a supervisor, not yet an alarm. Do not fake the wake: a
finding nobody receives is worse than a finding on disk, because it looks
handled.
