# paseo-rescue - reference

Adjacent reference for [SKILL.md](SKILL.md).

## Model-name check (no tokens)

```powershell
pwsh -File $env:CL_REPOS_ROOT\cl-common\Skills\credential-rescue\scripts\Test-PaseoMuseSparkCanary.ps1 -Model 'opencode-go/deepseek-v4.1-flash'
```

The canary's current target model is `opencode-go/deepseek-v4.1-flash` (the
fleet default); the Muse Spark names below are the historical 2026-10-15
evidence record, not the live default.

Proves the exact endpoint name `opencode-go/muse-spark-1.3-contributor` resolves
via `opencode models opencode-go`. The `opencode/muse-spark-1.3-contributor`
form does **not** exist upstream (only `…-free` does) — a provider-prefix error,
not a credential. Record: `assets/paseo-muse-spark-resolution-2026-10-15.md`
plus `assets/opencode-go-seam-projection-2026-10-16.md` (probe encoding tell).
Add `-WithRun` for the one-word inference proof (~60s, spends tokens).

## Timeout storm — `session.create` 30s / `workspace_request_key_conflict` (WEDGE, not a key)

`Repair-Paseo.ps1` (classify step, including `-VerifyOnly`) detects this
directly: it scans the daemon-log tail for `session.create timed out` /
event-stream watchdog expiries and probes every registered helper with a live
`POST /session` (deleted immediately after). A WEDGE finding means restart,
never a key cutover.

Tells (verified 2026-10-15): `~/.paseo/daemon.log` repeats `OpenCode
session.create timed out after 30s` with a preceding `OpenCode event stream
first-record watchdog expired` (attempt counter climbing, hours stuck), while
`Test-PaseoMuseSparkCanary` still passes — the name resolves, session creation
does not. `workspace_request_key_conflict` follows the timeout and is absent
from `daemon.log`: it is the retry artifact (the UI re-sends the timed-out
create under the same workspace request key while the first request is still
pending), not a second fault and never a credential fault. Do not chase it;
fix the wedge and it goes away.

Load factor on this box: `opencode.db` was 33 GB (8.5M pages, freelist 0,
WAL; `event` 1.66M rows, `part` 451k rows) when the storm hit — session
creation inserts under checkpoint pressure on that file, so a stuck helper
plus a giant db is what times out. Never `VACUUM` the live db (exclusive
lock, breaks running helpers) and never delete sessions without an explicit
operator call; the restart is the repair, db pruning is operator-owned.

## Verify — strongest first

Drive the fresh live helper and see it answer (proves the key, not the config):
create a session and post a message to `http://127.0.0.1:<helper-port>`:

```
POST /session                                -> { "id": "ses_…" }
POST /session/<id>/message
  {"model":{"providerID":"opencode-go","modelID":"deepseek-v4.1-flash"},
   "agent":"build","parts":[{"type":"text","text":"reply pong"}]}
```

A `text` part reading `pong` with non-zero `cost` means the helper holds a
working key; an exhausted key fails with the usage-limit signature. Then:

> **Body encoding tell (verified 2026-10-16):** `POST /session/<id>/message`
> JSON-parses the request body server-side, and a UTF-8-BOM body surfaces as
> `UnknownError ... SyntaxError: JSON Parse error: Invalid escape character U`
> with an opaque 500 — which reads exactly like a key fault. Write probe
> bodies with `[System.IO.File]::WriteAllText(..., [System.Text.UTF8Encoding]::new($false))`
> (no BOM); `Set-Content -Encoding utf8` is fine on PowerShell 7 but carries a
> BOM on Windows PowerShell 5.1.

```powershell
& 'C:\Program Files\Paseo\resources\bin\paseo.cmd' provider diagnostic opencode   # Status Available
& 'C:\Program Files\Paseo\resources\bin\paseo.cmd' status                          # workerPid changed
```

## Provider shows "Not installed" / OpenCode binary not found

A *different* failure — nothing launched, so there is no auth error. Usual cause:
a Windows User `PATH` truncated at 1024 chars by `setx`, dropping
`…\Roaming\npm`. Full diagnosis and repair: [REFERENCE.md](../../REFERENCE.md)
§ Runbook C.