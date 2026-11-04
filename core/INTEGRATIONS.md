# External integrations — referenced, never bundled

The plugin must run **standalone** and must also take advantage of the fleet
tooling when it is present. Those are different promises, and this file is the
line between them.

## Bundled (vendor/)

Everything the plugin needs to function on a machine that has nothing but the
plugin and `bd` (beads, a declared prerequisite):

`agent-spawn-capacity`, `aws`, `credential-rescue`, `dispatch`, `git-operations`,
`iqa-merge`, `paseo-child-agents`.

## Referenced, when cl-common is installed

| Skill | Owner | Used for |
| :--- | :--- | :--- |
| `machine-state` | cl-common | the two state roots and their invariants |
| `work-now` | cl-common | drive the beads graph to empty as Hub |
| `work-unattended` | cl-common | the same, with no operator for N hours |
| `repo-clean` | cl-common | trunk grooming / consolidation |
| `branch-worktree-hygiene` | cl-common | stale branch and worktree sweep |

These are **fleet-wide**: every repo and every hub uses them. Bundling a copy
here would fork it, and the two copies would drift — the exact failure the
vendored-helper gate (`tools/Test-VendoredSync.ps1`) exists to catch.

## How to resolve cl-common

```powershell
$common = & "$PSScriptRoot/../lib/Resolve-ClCommon.ps1"
if ($common.Available) {
    # $common.Path is the checkout; $common.Source says which variable found it
    $skill = Join-Path $common.Path 'Skills/work-now/SKILL.md'
}
else {
    Write-Warning $common.Reason   # "cl-common not installed (tried: ...)"
}
```

Resolution order: `CL_COMMON_HOME` -> `CL_COMMON_PATH` (legacy alias) -> `CL_REPOS_ROOT\cl-common` -> absent. `CL_COMMON_HOME` is the name the machine sets when cl-common is installed; the plugin never bundles cl-common.

## The contract

- **Available absent is not an error.** A missing cl-common means the machine
  skills are unavailable; plugin-local behaviour is unaffected.
- **Degrade with a named reason**, never silently: a hub that cannot reach
  `repo-clean` should say "groom unavailable: cl-common not installed", not skip
  the step as though it had passed. (Gate integrity: a gate that cannot run is
  skipped-with-waiver, carrying its reason — never a pass.)
- **Never hardcode** a user-home path or any other recreatable location in a shipped file.
  `tools/Test-PackagePaths.ps1` fails the package for it.
