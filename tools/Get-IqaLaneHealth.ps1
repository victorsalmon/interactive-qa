<#
.SYNOPSIS
Classify every IQA lane worktree by evidence, so a dead or rogue lane is caught in one tick instead of by accident.

.DESCRIPTION
A lane is only as healthy as the evidence it leaves behind. This tool reads, for each
worktree under <repo>/.worktrees/, four independent sources and classifies it:

  daemon  - the Paseo agent bound to that path (status, model, last activity)
  git     - commits ahead of the trunk, dirty file count, last commit time
  files   - is there a brief (.iqa-brief*.md) and a report (.iqa-report.md)
  peers   - is the same branch name held by another worktree or repo

Verdicts, in precedence order:

  ROGUE-DUPLICATE  branch name held by 2+ worktrees (two writers, one name)
  IDLE-EMPTY       no brief, no agent, nothing committed - a directory pretending to be a lane
  ZOMBIE           agent "running" but silent past -StallMinutes with zero commits and a clean tree
  STALLED          agent silent past -StallMinutes but work IS present (not reapable)
  DELIVERED        report written, nothing running - ready for the merge queue
  HALF-DONE        commits or uncommitted work, no report, nothing running
  ABANDONED        brief but nothing else, no agent, past grace - died mid-flight
  ACTIVE           working, or inside the grace window

The distinction that matters: "running" is a claim by the daemon, while last-activity,
commits and a report are evidence. A lane that is running but has not changed anything
past the stall window is not slow, it is stuck.

.PARAMETER Repo
Repo roots to scan. Defaults to the repo containing the current directory.

.PARAMETER GraceMinutes
How long after its brief a lane may exist with no output before it counts as abandoned.

.PARAMETER StallMinutes
How long a running agent may go without daemon activity before it is considered stuck.

.PARAMETER Reap
Act on reapable lanes only (ZOMBIE, ABANDONED, IDLE-EMPTY with zero commits and a clean
tree): stop the agent, archive it, remove the worktree, delete the non-unique branch.
Refuses (exit 3) when any commit or uncommitted file would be destroyed.

.PARAMETER AgentsJsonPath
Read the agent list from a JSON file instead of asking Paseo. For tests and for reading a
captured snapshot.

.PARAMETER Now
Treat this moment as "now". For deterministic tests.

.PARAMETER PaseoCommand
Path to the Paseo CLI. Defaults to paseo.cmd next to the installed app, else `paseo`.

.OUTPUTS
Human lines, one per lane, or JSON with -Json.
EXIT 0 no actionable finding, 3 findings (list printed), 1 reap failed, 2 cannot evaluate.
#>
[CmdletBinding()]
param(
  [string[]]$Repo = @(),
  [int]$GraceMinutes = 45,
  [int]$StallMinutes = 20,
  [switch]$Reap,
  [switch]$Json,
  [string]$AgentsJsonPath,
  # object, not [datetime]: callers (and the wrapper below) legitimately pass $null,
  # and a typed parameter turns that into a binding error instead of "use the clock".
  [object]$Now = [datetime]::MinValue,
  [string]$PaseoCommand
)

$ErrorActionPreference = 'Stop'

function Get-NormalPath {
  param([string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
  try { return ([IO.Path]::GetFullPath($Path).TrimEnd('\', '/')).ToLowerInvariant() }
  catch { return $Path.TrimEnd('\', '/').ToLowerInvariant() }
}

function Get-PaseoAgents {
  param([string]$AgentsJsonPath, [string]$PaseoCommand, [string[]]$IdsToInspect)

  if (-not [string]::IsNullOrWhiteSpace($AgentsJsonPath)) {
    $raw = Get-Content -LiteralPath $AgentsJsonPath -Raw
    return ,@($raw | ConvertFrom-Json)
  }

  $paseo = $PaseoCommand
  if ([string]::IsNullOrWhiteSpace($paseo)) {
    $candidates = @(
      'C:\Program Files\Paseo\resources\bin\paseo.cmd',
      'paseo'
    )
    foreach ($c in $candidates) {
      $cmd = Get-Command $c -ErrorAction SilentlyContinue
      if ($cmd) { $paseo = $cmd.Source; break }
    }
  }
  if ([string]::IsNullOrWhiteSpace($paseo)) { return $null }

  $raw = & $paseo agent ls --json 2>&1 | Out-String
  if ($LASTEXITCODE -ne 0) { return $null }
  $agents = @($raw | ConvertFrom-Json)

  # `agent ls` is a cheap list and does not always carry last-activity, so ask `inspect`
  # for the agents we actually care about. Absence of the field would otherwise read as
  # "silent forever", which is the failure mode this tool exists to avoid.
  foreach ($a in $agents) {
    if ($a.PSObject.Properties.Name -contains 'UpdatedAt') { continue }
    if ($null -eq $IdsToInspect -or $IdsToInspect -notcontains $a.id) { continue }
    try {
      $one = & $paseo inspect --json $a.id 2>&1 | Out-String
      if ($LASTEXITCODE -eq 0) {
        $o = $one | ConvertFrom-Json
        if ($o.UpdatedAt) { $a | Add-Member -NotePropertyName UpdatedAt -NotePropertyValue $o.UpdatedAt -Force }
        if ($o.Status) { $a | Add-Member -NotePropertyName Status -NotePropertyValue $o.Status -Force }
        if ($o.Model) { $a | Add-Member -NotePropertyName Model -NotePropertyValue $o.Model -Force }
      }
    } catch { }
  }
  return ,$agents
}

function Get-RefAgeMinutes {
  param([datetime]$Moment, [datetime]$Now)
  if ($Moment -eq [datetime]::MinValue) { return $null }
  return [int]([math]::Round(($Now - $Moment).TotalMinutes))
}

function Get-LaneVerdict {
  param(
    [int]$Ahead,
    [int]$Dirty,
    [string]$AgentStatus,
    [object]$SilenceMinutes,
    [object]$BriefAgeMinutes,
    [bool]$HasBrief,
    [bool]$HasReport,
    [bool]$DuplicateBranch,
    [int]$GraceMinutes = 45,
    [int]$StallMinutes = 20
  )

  if ($DuplicateBranch) { return 'ROGUE-DUPLICATE' }

  $running = ($AgentStatus -eq 'running')
  $hasAgent = -not [string]::IsNullOrWhiteSpace($AgentStatus)
  $progress = ($Ahead -gt 0) -or ($Dirty -gt 0)
  $age = if ($null -ne $BriefAgeMinutes) { [int]$BriefAgeMinutes } else { 0 }

  if (-not $hasAgent -and -not $HasBrief -and -not $progress) { return 'IDLE-EMPTY' }
  if (-not $hasAgent -and -not $HasBrief -and -not $HasReport -and -not $progress) { return 'IDLE-EMPTY' }

  if ($running) {
    $silent = if ($null -ne $SilenceMinutes) { [int]$SilenceMinutes } else { 0 }
    if ($progress) {
      if ($silent -gt $StallMinutes) { return 'STALLED' }
      return 'ACTIVE'
    }
    if ($silent -gt $StallMinutes) { return 'ZOMBIE' }
    if ($age -gt $GraceMinutes) { return 'ZOMBIE' }
    return 'ACTIVE'
  }

  if ($HasReport) { return 'DELIVERED' }
  if ($progress) { return 'HALF-DONE' }
  if ($HasBrief -and $age -gt $GraceMinutes) { return 'ABANDONED' }
  return 'ACTIVE'
}

function Get-LaneFacts {
  param([string]$RepoRoot, [string]$WorktreePath, [string]$Branch)

  $ahead = 0
  $dirty = 0
  $lastCommit = [datetime]::MinValue

  foreach ($base in @('origin/dev', 'origin/main', 'dev', 'main')) {
    $null = & git -C $WorktreePath rev-parse --verify --quiet $base 2>$null
    if ($LASTEXITCODE -eq 0) {
      $ahead = [int]((& git -C $WorktreePath rev-list --count "$base..HEAD" 2>$null | Select-Object -First 1))
      break
    }
  }

  $dirty = @(& git -C $WorktreePath status --porcelain 2>$null).Count

  $epoch = (& git -C $WorktreePath log -1 --format=%ct 2>$null | Select-Object -First 1)
  if ($epoch -match '^\d+$') { $lastCommit = [datetimeOffset]::FromUnixTimeSeconds([int64]$epoch).LocalDateTime }

  $brief = Get-ChildItem -LiteralPath $WorktreePath -Filter '.iqa-brief*.md' -Force -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
  $report = Test-Path -LiteralPath (Join-Path $WorktreePath '.iqa-report.md')

  return [pscustomobject]@{
    Repo        = $RepoRoot
    Path        = $WorktreePath
    Branch      = $Branch
    Ahead       = $ahead
    Dirty       = $dirty
    HasBrief    = [bool]$brief
    BriefTime   = if ($brief) { $brief.LastWriteTime } else { [datetime]::MinValue }
    HasReport   = [bool]$report
    LastCommit  = $lastCommit
  }
}

function Invoke-LaneReap {
  param([object]$Lane, [string]$PaseoCommand)

  if ($Lane.Ahead -gt 0 -or $Lane.Dirty -gt 0) {
    Write-Output ("REFUSED {0}: has {1} commit(s) ahead and {2} dirty file(s); nothing is destroyed by this tool" -f $Lane.Path, $Lane.Ahead, $Lane.Dirty)
    return $false
  }

  if ($Lane.AgentId) {
    if (-not [string]::IsNullOrWhiteSpace($PaseoCommand)) {
      & $PaseoCommand stop $Lane.AgentId 2>&1 | Out-Null
      & $PaseoCommand archive $Lane.AgentId 2>&1 | Out-Null
    }
  }

  $repoRoot = $Lane.Repo
  & git -C $repoRoot worktree remove $Lane.Path --force 2>&1 | Out-Null
  if ($LASTEXITCODE -ne 0) {
    Write-Output ("REAP-FAILED {0}: git worktree remove exited {1}" -f $Lane.Path, $LASTEXITCODE)
    return $false
  }
  if ($Lane.Branch -and -not $Lane.BranchProtects) {
    & git -C $repoRoot branch -D $Lane.Branch 2>&1 | Out-Null
  }
  Write-Output ("REAPED {0} (branch {1})" -f $Lane.Path, $Lane.Branch)
  return $true
}

function Invoke-Main {
  param(
    [string[]]$Repo, [int]$GraceMinutes, [int]$StallMinutes, [switch]$Reap,
    [switch]$Json, [string]$AgentsJsonPath, [object]$Now, [string]$PaseoCommand
  )

  if ($null -eq $Now -or $Now -eq [datetime]::MinValue) { $Now = Get-Date }
  $Now = [datetime]$Now

  if (-not $Repo -or $Repo.Count -eq 0) {
    $here = (Get-Location).Path
    $top = & git -C $here rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -ne 0) {
      Write-Output 'CANNOT-EVALUATE: not inside a git repository and -Repo was not supplied.'
      $script:LaneHealthExit = 2; return
    }
    $Repo = @($top)
  }

  # Resolve paseo once; without it we can still judge git and files, but agent state is unknown.
  $paseo = $PaseoCommand
  if ([string]::IsNullOrWhiteSpace($paseo)) {
    foreach ($c in @('C:\Program Files\Paseo\resources\bin\paseo.cmd', 'paseo')) {
      $cmd = Get-Command $c -ErrorAction SilentlyContinue
      if ($cmd) { $paseo = $cmd.Source; break }
    }
  }

  $lanes = New-Object System.Collections.ArrayList
  foreach ($root in $Repo) {
    $rootFull = (Resolve-Path -LiteralPath $root).Path
    $porcelain = & git -C $rootFull worktree list --porcelain 2>$null
    if ($LASTEXITCODE -ne 0) {
      Write-Output "CANNOT-EVALUATE: '$rootFull' is not a git repository."
      $script:LaneHealthExit = 2; return
    }

    $current = $null
    foreach ($line in @($porcelain) + @('')) {
      if ($line -like 'worktree *') {
        $current = [pscustomobject]@{ Path = $line.Substring(9).Trim(); Branch = ''; Head = '' }
      } elseif ($current -and $line -like 'branch refs/heads/*') {
        $current.Branch = $line.Substring('branch refs/heads/'.Length).Trim()
      } elseif ($current -and $line -like 'HEAD *') {
        $current.Head = $line.Substring(5).Trim()
      } elseif ($current -and [string]::IsNullOrWhiteSpace($line)) {
        if ((Get-NormalPath $current.Path).Contains('\.worktrees\')) {
          $null = $lanes.Add([pscustomobject]@{ Repo = $rootFull; Path = $current.Path; Branch = $current.Branch })
        }
        $current = $null
      }
    }
  }

  # Ask the daemon about every lane path at once, rather than per lane.
  $agents = Get-PaseoAgents -AgentsJsonPath $AgentsJsonPath -PaseoCommand $paseo
  if ($null -eq $agents) {
    Write-Output 'CANNOT-EVALUATE: could not read the Paseo agent list; lane agent state is unknown.'
    $script:LaneHealthExit = 2; return
  }

  $branchCounts = @{}
  foreach ($l in $lanes) {
    if ($l.Branch) {
      $k = $l.Branch.ToLowerInvariant()
      if (-not $branchCounts.ContainsKey($k)) { $branchCounts[$k] = 0 }
      $branchCounts[$k] = $branchCounts[$k] + 1
    }
  }

  $results = New-Object System.Collections.ArrayList
  foreach ($lane in $lanes) {
    $facts = Get-LaneFacts -RepoRoot $lane.Repo -WorktreePath $lane.Path -Branch $lane.Branch

    $bound = @($agents | Where-Object { $_.cwd -and ((Get-NormalPath $_.cwd) -eq (Get-NormalPath $lane.Path)) })
    $live = $bound | Where-Object { $_.status -in @('running', 'idle') } | Select-Object -First 1
    $any = if ($live) { $live } else { $bound | Select-Object -First 1 }

    $agentStatus = if ($any) { [string]$any.status } else { '' }
    $silence = $null
    if ($any -and $any.PSObject.Properties.Name -contains 'UpdatedAt' -and $any.UpdatedAt) {
      try { $silence = Get-RefAgeMinutes -Moment ([datetime]$any.UpdatedAt) -Now $Now } catch { $silence = $null }
    }
    if ($null -eq $silence -and $facts.LastCommit -ne [datetime]::MinValue -and $agentStatus -eq 'running') {
      $silence = Get-RefAgeMinutes -Moment $facts.LastCommit -Now $Now
    }

    $briefAge = if ($facts.HasBrief) { Get-RefAgeMinutes -Moment $facts.BriefTime -Now $Now } else { $null }

    $verdict = Get-LaneVerdict -Ahead $facts.Ahead -Dirty $facts.Dirty -AgentStatus $agentStatus `
      -SilenceMinutes $silence -BriefAgeMinutes $briefAge -HasBrief $facts.HasBrief -HasReport $facts.HasReport `
      -DuplicateBranch ($lane.Branch -and $branchCounts[$lane.Branch.ToLowerInvariant()] -gt 1) `
      -GraceMinutes $GraceMinutes -StallMinutes $StallMinutes

    $entry = [pscustomobject]@{
      Verdict   = $verdict
      Repo      = (Split-Path $lane.Repo -Leaf)
      Path      = $lane.Path
      Branch    = $lane.Branch
      Ahead     = $facts.Ahead
      Dirty     = $facts.Dirty
      Agent     = if ($any -and $any.PSObject.Properties.Name -contains 'shortId') { [string]$any.shortId } elseif ($any) { [string]$any.id } else { '' }
      AgentId   = if ($any) { [string]$any.id } else { '' }
      Status    = $agentStatus
      Model     = if ($any -and $any.PSObject.Properties.Name -contains 'Model') { [string]$any.Model } else { '' }
      SilentMin = $silence
      BriefMin  = $briefAge
      HasReport = $facts.HasReport
      Reapable  = ($verdict -in @('ZOMBIE', 'ABANDONED', 'IDLE-EMPTY')) -and ($facts.Ahead -eq 0) -and ($facts.Dirty -eq 0)
    }
    $null = $results.Add($entry)
  }

  $actionable = @($results | Where-Object { $_.Verdict -in @('ZOMBIE', 'STALLED', 'ROGUE-DUPLICATE', 'ABANDONED', 'IDLE-EMPTY') })

  if ($Reap) {
    $failed = 0
    foreach ($r in @($results | Where-Object { $_.Reapable })) {
      $ok = Invoke-LaneReap -Lane $r -PaseoCommand $paseo
      if (-not $ok) { $failed++ }
    }
    if ($failed -gt 0) { $script:LaneHealthExit = 1; return }
  }

  if ($Json) {
    [pscustomobject]@{
      Now        = $Now.ToString('s')
      Grace      = $GraceMinutes
      Stall      = $StallMinutes
      Lanes      = @($results)
      Actionable = $actionable.Count
      Reapable   = @($results | Where-Object { $_.Reapable }).Count
    } | ConvertTo-Json -Depth 5
  } else {
    foreach ($r in ($results | Sort-Object @{ Expression = { $_.Verdict }; Descending = $false }, Repo, Path)) {
      $silent = if ($null -ne $r.SilentMin) { "$($r.SilentMin)m" } else { '-' }
      $brief = if ($null -ne $r.BriefMin) { "$($r.BriefMin)m" } else { '-' }
      Write-Output ("{0,-15} {1,-22} ahead={2,-2} dirty={3,-2} agent={4,-8} status={5,-8} silent={6,-5} brief={7,-5} {8}" -f `
        $r.Verdict, (Split-Path $r.Path -Leaf), $r.Ahead, $r.Dirty, $(if ($r.Agent) { $r.Agent } else { '-' }), $(if ($r.Status) { $r.Status } else { '-' }), $silent, $brief, $r.Branch)
    }
    Write-Output ''
    Write-Output ("lanes={0} actionable={1} reapable={2}" -f $results.Count, $actionable.Count, @($results | Where-Object { $_.Reapable }).Count)
    foreach ($r in $actionable) {
      Write-Output ("FINDING {0,-15} {1}" -f $r.Verdict, $r.Path)
    }
  }

  if ($actionable.Count -gt 0) { $script:LaneHealthExit = 3; return }
  return
}

if ($MyInvocation.InvocationName -ne '.') {
  $script:LaneHealthExit = 0
  Invoke-Main -Repo $Repo -GraceMinutes $GraceMinutes -StallMinutes $StallMinutes `
    -Reap:$Reap -Json:$Json -AgentsJsonPath $AgentsJsonPath -Now $Now -PaseoCommand $PaseoCommand
  exit $script:LaneHealthExit
}
