# Interactive QA Agent

Version **1.0.0**. A publishable agent plugin for running interactive
quality-assurance sessions against a product, with a merge hub, worker lanes, and
credential-safe dispatch. It is a **package of links and contracts**, not a copy
of any existing skill: the normative text stays in one owner file per rule and
every other surface points at it.

## What it is

- One front door ([SKILL.md](SKILL.md)) that routes to exactly one member.
- A small normative core ([core/INVARIANTS.md](core/INVARIANTS.md),
  [core/TASK-MODEL.md](core/TASK-MODEL.md), [core/ADAPTERS.md](core/ADAPTERS.md),
  [core/PROFILE.template.md](core/PROFILE.template.md)) that states each shared
  rule once.
- Six members, each owning one kind of work, each a thin shell around the core.

## What it is NOT

- **Not a fork of `iqa-beads`, `iqa-merge`, `iqa-common`, `work-now`,
  `sub-mode`, `sub-watch`, `paseo-child-agents` or `credential-rescue`.** The Key
  family moved here in Phase 2 and the IQA family (hub, sub, handoff, dispatch)
  in Phase 3; every old skill file is now a thin pointer that names the member
  that owns the text. `work-now` keeps its canonical text and is cited, never
  copied. The on-ramp stays outside and is reached through the `on_ramp`
  adapter; every executable the members prescribe is **vendored** under
  `vendor/` (the Key family included) and reached through the matching adapter
  rather than through a link that escapes this package
  ([core/ADAPTERS.md](core/ADAPTERS.md) -> `## External adapters` and
  `## Vendored helpers (in-package)`).
- **Not a task store.** It does not define a backlog format of its own
  ([core/TASK-MODEL.md](core/TASK-MODEL.md)).
- **Not an autonomy grant.** It never authorises an operator-gated action
  ([core/INVARIANTS.md](core/INVARIANTS.md) → Invariant 8).
- **Not a secrets holder.** No key material is stored here, and no value is ever
  printed (Invariant 6).

## The members

| Member | One line | Read |
| :--- | :--- | :--- |
| `iqa-hub` | Runs the QA session end to end (blocker analysis, tracker, triage, close) and is the repo's single merge owner. | [members/iqa-hub/SKILL.md](members/iqa-hub/SKILL.md) |
| `iqa-sub` | Executes one unit of built work on its own branch and worktree, then parks it queued for the hub. | [members/iqa-sub/SKILL.md](members/iqa-sub/SKILL.md) |
| `iqa-handoff` | Carries context between agents and decides whether a hand-off was actually delivered. Sole owner of the receipt rule. | [members/iqa-handoff/SKILL.md](members/iqa-handoff/SKILL.md) |
| `dispatch` | Spawns, briefs, supervises and recovers a detached worker. | [members/dispatch/SKILL.md](members/dispatch/SKILL.md) |
| `key-watch` | Canaries credential health on a cadence and decides when a cutover is due, including the deadline-bounded Key Check. | [members/key-watch/SKILL.md](members/key-watch/SKILL.md) |
| `key-cutover` | Moves the machine onto a replacement credential, one track at a time, and proves every surface moved. | [members/key-cutover/SKILL.md](members/key-cutover/SKILL.md) |

## How to invoke it

The front door is [SKILL.md](SKILL.md). A harness that discovers skills by
directory loads it when the user's words match, or you load it explicitly:

```
# any harness that reads a skill directory
read interactive-qa-agent/SKILL.md
```

Read the front door, then **one** member — the member the user's words name. The
front door defines no procedure; it routes and stops.

## How adapters resolve

Three independent axes, one value per axis, chosen by a **profile**
([core/PROFILE.template.md](core/PROFILE.template.md)):

- **executor** — `paseo` or `generic`;
- **provider pool** — a pool of keys or a single key;
- **repo profile** — trunks, gates, deploy, secrets and logging for one repo.

Every slot is either an in-package default or a deployment value:

- **Helpers** resolve from the profile's `scripts_root`, which defaults to
  `<package>/vendor` — in-package, and that is the deployment truth. The fleet
  tree is a **development override** supplied by a profile, never a requirement.
- **Documents** (an on-ramp, a bead schema, a provider log) resolve through their
  adapter's profile value. Absent is always `cannot-evaluate` with a reason —
  never a guessed path ([core/ADAPTERS.md](core/ADAPTERS.md)).

Vendored files mirror the canonical layout so the scripts' own relative
resolution (`../assets`, `../../aws/scripts`, `../../iqa-merge`,
`../../git-operations`) lands inside the package. Drift between a vendored file
and its canonical source is caught by `tools/Sync-VendoredHelpers.ps1 -Check`.
Two vendored files are deliberately **patched** (both hashes recorded, canonical
change still reported as DRIFT): the provider-lock resolver, which keeps the lock
in the machine state root, and the cutover switch, whose credential log falls back
to the machine state root when no fleet checkout is present.

## Install

1. Copy this directory into the harness's skill root (or add its parent as a
   skill path).
2. Make sure `pwsh` 7+ and `git` are on `PATH`, and `bd` (beads) for the repo the
   session works on. `bd` is the required task store
   ([core/TASK-MODEL.md](core/TASK-MODEL.md) -> `## Adapter contract`).
3. On the fleet, the thin cross-harness pointers can be converged with the
   fleet installer (a deployment tool, not part of this package):
   `pwsh -File <fleet>/Skills/install-harness/Invoke-HarnessInstall.ps1 -Verify`.
   Without it, the package works standalone — its own `SKILL.md` is the entry
   point.

Nothing else is required: no `Skills/` tree beside the package, no environment
variable, no machine path.

## Verify

```
pwsh -NoProfile -File tools/Test-PluginLinks.ps1              # 0 dead, 0 escaping
pwsh -NoProfile -File tools/Sync-VendoredHelpers.ps1 -Check   # every row MATCH
pwsh -NoProfile -File tools/Test-VendoredHelpers.ps1          # no orphans, no unexcused helper
pwsh -NoProfile -File tools/Test-PackagePaths.ps1             # no unexplained absolute path
```

All four run from the package root and from a copy anywhere on disk. The link
gate exits `0` only when every relative Markdown link resolves **and stays inside
the package root**; it prints each dead or escaping link with its file and line.
`-ResolvableOnly` is a diagnostic for "what is dead", never a self-containment
proof. The link gate's own proof is
[tools/Test-PluginLinks.Tests.ps1](tools/Test-PluginLinks.Tests.ps1); the
vendored-helper gate's is
[tools/Test-VendoredHelpers.Tests.ps1](tools/Test-VendoredHelpers.Tests.ps1).

One owner writes every vendored copy (`tools/Sync-VendoredHelpers.ps1`); run it
with no argument after a canonical change, and commit both sides. What ships and
what does not is [MANIFEST.md](MANIFEST.md).

## Archive and alias relationship

The plugin replaces the legacy IQA and Key skill names without deleting them.
Each old name keeps its trigger words and points at the member that now owns the
text; the package's member files are the destination. Text the rules quote
verbatim is vendored under [references/vendored/](references/vendored/iqa-common-contracts.md)
with its source path and commit, and documents retired during the migration are
recorded as archived rows in the manifest (their old path, their archived path and
their hash), so provenance survives the move.

## Status

Phase 6. The core contracts and the link gate landed in Phase 1; the **Key
family** in Phase 2; the **IQA family** in Phase 3; the archive/alias work in
Phases 4–5; publish hardening (no runtime state in the package, no absolute
paths, a publish manifest, and a cold start from a copy alone) in Phase 6. Still
outside the plugin by design: `work-now`, `credential-rescue` (cited as the
fleet's owner until it is retired), and every helper the manifest declares
not-vendored.

## License

MIT — see [LICENSE](LICENSE). Copyright (c) 2026 Victor Salmon.
