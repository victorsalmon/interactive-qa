# iqa-hub - reference

Adjacent reference for [SKILL.md](SKILL.md). This is the canonical body of the
former `Skills/iqa-merge/REFERENCE.md`, moved into the plugin in Phase 3 with its
content intact; only the links were re-pointed, and the two rules that now have a
single owner elsewhere are cited instead of restated.

Normative order: [core invariants](../../core/INVARIANTS.md) -> this member's
[SKILL.md](SKILL.md) (-> `## QA mode`) -> the in-package QA procedure
([references/vendored/qa-procedure.md](../../references/vendored/qa-procedure.md))
with the package's own core documents -
[TASK-MODEL](../../core/TASK-MODEL.md) and [ADAPTERS](../../core/ADAPTERS.md) -
and the repo profile's batch/lock mechanics, resolved through the profile
([PROFILE template](../../core/PROFILE.template.md) -> `scripts_root`,
`seam_path`, batch and lock values). A full IQA session executes the vendored
procedure; it does not need to read anything outside this package.

The skills that gave this procedure its content stay named here as **provenance
only**, never as the procedure: `iqa-beads` (bead deltas and the merge-mode
passes), `iqa-beads-saas` (the SaaS slots), `iqa-common` (the three passes, the
session-log contract, Validate/Close), and `hub-mode` (the reference
deployment's batch/lock mechanics). They own their canonical text; when one of
them changes, the vendored snapshot
([references/vendored/qa-procedure.md](../../references/vendored/qa-procedure.md),
whose `## Provenance` table names the exact sections) is re-taken - never patched
from memory. Where this file seems to disagree with a lower layer, the lower
layer wins - fix this file, never fork the rule.

## Roles

Moved out of `SKILL.md` (progressive-disclosure budget); the routing is unchanged.

| Role | Load | Canonical path |
| :--- | :--- | :--- |
| Full IQA session (blocker analysis, live tracker, three passes) | this member's `## QA mode` + core + the vendored procedure, followed never restated | [SKILL.md](SKILL.md) → `## QA mode`, [core/INVARIANTS.md](../../core/INVARIANTS.md), [core/TASK-MODEL.md](../../core/TASK-MODEL.md), [references/vendored/qa-procedure.md](../../references/vendored/qa-procedure.md) |
| Merge hub duty (labels, merge-tick, drain) | this skill + merge-tick | this `REFERENCE.md`, `## Hub heartbeat (self-wake)` below |
| Built work, hand over (never merge) | forwarder section | `## Sub handoff` below |
| Create/shape beads (any role) | `create-bead` | `Skills/create-bead/SKILL.md` (canonical owner) |

Provenance for the two rows that have one: the full-session procedure is the
snapshot of `Skills/iqa-beads`, `Skills/iqa-beads-saas` and
`Skills/iqa-common`; the merge duty's canonical text is
`Skills/iqa-beads/REFERENCE.md` → `## IQA-Merge Mode`. Both are owners of the
rules, not reading requirements for a session running inside this package.

A Merge invocation always wears the Hub labels for its repo (session + hub duty
— the IQA-Beads-SaaS-Hub version); bare `IQA` stays beads-only. Labels below
(`## Hub labels`), off last at Close, after drain-or-park. Backlog = the beads
graph, never salmon-run (`## Hub backlog`).

## Hub probe

The first step of a Hub session: probe, then fire only what the probe flags.
`Invoke-HubProbe.ps1` is read-only git plumbing plus one queue-file read — no
node, no helper scripts, no writes, ~1s (a few seconds with the default fetch).
It replaced the unconditional full groom as the session-start step: a session
that needs nothing pays ~1s instead of running every groom helper.

Parts, each `NEEDED` / `SKIP` / `INFO` / `BLOCKED` with a reason and, when
`NEEDED`, the exact standalone command:

| Part | Fires when | Command |
| :--- | :--- | :--- |
| `precondition` | HEAD is not the trunk (BLOCKED) | `git -C <repo> switch <trunk>` |
| `commit` | tracked modifications exist | `Invoke-SafeCommit.ps1 -RepoRoot <repo> -Paths … -Message …` |
| `untracked` | untracked paths exist (INFO only, never swept) | — |
| `sync` | trunk ahead (push) or behind (fast-forward pull) a remote | `Invoke-GitPullSafe.ps1 -RepoRoot <repo>` / `git -C <repo> push <remote> <trunk>` |
| `helpers` | this checkout's `Skills/` differs from `origin/<trunk>` — a helper invoked from here is **not** the shipped helper, and writes the record shape it knows | review `git -C <repo> diff --stat origin/<trunk> -- Skills`, then sync before invoking any skill helper |
| `reconcile` | queued/merging queue rows whose frozen SHA is already on the trunk | `merge-queue.mjs prune --repo <slug> --repo-root <repo> --base <trunk>` |
| `shared-deps` | a pending branch touches `package.json` / `pnpm-workspace.yaml` / `pnpm-lock.yaml` (the only time the gate can have moved) | `Test-SharedDepAgreement.mjs --root <fleet> --ref origin/<trunk>` |
| `merge` | a local non-permanent branch has commits the trunk lacks | `Invoke-TrunkPrep.ps1 -RepoRoot <repo> -OnConflict CherryPick` |
| `hygiene` | a local branch is merged or patch-equivalent, or extra worktrees exist | `Invoke-BranchWorktreeHygiene.ps1 -RepoRoot <repo> -IncludeRoot -BranchDays 0 -WorktreeDays 0 -Apply -IncludePatchEquivalent` |

Verdict: `READY` (every part SKIP/INFO → advertise now), `GROOM NEEDED` (run the
printed commands in order, then re-probe), `BLOCKED` (exit 1 — do not advertise).

Rules:
- The probe orchestrates nothing. Each part names the canonical helper; it
  never reimplements one, and Repo Clean is not involved.
- A helper's semantics are whatever the **checkout** holds, not what the remote
  ships. Invoke skill helpers from a checkout at `origin/<trunk>`; an absolute
  path into a stale clone looks canonical and behaves old. `helpers` exists
  because exactly that silently wrote a `schemaVersion: 1` registry record over a
  v2 set on 2026-11-01 — a downgrade, not cosmetic staleness.
- `-Steps`-style partial modes do not exist on Repo Clean: partial grooming is
  "run the canonical command for that part", which is what the probe prints.
- Fetch is on by default because a stale `origin/<trunk>` makes `sync` lie
  (2026-10-23: an un-fetched mirror ref reported the trunk 8 behind and blocked
  a good groom). `-NoFetch` is for offline/fast runs only.
- Pending-branch patch equivalence uses `git cherry` (no '+' lines), so a
  cherry-picked branch is retired rather than re-merged.
- Tests pin the verdicts: `Tests/Invoke-HubProbe.Tests.ps1`.
- **Repository identity is resolved from the repository, never from the checkout
  directory name.** A directory name describes *this copy*: inside
  `<repo>/.worktrees/<lane>` the leaf is the lane, and a clone may be called
  anything (`git clone tmp-xyz`). Order: explicit `-Slug`, then
  `remote.origin.url` (the only source that names the repository), then
  `git rev-parse --git-common-dir` (the MAIN checkout, even from a linked
  worktree), then the directory name with a warning. A remote that disagrees
  with the common dir is **reported as a finding**, never resolved silently -
  the probe does not know which one the operator meant. The `reconcile` part
  prints the identity it looked up even when it SKIPs, because "no queue file"
  plus a lane name is how a Hub came to believe a busy repo had nothing queued
  (`cl-common-0co.30`; the sibling of UH `1ef.124`).

## Repo clean

Repo Clean is its own skill now: `Skills/repo-clean/SKILL.md` (modes `groom`,
`-Plan`, `hygiene`, `-All`; absorbed Tidy and Merge Audit). This Hub fires it
only when `Invoke-HubProbe.ps1` flags a part, then advertises on `READY`.

```powershell
pwsh -NoProfile -File $env:CL_REPOS_ROOT\cl-common\Skills\repo-clean\Invoke-RepoClean.ps1 -RepoRoot <repoRoot>
pwsh -NoProfile -File $env:CL_REPOS_ROOT\cl-common\Skills\repo-clean\Invoke-RepoClean.ps1 -RepoRoot <repoRoot> -Complete
```

Detail: `Skills/repo-clean/REFERENCE.md` (groom), `plan.md` (classification),
`hygiene.md` (red state/docs/style/disk).
## Hub labels

| Label | Repo | `repoRoot` | Status |
| :--- | :--- | :--- | :--- |
| `hub-cbk` | currents-bookkeeping | `$env:CL_REPOS_ROOT\currents-bookkeeping` | active |
| `hub-uh` | upscale-havens | `$env:CL_REPOS_ROOT\upscale-havens` | active |
| `hub-common` | cl-common | `$env:CL_REPOS_ROOT\cl-common` | active |
| `hub-salmon` | salmon-run | reserved | phase 2 |

Every Hub-wearing session also carries `iqa-role=merge` (regular queue
drainers carry `iqa-role=beads`). Compatible with the `{mode: hub-mode,
repo, trunk}` label scan — either form resolves.

## Hub backlog

The Hub drains its repo's **beads graph**, never a salmon-run queue. Ready work
is `bd ready` / `bd list` in the repo graph (merge beads first, then the
follow-ups they unblock); anything a human must do is a manual bead (`manual`,
`origin:human`) in that same graph. Salmon-run `Tasks/` trees are legacy
migration input only: a live item found there is minted as a bead and its file
archived under `09Archive/Moved to Beads/`. Merge-queue rows remain the merge
handoff (`## Sub handoff`) and are unchanged by this rule.

## Hub start contract (binding, every Hub-role session)

Assuming the Hub role is a **claim that must be proven**, not a mode you
announce. A session is a Hub only when all five receipts exist in its own
transcript — the `## Dispatch durability` #1 rule (a dispatch exists iff the
tool result carries an id) applied to the advertisement and the timer.

| # | Receipt | Proof in the transcript | Failure if missing |
| :--- | :--- | :--- | :--- |
| 1 | Lease | `Acquire` result printed (`owner`, `expiresAt`) **and** `-Mode Status` → `Live: true` from a persistent shell | Subs cannot find the Hub; work parks ownerless |
| 2 | Registry | `HubRegistry.ps1 -Mode Register` result printed (`repo`, `agentId`, `machine`, path) | A Sub in another workspace cannot see the Hub at all (`## Sub lookup` step 0) |
| 3 | Labels | `hub-<x>` + `iqa-role=merge` set, `## Sub lookup` self-verdict printed (`FOUND <agentId>`) | Hub exists but is invisible (`## Advertise checklist`) |
| 4 | Self-wake | `paseo_create_heartbeat` **tool result printed** (name, cron, `expiresAt`) | nothing wakes the session; ready beads sit idle |
| 5 | Backstop | `new-agent` cron `hub-watch-<repo>` (`*/15`) registered in the same turn and visible in `paseo_list_schedules` | a Paseo restart or session death ends the drain silently |

Rules:

- **Receipts in one turn, before any merge duty.** Acquire → register → labels
  → self-verify → heartbeat → backstop. Do not tick, mint, claim, or drain a
  bead before 1–5 are printed. A Hub that starts draining with no
  advertisement is the defect class that left ready beads idle (2026-10-28),
  and on 2026-11-01 a live Hub with no registry record and no labels sent a
  Sub to spawn a duplicate Hub for work that already had an owner.
- **Heartbeats have no list surface.** `paseo_list_schedules` returns only
  `new-agent` crons, so the `hub-watch-<repo>` schedule is the *only*
  auditable wake-up: a future `nextRunAt` means alive, `status: completed`
  means dead. Also record the heartbeat name on the bead note (or in the
  tick log line) — that mapping is the heartbeat's inventory. The backstop is
  a `new-agent` schedule (a fresh agent per fire, which then prompts the
  Hub), **not** a second session heartbeat: the one-heartbeat-per-session
  rule in `iqa-common` still holds.
- **One ACTIVE MERGE-TICK rung per repo, proven before a rung is created or
  re-armed.** Run `Skills/iqa-merge/Test-SingleHubRung.ps1 -Repo <repo>` (also
  the probe's `rungs` part) and act on its exit: **1 REFUSE** - keep the rung
  addressed to the live hub of record and pause the other, per
  `## Hub heartbeat (self-wake)` → `### One rung per repo (binding)`; **2
  CANNOT-EVALUATE** - fix the schedule source before arming anything; **3
  NO-RUNG** - create exactly one. `paseo_create_schedule` is not idempotent by
  name, so a bare create beside a live rung is exactly how the duplicate appears.
- **Backstop body** (one fire, spawned by the schedule):
  1. Liveness: `Invoke-WorktreeLease.ps1 -Mode Status -Path <repoRoot>` →
     `Live: true` **and** the owner still carries `hub-<x>` +
     `iqa-role=merge` **and** its session is live (`## Sub lookup` step 2)
     ⇒ Hub alive: send one `paseo_send_agent_prompt` "merge-tick now",
     report one line, stop.
  2. Otherwise the Hub is dead: take over Hub duty **once** — advertise per
     `## Hub advertise`, run one merge-tick, report refs, stop.
  3. Never merge inline, never write `bd` state it did not claim itself,
     never touch a foreign worktree.
- **Every turn ends with the rung check and one printed line** — a prompt
  reply, a dispatch receipt, a completion close-out, all of them. Run
  `Get-HubCadence.ps1` (`## Hub heartbeat (self-wake)` → end-of-turn rung
  check), act on its action, and print the returned `RungLine`:
  `Rung: <heartbeat-name> next <cadence/time> — <ACTION>: <reason>`. A prompt
  floors the gear at 1 minute, so answering an operator prompt while leaving a
  60-minute rung standing is a defect, not a quiet stretch. No line ⇒ the turn
  failed wake-up coverage; report the failure instead of reporting done.
- **Standing down is allowed; going silent is not.** `STAND-DOWN` is
  deliberate and prints the parked list plus `Rung: none (stand-down)`.
  Silence with no printed rung is a defect, never a pause.
- **Verification is cheap and read-only** — run it any time a Hub looks
  quiet: `paseo_get_agent_activity` (repeated tick prompts present?),
  `paseo_list_schedules` (`hub-watch-<repo>` has a future `nextRunAt`?),
  lease `-Mode Status` (`Live: true`?), and `bd ready` on the repo graph
  (dispatchable-but-idle beads?).

## Hub advertise

Advertise = live worktree lease on the `repoRoot` + `hub-<x>` and
`iqa-role=merge` labels on the Hub session + a hub record in the per-repo
registry, in that order, before any other Hub work. A Merge invocation
advertises for its repo immediately — never deferred, never conditional.
Discovery (`## Sub lookup`) reads the registry record first, then corroborates
with the lease and labels.

Why three signals and not one (2026-11-01, `currents-bookkeeping`): a Sub could
not find a live Hub-CBK and concluded "no Hub" — then spawned a duplicate. Both
discovery inputs had failed silently at once: `paseo_list_agents` without `cwd`
returns only the caller's own workspace (the Sub sat in another workspace, so
the Hub was not in the list at all), and the Hub had never set its labels
(`{}`). Either failure alone loses the handoff. The registry file is the signal
that survives both.

1. `Invoke-WorktreeLease.ps1 -Mode Acquire -Path <repoRoot> -Owner <agent-id>
   -TaskId hub-<x> -TtlMinutes <n> -Json` — `-Owner` is the Hub session's own
   agent id. Acquire from a persistent shell (terminal session, never a
   one-shot tool call): the lease records that shell's PID, and liveness =
   `expiresAt` in the future AND that PID alive same-host — a one-shot
   shell's PID is dead on return, so the lease reads stale. Set
   `BEADS_ACTOR` to the Hub agent id before any `bd` mutation —
   claim/close verify actor == assignee, and the default git-user actor
   fails that check.
2. Set session labels `hub-<x>` + `iqa-role=merge`.
2a. **Register the hub record** (the durable half of the advertisement):
   `pwsh -NoProfile -File <package>/vendor/iqa-merge/HubRegistry.ps1 -Mode Register
    -Repo <slug> -RepoPath <repoRoot> -AgentId <agent-id> -Trunk <trunk> -Json`
   (`<scripts_root>` defaults to this package's `vendor/`; the fleet path
   `Skills/iqa-merge` is a development override only.)
   writes `~/.salmon/State/hubs/<slug>.json` naming the **agent id** and the
   **machine** with a heartbeat stamp. A record that says only "repo X has a
   hub" is not actionable — a Sub needs *which* agent, on *which* machine, and
   *whether it is alive*. Re-Register is idempotent and keeps `registeredAt`.
3. **Prove the lease is LIVE, not merely held.** `-Mode Status` must report
   `Live: true`. A one-shot `pwsh -Command "& Invoke-WorktreeLease.ps1 …"` records
   the PID of a child that dies on return, so the lease reads
   `Held: true, Live: false` and discovery treats it as stale. Hold it from a
   long-lived process instead - an interactive `pwsh` REPL in a terminal
   session, or a detached holder that runs the acquire and then sleeps past the
   TTL. Observed 2026-10-28: three acquires before one reported `Live: true`.
4. Heartbeat: same-owner `Acquire` refreshes (same generation, new
   `expiresAt`) — refresh at ≤ half TTL, and inside the first third when
   the refresh rides cron (exact-half cadence lapses on jitter — observed
   2026-10-21: 30-min cron on 60-min TTL lapsed by 1s, harmless same-owner
   takeover, gen bump). Common: TTL 60, refresh every 20. Refresh the registry
   record in the same breath, or it will
   read stale at `MaxAgeMinutes` (15) while the lease is still good.

   **Renew the HUB OF RECORD, never your own transient id.** A merge-tick is a
   NEW Paseo agent on every fire, so its id has no registry entry and
   `-Mode Heartbeat -AgentId <tick>` is refused (that is correct). Name the
   stable id instead:

   ```
   HubRegistry.ps1 -Mode Heartbeat -Repo <slug> -HubAgentId <hub-of-record-id>
   # or export it once per tick:  $env:SALMON_HUB_AGENT_ID = <hub-of-record-id>
   ```

   Resolution order: `-HubAgentId` → `$env:SALMON_HUB_AGENT_ID` → `-AgentId`
   (only when that id already has an entry) → the live primary in the registry
   → otherwise a named `no-hub-of-record` verdict (exit 4). A tick **never**
   falls back to `Register`: registering the tick is how `cl-common` reached
   `hubCount: 6` with `duplicate: true` in four fires on 2026-11-03
   (cl-common-y49). Where no record exists at all, the helper registers the
   DECLARED stable id once, never the caller.

   When you are about to block for longer than `MaxAgeMinutes` — a serialised suite,
   a subsystem build, a long drain — declare it:
   `-Mode Heartbeat -Repo <slug> -HubAgentId <id> -BusyMinutes <n>`. Inside
   that window `Find` reports `unknown` rather than `dead`, so a Sub waits
   instead of spawning a duplicate. **Size the window to the block plus
   margin** (measured run + 15), and **renew it between blocks** — the window
   is an opt-out from heartbeating, never a renewal of it. A window shorter
   than the work it covers is a self-inflicted outage: Hub-CBK declared 60
   minutes over a longer suite and watched itself decay to `dead` mid-run. The
   helper now grants one grace window after a declared window closes before
   silence counts as absence, but that is a backstop, not a licence to
   under-declare. Expired or
   pid-dead leases are takeover-eligible (generation bump), so a dead Hub
   stops advertising on its own — never take over a live owner's lease.
5. At Close: final merge drain first, then `Release` the own lease,
   `HubRegistry.ps1 -Mode Clear -AgentId <own-id>` (it refuses to clear a
   record another agent owns, and refuses to clear a **live peer** as a
   predecessor — only a terminal predecessor may be cleared, `-Terminal`
   commanding an `unknown` one), labels off last.

Lease-hold summary: the advertisement holds one TTL per heartbeat (default
30 min). The trunk lock (`Invoke-TrunkMergeLock.ps1`, Ttl/Stale 5,
Ceiling 10) is separate — held only around the land window, never as the
advertisement.

See also `## Advertise checklist` (Hub-side self-verify after advertising).

## Repo identity (a lookup must never depend on the caller's spelling)

`Find` is keyed on the REPO, so what the caller passes matters. Two hubs ran
against one repo because a second hub could not see the first: it had not
registered, and the lookup it did perform used a key that did not match. A miss
read as "no hub here" — the licence to spawn a duplicate.

1. **Resolve identity, never pass spelling.** A repo name, a checkout path, a
   subdirectory, and a `.worktrees/<name>` lane all resolve to the same repo:
   the leaf of the MAIN checkout, via git's common dir. Pass
   `-RepoPath <folder>` and let the helper resolve it; a path-like `-Repo` is
   resolved the same way. Measured before this rule: `-Repo <path>`,
   `-Repo <worktree folder>` and `-Repo <own project name>` each returned
   `dead` with `hubCount: 0` while a live hub existed.
2. **A bare name that misses never falls back to the caller's cwd.** An identity
   scan runs only when the caller made a path claim. Otherwise a miss returns
   `dead` plus `knownRepos`, so the caller sees what IS registered and re-asks
   by name — it is never answered with an unrelated repo.
3. **One hub per repo is the rule; a set is what the file can hold.** Every
   entry is classified `primary` (anchored at the repo itself) or `secondary`
   (alive but standing elsewhere — a lane worktree, or a folder that is not the
   repo). A Sub defers to `primaryAgentId`; a secondary is visible, not
   authoritative. `Find` always reports `hubCount`, `duplicate`,
   `primaryAgentId` and `secondaryAgentIds`, so a duplicate is never silent.

## Helper version (ask, never assume)

`-Mode Version` answers with `helperVersion`, `schemaVersion` and the path that
answered. Every payload also carries `helperVersion`, because "which semantics
replied to me?" is not answerable from the shape of a verdict:

- `schemaVersion` = the shape of the FILE on disk.
- `helperVersion` = the SEMANTICS that produced the answer. Identity resolution,
  primary/secondary roles and freshness warnings all changed behaviour without
  changing the file shape, so a stale copy can write a current-looking record
  and answer with old meaning.

`Find` therefore reports `recordHelperVersion`, `helperVersionOutdated`,
`staleWriterAgentIds` and a note naming the stale writers. Every writer refuses
(exit 2) a record whose `helperVersion` is NEWER than its own, and a record that
carries none reads as 0 — older than any current helper.

The trap this closes: the cl-common MAIN checkout sat behind `origin/dev` and
answered with v1 semantics while the trunk shipped v2. A hub that ran the
main-checkout path wrote the old shape and could not see the record it was
overwriting. Ask `-Mode Version` from the path you intend to use; treat a
`helperVersion` below the trunk's as "this checkout cannot answer for the
trunk", not as a verdict.

## Sub lookup

The Sub resolves its repo, then finds that repo's live merge Hub. Read the
**registry record first** (a file, so it crosses workspace, session and even
machine boundaries), then corroborate with the lease and labels.

0. **Registry (authoritative, cheap, scope-free).**
   `pwsh -NoProfile -File <package>/vendor/iqa-merge/HubRegistry.ps1 -Mode Find
    -Repo <slug> -MaxAgeMinutes 15 -Json`
   The record holds a SET of hubs, one per agent id, and `Find` FOLDS it:
   `live` if any entry is live, `unknown` if any is unknown, `dead` only when
   every entry is dead. `hubCount` says how many were folded and every entry's
   state is returned, because a repo can legitimately be served by two hubs
   (a takeover during a drain, or a duplicate lane).
   Three verdicts, and the middle one exists for a reason:
   - **exit 0, `state: live`** → `{ agentId, machine, repoPath, heartbeatAt }`:
     address that agent id directly with `MERGE-READY` and skip the scans below.
     With `hubCount > 1`, say so in the message — an unannounced second hub is
     the shape that nearly double-landed a branch on 2026-11-01.
   - **exit 3, `state: unknown`** → an entry exists but its heartbeat is older
     than `MaxAgeMinutes`, or that Hub declared a busy window (`busyUntil`), or
     the window closed inside its renewal grace.
     A Hub mid-way through a 40-minute suite *cannot* heartbeat inside a
     15-minute window. **Do not spawn a duplicate Hub.** Verify the agent by
     direct status and prompt it; only fall through if that agent is gone.
   - **exit 1, `state: dead`** → every entry is past the grace window (default
     2× `MaxAgeMinutes`), or there is no record at all (a named `reason` either
     way). This is the *only* no-Hub verdict from the registry; a stale record
     is never evidence of no Hub, so corroborate with steps 1–3 before parking.
   `schemaVersion` travels with the payload. `schemaVersionOutdated: true` means
   the file was written by an older helper: it still reads (as a one-entry set),
   but a v1 writer that runs again would collapse co-registered hubs, so
   re-register with the helper from a checkout at `origin/<trunk>`.
1. `git rev-parse --show-toplevel` → `repoRoot`; map to the expected label
   (`currents-bookkeeping` → `hub-cbk`, `upscale-havens` → `hub-uh`,
   `cl-common` → `hub-common`).
   Scan that exact label only — never guess inversions (`cbk-hub` is not
   a label); on zero hits, report the labels actually present instead of
   silently parking.
2. Resolve the owner, then verify the SESSION — lease liveness is not the
   test. A Hub that heartbeats via short-lived CLI calls always reports
   `Live: false` (its pid died with the call) while the session stays live,
   so liveness gates takeover, never Hub-ness. `Status` → `owner`/`agentId`;
   `paseo inspect <agentId>` must show `hub-<x>` **and** `iqa-role=merge`
   plus a live session whose `cwd` sits under `repoRoot`. That triple — live
   session, Hub labels, lease held by the same owner — IS the advertisement.
   Labels or session missing/dead → not a Hub (fall through to
   `## No-Hub park + alert`). `Live: false` with a live labeled owner
   session → Hub present; note the lease wants a heartbeat, never treat it
   as no-Hub.
3. Fallback: `paseo_list_agents -Cwd <repoRoot> -IncludeBackground
   -SinceHours 720` (then `paseo_get_agent_status` each hit), keeping hits whose
   `cwd` sits under `repoRoot`, whose session is live, and whose labels carry
   `hub-<x>` or `iqa-role=merge`. **Pass `cwd`.** The list is
   workspace/lineage-scoped without it: called bare from another workspace it
   returns that workspace's agents and silently omits the Hub. A bare call is
   how the 2026-11-01 handoff concluded "no Hub" while Hub-CBK sat idle one
   workspace away.
4. Stale label (no lease at all, or `inspect` dead/missing) is ignored, never
   trusted. Two live `merge` Hubs → oldest lease wins, other stands down.
   A live Hub whose lease pid reads dead is takeover-eligible by the letter
   of the lock — Subs must still prefer the wake-up ping over racing it.

List-scope trap: `paseo_list_agents` (and the `paseo ls` surface) is
workspace/lineage-scoped unless `cwd` is passed — a live Hub in another
workspace is silently excluded. Never conclude no-Hub from a silent list.
Resolve via the registry record (step 0) or the lease file's owner `agentId` +
direct status-by-ID, both of which cross scopes; a silent list plus a live
direct status means the list lied, not that the Hub is dead. Precedents:
Hub-UH 2026-10-21 missed live Hub-CBK (1586a424) through the scoped list;
2026-11-01 a CBK Sub missed live Hub-CBK (cb0d5cd5) the same way **and** the
Hub had no labels — which is why the registry exists.

## Advertise checklist (Hub side)

After registering the hub record and setting labels + acquiring the lease, run
`## Sub lookup` against yourself and report the verdict before accepting merge
duty: a Hub the lookup cannot find is a Hub Subs cannot find. All three legs
must report present — `HubRegistry.ps1 -Mode Find` (exit 0), your `hub-<x>` /
`iqa-role=merge` labels, and the live lease. A bare `paseo_list_agents` is not a
self-check: it shows your own workspace by construction, so it will "find" you
even when nothing is advertised.

Re-heartbeat on a cadence well under both TTLs — the lease `expiresAt` **and**
the registry's `MaxAgeMinutes` (15) — so neither the row nor the record expires
mid-drain. The heartbeat refreshes expiry; it does not confer `Live: true` on
CLI-driven sessions (see step 3).

See also `## Hub advertise` (lease + label + registry procedure that precedes
this check).

## Merge landing proof (binding, every landed row)

**A merge verified by reading the local checkout is not verified.** The shared
trunk checkout is ahead of, behind, or diverged from `origin` at any moment —
another lane resets it routinely, and a hub that checks out a branch there can
hold a merge commit that never reached the remote.

That is not hypothetical: on 2026-11-01 a hub landed `copy/pass-2`, reported
"origin/dev head is e828d45bf, all three keys PRESENT", and marked the handoff
done. `origin/dev` was still at the tip that predated the merge, the push had
never happened, and the row was still `queued`. It was the third failure of the
same shape that night (a name grep for a GIFI table, a local copy of a code
table, a local `git log`): each trusted a signal that was available instead of
the one that is authoritative.

Land, then prove it against the REMOTE:

```powershell
pwsh -NoProfile -File <package>/vendor/iqa-merge/Test-Landed.ps1 `
  -RepoPath <repoRoot> -Sha <landed-sha> -Trunk dev `
  -Path 'backend/drizzle/0209_*.sql' -Json
```

It fetches, then asserts four things: the remote ref resolves, `<sha>` is an
ancestor of `origin/<trunk>`, every `-Path` you claim exists in the REMOTE tree
(a partial landing is not a landing), and it reports the trunk head it compared
against. Exit 0 proven / 1 not landed with the failing check named / 2 error —
an unevaluable check is never a pass.

Rules:

- Mark a queue row `merged` only after `Test-Landed.ps1` exits 0. A row marked
  from a local `git log` is a false claim, and the next Sub will act on it.
- Quote the helper's output (or the equivalent `ls-remote` + `merge-base` +
  `show origin/<trunk>:<path>`) when reporting a landing — not a summary.
- If dev moved under you, rebase and re-push, then re-run the proof. Never
  force-push, never report the earlier attempt as landed.
- A trunk checkout that is ahead of origin is a **standing hazard**, not
  housekeeping: every lane reading "dev head" from it gets a different answer.
  Reconcile it deliberately (owner of that checkout) and say so.

### A proven landing closes the bead — it does not sweep the worker

Landing proof and worktree hygiene are two independent gates. Passing the first
never licenses the second:

- **Close the merge bead** on remote proof alone: fresh fetch, frozen SHA an
  ancestor of the trunk ref, `Test-Landed.ps1` exit 0 on the changed paths, and
  `ls-remote` agreeing with the tip reported.
- **Sweep the worktree and delete the branch only when the owning worker is
  terminal**: a completion ping has arrived, *or* the ping-timeout window has
  elapsed with the worker idle/parked and its done-file present. A running agent
  is never swept, even when the landing is proven — it may still be writing its
  report, and its `.iqa-ping.cmd` goes with the directory.

Worked example, 2026-11-02 (`refactor/ah5-5-shrink-guides` → `public/salmon-run`):
a worker pushed merge `0822dcdb`; the Hub saw it as an ancestor of `main`,
`Test-Landed` exited 0, and it swept `.worktrees/merge-ah5-5` and deleted
`chore/merge-ah5-5` while the worker was still writing its landing report. The
worker rebuilt `.worktrees/merge-ah5-5b` / `chore/merge-ah5-5-report` and landed
two more commits after the bead had closed and `main` was recorded as
`0822dcdb` — a second branch plus a moved trunk to reconcile.

Recovery for a worker that relocated: prove the second branch an ancestor of the
trunk (its own `Test-Landed` run), reconcile its commits as the landing they
are, and only then sweep — never delete a relocated branch blind.

Pinned by `Tests/Test-Landed.Tests.ps1` (6 tests, real bare remote + two
clones): an unpushed merge reports not-landed, the same commit reports landed
once pushed, a missing claimed path fails, and a non-repo exits 2 rather than
passing.

## Sub handoff

For the agent that already built the feature. Unless the user explicitly
ordered a merge in the same turn, the Sub never merges.

1. **Freeze.** `git status --short`, `git branch --show-current`,
   `git log --oneline -5`, `git diff --stat`, ahead/behind of the trunk.
   No further edits after `Sub Mode` is invoked.
2. **Enqueue.** Register the frozen SHA as one merge-queue row
   (`node $env:CL_REPOS_ROOT\currents-bookkeeping\scripts\merge-queue.mjs`,
   `enqueue --repo <cl-common|cbk|uh> --branch <b> --sha <frozen> --worktree <path>`
   `--owner <sub-id> [--base <dev|trunk>]`; dir first-set-wins
   `$MERGE_QUEUE_DIR`, `$SALMON_RUN_HOME/Tasks/MergeQueue`,
   `~/.salmon/Tasks/MergeQueue`). `--note` carries the COMPLETE
   instructions: test evidence actually run, one `needs:` line per piece
   of residual work, and the return contact. A vague note mints
   nothing — the Hub relays it back as a question. The row is the
   durable handoff.
3. **Verify, then ping.** `merge-queue.mjs list --repo <r>` must show the
   row before anything else. Then one MERGE-READY ping to the Hub id with
   branch + frozen SHA only — a wake-up, never the payload. Queued
   delivery never interrupts the Hub's in-flight batch.
4. **Await Hub ack.** Poll `list --repo <r>` for your branch row every
   ~60s, up to 10 (≈10 min, inside the lane watchdog): status `merging`
   with a bead id in the note = Hub received and minted. Re-ping once
   at poll 5. Still `queued` with a live Hub after 10 → report
   unacknowledged: do NOT archive, alerted. (No live Hub at all →
   `## No-Hub park + alert` instead; never archive unacknowledged work.)
5. **Stop.** Report `Handed to <hub-label> (<agent-id>), ack <bead-id>,
   ready to archive` and touch the repo no more.
   Mint detail: same SHA returns the live bead; new SHA mints fresh with a
   "supersedes" note, plus one follow-up bead per `needs:` line.

**Adoption is a receipt.** A Hub that adopts a hand-off acks it in the shape owned
by [iqa-handoff](../iqa-handoff/SKILL.md) - the record fields, the `decision` values
and the re-ping / escalation rule are stated there and nowhere else - and the ack
additionally names the worker ids it dispatched and records the adoption on the
beads (a bead note or a `received` line naming the handoffId). Only then is the
hand-off `delivered`; a queued row or a wake-up ping is the offer, never the receipt.

## Plan-mode guard

An IQA-Merge invocation in Plan mode performs no transition. Advertising as
Hub (trunk lease + `{mode, repo, trunk}` / `hub-*` + `iqa-role=merge`
labels), the merge-tick (reconcile, mint, follow-ups, drain, close on push),
detached dispatch, Sub enqueue + ping, merge, and deploy are all Build-mode
writes. The agent tells the user verbatim to switch to Build mode to
complete the transition and stops — queue rows, beads, leases, and labels
stay untouched until the switch. Repo shells mirror this guard
(`currents-bookkeeping/Skills/{hub-mode,iqa-beads,sub-mode}/SKILL.md`).

## No-Hub park + alert

No live Hub for the repo: the queue row from `## Sub handoff` step 2 stays
queued — it is minted at the next Hub's first poll — and the Sub alerts the
user verbatim before stopping:

`No live <hub-label> for <repo> — parked at <queue-path>, nothing merged.`

## Hub-to-Hub forwarding (landing a branch in `cl-common`)

A `hub-cbk` / `hub-uh` session never lands `cl-common` branches itself. When
its merge-tick sees a queued row or a `needs:` line touching `cl-common`
(`Skills/`, `saas-modules/`, shared tooling), it forwards instead of draining:

1. Enqueue to the `cl-common` queue verbatim (`merge-queue.mjs enqueue
   --repo cl-common --base dev` with the frozen SHA + worktree + owner).
2. Mint a ledger follow-up under the `Merges: cl-common/dev` epic with a
   `blocked-by` edge onto the originating merge bead (`Cross-repo:
   <repo>/<bead-id>` in the body).
3. One wake-up-only ping to the `hub-common` agent id (branch + SHA only).
4. Leave the originating bead `blocked` on the follow-up; close both when
   `hub-common` marks `merged`.

**This section is about landing a branch.** It is not the route for information —
that goes direct, next section.

## Hub-to-Hub messaging (direct, queued, never relayed)

Landing a branch in `cl-common` goes through the queue (§ above). **Everything
else goes direct**: patch requests, defect reports, API/contract changes,
exit-code conventions, "I pin your SHA", and any coordination note. A Hub resolves
the other Hub's agent id from its `hub-<repo>` label and sends a **queued**
message.

- **Never route information through the operator.** They are not a message bus; a
  relayed defect report loses the context that made it actionable, and the reply
  path is gone. (Recorded 2026-10-29, after a Hub misread the section above as
  covering all inter-hub contact and sent patch requests through the operator.)
- **Queue, don't interrupt.** Interrupt only for a safety stop — a deploy about to
  destroy live resources, a push about to land on a branch someone else is
  rewriting. Otherwise a queued message read at the next turn boundary is correct
  even when it is urgent.
- **A patch request names the file, the section, and the exact words.** "Please add
  X to your skill" costs a round trip; quoted replacement text costs none.
- **The owning Hub decides.** A request is a request: if it is out of scope for that
  repo, the owner says so and the originating Hub finds another route — it never
  lands the change in someone else's repo.
- **The reply carries the evidence**: the SHA, or the reason it was declined.

### Resolving a peer Hub

Label → session, every time. The ids are **per-session and change on restart**, so
resolve them rather than pasting one into a script or a note:

```powershell
& "$env:ProgramFiles\Paseo\resources\bin\paseo.cmd" ls --json    # crosses workspaces
& "$env:ProgramFiles\Paseo\resources\bin\paseo.cmd" inspect <id> # confirm labels + cwd
```

| Hub | Labels to match | Repo |
| :--- | :--- | :--- |
| `hub-uh` | `hub-uh=true`, `iqa-role=merge` | `upscale-havens` |
| `hub-cbk` | `hub-cbk=true`, `iqa-role=merge` | `currents-bookkeeping` |
| `hub-common` | `hub-common=true`, `iqa-role=merge` | `cl-common` |

A **stale id is worse than no id**: it either fails to resolve (a wasted turn) or
resolves to whatever session now holds that uuid. Write the *lookup*, not the value.
The in-session agent list may be workspace-scoped and miss a live cross-workspace
Hub — the CLI `ls --json` is the authority, then `inspect` the id directly.

### Queued means the delivery semantics, not the transport

Both of these are "queued" and both are correct:
`Skills/paseo-child-agents/Send-PaseoMessage.ps1 -To hub-<repo>` (durable copy under
`~/.paseo/mailbox/<hub>/` first, then a doorbell) and the `paseo_send_agent_prompt`
tool. The rule is about **when the peer reads it** — at its next turn boundary, never
mid-turn — not about which call you use. Prefer `Send-PaseoMessage.ps1` when the
message must survive a restart (the mailbox file is the source of truth) and the tool
when you are already in a Paseo session and want the delivery receipt inline.

## Cross-repo bead linking

`bd` typed edges never span DBs (one typed edge per pair, same store only).
The shared ledger DB at `~/.salmon/State/merge-beads` is the cross-repo
graph: every repo's `Merges: <repo>/<base>` epic lives there. Session DBs
(`.beads/` in the trunk worktree) stay per-repo and ephemeral. To link a
CBK/UH session bead to `cl-common`:

- Put `Cross-repo: cl-common/<bead-or-branch> <reason>` in the session bead
  body, and mirror it as a ledger follow-up with a `blocked-by` edge.
- Never copy a bead across DBs; the ledger follow-up is the link.
- Project graph for `cl-common` lives at `$env:CL_REPOS_ROOT\cl-common\.beads\`
  (local persistent, gitignored via `.git/info/exclude`, never committed —
  same shape as `upscale-havens/.beads/`); session work still uses the trunk
  worktree DB per `iqa-beads`.

## Merge beads (SaaS shape)

Ledger DB `~/.salmon/State/merge-beads` (`$MERGE_LEDGER_DIR` override;
helper `node $env:CL_REPOS_ROOT\currents-bookkeeping\scripts\merge-ledger.mjs`).
Slugs (logical namespaces inside the single shared ledger DB, realized as
epic titles — no per-slug subdirs exist yet): `currents-bookkeeping` →
`cbk-merges`, `upscale-havens` → `uh-merges`, `cl-common` → `common-merges`.
One epic per trunk (`Merges: <repo>/<base>`), one merge bead
per queued branch (`M-<n>: land <branch> onto <repo>/<base>`, continuous
per database), follow-ups per `needs:` with `blocked-by` edges. Match by
frozen SHA, not branch (same branch + new SHA = superseded). At mint the
Hub `mark`s the row `merging --note <bead-id>` — that mark is the Sub's
ack. Merge beads close on push alongside the queue `mark merged` — the
two move together — and a tick that finds the frozen SHA already on the
trunk (crash between push and close-out, rival assembly landed first)
runs close-out immediately instead of re-landing: verify the tree holds
the scope, close the bead with push refs, mark the row `merged`, report.
Queue file wins on conflict until the operator flips truth to beads.

## Stale-probe disposition (Hub may close, must document)

A bead the Hub probes and finds non-actionable — already-fixed on the
trunk, superseded by a re-enqueue, or its premise gone (stale) — is
closed as complete *for Hub purposes* without asking: no worker is
dispatched, no merge is attempted. The task itself may still be open
elsewhere; "stale" means there is nothing for the Hub to do, never
that the underlying work is verified done.

Every stale close records three things, or it did not happen:
1. The probe evidence on the bead's own close reason (what was
   checked, what proved non-actionability — SHAs, gate outputs).
2. The stale determination on the summary bead — the parent epic
   (merge epic in the ledger; session epic in the session DB) gets a
   `STALE:` note naming the bead + evidence. Epic-less beads carry
   the determination in their close reason alone (rule 1), which is
   then the record.
3. Dropped queue rows (no-op merges) carry the same note on the row.

Never silently close: a stale close with no summary-bead note is a
defect, same as a merge with no push refs. Precedent: 5m2
(already-fixed by an earlier commit, closed with gate proof, row
dropped as no-op); r1b (premise stale, re-scoped as CI-green tracker,
not closed).

## Merge worker (exception to strict core)

The core's "session merges inline" is inverted here and only here: a
claimed detached merge worker runs the mechanical landing while the Hub
supervises and stays interactive. Guardrails (all session-enforced):

- Claim at dispatch (`bd update <id> --claim`), brief pins bead id + exact
  scope + staging worktree (never the trunk checkout); worker never runs `bd`.
- **Vendored-helper acceptance (cl-common class).** Before a branch lands,
  run `tools/Test-VendoredSync.ps1 -RepoPath <repo> -Trunk dev
  -Branch <branch>`. It intersects the branch diff with the vendored manifest
  rows and runs `Sync-VendoredHelpers.ps1 -Check` on the branch tip; exit 1
  names the `ROW` and `CANONICAL` file that must be re-vendored, exit 0 means
  no governed canonical changed or every vendored copy is in sync, exit 2 is
  `CANNOT-EVALUATE` and never a pass. A repo with no
  `interactive-qa-agent/tools/vendored-helpers.manifest.json` skips with that
  reason. `Invoke-RepoClean.ps1` runs the same gate as its `vendored-sync`
  step, so a groom blocks identically.
- Trunk lock around the land window only:
  `../git-operations/Invoke-TrunkMergeLock.ps1 -RepoRoot <repo> -Trunk dev`.
  Pass `-Owner` explicitly on Acquire AND Release — the default owner embeds
  the acquiring PID, and a later one-shot shell cannot release by default.
- Fresh `fetch`, `--no-ff`, owner-pushed branches only; assembly into
  `chore/batch-<id>` for depth ≥ 2, single push per Completion.
- Verify in staging first (short gates in-session, long pole dispatched per
  the CBK detached-worker pins), deploy-log verify (never hook exit code),
  T+30 check-back; drops return rows to queued with the gate-log pointer.
- `Test-SkillFormat references.resolve` may fail environmentally when the
  checker resolves `$env:CL_REPOS_ROOT` against a stale stable checkout;
  the worker must reproduce the in-branch proof (empty `git diff dev --`
  on the canonical path) and the binding gate is installer `-Verify`
  post-merge, which supersedes the exception.
- Durable check-back (worker ping is a hint, never the wake-up): before
  ending a turn with a worker outstanding, register a one-shot follow-up
  (Paseo schedule, `maxRuns: 1`, CI-checkback pattern) that re-polls bead
  + queue row + trunk tip and either closes out, re-dispatches (bounded),
  or re-registers itself. No turn ends with zero wake-ups pending.
- Claim hygiene: `bd update --claim` at dispatch; heartbeat/renew while
  supervising; going idle with work outstanding means handing the claim
  to the check-back (recorded on the bead note) or releasing it — never
  an expired lease nobody owns. Always record the worker session/agent
  id on the bead note.
- Linked workers: dispatch merge workers as linked child agents with
  completion notification, not bare background sessions, so a dead
  worker notifies instead of vanishing. A missing ping + idle worker at
  check-back counts as worker loss: re-dispatch bounded, then escalate.
- Collision gate: before dispatch, scan for rival assembly branches and
  worktrees on the same slice; adopt (verify + use) or stand down with
  the decision on the bead — never two landings of one slice.
- Styles, code-freeze/drop, prune, backoff polls, rescue adoption: followed
  from `$env:CL_REPOS_ROOT\currents-bookkeeping\Skills\hub-mode\REFERENCE.md`, never
  restated here.

## Dispatch durability (overnight continuity)

Failure modes observed 2026-10-21 (hub-cbk overnight drain) and their rules.
All are Hub-enforced; brief workers accordingly.

1. **Phantom dispatch.** A turn that promises dispatches but emits no tool
   call dispatches nothing. A dispatch exists iff the tool result carries a
   sessionID. End-of-turn check: every promised dispatch has a sessionID
   recorded (bead note or outbox started-line). No sessionID → re-issue,
   never claim.
2. **Foreground default blocks the Hub.** Lane dispatches default to
   foreground: each call holds the Hub turn until the worker finishes, and
   sibling dispatches in the same block abort. Every lane dispatch goes
   `background:true`; batch independent dispatches in one turn. Foreground
   is reserved for reads and verifications, never for builds, suites, or
   lands.
3. **No detached shells inside workers.** A worker that runs gates in a
   background shell and ends its session leaves unverifiable work: the shell
   dies with the session and the reported DONE is a claim, never a
   completion (observed ×3 in one night). Brief workers to run every command
   in the foreground and wait; outbox DONE is written only after the push
   command returns success.
4. **Verify before advancing.** Every DONE is verified against live evidence
   before the Hub closes beads or advances the queue — `git ls-remote` tip
   equals the reported tip, outbox terminal line present. Mismatch → the
   work is still outstanding: re-dispatch bounded, then escalate.
5. **Skip, don't hold; circle back.** One red land must not hold a serial
   merge queue (observed: 1 red parked 18 ready lands). The merge lane skips
   a red branch (outbox blocked with tail) and continues; HOLD only for
   trunk-integrity threats. Circle back at queue end: re-check the
   fix/finish outbox files and land what turned green; whatever is still red
   becomes an explicit REMAINING list, never a silent stall.
6. **Single-owner queue claims.** Two lanes running the same queue
   double-build (observed: stale pre-compaction lane vs fresh lane on the
   identical conformance queue). Before dispatch, census live agents plus
   outbox started-lines; the lane writes its started-claim to its outbox
   file at dispatch. A second started-claim on one queue is a collision:
   adjudicate (pick one design, stand the other down), never let both
   proceed.
7. **Record the death before the rescue.** When a started-line has no
   terminal and its session is gone, write the evidence to the outbox
   **before** touching the lane: `dead_session_id`,
   `last_user_message_at`, `last_event_type`, `last_error` (session store /
   agent status), the worktree and branch, and the untouched base SHA.
   Only then preserve the tree with a labeled rescue commit
   (`rescued(<bead>): <worker content verbatim>`) and run gates on it. The
   retry session's id belongs on the re-dispatch line, never in the death
   note. Without this record, "why did it fail" is unrecoverable — the
   27u.115a incident named the retry session in the death note and lost the
   dead worker's cause, leaving the rescue evidence un-attributable.
8. **A cutover closes every lane at once - recover by roster, never
   re-dispatch.** A credential cutover restarts Paseo, which ends every
   Paseo-hosted session including Hubs, and a Hub that comes back has also lost
   its view of the children it was supervising. Recovery is roster → resume →
   `Continue`, in that order: read
   `~/.salmon/State/key-check/last-cutover.json`, resume from its roster, and
   send each surviving non-terminal agent **one** `Continue` naming its exact
   missing artifacts (report, done file, gate lines). Re-dispatch only when the
   branch carries no commits - a resumed agent re-reads its brief, a
   re-dispatched one duplicates the work. The resume pass is idempotent (one
   sent `roster-resume` per `runId`+`agentId`), so both call sites - the helper
   after a proven cutover and the watch's recovery path - are safe. Measured
   2026-11-02 (runId `20261102-172700`): GO6 97 % wk → GO3, seam/User/pin all
   `GO3`, witness `verified-by-witness`, lanes resumed by `Continue`. **A Hub's
   first duty after a cutover is to enumerate its children**, before its own
   queue. Canonical: `Skills/credential-rescue/skills/key-check/SKILL.md`
   § After a cutover.
9. **A shared trunk cwd is not evidence an agent finished.** The roster
   snapshot marks an agent finished when its checkout already holds
   `.iqa-done-*.json` or `.iqa-report.md` - correct for a lane with its own
   worktree, wrong for a Hub whose cwd is the shared trunk, where merge workers'
   `.iqa-done-merge-*.json` files sit in the repo root. On 2026-11-02 that
   skipped the `cl-common` Hub and resumed only one of the Hubs; the code fix is
   bead `qz8`. Until it lands, require an **own-artifact match** (the done file
   names this agent's task or branch) **or a closed status** before treating an
   agent as finished; failing either, resume it.
10. **A vague brief stalls the lane it was meant to rescue - the salvage brief
    has a shape.** Same model, same repo, 2026-11-03: "find the writer and fix
    it" looped 29 minutes and committed nothing, while the replacement brief
    that named the file, capped the file set, named one test file, and demanded
    commit-then-push finished in 2.5 minutes. So a salvage or re-dispatch brief
    carries four things: the **file** (a closed set, paths not descriptions),
    the **test file** to run, the **cap** ("touch nothing else"), and
    **commit-then-push before you report**. Discovery is what consumed the 29
    minutes; the brief does that work instead.
11. **A durable dispatch is ASSERTED, never assumed.** A one-shot schedule
    (`maxRuns: 1`) is the documented way to survive a turn ending, and its fire
    can fail before any agent exists. Measured 2026-11-03 (bead
    `cl-common-q8k`): the only run ended `status=failed`, `agentId=null` on
    `EPERM: operation not permitted, rename '...\.paseo\schedules\<id>.json.<tmp>'`,
    the budget was consumed, and the tick had already moved on - the bead read
    as dispatched while nothing ran. The same EPERM also fails an UPDATE (the
    Hub re-arming its own rung) and the identical call succeeded seconds later,
    so it is momentary daemon write contention, not a leaked handle.

    Two helpers close the Hub's end of it:

    - `Test-ScheduleDispatch.ps1 -ScheduleId <id>` (or `-Name <name> -Cwd <repo>`)
      reads the record ONCE and returns one of four verdicts:
      `spawned-and-live` (exit 0), `spawned-and-terminal` (0),
      `failed-spawn` (1), `pending-fire` (3); whatever it cannot prove is
      `CANNOT-EVALUATE` (2). Run it immediately after arming a durable dispatch
      and again at every check-back. **`failed-spawn` or `CANNOT-EVALUATE` means
      the dispatch did not happen**: recreate the one-shot and write the failed
      run on the bead. **`pending-fire` means wait and assert again** - never
      report the dispatch as delivered. It reads the record as RAW TEXT on
      purpose: JSON coercion re-formats `nextRunAt` and loses its offset (bead
      `cl-common-gct`), so every instant it prints is the record's own token.
    - `Invoke-ScheduleRecordWrite.ps1` bounds the retry around any schedule
      read-modify-write (create, update, re-arm): exponential backoff capped by
      `-MaxDelayMilliseconds`, a bounded `-Attempts`, a read-back verify step,
      and a final error that names the operation, the schedule id and the last
      error. For the agent-driven surface - `paseo_create_schedule` /
      `paseo_update_schedule` are MCP tool calls, so no script can invoke them -
      pass the tool's error and attempt number (`-ErrorText ... -Attempt n`) and
      it answers `RETRY` (with the delay) or `STOP`, so the retry loop is
      mechanical. **A schedule record write that did not land is a dead cadence:
      never report it armed.**

    Re-arm is not create. A `maxRuns`-exhausted record that ended `completed`
    stays completed with `nextRunAt: null` after `paseo_update_schedule` (same
    bead), so the recovery for a `failed-spawn` one-shot is **delete + create a
    fresh schedule** with the same prompt and target, then assert again - never
    an update in place.

    Boundary, and it is upstream: the daemon's state write should be
    atomic-and-retried internally, and a `maxRuns` run that never produced an
    agent should not consume the budget. That lives inside `.paseo` state and
    belongs to Paseo, so this contract guards the Hub's end and names the defect;
    a Hub must never write the daemon's record files to work around it.

Tick discipline ties them together: the Hub re-derives queue state from live
evidence each tick (outbox terminals, `ls-remote` tips, live session census)
— never from carried estimates. A started-line with no terminal and no live
session is a dead lane: re-dispatch bounded, then escalate.

## SaaS resolutions (pointer table)

Full slot values: the `beads_skill` adapter ([ADAPTERS](../../core/ADAPTERS.md) -> `## External adapters`) ->
Merge slots row. Trunk `dev` all three repos (CBK: main folder is the trunk
checkout; UH: integration funnel, `prod` release-only; cl-common: `dev`
integration trunk, `prod` protected release). Gates CBK:
`typecheck` + `test:fe` + `test:backend` + `audit` + `verify:diag-off`;
UH: per `docs/agent-quality-gates.md`, deploy per `docs/deploy-outputs.md`;
cl-common (non-SaaS, no deploy): Pester suites where present + Harness Install
`-Verify` **and** `-VerifyLock` clean (the skills-lock verifier is
`Invoke-HarnessInstall.ps1 -VerifyLock`, which recomputes every `computedHash`);
deploy-verify N/A, pointer convergence is the close proof.

## Pointer convergence (completion rule, never a legacy queue)

## Skill-update fan-out (Hub duty)

A Hub that lands a change to shared Hub/IQA skills (`iqa-merge`,
`iqa-beads`, `iqa-common`, `iqa-beads-saas`, harness pointer surfaces)
pings every other live Hub (`hub-cbk`, `hub-uh`, `hub-common`,
`hub-salmon`) to refresh before its next merge-tick: direct wake-up
ping when the Hub session is live, durable handoff record
(`Tasks/00Handoff/`, pointing at the follow-up bead) when it is not. The
updating Hub refreshes its
own checkout first (re-read the canonical files — never assume the
session-start copy is current) and names the exact change + commit in
the ping. A Hub that receives the ping re-reads the canonical skill
files at its next tick and reports the refresh, never
blind-acknowledges. Skill-surface changes still ride the normal merge
flow (branch → drain) in their owning repo; the ping is notification,
not a bypass.
Pointer convergence is owned by the Hub flow, not a legacy salmon-run queue
(those trees are migration input only): after any merge drain that landed
skill-surface changes (new or
renamed skill, changed frontmatter, moved canonical body), the Hub completes
the Harness Install before it reports done. The lane works in the same
isolated worktree the merge used (root checkout stays on `dev`, never
touched), runs the installer with `-StableRoots '<worktree>=$env:CL_REPOS_ROOT\<repo>'`
for every `-RepoPaths` root, and ends with a `-Verify` clean run (zero
`create`/`update`; `stale-kept` is steady state, never drift). In-repo pointer
changes ride the normal merge flow; global surfaces converge live and are
verified by the clean `-Verify`. Same lane shape as the Pass 3 Tier-1 pointer
lane (`beads_skill` adapter -> `Pointer convergence` in the deployment's SaaS
reference) - the Hub applies it on every qualifying drain, not
only inside an audit. Fleet `-Verify` runs resolve the stable checkout, not
the merge tip: if that checkout lags `dev`, freshly landed skills report
`stale-kept <name> (unknown skill name)` (observed 2026-10-21 for grill-me,
story-reviewer, create-bead — alongside pre-existing unknowns). That is a
stale checkout, never a missing mapping: move the checkout to `dev`
(landing whatever holds it there first), never `-Prune` to "fix" it —
prune deletes installer-owned pointers with currently-dead targets. Moving the root checkout deletes tracked files absent on the target (observed: `.beads` wrappers vanishing mid-drain) — back up excluded-but-tracked state first and restore wrappers before running `bd`.

## Lane worktree lifecycle

A worktree is a lane's workspace, not scratch space. Two rules, both learned the
hard way on 2026-10-28:

- **Do not remove a worktree while any agent pointed at it may still be
  running.** A lane that reports "done" and is still finishing a suite, plus a
  salvage lane on the same checkout, both look idle from the Hub. Removing the
  directory mid-run destroys the lane's finishing work and forces a post-hoc
  reconstruction; the merge that follows is one combined commit instead of the
  intended series. Check the agent list for every agent whose brief named that
  path, not just the last one that messaged. A proven landing is **not**
  terminal-worker evidence — the two-condition sweep rule is `## Merge landing
  proof` → `### A proven landing closes the bead — it does not sweep the worker`.
- **A removed worktree can leave a partial remnant** (node_modules and a few
  dirs, no `.git`). `git worktree list` will not show it, and
  `git worktree remove` errors with `Invalid argument`. Delete it with the
  filesystem, then `git worktree prune`.

## Watch-list format

When reporting pending timers/check-backs, use one line per item with times
in America/Vancouver:

`18:00 - watchdog sweep, parked-bead audit (27u graph) [repeats 30m x 11]`
`on completion - split resolver gates + push (27u.64)`

Rules: the time is when the timer fires / the check-back occurs (schedule
`nextRunAt` converted to America/Vancouver for DISPLAY only — pass the raw value
with its `Z`/offset to `Get-HubCadence.ps1`, never the converted one). Compress
repeats as first-fire
+ `[repeats <cadence> x <remaining>]` — never list identical rows. Items with
no clock fire (worker completions) use `on completion - <desc> (<bead>)`.
A retired one-shot (fired against already-closed beads) is reported once,
then dropped from the list.

## Peer Hub (a live Hub already holds this repo)

A **peer Hub** is another session that is advertised for this repo and holds its
drain. It is a ladder state (`peer-hub`), not an error and not a stand-down: the
work is owned, just not by this session.

Advertised means either signal - the registry record first, because it is a file
and crosses workspace, session and machine boundaries; the triple second:

1. **A fresh registry record.** `HubRegistry.ps1 -Mode Find -Repo <slug>
   -MaxAgeMinutes 15 -Json` returns `state: live` (exit 0) with
   `{ agentId, machine, repoPath, heartbeatAt }`. `hubCount > 1` means a
   co-registered peer; say so in the message rather than picking one silently.
2. **The corroborated triple.** A live session carrying `hub-<x>` and
   `iqa-role=merge`, whose `cwd` sits under the repo root, and the worktree lease
   on that repo root held by the same owner.

The three reads, exactly - all are helpers or tools a Hub already has:

| Read | Command | What it proves |
| :--- | :--- | :--- |
| Registry | `HubRegistry.ps1 -Mode Find -Repo <slug> -MaxAgeMinutes 15 -Json` | `state: live` = an advertisement. `unknown` (exit 3) = an entry whose heartbeat is older than the window: still a Hub, not a no-Hub verdict. `dead` (exit 1) = the registry's own verdict only. |
| Session | `paseo_get_agent_status <agentId>` (or `paseo inspect <agentId>`) | `status: running`, labels carry `hub-<x>` and `iqa-role=merge`, `cwd` under the repo root. |
| Lease | `Invoke-WorktreeLease.ps1 -Mode Status -Path <repoRoot>` | `Owner` / `agentId` equals that agent. `Live: false` with a live labelled owner session still means Hub present - a CLI-heartbeat Hub's pid dies between calls. |

Both helpers are adapter values, never paths baked into this file: `scripts_root`
defaults to this package's `vendor/`, where `HubRegistry.ps1` is vendored, and
the lease helper comes from the `git-operations` owner (`Invoke-WorktreeLease.ps1`
is vendored too). The fleet paths (`Skills\iqa-merge`, `Skills\git-operations`)
are development overrides only.

Rules that make the verdict honest:

- **`dead` from the registry is not a no-Hub verdict by itself.** A Hub running a
  40-minute suite cannot heartbeat inside a 15-minute window, so `dead` is
  routinely wrong about a live peer. Corroborate with the session and the lease
  before concluding anything, and never park, spawn a duplicate, or take over on
  the registry's word alone.
- **A peer is real when the registry says live OR the triple holds** - one signal
  is enough to stand down from the drain, because the cost of a duplicate drain is
  a double land. Two reads that disagree are a stalemate to report, not a takeover
  licence.
- **Terminal requires all three signals**: no fresh registry record, session not
  running, lease released. One missing signal is a slow peer. When all three
  hold, the state becomes `dispatched` and the normal gear applies on the next
  turn.
- **The peer owns the drain.** Under `peer-hub` this session does not mint, claim,
  dispatch, merge, close, delete the standing heartbeat, or remove the
  `hub-watch-<repo>` backstop. It prints
  `Rung: none (peer-hub: <peer-agent-short-id> owns <repo>)` and re-checks on the
  `peer-hub` gear (15 min, `## Hub heartbeat (self-wake)` -> the gear ladder).

## Hub heartbeat (self-wake)

The Hub session only acts when messaged (user turn, worker ping, schedule
wake-up). Check-backs and watchdogs run as separate agents whose outputs do
not wake the Hub — a terminal with no covering wake-up sits unprocessed
(precedent: 70-minute stall on a landed trunk, 2026-10-21, resolver phase
had no check-back and no self-wake).

- At Hub start, create a heartbeat on itself and keep it ADAPTIVE. A fixed
  cadence either burns turns when the queue is cold or leaves work idle when
  it is hot; the operator's rule (2026-10-28) is that the gear is chosen by
  what the last probe found, not by a clock:
  **1 min** right after an operator prompt, **2 min** while a lane was just
  dispatched or every lane is healthy and working (never spend more than that
  on a long run), **5 → 15 min → hourly** only when nothing is running and
  every open bead is operator-blocked; and **none** (a 15-minute liveness
  re-check, not a drain tick) when a live peer Hub holds this repo's drain - a
  peer-held repo is work owned elsewhere, not "nothing is running". The heartbeat
  is the fast path; the visible
  `hub-watch-<repo>` `new-agent` backstop (`## Hub start contract`) is the
  proof, and both are registered in the same turn.
- The probe is deliberately CHEAP — one `paseo_list_agents` call
  (`statuses: ['running']`, repo cwd). Healthy lanes ⇒ report one line and
  stop; no `bd`, no git, no timeline reads, no merging. Only when no lane is
  running does it fall through to `bd ready` and dispatch. That ordering is
  the whole token saving: health is one call, work is the fallback.
- Self-reschedule FIRST: each fire creates its successor heartbeat
  (`maxRuns: 1`) with the cron the probe decided, before doing anything
  else, so a crash mid-turn still leaves a live wake-up. Never hold a
  long-lived heartbeat open. The fire prints one line —
  `Rung: <name> next <cadence> — successor created <ts>` — so the next rung
  is provable from the transcript, not inferred from a promise.
- Each actionable fire runs the merge-tick (drain outbox
  → verify → close/re-dispatch; coverage check; dispatch ready beads, one
  trunk pusher at a time; lease refresh if a push is outstanding; report
  the watch list in the compressed format).
- **The fire is a new agent, so it does not own the registry entry.** Renew
  the hub of record, not your transient id:
  `HubRegistry.ps1 -Mode Heartbeat -Repo <slug> -HubAgentId <hub-of-record-id>`
  (or `SALMON_HUB_AGENT_ID`, or nothing at all — the helper then takes the
  live primary). `-AgentId $env:PASEO_AGENT_ID` is refused, and a tick must
  never fall back to `Register`: on 2026-11-03 (cl-common-y49) four fires that
  did exactly that left `hubCount: 6`, `duplicate: true`, and a primary
  flapping between the tick and the real Hub. Exit 4 `no-hub-of-record` means
  there is nothing to renew — report it, do not invent a hub.
- Coverage invariant: before ending ANY turn, every outstanding worker
  (bead note names a session, no terminal outbox line) must have a live
  wake-up covering it — a dedicated one-shot or the heartbeat itself,
  recorded on the bead note. Dispatching a new phase (retry, resolver,
  fold, land) without same-turn coverage is a defect.
- **End-of-turn rung check (every turn, including a one-line prompt reply).**
  A prompt is fresh evidence that work may have arrived, but the rung the
  last fire left behind can be an hour out — waiting for that far fire to
  happen and *then* rescheduling is the whole failure. So each turn closes
  with one local call:

  ```
  pwsh -NoProfile -File <Skills>/iqa-merge/Get-HubCadence.ps1 -State <prompt|dispatched|healthy|blocked|stand-down> `
       [-SincePromptMinutes <n>] [-QuietRounds <n>] [-NextFireAt <raw nextRunAt, Z or offset intact>] [-ExpiresAt <holds-expiry>] `
       [-RunHistoryPath <schedule-runs.json>] [-HeldCron <armed expression>] [-AcceptEffectiveCadence] [-RequireEffectiveCadence] `
       [-Name hub-watch-<repo>]
  ```

  It returns the required gear, the cron, and one action — **CREATE**
  (no rung known), **RECREATE** (the held rung fires later than the gear, is
  overdue, or expires before it can cover two fires), **HOLD** (inside the
  gear), **LAPSE** (stand-down) — plus the `RungLine` to print. Act on it in
  the same turn: on CREATE/RECREATE delete the tracked heartbeat and create
  the successor with the returned cron (expiry ≥ two fires), then print the
  line. Print the line on HOLD too; that is how a silent hour is
  distinguishable from a dead timer.

  **A gear is NOMINAL until the run history proves it.** Each fire spawns an
  agent that outlives the interval, and the daemon drops the overlapping fires
  instead of queueing them, so a `*/2` rung measured one verdict per 2-10
  minutes (schedule `b3fdf56a`, 2026-11-03). Pass `-RunHistoryPath` (or
  `-RunHistoryJson`) with the schedule's `{ scheduledFor, status }` rows and the
  helper reports the EFFECTIVE cadence — the median gap between consecutive
  `succeeded`/`running` fires — states both on the line when they disagree
  (`HOLD (nominal 2 min, effective 6 min)`), and drives the cadence verdict from
  the effective figure only, naming the satisfiable cron
  (`SuggestedMinutes`/`SuggestedCron`) instead of recreating into the same
  unsatisfiable interval. **The measurement is ERA-WINDOWED**: one history holds
  every regime the schedule has ever run, so an all-history median never
  converges — a rung re-armed from `*/2` to `*/10` kept reading the retired
  4-minute median over 139 gaps while its last 25-40 fires delivered 10 minutes
  (measured 2026-11-03, `hub-tick-runs.json`: 141 fires, all-history median
  4 min, last-40 median 10 min, median run 6.4 min). Both the effective cadence
  and the run-duration floor are therefore measured over the most recent **40**
  qualifying fires (fewer when the history is shorter): wide enough that one
  20-minute run cannot swing the median, narrow enough that the retired regime
  stops voting. The winner is stated on `EffectiveCadenceNote` (`the last N of M
  fires`) so the era is visible rather than assumed. **The satisfiable gear is
  also floored at `ceil(median run duration)`** over the same window
  (`RunDurationFloorMinutes`, from the rows' `startedAt`/`endedAt`), because a
  cron finer than a run's own duration is dropped by the daemon by
  construction; rows without both timestamps contribute no sample
  (`RunDurationSamples`), and with no samples the floor is absent rather than
  guessed. **Pass the record's raw `nextRunAt` with its offset
  intact.** The schedule record's `nextRunAt` is a UTC instant
  (`"2026-11-03T16:02:00.000Z"`), so pass it quoted and untouched
  (`-NextFireAt '2026-11-03T16:02:00.000Z'`); if you reformat it for a report,
  carry the offset back (`'2026-11-03T09:02:00-07:00'`). The helper **refuses**
  an instant that has neither a `Z` nor an explicit offset instead of assuming
  UTC — exit 1, `NextFireAt '2026-11-03T09:02:00' has no offset; pass a Z or an
  explicit offset` — and refuses a bare `[datetime]` whose Kind is Unspecified
  for the same reason (Kind Utc/Local are taken as stated). That refusal closes
  a measured ~7-hour phantom: on one rung at 09:04 local on 2026-11-03,
  `'16:02:00Z'` HOLD (fires in -0.1 min), `'09:02:00-07:00'` HOLD (fires in
  -0.1 min), `'09:02:00'` RECREATE (overdue by 420.1 min) — the naive form is
  the same call this tick prescribes, one time-zone conversion away from a
  confident wrong verdict. An absent
  history is named `cannot-evaluate` (JSON status and the `Cadence:` line), and
  `-RequireEffectiveCadence` turns that absence into a non-zero CANNOT-EVALUATE
  for a turn that wants the effective cadence as its assurance.

  **A deferral behind a live run is HOLD, never a dead rung.** When the run
  history contains a `running` fire of this schedule that started at or before
  the held fire, the daemon is holding the next fire behind that run, and the
  rung is healthy no matter how late the record reads (measured 2026-11-03: a
  healthy `*/2` rung reported "overdue by 3.5 min" three times in half an hour
  because the previous turn was still running). The verdict is `HOLD`,
  `Deferred: true`, `DeferredReason: in-flight`, and the reason names the
  in-flight run's `scheduledFor` and its age - check that run, do not re-arm.
  A running fire that started *after* the held fire is the opposite evidence
  (the record is behind reality), so that stays a RECREATE. With no history
  only the old one-interval allowance applies, and a rung overdue by more than
  one interval with nothing in flight is a stale record: RECREATE.

  **Every RECREATE is clearable.** Obeying the verdict once must end it;
  re-arming on every tick is churn dressed as compliance (measured
  2026-11-03, `cl-common-leb`: required 2 min is state-derived, so RECREATE at
  the measured `*/4` returned forever, including on a rung already armed at
  `*/4`). Pass `-HeldCron` with the schedule record's own `expression`, and the
  helper compares the ARMED interval against the satisfiable gear - the larger
  of the state gear and the measured effective cadence:

  - armed at the satisfiable gear ⇒ `HOLD` ("the satisfiable gear is the gear
    already held"), while the `Rung` line still states both cadences;
  - armed coarser than the satisfiable gear ⇒ `RECREATE` at
    `SatisfiableMinutes`/`SatisfiableCron` — unless `-AcceptEffectiveCadence`
    says the coarser rung is deliberate, in which case it is `HOLD` (a `*/10`
    rung for a repo whose runs last 7 minutes is a *chosen* landing spot, not a
    stale gear);
  - armed finer than the daemon delivers (a `*/2` cron measuring one fire per
    8 min) ⇒ `RECREATE` at the measured gear, or `HOLD` with
    `-AcceptEffectiveCadence` when the finer cron is deliberate.

  So the switch accepts a deliberate divergence in EITHER direction, and a
  rung that is genuinely too slow still recreates at the era gear. Before
  cl-common-q64 the switch was consulted only on the armed-FASTER branch, so an
  accepted-but-slower rung could only be cleared by overriding a false
  `RECREATE` by hand — a silent gate override.

  Without `-HeldCron` the effective-cadence RECREATE keeps its old behaviour,
  and its reason names both ways to clear it. `-HeldIntervalMinutes` is the
  same evidence when the caller already parsed the cron; a cron that cannot be
  placed at a minute interval is refused by name rather than guessed.

- **Two diagnostics that manufacture their own verdict.** (a) A process filter
  that names the script you are looking for (`Invoke-KeyCheck.ps1`) matches
  *its own command line*, so a single watch read as three churning processes
  and was reported as an external spawner. Prove a process count with a filter
  that cannot match the querying command (a `<script>*<flag>` pattern plus a
  parent check), never with the pattern being run. (b) `Get-HubCadence.ps1` is
  a pure function of what you pass it, so a plausible-but-guessed
  `-NextFireAt` produced `RECREATE: overdue by 4 min` twice on a healthy `*/2`
  rung (2026-11-03). Read `nextRunAt` from the schedule record
  (`paseo_list_schedules`) before evaluating; never estimate it, and never
  retype it without its `Z`/offset — an offset-less instant is now refused by
  name instead of being read as UTC.
- **Gear ladder, in one place** (the helper encodes exactly this):

  | Observed state | Gear |
  | :--- | :--- |
  | an operator prompt or worker ping arrived | 1 min |
  | inside the 10-minute prompt window (any state except stand-down and peer-hub) | 1 min |
  | a lane/worker was just dispatched | 2 min |
  | every lane running, none needs attention | 2 min |
  | blocked, 0–1 quiet rounds | 5 min |
  | blocked, 2 quiet rounds | 15 min |
  | blocked, 3+ quiet rounds | 60 min |
  | a peer Hub holds this repo's drain (advertised, corroborated) | 15 min - liveness re-check only; `Rung: none (peer-hub: <peer-agent-short-id> owns <repo>)` |
  | stand-down (zero actionable work) | none — `Rung: none (stand-down)` |

  A dispatched Hub is woken by pings, and the rung is only a backstop for a
  missed ping, so `dispatched` matches the `healthy` gear rather than racing
  it — a 1-minute tick bought nothing and cost a model turn every minute
  (operator decision 2026-11-03: the 1-minute default was a mistake).

  The prompt floor outranks every other row: after an operator prompt the
  gear is 1 min for 10 minutes even if the last probe said "blocked at 60".
  It does not outrank `peer-hub`: a prompt addressed to this session is not a
  licence to drain a repo another Hub owns, so the turn re-corroborates the
  peer (`## Peer Hub (a live Hub already holds this repo)`), prints the
  `peer-hub` line, and leaves the 15-minute liveness gear standing.

  **`peer-hub` - the state for "a live peer Hub owns this repo".** The ladder
  used to have no way to say this: a gate run sat on 60 ready beads that a live
  peer Hub held, so every value misdescribed the truth and the line was printed
  under `blocked`. A peer Hub is advertised - a fresh registry record, or the
  corroborated triple of live session + `hub-<x>`/`iqa-role=merge` labels + lease
  held by that same owner (`## Peer Hub (a live Hub already holds this repo)`) -
  and it holds this repo's drain.

  Under `peer-hub` the required gear is a **liveness re-check, never a drain
  tick**: no `bd`, no claim, no dispatch, no merge, no close. **15 min** is the
  registry's own freshness window (`-MaxAgeMinutes 15`, the number the discovery
  read uses), which bounds how long a dead peer can go unnoticed to one window,
  and it is 7.5x the peer's 2-minute `healthy` gear, so it cannot duplicate the
  peer's own ticks.

  Three rules make it honest:

  - **Not a stand-down, and not a close.** `peer-hub` is work owned elsewhere,
    not zero work. It prints `Rung: none (peer-hub: <peer-agent-short-id> owns
    <repo>)`, it never prints `STAND-DOWN` or `Rung: none (stand-down)`, and it
    must not delete the standing heartbeat or the `hub-watch-<repo>` backstop -
    deleting them is how a repo with a dead peer becomes a repo nobody watches.
  - **Terminal needs all three signals**: no fresh registry record, session not
    running, lease released. One missing signal is a slow peer, never a dead one;
    a Hub mid-suite cannot heartbeat inside 15 minutes. When all three hold, the
    state becomes `dispatched` and the normal gear applies on the next turn -
    the usual takeover path, run once.
  - **The helper carries the state** (gap closed 2026-11-03 by the integration
    lane). `Get-HubCadence.ps1 -State` accepts
    `prompt|dispatched|healthy|blocked|peer-hub|stand-down`; `peer-hub` returns
    the 15-minute liveness rung (`*/15 * * * *`, `required 15 min`) and a prompt
    does **not** floor it, matching the gear ladder above. Never pass `blocked`,
    `healthy` or any other value as a stand-in: a substituted state prints a gear
    that misdescribes the truth, which is the defect this state exists to remove.
    The helper's rung is the liveness backstop; the drain line this member prints
    is `Rung: none (peer-hub: <peer-agent-short-id> owns <repo>)`.

- Stop condition: zero actionable work (every bead closed or
  blocked-on-operator/owner, no running workers, outbox empty) → report
  STAND-DOWN with the parked list and `Rung: none (stand-down)`, and let the
  heartbeat lapse. The backstop schedule stays registered until the Hub
  closes (it is the takeover path, not a tick); delete it at Close with the
  labels. Silence with no printed rung is always a defect, never a pause.

### One rung per repo (binding)

**Exactly one ACTIVE MERGE-TICK rung may exist per repo graph.** Two active
rungs are two writers on one trunk, and one will sweep a branch, a trunk ref or
a worktree out from under the other's merge worker. Measured 2026-11-03
(bead `cl-common-3tv`): main rung `b3fdf56a` and backstop `728ea6ac` both fired
for `cl-common`; one tick verified `fix/7cu-vendored-fallback`, minted a merge
bead and dispatched a capacity-gated merge worker, while the other tick landed
the same branch, fast-forwarded `dev` and `origin/dev`, deleted the local
branch and removed the lane's worktree admin entry - orphaning the worker in a
deleted-branch checkout and double-mutating the trunk.

The rule is enforced by one owner script, never re-implemented:

```
pwsh -NoProfile -File <Skills>/iqa-merge/Test-SingleHubRung.ps1 -Repo <repo> [-Json]
```

It reads the Paseo schedule store (`%USERPROFILE%\.paseo\schedules`, read-only;
`-SchedulesPath`/`-SchedulesJson`/`-Schedules` for a store in hand) and judges
only the MERGE-TICK rung class: schedule names starting `hub-watch`, or prompts
carrying a `MERGE-TICK` / `HUB BACKSTOP` marker. A rung is identified by every
GUID in its prompt (`session:<guid>`) and by its repo evidence (`hub-<x>`
tokens, `Repo root:`/`-RepoPath`/`-Repo`/`cwd =` in the prompt, the target
`cwd`, or the `hub-watch-<repo>[-backstop]` name). Two ACTIVE rungs sharing any
key are a refusal.

| Exit | Verdict | Meaning |
| :--- | :--- | :--- |
| 0 | `PASS` | at most one active rung; paused/completed rungs are named as tolerated |
| 1 | `REFUSE` | two or more active rungs share a repo or hub session; both ids and crons are printed |
| 2 | `CANNOT-EVALUATE` | unreadable schedule source, or an active rung with no identity at all - never a pass |
| 3 | `NO-RUNG` | no active rung for this repo; create exactly one in the turn you advertise |

`Invoke-HubProbe.ps1` runs the guard as its `rungs` part at Hub start,
routing exit 1/2 to `BLOCKED` and exit 3 to `INFO`. The guard itself never
mutates a schedule: pausing, deleting or updating one is the Hub's act, after
it has read the refusal.

**A pause is tolerated, deletion is not required - but only while it stays
paused.** A paused backstop still counts as wake-up coverage for a resume or a
handover, and resuming it re-creates the second active rung; the guard names it
in every PASS so the tolerance is visible rather than assumed. A `completed`
rung is history and is ignored.

**What a Hub does when the guard refuses:**

1. **Which rung wins.** Keep the rung addressed to the repo's live hub of
   record - the one whose prompt carries that Hub's session id (`session:<guid>`)
   and whose target cwd is the repo. Between a main `hub-watch-<repo>` and a
   `...-backstop`, the main rung wins: it is the fast path, and the backstop's
   takeover path only needs to exist, not to fire alongside it. When neither
   carries a session id, keep the newest (largest `createdAt`) rung, and record
   the tie-break in the bead note.
2. **How the other is retired.** `paseo_pause_schedule` (reversible) is the
   default, because the backstop is the resume/handover path and a deleted
   schedule cannot be re-armed without re-deriving its prompt. Record
   `<id> <name> <cron> paused because <winner-id> is the repo's one active
   MERGE-TICK rung` on the bead. Delete only a rung whose prompt carries no
   unique knowledge and whose owner has confirmed it is dead. Never resume the
   retired rung while the winner is active, and never create a replacement for
   it in the same turn.
3. **Re-run the guard** and paste the `PASS` line (it names the winner and the
   tolerated pause) into the turn's report. A refusal left unresolved is a
   blocked Hub, not a working one.

Other schedule classes (a nightly suite, a CI check-back, an overnight hub tick
named differently) are deliberately not judged by this guard; a second schedule
of one of those classes that mutates the same trunk is the same hazard and needs
its own retirement decision, but this helper will not raise it for you.

## Verification checklist

- Philosophy compliance is part of the contract, not a style note: `SKILL.md`
  carries `## Development philosophy (binding)` and the two red lines that follow
  from it (no roadmap merge without its flag; no "done" that is a status code),
  and `ENROLMENT.md` exists as the on-ramp a brand-new agent can follow to all
  five receipts without reading another Hub's transcript.
- `ENROLMENT.md` stays true to the helpers: every command in it resolves, the
  gate ids it lists exist in the repo's `scripts/gate/registry.mjs`, and the
  traps in §8 are ones actually observed (not hypotheticals).

- `SKILL.md` ≤ 120 lines (count via `(Get-Content).Count` — `Measure-Object -Line` undercounts); no restated pass/delegation/watchdog text.
- Plan-mode invocation alerts (switch to Build mode) and stops with no lease,
  labels, rows, or beads touched.
- `IQA Merge Mode`/`IQA-Merge Mode`/`Hub Mode` routes here and always
  wears Hub labels; only `Sub Mode`/`IQA Sub Mode` takes the forwarder
  path (complete `--note` packet, row verified, wake-up-only ping, Hub
  acks by `merging` mark, Sub stops only on ack — unacked never
  archives); bare `IQA` unchanged.
- Live: two Subs → two merge beads + `blocks` edge, serial drain per
  dependency, Hub chat responsive; no-Hub Sub parks + alerts with path;
  merge commit + push + focused suite + deploy-log `OK` + probe, bead closed
  with refs; `bd ready` orders a fix→merge→merge chain mechanically.
- Wake-up ladder: a rung is LIVE at every moment of the session
  (`paseo_create_heartbeat` A→B→C→D), and the last fire of each rung names
  the rung it created. A Hub turn that ends with outstanding work and no
  live rung is a defect, not a pause — this is the class that let a ready
  bead sit idle while the Hub waited for a worker ping (2026-10-28).
- Hub start contract: all five receipts (lease `Live: true`; the printed
  `HubRegistry.ps1 -Mode Register` result; labels + the self-lookup verdict;
  the printed `paseo_create_heartbeat` result; a `hub-watch-<repo>` schedule
  with a future `nextRunAt`) appear in the
  transcript before the first tick, and every turn ending with outstanding
  work prints its `Rung:` line. A Hub that drains without them is out of
  contract — the fix is to advertise and register, never to "carry on
  quietly".
- Backstop auditability: `paseo_list_schedules` shows `hub-watch-<repo>` alive
  (future `nextRunAt`) or dead (`completed`). A heartbeat alone is never
  accepted as the only timer — it has no list surface, so its absence is
  indistinguishable from its never having existed.
- Cadence gate: every turn ends with a `Get-HubCadence.ps1` call and its
  printed `Rung:` line; a prompt reply never leaves a rung longer than 1
  minute, and a rung firing later than the current gear is recreated in the
  same turn rather than trusted. `Tests/Get-HubCadence.Tests.ps1` pins the
  ladder, the prompt floor, and the CREATE/RECREATE/HOLD/LAPSE decisions.
- Drain durability: every worker dispatch leaves a one-shot check-back
  pending; a tick that finds landed-but-open work closes out instead of
  re-landing; claims never expire silently; rival assemblies adopt or
  stand down before dispatch.
- Lookup robustness: dead-pid lease + live labeled owner session resolves
  Hub (never no-Hub); exact `hub-<x>` scan with present-labels diagnostic;
  Hub self-verifies its advertisement at session start.
- Continuity: every promised dispatch has a sessionID in hand; every DONE is
  verified against `ls-remote` before close-out; serial queues skip-don't-hold
  with circle-back; no turn ends with unclaimed in-flight work.

## Lane supervisors

A lane supervisor is a persistent detached worker that owns one ordered queue
top-to-bottom while the Hub attends elsewhere (grill sessions, reviews). Two
shapes, both proven in-session (merge queue 5/5 drained, build queue active):
- Merge lane: serial land queue. Strictly one merge/push at a time; adopts
  in-flight lands (verify-then-proceed, never duplicate); resolves conflicts
  only when both sides are Hub-lane commits, else escalates BLOCKED and holds
  (stacked items make order contractual - Q2-on-Q1 precedent).
- Build lane: serial build queue. One build at a time; triggered items poll
  their prerequisite (outbox terminal + origin branch tip) without touching
  the prerequisite worker's checkout; shared-file follow-ons stack on the
  prerequisite branch (D2-on-D1, picker-on-B3 precedent); Hub fast-forwards
  at land time.
Standing rules for both: no bd writes of any kind (Hub closes from lane
reports); no deploys; per-item outbox terminals on the item's own file plus
one lane-terminal line (QUEUE-DRAINED / LANE-IDLE); escalate-and-hold on any
red (GATE-RED + tail, BLOCKED + files); all state in ledger + outbox so the
Hub can reclaim the queue with zero hidden state.
Land-time follow-ups ride the land, not a new bead: catalog the l10n keys,
fold the stacked picker, at merge time (Q1/B3 precedent). Standing push
discipline: hooks on, never --no-verify, generous timeout (120s timeouts hit
on large pushes; 600s retry succeeded with origin untouched).
Companion to `## Hub heartbeat (self-wake)` - the heartbeat wakes the Hub;
lanes keep moving while it is busy elsewhere.

## Watch-list status counts

Each tick recomputes the graph census from live state (bd list/show read-only
+ full-file outbox scan, never tails-only) and reports one line:
`Status: <queued> queued - <building> building - <merging> merging`.
Building = bead note names a live worker with no terminal outbox line.
Merging = the single-pusher land queue (current merge + queued depth; only
one merges at a time). Queued = everything else actionable. Ambiguous beads
(worker named, outbox silent past ETA) report as WATCH, never as building.
A read-only counter subagent owns the census so the Hub turn stays
interactive; the tick verifies the counts before acting on them. Companion
to `## Watch-list format` (timers) - counts say what waits, timers say when.

## Lane heartbeat (adaptive)

Lanes poll rather than spin: 60-second checks while work is flowing or just
finished; after 5 consecutive quiet polls (nothing actionable, no new beads,
no terminal outbox lines), back off to 300-second checks; stand down at 60
minutes elapsed with LANE-IDLE. Any new work resets the series to 60-second
checks for another 5 quiet minutes, and so on. Implement with bounded sleep
loops (60s/300s increments), never an unbounded wait. Rationale: minute-level
responsiveness when the queue is hot, near-zero load when it is not, and a
guaranteed end so a forgotten lane can never linger past its bound.

**Liveness is a file write, not a timeline beat.** A cancelled lane kept
printing status updates while writing no file for 20 minutes, so a timeline
entry (or an `updatedAt` that keeps moving) is not progress. To answer "is this
lane alive", read the newest file mtime in its worktree.

## Tick census (Hub)

The Hub tick re-runs the graph census from live state every round (same
read-only sources as the status line) instead of carrying estimates forward -
precedent: a stale carried 19 corrected by recount. The tick acts on the
fresh counts (dispatchable-but-idle items get dispatched, stale notes get
corrected) and reports the Status line verbatim. Bookkeeping-block override:
`bd close --force` is allowed only when the blocker is chain-ordering
formalities moot for the verified result (work complete and pushed, blocker
scope unrelated), with the justification logged on the bead in the same turn -
precedent: 27u.11 (R3 NO-GAP over queued R2 land), 27u.22 (B-P13 built over
S6-blocked deletions). Never force past a substantive gate (red lanes,
missing QA accounts, unsigned operator items).

## Development philosophy (long form)

Canonical authority: [SKILL.md](SKILL.md) -> `### Development philosophy`, which
carries the eight bindings and enforces them at every dispatch and merge verdict
(the package mirrors the fleet `development-philosophy` skill by name). This
section is what they mean at Hub altitude - the questions a tick asks and the
ways a Hub has got them wrong. Where this section and the bindings disagree,
the bindings win for *shape*; the repo's code wins for *behaviour*.

**MVP or roadmap?** Ask one question per bead: *is this the existing product
surface made correct, isolated, priced and operable?* If yes — MVP, and it can
land as soon as its gates pass. If no — roadmap, and it lands **dark**. The
temptation is always a feature that is "nearly built"; nearly-built is not a
bucket. A Hub that lets "nearly built" ride as MVP has moved the release date
without anyone deciding to. Record the bucket in the dispatch receipt; a roadmap
item names its `roadmap.md` line, because a roadmap item with no roadmap line is
either misfiled or out of scope.

**What "ships dark" costs the Hub.** Flag catalogue entry, default `false`,
resolution order user > org > default, unknown key resolves `false` *and logs*,
`404` (never `403` — that leaks existence) plus a genuinely unroutable page when
off, and one audit row per enable. The merge verdict for such a bead is: no flag
⇒ send it back; flag present but reachable without it ⇒ send it back. Turning it
on afterwards is an operator act on one org, then one user, then globally — not
something a deploy does.

**What "deployed" means.** In order, and each one is evidence you can paste:
artifact identity (fingerprint or a new symbol in the served bundle, e.g.
`main-<hash>.js`) → schema state (migration applied and visible, not merely
shipped) → surface shape (the designed route, *including* the 404/401 negatives)
→ persisted effect (rows, files, signatures, mail actually read back) → diff
review of what changed. `UPDATE_COMPLETE`, a changed stack and a green health
check are none of these. When only the first is true, the honest sentence is
"stack updated, artifact unverified" — never upgrade an assumption into a fact by
repeating it.

**What counts as quality evidence.** A status code is a claim; a row is evidence.
A fix needs a failing reproduction captured against pre-fix code, and a test
double must never pin the value that hides the defect. A gate that cannot run is
`cannot-evaluate` — never a pass, never a failure. Never lower a threshold, widen
a policy, weaken a test, or add a `Stryker disable` to reach green: an equivalent
mutant is deleted. A measurement taken under load is not a finding; re-measure
quiet before you act on it. Mutation is nightly, never a lane gate.

**Which tier to buy.** contract test (ms) → PGlite integration (s) → deployed
smoke (~1 s) → journey (min) → full suite. A lane stops at the cheapest tier that
answers its question; climbing needs the sentence "the cheaper tier could not
answer because …". The Hub checks that sentence, not the tier.

**Approvals.** Nothing money-moving, prod-touching, legal/compliance-signing or
destructive happens on a lane's word, on a recommendation nobody answered, or on
"the operator seemed fine with it". Quote the instruction or do not act. The two
standing grants (§ `## Standing grants` in `SKILL.md`) are the complete list of
pre-approvals; anything adjacent is not covered by analogy.

**Wave continuity, long form.** An approved epic is approved for its whole queue,
so the Hub's failure mode is not a wrong merge — it is a *stalled* queue. After
every landing: prove it, deploy dev, re-read `bd ready` and capacity, and
dispatch the next wave before the turn ends. Lanes that come back BLOCKED get
their block recorded on the bead and routed to the decision queue while the rest
of the wave keeps moving; one red branch never holds a serial queue (skip and
circle back, then publish an explicit REMAINING list). The three legitimate stops
are the ones the operator named, a red gate the Hub cannot fix, and a credential
or account it does not have.

**The gate, before "done".** Scope stated (MVP or roadmap + line) · flag present
and off with a 404 when off, for roadmap · done is a persisted effect · every
gate claim quotes a number and an artefact path · no flake tolerated or
re-baselined · a bug fix shipped its failing reproduction · no threshold lowered
· nothing operator-gated happened without a quoted instruction · every decision
is on a bead, not in the transcript.



## Moved from SKILL.md

_Moved from `SKILL.md` 2026-10-31 (progressive-disclosure split; content unchanged)._

## Lane suborchestrators (operator order 2026-10-25)

The Hub stays interactive. Work is grouped into **lanes** and each lane gets a
detached suborchestrator that owns the whole item set end to end:

- The Hub dispatches one lane per coherent item set with its own worktree and
  branch. The lane may create and block on its own child agents for recon,
  coding, and review.
- The lane returns one branch, one report, test evidence, and a merge
  recommendation. It never merges to the trunk and never deploys.
- The Hub remains the only merge/deploy owner. It reviews the lane report and
  lands one branch at a time.
- The Hub must not sleep or poll (`Start-Sleep`, repeated status checks, or a
  blocking child). Dispatch detached, end the turn, and let the lane's
  completion ping resume the conversation.
- Lane child agents count against the same key-set cap; the lane owns its fan-out
  and must stay inside the pool budget.
- The Hub does not execute work itself: beads first, then a detached lane; only a one-file/under-60s task is exempt ([REFERENCE.md](REFERENCE.md)).
- **The Hub never runs Vitest, `npm test`, `npm run test:*`, Stryker, or any other blocking test/mutation battery.** Those runs belong to a detached worker; the Hub reads the report and evidence. This is a hard rule: a suite run in the Hub blocks the interactive role and is a defect.

## Work Shape Gate (Hub and Sub)

Mandatory before the first tool call of any task. Classify the **whole** unit
of work, not the next step.

| Role | Allowed inline | Must become a bead + detached worker |
| :--- | :--- | :--- |
| Hub | one read-only inspection, a one-file edit, one command at or under 60s, an operator decision | anything multi-file, multi-step, over 60s, or any build/test/mutation/patch-apply/regen/merge sequence |
| Sub | the claimed bead's own implementation and its acceptance commands | unrelated work, a second bead, or a suite that is not that bead's gate |

Rules:

- **Estimate wall time first.** If the estimate is over 60s or unknown and
  likely long, stop: mint or claim a bead, dispatch a detached worker, and
  return a dispatch receipt. Do not "just finish" the current step.
- **Hub hard bans.** The Hub never runs Vitest, `npm test`, `npm run test:*`,
  Stryker, a mutation battery, a full build, a patch-application sequence,
  generated-file regeneration, or a merge inline. It reads the worker's report
  and evidence.
- **A bead is the unit.** One bead = one verifiable outcome with acceptance
  commands, expected exit codes, branch/worktree, and a no-merge clause for
  lane workers.
- **Dispatch receipt.** Report the bead id, worker model and effort, branch and
  worktree, acceptance gates, expected exit codes, and "worker may not merge or
  deploy".
- **Default worker.** `opencode-go/deepseek-v4.1-flash` at `low` effort.
  Escalate to `high` only for complex logic, edge cases, or multi-step
  invariants, and name the reason in the receipt.
- **Drift recovery.** If the Hub notices it is already over 60s into inline
  work, stop at the next safe boundary, mint the remainder as a bead, dispatch
  it, and state what was done inline.

## Procedure

**Step 0 — Probe, then fire only what is needed.** One fast read-only pass, not
a groom:
`pwsh -NoProfile -File <package>/vendor/iqa-merge/Invoke-HubProbe.ps1 -RepoRoot <repoRoot>`
(~1s; `-Json` for scripting). It reports one line per part - `commit`, `sync`,
`reconcile`, `shared-deps`, `merge`, `hygiene`, `untracked` - as `NEEDED` /
`SKIP` / `INFO` / `BLOCKED`, each `NEEDED` line carrying the exact standalone
command that fixes it. Run only the flagged commands in the printed order, then
re-probe; `READY` means advertise immediately, a `BLOCKED` part stops the start.
The queue slug is resolved from the repository's **remote**, never from the
directory name, so probing inside `.worktrees/<lane>` still reads that repo's
queue; `-Slug` overrides it and a remote/checkout disagreement is reported.
`Invoke-RepoClean.ps1 -Complete` stays the periodic/manual deep groom (nightly,
weekly, "Repo Clean" by name) — never a per-session tax.
Detail: REFERENCE.md → `## Hub probe` and `## Repo clean`.

**Hub lifecycle** — advertise immediately at Merge invocation (lease + labels
first - REFERENCE.md → `## Hub advertise`), merge-tick each batch (reconcile →
mint → follow-ups → drain ready → close on push), final drain at Close, labels
off last; in Plan mode there is no transition — tell the user to switch to
Build mode and stop (REFERENCE.md → `## Plan-mode guard`).

**Sub handoff** — REFERENCE.md → `## Sub handoff` (freeze → enqueue
COMPLETE packet → verify row → ping → await ack → stop, report archivable).


Moved out of `SKILL.md` to keep the entry point within the
progressive-disclosure budget (120 lines); content unchanged, original order
preserved. `SKILL.md` → `## Reference` points here.

## Key cross-references

- The session procedure (three passes, session log, Validate/Close) and the
  merge-mode passes: [references/vendored/qa-procedure.md](../../references/vendored/qa-procedure.md)
  - in-package, executed as-is. Provenance (owners of the canonical text, not
  reading requirements): `Skills/iqa-beads`, `Skills/iqa-beads-saas`,
  `Skills/iqa-common`.
- Batch/lock/merge-styles/rescue mechanics: the repo profile's batch and lock
  values ([PROFILE template](../../core/PROFILE.template.md)). Provenance: the
  reference deployment's `currents-bookkeeping/Skills/hub-mode/REFERENCE.md`
  owns the CBK mechanics; a session running in this package reads its profile,
  never that file.
- Merge landing proof: `## Merge landing proof` above, with the vendored
  [vendor/iqa-merge/Test-Landed.ps1](../../vendor/iqa-merge/Test-Landed.ps1).
- Detached dispatch + capacity gate: [members/dispatch](../dispatch/SKILL.md),
  with the vendored closure under [vendor/dispatch/](../../vendor/dispatch) and
  [vendor/agent-spawn-capacity/](../../vendor/agent-spawn-capacity). The canonical
  prose stays with `Skills/paseo-child-agents` and
  `Skills/agent-spawn-capacity` as provenance.
- Lease: `../git-operations/Invoke-TrunkMergeLock.ps1` (trunk, canonical owner)
  and the vendored [vendor/git-operations/Invoke-WorktreeLease.ps1](../../vendor/git-operations/Invoke-WorktreeLease.ps1)
  (checkout).

## Changelog

- v19 (2026-11-03): **the effective cadence is era-windowed and run-duration
  floored, and `-AcceptEffectiveCadence` works in both directions**
  (cl-common-q64). A rung deliberately armed at `*/10` was RECREATEd to `*/4`
  on every tick because `Measure-EffectiveCadence` medianed the gaps across the
  WHOLE history: the retired `*/2` era (median 4.0 min over 139 gaps) outvoted
  the current regime (last 25-40 fires deliver 10 min) and never converged, so
  the verdict named a gear that 7-minute runs make undeliverable. The same
  history also showed `-AcceptEffectiveCadence` was consulted only on the
  armed-FASTER branch, so an accepted-but-slower rung could only be cleared by
  overriding the RECREATE by hand. Both cadence and run duration are now
  measured over the most recent **40** qualifying fires, `SatisfiableMinutes`
  is floored at `ceil(median run duration)`, and the switch holds a
  deliberately coarser rung while a genuinely too-slow one still recreates at
  the era gear. Measured: `hub-tick-runs.json`, 141 fires, all-history median
  4 min → last-40 median 10 min, median run 6.4 min. New JSON fields
  `EffectiveWindowFires`, `EffectiveTotalFires`, `MedianRunMinutes`,
  `RunDurationSamples`, `RunDurationFloorMinutes`. Pinned by
  `Tests/Get-HubCadence.Tests.ps1` § era window and run-duration floor
  (4 tests, proven red against the pre-fix helper).

- v18 (2026-11-03): **an instant with no offset is refused, never assumed UTC**
  (cl-common-gct). The end-of-turn tick takes an instant (`-NextFireAt`), and a
  string carrying a `Z` or an offset was read correctly — but a string with
  neither was padded with `AssumeUniversal`, so the same call the contract
  prescribes answered confidently from the wrong side of the time zone.
  Measured back to back on one rung at 09:04 local: `'2026-11-03T16:02:00Z'`
  HOLD (fires in -0.1 min), `'2026-11-03T09:02:00-07:00'` HOLD (fires in -0.1
  min), `'2026-11-03T09:02:00'` RECREATE (**overdue by 420.1 min**). A value
  that carries no offset — an offset-less string, a Kind=Unspecified
  `[datetime]`, or a run-history `scheduledFor` — is now a NAMED error
  (`NextFireAt '...' has no offset; pass a Z or an explicit offset`; a history
  row is a non-zero `CANNOT-EVALUATE`), so a guessed instant can never be
  printed as a verdict. Kind Utc/Local are still taken as stated, so the
  cl-common-0yn fix is intact. This section now tells the tick to pass the
  record's raw `nextRunAt` with its `Z` intact, and the watch-list rule is
  explicit that the America/Vancouver conversion is display-only. Pinned by
  `Tests/Get-HubCadence.Tests.ps1` (55 tests: the measured triple, the
  Z-equals-offset property over four instants, and the named refusals).

- v17 (2026-11-03): **`peer-hub` - the ladder state for "a live peer Hub owns
  this repo".** D4: the ladder accepted `prompt | dispatched | healthy | blocked |
  stand-down`, where stand-down means zero actionable work. A gate run sat on 60
  ready beads that a live peer Hub held, so every value misdescribed the truth and
  the line was printed under `blocked`. The new state is advertised - a fresh
  registry record, or the corroborated triple - and holds this repo's drain. Its
  required gear is a **15-minute liveness re-check, not a drain tick**: the
  registry's own freshness window, 7.5x the peer's 2-minute `healthy` gear, so it
  notices a terminal peer inside one window without duplicating its ticks. It
  prints `Rung: none (peer-hub: <peer-agent-short-id> owns <repo>)`, is never a
  stand-down, and never deletes the standing heartbeat or the `hub-watch-<repo>`
  backstop; all three terminal signals (no fresh record, session not running,
  lease released) turn it into `dispatched`. New
  `## Peer Hub (a live Hub already holds this repo)` carries the three reads and
  the rule that a registry `dead` is **not** a no-Hub verdict by itself.
  **The helper gap this opened was closed by the integration lane** (same day):
  `Get-HubCadence.ps1 -State` now accepts
  `prompt|dispatched|healthy|blocked|peer-hub|stand-down`, and `peer-hub` returns
  the 15-minute liveness rung. A `peer-hub` turn prints the ladder's drain line
  (`Rung: none (peer-hub: ...)`) with the helper's `required 15 min` rung as its
  backstop; substituting `blocked` (or any other value) would print exactly the
  false gear this state exists to remove.

- v16 (2026-11-03): **the 1-minute `dispatched` gear was a mistake** (operator
  decision). `Get-HubCadence.ps1` mapped `dispatched` to 1 min while the live
  Hub heartbeat runs every 2 min, so every tick printed a `HOLD`/`RECREATE`
  line asserting a gear the deployment never met. Lane and worker completion is
  delivered by push ping, not by polling, so a 1-minute tick bought nothing and
  cost a model turn every minute. `dispatched` now shares the **2 min** healthy
  gear (a backstop for a missed ping); `prompt` stays 1 min, including the
  10-minute prompt floor. Ladder table and helper comment updated; pinned by
  `Tests/Get-HubCadence.Tests.ps1` (20 tests, incl. a 2-minute heartbeat ⇒
  `HOLD` for `dispatched`).

- v15 (2026-11-02): **a proven landing is not the end of the merge lifecycle.**
  Landing proof licenses closing the merge bead; it does not license sweeping the
  worker. New `## Merge landing proof` → `### A proven landing closes the bead —
  it does not sweep the worker`: sweep (worktree + branch) only once the owning
  worker is terminal — completion ping, or ping-timeout with the worker
  idle/parked and its done-file present — and never a running agent, however
  proven the landing. Worked example: a Hub swept the merge worktree and branch
  mid-report, and the worker had to relocate to a second worktree/branch, leaving
  a second branch and a moved trunk to reconcile (recovery: prove the relocated
  branch an ancestor, reconcile, then sweep).

- v14 (2026-11-01): **wave continuity + grill-after-recon.** An approved epic is
  approved for its whole queue: the Hub dispatches the next wave in the same turn
  a wave lands and never asks "shall I continue?" - the only stops are a named
  operator exception, an unfixable red gate, a missing credential, or an
  irreversible operator-gated act. And when the instruction is "complete this
  epic / all these beads", the Hub recons first and then grills the operator in
  grill-me batch rounds before dispatching, recording every answer as a decision
  on the bead. Operator order, 2026-11-01.

- v13 (2026-10-30): **end-of-turn rung check** - every Hub turn (prompt
  reply included) now closes with `Get-HubCadence.ps1` and its printed `Rung:`
  line. The helper is the deterministic gear gate: prompt ⇒ 1 min, dispatched ⇒
  2 min (v16), a prompt floors the gear at 1 min for 10 min, healthy ⇒ 2,
  blocked walks 5/15/60 by quiet rounds, stand-down lapses; a held rung that
  fires later than the gear, is overdue, or cannot cover two fires is
  RECREATEd in the same turn. Pinned by `Tests/Get-HubCadence.Tests.ps1`
  (20 tests).
- v13 (2026-11-01): **hub discovery stops depending on a label scan.** A CBK
  Sub concluded "no Hub" while a live Hub-CBK sat idle: `paseo_list_agents`
  without `cwd` returns only the caller's workspace, *and* that Hub had never
  set its labels — either failure loses the handoff, and together they sent the
  Sub to spawn a duplicate Hub. New `HubRegistry.ps1`
  (`Register`/`Heartbeat`/`Clear`/`Find`/`List`, pinned by
  `Tests/HubRegistry.Tests.ps1`, 15 tests) writes
  `~/.salmon/State/hubs/<repo>.json` naming the **agent id** and **machine**
  with a heartbeat stamp; `## Sub lookup` reads it first (step 0) and the
  `paseo_list_agents` fallback now mandates `cwd`. The Hub start contract grows
  to five receipts (registry record added) and the advertise checklist requires
  all three legs.
  **Two failure modes recorded, not just a feature added.** (a) *Advertise was
  the skipped step.* The Hub role itself skipped label-setting — the rule was in
  the skill and went unexercised — which is why "no labels" is now a missing
  receipt rather than a style nit. (b) *Stale read as dead.* A liveness window
  shorter than a real work block turns a busy Hub into a "dead" one and
  reproduces the same duplicate-Hub failure one level down, so `Find` is
  three-state (`live` 0 / `unknown` 3 / `dead` 1) and a Hub can declare
  `-BusyMinutes` before blocking. Only `dead` justifies acting as if no Hub
  exists.
- v13.1 (2026-11-01): **a landing is proven against the remote, not the
  checkout.** Same night, a Hub reported `copy/pass-2` landed at `e828d45bf`
  with "all three keys PRESENT" — the merge commit existed only in the shared
  trunk checkout, the push never happened, and `origin/dev` was two commits
  behind; the queue row was still `queued`. Third failure of one shape that
  night (name-grep for a GIFI table, a local code table, a local `git log`):
  trusting an available signal instead of the authoritative one. New
  `Test-Landed.ps1` fetches and asserts remote-ref resolution + ancestry +
  claimed paths present in the remote tree, exit 0/1/2 with the failing check
  named; pinned by `Tests/Test-Landed.Tests.ps1` (6 tests, real bare remote +
  two clones, including the unpushed-merge defect itself). `## Merge landing
  proof` is the runbook; marking a row `merged` from a local `git log` is now a
  red line.
- v13.2 (2026-11-01): **the registry holds a SET of hubs, and a busy window
  cannot manufacture its own death.** Two defects found live by Hub-CBK, both
  in v13's own code. (a) *Single-slot, last-writer-wins.* The record held one
  hub per repo, so `Find` named whichever registered last while a second hub was
  landing on the same trunk — "two hubs alive" was unrepresentable, which is the
  configuration that produced the duplicate landing v13 exists to prevent.
  Schema v2 stores `hubs: [ {agentId, machine, pid, repoPath, trunk,
  registeredAt, heartbeatAt, busyUntil}, … ]`; `Register`/`Heartbeat` upsert
  only the caller's entry, `Clear` removes only the caller's, and v1 files read
  as a one-entry set. `Find` FOLDS: `live` if any entry is live, `unknown` if
  any is unknown, `dead` only when every entry is dead, and it always returns
  `hubCount` plus each entry's state so a duplicate is never silent. (b) *A
  one-shot busy window decaying mid-run.* A 60-minute declaration over a longer
  suite turned into `dead` while the suite was still running: the window is an
  explicit opt-out from heartbeating, so its edge cannot be evidence of absence.
  One grace window now follows a declared window before silence counts, and the
  runbook requires sizing the window to the block plus margin and renewing
  between blocks. `pid` is documented as diagnostic only (the writing process
  exits immediately; the Hub does not). Pinned by
  `Tests/HubRegistry.Tests.ps1` (26 tests, up from 15: two hubs coexist, fold
  live-over-dead, fold all-dead, fold unknown, busy-window grace, dead past
  grace, clear-one-keeps-other, heartbeat-leaves-other, v1 backward read).
- v13.3 (2026-11-01): **a stale checkout serves old helper semantics, and a
  stale writer can downgrade a record.** Found by Hub-CBK during acceptance: it
  ran "the shipped helper" by absolute path out of the cl-common main checkout,
  which was 6 commits behind, and the v1 file there silently wrote a
  `schemaVersion: 1` record — once v2 sets exist, that collapses two hubs back
  to one. Data loss, not staleness, and invisible from the caller's side.
  Three responses, none of which is "documented as a caveat": (a) `Find`/`List`
  now emit `schemaVersion` plus `schemaVersionOutdated` and a note when the file
  predates the helper, so a stale writer is visible in the output instead of
  inferred; (b) every writer refuses (exit 2) to write over a record whose
  `schemaVersion` is NEWER than it knows — the guard whichever helper is older
  can actually honour; (c) `Invoke-HubProbe.ps1` gains a `helpers` part that
  fires NEEDED when this checkout's `Skills/` differs from `origin/<trunk>`, so
  a hub is told before it uses a helper, not after. The v1→v2 direction was
  already safe and is now pinned by a test: a v2 helper folds the v1 entry into
  the set rather than replacing it. Pinned by 29 registry tests and 16 probe
  tests (69 across the skill's four files).
- v12 (2026-10-30): **Hub start contract** — assuming the Hub role now needs
  four printed receipts in one turn (lease `Live: true`, labels + self-lookup
  verdict, the `paseo_create_heartbeat` tool result, and a visible
  `hub-watch-<repo>` `new-agent` backstop in `paseo_list_schedules`), plus a
  closing `Rung:` line on every turn that leaves work outstanding. Heartbeats
  have no list surface, so the schedule is the auditable wake-up; no receipts
  ⇒ the role is not assumed. Detail: `## Hub start contract`.
- v11 (2026-10-28): **beads is the Hub backlog.** New `## Hub backlog` (ready
  work is `bd ready`/`bd list` in the repo graph; salmon-run `Tasks/` trees are
  legacy migration input, merge-queue rows unchanged); skill-update fan-out
  points at a follow-up bead and calls the salmon-run side a durable handoff
  record; pointer convergence no longer names the retired Intake queue.
- v1 (2026-10-18): new skill (skill-template v1): Hub/Sub synonyms, `hub-*`
  labels, Sub forwarder + park-and-alert, merge-worker exception, oldest-wins; mechanics by reference.
- v2 (2026-10-20): stable front door. Full IQA-Beads-SaaS session path +
  role router (session / hub / sub); Hub labels table moved to REFERENCE.md;
  `IQA Merge Mode`/`IQA-Merge Mode` (+ case variants) triggers; stale nested
  `iqa-mode` duplicates in `cl-audit`/`cl-product` retired to pointers.
- v3 (2026-10-20): always-Hub (every Merge invocation wears Hub labels) +
  queued Sub packet (complete `--note`, verify row, wake-up-only ping,
  Hub acks by row mark, Sub stops on ack — unacked never archives).
- v4 (2026-10-20): Plan-mode guard — Plan mode performs no transition (no
  advertise/tick/dispatch/merge/deploy); tell the user to switch to Build mode and stop. Detail: REFERENCE.md → `## Plan-mode guard`.
- v5 (2026-10-21): watch-list format — one line per timer, times in
  America/Vancouver, repeats compressed as first-fire + `[repeats <cadence>
  x <remaining>]`, clockless items as `on completion - <desc> (<bead>)`.
- v6 (2026-10-21): Hub heartbeat — self-wake `*/15` merge-tick (outbox
  drain, coverage invariant, lease refresh, STAND-DOWN stop); every
  dispatch carries same-turn wake-up coverage. Closes the 70-minute idle
  stall class.
- v7 (2026-10-22): Step 0 Hub preflight — `Invoke-HubPreflight.ps1` reconciles
  the merge queue, folds temp branches (TrunkPrep) and runs branch/worktree
  hygiene before advertising; `Hub Preflight` / `Tidy + Merge + Hygiene`
  triggers; `Tests/` pins dry-run default and the blocked envelope.
- v8 (2026-10-23): renamed **Repo Clean** (`Invoke-RepoClean.ps1`; `Hub
  Preflight`/`Tidy + Merge + Hygiene` kept as synonyms) with the completion
  contract: `-Complete` commits pending tracked work, cherry-picks branches a
  merge cannot take whole (TrunkPrep `-OnConflict CherryPick`), retires
  patch-equivalent branches (hygiene `-IncludePatchEquivalent`), and enforces
  an end-state check (clean tree, remotes equal, every surviving branch
  accounted for). Per-remote push and content-loss warnings come from
  TrunkPrep. Tests cover dry run, dirty/non-trunk blocks, `-Complete` on a
  dirty tree, and a kept-out conflicted branch.
- v9 (2026-10-23): **Hub probe** replaces the unconditional session-start
  Repo Clean. `Invoke-HubProbe.ps1` is a ~1s read-only pass reporting each
  grooming part (`commit`, `sync`, `reconcile`, `shared-deps`, `merge`,
  `hygiene`, `untracked`) as NEEDED/SKIP/INFO/BLOCKED with the exact standalone
  command to run; the Hub fires only what is flagged and advertises on `READY`.
  Repo Clean is now the periodic/manual deep groom. Tests:
  `Tests/Invoke-HubProbe.Tests.ps1` (12 verdict cases, four of them identity).
- v10 (2026-10-28): **adaptive probe** replaces the flat `*/15` heartbeat.
  Each fire self-reschedules first (`maxRuns: 1`) at a gear chosen by the last
  probe — 1 min when a lane was just dispatched or needs attention, 2 min
  while all lanes are healthy, 5/15/hourly only when nothing runs and every
  open bead is operator-blocked. The probe itself is one `paseo_list_agents`
  call; `bd ready` is the fallback, not the routine. Checklist gains a
  `Wake-up ladder` item.
- v11 (2026-10-30): Repo Clean absorbs Tidy phase B's merge prep. Conflicts
  **default to `-OnConflict CherryPick`** in every writing mode (`Stop` is the
  opt-out); a new `prep` step excludes lane-active branches (live worktree
  lease or dirty tracked files) from the fold and protects their worktrees via
  `Invoke-BranchWorktreeHygiene.ps1 -ProtectedWorktrees`; a `retrack` step
  re-tracks the canonical worktree; `-Build` proves the consolidated trunk
  (opt-in, `SKIPPED` unless asked). Verify counts lane-active branches as
  accounted-for. Tests: cherry-pick default, `-OnConflict Stop`, lane
  exclusion, prep reporting, protected worktree.

## Triage procedure

- **No Hub / two Hubs / stale label:** REFERENCE.md → `## Sub lookup` and
  `## No-Hub park + alert` (oldest-lease-wins; verbatim alert; durable row).

## Watch-list format

Timer/check-back reports: one line per item, America/Vancouver times, repeats compressed (detail: REFERENCE.md → `## Watch-list format`).

## Hub heartbeat (self-wake)

Self-wake `*/15` merge-tick + coverage invariant: every dispatch carries same-turn wake-up coverage (detail: REFERENCE.md → `## Hub heartbeat (self-wake)`).

## Completion

`Status: Hub draining (<n> queued, <m> ready, batch <id>)`,
`Status: Handed to <hub-label> (<agent-id>), stopped`,
`Status: No Hub — parked at <queue-path>, alerted`, or
`Status: Hub closed (drained <branches>, <n> queued, deploy <OK|FAILED>, pointers <Verify-clean|N/A>)`.

## Delegation default (operator order 2026-10-27)

The Hub executes almost nothing itself. **Beads graph first**: every item must
exist as a bead before work starts - a Hub that "just fixes it" leaves no bead,
no branch, and no evidence.

| Situation | Route |
| :--- | :--- |
| Touches any file, runs a suite, needs discovery, or could exceed a minute | Detached lane subagent, own worktree and branch |
| One file or one command, under ~60s, no suite, no merge/deploy implication | Hub may do it directly |
| Minting, claiming, closing, reviewing evidence, merging, deploying, answering | Hub owns it |

This is model-sensitive: **DeepSeek V4.1 Flash** in particular will happily do
the work itself and skip the graph, so a Hub running that model must justify any
self-execution in one line ("under 60s: one command") rather than defaulting to
it. The failure mode is concrete - work done in the Hub leaves no bead, no
branch, and no reviewable evidence, so the next session cannot tell what
happened or re-run the proof.

- v15 (2026-11-01): **standing grants** - the Hub deploys dev after every landing
  and sweeps dead refs/branches/worktrees without asking (neither is re-asked);
  prod, money, legal sign-off and destructive infrastructure stay gated. Detail:
  development-philosophy S9.
- v16 (2026-11-01): **the philosophy is in the contract, and the role has an
  on-ramp.** The Hub is where the operator's development shape is enforced, so
  `## Development philosophy (binding)` is now a first-class section of
  `SKILL.md` (MVP-before-roadmap, ship-dark flags with 404-not-403, five
  deployment proofs, evidence-not-assertion, cheapest sufficient tier, never
  invent an approval, lanes-are-leases) plus two red lines that follow from it
  (never merge a roadmap bead without its flag; never merge a "done" that is a
  status code). Reason: the rules existed in `development-philosophy` but a Hub
  could satisfy every merge gate while still shipping scope wrongly - nothing in
  this skill asked the question. New `ENROLMENT.md` is the new-Hub on-ramp
  (ordered reading, the five receipts with exact commands, first tick, dispatch
  contract, merge-and-prove path, ten traps that have already cost a Hub a
  night) because the contract was learnable only from other Hubs' failures.
  `SKILL.md` also came back inside its 120-line budget (was 156): the role table
  moved to `## Roles` here, and the long forms of wave continuity / standing
  grants remain above. `ENROLMENT.md` §8 records the recurring mechanical traps
  found in live use (terminal `Enter` events, one-shot-shell leases reading
  `Live: false`, stale-checkout helper downgrades, duplicate Hubs from a
  workspace-scoped agent list).
- v16.1 (2026-11-01, same night, after driving three waves): **the on-ramp gained
  the five failures that actually stopped work.** `ENROLMENT.md` §8 grows from 10
  to 15 traps, all observed live: a lane death is usually the provider key, not
  the work (three lanes died on `GO2`/`GO5` exhausted; triage order and the
  same-worktree recovery rule are now written down); the lease-holding terminal
  can be reaped mid-session (re-acquire and confirm `Live: true`); a
  remote-tracking ref is a local belief, never remote truth (`ls-remote` proved a
  "stale mirror" that was level); workers overwrite the root `.iqa-report.md`
  index; and a lane can merge into `dev` itself, bypassing the merge worker, the
  trunk lock and the branch assertion. Each carries the evidence that produced
  it. Also learned and now policy: brief every lane to commit early and push as
  soon as coherent, and drop to one lane while the provider pool is short - two
  lanes on one healthy key spent four workers on one bead.
- v17 (2026-11-03): **a durable dispatch is asserted, not assumed** (bead
  `cl-common-q8k`). Two live occurrences the same day: a one-shot's only run ended
  `status=failed`, `agentId=null` on `EPERM ... rename ...schedules\<id>.json.<tmp>`
  and burned the `maxRuns: 1` budget with zero work, and the same EPERM failed a
  Hub's own `paseo_update_schedule` re-arm, then the identical call succeeded four
  seconds later. `## Dispatch durability` gains rule 11 with two helpers -
  `Test-ScheduleDispatch.ps1` (one read, four verdicts, `failed-spawn` exits 1,
  `pending-fire` 3, `CANNOT-EVALUATE` 2) and `Invoke-ScheduleRecordWrite.ps1`
  (bounded retry/backoff, optional read-back verify, RETRY/STOP classifier for the
  agent-driven MCP surface). It also records that re-arm is not create: a
  `maxRuns`-exhausted `completed` record is recreated, never updated in place, and
  names the daemon-side half (atomic internal retry; a run that produced no agent
  should not consume budget) as Paseo's, out of the Hub's reach.
