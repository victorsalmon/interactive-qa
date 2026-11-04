# Credentials Rescue — shared reference

Adjacent reference for [SKILL.md](SKILL.md) and its runbooks. Shared detail every
runbook needs: safe reads of credential-bearing dotfiles, the facts of the world,
and the long-form procedures.

Runbooks: [salmon-run](skills/salmon-run/SKILL.md) ·
[paseo](skills/paseo-rescue/SKILL.md) · [aws-store](skills/aws-store/SKILL.md) ·
[watch](skills/watch/SKILL.md).

## Safe reads — credential-bearing dotfiles

Some dotfiles are **credential files that look like config**. `~/.npmrc` is the
one that has burned us: a live npm registry token sits beside the harmless
`prefix=` line, and a blanket `Get-Content` on the assumption "it's just
config" is how a credential lands in a transcript.

Never read a file wholesale before classifying it. Default to masking **every**
value and reveal one only from an explicit allowlist you have already confirmed
is not a credential — the machine rule is *mask by value shape, never by field
name*, because a key that looks harmless can hold the credential:

```powershell
# shape-masking read: key NAMES + value lengths; values only from $show
$show = @('prefix')   # allowlist: add a key ONLY once its value is confirmed non-secret
Get-Content <file> | ForEach-Object {
  if ($_ -match '^\s*#|^\s*$') { return }
  $k,$v = $_ -split '=',2
  if ($null -eq $v) { Write-Host $k.Trim(); return }
  $k = $k.Trim(); $v = $v.Trim()
  if ($show -contains $k) { Write-Host "$k=$v" } else { Write-Host "$k len=$($v.Length)" }
}
```

`npm config list` and `npm config get <key>` can echo the token too — npm's own
output is credential output. When all you need is the shim directory, ask for
the non-secret value: `npm config get prefix` returns a path.

Known credential-bearing dotfiles on this box (read masked, never wholesale):
`~/.npmrc` (registry `_authToken`, plus the `prefix` line),
`~/.aws/credentials`, `D:\opencode-data\opencode\auth.json` (live, per
`XDG_DATA_HOME`) and `$env:CL_REPOS_ROOT\Tools\opencode-data\opencode\auth.json` (legacy
copy), `~/.salmon/.env`, and the operator-held `restore.zip` / `restore.txt`
bundle (untracked from the tree by `ca236ac6`).

An accidental whole-file print is a **logged disclosure**, not a silent
mistake: append an `action: "accidental-display"` line to
`$env:CL_REPOS_ROOT\Tasks\Logs\credential-changes.jsonl` (schema `actor, ts, action,
repo, secret, profile` — `secret` names the field, never holds the value) and
tell the operator to rotate the exposed credential.

## Error taxonomy (canonical)

Single copy — `Test-GoKey.ps1` emits these tokens; the watch loop rescues **only**
on `EXHAUSTED`. Do not copy this table into runbooks; link here.

| Token | Meaning | Rescues? |
| :-- | :-- | :-- |
| `OK` | answered `pong` | no |
| `EXHAUSTED` | weekly usage / rate-limit text (`usage limit`, `Go usage`, `rate_limit`, `429 … limit`) in CLI output **or** the time-scoped log | **yes** |
| `NOT-SUBSCRIBED` | `subscription is required` / `active OpenCode Go subscr` — monthly term lapsed, no payment | no (and never a rescue *target*) |
| `BUSY` | provider busy / transient upstream — retried `-MaxRetries` times first | no |
| `TRANSPORT` | `encrypted_content` / Responses-API replay defect | no |
| `AUTH` | `unauthorized` / `invalid api key` / `401` / `403` | no |
| `TIMEOUT` | no answer **and** no usage-limit signature (retried first) | no |
| `ERROR` | anything else | no |

Three classes never conflated: **EXHAUSTED** (weekly cap → cut over),
**NOT-SUBSCRIBED** (account-side → operator renews, never a target),
**BUSY/TIMEOUT** (transient → retry same key).

### Classify a canary failure before believing it (canary-defect class)

A canary whose own CLI invocation is stale reports a **NAME/KEY failure on a
healthy key**. Observed live 2026-10-22: `Repair-Paseo.ps1` threw
`post-restart name canary failed` on a key that answered `pong` seconds later.

| Canary symptom | Class | Action |
| :-- | :-- | :-- |
| `Unexpected positional argument: "<provider>"` | CANARY-DEFECT | `opencode models` takes **no** provider argument - list and filter |
| `Unrecognized flag: --variant` | CANARY-DEFECT | variant is part of the model id: `-m provider/model#variant` |
| `Go usage limit exceeded` from a canary that did **not** pass `--standalone` | STALE-SERVICE - not a verdict on the key | re-run with `--standalone`; see § The CLI's background service caches its credential |

Whenever a canary fails with CLI usage text (DESCRIPTION/USAGE/FLAGS), fix or
bypass the canary — never cut over the key a second time on that evidence.

## Wallet truth — probe keys directly (no CLI, no cached env)

The CLI and the Paseo helper both cache env at spawn, so a CLI `usage limit`
answer can belong to the **previous** key. To learn which keys are actually
alive, POST to the Go endpoint once per key from a process whose env you set
explicitly. Values never printed; only HTTP status and `metadata`.

```powershell
foreach ($k in 1..5) {
  $v = [Environment]::GetEnvironmentVariable("OPENCODE_GO${k}_KEY", "Machine")
  if (-not $v) { "GO${k}: MISSING"; continue }
  $body = @{ model='deepseek-v4.1-flash'; max_tokens=8;
             messages=@(@{role='user';content='ping'}) } | ConvertTo-Json -Depth 5
  $h = @{ Authorization="Bearer $v"; 'Content-Type'='application/json';
          'x-opencode-session'="ses_probe_" + [guid]::NewGuid().ToString('N') }
  $r = Invoke-WebRequest 'https://opencode.ai/zen/go/v1/chat/completions' -Method Post `
        -Headers $h -Body $body -TimeoutSec 60 -SkipHttpErrorCheck
  "GO${k}: HTTP $($r.StatusCode) $($r.Content)"
}
```

Reading the answers:

| Answer | Meaning |
| :-- | :-- |
| `400 MissingSessionID` | header omitted — the probe is malformed, not a key verdict |
| `400 ModelProtocolUnsupported` | **key is healthy**; this model needs the Responses protocol, not `chat/completions` |
| `429 GoUsageLimitError` + `metadata.limitName` | exhausted — `weekly` (cut over) or `monthly` (account term) |
| `metadata.workspace` | keys can serve different workspaces; a `monthly` 429 is workspace-wide, not key-wide |

`opencode run --standalone …` is the same idea through the CLI: it starts a
private server with the **calling process's** env, so it is the only CLI mode
that proves a key you just set by hand. The default (service) mode proves what
the *long-lived* server holds, which is the next section.

**2026-10-25 incident — this is not theoretical.** `Test-GoKey.ps1` used the
default (service) mode, so all five pool keys reported `EXHAUSTED` in one sweep
while a direct probe answered HTTP 200 for GO1/GO3/GO5. Cause: the standalone
`opencode serve --service` was still holding GO2, whose **monthly** limit had
lapsed, so every `opencode run` inherited GO2's verdict. `Test-GoKey.ps1` now
passes `--standalone`, and a returned `pong` outranks the shared log. Corollary:
a *green* sweep from the pre-fix script was equally meaningless (all five keys
read `OK` earlier the same hour only because GO2, the service's frozen key, was
healthy then) — a pool sweep is only worth reading when it comes from standalone
runs.

## The third consumer — `opencode serve --service`

The seam projects three surfaces, but a workstation has **three** independent
consumers, not two:

| Consumer | Env source | Picks up a cutover? |
| :-- | :-- | :-- |
| Salmon Run lanes | Machine/User env + `~/.salmon/config.json` | yes (config projection) |
| Paseo helpers (`opencode.exe serve` spawned by Paseo) | `~/.paseo/config.json` pin | only after `Repair-Paseo.ps1` restart |
| **Standalone CLI service** (`opencode.exe serve --service`) | env frozen at spawn | **no — must be killed** |

A `serve --service` process started before the cutover keeps answering with the
**old** key's quota error, so every `opencode run`/CLI canary looks exhausted
while the new key is healthy. Detect by start time, then let it respawn:

```powershell
Get-Process opencode | Select-Object Id, StartTime
Get-CimInstance Win32_Process -Filter "ProcessId=<pid>" |
  Select-Object CommandLine        # confirm 'serve --service'
Stop-Process -Id <pid> -Force      # next CLI call respawns it with current env
```

## The CLI's background service caches its credential

Measured 2026-11-02, the same minute as a cutover that "failed" on a healthy key:

```powershell
# same key (GO3), same command, only the server mode differs
opencode run 'reply with the single word pong' --model opencode-go/deepseek-v4.1-flash              # exit 1  "Go usage limit exceeded"
opencode run 'reply with the single word pong' --model opencode-go/deepseek-v4.1-flash --standalone # exit 0  pong
```

1. **`opencode run` does not run in your process.** It hands the session to a
   long-lived background service that resolves the credential **it** started
   with. Writing `OPENCODE_GO_KEY` / `OPENCODE_API_KEY`, or rewriting
   `auth.json`, does not change what that service uses - and it kept answering
   with the pre-cutover key's quota error for the rest of the day.
2. **Every canary must run `--standalone`** (private server, inherits *this*
   process's environment), or the service must be explicitly restarted. A
   canary that is not standalone measures the service, not the key.
3. **`Go usage limit exceeded` from a non-standalone canary proves nothing about
   the key.** It is a stale-service signal: on 2026-11-02 it was returned for
   *every* pool key, including one serving live traffic at that moment. Do not
   rotate a credential on it and do not read it as exhaustion of the active key -
   check the meters (`scripts/Get-GoKeyUsage.ps1`), then re-run with
   `--standalone`.
4. **A stored credential in the CLI auth store shadows the environment.** Ask
   `opencode auth list` which source is in force (`environment` vs `stored`, per
   provider; it prints sources, never values). If a stored `OpenCode Go` entry
   disagrees with the seam, treat it as drift: remove or realign it and append
   the change to `$env:CL_REPOS_ROOT\Tasks\Logs\credential-changes.jsonl`.
5. **Recovery, one line each.**

```powershell
opencode auth list                                                                    # which source is in force
pwsh -File scripts/Get-GoKeyUsage.ps1                                                 # what the meters say
opencode run 'reply with the single word pong' --model opencode-go/deepseek-v4.1-flash --standalone   # prove the key
Get-Process opencode | Select-Object Id, StartTime                                    # only if the service itself is suspect
```

`Switch-OpencodeGoKey.ps1` canaries with the key value it just wrote **and**
`--standalone`, and its canary line names the label (`key GO3`), so this cannot
silently regress. A non-standalone result from any other tool is not evidence.

## A missing `~/.salmon/config.json` silently drops `defaultCodingKey`

`Switch-OpencodeGoKey.ps1` warns (`runtime config not found … defaultCodingKey
not projected`) and **continues** — leaving exactly the 2026-10-15 condition:
lanes prefer a stale key ahead of the fresh one. After any cutover, assert the
projection took instead of trusting the cutover's success line:

```powershell
(Get-Content "$env:USERPROFILE\.salmon\config.json" -Raw |
  ConvertFrom-Json).execution.defaultCodingKey     # must be the new pool key
```

If the file is absent but `config.json.bak-*` siblings exist, restore the newest
backup, then re-run the switch so the key and the concurrency caps are projected
onto the restored file. Do not hand-edit `defaultCodingKey`: the script also
must satisfy the spillover invariant
(`providerMaxConcurrent['opencode-go'] == keyMaxConcurrent[activeKey]`).

## Key freshness ledger — where exhaustion is tracked

**One place, two files.** The seam `assets/opencode-go-cutover.json` owns CONFIG:
`activeKey`, `poolOrder`, the caps, the canary set, the hygiene policy and the
metering `freshness.windows` definitions. The per-key OBSERVATIONS are RUNTIME
STATE and live at the seam's `observationsPath` in the profile state root:

```
$HOME/.salmon/State/credential-rescue/seam-observations.json
```

Why the split: the seam is tracked in git AND vendored as a manifest copy row, so
a file a watch cycle rewrites on a timer can never stay byte-stable — every Key
Watch write would dirty a tracked file and redden its own vendored row (the same
cause the provider lock was fixed for, cl-common-6j7). `Set-OpencodeGoFreshness.ps1`
writes the observations file and never the seam; `Get-OpencodeGoFreshness.ps1`
reads config from the seam and observations from the state root. A cold start
with no observations file reports an empty ledger plus the config's `activeKey`.

The observation record is the seam's former `freshness` payload minus `windows`
(which stay in config): `asOf` + `keys`.

```json
"freshness": {
  "asOf": "2026-10-28",
  "windows": {                     // the CYCLES themselves - defined once, referenced by meter name
    "rolling5h": { "label": "5-hour rolling", "kind": "rolling", "lengthHours": 5,  "percentOfMonthly": 20,  "tracked": false },
    "weekly":    { "label": "weekly", "kind": "aligned", "lengthDays": 7, "percentOfMonthly": 50, "tracked": true,
                   "boundary": { "weekday": "Sunday", "time": "17:00", "timezone": null } },
    "monthly":   { "label": "monthly term",   "kind": "term",    "lengthDays": null, "percentOfMonthly": 100, "tracked": true }
  },
  "keys": {
    "OPENCODE_GO2_KEY": {
      "state": "exhausted",          // fresh | exhausted | unknown
      "trippedMeter": "monthly",     // how the 429 presented: monthly (account term) | weekly (pool cap)
      "usage": { "used": 100, "of": 100 },   // binding summary: the fullest meter; null when unknown
      "resetsOn": "2026-11-10",      // binding summary: the reset that frees the key - the tripped meter's, or the tightest meter's
      "observedAt": "2026-10-28",    // NEWEST evidence for the row (newest meter reading, or a later probe)
      "evidence": "429 GoUsageLimitError limitName=monthly; ...",
      "meters": {                    // per-meter detail - the two meters refresh INDEPENDENTLY
        "weekly":  { "used": null, "of": 100, "resetsOn": null,        "observedAt": null },
        "monthly": { "used": 100,  "of": 100, "resetsOn": "2026-11-10", "observedAt": "2026-10-28" }
      }
    }
  }
}
```

The three things the operator asked the ledger to answer, and exactly where each lives:

| Question | Field |
| :-- | :-- |
| How exhausted is the **weekly** meter? | `meters.weekly.used` / `.of` |
| What **cycle** is the weekly meter, and how long is it? | `windows.weekly` — `kind: aligned`, `lengthDays: 7`, `boundary: Sunday 17:00`, `percentOfMonthly: 50` |
| When does the **weekly** window roll over? | `meters.weekly.resetsOn` (+ `renewsInDays` computed by the reader, and `nextRollover` / `anchorWeekday` / `anchorTime` derived so the date survives passing) |
| How exhausted is the **monthly** meter? | `meters.monthly.used` / `.of` |
| What **cycle** is the monthly meter, and how long is it? | `windows.monthly` — `kind: term`, `lengthDays: null`, `percentOfMonthly: 100` (the cycle is *to that key's anniversary*, so its length is not a fixed number of days) |
| When does the **monthly** term roll over? | `meters.monthly.resetsOn` (its day-of-month **is** that key's anchor day); the reader also derives `anchorDay` and `nextRollover` so the date stays answerable after a recorded `resetsOn` has passed |
| What about the 5-hour cap? | `windows.rolling5h` — `kind: rolling`, `lengthHours: 5`, `percentOfMonthly: 20`, **`tracked: false`** |
| **When was each of those figures last updated?** | `meters.weekly.observedAt` and `meters.monthly.observedAt` — **per meter**, because the two are read at different times |
| When was the key last checked at all? | row-level `observedAt` (newest of the meter readings, or a later probe) |
| When was the ledger itself last touched? | `freshness.asOf` |

**The three cycles, defined once** in `freshness.windows` (never hardcoded by a
reader). A Go limit is a per-model **monthly dollar allowance** sliced into three
windows — one allowance, three cycles, and they are *shares of the same budget*,
not independent quotas:

| Window | Cycle | Share of the monthly allowance |
| :-- | :-- | :-- |
| `rolling5h` | 5 hours, rolling | 20 % |
| `weekly` | 7 days, **aligned to Sunday 17:00** | 50 % |
| `monthly` | to the key's term anniversary | 100 % |

`rolling5h` is **deliberately not a ledger meter** (`tracked: false`): it heals
continuously, so it is read from a probe and never stored — see the rolling-cap
trap below. The weekly and monthly cycles *are* tracked, each with its own
reading date and roll-over instant.

**Weekly is a shared boundary, not per-key rolling — confirmed on all five keys
(2026-10-31).** The docs describe a 7-day rolling window, which would mean no
recurring anchor. It is not: GO1, GO2, GO3, GO4 and GO5 are five separate
workspaces, every one names **2026-11-01 17:00, a Sunday**, and they occupy every
possible weekly utilisation at the time (GO1 100 %, GO3 100 %, GO4 24 %, GO2 0 %,
GO5 0 %). Five workspaces cannot drift onto one instant, and usage is not what
determines it — so the weekly window closes on a common boundary: **Sunday 17:00**,
then Nov 8, Nov 15, …

Two consequences worth keeping in view:

- The pool gets its weekly reset **together**. A fleet-wide burst before the
  boundary pushes every key against the same wall instead of staggering across
  them, which is the exact shape that makes a burst look like five broken keys.
- `boundary.timezone` is `null` on purpose: every reading arrived from the Console
  as wall-clock with no zone, and this box runs `-07:00`. Record a zone only if it
  is ever confirmed against a UTC-stamped probe.

**Which meter binds first is a scheduling question, not a state question.** Both
meters are percentages of the *same* monthly allowance, so headroom is simply
`50 - weeklyUsed` points against `100 - monthlyUsed` points — but the weekly window
reopens every Sunday 17:00, which can restore 50 points in the middle of a term.
GO4 on 2026-10-31 is the worked example: 24 % weekly (26 points left) and 73 %
monthly (27 points left) are almost identical, yet the weekly window reopens in
~1.6 d and resets that cap to 50 against the remaining 27 monthly points. So GO4
will reach **100 % monthly and refresh the week without ever tripping the weekly
limit**. The ordering flips across the boundary, so state the assumption whenever
you predict: inside the current weekly window the two can be within a point of each
other, and a burst then trips whichever is smaller by one.

**The Console truncates its countdowns to whole units.** A reading of "weekly in
1d13h" converts to an instant that sits ~0.63 h *under* the true boundary, and the
same offset shows up on the monthly figure in the same reading, so it is one
rounding behaviour rather than measurement noise. Convert, then reconcile against
an already-recorded instant instead of trusting the arithmetic — and when the two
disagree, keep the recorded instant and note the derived one in `evidence`.

**A weekly reset does not free a monthly-capped key.** Row-level `resetsOn` is the
reset of the meter that *tripped* when a key is exhausted (GO2 is monthly-capped
to 2026-11-10 even though its weekly window reopens 2026-11-01). For a key that is
**not** exhausted it is the refresh of the **binding** meter — the one with the
least remaining headroom, weighed in points of the monthly allowance — not the
soonest date. GO4 at 99 % monthly with weekly at 24 % therefore reports
2026-11-13, not the Sunday boundary: the weekly window reopening adds room the
monthly meter will not let it spend.

**Monthly rolls over on the key's own anniversary, not on the calendar month.**
Each key's anchor day is the day-of-month of its `meters.monthly.resetsOn`
(GO1 23rd, GO2 10th, GO3 20th, GO4 13th, GO5 14th — all five known as of
2026-10-31). The reader derives `anchorDay` and `nextRollover` from that single
observation and clamps short months, so a day-31 anchor lands on the 30th/28th
instead of spilling into the following month.

**Two readings of one field that disagree beyond rounding: the newer one wins and
the older is retired.** GO5 was recorded at the 11th on 2026-10-28 and read as the
14th on 2026-10-31 — 3.81 days apart, which is neither Console truncation (0.63 h)
nor a timezone offset (max ~26 h), so it had to be either a re-anchored term or a
bad transcription. The operator resolved it: **today's reading was the accurate
one**, the 2026-10-28 figure was wrong, and it is retired in `evidence` rather than
kept as an alternative. Two habits follow:

- Never overwrite the older figure silently *when the disagreement is still
  unexplained* — record both and say which is live; then, once it is resolved,
  retire the loser explicitly so the row never carries two competing dates.
- Never carry a "re-anchored" theory forward as fact. Here the simple explanation
  (a bad reading) was correct, and the exotic one (the account moved the term) was
  not.

An anchor is still not permanent — if a term is admin-managed (renewal, plan
change, support adjustment), the Console wins and re-reading is what re-anchors it.

Each meter carries its **own** `observedAt` on purpose: a weekly reading taken
Nov 1 and a monthly reading taken Oct 28 must not collapse into one date, or you
cannot tell which figure went stale. `used: null` means **not reported** (a null
`observedAt` on an unreported meter is correct, not a gap). A `resetsOn` that is
already in the past means the figure **predates a roll-over** — the reader prints
`ROLLED OVER` and the number should be re-read, not trusted.

The operator always reports **both** meters ("fresh, weekly resets Nov 1 17:00, monthly
Nov 23"), so the row carries a `meters` object as well as the flat summary. Keep the
flat `state`/`trippedMeter`/`usage`/`resetsOn` fields authoritative for readers (the
freshness script and the watch loop read them); `meters` is the detail.

Three inputs feed it, and they are not interchangeable:

| Input | Owner | What it can answer |
| :-- | :-- | :-- |
| `freshness` observations file (`seam-observations.json` in the profile state root; `windows` stay in the seam config) | rescue/watch runs + the operator | recorded utilisation, reset dates, reading dates, last known verdict |
| `Test-GoKey.ps1` / direct probe | any agent, live | *is it working right now* (standalone CLI + HTTP `/v1/responses`) |
| `Tasks/Logs/credential-changes.jsonl` | scripts, append-only | *what changed, when, by which run* |

Rules: a probe verdict overwrites `state`/`trippedMeter`/`observedAt`/`evidence`
and never guesses at `usage`; `usage` and `resetsOn` come from the operator's
account UI (no API exposes the meter here). Stamp **the meter you actually read**
— every operator update sets `state`, `usage`, `resetsOn` and **that meter's
`observedAt`**, then refreshes the row-level `observedAt`/`usage`/`resetsOn`
summary and `asOf`. `monthly` is an account-term limit — a cutover cannot fix it,
only time or renewal can, which is exactly what `resetsOn` is for. Keep `asOf`
at the newest date any row was touched.

Read it with `scripts/Get-OpencodeGoFreshness.ps1` (add `-Probe` for the live
verdict per key, `-KeyNumber <n>` to narrow, `-Json` for machine-readable output
in an agent/coding loop, `-StaleDays <n>` to flag readings older than a week by
default); after any rescue or watch event, write the observed state back so the
next run starts from the truth.

Write it with `scripts/Set-OpencodeGoFreshness.ps1`, never by hand-editing the
JSON — the script is what keeps the per-meter `observedAt`, the row summary and
`asOf` consistent, and it validates before it writes:

```powershell
# record both meters for GO4 (each gets today's observedAt)
pwsh -File Set-OpencodeGoFreshness.ps1 -KeyNumber 4 `
  -WeeklyUsed 40  -WeeklyResets 2026-11-01T17:00 `
  -MonthlyUsed 73 -MonthlyResets 2026-11-13 `
  -Evidence 'operator Console read 2026-10-31'

# record only the weekly meter (the monthly figures and their date are untouched)
pwsh -File Set-OpencodeGoFreshness.ps1 -KeyNumber 3 -WeeklyUsed 100 -WeeklyResets 2026-11-01T17:00

# a probe verdict: state + which meter tripped, no guessed utilisation
pwsh -File Set-OpencodeGoFreshness.ps1 -KeyNumber 2 -State exhausted -TrippedMeter monthly `
  -Evidence '429 GoUsageLimitError limitName=monthly (direct probe)'

# mark a meter as not reported
pwsh -File Set-OpencodeGoFreshness.ps1 -KeyNumber 5 -Unknown weekly
```

**Close-out is part of the rescue, not an optional extra.** Every rescue ends with
one question to the operator — *what was the key you left reading, monthly and/or
weekly, and when does it reset?* — recorded above. Nothing else can fill it: there
is no usage API (below), and the operator is the only reader of the Console. If they
report only one meter, record only that meter; if they say the key was healthy and
the move was for headroom, record `state: fresh` with its utilisation. A rescue that
ends without a reading is an unfinished rescue, because the next run inherits a row
that is silently older than the event it describes.

This is the "where do my agents read it" answer: the ledger is git-tracked in a
Pro Repo (`cl-common`), so any agent in any repo reads it with
`Get-OpencodeGoFreshness.ps1 -Json` and records with `Set-OpencodeGoFreshness.ps1`
— no per-agent copy, no separate service.

## ETT - minutes, measured over a sample-history window

**ETT** (Estimated Time to Trigger) is quoted in **minutes**, never hours; the
older `hoursToTrigger` name is retired (`cl-common-f3r`). It is
`remaining / burnPerMinute`, where `remaining` is the points left to the binding
trigger and the burn comes from a bounded **sample history** in the state file
(`cadenceSamples[]`, 12 entries of `{ at, wk, mo }`) - the oldest sample that is
at least 15 minutes old (`window-15m`), or the oldest available one with the
reason `window-short` when the history is younger.

**Why not the previous poll.** Measuring against the immediately preceding
sample starved ETT by construction: once the gear tightened to 5 minutes (the
1-minute floor included), two consecutive polls were *closer together* than the
15-minute guard, so a qualifying pair never formed, `ettMinutes` stayed `null`
for the rest of the run, and the gear froze - it could neither tighten toward
the trigger nor loosen once the burn stopped (`cl-common-6yr`). The window is a
history rather than a delta, and a resumed run keeps it. Cadence table and
thresholds: `skills/key-check/SKILL.md` § Adaptive cadence.

## Quota interrogation — what the API can and cannot tell you

Measured on this box 2026-10-28. Short version: **there is no public
management/usage REST endpoint and no management key.** You cannot ask "how much
is left on GO<n>?" from one credential; you learn it per key, and only in the
terms below.

**How Go meters actually work.** Go/Go Plus limits are per-model monthly **dollar**
amounts, and each model's monthly limit is sliced into three windows:
5-hour = 20 % of the monthly limit, weekly = 50 %, monthly = 100 %
(<https://opencode.ai/v2/docs/console/go#usage-limits>). So "73 % consumed" is
73 % of *that model's* monthly dollar allowance, not a token count.

**The 5-hour rolling cap is the trap (2026-10-30).** Because the rolling cap is
only 20 % of the monthly allowance, a key can read "fresh, 0 % monthly" and
still 429 under a burst of parallel agents — and be answering `200` again
minutes later once the window rolls forward. That is exactly what happened: a
rescue moved Paseo from GO1 to GO4 at 03:06Z while GO1 probed healthy either
side of it. Consequences for this runbook:

- A single 429 under load is **not** proof a key is spent. Confirm with a direct
  probe (or two, minutes apart) before declaring a key exhausted, and record
  which meter tripped — `GoUsageLimitError.metadata.limitName` only distinguishes
  `weekly` from `monthly`, so a rolling-cap trip shows up as `monthly` on some
  routes and as a plain 429 on others.
- Because the rolling cap recovers continuously, the *worst* time to judge a key
  is 30 seconds after a fan-out of agents starts.
- Prefer the key with the most monthly headroom when the burst is over; a key at
  0 % monthly with a tripped rolling cap is healthier than one at 73 %.
- The ledger has no rolling field on purpose (it is a live, self-healing signal).
  Read it from a probe, never store it as state.

**What a key can tell you about itself.**

- **A successful response** carries `usage.opencode.allowance` (dollars this
  request counted toward the monthly limit) plus `opencode.billing_source`
  (`go` / `go-plus`) and `opencode.list_cost`. That is consumption accounting,
  not remaining budget.
- **A 429** returns `GoUsageLimitError` with `metadata.limitName` (`weekly` or
  `monthly`) and `metadata.workspace` (`wrk_…`) — no remaining amount and **no
  reset timestamp**. Verified against a monthly-spent key and a weekly-spent key
  on 2026-10-28. This is why `Test-GoKey.ps1` can classify EXHAUSTED but why
  `resetsOn` is operator-only. A direct probe must send `x-opencode-session`
  (and a real user-agent) or the API answers `400 MissingSessionID` before it
  ever reaches the quota check.

**The one real endpoint — local, newer builds only.** The v2 OpenAPI documents
`GET /api/experimental/usage/limits` (tag `usage`):

```jsonc
{ "workspace": { "id", "name", "usageURL" },
  "go": { "rolling": { "percent", "limited", "resetsAt" },   // 5-hour window
          "weekly":  { ... },
          "monthly": { ... } },
  "budgets": [ { "limit", "spent", "scope", "models", "resetsAt", ... } ] }
```

`resetsAt` is Unix **milliseconds** — exactly the refresh data no other call
exposes. Call it with `opencode api GET /api/experimental/usage/limits`.
**This box's v2.1.2 server does not implement it** (absent from its
`/openapi.json`; returns 404), so it lands only after an `opencode upgrade`.
It answers for **one signed-in workspace**, i.e. one pool key at a time — a
different key is a different `wrk_…`, so there is nothing to "manage" centrally.

**Console API keys.** A Console key can be scoped with **Usage: Read**, but the
public Console API documents only Inference and Providers; no usage/billing REST
operation is published. The authoritative UI view is
`https://opencode.ai/console` (and the per-workspace `usageURL`).

**So how does the fleet track quota today?** Three inputs, none a live meter:
the 429 `limitName` on a probe (which meter tripped), the operator's Console
readings (`usage` + `resetsOn`), and this ledger. When `opencode` is upgraded
past 2.1.2, `usage/limits` becomes a fourth, machine-readable source — prefer it
then, and still write the result back here.


## Runbook A — switch opencode + Paseo to a non-exhausted key

> **Fast path: Paseo first, completely; then ask before the other surfaces.**
> For the common case — the operator names an exhausted key and a fresh one —
> replace the **Paseo surface in full first**:
> `scripts/Repair-Paseo.ps1 -KeyNumber <n>` (provider-env pin + DSH `apiKeyEnv`
> repoint + worker restart + verify both harnesses). Then **ask the operator**
> whether to replace the remaining surfaces, and only on approval run the Salmon
> cutover `scripts/Switch-OpencodeGoKey.ps1 -KeyNumber <n>` (User env +
> `auth.json` + `~/.salmon/config.json`, hygiene, canary) and the standalone
> `opencode.exe serve --service` kill. Do not fan a cutover across every consumer
> without that ask: the Paseo surface must be incontrovertibly on the new key
> first, and the rest is a separate approved step. This section is the long form:
> the manual checklist, every edge, and the model-transport class.
>
> The seam `assets/opencode-go-cutover.json` owns `activeKey`, `poolOrder`, the
> caps, the canary set, and the hygiene policy — CONFIG ONLY, because it is both
> tracked and vendored. The script projects the seam onto
> User env + `auth.json` + `~/.salmon/config.json` (`defaultCodingKey` and the
> caps) and writes the new `activeKey` back, so the seam and reality never drift.
> Canary mode is `fast` (fleet default worker only) unless `-Full` is passed;
> hygiene is `auto` (count first, strip only when poisoned parts exist).

Automated: `scripts/Switch-OpencodeGoKey.ps1 -KeyNumber <n> -DryRun` first,
then without `-DryRun`. The script repoints `OPENCODE_GO_KEY` +
`OPENCODE_API_KEY` (User), `auth.json` `opencode-go`, and
`~/.salmon/config.json` `execution.defaultCodingKey` (+ caps), and logs the
change. It **pre-checks the configured model name/endpoint/transport first**,
then canaries the new key **explicitly and standalone** (see § The CLI's
background service caches its credential) against the configured model at its
real variant plus the seam's canary models (`-Full` adds every other model in
the seam's `full` block); every canary line names the label (`key GO3`).

A cutover is **all-or-nothing**. The exact pre-switch bytes of the seam,
`auth.json` and `~/.salmon/config.json` - and the pre-switch User values - are
captured before the first write (`~/.salmon/State/key-check/cutover-snapshot/`).
If any canary fails the script restores all of them and exits **1** with
`rolled-back`: the machine is never left with surfaces that disagree. If that
restore itself fails it writes a **label-only** marker
`~/.salmon/State/key-check/partial-cutover.json`
(`{from, to, surfaces, at, runId}` - never a value) and exits **6**;
`Invoke-KeyCheckCutover.ps1` (or `Switch-OpencodeGoKey.ps1 -ResumePartial`)
then completes the recorded target when it is still the requested key, or
reverts to the recorded `from` key, and clears the marker.

It also runs **session hygiene** (count stored `metadata.openai` reasoning
parts; strip them only when some exist, backed up first) before the canary —
`-SkipSessionCleanup` / `-SkipHygiene` bypass it.
`-SkipCanary` bypasses the canary set (CLI unavailable only). `-RetirePoolKey <n>`
additionally clears a dead pool key's Machine var so lanes stop selecting it
(pool picks resolvable+under-cap, not healthy); it runs only after the cutover
proved out, so a rolled-back cutover never retires a key.

`auth.json` is only rewritten when the provider entry already exists, so the
success line can read `auth.json updated providers:  (backup …)` with an empty
list on a box whose auth store has no `opencode-go`/`opencode` entry (this box,
2026-10-25: only `deepinfra` + `openrouter`). That empty list means *nothing was
written*, not "auth.json now holds the new key" — there opencode resolves the
key from `OPENCODE_GO_KEY`/`OPENCODE_API_KEY` in the environment, so the cutover
still works. Verify a projection by fingerprint, never by that line's shape.

Manual checklist (what the script does + what it can't):

1. Identify the active key: compare `OPENCODE_GO_KEY` (User) against each
   `OPENCODE_GO<n>_KEY` (Machine) — match tells you which pool key is live.
   Compare only, never print.
2. Repoint `OPENCODE_GO_KEY` and `OPENCODE_API_KEY` (User scope) to the new
   pool key's value.
3. Update the **live** `auth.json`, i.e. `$env:XDG_DATA_HOME\opencode\auth.json`
   (User `XDG_DATA_HOME` — `D:\opencode-data\opencode\auth.json` on this box).
   The path this runbook used to name,
   `$env:CL_REPOS_ROOT\Tools\opencode-data\opencode\auth.json`, is a legacy 113-byte stub
   with no `opencode.db`: writing there silently changes nothing. Repoint
   `."opencode-go".key` (and `."opencode".key` if present), backing it up
   first. `scripts/Switch-OpencodeGoKey.ps1` resolves the same way by default.
4. **Restart Paseo + stale helpers** — Paseo hosts opencode sessions inside
   long-lived `opencode.exe serve --port <n>` helper servers ("generations";
   registry `~/.paseo/runtime/managed-processes/*.json`; spawned with cwd
   `~/.paseo/opencode-home`, a deliberate neutral scratch dir). Both daemon and
   helpers freeze env at spawn — check `paseo.pid` `startedAt` and each
   helper's process CreationDate against the repoint time; anything older
   still holds the dead key. `auth.json` repoints do NOT reach running
   helpers (verified 2026-09-18: requests kept failing on the retired key one
   minute after the repoint). Restart the app/daemon and kill any surviving
   pre-change `opencode.exe serve` PIDs (`Win32_Process` filter on the
   command line); the daemon spawns fresh helpers on demand with the new env.
   Sessions persist in `opencode.db` — a helper swap loses at most one
   in-flight turn; history is intact. `~/.paseo/config.json`
   `agents.providers.opencode` has no env block → pure env inheritance.
    **Automated:** `scripts/Repair-Paseo.ps1` pins the provider `env` and
    restarts the daemon worker so fresh helpers inherit the new key
    (`-FullApp` fallback re-opens the Desktop app with a composed current
    child env). `Restart-Paseo*.ps1` are deprecated shims forwarding there.
    The same script covers the **deepseek-harness** child too (verifies its
    `apiKeyEnv` key + diagnostic; a worker restart respawns it with the
    current Machine/User env — there is no DSH pin). Full per-harness detail:
    the `paseo-rescue` runbook.

    > **Never "repair" DSH by re-running the installer (2026-10-31).**
    > `salmon-run Tools/Install-PaseoDeepSeekHarness.ps1` owns the file, but it
    > *rewrites* `~/.dsh/profiles/acp/salmon-run-model.yml` from its own defaults:
    > it resets `apiKeyEnv` to `DEEPSEEK_API_KEY`, **drops the
    > `baseURL: https://opencode.ai/zen/go/v1` line**, and raises
    > `reasoningEffort` low → high. On this box the DSH route goes through
    > opencode-go with a pool key, so the installer silently breaks it (and warns
    > that `DEEPSEEK_API_KEY` is unset, which is the symptom, not the cause).
    > When the DSH diagnostic reads `Status Error` / `child did not launch`, use
    > `Repair-Paseo.ps1 -DshKeyNumber <n>` (repoints `apiKeyEnv` only) and verify;
    > run the installer only for a genuinely missing/broken binary, and afterwards
    > restore `apiKeyEnv`, `baseURL`, and the effort setting — compare against the
    > newest `salmon-run-model.yml.bak-*`.
   Surgical alternative when a daemon restart is inconvenient: kill the helper
   PID and respawn `opencode.exe serve --port <same>` yourself with the new
   key exported in the spawning shell and `-WorkingDirectory
   ~\.paseo\opencode-home` — verified serving 2026-09-18, but whether the
   daemon adopts a manual respawn vs spawning its own (stale-env) generation
   on next demand is unverified; daemon restart remains the deterministic
   path.
5. Salmon Run lanes: no action if the new key is already higher-priority in
   the pool. If the EXHAUSTED key is a pool key, it still resolves and lanes
   keep dying on it — either `-RetirePoolKey` it, or flip `OPENCODE_GO<n>_ON`
   in SM `ClockLobster/Salmon-Run` and re-run `Sync-SalmonRunCodingKeys.ps1`
   (needs working `~/.aws`).
6. Append the credential-changes.jsonl line (script does it).
7. Canary: `opencode run "ping" --model opencode-go/deepseek-v4.1-flash --variant low`.
   To probe a live helper instead: `POST http://127.0.0.1:<port>/session/<ses_id>/message`
   with `{"model":{"providerID":"opencode-go","modelID":"<m>"},"agent":"build","parts":[{"type":"text","text":"reply pong"}]}`.
   Check the live `$env:XDG_DATA_HOME\opencode\log\opencode.log`
   (`D:\opencode-data\opencode\log\opencode.log` here) for
   `rate_limit_exceeded`/`usage_limit_exceeded` vs auth errors. Signature note:
   `Weekly usage limit reached. Resets in N days` = GO subscription cap (key
   exhaustion — this runbook); `Insufficient balance` on `providerID=opencode`
   (built-in zen provider) is workspace balance, a different wallet — not a GO
   key issue. A THIRD class (distinct from weekly exhaustion): `An active
   OpenCode Go subscription is required to use Go models.` = the key's **monthly
   term lapsed with no scheduled payment** (NOT-SUBSCRIBED; live example GO5,
   2026-10-10). Repointing to such a key changes nothing — fix is account-side
   (renew/subscribe, operator-owned). Do not treat it as an exhaustion cutover
   target. Detection + unattended handling: `credential-rescue` § watch
   (`skills/watch/SKILL.md`).

   **Model pre-check + canary set (mandatory since 2026-10-09).** A key cutover
   can surface a latent **model-transport** defect that is invisible until the
   new caller replays account-bound reasoning — the
   `reasoning encrypted_content was not issued to this caller` error. It is NOT
   a credential failure, and a `--variant default` ping is a **false green**
   (it passes while the model's real reasoning variant fails). So:

   - **Before touching the credential**, resolve and print the configured
     `opencode-go` model *name*, its `baseURL`, and its transport `npm` from
     `$env:XDG_CONFIG_HOME\opencode\opencode.jsonc`. If the transport is the
     Responses API (`"npm": "@ai-sdk/openai"`) and the variants include
     `reasoning.encrypted_content`, warn — that pairing is what turns a key
     switch into the encrypted_content error on existing sessions.
   - **After the repoint**, canary the configured model **at its real variant**
     *and* the two fleet-standard `opencode-go` models, each at the correct
     endpoint/variant: `opencode-go/deepseek-v4.1-flash --variant low`
     (the fleet default; `high` for complex work) and
     `opencode-go/deepseek-v4-pro --variant max`.
   - `Test-OpencodeProvider.ps1` now defaults to the model's configured variant
     and detects the `encrypted_content` / `not issued to this caller` /
     `invalid_request_error` signature as a **model-transport** failure (distinct
     from credential/quota), so it exits non-zero instead of passing.

   `Switch-OpencodeGoKey.ps1` performs the pre-check and the whole canary set
   itself; it canaries the new key standalone and **rolls every surface back**
   when a canary fails (exit 1, `rolled-back`), so a failed cutover never leaves
   the machine split. `-SkipCanary` bypasses it (only when the CLI is
   unavailable); `-OpencodeCli` / `-ConfigPath` override resolution.

   **Encrypted_content class — root cause & repair (verified 2026-10-09).** The
   failure is *account-bound reasoning replay*, not a dead model. The model path
   is already correct; the defect is the transport. The Responses API
   (`@ai-sdk/openai` — either a model-level `npm` pin or the provider-level pin
   in `opencode.jsonc`) persists reasoning items carrying
   `metadata.openai.reasoningEncryptedContent`, bound to the caller (account/key)
   that issued them. Continuing a pre-switch session on the new key replays them
   and the upstream rejects the request with `reasoning encrypted_content was
   not issued to this caller`. Diagnostic tell: a **fresh** session on the new
   key passes; an **existing** session fails.

   **The durable prevention is session hygiene on every cutover**, which
   `Switch-OpencodeGoKey.ps1` now performs automatically (`-SkipSessionCleanup`
   to bypass): before the canary it strips `metadata.openai` from every part
   that carries an encrypted-reasoning item, backing the rows up to
   `%TEMP%\opencode-encrypted-reasoning-<utc>.json` first. Manual equivalent
   (back the rows up first):

   `UPDATE part SET data=json_remove(data,'$.metadata.openai') WHERE
   json_extract(data,'$.metadata.openai.reasoningEncryptedContent') IS NOT NULL;`

   (add `AND session_id='<id>'` to scope one session). A separate, larger-blast-
   radius alternative — dropping the provider-level `"npm": "@ai-sdk/openai"`
   pin so models use their built-in transports — is NOT applied by default: it
   changes every opencode-go model's transport, whereas hygiene fixes the class
   without that risk.

**Credential resolution per provider (verified 2026-09-19):** `opencode-go`
resolves its key ONLY from `OPENCODE_GO_KEY`/`OPENCODE_API_KEY` env vars —
the `auth.json` `opencode-go` entry is NOT consulted by spawned opencode
processes (env cleared + auth.json present = "Missing API key"). So for
workers/helpers the repoint's env half is what matters, and helpers only
get it via daemon env inheritance → daemon restart is mandatory, not
optional, after a repoint that must reach spawned agents. `deepinfra` /
`openrouter` DO read `auth.json` at spawn — repointing auth.json reaches
them without a daemon restart.

**Whole-pool-exhausted fallback:** when every `OPENCODE_GO<n>` key is spent
(weekly cap, all five), don't spawn doomed workers — hold the wave and
rotate/rescue keys (Runbook A), then re-dispatch on the fleet default worker
model `opencode/opencode-go/deepseek-v4.1-flash` (at `low`; `high` only for
complex logic/edge cases/multi-step invariants). Audit runs of every
kind (Complete, IQA, Paseo, attached or detached) stay on the default model:
verify the rescued key with
`$env:CL_REPOS_ROOT\cl-common\Skills\iqa-mode\scripts\Test-OpencodeProvider.ps1 -Model
opencode-go/deepseek-v4.1-flash` before re-dispatching (non-audit
one-offs remain an operator call). The same canary script preflights any
`opencode/*` provider/model before a dispatch.

**OpenCode settings restore** (config loss, not key exhaustion): an
operator-held bundle at `restore\opencode\` restores `opencode.jsonc`,
`plugins/`, `package.json`, and repairs the `XDG_CONFIG_HOME` /
`XDG_DATA_HOME` / `OPENCODE_CLI_PATH` User pointers; `-WithAuth` also restores
`auth.json` + `mcp-auth.json` from an AES-256 zip unlocked by `restore\restore.txt`.
The bundle was untracked from the tree by `ca236ac6` and is absent here — get the
copy from the operator before planning around it. `opencode.db` / `log/` /
`tool-output/` are runtime state and are never bundled.

## Runbook B — restore `~/.aws` after deletion

Automated: `scripts/Restore-AwsStore.ps1` (PS 5.1+).

```powershell
# inspect
pwsh -File scripts/Restore-AwsStore.ps1 -Mode Status
# rebuild: operator bundle -> newest backup -> encrypted backup -> -CredentialsFile -> session-DB scrape -> config template
pwsh -File scripts/Restore-AwsStore.ps1 -Mode Restore -FromSessionDb
# prove it (prints profile names + caller ARNs only)
pwsh -File scripts/Restore-AwsStore.ps1 -Mode Verify
# reseed the off-.aws snapshot so the next deletion is a file-copy restore
pwsh -File scripts/Restore-AwsStore.ps1 -Mode Backup
```

Restore source order: **operator bundle** (`-RepoZipDir`, default the repo
`restore\` dir — untracked by `ca236ac6` and absent here, so the script skips
it) → `~/.salmon/Backups/aws-store/latest` → newest
`.enc` backup (AES-256, key = `AWS_CRED_BACKUP_KEY` in `~/.salmon/.env`) →
`-CredentialsFile` → session-DB scrape (Devin `cli/sessions.db`, transcripts,
summaries; opencode-data `opencode.db`, `tool-output`, `snapshot` under the
live `$env:XDG_DATA_HOME\opencode`, i.e. `D:\opencode-data\opencode` here — the
2026-09-15 03:38 restore recovered keys this way) → `config` template +
operator-pasted `credentials`. **Backups live under `~/.salmon`, never inside
`~/.aws`** — the cleaner wipes the whole `.aws` dir including `backups/`.

The bundle is the operator-curated encrypted snapshot of `.aws`:
`restore.zip` is the encrypted archive, `restore.txt` its password,
`restore.ps1` performs the restore (dry-run default; `-Apply` extracts to
`%TEMP%` via 7-Zip, snapshots any existing `~/.aws` files to
`~/.salmon/Backups/aws-store/pre-ziprestore-<utc>/` first, verifies via
`sts`, logs names-only). It was **untracked from the tree** by `ca236ac6` and is
absent here — take the copy from the operator. **Never print, quote, or copy its
contents** into logs, chat, memory, or commits.

If nothing is recoverable: operator creates fresh IAM keys in the console
(or pastes them), then `-CredentialsFile <path>` or direct paste, then
`-Mode Backup`. Rotate afterwards per `salmon-run/secret-rotation-policy.json`.

The same cleanup class also wiped `~/.config` (Devin's global skill pointers
at `~/.config/devin/skills` are one-line redirect files — recreate from the
canonical SKILL.md frontmatter per
`Skills\git-operations\harness-compatibility.json`) — any `~/.*/` folder
vanishing is this incident class.

## Runbook C — Paseo can't find opencode (binary/PATH, not key exhaustion)

This is the repair to run when the operator says "my config for opencode in
Paseo is broken". It is **not** a key problem, so Runbook A does not apply and
no `OPENCODE_GO*` variable is at fault.

**Symptoms.** `paseo daemon status --json` reports
`"provider": "opencode", "available": false`; `paseo provider diagnostic
opencode` ends `Status: Unavailable` / `Error: OpenCode binary not found…`; and
`~/.paseo/daemon.log` repeats `Provider 'opencode' is not available. Please
ensure the CLI is installed.` No auth error appears, because nothing launched.

**Usual cause: the Windows User `PATH` was truncated.** `setx PATH
"%PATH%;…"` expands the *combined* Machine+User PATH into the User value, then
caps the write at **1024 characters**, cutting the tail mid-entry. That tail is
where `…\AppData\Roaming\npm` — the `opencode` shim — lives, so `opencode`
stops resolving for everything launched afterwards. Fingerprints:

- `[Environment]::GetEnvironmentVariable('PATH','User')` is *exactly* 1024
  chars and its last entry is a partial path (e.g. `C:\Users\RDP\AppData\`);
- the User `PATH` contains a duplicated copy of the Machine `PATH`;
- `winget` and `wt` are unresolvable too — their
  `…\AppData\Local\Microsoft\WindowsApps` entry was cut by the same write.

**Diagnose (read-only).**

1. `paseo daemon status --json` → `available: false` for opencode.
2. `paseo provider diagnostic opencode` → `Command source: default` with
   `Resolved path: not found` is the PATH case; `Command source: override`
   means a config pin already exists and the fault is elsewhere.
3. Compare the User `PATH` against a fresh login shell; length exactly 1024
   means truncated.

**Repair.**

1. **Pin the binary** so Paseo never depends on `PATH` again. Add to
   `~/.paseo/config.json` → `agents.providers.opencode`:

   ```json
   "command": ["$env:CL_REPOS_ROOT\\Tools\\opencode-standalone\\node_modules\\opencode-ai\\bin\\opencode.exe"]
   ```

   then `paseo reload`. `command` is `[binary, ...args]` and replaces the
   provider's default launch command; it does **not** change env inheritance,
   so Runbook A's key half still applies.
2. **Restore the User `PATH` tail** in `HKCU:\Environment` (value kind
   `String`). Replace the dangling fragment with the real entries:
   `…\AppData\Local\Microsoft\WindowsApps`, `…\AppData\Roaming\npm`,
   `…\AppData\Local\npm-global` (the live npm prefix per `~/.npmrc`), and
   `$env:CL_REPOS_ROOT\Tools\opencode-standalone\node_modules\.bin` (the fleet install
   `OPENCODE_CLI_PATH` names). Back the old value up first, and prefer
   `[Environment]::SetEnvironmentVariable(...,'User')` over `setx` — it has no
   1024 cap and broadcasts the change; `setx` is what caused this.
3. **Restart Paseo.** The running daemon caches provider launch settings at
   startup: `provider-snapshot-manager` logs `OpenCode server manager already
   initialized with different runtime settings` (`existing {}` versus the
   requested `command`), and `paseo reload` cannot apply it. On Windows Paseo
   uses the environment it was launched with, so a **full Desktop restart** is
   what also picks up the repaired `PATH`; a daemon-only restart is enough to
   apply the `command` pin. Warn the operator first — restarting the daemon
   ends every agent session it hosts, including yours.

**Verify.** `paseo provider diagnostic opencode` → `Status: Available` with the
expected `Auth` rows, then canary with
`$env:CL_REPOS_ROOT\cl-common\Skills\iqa-mode\scripts\Test-OpencodeProvider.ps1 -Model
opencode-go/deepseek-v4.1-flash`. A resolvable binary can still fail on
a spent key; the canary is what separates the two failure classes.

## Runbook D — verification traps after a cutover

Two traps that make a healthy cutover look broken. (The wallet probe, the
`serve --service` consumer, and the missing-`config.json` check are the sections
above, before Runbook A — this runbook only covers what they do not.)

### 1. Canary commands age out with the CLI

Both `Test-PaseoMuseSparkCanary.ps1` and `Test-GoKey.ps1` call
`opencode models <provider>` and `opencode run --variant <v>`; the installed CLI
rejects both (positional arg to `models`, and variant is now `-m model#variant`).
A canary that fails with `Unexpected positional argument` or
`Unrecognized flag: --variant` is a **tooling** failure, never `KEY` — classify
it separately and prove the credential with the direct wallet probe above.

### 2. Run the worker restart OUTSIDE the agent's process tree

`Repair-Paseo.ps1` ends every session the daemon hosts, **including the one
that invoked it** — the tool call is interrupted mid-restart. That is expected,
not a failure: the pin, the DSH repoint, and the credential-log line are all
written **before** step 3.

**Prefer a helper that is outside the job object by construction.** An agent
host may wrap its process tree in a Job Object and `paseo restart` kills that
tree, so a `Start-Process` child *may* inherit membership and die with it.
`Win32_Process.Create` is created by the WMI provider, so it is not a member of
the caller's job by construction — that is a design argument, not a measurement.
What has actually been observed on this host (2026-11-02): **both** mechanisms
survived a force-killed launcher, from a plain shell and from the agent chain
alike, and survival across a real `paseo restart` remains **unproven**. Measure
your own host with `scripts\Test-KeyCheckDetachment.ps1`; `-Legacy` swaps the
mechanism to `Start-Process` for contrast, not as a demonstration that it fails.

```powershell
$cmd = '"' + (Join-Path $PSHOME 'pwsh.exe') + '" -NoProfile -File "<path>\Repair-Paseo.ps1" -KeyNumber <n>'
Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $cmd }
```

Survival is not what the rescue depends on. `Invoke-KeyCheckCutover.ps1` writes
its outcome **before** the restart (switch → verify seam + User → write
`restartPending` → pin + restart → re-verify), so a helper that dies mid-restart
is finished by the next invocation instead of being lost. That is why a CIM
failure is a loud exit 4 rather than a silent `Start-Process` fallback, and why
`-AllowProcessFallback` is still safe when a host blocks CIM: slower to prove,
not wrong. Prefer the helper over hand-rolling the sequence.

Then verify afterwards: pin matches the Machine value, worker `startedAt` is
after the cutover, and a live helper answers `pong`.

## Provider lock

`assets/provider-lock.json` + `scripts/Invoke-ProviderLock.ps1` answer "is every
consumer using the right provider key?" without printing a value. This closed
the class of drift that produced the 2026-10-23 disclosure: Paseo's provider
env, the Machine/User env vars, and the AWS SM source had to be compared by
hand.

### Asset shape

Per provider: `source` (where the authoritative value lives), `targets` (every
consumer that must match), `fingerprint` (SHA-256 + length + who/when locked).

```json
"opencode-go": {
  "source": { "kind": "aws-sm-seam", "secretId": "ClockLobster/Salmon-Run",
              "seamPath": "opencode-go-cutover.json", "seamField": "activeKey",
              "profile": "dev-daily-fixed", "region": "ca-central-1" },
  "targets": [
    { "kind": "env",   "scope": "Machine", "name": "${activeKey}", "required": true },
    { "kind": "env",   "scope": "User",    "name": "OPENCODE_GO_KEY", "required": true },
    { "kind": "paseo", "provider": "opencode", "envName": "OPENCODE_GO_KEY", "required": true }
  ],
  "fingerprint": { "sha256": "…", "length": 51, "lockedAt": "…", "lockedBy": "…" }
}
```

- Source kinds: `aws-sm` (secretId + field), `aws-sm-seam` (field named by the
  seam's `activeKey` — opencode-go), `file` (single-line key file).
- Target kinds: `env` (scope Machine/User/Process), `paseo` (provider env in
  `~/.paseo/config.json`), `file`.
- `${activeKey}` in a target name expands from the seam, so the lock follows a
  cutover without editing the asset.
- `required: false` = absent is informational (`OPTIONAL-MISSING` /
  `NOT-CONFIGURED`), not a failure.

### Modes and statuses

```powershell
# Verify (read-only, default). Exit 1 on drift.
pwsh -NoProfile -File $env:CL_REPOS_ROOT\cl-common\Skills\credential-rescue\scripts\Invoke-ProviderLock.ps1

# Record the authoritative fingerprints (run after a cutover/rotation)
pwsh -NoProfile -File ...\Invoke-ProviderLock.ps1 -Mode Lock [-Provider opencode-go]

# Offline / no AWS: compare consumers to the stored fingerprint only
pwsh -NoProfile -File ...\Invoke-ProviderLock.ps1 -NoAws
```

Statuses: `SOURCE` (authoritative resolved), `LOCKED` (fingerprint recorded),
`UNLOCKED` (no fingerprint yet), `MATCH`, `DRIFT`, `MISSING` (required),
`OPTIONAL-MISSING`, `NOT-CONFIGURED` (e.g. Paseo has no such provider),
`UNVERIFIED` (no expected value at all — never reported as a pass),
`LOCK-DRIFT` (the authoritative value no longer matches the recorded
fingerprint: rotation happened without re-locking), `SOURCE-MISSING`.

### Operating rules

- The lock is the drift gate, not a rotation tool: it never writes env vars or
  Paseo config. Cutovers stay in `Switch-OpencodeGoKey.ps1` /
  `Repair-Paseo.ps1`; the lock then verifies them and `-Mode Lock` re-pins.
- Never store a value in the asset. Only `sha256`, `length`, timestamps, actor.
- A recorded fingerprint is per provider and per active selector: after a
  cutover to another pool key, `-Mode Lock` once so `LOCK-DRIFT` is meaningful.
- Tests: `Tests/ProviderLock.Tests.ps1` (10 cases: lock, MATCH, DRIFT, required
  vs optional missing, Paseo NOT-CONFIGURED / configured, seam expansion, and
  "no value ever appears in output").
- Current live state (2026-10-23): `openrouter` — Machine env matches SM,
  Paseo has no openrouter provider (`NOT-CONFIGURED`, expected); `opencode-go`
  — all five consumers match the seam's `OPENCODE_GO2_KEY` source.

### OpenRouter provider route (2026-10-23)

OpenRouter is a model gateway, not a Paseo harness, so it arrives as a Paseo
provider that **extends `acp`** and boots the DeepSeek Harness with an
OpenRouter patch:

| Piece | Where | What |
| :--- | :--- | :--- |
| Paseo provider | `~/.paseo/config.json` → `agents.providers.openrouter` | `extends: acp`, command = `node … dsh/lib/bin.js --profile acp --patch …\openrouter-model.yml`, `env.OPENROUTER_API_KEY` pinned to the SM value, `additionalModels` = the two OpenRouter model ids |
| Model route | `~/.dsh/profiles/acp/openrouter-model.yml` | `llm-pi-ai` provider `openrouter`: `api: openai-completions`, `baseURL: https://openrouter.ai/api/v1`, `apiKeyEnv: OPENROUTER_API_KEY`, models; plus `acp.provider/model` |
| Credential | SM `ClockLobster/Salmon-Run#OPENROUTER_AGENT_KEY` | the provider lock verifies `env` + Paseo pin + Machine env |

`paseo reload` applies the provider list without restarting agents (a daemon
restart is not needed for a new provider block). Traps found while building it:

- **opencode's built-in `openrouter` provider ignores `OPENROUTER_API_KEY`** and
  resolves its stored auth entry instead; a stale stored key fails with
  `AI.Error.Authentication: User not found` even though the SM key returns 200
  from `curl`. That is why the route is DSH/pi-ai, not opencode.
- A Paseo provider block without `extends` is silently ignored — it must carry
  `extends: acp` (or another registry type) to appear in the provider list.
- The DeepSeek-specific `llm-deepseek` adapter against OpenRouter ends the
  stream without `[DONE]` (`SSE stream ended without [DONE]`); use
  `llm-pi-ai` with `api: openai-completions`.
- `deepseek/deepseek-chat` on OpenRouter routes to a 32k-capped upstream
  (DeepInfra) and fails Paseo's ~50k-token prompt with
  `Upstream error from DeepInfra … max_num_tokens (32768)`. Default to
  `deepseek/deepseek-v4-flash` (1M-context upstreams); a 50k-token probe
  against it returns 200.

## Absorbs / related skills

- `opencode-go/model-replacement` (`Public\salmon-run\skills\providers\opencode\model-replacement`) — still owns MODEL diagnosis (missing/bumped/consent/region models, failover chain). Its credential-exhaustion path defers here.
- `aws` (`cl-common\Skills\aws`) — still owns AWS CLI ops, profiles, Secrets Manager reads, SSO login. Its restore-adjacent troubleshooting defers here.
- `fix-orchestrator` / `self-healing` — still owns pipeline diagnosis; auth-exhaustion *repair* defers here.
- `tidy` — owns the never-touch-`~/.*/` hygiene rule that documents this loss class.
- `least-permissions` — IAM privilege auditing, unrelated to restore.

## Approval boundaries

- Repointing User env vars / auth.json to another existing pool key: allowed, log it.
- Clearing a Machine pool var (`-RetirePoolKey`) or flipping SM `_ON` flags: operator-visible — prefer asking unless the operator already authorized the cutover.
- `aws sso login` prints a URL+code the USER completes — run it, present the code.
- Rotating/creating IAM keys is operator-owned; agents never create keys.