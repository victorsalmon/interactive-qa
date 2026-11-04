# Profile — `currents-bookkeeping`

An example filled profile, for the SaaS portal the fleet ran IQA against before
the plugin existed. It is **a worked example, not the only valid profile**: copy
[the template](../core/PROFILE.template.md), fill it for another repo, and keep
the rule text in the core and the members - a profile only resolves slots
([ADAPTERS.md](../core/ADAPTERS.md) -> `## Axis 3 — repo profile`).

No secret values and no machine paths appear here; every path resolves through
`$env:CL_REPOS_ROOT`.

## Identity

| Slot | Value |
| :--- | :--- |
| `repo` | `currents-bookkeeping` |
| `repo_root` | `$env:CL_REPOS_ROOT\currents-bookkeeping` |
| `trunk` | `dev` |
| `permanent_branches` | `main`, `dev`, `prod`, `dotCanada*` |
| `worktree_pattern` | `<repo_root>/.worktrees/<name>` |
| `branch_prefix` | `feat/`, `fix/`, `iqa2/scan-` |
| `session_log_dir` | `<repo_root>/IQA2/<date>-<iteration>.md` |
| `beads_epic` | `iqa:list=<list>` (the run's list label — no roll-up bead exists; `Merges: currents-bookkeeping/<trunk>` for merge work) |

## Axes

| Slot | Value |
| :--- | :--- |
| `executor` | `paseo` |
| `provider_pool` | `pool` |
| `pool_order` | `opencode-go` -> `opencode-zen` -> `openrouter` (Gemini disabled, Codex opt-in only) |
| `default_work_role` | `fix` (low effort) |
| `capacity_policy_ref` | `Skills/agent-spawn-capacity/` (caps, cooldowns, error log) |

## Gates

| Slot | Value |
| :--- | :--- |
| `focused_gate` | `npm run test:fe` (one affected spec), or `npm run test:backend` |
| `full_gate` | the repo `qa-suite` full run (pass 2 only) |
| `typecheck_gate` | `npm run typecheck` |
| `lint_gate` | `npm run audit` |
| `landing_test` | `Skills/iqa-merge/Test-Landed.ps1` (fresh fetch, ancestor of `origin/dev`, claimed paths in the remote tree) |
| `gate_waivers` | none in force for this profile |

## Deploy and close

| Slot | Value |
| :--- | :--- |
| `deploy_skill` | `currentsbk-local-deploy` |
| `deploy_target` | `dev` post-merge hook -> `scripts/auto-deploy-dev.ps1` (`dev-front` + `dev-back`) |
| `deploy_verify` | `Backend deploy OK` in the post-merge deploy log - never the hook's exit code, and `/api/health` plus a portal 200 and served bytes |
| `secrets_profile` | per the repo IQA adapter; `none` rather than a guess |
| `close_evidence` | the session record, the tracker tally, the closed/kept bead list, and the deploy-verify artefact |
| `merge_lock` | `$env:CL_REPOS_ROOT\cl-common\Skills\git-operations\Invoke-TrunkMergeLock.ps1 -RepoRoot <repo_root> -Trunk dev` |
| `merge_gates` | `typecheck` + `test:fe` + `test:backend` + `audit` + `verify:diag-off` (all before the lock is taken) |

## Adapter slots

| Slot | Value |
| :--- | :--- |
| `close_doc` | `IQA2/<date>-<iteration>.md` - tracker tally, planning docs, ADRs, and drift groomed before testing |
| `qa_command_surface` | `check:routes`, `check:react`, the `qa-suite` full run, property/invariant additions, new or refactored specs |
| `nightly_queue` | changed testing infra for non-stale items joins that evening's `goodnight` run |
| `export_first` | `Export-Iqa2Beads.ps1` renders the graph before the close pass starts |
| `test_focused` | `npm run test:fe` / a single affected spec / `npm run test:backend` |
| `test_full` | the full battery, pass 2 only |
| `qa_matrices` | `<repo>/docs/qa-*` matrices, reconciled `scan ∖ matrix` |
| `review_branch` | `iqa2/scan-<date>` (never `iqa/scan-<date>`), merged from the trunk worktree with `--no-ff` |
| `beads_home` | the trunk worktree's `.beads/`, initialised by `Invoke-Iqa2BeadsInit.ps1`; the `bd` version is recorded in the hand-off |
| `merge_trunk` | `dev` (the canonical folder is the trunk checkout) |
| `release_trunk` | `prod` - release-only, never an integration target |
| `close_proof` | deploy-verify from the post-merge log (`Backend deploy OK`) |
| `scripts_root` | `$env:CL_REPOS_ROOT\cl-common\Skills\iqa-merge` for the hub helpers and `...\Skills\credential-rescue\scripts` for the Key family (development override only; the in-package `vendor/` mirror is the deployment truth) |
| `seam_path` | `$env:CL_REPOS_ROOT\cl-common\Skills\credential-rescue\assets\opencode-go-cutover.json` (the machine's seam, which this box's live Key Watch reads and writes; a seam write names it, or is `cannot-evaluate`) |

## Merge mode notes

- Close runs a final merge drain first; unadvertising (labels off) comes last.
- Merge mechanics are repo-local and followed, never copied:
  `<repo>/Skills/hub-mode/REFERENCE.md` and
  `$env:CL_REPOS_ROOT\cl-common\Skills\git-operations\SKILL.md`.
- A non-SaaS repo riding the same session (`cl-common` here) gets its own slot
  block: trunk `dev`, `prod` release-only, no deploy, and a close proof of
  Harness Install `-Verify` plus `-VerifyLock` clean.
