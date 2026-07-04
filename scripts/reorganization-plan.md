# Scripts Reorganization Plan

> **Status: EXECUTED.** The move to the `k3s/{phases,verify,tours,ui}` +
> `debug/{capture,observe,ui}` + `dev/` tree is done — see `scripts/README.md`
> for the live map. Two deliberate deviations from the plan below: (1) it was
> done as a **clean move with NO compatibility wrappers** (single-dev repo, all
> callers in-tree), updating the routers, inter-script calls, and every doc
> reference in one pass; (2) `docs-verify.sh` (added after this plan was written)
> was placed in `k3s/verify/`. Path resolution uses a walk-up-to-`lib/common.sh`
> root-finder rather than hardcoded `../..`. This document is kept as the record.

The current `scripts/` directory works, but it has become hard to scan because
scripts with very different execution behavior sit at the same level. The goal
of this plan is to make script intent obvious without breaking existing commands
or documentation.

## Goals

- Preserve the stable public entrypoints: `./tui`, `./debug`, `scripts/k3s.sh`,
  and `scripts/debug.sh`.
- Separate install/mutation scripts from verification, tours, diagnostics, and
  developer workflow helpers.
- Make disruptive commands visibly different from read-only commands.
- Keep compatibility wrappers for existing script paths during the transition.
- Move gradually, with a validation step after each group of moves.

## Non-goals

- Do not rewrite shell logic while moving files.
- Do not change the user-facing command language in the same pass.
- Do not remove old script paths until docs, runbooks, and muscle memory have
  had time to move to the new layout.
- Do not move generated caches such as `scripts/.cache/` into the source tree
  layout; caches should remain ignored implementation detail.

## Proposed target layout

```text
scripts/
  README.md
  reorganization-plan.md

  k3s.sh                    # compatibility/public router
  debug.sh                  # compatibility/public router

  lib/
    common.sh
    k3s-env.sh

  k3s/
    phases/
      preflight.sh
      bundle-images.sh
      cluster.sh
      net.sh
      platform.sh
      charts.sh
      lb.sh
      install.sh
      uninstall.sh

    verify/
      doctor.sh
      smoke.sh
      chaos.sh
      valkey-cluster-tests.sh

    tours/
      api-tour.sh
      valkey-tour.sh

    ui/
      tui.sh

  debug/
    ui/
      tui.sh

    capture/
      actuator.sh
      jattach.sh
      jdk-threads.sh
      jdk-heap.sh

    observe/
      memory-report.sh
      snapshot.sh
      tail-logs.sh
      set-log-level.sh

  dev/
    run-unit-tests.sh
    local-ci.sh
```

## Compatibility wrapper pattern

Old top-level paths should remain as wrappers for at least one transition
period. A wrapper should contain no business logic:

```bash
#!/usr/bin/env bash
set -euo pipefail
D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$D/k3s/phases/install.sh" "$@"
```

Use wrappers for old paths such as `scripts/k3s-install.sh` and
`scripts/dump-jattach.sh`. The routers can call the new locations directly.

## Migration phases

### Phase 0: classify and document

- Add `scripts/README.md` with the behavior map.
- Add this plan.
- Do not move files in this phase.
- Validation:
  - Markdown local-link check.
  - `git status --short` to confirm only docs changed.

### Phase 1: move k3s implementation scripts

Move lifecycle scripts first because they are the largest and most operator
visible group.

| Current path | New path |
|---|---|
| `scripts/k3s-preflight.sh` | `scripts/k3s/phases/preflight.sh` |
| `scripts/bundle-images.sh` | `scripts/k3s/phases/bundle-images.sh` |
| `scripts/k3s-cluster.sh` | `scripts/k3s/phases/cluster.sh` |
| `scripts/k3s-net.sh` | `scripts/k3s/phases/net.sh` |
| `scripts/k3s-platform.sh` | `scripts/k3s/phases/platform.sh` |
| `scripts/k3s-charts.sh` | `scripts/k3s/phases/charts.sh` |
| `scripts/k3s-lb.sh` | `scripts/k3s/phases/lb.sh` |
| `scripts/k3s-install.sh` | `scripts/k3s/phases/install.sh` |
| `scripts/k3s-uninstall.sh` | `scripts/k3s/phases/uninstall.sh` |
| `scripts/k3s-doctor.sh` | `scripts/k3s/verify/doctor.sh` |
| `scripts/k3s-smoke.sh` | `scripts/k3s/verify/smoke.sh` |
| `scripts/k3s-chaos.sh` | `scripts/k3s/verify/chaos.sh` |
| `scripts/valkey-cluster-tests.sh` | `scripts/k3s/verify/valkey-cluster-tests.sh` |
| `scripts/api-tour.sh` | `scripts/k3s/tours/api-tour.sh` |
| `scripts/valkey-tour.sh` | `scripts/k3s/tours/valkey-tour.sh` |
| `scripts/k3s-tui.sh` | `scripts/k3s/ui/tui.sh` |

Implementation notes:

- Keep `scripts/k3s.sh` at the top level.
- Update `scripts/k3s.sh` to call the new paths.
- Add wrappers at all old top-level paths.
- Review scripts that compute paths with `dirname "${BASH_SOURCE[0]}"`; after
  moving, they may need to resolve the repo script root differently.

Suggested validation:

```sh
bash -n scripts/k3s.sh scripts/k3s/**/*.sh scripts/k3s-*.sh scripts/*tour.sh
scripts/k3s.sh --help
scripts/k3s.sh status
```

When a live cluster is available, also run:

```sh
scripts/k3s.sh doctor
scripts/k3s.sh smoke
```

### Phase 2: move JVM debug kit scripts

Move the cluster-agnostic JVM diagnostic tools after the k3s scripts are stable.

| Current path | New path |
|---|---|
| `scripts/debug-tui.sh` | `scripts/debug/ui/tui.sh` |
| `scripts/dump-actuator.sh` | `scripts/debug/capture/actuator.sh` |
| `scripts/dump-jattach.sh` | `scripts/debug/capture/jattach.sh` |
| `scripts/dump-threads.sh` | `scripts/debug/capture/jdk-threads.sh` |
| `scripts/dump-heap.sh` | `scripts/debug/capture/jdk-heap.sh` |
| `scripts/memory-report.sh` | `scripts/debug/observe/memory-report.sh` |
| `scripts/snapshot.sh` | `scripts/debug/observe/snapshot.sh` |
| `scripts/tail-logs.sh` | `scripts/debug/observe/tail-logs.sh` |
| `scripts/set-log-level.sh` | `scripts/debug/observe/set-log-level.sh` |

Implementation notes:

- Keep `scripts/debug.sh` at the top level.
- Update `scripts/debug.sh` to call the new paths.
- Keep old top-level debug script paths as wrappers.
- Ensure moved scripts can still source `scripts/lib/common.sh` from their new
  depth.

Suggested validation:

```sh
bash -n scripts/debug.sh scripts/debug/**/*.sh scripts/dump-*.sh scripts/*report.sh scripts/snapshot.sh scripts/tail-logs.sh scripts/set-log-level.sh
scripts/debug.sh --help
scripts/debug.sh status
```

When a live app pod is available, also run:

```sh
scripts/debug.sh health
scripts/debug.sh threads --via actuator
scripts/debug.sh memory
```

### Phase 3: move developer workflow helpers

Move the local-only developer helpers last.

| Current path | New path |
|---|---|
| `scripts/run-unit-tests.sh` | `scripts/dev/run-unit-tests.sh` |
| `scripts/local-ci.sh` | `scripts/dev/local-ci.sh` |

Implementation notes:

- Keep wrappers at the old paths.
- Update README and docs to prefer the new paths only after wrappers exist.

Suggested validation:

```sh
bash -n scripts/dev/*.sh scripts/run-unit-tests.sh scripts/local-ci.sh
scripts/run-unit-tests.sh
```

Run `scripts/local-ci.sh` only when the local Artifactory stack is installed and
ready.

### Phase 4: update documentation references

After wrappers are in place, update docs in two layers:

1. User-facing docs should prefer public routers: `./tui`, `./debug`,
   `scripts/k3s.sh`, and `scripts/debug.sh`.
2. Deep implementation docs may reference new implementation paths when useful,
   but should mention that old paths remain wrappers.

Suggested validation:

```sh
ruby -e 'files = Dir["README.md", "docs/*.md", "scripts/*.md"]; missing = []; files.each do |file|; File.read(file).scan(/\[[^\]]+\]\(([^)#]+)(?:#[^)]+)?\)/).flatten.each do |href|; next if href =~ %r{^[a-z]+://} || href.start_with?("mailto:"); path = File.expand_path(href, File.dirname(file)); missing << "#{file} -> #{href}" unless File.exist?(path); end; end; if missing.empty?; puts "all local markdown links exist"; else; puts missing; exit 1; end'
```

## Path-resolution rule for moved scripts

Moved scripts should not assume they live directly under `scripts/`. Prefer a
small helper pattern that finds the script root or repo root explicitly. For
example:

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$SCRIPTS_ROOT/.." && pwd)"
```

The exact number of `..` segments depends on the target directory. Validate this
carefully for scripts moved under `scripts/k3s/phases`, `scripts/debug/capture`,
and `scripts/debug/observe`.

## Acceptance criteria

- Public commands still work:
  - `./tui`
  - `./debug`
  - `scripts/k3s.sh --help`
  - `scripts/debug.sh --help`
- Existing top-level script paths still work as wrappers.
- `bash -n` passes for routers, moved scripts, and wrappers.
- Markdown links pass for `README.md`, `docs/*.md`, and `scripts/*.md`.
- With a live stack, `scripts/k3s.sh doctor` and `scripts/k3s.sh smoke` pass.
- With a live app pod, `scripts/debug.sh health` and actuator thread capture
  still work.

## Recommended first implementation commit

The first implementation commit should move only the k3s lifecycle and
verification scripts, update `scripts/k3s.sh`, and leave wrappers behind. Do not
move the debug kit in the same commit. That keeps the blast radius small and
makes failures easier to diagnose.