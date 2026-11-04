<#
Tests for the repo-scoped queue store resolution in tools/Invoke-IqaQueue.ps1

Regression being pinned (measured 2026-11-04): the store was resolved from the current
directory, so a Hub working in repo A could queue a branch for repo B and the merge
worker in repo B would read a different, empty queue. One repo ended up with two stores
and a merge stalled on a frozen SHA nobody could see.
#>

BeforeAll {
  $script:Tool = Join-Path $PSScriptRoot '..' 'tools' 'Invoke-IqaQueue.ps1'
  $script:tmp = Join-Path ([IO.Path]::GetTempPath()) ("iqa-queue-" + [guid]::NewGuid().ToString('N'))
  $null = New-Item -ItemType Directory -Path $script:tmp -Force

  $script:root = Join-Path $script:tmp 'repos'
  $script:repo = Join-Path $script:root 'Public' 'demo-repo'
  $null = New-Item -ItemType Directory -Path $script:repo -Force
  & git -C $script:repo init -q -b dev 2>&1 | Out-Null
  & git -C $script:repo config user.email 'test@example.com'
  & git -C $script:repo config user.name 'Test'
  'x' | Set-Content -LiteralPath (Join-Path $script:repo 'f.txt')
  & git -C $script:repo add -A 2>&1 | Out-Null
  & git -C $script:repo commit -q -m 'base' 2>&1 | Out-Null

  $script:elsewhere = Join-Path $script:tmp 'elsewhere'
  $null = New-Item -ItemType Directory -Path $script:elsewhere -Force

  $script:sha = 'a' * 40
}

AfterAll {
  if ($script:tmp -and (Test-Path $script:tmp)) { Remove-Item -LiteralPath $script:tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

Describe 'queue store resolves to the repo, not the current directory' {

  It 'writes the row into Public/<repo>/.iqa/merge-queue when run from elsewhere' {
    $env:CL_REPOS_ROOT = $script:root
    Push-Location $script:elsewhere
    try {
      & $script:Tool -Mode Enqueue -Repo 'demo-repo' -Branch 'feat/x' -Sha $script:sha -Worktree $script:repo -Owner 'test' 2>&1 | Out-Null
      $expected = Join-Path $script:repo '.iqa\merge-queue\demo-repo.jsonl'
      Test-Path -LiteralPath $expected | Should -BeTrue
      $cwdStore = Join-Path $script:elsewhere '.iqa\merge-queue\demo-repo.jsonl'
      Test-Path -LiteralPath $cwdStore | Should -BeFalse
    } finally { Pop-Location }
  }

  It 'still writes into the current checkout when the slug matches it' {
    Push-Location $script:repo
    try {
      & $script:Tool -Mode Enqueue -Repo 'demo-repo' -Branch 'feat/y' -Sha $script:sha -Worktree $script:repo -Owner 'test' 2>&1 | Out-Null
      $expected = Join-Path $script:repo '.iqa\merge-queue\demo-repo.jsonl'
      (Get-Content -LiteralPath $expected | Measure-Object -Line).Lines | Should -BeGreaterThan 1
    } finally { Pop-Location }
  }

  It 'refuses rather than silently using the cwd when the repo cannot be found' {
    $env:CL_REPOS_ROOT = $script:root
    Push-Location $script:elsewhere
    try {
      & $script:Tool -Mode Enqueue -Repo 'no-such-repo' -Branch 'feat/z' -Sha $script:sha -Worktree $script:elsewhere -Owner 'test' 2>&1 | Out-Null
      $LASTEXITCODE | Should -Not -Be 0
      Test-Path -LiteralPath (Join-Path $script:elsewhere '.iqa\merge-queue\no-such-repo.jsonl') | Should -BeFalse
    } finally { Pop-Location }
  }
}
