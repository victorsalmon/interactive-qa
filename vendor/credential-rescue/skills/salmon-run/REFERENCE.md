# Salmon Run lane key cutover - reference

## Moved from SKILL.md

## Close out the ledger — ask, then record

The switch knows the new key; only the operator can say what the old one was
reading. Ask before reporting the cutover done:

> "What did the Console show for `GO<n>` — monthly and/or weekly usage, and the
> reset dates?"

```powershell
pwsh -File $env:CL_REPOS_ROOT\cl-common\Skills\credential-rescue\scripts\Set-OpencodeGoFreshness.ps1 `
  -KeyNumber <old> -MonthlyUsed <pct> -MonthlyResets <yyyy-MM-dd> `
  -WeeklyUsed <pct> -WeeklyResets <yyyy-MM-ddTHH:mm> `
  -Evidence 'operator Console read <date>, cutover to GO<new>'
```

Record what you were told and leave the rest alone — every meter carries its own
`observedAt`, so a monthly-only answer must not be smeared over the weekly meter.
If the answer is "fresh, I just moved for headroom", say that too: `state: fresh`
with its utilisation is a real entry and the reason the next run can trust the key.

