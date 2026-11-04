---
name: aws-store
description: Runbook — restore the ~/.aws credential store after one of the recurring external-cleanup deletions, and reseed its off-.aws backup. Owns the restore source order, the Restore-AwsStore.ps1 modes (Status/Restore/Verify/Backup), and the touched-file inventory. Use when ~/.aws (or another ~/.*/ folder) has vanished, when AWS CLI calls suddenly fail with NoCredentialProviders, or before rotating IAM keys.
triggers:
  - user
  - model
---

# Runbook — restore `~/.aws` after deletion

A recurring external cleaner wipes `~/.aws` (and sometimes other `~/.*/`
folders). Backups live **under `~/.salmon`, never inside `~/.aws`** — the cleaner
removes the whole `.aws` dir including its `backups/`.

**Never print a secret value.** Profile NAMES and ARNs only.

## Quick start

```powershell
$s = '$env:CL_REPOS_ROOT\cl-common\Skills\credential-rescue\scripts\Restore-AwsStore.ps1'
pwsh -File $s -Mode Status                 # inspect: what is present/missing
pwsh -File $s -Mode Restore -FromSessionDb # rebuild from the best source
pwsh -File $s -Mode Verify                 # prove it (names + caller ARNs only)
pwsh -File $s -Mode Backup                 # reseed the off-.aws snapshot
```

## Restore source order

1. The **operator's restore bundle** — untracked from the tree by `ca236ac6`
   and absent here; the script skips what it cannot find (`-SkipRepoZip` to skip
   it explicitly). Confirm the operator's copy before planning around it.
2. `~/.salmon/Backups/aws-store/latest`.
3. Newest `.enc` backup (AES-256, key = `AWS_CRED_BACKUP_KEY` in `~/.salmon/.env`).
4. `-CredentialsFile <path>`.
5. Session-DB scrape (Devin `cli/sessions.db`; opencode `opencode.db` under the
   live `$env:XDG_DATA_HOME\opencode`).
6. `config` template + operator-pasted `credentials`.

If nothing is recoverable: the operator creates fresh IAM keys in the console
(agents never create keys), then `-CredentialsFile` or direct paste, then
`-Mode Backup`, and rotate per `salmon-run/secret-rotation-policy.json`.

## The operator bundle

`restore.zip` (the encrypted `.aws` snapshot) and `restore.txt` (its password)
were **untracked from the tree** by `ca236ac6` and are absent here — they are
operator-held, so confirm the operator's copy before planning a restore around
them. **Never print, quote, or copy their contents** into logs, chat, memory, or
commits.

Local backup state right now: `~/.salmon/Backups/aws-store` is **absent**, so run
`-Mode Backup` after any successful restore — that reseed is what makes the next
deletion a file-copy restore instead of a scrape.

## What is in `~/.aws`

| File | Contents | Secret? |
| :-- | :-- | :-- |
| `config` | profile metadata only (regions, SSO) — rebuildable | no |
| `credentials` | `[dev-daily-fixed]`, `[currentsSetup]` IAM key pairs | **yes** |
| `cli/cache/`, `sso/cache/` | regenerates | no |
| `backups/` | deleted with the dir — do NOT rely on it | — |

Profiles: `dev-daily-fixed` (default, read-only agents), `currentsSetup`,
`salmon-sso` (Identity Center, `aws sso login --profile salmon-sso --use-device-code`).

## Same-cleanup class

The cleaner also wipes `~/.config` — Devin's global skill pointers there are
one-line redirect files, recreated by the harness installer. Any `~/.*/` folder
vanishing is this incident class: restore, do not "remediate" (never delete or
clean a `~/.*/` credential folder).

## Reference

- Templates, the full source order, and the bundle rules: `interactive-qa-agent/vendor/credential-rescue/REFERENCE.md` § Runbook B
  (the `Skills/credential-rescue/REFERENCE.md` body is archived — see `Skills/_archive/iqa-superseded-2026-11-03/`)
- AWS CLI ops (profiles, Secrets Manager reads, SSO): the `aws` skill
