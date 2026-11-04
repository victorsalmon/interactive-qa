# Seam projection defect — GO5 → GO4 cutover (2026-10-16)

Recorded during the GO5 → GO4 rescue. Restored-work discovery, verified live.

## The defect (found in the restored Switch-OpencodeGoKey.ps1)

The Salmon-track seam projection wrote `execution.defaultCodingKey` from
**`$seam.activeKey`** — but `activeKey` is only updated to the cutover target
*after* the projection block. On a real cutover where the seam is stale
relative to the target (the normal case), the two disagree:

- env + `auth.json` → GO4 (correct)
- `~/.salmon/config.json execution.defaultCodingKey` → **OPENCODE_GO5_KEY** (old)

That re-creates the 2026-10-15 incident the block's own comment warns about:
`defaultCodingKey` moves the named key to the front of the lane pool order, so
every spawned lane prefers the retired key first and dies before reaching the
fresh one.

## The tell

The dry run prints the disagreement before any credential is touched:

```
dry-run: would repoint OPENCODE_GO_KEY, OPENCODE_API_KEY, auth.json opencode-go -> OPENCODE_GO4_KEY
dry-run: would set ~/.salmon/config.json execution.defaultCodingKey -> OPENCODE_GO5_KEY
```

Any dry run whose `defaultCodingKey` label does not equal its repoint target is
a defect in the writer, not a plan to execute. **Read the dry run before a live
cutover; the pre-check is the guard.**

## The fix (shipped)

The projection block now projects from `$targetName` (the cutover target), and
the seam write-back still persists `activeKey` afterwards, so the seam and
`~/.salmon/config.json` agree once the swap completes.

## Verified rescue (GO5 → GO4, same date)

| Surface | Before | After |
| :--- | :--- | :--- |
| User env `OPENCODE_GO_KEY` / `OPENCODE_API_KEY` | GO5 | GO4 |
| `auth.json` `opencode-go` | GO5 | GO4 |
| `~/.salmon/config.json` `defaultCodingKey` | GO5 | GO4 |
| seam `activeKey` | GO5 | GO4 |
| `~/.paseo/config.json` opencode pin | GO5 | GO4 |
| DSH `apiKeyEnv` | OPENCODE_GO5_KEY | OPENCODE_GO4_KEY |

Session hygiene (seam mode `auto`) stripped 12,540 account-bound reasoning
parts (0 remaining; backup under `%TEMP%`). Post-cutover canaries: CLI
`muse-spark-1.3-contributor --variant high` PASS, DSH `dsh-key: OK`, and a live
Paseo helper message probe returned a real assistant reply with non-zero cost —
the verify-only probe of `session.create` alone does NOT prove a working key.
