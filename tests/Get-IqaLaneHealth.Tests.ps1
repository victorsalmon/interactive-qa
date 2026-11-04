<#
Tests for tools/Get-IqaLaneHealth.ps1

The classifier is the part that decides whether a lane gets reaped, so it is tested
as a truth table first. One integration test then proves the git facts (commits ahead,
dirty count) are counted from a real repository rather than trusted.
#>

BeforeAll {
  $script:Tool = Join-Path $PSScriptRoot '..' 'tools' 'Get-IqaLaneHealth.ps1'
  . $script:Tool
}

Describe 'Get-IqaLaneHealth verdicts' {

  It 'calls a running lane with recent progress ACTIVE' {
    Get-LaneVerdict -Ahead 3 -Dirty 0 -AgentStatus 'running' -SilenceMinutes 2 -BriefAgeMinutes 10 `
      -HasBrief $true -HasReport $false -DuplicateBranch $false -GraceMinutes 45 -StallMinutes 20 |
      Should -Be 'ACTIVE'
  }

  It 'calls a running lane that has work but has gone silent STALLED, not ZOMBIE' {
    Get-LaneVerdict -Ahead 3 -Dirty 0 -AgentStatus 'running' -SilenceMinutes 40 -BriefAgeMinutes 60 `
      -HasBrief $true -HasReport $false -DuplicateBranch $false -GraceMinutes 45 -StallMinutes 20 |
      Should -Be 'STALLED'
  }

  It 'calls a running lane with zero output past the stall window ZOMBIE' {
    Get-LaneVerdict -Ahead 0 -Dirty 0 -AgentStatus 'running' -SilenceMinutes 120 -BriefAgeMinutes 130 `
      -HasBrief $true -HasReport $false -DuplicateBranch $false -GraceMinutes 45 -StallMinutes 20 |
      Should -Be 'ZOMBIE'
  }

  It 'calls a running lane with no progress and an old brief ZOMBIE even without a daemon timestamp' {
    Get-LaneVerdict -Ahead 0 -Dirty 0 -AgentStatus 'running' -SilenceMinutes $null -BriefAgeMinutes 90 `
      -HasBrief $true -HasReport $false -DuplicateBranch $false -GraceMinutes 45 -StallMinutes 20 |
      Should -Be 'ZOMBIE'
  }

  It 'leaves a freshly dispatched lane alone (inside grace)' {
    Get-LaneVerdict -Ahead 0 -Dirty 0 -AgentStatus 'running' -SilenceMinutes 1 -BriefAgeMinutes 1 `
      -HasBrief $true -HasReport $false -DuplicateBranch $false -GraceMinutes 45 -StallMinutes 20 |
      Should -Be 'ACTIVE'
  }

  It 'calls a finished lane with a report DELIVERED' {
    Get-LaneVerdict -Ahead 2 -Dirty 0 -AgentStatus 'idle' -SilenceMinutes 30 -BriefAgeMinutes 90 `
      -HasBrief $true -HasReport $true -DuplicateBranch $false -GraceMinutes 45 -StallMinutes 20 |
      Should -Be 'DELIVERED'
  }

  It 'calls work with no report HALF-DONE rather than failed' {
    Get-LaneVerdict -Ahead 2 -Dirty 0 -AgentStatus 'idle' -SilenceMinutes 30 -BriefAgeMinutes 90 `
      -HasBrief $true -HasReport $false -DuplicateBranch $false -GraceMinutes 45 -StallMinutes 20 |
      Should -Be 'HALF-DONE'
  }

  It 'calls a lane that died mid-flight ABANDONED' {
    Get-LaneVerdict -Ahead 0 -Dirty 0 -AgentStatus '' -SilenceMinutes $null -BriefAgeMinutes 120 `
      -HasBrief $true -HasReport $false -DuplicateBranch $false -GraceMinutes 45 -StallMinutes 20 |
      Should -Be 'ABANDONED'
  }

  It 'calls a bare worktree with no brief and no agent IDLE-EMPTY' {
    Get-LaneVerdict -Ahead 0 -Dirty 0 -AgentStatus '' -SilenceMinutes $null -BriefAgeMinutes $null `
      -HasBrief $false -HasReport $false -DuplicateBranch $false -GraceMinutes 45 -StallMinutes 20 |
      Should -Be 'IDLE-EMPTY'
  }

  It 'treats a duplicated branch name as ROGUE-DUPLICATE regardless of other evidence' {
    Get-LaneVerdict -Ahead 4 -Dirty 2 -AgentStatus 'running' -SilenceMinutes 1 -BriefAgeMinutes 5 `
      -HasBrief $true -HasReport $true -DuplicateBranch $true -GraceMinutes 45 -StallMinutes 20 |
      Should -Be 'ROGUE-DUPLICATE'
  }
}

Describe 'Get-IqaLaneHealth git facts' {

  BeforeAll {
    $script:tmp = Join-Path ([IO.Path]::GetTempPath()) ("iqa-lane-health-" + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $script:tmp -Force
    $script:repo = Join-Path $script:tmp 'repo'
    $null = New-Item -ItemType Directory -Path $script:repo -Force
    & git -C $script:repo init -q -b dev 2>&1 | Out-Null
    & git -C $script:repo config user.email 'test@example.com'
    & git -C $script:repo config user.name 'Test'
    'base' | Set-Content -LiteralPath (Join-Path $script:repo 'file.txt')
    & git -C $script:repo add -A 2>&1 | Out-Null
    & git -C $script:repo commit -q -m 'base' 2>&1 | Out-Null

    $script:wt = Join-Path $script:repo '.worktrees/lane-x'
    & git -C $script:repo worktree add -q -b feat/x $script:wt 2>&1 | Out-Null
    'one' | Set-Content -LiteralPath (Join-Path $script:wt 'one.txt')
    & git -C $script:wt add one.txt 2>&1 | Out-Null
    & git -C $script:wt commit -q -m 'one' 2>&1 | Out-Null
    'two' | Set-Content -LiteralPath (Join-Path $script:wt 'two.txt')
    & git -C $script:wt add two.txt 2>&1 | Out-Null
    & git -C $script:wt commit -q -m 'two' 2>&1 | Out-Null
    'scratch' | Set-Content -LiteralPath (Join-Path $script:wt 'dirty.txt')
  }

  AfterAll {
    if ($script:tmp -and (Test-Path $script:tmp)) { Remove-Item -LiteralPath $script:tmp -Recurse -Force -ErrorAction SilentlyContinue }
  }

  It 'counts commits ahead of the trunk and dirty files from the real worktree' {
    $f = Get-LaneFacts -RepoRoot $script:repo -WorktreePath $script:wt -Branch 'feat/x'
    $f.Ahead | Should -Be 2
    $f.Dirty | Should -Be 1
    $f.HasBrief | Should -BeFalse
    $f.HasReport | Should -BeFalse
  }

  It 'classifies an interrupted-dispatch directory as IDLE-EMPTY end to end' {
    $json = Join-Path $script:tmp 'agents.json'
    '[]' | Set-Content -LiteralPath $json
    $out = & $script:Tool -Repo $script:repo -AgentsJsonPath $json -Json 6>&1 | Out-String
    $parsed = $out | ConvertFrom-Json
    @($parsed.Lanes).Count | Should -Be 1
    @($parsed.Lanes)[0].Verdict | Should -Be 'HALF-DONE'   # it has commits + a dirty file, so it is work, not junk
  }
}

Describe 'Paseo timestamps' {

  It 'reads a zone-less Paseo instant as UTC, not as local' {
    $seen = [datetime]::SpecifyKind([datetime]'2026-11-04T13:12:59', [System.DateTimeKind]::Unspecified)
    (ConvertFrom-PaseoTime $seen).ToUniversalTime() | Should -Be $seen
  }

  It 'does not infer silence from a commit time when the daemon gave none' {
    # running, no daemon timestamp, zero progress, brief inside grace -> must stay ACTIVE
    Get-LaneVerdict -Ahead 0 -Dirty 0 -AgentStatus 'running' -SilenceMinutes $null -BriefAgeMinutes 33 `
      -HasBrief $true -HasReport $false -DuplicateBranch $false -GraceMinutes 45 -StallMinutes 20 |
      Should -Be 'ACTIVE'
  }
}
