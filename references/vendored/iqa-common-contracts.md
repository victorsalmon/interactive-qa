# Vendored: iqa-common contracts

> **Vendored snapshot — provenance.** Source: `Skills/iqa-common/REFERENCE.md`
> in the cl-common repository at commit `29e4d6e7` (2026-11-03).
> Two normative sections are reproduced here verbatim so this package resolves
> them without reaching outside its own root:
>
> - `### Completion report contract (normative)` — `members/dispatch` Rule 3
> - `## Session-log contract (user-gated validation)` — `members/iqa-hub` session log
>
> The source file remains the owner. When it changes, re-vendor this snapshot in
> the same change; a divergence between the two is a defect in this file, never a
> licence to edit the text here.

---

### Completion report contract (normative)

Every lane ends the same way, because a report nobody can check is a claim:

- **The last action is a foreground gate run (rule 8).** The worker's final
  command is the repo's gate, run in the foreground, with its exit code captured
  — never "gates should pass", never a background job it did not wait on. A
  report whose last action is a commit has no evidence in it.
- **Fixed shape, ~40 lines (rule 8).** Verdict line, a gate table (gate ·
  command · exit code), then what is unproven. Forty lines is the cap: a report
  that needs more is either a second report or an admission that the gate did
  not run.
- **Command output only (rule 9).** Every SHA, count, score, and gate result in
  the report must be text the worker captured from a command in this lane.
  Never a SHA from memory, never a re-quoted header, never a green carried
  forward from the brief. If it was not captured, it is unproven and belongs in
  that column.
- **Counts + files + evidence path (rule 2's payload).** A bare "finished" is a
  stall: the lane names the files it touched and the path of the report it wrote.

---

## Session-log contract (user-gated validation)

Every session writes one log file per session in the target repo (location is
mode-specific: `<repo>/IQA/` for `iqa-mode`, `<repo>/IQA2/` for `iqa-beads`).
Required per-issue fields:

1. **Issue ID** — the item's ID in its list (never renumber user items).
2. **Issue in the user's words** — verbatim or near-verbatim report.
3. **What was done** — hotfix commit(s) + deploy ref(s) + deep-plan ref,
   or "no fix yet / deep-only, testing around it".
4. **User status** — one of `open`, `fix live, awaiting validation`,
   `validated resolved` (user explicitly confirmed), or `deferred` with
   the user's reason. The agent never flips an issue to resolved on the
   user's behalf.

Resolution rule: **until the testing user specifically says an issue is
resolved, it is not resolved** — a shipped fix only moves it to `fix
live, awaiting validation`. After the user validates, record it as
`validated resolved` with the validation note (what they re-tested).

The review branch lives in the **target repo** and is merged into the trunk by
the interactive session in pass 1 — the branch is the review unit, not the
delivery vehicle. Branch prefixes are mode-specific (`iqa/` vs `iqa2/`).

