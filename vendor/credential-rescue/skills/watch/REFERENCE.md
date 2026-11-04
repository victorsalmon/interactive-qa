
# Credential Rescue Watch — unattended key-exhaustion rescue

A **watch mode** layered on [credential-rescue](../../SKILL.md).
That skill is the *repair* (how to cut over and restore); this skill is the
*monitor*: it sits in a loop testing the active key against a standby key, and
fires the repair automatically the moment the active key dies — then revives the
agents that were running on it. Built for the overnight case: the operator
starts it, sleeps, and wakes to agents that survived a key exhaustion.

**Never print secret values** (key/profile NAMES only). Every credential change
this skill triggers goes through `Switch-OpencodeGoKey.ps1`, which appends the
mandatory line to `$env:CL_REPOS_ROOT\Tasks\Logs\credential-changes.jsonl`. This skill
also logs its own watch timeline (see § Logging).

## When it fires

The active key is near its weekly cap and agents are mid-run; a cutover cannot
wait for a human. Symptoms that justify starting a watch: the weekly-cap error
`Go usage limit exceeded` / `Weekly usage limit reached. Resets in N days` in
`D:\opencode-data\opencode\log\opencode.log`, `rate_limit_exceeded` on a live
helper, or the operator saying "watch the key overnight / rescue the agents while
I sleep". This is NOT for a *binary missing* failure (that is credential-rescue
Runbook C), NOT for the built-in `opencode` (zen) provider's workspace-balance
error, and NOT for transient `BUSY` errors (retry — see the taxonomy below).

## The loop (operator contract)

The runbook below is exactly what the watch session does. Scripts live in
`scripts/` next to this file.

### 1. Familiarize + snapshot

- Read [credential-rescue/SKILL.md](../../SKILL.md) and its
  `REFERENCE.md` § Runbook A (the cutover this skill automates). Know the pool
  layout (`OPENCODE_GO1..5_KEY` Machine vars; `OPENCODE_GO_KEY` +
  `OPENCODE_API_KEY` User; live `auth.json` at `$env:XDG_DATA_HOME`).
- Snapshot the running agents with the Paseo MCP: `paseo_list_agents`
  (`statuses: ["running"]`). Record each agent's **id, title, cwd**. This set is
  the "before" cohort that may need a `Continue` nudge after a rescue.
- Resolve which pool key is active: compare `OPENCODE_GO_KEY` (User) against
  each `OPENCODE_GO<n>_KEY` (Machine); the match is the active index. Compare
  only, never print values.

### 2. Test both keys

- `scripts/Test-GoKey.ps1 -KeyNumber <active>` and `-KeyNumber <new>`. Both must
  answer (exit 0) before the loop starts. If the new key is dead there is no
  safe target — abort and tell the operator.

> **Never trust a remembered key status.** Pool health is *transient*: a key's
> weekly cap resets, a monthly subscription term lapses or renews, a new key is
> bought — all on a monthly-or-faster cadence. Do NOT record or rely on any
> key's status as a stable fact. **Ascertain it at run time** by canarying each
> key (`Test-GoKey.ps1`). The only durable facts are the *pool layout* (var
> names, roles) and the *error taxonomy* below.

### Loop — steps 3-5

Run `scripts/Invoke-CredentialRescueWatch.ps1 -ActiveKeyNumber <active>
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

#### Exhaustion criteria — evidence, not guesswork

A rescue must fire **only** on proof the key is *spent*, never on a bare
timeout. An exhausted opencode-go key does **not** return a fast CLI error — the
request hangs on retries, so the CLI is killed as a timeout and the only
reliable evidence is the log line the attempt writes:

```
error.error="AI_APICallError: Go usage limit exceeded"
error.error="AI_APICallError: Upstream request failed: An active OpenCode Go subscription is required to use Go models."
```

The log is **shared across every session on the machine**, so `Test-GoKey.ps1`
attributes evidence by time: it keeps only `error.error=` / `stream error` lines
timestamped at/after the attempt started (bounded tail read — never the whole,
possibly-rotated file). Downstream of a rotation, an unbounded read would drag in
another key's old lines — that is how GO2 once mis-reported `NOT-SUBSCRIBED`.

`Test-GoKey.ps1` returns a classified first token. Canonical table:
[../../REFERENCE.md](../../REFERENCE.md) § Error taxonomy — linked, not copied.

The watch loop parses the token and cuts over **only** on `EXHAUSTED`; every
other non-OK class is logged and the loop waits another unit. This prevents a
transient hang / provider-busy blip from triggering a spurious cutover onto the
standby key.

**Three failure classes — never conflate them.**
- **EXHAUSTED** = the key's *weekly cap* is spent. The fix is to cut over to a
  healthy standby key (Rescue).
- **NOT-SUBSCRIBED** = the key's *monthly subscription term* lapsed with no
  payment scheduled. Repointing to it changes nothing — it fails identically for
  every caller. The only fix is at the account (renew/subscribe) and is
  **operator-owned**. The watch aborts rather than cut over onto a
  `NOT-SUBSCRIBED` standby and never nags agents onto it.
- **BUSY / TIMEOUT** = the provider (or network) is busy. The key is *fine*; the
  fix is to **retry** — `Test-GoKey.ps1` already does, `-MaxRetries` times. Never
  treat it as a key fault and never rescue because of it.

### Choosing the standby key — health is not enough

A key that merely *answers* `pong` is not automatically a safe target: a
near-cap key can be `OK` on the canary and exhaust seconds later, killing every
agent you just nudged. Before starting a watch, canary *every* pool key and pick
the **least-consumed healthy** one; treat a key known to be >~95% consumed as
unavailable. Canarying all five keys (not just the intended pair) is also how you
discover a `NOT-SUBSCRIBED` or `EXHAUSTED` key that should not be a target at all.

There is no safe standby if every remaining healthy key is near-cap or
unsubscribed — the watch is only worth arming when a genuinely fresh key exists.
Re-check at run time; never assume last month's layout still holds.

### The error taxonomy (durable) — canonical table

Linked, not copied: [../../REFERENCE.md](../../REFERENCE.md) § Error taxonomy.
The class strings are the durable knowledge; which key is in which class is not.
Live samples per class (weekly-cap text → EXHAUSTED/rescue; subscription text →
NOT-SUBSCRIBED/operator renews; busy JSON/overload/5xx → BUSY/retry;
encrypted_content → TRANSPORT; 401/403 → AUTH; silent → TIMEOUT/retry) are in
the canonical section.

**Transient errors are expected, not exceptional.** opencode-go / DS4.1 Flash is
frequently under load and returns a "provider is busy" style error
(`Output token rate limit exceeded…`, `Upstream response was not valid JSON`).
These are the network being busy — a key that shows one is *fine*. `Test-GoKey.ps1`
therefore **retries up to `-MaxRetries` (default 3) with a delay** and only
reports `BUSY`/`TIMEOUT` after exhausting retries; neither ever triggers a rescue
or marks the key bad. (A "provider is down" class also exists and is rarer still
— it is folded into the `BUSY`/`TIMEOUT` retry path by the same `overloaded` /
`unavailable` / `5xx` patterns.) Only a *definitive* `EXHAUSTED` verdict — the
weekly-cap text — causes a cutover.

### 6. Make sure the old agents switched to the new key

Paseo hosts opencode inside long-lived `opencode.exe serve` helpers that freeze
their **environment at spawn**, so the cutover's env repoint does NOT reach a
running helper. A provider `env` is a **launch setting**: `paseo reload` cannot
apply it — it answers "Configuration reloaded" while the daemon keeps its old
settings (daemon.log level 40, "already initialized with different runtime
settings"). Pinning the key in `~/.paseo/config.json` and restarting the daemon
worker is what rebuilds the opencode server manager with the credential.

`scripts/Repair-Paseo.ps1` does that (default worker restart):

1. pin `OPENCODE_GO_KEY` + `OPENCODE_API_KEY` into
   `agents.providers.opencode.env` from the User-scope values the cutover wrote;
2. `paseo restart` — a daemon **worker** restart; the Desktop supervisor is
   retained, so the UI does not close;
3. verify the daemon is alive and a fresh helper is present.

`-FullApp` (`-Mode App`) is the fallback: close and re-open the Paseo desktop
app, composing the child environment explicitly so the daemon inherits the
current credential rather than the launching shell's frozen env. Use it when the
worker restart does not take. Sessions persist in `opencode.db` — the swap loses
at most one in-flight turn.

> **Launch-env note (the env pin is the durable fix).** The worker restart is
> sufficient precisely because `Repair-Paseo.ps1` pins the provider `env`: the
> daemon then no longer depends on the environment it was launched with. Without
> that pin, only the full app restart (which re-inherits the OS env) changes the
> key — and a plain `Start-Process Paseo.exe` from a long-lived shell, or from the
> detached watch process whose env was frozen *before* the switch, hands the new
> daemon the **OLD** key so every respawned helper keeps failing with
> `Go usage limit exceeded`. App mode exists for that no-pin case and composes
> the child env explicitly, reporting the pool match (e.g.
> `launch env OPENCODE_GO_KEY -> GO2`). `no-pool-match` means the launch env did
> not pick up the cutover — investigate before nudging agents.

> A daemon worker restart is lighter than the old close+reopen, but it can still
> interrupt a session that runs inside Paseo — the official Paseo docs say
> running agents keep going and clients reconnect, but treat this watch session
> as possibly dropping. Start the watch from a durable context (or rely
> on the step-8 run record for the hand-off). Warn the operator when interactive.
> A `Start-Process` child of a Paseo-hosted shell may inherit the agent's Job
> Object (the agent host decides); create long-lived children with
> `Win32_Process.Create`, which is outside the caller's job by construction, and
> confirm on a new host with `scripts/Test-KeyCheckDetachment.ps1`. Survival is
> environment-dependent and unproven for a real restart — the cutover does not
> depend on it, because the helper writes its outcome before the restart.

Verify, strongest first:
- **Live-helper probe (definitive)** — drive the fresh helper and see it answer:
  `POST http://127.0.0.1:<helper-port>/session`, then `POST /session/<id>/message`
  with
  `{"model":{"providerID":"opencode-go","modelID":"deepseek-v4.1-flash"},"agent":"build","parts":[{"type":"text","text":"reply pong"}]}`.
  A `text` part reading `pong` with non-zero `cost` proves the helper holds a
  working key; an exhausted key fails with the usage-limit signature.
- `scripts/Test-GoKey.ps1 -KeyNumber <new>` for a clean green;
- `paseo_list_agents` should still list the cohort;
- spot-check `D:\opencode-data\opencode\log\opencode.log` for auth/quota errors.

### 7. Send "Continue" to survivors

For every agent in the step-1 cohort that did **not** complete successfully
(status not `closed`-with-success / still needs attention after the restart),
send the prompt **"Continue"** via `paseo_send_agent_prompt`. Skip agents whose
work finished. Prefer `background: true` + `notifyOnFinish: true` so the watch
session is not blocked. If an agent's session was mid-turn when Paseo restarted,
`Continue` resumes it on the new key.

### 8. Record and log everything

- The script writes a timeline to
  `%TEMP%\opencode\credential-rescue-watch\watch.log` and a machine-readable
  `state.json` (phase: `watching` | `rescued`).
- The cutover itself logs to `credential-changes.jsonl` via the switch script.
- Append a run record (below) and, if the operator is not watching, a morning
  summary of: which key died, when, which key is active, which agents were
  nudged, and any incomplete rescue.

## Run record

```
CRW run <utc>  active=GO<n> new=GO<m> interval=<s>s
loop: <N> iterations
detected exhausted: GO<n> at <utc>
cutover: switch rc=<0|1> paseo-restart rc=<0|1> post-canary=<OK|FAIL>
agents before: <count>; nudged Continue: <ids>; completed-skip: <ids>
incomplete: <none | description>
```

## Scripts

| Script | Purpose |
| :-- | :-- |
| `scripts/Test-GoKey.ps1` | Canary one pool key by number/value, isolated from the live env. Retries transient `BUSY`/`TIMEOUT` up to `-MaxRetries`. Emits a class token: `OK` / `EXHAUSTED` / `NOT-SUBSCRIBED` / `BUSY` / `TRANSPORT` / `AUTH` / `TIMEOUT` / `ERROR`. Exit 0 only on `OK`. |
| `scripts/Invoke-CredentialRescueWatch.ps1` | The watch loop: snapshot baseline, poll both keys, fire the cutover + Paseo restart **only** on `EXHAUSTED`; abort if the standby is `NOT-SUBSCRIBED`. |
| `scripts/Repair-Paseo.ps1` | Make Paseo's opencode helpers use the current key. Worker restart default: pin the provider `env` in `~/.paseo/config.json`, then `paseo restart` (daemon worker; the UI stays open). `-FullApp` = close + re-open fallback with a composed child env. `-VerifyOnly` to inspect; `-KeyNumber <n>` to pin that pool key. |

Reused from credential-rescue: `scripts/Switch-OpencodeGoKey.ps1` (the Salmon
cutover — User env + `auth.json` + `~/.salmon/config.json`; `-RestartPaseo`
delegates to `Repair-Paseo.ps1`). `Restart-Paseo*.ps1` are deprecated shims
forwarding to `Repair-Paseo.ps1`.

## Approval boundaries (inherited)

- Repointing User env / auth.json to another existing pool key: allowed, logged.
- Clearing a Machine pool var / flipping SM `_ON` flags: operator-visible —
  ask unless already authorized.
- Restarting Paseo ends hosted sessions including possibly this one — warn
  first when interactive.
- Rotating/creating IAM keys: operator-owned; agents never create keys.

## Send "Continue" to survivors

Send **"Continue"** via `paseo_send_agent_prompt` (`background: true`,
`notifyOnFinish: true`) to every agent in the step-1 cohort that did not complete;
a session that was mid-turn when the daemon restarted resumes on the new key.

## Logging

Timeline `%TEMP%\opencode\credential-rescue-watch\watch.log` + `state.json`
(`watching` | `rescued`); cutover lines go to `credential-changes.jsonl`. Append a
run record and, if the operator is asleep, a morning summary: which key died,
when, which key is active, which agents were nudged, any incomplete rescue.

## Scripts

| Script | Purpose |
| :-- | :-- |
| `scripts\Test-GoKey.ps1` | Canary one pool key, isolated from the live env; retries transient `BUSY`/`TIMEOUT`. Emits a class token; exit 0 only on `OK`. Canonical error taxonomy: [REFERENCE](../../REFERENCE.md) § Error taxonomy. |
| `scripts\Invoke-CredentialRescueWatch.ps1` | The loop: snapshot, poll both keys, fire cutover + Paseo repair **only** on `EXHAUSTED`. |
| `scripts\Repair-Paseo.ps1` | Make Paseo's helpers use the current key (worker restart default; `-FullApp` fallback). |

## Approval boundaries

- Repointing User env / `auth.json` to another existing pool key: allowed, logged.
- Clearing a Machine pool var / flipping SM `_ON` flags: operator-visible — ask
  unless already authorized.
- A daemon restart can interrupt this session — warn the operator when interactive.
- Rotating/creating IAM keys: operator-owned; agents never create keys.