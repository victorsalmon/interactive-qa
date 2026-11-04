---
name: key-cutover
description: >
  IQA key-cutover member — moves every consumer from an exhausted credential to
  a proven replacement in one pass: verify the new one, switch the surfaces that
  hold it, restart what caches it, canary, then resume the interrupted workers.
  Owns the cutover seam, the Paseo track, and the canary-driven watch that calls
  the cutover when a key is proven dead. Use when a key is exhausted, when told
  to "use the other key", when Paseo still holds the old key, or before a
  rotation.
---

# key-cutover

## When to use

A replacement credential exists and consumers must move to it. Whether to move
is [key-watch](../key-watch/SKILL.md)'s decision, on proven exhaustion.

## What this member owns

- **The order**: verify the replacement first, then switch, then prove. A
  cutover that starts by overwriting the working credential has no way back.
- **Every surface that holds the credential**, enumerated before the switch: the
  environment, the credential file, the routed default, and any daemon or helper
  process that cached the old value at start-up. Missing one is the standard
  failure, and the restart that re-reads it is part of the cutover.
- **The canary and the resume set**: prove the new credential by a call that
  succeeds, not by a file that contains the new value, then continue the
  interrupted workers that survived and leave the finished ones alone.
- **The record**: one credential-change log line per touched surface, naming
  fields and fingerprints only — never a value (Invariant 6). A cutover that
  moves a shared or machine-wide credential is **operator-gated** (Invariant 8):
  the operator names the replacement; keys are never invented, borrowed or
  guessed.

## Where the scripts live (an adapter value)

`scripts_root` = **`<package>/vendor/credential-rescue/scripts`** — in-package by
default, where `<package>` is the directory holding this plugin's `SKILL.md`. The
package ships the whole Key family there (entry scripts, the dot-sourced
`scripts/lib/`, the runbooks under `skills/`, `assets/`, `Tests/`), so every
command in this member is written against that path and resolves without a
`Skills/` tree anywhere on the machine.

The fleet path `$env:CL_REPOS_ROOT\cl-common\Skills\credential-rescue` is a
**development override** supplied by the profile's `scripts_root` — never the
requirement. It exists on this box because a live Key Watch runs from the fleet
tree; when the profile supplies it, substitute it for
`<package>/vendor/credential-rescue` in the commands below, and let
`tools/Sync-VendoredHelpers.ps1 -Check` prove the two are the same files.

`<package>/vendor/credential-rescue/assets/` is **state as well as source**: the
seam and the provider lock under the profile state root are snapshots of the
machine's records. A
**read** (`-VerifyOnly`, `-Mode Status`, a canary) is meaningful as of the last
sync; a **write** (`Switch-OpencodeGoKey.ps1`, the Key Check cutover,
`Set-OpencodeGoFreshness.ps1`) must be given the machine's seam — the profile's
`seam_path`, or `-SeamPath <file>` — or it edits the package's own snapshot and
splits the machine's record in two. No `seam_path` in the profile means a write
is `cannot-evaluate`: report it, do not default it.

## The cutover seam and the runbooks

Repair credentials on the Clock Lobster dev box. One **seam** says which key is
active; one **runbook** per consumer fixes it. Read the triage row, load that one
runbook, and stop there.

**Some dotfiles are credential files that only look like config.** Classify
before reading; never dump a file wholesale on the assumption it is harmless.
`~/.npmrc` can contain a live registry `_authToken` beside `prefix=`. Use the
masked-read procedure in `vendor/credential-rescue/REFERENCE.md` § Safe reads.

**Secrets by shape — Invariant 6.** Key/profile NAMES and sources only. Every
credential add/remove/move/modify appends one JSON line to
`$env:CL_REPOS_ROOT\Tasks\Logs\credential-changes.jsonl` — the scripts do it themselves; if
you edit by hand, append the line yourself. `~/.*/` credential folders are
intentional state — never deleted or "remediated" here.

### Triage — pick ONE runbook

| Symptom | Runbook |
| :--- | :--- |
| A Salmon Run **lane/CLI** dies on `Weekly usage limit reached` / `Go usage limit exceeded`; "GO<n> is exhausted, use GO<m>" | `vendor/credential-rescue/skills/salmon-run/SKILL.md` |
| **Paseo** conversations use the OLD key, or report `Model not found: opencode/muse-spark-1.3-contributor`, or the provider shows *Not installed*, or `session.create timed out after 30s` (then `workspace_request_key_conflict`), or DSH-harness calls fail while opencode works | this member § [Paseo rescue](#paseo-rescue--the-paseo-track) |
| `~/.aws` (or another `~/.*/` folder) vanished; AWS calls fail with `NoCredentialProviders` | `vendor/credential-rescue/skills/aws-store/SKILL.md` |
| A key is near its weekly cap and agents must survive **unattended** overnight | this member § [The watch](#the-watch--unattended-key-exhaustion-rescue) |
| The active key is **approaching** its wk/mo cap and should be replaced **before** it dies; "Key Check", "key usage", "near exhaustion" | [key-watch](../key-watch/SKILL.md) |

**Two independent consumers.** Salmon Run lanes read the Machine pool +
`~/.machine/config.json`; **Paseo** hosts opencode in long-lived helpers that
freeze env at spawn. A cutover that repoints the env fixes Salmon Run but **not**
a running Paseo helper — which is why Paseo has its own runbook. A third
consumer, the standalone `opencode.exe serve --service` on this workstation,
also freezes env: until it is killed and respawned every CLI canary reports the
**old** key's quota. See `vendor/credential-rescue/REFERENCE.md` § "The third consumer".

> **Rescue order (standing operator order) — Paseo first, completely, then ask.**
> When a rescue fires, the **Paseo surface is replaced first and in full**:
> `vendor/credential-rescue/scripts/Repair-Paseo.ps1 -KeyNumber <n>` pins the opencode provider env,
> repoints the DSH `apiKeyEnv`, worker-restarts the daemon, and verifies BOTH
> harnesses (diagnostic `Ready` + name canary; the pong proof is a separate
> `opencode run … --standalone` — `Repair-Paseo.ps1` has no `-WithRun`).
> Only after that surface is whole does the agent **ask the operator** whether
> to replace the *other* surfaces — the Salmon track (`Switch-OpencodeGoKey.ps1`:
> User env, `auth.json`, `~/.machine/config.json`, seam `activeKey`), the
> standalone `opencode.exe serve --service`, and any other consumer. Do not
> silently fan a cutover out across every consumer: Paseo is the surface that
> must be incontrovertibly working on the new key first, and the rest is a
> separate, operator-approved step. The Paseo surface needs no prior Salmon
> cutover — the pin reads `OPENCODE_GO<n>_KEY` from Machine scope, falling back
> to User scope when no Machine value exists (a key staged without elevation).

### Close-out — ask for the meter reading of the key you left

A rescue moves every consumer off `GO<n>` and records **what changed**; it records
nothing about **why** unless the agent asks. The freshness ledger is what the next
run reasons from, and only the operator can read those numbers (no API exposes
them — see REFERENCE § Quota interrogation). So the **last step of every rescue,
before the run is reported done**, is one question to the operator:

> "What did the Console show for the key you just left — monthly and/or weekly
> usage, and the reset dates if they were visible?"

Then record it, never by hand-editing the seam:

```powershell
pwsh -File <package>\vendor\credential-rescue\scripts\Set-OpencodeGoFreshness.ps1 -KeyNumber <old> `
  -MonthlyUsed <pct> -MonthlyResets <yyyy-MM-dd> `
  -WeeklyUsed <pct>  -WeeklyResets <yyyy-MM-ddTHH:mm> `
  -Evidence 'operator Console read <date>, rescue off GO<old>'
```

Rules that make the answer usable:

- **Ask even when the cutover looked obvious.** "The key was fine, I moved for
  headroom" is itself a ledger entry (`state: fresh` plus its utilisation). A rescue
  with no reading leaves the next agent guessing from a stale row.
- **Pass only what you were told.** Each meter carries its own `observedAt` and an
  omitted meter keeps its previous figures and date — so a monthly-only answer is
  recorded as a monthly-only reading, never back-filled onto the weekly meter.
- **A 100 % meter is `exhausted` with `trippedMeter` named**; 99 % is still
  `fresh` with the figure recorded, because the row's job is to say how close it
  is, not to round it into a verdict.
- **A high monthly figure on the key you left is a forward-looking fact**, not
  history: if the Salmon track stayed behind on that key, say so in the report —
  it is about to start failing, and the operator's "leave it" was decided on the
  older number.

### The seam — one file owns the active key

`<package>/vendor/credential-rescue/assets/opencode-go-cutover.json` is the
package's copy of the **single source of truth for CONFIG**: `activeKey`,
`poolOrder`, `keyMaxConcurrent`, `providerMaxConcurrent`, the canary set, the
hygiene policy, the Paseo provider pin, and the metering **`freshness.windows`**
definitions. The per-key freshness OBSERVATIONS (state, utilisation, reset and
reading dates) are runtime state and do **not** live in this file — they live at
the seam's `observationsPath` in the profile state root
(`$HOME/.machine/state/credential-rescue/seam-observations.json`), beside the
provider lock, because a watch cycle must never modify a tracked+vendored file
(see `vendor/credential-rescue/REFERENCE.md` § "Key freshness ledger"). Two
tracks project the config, one surface each:

```
Step 1 (default) Paseo track  <package>/vendor/credential-rescue/scripts/Repair-Paseo.ps1 [-KeyNumber <n>]   (pin + DSH apiKeyEnv + worker restart + verify, BOTH harnesses)
  ~/.paseo/config.json   agents.providers.opencode.env  (the opencode helper pin)
  DSH child reads Machine/User <apiKeyEnv> from ~/.dsh/profiles/acp/salmon-run-model.yml (no pin; restart carries it)
  --- ask the operator before continuing past this line ---
Step 2 (on approval) Salmon track  <package>/vendor/credential-rescue/scripts/Switch-OpencodeGoKey.ps1 -KeyNumber <n> [-RestartPaseo] [-SeamPath <seam_path>]
  User env OPENCODE_GO_KEY + OPENCODE_API_KEY   (what interactive opencode reads)
  auth.json opencode-go                          (the CLI's credential store copy)
  ~/.machine/config.json  execution.defaultCodingKey (+ the caps)
  the seam  activeKey
```

Change the key by editing the seam **or** running the script with `-KeyNumber`;
the script writes the new `activeKey` back to the seam it read, so the two never
drift.

**Which seam is the machine's.** The package copy is the deployment truth on a
machine that has no fleet checkout. On a box that also runs the Key machinery
from a fleet tree (this one does), the machine's seam is that tree's
`assets/opencode-go-cutover.json`, and a write must name it: pass
`-SeamPath <seam_path>` on `Switch-OpencodeGoKey.ps1`, `Invoke-KeyCheckCutover.ps1`
and `Set-OpencodeGoFreshness.ps1`, where `seam_path` is the profile value. A write
with no `seam_path` is `cannot-evaluate` — it would move the package's snapshot
and leave the record the live watcher reads untouched. After a write to the
machine seam, re-run `tools/Sync-VendoredHelpers.ps1` so the package copy and the
machine record agree again; `-Check` reporting DRIFT on
`vendor/credential-rescue/assets/opencode-go-cutover.json` is exactly that signal.


> **`defaultCodingKey` is not advisory (the 2026-10-15 incident).**
> `Get-OpencodeDefaultCodingKey` feeds it to `Get-OpencodeKeyPriority -DefaultKey`,
> which moves the named key to the **front** of the pool order. Left on an
> exhausted key, every lane tried that key first and died before reaching the
> fresh one. Repointing the env alone fixes nothing — the script does both.

### Scripts (shared)

| Script | Purpose |
| :-- | :-- |
| `vendor/credential-rescue/scripts/Switch-OpencodeGoKey.ps1` | Salmon-track cutover (`-KeyNumber`, `-RetirePoolKey`, `-Full`, `-DryRun`; `-RestartPaseo` delegates to Repair-Paseo). Never touches Paseo config itself. |
| `vendor/credential-rescue/scripts/Repair-Paseo.ps1` | **Single Paseo entry**: classify (BINARY/NAME/WEDGE/KEY) both harnesses → pin opencode provider `env` → worker restart (`-FullApp` fallback) → verify both diagnostics. `-VerifyOnly` classifies only; `-KeyNumber <n>` pins that pool key. The DSH key is verified (apiKeyEnv name + GO-label + diagnostic + pool-key canary), never pinned. |
| `vendor/credential-rescue/scripts/lib/CredLog.ps1` · `vendor/credential-rescue/scripts/lib/PaseoCommon.ps1` | Shared: credential-change logger; Paseo CLI/pin/process helpers. Dot-sourced, never duplicated. |
| `vendor/credential-rescue/scripts/Restart-Paseo.ps1` · `Restart-PaseoDaemon.ps1` · `Restart-PaseoOpencodeHelpers.ps1` | **Deprecated shims** — forward to `Repair-Paseo.ps1`. Update callers. |
| `vendor/credential-rescue/scripts/Test-PaseoMuseSparkCanary.ps1` | Fast model-name canary (no tokens by default). |
| `vendor/credential-rescue/scripts/Restore-AwsStore.ps1` | `~/.aws` restore (`-Mode Status\|Restore\|Verify\|Backup`). |
| `vendor/credential-rescue/scripts/Invoke-ProviderLock.ps1` | **Provider lock**: `-Mode Status` (default, read-only) proves every consumer (Machine/User env, Paseo provider env, key file) still matches the authoritative source, printing only lengths + SHA-256 prefixes; `-Mode Lock` records the fingerprints at the machine state root (the profile's `provider-lock.json`, default `$env:USERPROFILE/.machine/state/credential-rescue/provider-lock.json`), never in this package. Drift exits 1. `-NoAws` compares consumers to the stored fingerprint only. A machine with no lock file is `cannot-evaluate` - seed the state root once from the deployment's lock asset. |
| `vendor/credential-rescue/scripts/Set-OpencodeGoFreshness.ps1` | **Freshness ledger write** (the write side of `Get-OpencodeGoFreshness`): records ONE key's meter reading(s) — pass `-WeeklyUsed`/`-WeeklyResets` and/or `-MonthlyUsed`/`-MonthlyResets`, each stamping that meter's own `observedAt` (default today); omitted meters keep their figures and reading date. Recomputes the row summary (`state`/`trippedMeter`/`usage`/`resetsOn`/`observedAt`) and the ledger `asOf`, then writes the **observations file** (`$HOME/.machine/state/credential-rescue/seam-observations.json`, the seam's `observationsPath`) — never the tracked seam. `-ObservationsPath` overrides the location; a first write imports a legacy embedded `freshness.keys`. `-WhatIf` supported, appends a `freshness-update` line to `Tasks/Logs/credential-changes.jsonl` (`-NoLog` disables). Never stores a key value. |
| `vendor/credential-rescue/scripts/Test-GoKey.ps1` · `Invoke-CredentialRescueWatch.ps1` | The unattended watch (`watch` runbook): canary → `Switch` + `Repair-Paseo` only on `EXHAUSTED`. |
| `vendor/credential-rescue/scripts/Get-OpencodeGoFreshness.ps1` | **Freshness ledger view** (read-only): reads the seam's `freshness.windows` for the cycle definitions and the observations file for per-key state, tripped meter, and per meter (`weekly` / `monthly`) the utilisation, the **cycle** it lives in, its `resetsOn` roll-over instant, `renewsInDays`, **its own `observedAt` reading date**, `ageDays`, a `STALE` marker past `-StaleDays` (default 7) and `ROLLED OVER` when `resetsOn` has already passed. A cold start with no observations file reports an empty ledger plus the config's `activeKey` (never an error). `-Probe` adds the live `Test-GoKey` verdict per key; `-KeyNumber <n>` narrows; `-Json` emits machine-readable output (including `windows`, `ledgerSource` and `observationsPath`) for an agent/coding loop. |

### Reference

Shared detail — safe reads of credential-bearing dotfiles, the facts of the
world, the long-form cutover, the `~/.aws` templates, and the Paseo binary/PATH
repair: `vendor/credential-rescue/REFERENCE.md`.

## Paseo rescue — the Paseo track

Paseo hosts opencode inside long-lived `opencode.exe serve` helper servers whose
environment is **frozen at spawn**. That is why a key cutover can leave Paseo
still on the old key, and why Paseo is handled separately from Salmon Run.

**Secrets by shape — Invariant 6.** Key NAMES only.

### Quick start — the express Paseo repair

```powershell
pwsh -File <package>\vendor\credential-rescue\scripts\Repair-Paseo.ps1 -VerifyOnly
pwsh -File <package>\vendor\credential-rescue\scripts\Repair-Paseo.ps1
```

It runs: classify (BINARY / NAME / KEY) → pin the provider `env` →
**`paseo restart`** (worker; supervisor + UI retained) → provider diagnostic →
name canary. `-FullApp` is the close + re-open fallback; `-KeyNumber <n>` pins
that pool key instead of the current User key. This ends every Paseo session
the daemon hosts, **including yours** — warn the operator first. Sessions
persist in `opencode.db`; a helper swap loses at most one in-flight turn.

**This is step 1 of a rescue, not step 2.** The Paseo surface is replaced first
and in full; the Salmon cutover is offered to the operator only after this
surface verifies.

```powershell
pwsh -File <package>\vendor\credential-rescue\scripts\Repair-Paseo.ps1 -KeyNumber 5
# then, only if the operator approves the other surfaces:
pwsh -File <package>\vendor\credential-rescue\scripts\Switch-OpencodeGoKey.ps1 -KeyNumber 5
# then close out: ask what the key you LEFT was reading, and record it
pwsh -File <package>\vendor\credential-rescue\scripts\Set-OpencodeGoFreshness.ps1 `
  -KeyNumber 4 -MonthlyUsed <pct> -WeeklyUsed <pct> -Evidence 'operator Console read <date>'
```

The close-out question is mandatory, not optional polish: the ledger can only hold
what the operator reads out of the Console, and a rescue that ends without it
leaves the next run reasoning from a stale row (see § *Close-out* above).

`-KeyNumber <n>` on `Repair-Paseo.ps1` moves **both** harnesses to `GO<n>` in
one command (opencode pin + DSH apiKeyEnv). `-NoDshSync` keeps opencode-only;
`-DshKeyNumber <m>` moves DSH alone.

### Classify before restarting

| Finding | Class | Action |
| :--- | :--- | :--- |
| `provider diagnostic opencode` → `Unavailable` / binary not found | BINARY | PATH/command-pin repair — see REFERENCE § Runbook C |
| name canary fails on `opencode/deepseek-v4.1-flash` (historical case: `opencode/muse-spark-1.3-contributor`) | NAME | provider-prefix error, not a credential (this runbook § Model-name check) |
| `session.create timed out after 30s`, then `workspace_request_key_conflict`; name canary still passes | WEDGE | stuck helper/daemon, not a credential — worker restart only, never a key cutover (this runbook § Timeout storm) |
| name resolves but helpers answer with usage-limit text | KEY | pin + worker restart (this script) |

Legacy entry points (`Restart-Paseo.ps1`, `Restart-PaseoDaemon.ps1`,
`Restart-PaseoOpencodeHelpers.ps1`) are deprecated shims that forward to
`Repair-Paseo.ps1` — update callers.

### The launch-env rule (why reload is not enough)

A provider `env` is a **launch setting**. `paseo reload` answers
*"Configuration reloaded"* and **silently keeps the old env** — the daemon logs
a level-40 `already initialized with different runtime settings`. Only a
**daemon worker restart** rebuilds the opencode server manager with the env. So:

| Action | Applies a launch env? |
| :--- | :--- |
| edit `~/.paseo/config.json` + `paseo reload` | no |
| `paseo restart` (worker; supervisor + UI retained) | **yes** |
| quit + reopen the Desktop app | yes (also re-inherits the OS env) — the no-pin fallback |

Pin the key under `agents.providers.opencode.env` (`OPENCODE_GO_KEY` +
`OPENCODE_API_KEY`) so the daemon no longer depends on the environment it was
launched with. On Windows Paseo uses the env it was launched with, so without
the pin only the app restart changes the key.

### DeepSeek Harness — the second consumer (same wallet, different key source)

`Repair-Paseo.ps1` classifies and verifies **both** harnesses. The DSH ACP
child does **not** read the opencode pin: it reads the Machine/User env var
named by `apiKeyEnv` in `~/.dsh/profiles/acp/salmon-run-model.yml` (managed by
`Public/salmon-run/Tools/Install-PaseoDeepSeekHarness.ps1`; live value on this
box is a pool key, e.g. `OPENCODE_GO3_KEY` — names only, never values). An
empty `env` block on `agents.providers.deepseek-harness` is **expected**, not a
defect.

| Finding | Class | Action |
| :--- | :--- | :--- |
| `provider diagnostic deepseek-harness` → not `Ready` | BINARY(DSH) | reinstall via `Install-PaseoDeepSeekHarness.ps1` |
| DSH apiKeyEnv name missing from Machine+User env | env-missing | set the named var (operator-owned value), then worker-restart |
| `Test-GoKey.ps1 -KeyNumber <n>` on the apiKeyEnv pool key → non-OK | KEY(DSH) | move both harnesses at once: `Repair-Paseo.ps1 -KeyNumber <healthy-n>` (pins opencode AND repoints DSH apiKeyEnv; `-NoDshSync` for opencode-only, `-DshKeyNumber <m>` for DSH-only) — never touch the opencode pin for a DSH-only failure |

A worker restart (`paseo restart`) respawns the DSH child with the current
Machine/User env, which is what carries a changed DSH key — `paseo reload`
does not. The opencode pin and the DSH key are independent: either harness
can be sick while the other is healthy (live case: opencode on GO5 Ready
while the DSH key is EXHAUSTED).

### Wedged helper, not a dead key

`OpenCode session.create timed out after 30s` during workspace/session
creation — especially from `WorkspaceAutoName` structured generation trying
several models in a row — is a **stuck helper/daemon**, not exhaustion: the
name canary still passes through it. `Repair-Paseo.ps1 -VerifyOnly` proves it
with the daemon-log timeout/watchdog scan plus a live `POST /session` probe
per helper. A WEDGE finding means **restart, never cut over the key**. The
follow-on `workspace_request_key_conflict` is the UI retrying the timed-out
create under the same request key — retry the creation fresh (new key) after
the restart instead of hammering the same one.

### Reference

- Shared facts + long-form cutover: `vendor/credential-rescue/REFERENCE.md`
- Lane resumption after the restart: `vendor/credential-rescue/skills/salmon-run/SKILL.md`
- Unattended watch (does this restart for you): [this member — the watch](#the-watch--unattended-key-exhaustion-rescue)

- `## Model-name check (no tokens)`
- `## Timeout storm — `session.create` 30s / `workspace_request_key_conflict` (WEDGE, not a key)`
- `## Verify — strongest first`
- `## Provider shows "Not installed" / OpenCode binary not found`

## The watch — unattended key-exhaustion rescue

The watch's decision cadence — when to canary, and when exhaustion is *proven* —
is owned by [key-watch](../key-watch/SKILL.md); this is the cutover side of it.

A **watch mode** layered on this plugin: it sits in a loop testing the active key
against a standby, fires the rescue the moment the active key dies, then revives
the agents that were running on it. Built for the overnight case — the operator
starts it, sleeps, and wakes to agents that survived a key exhaustion.

**Secrets by shape — Invariant 6.** Key NAMES only. The cutover logs to
`$env:CL_REPOS_ROOT\Tasks\Logs\credential-changes.jsonl`; this runbook also writes its own
timeline (see § Logging).

### When it fires

The active key is near its weekly cap and agents are mid-run: `Go usage limit
exceeded` / `Weekly usage limit reached. Resets in N days` in the opencode log, or
the operator asking to watch the key. **Not** for a missing binary (this member's **Paseo rescue** section), **not** for the built-in `opencode` (zen) provider's workspace-balance
error, **not** for transient `BUSY`.

### The loop

1. **Familiarize + snapshot.** Read the `salmon-run` runbook (the cutover this
   automates). Snapshot running agents with `paseo_list_agents`
   (`statuses: ["running"]`) — the "before" cohort. Resolve the active pool key by
   comparing `OPENCODE_GO_KEY` (User) to each `OPENCODE_GO<n>_KEY` (Machine);
   compare only, never print.
2. **Canary both keys** before the loop: `vendor/credential-rescue/scripts/Test-GoKey.ps1 -KeyNumber <n>`.
   If the standby is dead there is no safe target — abort.
3. **Wait one unit** (default 3600s).
4. **Re-test both keys.**
5. **Old key failed → rescue**, or **both fine → wait again.** The rescue is
   `Switch-OpencodeGoKey.ps1 -KeyNumber <new>` (this plugin's cutover), then make
   Paseo use the new key (see § Paseo), then re-canary.

Driver: `vendor/credential-rescue/scripts/Invoke-CredentialRescueWatch.ps1 -ActiveKeyNumber <a> -NewKeyNumber <b>`.
Exit **0** rescue complete · **2** standby unusable · **3** both dead · **4**
cutover done but restart/post-check imperfect. On `0`, run steps 6-8.

> **Never trust a remembered key status.** Pool health is transient (weekly cap
> resets, a monthly term lapses or renews). Ascertain it at run time by
> canarying. Only the pool layout and the error taxonomy are durable.

### Rescue only on proof, never on a timeout

An exhausted key does **not** return a fast error — the request hangs on retries,
so the CLI is killed as a timeout. The only reliable evidence is the log line the
attempt writes, and that log is **shared across every session on the machine**,
so `Test-GoKey.ps1` attributes evidence by time (bounded tail read).

| Token | Meaning | Rescues? |
| :-- | :-- | :-- |
| `OK` | answered `pong` | no |
| `EXHAUSTED` | weekly usage / rate-limit text | **yes** |
| `NOT-SUBSCRIBED` | monthly term lapsed, no payment | no (and never a target) |
| `BUSY` / `TIMEOUT` | provider busy / transient — retried first | no |
| `TRANSPORT` | `encrypted_content` replay defect | no |
| `AUTH` | `unauthorized` / `401` / `403` | no |

The loop cuts over **only** on `EXHAUSTED` (weekly cap spent → rescue).
`NOT-SUBSCRIBED` is account-side — the operator renews it, never a rescue target.
`BUSY` means the key is fine: provider-busy blips are expected, so
`Test-GoKey.ps1` retries up to `-MaxRetries` (default 3) before it reports.

### Choosing the standby key — health is not enough

A key that merely answers `pong` is not automatically safe: a near-cap key can
exhaust seconds later, killing every agent you just nudged. Canary **every** pool
key and pick the least-consumed healthy one; treat a key known to be >~95%
consumed as unavailable. Re-check at run time.

### Dispatch modes — the watch stays single-active

The loop above assumes single-active: canary active + standby, cut over the
one pointer, `Continue` the survivors. `waterfall` / `round-robin` sessions
and this watch are mutually exclusive: `Acquire` under either mode refuses
while the watch state file (`%TEMP%\opencode\credential-rescue-watch\state.json`)
reads `watching` — stop the watch first, or stay on `-DispatchMode
single-active`.

No mode pointer exists for the watch to move — modes route around a spent
key through the gate's day-spent state, and only the cutover seam moves
`activeKey`. Until the watch learns mode-aware rescue (canary all 5, no
active-pointer cutover for a non-active `EXHAUSTED`, nudge only agents
bridged to the moved key), do not run modes under a live watch.

### Paseo — the restart is required

After the cutover the running helpers still hold the old key. Make Paseo take it:
`vendor/credential-rescue/scripts/Repair-Paseo.ps1` (default worker restart — pin the provider env, then
`paseo restart`, UI retained). `-FullApp` is the fallback. Full mechanism,
verification, and the launch-env rule: this member's **Paseo rescue** section.

### Reference

Full watch runbook, the error-taxonomy samples, and the run-record format:
`vendor/credential-rescue/skills/watch/REFERENCE.md`. Shared facts: `vendor/credential-rescue/REFERENCE.md`.

- `## Send "Continue" to survivors`

## Read first

[INVARIANTS](../../core/INVARIANTS.md) ·
[TASK-MODEL](../../core/TASK-MODEL.md) ·
[ADAPTERS](../../core/ADAPTERS.md) · [PROFILE](../../core/PROFILE.template.md)
