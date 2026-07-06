# Scripts Directory

Operational + diagnostic tooling, **organized by behavior** so intent is obvious
from the path. The k3s lab router stays at the top; the JVM debug kit is a
self-contained subtree with its own router. `lib/` is shared config + helpers.

```
scripts/
  k3s.sh          # router: k3s lab lifecycle          (public)
  jdebug/         # JVM debug kit; public router is jdebug/jdebug
  lib/            # common.sh, k3s-env.sh              (shared)
  k3s/
    phases/       # install/mutation, in order         (mutating)
    verify/       # doctor, smoke, chaos, docs-verify  (read-only / disruptive)
    tours/        # narrated read-only walk-throughs   (read-only)
    ui/           # tui.sh (the ./tui menu)            (interactive)
  jdebug/
    capture/      # thread/heap capture (actuator/jattach/jdk)
    observe/      # memory report, snapshot, logs, log-level
    ui/           # tui.sh (the ./jdebug menu)
  dev/            # run-unit-tests, local-ci
```

Scripts resolve their own location by walking up to `lib/common.sh`, so they run
correctly from any depth or working directory.

## Public entrypoints

Prefer these from the repo root; the rest are lower-level implementation commands
(useful directly, but go through the routers when you can):

| Command | Purpose |
|---|---|
| `./tui` / `scripts/k3s.sh <cmd>` | k3s lab lifecycle (interactive menu / router). |
| `./jdebug` / `scripts/jdebug/jdebug <cmd>` | JVM debug kit — cluster-agnostic (any Spring Boot pod / KUBECONFIG). |

## Behavior classes

Use the class to judge risk before running:

| Class | Meaning |
|---|---|
| Read-only | Observes state; does not intentionally mutate cluster or pod. |
| Mutating | Creates/updates/deletes local infra or Kubernetes resources. |
| Disruptive | Intentionally causes outage, failover, slot movement, or a heap pause. |
| Capture | Pulls diagnostic evidence from a pod; low-risk or disruptive by option. |
| Developer | Local build/test/CI helper. |

## Script map

### `k3s/phases/` — lifecycle (Mutating)
`preflight.sh` (Mac prerequisites, auto-fix) · `bundle-images.sh` (air-gap
bundle) · `cluster.sh` (Lima VMs + k3s + image import) · `net.sh` (DNS + resolver)
· `platform.sh` (MetalLB + ingress-nginx) · `charts.sh` (app + backends) ·
`lb.sh` (LB VM: keepalived + HAProxy) · `install.sh` (orchestrates all) ·
`uninstall.sh` (tears it all down).

### `k3s/verify/` — verification + chaos
| Script | Behavior |
|---|---|
| `doctor.sh` | Read-only — every-layer health + fix commands |
| `smoke.sh` | Read-only + app writes — 15-check end-to-end |
| `docs-verify.sh` | Read-only — asserts the `/docs` design claims against the live cluster |
| `chaos.sh` | Disruptive — node/LB/Valkey/scale failure injection |
| `valkey-cluster-tests.sh` | Disruptive — slot migration, failover, MOVED/ASK |

### `k3s/tours/` — Read-only
`api-tour.sh` (API walk-through via the VIP) · `valkey-tour.sh` (Valkey topology
+ command surface).

### `k3s/ui/` — `tui.sh`, the interactive menu behind `./tui`.

### `jdebug/capture/` — Capture (JRE-only first)
`actuator.sh` (preferred; heap pauses the JVM) · `jattach.sh` (installs jattach
on demand; heap pauses) · `jdk-threads.sh` / `jdk-heap.sh` (last-resort ephemeral
JDK container; heap pauses).

### `jdebug/observe/`
`memory-report.sh` (Read-only — cgroup RSS vs JVM anatomy) · `snapshot.sh`
(Capture — offline bundle; `--heap` is disruptive) · `tail-logs.sh` (Read-only) ·
`set-log-level.sh` (Mutating — runtime logger levels via actuator).

### `jdebug/ui/` — `tui.sh`, the interactive menu behind `./jdebug`.

### `dev/` — Developer
`run-unit-tests.sh` (Maven tests with a pinned JDK) · `local-ci.sh` (CI against
local Artifactory).

### `lib/` — shared
`common.sh` (pod/kubectl helpers; auto-targets `dumps/k3s.kubeconfig`) ·
`k3s-env.sh` (single source of truth for lab config).

## Adding a script

Put it in the subdirectory that matches its behavior — do **not** add scripts to
the flat top level unless they are public routers. Cross-script calls should use
`$SCRIPTS_ROOT/<subdir>/<name>.sh` (resolved by the root-finder in the header) so
a future move doesn't break them.
