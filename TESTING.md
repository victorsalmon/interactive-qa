# Testing locally

Everything here runs on one machine with **`pwsh` 7+**, **`git`**, and - for the
monitor's snapshot mode - **`bd`** (beads) and a repo that has a `.beads/` graph.
No cloud account, no secret, no fleet checkout.

Run every command **from the package root**. Each section says what it proves and
what a pass looks like, so a green run is evidence rather than a feeling.

---

## 1. The artifact gates (about 2 minutes)

```powershell
pwsh -NoProfile -File tools/Test-PluginLinks.ps1
pwsh -NoProfile -File tools/Sync-VendoredHelpers.ps1 -Check
pwsh -NoProfile -File tools/Test-VendoredHelpers.ps1
pwsh -NoProfile -File tools/Test-PackagePaths.ps1
```

| Gate | Pass looks like |
| :--- | :--- |
| links | `OK - <n> relative link(s) resolved across <n> file(s)` and exit 0 |
| vendored | `MATCH - 86 vendored file(s) identical` |
| helpers | `OK - ... 0 orphan(s) ... 0 of those a stale reference` |
| paths | `OK - every shipped file is free of unexplained absolute paths` |

The four gates have their own proofs:

```powershell
pwsh -NoProfile -File tools/Test-PluginLinks.Tests.ps1        # 11 tests
pwsh -NoProfile -File tools/Test-VendoredHelpers.Tests.ps1    # 16 tests, 5 skipped by design
pwsh -NoProfile -File tools/Test-VendoredSync.Tests.ps1       # 12 tests
```

A skipped test prints why it skipped. A red gate is a defect in the package, not a
baseline to accept.

## 2. Cold start - prove it works installed, not just in this checkout

This is the test that matters for publication: the package must not need the tree
it was built in.

```powershell
$cold = Join-Path $env:TEMP ('iq-cold-' + [guid]::NewGuid().ToString('N').Substring(0,6))
Copy-Item -Recurse . $cold -Exclude '.git'
$env:CL_REPOS_ROOT = $null
$env:CL_COMMON_PATH = $null
Push-Location $cold
pwsh -NoProfile -File tools/Test-PluginLinks.ps1
pwsh -NoProfile -File tools/Test-VendoredHelpers.ps1
pwsh -NoProfile -File tools/Test-PackagePaths.ps1
pwsh -NoProfile -File tools/Sync-VendoredHelpers.ps1 -Check
Pop-Location
```

Pass: all four exit 0. `-Check` says *recorded hashes only*, because there is no
canonical tree to compare against - that is the designed cold behaviour, not a
waiver. With `CL_REPOS_ROOT` set it also proves source equality.

The integration resolvers must degrade by name rather than crash:

```powershell
pwsh -NoProfile -File lib/Resolve-ClCommon.ps1        # Available=False + a reason
pwsh -NoProfile -File lib/Resolve-PrimaryRepos.ps1    # Available=False + a reason if no registry
```

## 3. The merge queue (the Sub → Hub contract)

Build a throwaway repo so nothing real is touched:

```powershell
$root   = Join-Path $env:TEMP 'iq-queue-test'
Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
$origin = Join-Path $root 'origin.git'; $repo = Join-Path $root 'repo'
git init --bare $origin -q
git clone $origin $repo -q
Set-Location $repo
git config user.email t@t.local; git config user.name T
'seed' | Out-File a.txt; git add a.txt; git commit -qm seed; git branch -M dev; git push -qu origin dev
git checkout -qb lane/one; 'one' | Out-File one.txt; git add one.txt; git commit -qm one; $sha = git rev-parse --short HEAD; git push -qu origin lane/one
git checkout -q dev

$q = (Resolve-Path .\tools\Invoke-IqaQueue.ps1).Path   # run this from the package root
pwsh -NoProfile -File $q -Mode Enqueue -Repo scratch -Branch lane/one -Sha $sha -Worktree $repo -Owner lane-1
pwsh -NoProfile -File $q -Mode List    -Repo scratch
pwsh -NoProfile -File $q -Mode Claim   -Repo scratch -ClaimedBy hub-test
pwsh -NoProfile -File $q -Mode Claim   -Repo scratch          # must REFUSE, exit 1
pwsh -NoProfile -File $q -Mode Mark    -Repo scratch -Branch lane/one -Status merged -Note 'landed'
pwsh -NoProfile -File $q -Mode Status  -Repo scratch -Json
```

Pass:

- `Enqueue` prints `queued lane/one @ <sha> base=dev by lane-1`.
- `List` shows the row; an urgent row sorts first.
- The first `Claim` prints `merging lane/one @ <sha> ... (claimed by hub-test)`.
- The **second** `Claim` exits **1** with *already merging ... One pusher per trunk*.
- `Status` reports `queued`, `merging`, `merged` counts and the next branch.
- The queue file is `<repo>/.iqa/merge-queue/scratch.jsonl` and every line starts
  with `{"v":1` - the same format the fleet's `merge-queue.mjs` reads.

Enqueue from inside a linked worktree (no `-RepoRoot`) and confirm the row lands in
the **main** checkout's `.iqa`, not the worktree's.

`Prune` deserves its own check: push a branch, delete it on origin, then

```powershell
pwsh -NoProfile -File $q -Mode Prune -Repo scratch -RepoRoot $repo -Json
```

Pass: `pruned=1`, and the row now reads `pruned ... branch gone on origin`. A branch
that is already an ancestor of the base is marked `merged`; anything unprovable is
**kept** - absence of proof is not proof of absence.

## 4. The monitor (zero tokens)

```powershell
pwsh -NoProfile -File tools/Invoke-IqaMonitor.ps1 -Mode Snapshot   # writes only when due
pwsh -NoProfile -File tools/Invoke-IqaMonitor.ps1 -Mode Snapshot   # immediately again
pwsh -NoProfile -File tools/Invoke-IqaMonitor.ps1 -Mode Status
pwsh -NoProfile -File tools/Invoke-IqaMonitor.ps1 -Mode Status -Repo uh
```

Pass:

- First `Snapshot` → `snapshots_written=<n>` (one per primary repo).
- Second `Snapshot` → `snapshots_written=0`. That is the whole cost model: an idle
  repo does not write.
- `Status` shows each repo's last write, last change, cadence interval and counts.
- `-Repo uh` (an alias) selects exactly one repo; an unknown name **fails** with
  the list of known names rather than silently supervising nothing.

Snapshots live at `<machine state home>/monitor/<repo>.jsonl`, one ~220-byte line
each.

### Simulate a stall and check the wake, without messaging anyone

```powershell
$t = Join-Path $env:TEMP 'iq-monitor-wake'
Remove-Item $t -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force "$t\monitor","$t\hubs" | Out-Null
Copy-Item "$env:USERPROFILE\.machine\state\primary-repos.json" "$t\primary-repos.json"

# a graph that has not moved for 10 hours, with unfinished work and live worktrees
[pscustomobject]@{ ts=(Get-Date).AddHours(-10).ToString('yyyy-MM-ddTHH:mm'); repo='upscale-havens'
  open=5; blocked=1; inprog=0; closed=3; estOpen=420; estClosed=180; basis='priority-table'
  trunk='abc123'; wt=2; wk=71; interval=60; changed=$true } | ConvertTo-Json -Compress |
  Set-Content "$t\monitor\upscale-havens.jsonl"

# a hub record that is live right now
$now = (Get-Date).ToUniversalTime().ToString('o')
@{ schemaVersion=2; helperVersion=4; repo='upscale-havens'; hubs=@(@{ agentId='test-agent-123'
   machine=$env:COMPUTERNAME; repoPath='x'; trunk='dev'; registeredAt=$now; heartbeatAt=$now
   pid=1; busyUntil=$null; helperVersion=4 }) } | ConvertTo-Json -Depth 5 |
  Set-Content "$t\hubs\upscale-havens.json"

# a stub transport: records what it was asked to send, sends nothing
$stub = "$t\paseo-stub.cmd"
"@echo off`r`necho %*>> `"$t\sent.txt`"`r`nexit /b 0" | Set-Content $stub -Encoding ascii

$env:MACHINE_STATE_HOME = $t
$env:PASEO_CLI = $stub
pwsh -NoProfile -File tools/Invoke-IqaMonitor.ps1 -Mode Check -Repo uh -Wake
Get-Content "$t\sent.txt"
```

Pass: two findings (`STALL-GRAPH`, `STALL-MERGE`), then
`wake upscale-havens: WAKE-SENT`, and `sent.txt` contains

```
send test-agent-123 --prompt-file <monitor>\wake-upscale-havens.txt --behavior steer --no-wait --json
```

`-WakeDryRun` prints the same command without invoking it. Point `PASEO_CLI` at a
script that exits non-zero and the result becomes a `WAKE-FAILED` **finding** - a
wake that did not get through is never silent. With no live hub the result is
`WAKE-NO-HUB`; the monitor does not invent a hub.

### Report and rollup

`Report` needs two snapshots spanning a window, so either wait, or synthesise a
history as above and run:

```powershell
pwsh -NoProfile -File tools/Invoke-IqaMonitor.ps1 -Mode Report -ReportHours 48
pwsh -NoProfile -File tools/Invoke-IqaMonitor.ps1 -Mode Rollup -RetainDays 7
```

`Report` prints completion rate, ETA and weekly-quota burn, and labels the estimate
basis **ASSUMED** - `bd` exposes no estimate, so minutes come from a declared
priority table. `Rollup` collapses lines older than `-RetainDays` into one row per
day and keeps recent lines raw.

## 5. Wire it into a harness

A harness that discovers skills by directory needs this directory on its skill
path. Nothing else: no environment variable, no `Skills/` tree beside it.

```powershell
$script = (Resolve-Path .\tools\Invoke-IqaMonitor.ps1).Path
Register-ScheduledTask -TaskName 'IQA-Monitor-Snapshot' `
  -Action @(
    New-ScheduledTaskAction -Execute (Get-Command pwsh).Source -Argument "-NoProfile -File `"$script`" -Mode Snapshot",
    New-ScheduledTaskAction -Execute (Get-Command pwsh).Source -Argument "-NoProfile -File `"$script`" -Mode Check -Wake") `
  -Trigger (New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 15)) `
  -Settings (New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew)
```

Then confirm the scheduler actually ran it:

```powershell
Get-ScheduledTaskInfo -TaskName 'IQA-Monitor-Snapshot' | Select-Object LastRunTime, LastTaskResult
```

`LastTaskResult = 0` is the pass. A non-zero code is a real failure; read it rather
than re-running until it changes.

## What a local run does NOT prove

- **A real wake to a real agent.** The transport is proven with a stub, and the
  CLI is discovered from `PASEO_CLI`, `PATH`, then the documented install
  locations; the first armed run against a live Hub is the end-to-end proof.
- **Source equality of vendored files** unless `CL_REPOS_ROOT` points at the
  fleet checkout that owns them. Without it, `-Check` proves the recorded hashes
  only, and says so.
- **A repo's own porcelain.** `Snapshot` reads `bd` and git; it never judges
  whether a bead is well written.
