# jdebug — JVM debug kit for Kubernetes

Capture and analyze JVM diagnostics from a pod **without a JDK in the image**.
`jdebug` drives thread/heap capture, memory anatomy, an offline snapshot bundle,
log tailing, and runtime log-level changes against **any Spring Boot / JVM pod**,
over `kubectl`. It is self-contained — no assumptions about a particular app,
namespace, or cluster; it uses whatever `kubectl` context is active.

## Why

Production JVM images are often JRE-only (no `jstack`/`jmap`/`jcmd`), and you may
not be allowed to `kubectl debug` a JDK sidecar in. `jdebug` prefers the tools
that work anyway, and falls back only when it has to.

**Three capture tiers** (in preference order):
1. **actuator** (default) — Spring Boot's `/actuator/threaddump` + `/actuator/heapdump`. Works JRE-only, no binary needed.
2. **jattach** — an ~80 KB static binary that speaks the Hotspot attach protocol, for the full `jcmd` surface (`GC.heap_info`, `VM.native_memory`, `JFR`, …). **Auto-downloaded** from GitHub releases and cached (see below); no manual placement.
3. **jdk** — last resort: an ephemeral JDK container via `kubectl debug` for `jstack`/`jmap`.

## Install

```sh
scripts/jdebug/install.sh          # symlink `jdebug` into ~/.local/bin
scripts/jdebug/install.sh --prefix ~/bin
scripts/jdebug/install.sh --uninstall
```
Or run it in place: `scripts/jdebug/jdebug <cmd>`. (The CLI resolves symlinks, so
the symlink install works from anywhere on PATH.)

## Usage

```sh
jdebug -n <namespace> -l <selector> <command> [--container <name>]

jdebug health                                  # actuator health + per-subsystem
jdebug status                                  # pod status + events
jdebug top                                     # top pods + HPA
jdebug memory                                  # cgroup RSS vs JVM heap/non-heap, reconciled
jdebug threads   [--via actuator|jattach|jdk]  # thread dump (default: actuator)
jdebug heap      [--via actuator|jattach|jdk]  # heap dump — PAUSES the JVM (needs --confirm)
jdebug jcmd "GC.heap_info"                     # any jcmd via jattach
jdebug snapshot  [--heap]                      # offline bundle (metrics, threads, memory, jcmd)
jdebug logs                                    # stream logs from all replicas
jdebug log-level <logger> <LEVEL>              # runtime level change via actuator
jdebug install-jattach                         # pre-stage jattach in the pod

jdebug                                         # interactive menu (triage → capture → memory → logs → snapshot)
```

Every command takes `-n/--namespace`, `-l/--selector`, `--container`, `--help`.

## Target selection

Defaults come from flags, then env, then built-ins:

| | flag | env | default |
|---|---|---|---|
| namespace | `-n` | `JDEBUG_NAMESPACE` | `default` |
| selector | `-l` | `JDEBUG_SELECTOR` | *(any pod in the namespace)* |
| container | `--container` | `JDEBUG_CONTAINER` | `app` |
| kube context | — | `KUBECONFIG` / kubectl | ambient |

## jattach binary

Auto-downloaded from `github.com/jattach/jattach` releases (matched to the pod's
arch), `kubectl cp`'d into the pod, and cached at
`${XDG_CACHE_HOME:-~/.cache}/jdebug/`. For air-gapped clusters, pre-place a copy
and pass `--binary /path/to/jattach` (or set `$JATTACH_BINARY`). Override the
version with `$JATTACH_VERSION`.

## Requirements

`kubectl` + `curl` on your PATH, a reachable kube context, and a pod that runs as
the same uid your `kubectl exec` lands as (jattach attaches same-uid).

Heap dumps and `snapshot --heap` **pause the JVM** — they require `--confirm` and
should be treated as destructive in production.
