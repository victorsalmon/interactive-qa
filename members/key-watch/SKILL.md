---
name: key-watch
description: >
  IQA key-watch member — keeps workers alive while nobody is watching the meter,
  by canarying the working credential against a proven replacement on a cadence
  and cutting over before the cap is hit. Owns the cadence, the trigger, the
  resume set and the watch log, and carries the deadline-bounded Key Check. Use
  when asked to watch the key, to rescue agents overnight, to run a Key Check, to
  monitor credential health, or when a lane dies on a usage-limit error.
---

# key-watch

## When to use

Work will be running unattended long enough that the working credential may run
out, or an agent has already died on a usage-limit error and the question is
whether the rest will survive. Also when the operator says "Key Check" — the
deadline-bounded form of the same watch, carried in § Key Check below. Not when
the replacement decision is already made — that is
[key-cutover](../key-cutover/SKILL.md).

## What this member owns

- **The cadence**: one canary per unit of time, against both the active
  credential and a proven standby. A watch that only tests the active one
  discovers the outage at the worst moment.
- **The trigger**: cutover fires on *proven exhaustion* of the active
  credential — never on a near-miss, a hunch, or a single transient error. A
  near-miss is a warning, reported, not an action.
- **The watch's scope**: which workers were running before, and which must be
  resumed after a cutover. Resuming the wrong set (including the ones that
  already finished) invents work and hides the real gap.
- **The log**: every canary and every cutover decision, so "what happened
  overnight" is answerable from evidence rather than memory.
- **Secrets discipline**: watch and report by field name, length and fingerprint
  only — never a value (Invariant 6).

The watch does not *perform* the cutover procedure; it decides that a cutover is
due and hands it to [key-cutover](../key-cutover/SKILL.md), which owns the seam.

## Where the scripts live (an adapter value)

`scripts_root` = **`<package>/vendor/credential-rescue/scripts`** — in-package by
default, where `<package>` is the directory holding this plugin's `SKILL.md`. The
package ships the whole Key family there (the watch driver, the canaries, the Key
Check entry points and their dot-sourced `scripts/lib/`), so every command in this
member resolves without a `Skills/` tree anywhere on the machine.

The fleet path `$env:CL_REPOS_ROOT\cl-common\Skills\credential-rescue` is a
**development override** supplied by the profile's `scripts_root` — never the
requirement. It exists on this box because a live Key Watch runs from the fleet
tree; when the profile supplies it, substitute it for
`<package>/vendor/credential-rescue` below, and let
`tools/Sync-VendoredHelpers.ps1 -Check` prove the two are the same files.

State follows the same rule as [key-cutover](../key-cutover/SKILL.md): a **read**
(a canary, a meter poll) is meaningful as of the last sync, and a **write** that
moves a credential takes the machine's seam — the profile's `seam_path`, or
`-SeamPath <file>`. No `seam_path` means a write is `cannot-evaluate`: report it,
never default it.

## The watch — unattended key-exhaustion rescue

A **watch mode** layered on [key-cutover](../key-cutover/SKILL.md).
That skill is the *repair* (how to cut over and restore); this skill is the
*monitor*: it sits in a loop testing the active key against a standby key, and
fires the repair automatically the moment the active key dies — then revives the
agents that were running on it. Built for the overnight case: the operator
starts it, sleeps, and wakes to agents that survived a key exhaustion.

**Secrets by shape — Invariant 6.** Key/profile NAMES only. Every credential change
this skill triggers goes through `Switch-OpencodeGoKey.ps1`, which appends the
mandatory line to `$env:CL_REPOS_ROOT\Tasks\Logs\credential-changes.jsonl`. This skill
also logs its own watch timeline (see § Logging).

### When it fires

The active key is near its weekly cap and agents are mid-run; a cutover cannot
wait for a human. Symptoms that justify starting a watch: the weekly-cap error
`Go usage limit exceeded` / `Weekly usage limit reached. Resets in N days` in
the profile's `provider_log` adapter (the harness log — `cannot-evaluate` when
the profile names no readable path), `rate_limit_exceeded` on a live
helper, or the operator saying "watch the key overnight / rescue the agents while
I sleep". This is NOT for a *binary missing* failure (that is credential-rescue
Runbook C), NOT for the built-in `opencode` (zen) provider's workspace-balance
error, and NOT for transient `BUSY` errors (retry — see the taxonomy below).

### The loop (operator contract)

The runbook below is exactly what the watch session does. Scripts live in
`vendor/credential-rescue/scripts/` under this package's root.

#### 1. Familiarize + snapshot

- Read [key-cutover](../key-cutover/SKILL.md) and its
  `REFERENCE.md` § Runbook A (the cutover this skill automates). Know the pool
  layout (`OPENCODE_GO1..5_KEY` Machine vars; `OPENCODE_GO_KEY` +
  `OPENCODE_API_KEY` User; live `auth.json` at `$env:XDG_DATA_HOME`).
- Snapshot the running agents with the Paseo MCP: `paseo_list_agents`
  (`statuses: ["running"]`). Record each agent's **id, title, cwd**. This set is
  the "before" cohort that may need a `Continue` nudge after a rescue.
- Resolve which pool key is active: compare `OPENCODE_GO_KEY` (User) against
  each `OPENCODE_GO<n>_KEY` (Machine); the match is the active index. Compare
  only, never print values.

#### 2. Test both keys

- `vendor/credential-rescue/scripts/Test-GoKey.ps1 -KeyNumber <active>` and
  `-KeyNumber <new>`. Both must answer (exit 0) before the loop starts. If the new
  key is dead there is no safe target — abort and tell the operator.
  `Test-GoKey.ps1` is the real script (the package ships it, it is not a
  forwarder); its CLI invocation and result contract are owned there, never
  duplicated here.

> **Never trust a remembered key status.** Pool health is *transient*: a key's
> weekly cap resets, a monthly subscription term lapses or renews, a new key is
> bought — all on a monthly-or-faster cadence. Do NOT record or rely on any
> key's status as a stable fact. **Ascertain it at run time** by canarying each
> key (`Test-GoKey.ps1`). The only durable facts are the *pool layout* (var
> names, roles) and the *error taxonomy* below.

#### Loop — steps 3-5

Run `vendor/credential-rescue/scripts/Invoke-CredentialRescueWatch.ps1 -ActiveKeyNumber <active>
-NewKeyNumber <new>` (defaults: 3 -> 2, interval 3600s). It implements:

- **3. Wait one unit** (default 3600s; `-IntervalSeconds`).
- **4. Re-test both keys.**
- **5a. Old key failed** → run the rescue: cut over with
  `Switch-OpencodeGoKey.ps1 -KeyNumber <new>` (automates REFERENCE Runbook A —
  env repoint, auth.json, session hygiene, canary set, credential log), then
  restart Paseo, then re-canary the new key.
- **5b. Both still work** → return to step 3 and wait another unit.

The script exits **0** on a completed rescue, **2** if the new key is unusable,
**3** if both keys are dead, **4** if the cutover happened but the post-check or
Paseo restart was imperfect. On a `0` exit the *session* finishes steps 6-8.



### Reference

Continued in `vendor/credential-rescue/skills/watch/REFERENCE.md`, starting at:

- `#### Exhaustion criteria — evidence, not guesswork`
- `### Choosing the standby key — health is not enough`
- `### The error taxonomy (durable)`
- `### 6. Make sure the old agents switched to the new key`
- `### 7. Send "Continue" to survivors`
- `### 8. Record and log everything`
- `## Run record`
- `## Scripts`
- `## Approval boundaries (inherited)`

## Key Check — the deadline-bounded rescue

Key Check sits between `watch` (canary-driven, cut over on proven `EXHAUSTED`)
and an operator reading the Console. It watches the **usage meters** and moves
early: a key is replaced while it still answers, so no agent dies first.

```powershell
pwsh -File <package>/vendor/credential-rescue/scripts/Invoke-KeyCheck.ps1 -IntervalMinutes 15 -DurationHours 2   # Key Check
pwsh -File <package>/vendor/credential-rescue/scripts/Invoke-KeyCheck.ps1 -IntervalMinutes 30                    # Key Check 30
pwsh -File <package>/vendor/credential-rescue/scripts/Invoke-KeyCheck.ps1 -IntervalMinutes 30 -DurationHours 4   # Key Check 30 4
pwsh -File <package>/vendor/credential-rescue/scripts/Invoke-KeyCheck.ps1 -DryRun -IntervalMinutes 1 -DurationHours 0.02 -Json
```

Defaults are **15 minutes / 2 hours**. Invalid input exits **2** with the
grammar, and so does a second run that finds another live run holding the lock.
The duration is wall-clock from start and **escalation never extends or
resets it** — a cutover keeps the same deadline and only `generation`
increments. An interrupted run **resumes** the same deadline rather than
starting a fresh window.

A watch also **does not simply end at its deadline**: it arms a successor, and
`Test-KeyCheckLiveness.ps1` is the standing supervisor that asserts one exists
(§ The successor arm, below).

### Phases

| Phase | Cadence | What it does |
| :-- | :-- | :-- |
| `initial` | once | Poll **all** keys, write wk+mo into the freshness ledger, resolve the in-use key by hashing every `OPENCODE_GO<n>_KEY` (Machine **and** User, seam `activeKey` as fallback), report ProviderLock drift without acting on it, canary the active key, fix the deadline, then evaluate imminent → near-exhaustion → heartbeat. An in-use value that no pool key and no seam `activeKey` can resolve **ends the run at once** (exit **1**, `active-key-unresolved`) instead of polling blindly. |
| `heartbeat` | adaptive (base gear, ≤ 60 min) | Poll the **active key only**. wk ≥ 80 **or** mo ≥ 90 → `discover`. |
| `discover` | once | **One** census read — the same reader `initial` uses. Replacement = eligible key with the soonest monthly reset, proven by `Test-GoKey.ps1` before it is armed (a failed proof tries the next candidate). The phase line and audit row name the armed key, **both** meters, and the monthly reset that ranked it. When nothing qualifies, every candidate is named with the rule that excluded it (`active-key`, `rate-limited`, `weekly>=80`, `monthly>=90`, `meter-not-reported`, `usage-FORBIDDEN`, `usage-HTTP500`, `usage-REVOKED`…). A census that yields no reading ends the run as `cannot-evaluate`, never as "no eligible replacement". Then `near`. |
| `near` | adaptive, **≤ 15 min** | Poll the active key only, on the same burn-derived gear with a 15-minute ceiling (1-minute floor). wk > 96 **or** mo > 98 → `trigger`; a rate-limited read triggers only on the **second consecutive** one. Two consecutive readings with wk < 70 **and** mo < 80 disarm back to `heartbeat`. Deadline → end. |
| `trigger` | once | active == replacement → no-op. Else re-prove, then **delegate**: create `vendor/credential-rescue/scripts/Invoke-KeyCheckCutover.ps1` **outside this process tree** and poll its outcome file. The helper runs the Salmon switch, then the Paseo repair, then verifies three surfaces. `applied` + `verified` → record the exhausted key's final reading, reset thresholds, **keep the deadline**, `generation++`, back to `near`. `applied=false` → end **4**. `applied` but a surface disagrees (or no outcome inside `-CutoverTimeoutMinutes`) → end **5**. |

### First automated rescue (2026-11-02)

The command's end-to-end proof, measured on this host, runId `20261102-172700`:

- **19:35:10** — GO6 at **97 % weekly**; the watch fired `trigger` as `imminent`.
- The helper launched through `Win32_Process.Create` (pid 39448) and wrote the
  **pending** outcome at **19:35:38** *before* the restart, then switched
  GO6 → GO3.
- Ranking line: `eligible: GO3, GO1` — GO3's monthly resets **11/20**, GO1's
  **11/23**, so GO3 ranked first (§ Eligibility and ranking).
- The helper's own outcome ended `applied=true, verified=true,
  restartPending=false`.
- `Invoke-KeyCheckWitness.ps1` independently reported
  **`verified-by-witness`**: seam `GO3`, User `GO3`, Paseo pin `GO3`, daemon
  alive.

This is the evidence that the command works **end to end**, not merely that it
ran: the destructive step came last, the pending outcome existed before it, and
a separate process reading the three surfaces agreed with the helper. Bead
`zqn` acceptance is satisfied by it.

The one failure of the run was the roster nudge skipping the `cl-common` Hub —
see `../iqa-hub/REFERENCE.md` § Dispatch durability traps 8–9 (code bead
`qz8`).

### Adaptive cadence (measured burn, not a guess)

Both polling phases run the **same gear**, derived from how fast the active key
is actually burning toward its trigger. The phases differ only by a ceiling:

| `ettMinutes` | Tick interval |
| :-- | :-- |
| > 240 | 60 min (the `heartbeat` ceiling) |
| 120–240 | 30 min |
| 60–120 | 15 min |
| 20–60 | 5 min |
| < 20 | 1 min |

- `remaining` = points left to the **binding** trigger, `min(96 − wk, 98 − mo)`,
  over the meters that are actually reported, **clamped at zero per meter**. An
  unreported meter is **not** 0 %; a **crossed** trigger leaves zero headroom,
  never a negative one — `ETT 0` selects the 1-minute floor for that reading,
  which is exactly right at the instant the trigger is crossed (`cl-common-8yq`
  used to audit `ETT −8.11`, `remaining −1`).
- `burnPerMinute` = `(current − oldestSampleInWindow) / windowMinutes`, read from
  a bounded **sample history** in the state file (`cadenceSamples[]`, 12 entries of
  `{ at, wk, mo }`), so a resumed run keeps its history. `ettMinutes`
  (**E**stimated **T**ime to **T**rigger, in **minutes**) = `remaining /
  burnPerMinute`, and is **null** — never infinity, never a sentinel — only when
  there is no second sample at all. It is never negative.
- **The window is a history, not "the previous poll".** Measuring against the
  previous poll starved ETT by construction: once the gear reached 5 minutes (or
  the 1-minute floor) two consecutive polls were *closer* than the 15-minute
  guard, so a qualifying pair never formed, ETT stayed null for the rest of the
  run, and the gear froze — it could not tighten toward the trigger and could not
  loosen when the burn stopped (`cl-common-6yr`). The burn is now measured from
  the **oldest sample in the ring that is at least 15 minutes old**
  (`window-15m`); with a younger history the oldest available sample is used and
  the reason says `window-short`.
- **`heartbeat` ceiling: 60 min** — a quiet key is checked hourly. The ladder is
  bounded by the **phase ceiling, not the run's interval**, so a run started with
  `Key Check 15` still reaches 60 minutes once its measured ETT says hours.
- **`near` ceiling: 15 min** — a key already inside the escalation band is never
  left unlooked-at for more than a quarter hour. The old fixed 120 s poll was a
  guess that cost ~30 reads an hour for a number that moves once an hour;
  measured burn is the better signal, and the ceiling expresses "never let a near
  key go unlooked-at for more than 15 minutes".
- **Floor: 1 min**, in both phases — nothing polls faster, ever.
- **`heartbeat` re-derives from ETT on every tick**, in both directions: a
  measured ETT of hours reaches the top gear on the tick that measured it. Holding
  the fast gear for a two-tick "loosen-pending" wait is what turned one rescue
  into 60× the intended reads (`cl-common-8yq`: `ETT 488.7`, gear `1m`, against a
  key 5 % used). `near` keeps the anti-flap rule: a faster gear applies at once, a
  slower one needs **two consecutive** better ticks.
- **Guards**: no gear until a second sample exists (one sample → `ettMinutes` null,
  previous gear retained) — but a keep path never holds a gear **faster** than the
  last measured ETT implies (`…/ett-held`, `heartbeat` only); a flat window keeps
  the gear on the first tick and can loosen only after **two consecutive** flat
  ticks (a flat reading is not "0 % burn"); a meter whose `resetsAt` changed — or
  whose window reset between samples, or that went backwards — has its burn
  discarded for one tick and **clears the ring**; the number of 1-minute ticks per
  run is capped (default 20) and then the cadence holds at 5 min with
  `cadence-floor-cap`.
- **A rescue is a new meter** (`generation++`): the ring, the burn and the ETT are
  discarded with the old key, the gear returns to the **post-cutover phase
  ceiling** (`near` 900 s), the per-key loosen streak and 1-minute budget restart,
  and the change is recorded as `generation-reset/phase-near-ceiling`. The next
  tick re-derives from measured burn and tightens as the new key burns. A fresh
  key at 5 % is never polled every minute, and the one-time ring seed is skipped
  when the persisted `lastReading` belongs to a **different** key, so a
  `97 → 5` delta across keys can never be read as a burn.

The choice is a **pure function** — `Get-KeyCheckCadenceGear` in
`vendor/credential-rescue/scripts/lib/KeyCheck.Decision.ps1` — so it is tested with a fixed clock and no
network, and `-IntervalMinutes` keeps its meaning as the **base** gear (capped at
60 min): the gear a run starts on before any burn is measured, and the
flat-window loosening target. A gear change is the only thing written to the
audit trail
(`{"kind":"cadence", runId, at, phase, fromSeconds, toSeconds, burnPerMinute,
ettMinutes, remaining, reason}` — one line per transition, never per tick) and to
`cadenceChanges[]` in the state file. `reason` names the transition **and** the
window it was measured over (`tightened/window-15m`, `loosened/window-15m`,
`gear-unchanged/window-short`, `loosen-pending/window-15m`,
`generation-reset/phase-near-ceiling`, …), so a reader can tell a real burn from a
provisional one, and the seconds, the ETT and the reason are on the same line. A
state written before the rename stores
the trigger distance in **hours**; it is converted once on read (`× 60` →
`ettMinutes`) and the old field is dropped on the next write, so a resumed run
keeps the gear it earned.

#### Loop shape — read then sleep, and wrap the whole `if`

Both were `cl-common-79y`; they are fixed in `Invoke-KeyCheck.ps1` and
`KeyCheck.State.ps1` and recorded here so a rewrite does not reintroduce them:

- **The first reading is at t≈0, and the cadence goes between readings.** A loop
  that sleeps a full interval before its first read never reads at all when the
  process is restarted more often than the gear — exactly the case a near key
  creates. Measure, then sleep.
- **`@()` wraps the whole `if`, not each branch.** `$x = if (c) { @(...) } else
  { @() }` unrolls a one-element array to a scalar, so a later `$x += …` throws
  `op_Addition` — and only while the collection holds exactly one element, which
  is why the watch crashed at its first gear transition and not at start. Write
  `$x = @(if (c) { … } else { })`.

### One run per machine (the lock)

Two watches on one machine each read the same state, both see the same
threshold crossing, and both cut over — the second `Repair-Paseo` restarts Paseo
underneath the first. So a run takes a lock at
`~/.machine/state/key-check/lock.json`:

```json
{ "pid": 12345, "host": "BOX", "runId": "20261102-152559",
  "startedAt": "2026-11-02T15:25:59.7945249-07:00",
  "heartbeatAt": "2026-11-02T15:40:12.0011223-07:00" }
```

- A second live run exits **2** with `locked-by-run` and prints the holder's
  `runId`, pid and age. It writes **no** run state.
- A lock is **stale** when its pid is dead **or** its heartbeat is older than
  three poll intervals. A stale lock is taken over and audited
  (`lock-stale-taken-over`, naming the previous holder) — that is how a crashed
  or rebooted run is recovered without a human.
- `-Force` steals a live lock deliberately, and the audit says `lock-forced`.
- `-DryRun` **never** takes the lock: a rehearsal must not block the real watch.
  It also never writes the live `state.json`, `lock.json` or `keycheck.jsonl`
  (see § *Dry run — a probe, never the live run*).
- A normal exit releases the lock. A hard kill cannot, so the next run waits for
  the staleness window (or takes `-Force`).

**To clear a lock deliberately:** confirm no Key Check process is running
(`Get-Process pwsh` plus the audit trail), then delete
`~/.machine/state/key-check/lock.json`, or re-run with `-Force`. Never delete it
while a run is alive — that reintroduces the double-cutover defect.

### Resume: the deadline is never extended

State is persisted to `~/.machine/state/key-check/state.json` after **every**
check, so an interruption — a reboot, an operator `Ctrl-C`, or the `paseo
restart` the cutover itself causes — does not lose the run:

```json
{ "runId": "20261102-152559", "startedAt": "…", "deadlineAt": "…",
  "phase": "near", "generation": 1, "replacementKey": 3,
  "consecutiveRateLimited": 0, "consecutiveCannotEvaluate": 0,
  "consecutiveBelowThreshold": 1, "armed": true,
  "lastCheckAt": "…", "lastResult": "near (watching)" }
```

On start:

| What the state says | What the run does |
| :-- | :-- |
| no state, or the previous run ended | start a new run with a new `runId` and a new deadline |
| deadline still ahead | **resume** the same `runId`, keep the **original** `deadlineAt`, continue at the saved phase, and audit `resumed` |
| deadline already passed, nothing ran | end immediately as **`window-expired-while-down`** (exit **0**, audited). No fresh window is invented — that would extend the deadline. |
| a **verified** cutover outcome was written while the run was down | resume in `near` at `generation + 1`, on the key the helper proved |
| a **`restartPending` / `verified: 'pending'`** outcome was written while the run was down | the helper applied the switch and was stopped before its post-restart verification. The next run **finishes the check**: seam, User key and Paseo pin are re-derived; a match upgrades the outcome to `verified` on disk and continues in `near` at `generation + 1`, a mismatch ends **4** `cutover-failed`. A pending outcome is **never** success. |
| an outcome says the cutover failed | end **4** `cutover-failed`; applied-but-unverified ends **5** `cutover-unproven` |
| phase `trigger` with **no** outcome file | the helper may have been killed mid-flight with a **partial switch** (seam moved, repair never ran). It resumes into `initial` and re-resolves the active key from the machine (`resumed-unverified-cutover`) instead of trusting the file. |

### Fail fast, don't wait out the clock

| Condition | Ending | Exit |
| :-- | :-- | :-- |
| the active key cannot be resolved at `initial` | `active-key-unresolved` | **1** |
| three **consecutive** usage reads produce no reading | `meter-unreadable` | **1** |
| a census read yields nothing during `discover` | `cannot-evaluate` | **1** |

Two unreadable reads never end the run, and one never does. An unreadable read
neither proves the key healthy nor resets a tolerance streak.


### The cutover is delegated, never performed in-process

The Paseo repair runs `paseo restart`, which ends **every** Paseo-hosted
session — including the Key Check session that asked for the rescue. A watch
that repaired in-process would kill itself at the moment it succeeded: no exit
code, no `endedAt`, no proof, no report.

So `trigger` starts `vendor/credential-rescue/scripts/Invoke-KeyCheckCutover.ps1` and polls its outcome
file. The helper writes that outcome **before** the repair runs — `-OutcomePath`
(default `~/.machine/state/key-check/<runId>-cutover.json`) carries `applied`,
`verified`, `restartPending`, each step's exit code, the surfaces checked so
far, `at` and `runId` — so the evidence exists **whether or not** the helper
outlives the restart. Survivability is environment-dependent and is not relied
upon; the ordering is what makes the rescue recoverable.

#### The cutover does not depend on the helper surviving

**What is established, and what is not.** `vendor/credential-rescue/scripts/Test-KeyCheckDetachment.ps1`
reports `survives` and the mechanism **in the chain it ran in** — nothing more.
On this host (2026-11-02) **both** mechanisms survived a force-killed launcher,
from a plain shell and from the agent-hosted chain alike. So survivability is
**environment-dependent and unproven for a real `paseo restart`**; an earlier
claim that a `Start-Process` child dies with its parent was retracted — the
kill in that experiment hit a launcher that had already exited, so it proved
nothing. Do not restore it as a measurement.

CIM is still the **default**, for a structural reason rather than a measured
one: `Win32_Process.Create` is created by the WMI provider, so it is not a
member of the caller's job object *by construction*, whereas a `Start-Process`
child may inherit job membership. That is a design argument; treat it as one.

**The load-bearing property is Option 1, not the launch mechanism.** The helper
writes its outcome **before** the restart, so a helper that dies is recoverable:
the next invocation reads `restartPending` and finishes the verification. That
is why a failed CIM launch is exit **4** (`cutover-failed`) with an audit
`launch` line — loud, not silently degraded — and why `-AllowProcessFallback`
plus the pre-restart outcome is still **safe**: slower to prove, not wrong.

Options considered, in order:

| Option | Status |
| :-- | :-- |
| **1. restart last, evidence first** (pending outcome) | **shipped** — the load-bearing property: worst case is "applied, restart pending", which the next run finishes |
| **2. CIM job-escape launch** (`Win32_Process.Create`) | **shipped** — the default, because it is outside the caller's job by construction (design, not a measurement) |
| 3. `Start-Process` fallback | documented fallback only, behind `-AllowProcessFallback`; it may inherit job membership, so it relies on the pre-restart outcome like any other helper. The audit records `launchMethod` whenever it is used |
| 4. External supervisor outside Paseo | **backup only** — not built; use it if a host ever blocks the CIM escape |
| 5. Operator runs the cutover by hand | always available: `Invoke-KeyCheckCutover.ps1 -KeyNumber <n> -RunId <id>` |

**Measure the host, don't assume it.** The probe spawns a marker-writing child
through the same mechanism, force-kills the launcher, and reports
`survives: true|false` plus the mechanism used (JSON with `-Json`; `-Legacy`
switches the mechanism to `Start-Process` as a **contrast probe**, not as a
demonstration that it fails). Job-object membership is inherited, so run it from
the same context as the watch before trusting an unattended watch on a new
machine. It is deliberately **not** part of the Pester suite: it kills processes
it created itself.

There is no `Process` object on the CIM path, so the outcome file is the only
proof: no outcome inside `-CutoverTimeoutMinutes` ends the run as
`cutover-unproven` (**5**), never as success.

The sequence is ordered, and the destructive step is last:

1. `Switch-OpencodeGoKey.ps1 -KeyNumber <n>` — the Salmon track: seam
   `activeKey`, User `OPENCODE_GO_KEY` / `OPENCODE_API_KEY`, `auth.json`,
   `~/.machine/config.json`.
2. Verify the **two non-Paseo surfaces** (seam `activeKey`, User key hash). If
   the switch left its own surfaces disagreeing, the repair is refused and the
   run ends **4** `surface-disagrees` — nothing usable moved.
3. Write the outcome `{ applied: true, verified: 'pending', restartPending:
   true, steps[], surfaces{seam,user-env} }`. **This is the load-bearing step.**
4. `Repair-Paseo.ps1 -KeyNumber <n>` — the Paseo track: provider env pin,
   worker restart, its own verification and canary. This may kill the helper.
5. If the helper is still alive after the restart, verify **all three** surfaces
   and write the outcome as
   `verified: true, restartPending: false` — seam `activeKey` is
   `OPENCODE_GO<n>_KEY`, User `OPENCODE_GO_KEY` resolves to GO<n>, the Paseo
   config pin resolves to GO<n> (`Get-PoolMatchLabel`; only labels are reported).
   If it is not alive, the `restartPending` outcome from step 3 stands and the
   next invocation finishes this step.

A failed step stops the sequence: a repair on top of a half-applied switch only
splits the machine's brain. The Salmon switch alone never proves the cutover —
that one-surface check is exactly why every rescue used to report
`cutover-not-proven`.

The switch is all-or-nothing, and its canary is the only proof of the new key:
the pre-switch state of every surface it writes is captured first, a canary
failure rolls them all back (exit 1, `rolled-back`), and only a rollback that
itself fails leaves `~/.machine/state/key-check/partial-cutover.json` (exit 6) —
which this helper resolves *before* any fresh switch by asking the switch to
complete the recorded target or revert to the recorded `from` key. **A canary
must run `--standalone` or it measures the CLI's cached background service, not
the key** — `Go usage limit exceeded` from a non-standalone canary is not
evidence against a key. Canonical: `vendor/credential-rescue/REFERENCE.md` § The CLI's background
service caches its credential.

**Do not run Key Check inside the Paseo agent it is protecting unless the helper
path is used.** Writing the outcome before the restart is what makes the rescue
recoverable; the helper is the only supported way to cut over from a
Paseo-hosted session.

### After a cutover: recover the roster (lanes AND Hubs)

A `paseo restart` strands every agent that was mid-turn. A stranded **Hub** is
worse than a stranded lane: restarting it is not recovery, because it also lost
its view of the children it was supervising.

**The roster** is that record. `vendor/credential-rescue/scripts/Capture-KeyCheckRoster.ps1` snapshots
the live agents **before** anything destructive, so a helper killed by the
restart still leaves the evidence behind:

```json
{ "version": 1, "capturedAt": "...", "runId": "...", "from": "GO3", "to": "GO1",
  "source": "paseo-ls",
  "agents": [ { "id": "...", "shortId": "...", "title": "...", "cwd": "...",
                "cwdIsRepoRoot": false, "status": "running", "created": "...",
                "sessionId": "...", "lastActivityAt": "...",
                "labels": { "hub-common": "cl-common" }, "isHub": true,
                "hasDoneFile": false } ] }
```

It lives at `~/.machine/state/key-check/<runId>-roster.json`, its path is
recorded in the cutover outcome (`rosterPath`), and it never contains a key
value — only `GO<n>` labels. This process and `merge-*` workers are excluded.

**Completion evidence is owned, never inherited.** A cwd holding `.git` is a
repository root — a shared trunk, where merge workers leave their
`.iqa-report.md` and `.iqa-done-merge-*` files — so it is never the occupant's
own evidence; reading it as such skipped the `cl-common` Hub during the
2026-11-03 rescue. Outside a repo root, an `.iqa-done-*.json` records the agent
as finished only when its file name carries this agent's id/short id or a bead
id from its title/labels, or when the agent is `closed` and the file postdates
its creation. `.iqa-report.md` is the lane's own brief-mandated report.

`vendor/credential-rescue/scripts/Resume-KeyCheckRoster.ps1` then makes **one logged decision per
agent** (`{kind:"roster-resume", runId, agentId, decision, reason, at,
variant}` in `~/.machine/logs/keycheck.jsonl`): `resumed`,
`skipped-finished`, `skipped-self`, `skipped-already-nudged`,
`skipped-missing`, `skipped-missing-cwd` (the worktree was swept: no send, no
failure line), `skipped-over-cap`. **An `isHub` entry is resumable by
default** — only an explicit `closed` status skips it, and the decision names
that status.

| Target | Message |
| :-- | :-- |
| lane | `Continue working — a key cutover just occurred (GO<from> → GO<to>) and your session may have been restarted. Re-read your brief and carry on; report to your parent as usual.` |
| Hub (`hub-*` label or `iqa-role=merge`) | the lane-style headline, then the Hub duty (enumerate YOUR children, resume the non-terminal ones, do not re-dispatch committed work), then a **role-restore block**: `HubRegistry.ps1 -Mode Register`, `Invoke-WorktreeLease.ps1 -Mode Acquire` and the label re-assert, each with this agent's id/cwd/repo filled in and each prefixed by the reason — "your old lease records a pid that is dead and your registry row may be gone", run from a FRESH persistent shell. |

**A send that fails is retried, then interrupted, then recorded.** `active run
cancellation was not acknowledged` is the daemon saying the previous turn is
still being cancelled; a single attempt left a Hub silently unresumed
(2026-11-02). The nudge retries three times with backoff (`-RetryBackoffSeconds`,
default `2,5,10`), then performs `paseo stop` and prompts once more, and only
then writes `roster-resume-failed` with `unhandled: true` — which the recovery
report surfaces as an explicit gap, never an omission.

**Idempotency:** a pass skips any agent the audit already holds a *sent*
`roster-resume` for, for that `runId`+`agentId`. `-LogOnly` decides and logs
(`logOnly: true`, which never consumes the slot); `-DryRun` writes nothing.
That is why **the nudge is sent by whichever process survives, so two call
sites are safe** — the helper after a proven cutover, and the watch's resume
path when the helper died mid-restart.

**The durable marker.** The resume pass (and the witness) writes
`~/.machine/state/key-check/last-cutover.json` =
`{runId, at, from, to, rosterPath, witnessPath, verdict}`, so a process can
learn a cutover happened without knowing the runId. On start, a Key Check run
that finds a marker newer than its own start **recovers before any further
checks** and audits `cutover-recovery` with `hubsNudged` / `lanesNudged` /
`skippedFinished`.

> **After a cutover the Hub's first duty is to recover its children** —
> `last-cutover.json` plus the roster are the checklist; resume, never
> re-dispatch committed work. The trap that costs a night
> (`../iqa-hub/REFERENCE.md` → the worker-loss and coverage-invariant
> traps) is re-dispatching work whose branch already has the commits.

**The ship's witness.** `vendor/credential-rescue/scripts/Invoke-KeyCheckWitness.ps1` reports one
verdict — `verified-by-helper`, `verified-by-witness`, `applied-but-unproven`,
`cutover-failed`, `no-evidence` — from the outcome file, the seam `activeKey`,
the User key label, the Paseo pin label and the daemon, and exits 0 only for the
two verified verdicts. Every label comes from `Get-PoolMatchLabel`, with the
seam's *name* resolved to its *value* first: labelling by stripping `_KEY`
compared `OPENCODE_GO3` against `GO3` and reported a verified machine as
`no-evidence` (pinned by a test). It writes
`~/.machine/state/key-check/witness-<runId>.json`, one `cutover-witness` audit
line, and refreshes `last-cutover.json`.

A failure in any of the three scripts is audited
(`roster-capture-failed` / `roster-resume-failed` / `witness-failed`) and
**never fails the cutover**: exit 4/5 keep their meanings.

### The cutover window: the marker, the backstop, and the repair

A cutover is not over when the switch verifies. It is over when the machine has
been **reconciled**: the role is back in the original hands, the leases the
restart killed are gone, and an interrupted measurement cannot be read as a red
gate. All three failures happened at once in runId `20261102-172700`.

#### Claim the machine first

`cutover-in-progress.json` (`{runId, startedAt, phase, host}`) is written by
`Invoke-KeyCheckCutover.ps1` **before** the switch moves any surface and removed
on every exit path — verified or failed. A helper killed by the restart leaves
it behind; the post-cutover recovery adopts and clears it.

A would-be backstop asks before taking a role:

```powershell
pwsh -File <package>/vendor/credential-rescue/scripts/Test-CutoverInProgress.ps1      # one loggable line
# 0 clear · 3 in progress, OR a cutover that ended inside -WindowMinutes (60)
# 2 cannot-evaluate — never a false "clear"
```

A backstop that ignores `3` is how one repo ends up with two live Hubs and a
lease in the wrong hands. **Do not treat 2 as clear either**: it means the state
exists and cannot be read.

#### Reconcile (`Invoke-CutoverRecovery.ps1 -RunId <id>`)

Keyed by runId, so the helper's call and any later pass are one recovery; a
second run for the same id prints `already-recovered` and writes nothing. It:

| Step | Rule |
| :-- | :-- |
| backstop detection | any Hub registry row (`registeredAt`) or lease (`acquiredAt`) inside the cutover window is a backstop; it gets ONE stand-down naming the runId and the original Hub, deduped per repo+runId+agent |
| lease seizure | **never automatic.** The stand-down asks; the run is done when the lease is released. `-ForceRevoke` is the explicit operator override and logs owner + generation |
| dead leases | a lease whose recorded pid is dead **and** whose checkout was in the window is released with `reason: cutover`, preserving owner/generation in `cutover-lease-released`. A live holder is never touched |
| role restore | the tool re-registers the original Hub itself (`HubRegistry.ps1 -Mode Register`, an upsert of its own row) and records that **the lease must be re-acquired by the resumed agent from a fresh persistent shell** — the pid the old lease names is dead |
| interrupted gates | `Stamp-InterruptedGates.ps1` writes `killed-by-cutover.json` (`{runId, at, lastLogLine}`) into every `<repo>/.gate-runs/<stamp>` modified inside `cutover-kill-window.json` (`{runId, startedAt, endedAt}`, written around the destructive step). A reader that finds it skips the run — it is neither red nor pass |
| report | `cutover-report-<runId>.json` + `.md`: every agent closed (id, title, repo, cwd, branch+HEAD), resumed, unresumed (with reason), every worktree with uncommitted work or a missing report/done file, every lease released/revoked, every stand-down, and every `unhandled` gap |

Two cutovers in minutes stay distinct: each window is bound to its own runId,
and neither recovery consumes the other's evidence.


The manual snapshot-then-`Continue` sweep is documented once, in
[this member — the watch](#the-watch--unattended-key-exhaustion-rescue) (the
`Continue` detail in `vendor/credential-rescue/skills/watch/REFERENCE.md`
§ snapshot/Continue) — this section is the automated form of it.

### The successor arm and the standing supervisor (cl-common-0ai)

A deadline-bounded run that merely **exits** leaves the active key unwatched
until a human or a Hub tick happens to look. Measured 2026-11-03: run
`20261102-235920` hit its 8 h deadline at **14:59:20Z** and stopped; the next
Hub tick started a fresh run at **15:07:48** — the key was unlooked-at for ~9
minutes, and **nothing** in the watch had asked for a successor. A watch that
lapses silently is indistinguishable from a healthy watch until a key exhausts,
which is exactly the failure the watch exists to prevent.

Two mechanisms close it, and they share **one** decision — a live lock is the
only liveness signal (`Get-KeyCheckSuccessorDecision` in
`vendor/credential-rescue/scripts/lib/KeyCheck.Decision.ps1`):

| Verdict | Meaning |
| :-- | :-- |
| `locked-by-run` (skip) | a live run holds `lock.json`; a second watcher would read the same meters and could cut over twice, so **nothing starts** |
| `no-state` (start) | no run state exists — nothing has ever watched |
| `run-ended` (start) | the state says the run ended (`phase = end`, an `endReason`, or an `endedAt`) |
| `run-not-live` (start) | the state says a run is in flight but no live lock exists: that run is unfinished, so the start **resumes** it on its **original** deadline |

**1. The run arms its own successor** — on a **deadline** ending, and on a
window that expired while the run was down (`window-expired-while-down`).
`Invoke-KeyCheck.ps1` creates the SAME entry point once, outside its own process
tree (`Win32_Process.Create`, the escape the cutover helper uses), told
`-StartAfterSeconds <deadline + SuccessorGraceSeconds>` (default **30 s**),
`-TriggeredBy successor-arm` and `-SuccessorOf <parentRunId>`. The wait is what
makes it a one-shot **later** run rather than a second watcher, and the grace
beat lets the parent write its terminal state and release the lock.

Arming is deliberately narrow: `-DryRun` is a rehearsal, `-NoWait` is a test
seam, and `-NoSuccessor` is the operator's opt-out. A rescue that failed (4/5),
a broken meter (1), an empty candidate field (3) or a max-checks stop arms
**nothing** — a fresh watch must not paper over a machine fault and make the
audit trail look healthy.

**2. A standing supervisor asserts liveness** — the successor process dies with
the host (reboot, logoff, a blocked CIM escape), so anything that ticks can ask
the same question in one line:

```powershell
pwsh -File <package>/vendor/credential-rescue/scripts/Test-KeyCheckLiveness.ps1                 # report only
pwsh -File <package>/vendor/credential-rescue/scripts/Test-KeyCheckLiveness.ps1 -Restart -Json   # assert and start
```

Read-only without `-Restart`. Exit **0** live (or restarted) · **3** lapsed and
not restarted · **4** restart attempted and failed · **2** `cannot-evaluate` —
the state file exists and cannot be read, which is **never** a pass (starting on
top of an unreadable run is how two watchers happen). `-Restart` creates the
same one-shot successor with `-TriggeredBy supervisor`, so the audit names which
arm of the fix acted. It never takes `-Force`: the lock is the liveness signal,
and a supervisor that stole a live lock would be the duplicate it exists to
prevent. Schedule it (hourly is enough — a lapsed watch costs nothing while the
key is quiet) and the chain recovers even after a reboot.

**What the record proves.** One `kind: successor` audit line per decision, with
the trigger source, in `~/.machine/logs/keycheck.jsonl`:

```json
{"kind":"successor","trigger":"successor-arm","action":"armed","runId":"20261103-080748",
 "parentRunId":"20261102-235920","at":"…","fireAt":"…","pid":300,"method":"Win32_Process.Create"}
{"kind":"successor","trigger":"successor-arm","action":"started","reason":"run-ended","parentRunId":"20261102-235920"}
{"kind":"successor","trigger":"successor-arm","action":"skipped","reason":"locked-by-run","holderRunId":"…"}
{"kind":"successor","trigger":"supervisor","action":"armed","reason":"run-ended","pid":3012}
```

`action` is `armed` / `failed` on the recording side, `started` / `skipped` on
the starting side. The run state carries the same fact on
`state.successor` (`trigger`, `armed`, `at`, `fireAt`, `pid`, `parentRunId`), so
a reader of `state.json` alone can see whether the next window is armed.

### Reset times are parsed explicitly, never by the machine's culture

The producer prints `resetsAt` as a **local short date** (`11/23/2026 23:43:24`),
whose day/month order follows *its* culture; other paths emit ISO-8601. Parsing
with the machine's culture is silently wrong (`11/23/2026` is not a date on an
en-GB box), so the accepted shapes are listed explicitly —
`yyyy-MM-ddTHH:mm:ss`, `M/d/yyyy H:mm:ss`, `d/M/yyyy H:mm:ss`, with and without
am/pm — and tried under `InvariantCulture`. A shape nothing matches yields
**`$null`, which is "window unknown", never an exception**: ranking falls back to
the rolling value (an unknown monthly reset sorts last, so it cannot outrank a
key with a known-sooner reset), the raw string is recorded in the audit, and the
run continues.


### Thresholds — what they mean, and why

| Meter | Cap | Share of the monthly allowance | Escalates at |
| :-- | :-- | :-- | :-- |
| weekly (`wk`) | 50 % | half the term | wk ≥ 80 discover, wk > 96 trigger |
| monthly (`mo`) | 100 % | the whole term | mo ≥ 90 discover, mo > 98 trigger |
| rolling 5 h | 20 % | a fifth of the term | **never** — it heals continuously |

Abbreviate the meters **wk** (weekly) and **mo** (monthly) everywhere — never
"w"/"m", because "m" already means minutes in this domain.

**Arming is one-sided; disarming is not.** Arming keeps the existing thresholds.
`near` disarms to the heartbeat cadence only after **two consecutive** readings
with weekly < **70** *and* monthly < **80** — both meters, no exceptions. A
single healthy-looking sample is not enough to leave the fast loop, and a key
hovering at the arm threshold cannot flip phase on every check. While armed,
`near` polls on the same burn-derived gear with a **15-minute ceiling** and a
1-minute floor (see § Adaptive cadence).

**One 429 is noise; two in a row is the key.** A rate-limited read increments
`consecutiveRateLimited` and is **not** a trigger; only the second consecutive
one triggers a cutover. Any readable check resets the counter. A percentage over
96/98 always triggers immediately — that is the key dying, not a burst.

A key at **0 wk / 100 mo is spent** (GO5 on 2026-11-02): the weekly slice is
irrelevant when the term is gone. That is why eligibility needs **both** meters
under their caps.

**An exclusion names the HTTP fact.** A usage read that answered with `429` is
`rate-limited`; `401`/`403` is `usage-FORBIDDEN`; any other non-200 is
`usage-HTTP<code>`; a transport failure is `usage-ERROR`. `meter-not-reported`
is reserved for a **200** whose meters are absent — it must never be used to
hide a rate limit or a broken endpoint.

**A budget shorter than one interval is one check.** When
`IntervalMinutes * 60 >= DurationHours * 3600` the run emits a warning line and
an audit `note` saying it performs effectively one check, instead of implying a
watch it cannot deliver.

### Eligibility and ranking

A rescue **target** must satisfy `weekly < 80 AND monthly < 90` — both meters,
no exceptions, and an unreported meter is never eligible. Among eligible keys,
rank by the **soonest monthly `resetsAt`**, ties broken by the lowest key
number.

**Weekly `resetsAt` is never used to rank.** The weekly window is aligned to one
shared Sunday 17:00 boundary across every key, so it carries no information about
which target lasts longer. Only the monthly term resets on each key's own
anniversary — that is the number that decides.

If no key is eligible when a rescue is needed, the run **ends with exit 3**
rather than moving the machine onto a spent key — and the reason line names
every candidate with the rule that excluded it, so "nothing eligible" is never
indistinguishable from "the reader returned nothing".

### Exit codes

`0` completed · `1` fatal — `cannot-evaluate` (a census that produced no
reading), `active-key-unresolved`, or `meter-unreadable` (three consecutive
unreadable reads) · `2` invalid grammar, **or another live run holds the lock
(`locked-by-run`)** · `3` no eligible replacement when a rescue was needed ·
**`4` cutover failed** (the helper reported `applied=false`, or it never
spawned — the credential move did not happen) · **`5` cutover unproven**
(`applied=true` but a surface disagrees, or the helper wrote no outcome inside
`-CutoverTimeoutMinutes`; the run ends instead of looping, and the outcome file
is the evidence for the next invocation).

`4` and `5` are different facts and must not be conflated: `4` means nothing
moved, `5` means something moved and cannot be proven. Both leave the run state
honest — neither claims success.

A run that resumes and finds its deadline already passed exits **0** with
`window-expired-while-down`: nothing was broken, the window simply closed while
nothing was watching it.

### State, audit, and what is written where

| Path | Content |
| :-- | :-- |
| `~/.machine/state/key-check/state.json` | The resumable run: `{ runId, startedAt, deadlineAt, phase, generation, replacementKey, consecutiveRateLimited, consecutiveCannotEvaluate, consecutiveBelowThreshold, armed, lastCheckAt, lastResult }` plus `activeKeyNumber`, `checks`, `lastReading`, `evidence[]`, `dryRun`, `cutovers` (each with `applied`, `verified`, `outcomePath`, `launchMethod`, `launchPid`), `drift`, `canary`, `simulatedActiveKeyNumber`, `endedAt`, `endReason`, `exitCode`, `successor` (`{ trigger, armed, at, fireAt, pid, method, parentRunId }` — whether the next window is armed, and by which arm of the fix), and the cadence record `{ cadenceSeconds, cadenceGear, cadenceReason, burnPerMinute, ettMinutes, sampleAt, cadenceChanges[], cadenceLoosenStreak, cadenceFloorTicks, cadenceSamples[], cadenceSampleSignature, cadenceSampleGeneration }`. Rewritten at every check — that is what makes an interrupted run resumable. One fixed path, never a per-run file. |
| `~/.machine/state/key-check/lock.json` | The live-run lock: `{ pid, host, runId, startedAt, heartbeatAt }`. Heartbeat refreshed at every check. Values only, never key material. |
| `~/.machine/state/key-check/dryrun/` | **A `-DryRun` probe's own artefacts** — `state.json`, `keycheck.jsonl`, `<runId>-cutover.json`, `witness-<runId>.json` — where `<runId>` ends `-dryrun` and the state carries `dryRun: true` plus `rehearsedRunId` (the live run it rehearsed). A dry run reads the live state as context and writes ONLY here, so the live `state.json` / `lock.json` / `keycheck.jsonl` are unreachable from it (cl-common-jqm). |
| `~/.machine/state/key-check/<runId>-cutover.json` | The helper's outcome: `applied`, `verified` (`true` or `'pending'`), `restartPending`, `reason`, per-step `exitCode`, the surfaces checked, `at`, `runId`, `rosterPath`, `witnessPath`, `witnessVerdict`. Written by the helper — the pending version **before** the restart, so it exists whether or not the helper outlives it, and a resume consumes it. |
| `~/.machine/state/key-check/<runId>-roster.json` | The pre-cutover agent snapshot (`id`, `shortId`, `title`, `cwd`, `cwdIsRepoRoot`, `status`, `created`, `sessionId`, `lastActivityAt`, `labels`, `isHub`, `hasDoneFile`). Labels only, never a key value. |
| `~/.machine/state/key-check/witness-<runId>.json` | The witness verdict plus the evidence it used: outcome presence/content, the three surface labels, daemon alive, exit code. |
| `~/.machine/state/key-check/last-cutover.json` | The durable discovery marker: `{runId, at, from, to, rosterPath, witnessPath, verdict}`. Readable without a runId; a marker newer than a run's start triggers the recovery pass. |
| `~/.machine/state/key-check/cutover-in-progress.json` | The in-flight claim: `{runId, startedAt, phase, host}`, written before the switch and removed when the cutover ends. What `Test-CutoverInProgress.ps1` answers 3 for. |
| `~/.machine/state/key-check/cutover-kill-window.json` | The destructive-step window: `{runId, startedAt, endedAt}`. A per-run sibling (`cutover-kill-window-<runId>.json`) is written too, so two cutovers in minutes do not overwrite each other's evidence. `Stamp-InterruptedGates.ps1` stamps `<repo>/.gate-runs/<stamp>` modified inside it with `killed-by-cutover.json`. |
| `~/.machine/state/key-check/cutover-report-<runId>.json` / `.md` | The post-cutover reconciliation report: closed / resumed / unresumed (with reason) agents with branch+HEAD, worktrees with uncommitted work or a missing report/done file, leases released/revoked with owner+generation, stand-downs, and `unhandled` gaps. |
| `~/.machine/logs/keycheck.jsonl` | One line per check (key number, wk/mo, phase, decision, the three tolerance streaks), one per cutover (from/to key numbers, `applied`, `verified`, canary result, outcome path, launch method — never values), one per `successor` decision (`trigger` = `successor-arm` \| `supervisor`, `action` = `armed` \| `failed` \| `started` \| `skipped`, the reason, the holder when skipped), one per cadence gear CHANGE (`kind: cadence` - phase, from/to seconds, burn, ETT, points remaining, reason; never one per tick), one per lock event, one per resume, one `roster-resume` per agent (`decision`, `reason`, `variant`, `logOnly`), one `cutover-recovery` per recovery pass with its counts, one `cutover-witness` per witness run, one `cutover-standdown` per reconciled backstop (repo, agent, original Hub, sent), one `cutover-lease-released` / `cutover-lease-revoked` with owner+generation, one `cutover-role-register`, one `cutover-gates-stamped`, one `cutover-marker-cleared`, `note` when the budget cannot hold one interval, and an `end` line with the reason and exit code. |
| `Tasks/Logs/credential-changes.jsonl` | Written **only** by `Set-OpencodeGoFreshness.ps1` when the ledger actually changes; Key Check does not duplicate it. |

`-DryRun` makes **every** decision and writes the full audit trail, but performs
**no cutover and no ledger write**; the real in-use key stays in
`activeKeyNumber` and the key the cutover would have chosen is recorded in
`simulatedActiveKeyNumber`. Use it to rehearse, and in any lane that must not
touch credentials.

### Dry run — a probe, never the live run

A dry run is a **probe**: it must be physically incapable of ending, rewriting
or impersonating the live run. Measured defect (cl-common-jqm, 2026-11-03
11:09:10 PT): a `-DryRun` probe resumed the LIVE runId `20261103-080748`,
appended `resume` + terminal `end` rows (`reason=max-checks`, `dryRun=true`) to
the live ledger, and rewrote the live `state.json` with
`endedAt`/`endReason`/`exitCode` — while the real watch (pid 47628, no `-DryRun`)
was alive and beating. A supervisor reading that state would have concluded the
watch was dead and started a duplicate.

The fix is structural, not a guard some later path can skip:

- the probe reads `~/.machine/state/key-check/state.json` as **context** (so the
  decisions it rehearses are the ones the live run would make) and then writes
  `state.json`, `keycheck.jsonl`, cutover outcome and witness files **only**
  under `~/.machine/state/key-check/dryrun/`;
- its identity is `<live runId>-dryrun` and its audit rows all carry
  `dryRun: true`, with `rehearsedRunId` naming the live run;
- the live lock is never taken, rewritten or released, and a probe leaves the
  live `state.json` and `keycheck.jsonl` **byte-identical**;
- readers of live state (`Test-KeyCheckLiveness.ps1`, the Hub tick, the cutover
  gate) address the live file names, so they cannot see a probe's artefact at
  all. A finished dry run still ends `max-checks`/`deadline` in its own file,
  and the live run then records its own `end` normally.
- what a probe deliberately does **not** replay: the live cutover outcome and
  the post-cutover recovery marker. Those describe a mutation the probe cannot
  verify and whose upgrade path would be a write; the probe rehearses the run's
  phases and decisions, not the recovery machinery.

### Secrets by shape — Invariant 6 (key numbers only)

Key **numbers** only. Comparisons are SHA-256 fingerprints
(`Get-SecretFingerprint`), so drift and identity are provable without the value
ever reaching a log, a plan, or a commit. A cutover line names `GO<from>` /
`GO<to>` and the canary verdict.

### Escalation ladder

```
        take the lock, resume or fix the deadline
initial ──► healthy ──────────────► heartbeat (gear, <= 60 min, active only)
  │                                     │ wk>=80 or mo>=90
  │ imminent / near-exhaustion          ▼
  └──────────────────────────────► discover ──► near (gear, <= 15 min, active)
                                       │            │ wk>96 / mo>98
                          no eligible  │            │ or 2nd consecutive 429
                                       ▼            ▼
                                   end (3)       trigger
                                                    │ active==replacement? no-op
                                                    │ else re-prove, create the
                                                    │ helper outside the job object
                                                    │ (Win32_Process) - but a helper
                                                    │ that dies is recovered by the
                                                    │ pre-restart outcome + resume
                                                    │ poll outcome, deadline kept,
                                                    │ generation++ -> near
                                                    ▼
                                                  near  ... until the deadline
                                                       disarm after 2 readings
                                                       with wk<70 AND mo<80
```

A cutover that reports `applied=false` ends **4**; one that applies but cannot be
verified (or never writes an outcome) ends **5**. A pending (`restartPending`)
outcome is finished by the next invocation, not accepted as success. A run whose
deadline expired
while nothing ran ends **0** as `window-expired-while-down`.

### Related

`salmon-run` (the Salmon track cutover) and
[key-cutover](../key-cutover/SKILL.md) (the canary-only watch, and what a cutover
repairs). Shared facts and safe reads: `vendor/credential-rescue/REFERENCE.md`.
Ledger view: `vendor/credential-rescue/scripts/Get-OpencodeGoFreshness.ps1`.


## Read first

[INVARIANTS](../../core/INVARIANTS.md) ·
[TASK-MODEL](../../core/TASK-MODEL.md) ·
[ADAPTERS](../../core/ADAPTERS.md) · [PROFILE](../../core/PROFILE.template.md)
