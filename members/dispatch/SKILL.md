---
name: dispatch
description: >
  IQA dispatch member - spawns, briefs, observes and recovers workers so the
  interactive session stays free, and owns the numbers behind a spawn: detached
  by default, durably briefed, never blocked on, parent identity carried in the
  brief, per-key-set caps, and the route-and-effort matrix that picks a
  destination for each work role. Use when a hub or sub needs a worker, when a
  worker must be re-dispatched, when a spawned worker is missing from its
  parent's list, when a worker dies on a provider error, when a pool looks
  exhausted, or when asked about default models and efforts.
---

# dispatch

## When to use

Work must be executed by a worker rather than by the session in front of the
user - which is most work. Also when a worker died and its task must be rebuilt
from the brief, when a worker exists but the parent cannot see it, or when the
question is *what* to spawn: which route, which effort, how many at once.

The mechanics came from `Skills/paseo-child-agents/SKILL.md` and the numbers from
`Skills/agent-spawn-capacity/SKILL.md`; both are thin pointers here now. Their
deep references stay where they are and are cited below.

## The spawn contract

### Rule 1 - dispatch detached, or the user's next message kills the worker

`paseo run -d` (background) is the only safe dispatch. A worker created from
inside the interactive session - any chat-coupled "create agent" tool - is
cancelled as soon as the user sends another message. Background workers keep
running while the user keeps talking, which is the entire point of dispatching
them. Never dispatch a worker in the foreground and never block the chat waiting
on one.

```powershell
# $env:PASEO_AGENT_ID in YOUR shell is YOUR OWN session id - write it into the
# brief verbatim below (never send to it yourself; that pings you and aborts
# your own in-flight work).
paseo run -d --title "<title>" --mode build `
  --provider opencode/opencode-go/deepseek-v4.1-flash --thinking low `
  --cwd <worker-worktree> --env OPENCODE_CONFIG=%USERPROFILE%\.paseo\iqa-no-approvals.json `
  "Read the brief at <worktree>\.iqa-brief-<id>.md and execute it end to end. Write your report to <worktree>\.iqa-report.md. Write your done file <worktree>\.iqa-done-<id>.json per <package>\vendor\paseo-child-agents\iqa-done.schema.json (check it with <package>\vendor\paseo-child-agents\validate-done.mjs) plus the human-readable message. ParentAgentId: <your-own-id> - ping THIS id on completion per Rule 3, never `$env:PASEO_AGENT_ID which is your own. Do not ask questions; if blocked, record the blocker, ping the parent anyway, and stop."
```

`--env OPENCODE_CONFIG=%USERPROFILE%\.paseo\iqa-no-approvals.json` is the
DEFAULT on every dispatch - not a per-dispatch memory item. Canonical machine
copy first, shipped fallback beside the IQA helper at
`<package>\vendor\dispatch\assets\no-approvals.json` (vendored from `iqa-mode`,
where its canonical owner keeps `Skills/iqa-mode/assets/no-approvals.json`; both
must carry the `question: deny` shape - see
`Skills/paseo-child-agents/REFERENCE.md` § Worker config, the canonical owner of
that prose). The helper below resolves it.

Prefer the helper (above + automatic parentage):

```powershell
pwsh <package>\vendor\dispatch\scripts\run-iqa-worker.ps1 `
  -Brief <worktree>\.iqa-brief-<id>.md -Title "<title>" -Workdir <worktree>
```

`<package>` is the directory holding this plugin's `SKILL.md`; the paths above
resolve in-package. The fleet path
`$env:CL_REPOS_ROOT\cl-common\Skills\iqa-mode\scripts\run-iqa-worker.ps1` is a
**development override** supplied by the profile, never the requirement - the
vendored copy is byte-identical and `tools/Sync-VendoredHelpers.ps1 -Check`
proves it. The helper's own siblings resolve inside `vendor/`
(`../assets/no-approvals.json`, `../../agent-spawn-capacity/scripts`,
`../../credential-rescue/assets`), so an isolated copy runs without a `Skills/`
tree. The runbook prose it cites (`Skills/paseo-child-agents/REFERENCE.md`,
`Skills/agent-spawn-capacity/REFERENCE.md`) stays with those owners as
provenance.

Opencode-shaped only (`--mode build` + `OPENCODE_CONFIG` pinned, `--thinking`
from the work role - see § Route and effort). Codex/Devin take raw `paseo run`
with their own mode id (see `Skills/paseo-child-agents/REFERENCE.md` § Per
harness).

### Rule 2 - a detached worker has no human

It cannot ask and cannot be answered. The prompt must end with
`Do not ask questions; if blocked, record the blocker, ping the parent anyway, and stop`, **and** the
worker config must deny the `question` tool - a worker that asks anyway blocks
forever with nobody to answer it.

### Rule 3 - a detached worker always pings the parent on completion

**A lane is not done until it has a completion artifact.** The ping carries a
result, never a status word: counts, the files touched, and the absolute path of
the report it wrote - a bare "finished" is a stall, and the parent treats it as
no report at all (report shape:
[vendored iqa-common contracts](../../references/vendored/iqa-common-contracts.md)
-> `### Completion report contract`; the attached-dispatch equivalent is
`subagent-dispatch`).

**A dispatch also gets a start receipt** - one line before the first step, so a
silent worker is detectable in minutes instead of at completion or death. The
shape, the ack rule and the re-ping/escalation timer are owned by
[iqa-handoff](../iqa-handoff/SKILL.md) -> `## Start receipt`; this member only
requires that it is sent.

**A lane's last act is `git push`, not a commit.** A branch that exists only in
the lane's worktree gives the Hub nothing to merge, so the brief says it in as
many words - *commit as you go and push the branch before you report* - and the
completion ping names the pushed tip (`git ls-remote origin <branch>`). Two lanes
on 2026-11-02 ended the night as unlandable work: one never pushed, the other
committed only after being told to. A report is not the deliverable.

A background worker never surfaces in the user's chat on its own - without a
ping, its report sits unread in its worktree. The session therefore writes its
OWN agent id into every dispatch brief verbatim:

`ParentAgentId: <id> - ping THIS id, never $env:PASEO_AGENT_ID which is your own`

`$env:PASEO_AGENT_ID` inside the worker's shell is the WORKER's own id - a
worker that sends to it pings itself and aborts its own in-flight shell
(self-ping trap). The verbatim id is the only safe target. Fallback when the
brief carries no id: the worker inspects itself and reads the parent link
(`paseo inspect $env:PASEO_AGENT_ID --json` -> `.ParentAgentId`); Devin sessions
resolve the id before dispatch with `Get-PaseoSelfAgentId.ps1` (see
`Skills/paseo-child-agents/REFERENCE.md` § Why the child link is lost).

### The brief, and how the spawn is observed

- **The brief is the durable contract; the chat is not.** It carries the task, the
  acceptance evidence, the repo and branch it writes, the report artefact path, the
  done-file schema, and the parent id to ping. A brief that omits acceptance is not
  a brief. Worktree-shaped, not trunk-shaped: checkpoint the work as it goes
  (`Skills/paseo-child-agents/REFERENCE.md` -> `## Rule 6 - brief the worktree,
  checkpoint the work`).
- **Observation never blocks.** Read a worker's state; never wait on it. A worker
  that cannot report is **failed**, not "still running"
  ([INVARIANTS](../../core/INVARIANTS.md) -> `## 7. The user never waits`). One
  lane-watcher per session, never one heartbeat per worker
  (`Skills/paseo-child-agents/REFERENCE.md` -> `## Rule 4`).
- **Recovery**: a dead worker's work is re-dispatched from its brief, not
  resurrected by poking a dead session.
- **Parent linkage**: a worker spawned without it is repaired, or labelled
  (`parent=<id>`) so it is still findable. A worker nobody can find is not running
  in any useful sense.
- **Hub to hub**: queue the message durably, then ring the doorbell
  (`Skills/paseo-child-agents/REFERENCE.md` -> `## Rule 5`).

## Route and effort - the numbers this member owns

The single owner of **how many agents may run at once per key set**, **which
route and effort a piece of work gets**, and **what happens when a provider
fails**. A dispatcher reads this before it spawns; the mirrored executor configs
are projected from it. Nothing here is optional or advisory.

### Caps

A cap is **per key set, not per model**: two routes on one wallet share one cap.
Registry (`assets/agent-capacity.json`, an adapter value in
`Skills/agent-spawn-capacity/`).

| Priority | Pool | Cap | Routes | State |
| :--- | :--- | :--- | :--- | :--- |
| 1 | `opencode-go` | **10** | primary: DeepSeek V4.1 Flash (OpenCode, low) · alternate: DeepSeek Harness failover | enabled - **tried first** |
| 2 | `opencode-zen` | **2** | DeepSeek V4.1 Flash on OpenCode Zen (free) | enabled - **first free fallback** |
| 3 | `gemini` | - | Gemini routes | **disabled by operator 2026-10-29** |
| 4 | `openrouter` | **2** | OpenRouter route | enabled |
| 5 | `codex` | **12** = 8 fix + 4 recon | fix/code/refactor: GPT-6 Luna · recon: GPT-6.1 Sol | **disabled; explicit opt-in only** |
| 6 | `devin` | **2** | `devin acp` | **disabled** |

`Acquire` with no pool (**`-Pool auto`**, the default) walks the enabled pools by
priority and takes the first that fits - so the first agent of a wave is normally
an opencode-go agent, and a busy or spent opencode-go falls straight through to
the free opencode-zen pool with no decision at the call site. Gemini is disabled
by operator decision and is skipped; an explicit `-Pool gemini` must fail rather
than dispatch. Occupancy counts subagents only: a dispatcher session
self-registers on `Acquire` and never occupies a slot, and only a genuinely live
agent (`running` or `initializing`) holds one. Idle, closed, errored and
archived records are history and never count (cl-common-0nm, 2026-11-03).

**Free-tier policy.** A free pool is never the sole route for implementation or
review. It may carry read-only verification while a paid pool is healthy; if
every paid pool is unavailable, the Hub does the mechanical work directly or
waits - it does not spend a free key on a task that needs a durable result.
Repeated re-dispatch is not a recovery strategy.

**Lanes and their children share the pool.** A lane suborchestrator is one
occupant; every child agent it creates is another occupant of the same key set.
A lane must acquire a slot for each child (or stay within the parent slot's
budget when the dispatcher already reserved it) and must never fan out past the
pool cap. The Hub only sees the lane's slot until the lane reports.

Codex is excluded from automatic routing while disabled. Use it only after an
explicit user request, with `Acquire -Pool codex -OptInCodex -Role <role>`;
this opt-in still enforces all capacity and failure checks. `-OptInCodex` is
invalid with `-Pool auto` and cannot be combined with `-IgnoreCapacity`.

### Preflight the dispatch triple

Validate the triple **before** spawning: the provider, the model id, and the
thinking level must all be supported by that provider's current model list (a
model that exists without the requested thinking option fails on turn 1, not at
dispatch), and the key must canary green. Fall back only in the documented pool
order, and fail fast with the **exact** provider/model id in the error rather
than substituting silently.

The canary is `Test-OpencodeProvider.ps1` (`run-iqa-worker.ps1 -Role <role>`
calls it); the model list is the provider's own, queried live - never a
remembered id. Route resolution, the fallback order, and the error log:
`Skills/agent-spawn-capacity/REFERENCE.md` § *Work roles - route + effort* and
§ *Error log*.

### Provider id shape - one string, never a tuple

Every `routes[].provider` is **one plain `provider/model` string** that a
dispatcher passes straight to `paseo run --provider`. Two shapes are refused by
`Acquire` with a named `ROUTE-PROVIDER-ID` error (pool, route and offending value
in the message; no reservation is written, so a refusal cannot leak a slot):
a serialized tuple (the DeepSeek Harness ACP catalog renders its model as
`["deepseek-official","deepseek-v4.1-flash"]` - write it
`deepseek-harness/deepseek-v4.1-flash` instead), and an `opencode` model id
missing its nested `<providerID>/<modelID>` segment. The alternate opencode-go
route consumes the DSH form, which also declares `mode: default` because DSH
exposes no session modes: a delegate must not pass `--mode build` on it
(verified 2026-11-02).

## Reference

Cited, never copied - the numbers above are the contract, these are the workings:

- [`vendor/paseo-child-agents/`](../../vendor/paseo-child-agents) - the done-file
  schema (`iqa-done.schema.json`), its validator (`validate-done.mjs`) and the
  lane watcher (`lane-watch.mjs`), all vendored in-package.
- `Skills/paseo-child-agents/REFERENCE.md`: `## Verify a dispatch`,
  `## Supervise without blocking`, `## Per harness`, `## Capacity gate (before
  every dispatch)`, `## Dispatch traps`, `## Failure-mode catalogue`, `## Changelog`.
- `Skills/paseo-child-agents/references/lane-brief-failures.md` - lane-brief gate
  failures measured 2026-10-31.
- `Skills/agent-spawn-capacity/REFERENCE.md`: `## The gate: four calls around every
  spawn`, `## Failure states - two windows, two clocks`, `## Work roles -> route +
  effort`, `## Error log`, `## Keeping the mirrors honest`; registry schema and
  the full `AgentCapacity.ps1` surface. The dispatch closure is vendored at
  [`vendor/agent-spawn-capacity/`](../../vendor/agent-spawn-capacity) (the
  capacity script, its registry helper and `agent-capacity.json`).
- `Skills/agent-spawn-capacity/EXECUTOR-DEFAULTS.md` - the mirrored executor
  configs projected from this owner.
- Helpers beside `paseo-child-agents`: `iqa-done.schema.json`, `validate-done.mjs`,
  `lane-watch.mjs` are vendored here; `Get-PaseoSelfAgentId.ps1`,
  `Send-PaseoMessage.ps1`, `Receive-PaseoMail.ps1` stay with their owner
  (Paseo transport, declared not vendored in the manifest).

## Read first

[INVARIANTS](../../core/INVARIANTS.md) · [TASK-MODEL](../../core/TASK-MODEL.md) ·
[ADAPTERS](../../core/ADAPTERS.md) · [PROFILE](../../core/PROFILE.template.md)
