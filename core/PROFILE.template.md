# Profile template

Copy this file to `<repo-profile>.md`, fill every slot, delete the guidance.
The schema is promoted from the adapter-slots table that
`Skills/iqa-beads-saas/SKILL.md` uses today, generalised so a non-SaaS repo can
fill it too. Read [ADAPTERS.md](ADAPTERS.md) first — this file only resolves the
slots it defines.

Every slot is **required**. Write `none — <reason>` rather than leaving a slot
blank or guessing a value: a guessed slot fails the same way a broken one does,
and is harder to spot.

## Identity

| Slot | Value |
| :--- | :--- |
| `repo` | repository name |
| `repo_root` | how a session resolves the checkout (env var expression, never a machine path) |
| `trunk` | the integration branch |
| `permanent_branches` | branches that are never swept |
| `worktree_pattern` | where a lane worktree is created |
| `branch_prefix` | prefix for session and scan branches |
| `session_log_dir` | where committed session history lives |
| `beads_epic` | the label that identifies this repo's QA run (`iqa:list=<list>`), or `none — <reason>` |

## Axes

| Slot | Value |
| :--- | :--- |
| `executor` | `paseo` \| `generic` |
| `provider_pool` | `pool` \| `single key` |
| `pool_order` | ordered destinations, or `none` |
| `default_work_role` | the role a fresh dispatch assumes |
| `capacity_policy_ref` | where per-key caps and cooldowns are owned |

## Gates

| Slot | Value |
| :--- | :--- |
| `focused_gate` | the command that proves one change |
| `full_gate` | the command that proves the whole suite |
| `typecheck_gate` | or `none — <reason>` |
| `lint_gate` | or `none — <reason>` |
| `landing_test` | the command that proves a landing on the trunk |
| `gate_waivers` | named waivers in force, each with its reason and owner |

## Deploy and close

| Slot | Value |
| :--- | :--- |
| `deploy_skill` | the skill that owns deployment |
| `deploy_verify` | the evidence that a deploy took effect (never an exit code) |
| `secrets_profile` | the profile name used for this repo's API calls |
| `close_evidence` | what the session must show before it may close |
| `merge_lock` | the lock command, or `none — <reason>` |
| `merge_gates` | gates that run before the trunk lock is taken |

## Adapter slots a repo must resolve

The three axes in [ADAPTERS.md](ADAPTERS.md) resolve into the slots below. They
are lifted from the SaaS adapter the fleet ran before the plugin existed, and
generalised so a non-SaaS repo fills the same shape. Every slot is required; a
slot with no value is `none — <reason>`.

| Slot | What it resolves |
| :--- | :--- |
| `close_doc` | where the close pass writes its session record (path pattern + tally) |
| `qa_command_surface` | the repo's QA entry points (route/react checks, suite run, spec dirs) |
| `nightly_queue` | how a non-stale testing item reaches the nightly run, or `none` |
| `export_first` | the export step that renders the graph before the close pass, or `none` |
| `deploy_skill` | the skill or runbook that owns deployment for this repo |
| `deploy_target` | what a deploy actually changes, and where its log is read from |
| `deploy_verify` | the artefact or log line that proves the deploy took effect |
| `test_focused` / `test_full` | one affected spec / the full battery (pass 2 only) |
| `secrets_profile` | the exact profile name for this repo's API calls |
| `qa_matrices` | the QA docs imported, and the `scan ∖ matrix` reconciliation |
| `review_branch` | the reconstruction/scan branch pattern, and the merge convention |
| `beads_home` | where the session's `.beads/` lives and how it is initialised |
| `merge_trunk` / `merge_lock` / `merge_gates` | the trunk that integrates, the lock command, and the gates that run **before** the lock is taken |
| `release_trunk` | a release-only branch that is never an integration target, or `none` |
| `close_proof` | what a non-deploying repo shows instead of a deploy (pointer + gate verification) |
| `scripts_root` | where the member's helper scripts resolve from: the in-package `vendor/` mirror by default (a helper sits at `<scripts_root>/<skill>/<name>.ps1`, and the vendored copy is the deployment truth); a profile names the fleet path only as a development override |
| `seam_path` | the machine's credential seam (`opencode-go-cutover.json`) that a **write** must be given, or `none`. A read may use the in-package `vendor/credential-rescue/assets/` snapshot; with `none`, any command that writes the seam is `cannot-evaluate` |

A filled example lives at
[`profiles/currents-bookkeeping.md`](../profiles/currents-bookkeeping.md).

## Slot rules

- **`trunk` and `permanent_branches` are read, not inferred.** A profile that
  says "the usual trunk" is unfilled.
- **`landing_test` is executable.** If no runnable landing test exists, the slot
  says `none — <reason>` and the member records a `cannot-evaluate`; it never
  falls back to "the worker said it pushed" (Invariant 1).
- **`deploy_verify` names an artefact**, not a command's exit status — the
  deploy hook's exit code is famously not the deploy result.
- **`secrets_profile` is exact.** A wrong profile presents as a provisioning
  failure, so an approximate value costs more than `none`.
- **No prose in a filled slot.** If a slot needs an explanation, the explanation
  belongs in the owning member or in [INVARIANTS.md](INVARIANTS.md); the profile
  carries the value and a link.
- **No absolute machine paths anywhere in a profile.** Resolve through the
  environment, so a published copy stays valid.
