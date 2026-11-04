---
name: salmon-run
description: Runbook — Salmon-track opencode-go key cutover for Salmon Run lanes (Switch-OpencodeGoKey.ps1: User env + auth.json + defaultCodingKey, hygiene, canary). This is the **second** track: the Paseo surface is replaced first and in full (Repair-Paseo.ps1), and the Salmon cutover runs only after the operator approves the other surfaces. Owns the cutover seam, the defaultCodingKey front-of-pool rule, and lane verification. Use when a lane or CLI dies on "Weekly usage limit reached" / "Go usage limit exceeded", or when the operator names an exhausted pool key and a fresh one.
triggers:
  - user
  - model
---

# Runbook — Salmon Run lane key cutover

Salmon Run lanes read the opencode-go pool from the Machine env vars plus
`~/.machine/config.json`. A cutover is a **one-file seam edit** projected onto
every lane surface. Paseo is a *different* consumer — see the `paseo-rescue` runbook.

**Never print a secret value.** Key NAMES only. Every change logs one JSON line
to `$env:USERPROFILE\.machine\logs\credential-changes.jsonl` (the script does it).

## Quick start

> **Ordering rule: Paseo first, then ask.** The default rescue replaces the
> **Paseo surface completely first** (`Repair-Paseo.ps1 -KeyNumber <n>`), and
> only then asks the operator whether to run the Salmon cutover below. Never
> fan the cutover across every consumer unasked.

```powershell
# step 1 (default): replace the Paseo surface in full, then verify both harnesses
pwsh -File $env:CL_REPOS_ROOT\cl-common\Skills\credential-rescue\scripts\Repair-Paseo.ps1 -KeyNumber 5

# step 2 (only after the operator approves the other surfaces): Salmon-track cutover
# preview, then swap (KeyNumber is the pool index 1-5)
pwsh -File $env:CL_REPOS_ROOT\cl-common\Skills\credential-rescue\scripts\Switch-OpencodeGoKey.ps1 -KeyNumber 5 -DryRun
pwsh -File $env:CL_REPOS_ROOT\cl-common\Skills\credential-rescue\scripts\Switch-OpencodeGoKey.ps1 -KeyNumber 5
```

`-KeyNumber` selects `OPENCODE_GO<n>_KEY` from Machine scope, falling back to
User scope when the Machine value is absent (a key staged without the elevation
prompt Machine scope needs); the operator never hands you the value. The script
is the only writer of the seam and of `~/.machine/config.json`.

## The seam

`assets/opencode-go-cutover.json` owns `activeKey`, `poolOrder`,
`keyMaxConcurrent`, `providerMaxConcurrent`, the canary set, and the hygiene
policy. It is CONFIG ONLY: the per-key freshness observations live at the seam's
`observationsPath` in the profile state root
(`$HOME/.machine/state/credential-rescue/seam-observations.json`), so a watch
cycle never dirties the tracked/vendored seam. `Switch-OpencodeGoKey.ps1`
projects the config onto the User env
(`OPENCODE_GO_KEY` + `OPENCODE_API_KEY`), `auth.json`, and
`~/.machine/config.json` (`execution.defaultCodingKey` + the caps), then writes
`activeKey` back so the seam and reality never drift.

## `defaultCodingKey` is not advisory

`Get-OpencodeDefaultCodingKey` feeds it to `Get-OpencodeKeyPriority -DefaultKey`,
which moves the named key to the **front** of the pool order. Left on an
exhausted key, every lane tries that key first and dies before reaching the
fresh one (the 2026-10-15 incident). Repointing the env without setting
`defaultCodingKey` fixes nothing — the script does both.

## Spillover invariant

The active key is first in pool order, so a lane reaches a lower-priority key
only when the provider cap exceeds the active key's per-key cap. Keep
`providerMaxConcurrent['opencode-go'] == keyMaxConcurrent[activeKey]` and only
the active key is used, even with all five keys still in the pool. The script
warns when they diverge.

## What the switch does, in order

Model pre-check (name / endpoint / transport) → repoint User env + `auth.json`
→ project `~/.machine/config.json` → write `activeKey` to the seam → session
hygiene (count first; strip only if poisoned) → one canary → credential log.

Then, as a separate step **the operator approves**, re-point the Salmon surfaces;
the Paseo surface never waits on it:

```powershell
pwsh -File $env:CL_REPOS_ROOT\cl-common\Skills\credential-rescue\scripts\Switch-OpencodeGoKey.ps1 -KeyNumber 5
```

This script never touches `~/.paseo/config.json` — the pin + restart live in
`Repair-Paseo.ps1` only (composition, not duplication).

**Flags.** `-Full` uses the wider canary set (adds `deepseek-v4.1-flash`, which
currently times out on this box — a model-transport defect, not a credential —
and costs ~3 min). `-SkipHygiene` skips the reasoning strip. `-SkipCanary` only
when the CLI is unavailable. `-RetirePoolKey <n>` clears a dead pool key's
Machine var so the pool stops resolving it. `-PaseoOnly` is deprecated (forwards
to `Repair-Paseo.ps1`); `-RestartPaseo` delegates to it after the cutover.

## Classify a failure before acting

| Message | Class | Action |
| :--- | :--- | :--- |
| `Weekly usage limit reached. Resets in N days` | key exhaustion | cut over to a fresh key |
| `encrypted_content … not issued to this caller` | model-transport | session hygiene — see `interactive-qa/vendor/credential-rescue/REFERENCE.md` § Runbook A |
| `An active OpenCode Go subscription is required` | NOT-SUBSCRIBED (account) | operator renews; repointing changes nothing |

## Verify the lanes

After the swap, a lane should resolve without a quota error. The pool consumes
highest-index-first, so `defaultCodingKey` is what pins the active key to the
front. Confirm the runtime config took:

```powershell
(Get-Content "$env:USERPROFILE\.machine\config.json" -Raw | ConvertFrom-Json).execution.defaultCodingKey
```

## Reference

- Shared facts, safe reads, and the long-form cutover: `interactive-qa/vendor/credential-rescue/REFERENCE.md` § Runbook A
  (the `Skills/credential-rescue/REFERENCE.md` body is archived — see `Skills/_archive/iqa-superseded-2026-11-03/`)
- Paseo consumer: [../paseo-rescue/SKILL.md](../paseo-rescue/SKILL.md)
- Unattended watch: [../watch/SKILL.md](../watch/SKILL.md)
- Moved from SKILL.md: `## Close out the ledger — ask, then record` — see [REFERENCE.md](REFERENCE.md) → `## Moved from SKILL.md`
