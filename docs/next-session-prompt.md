# Handoff prompt — image pre-pull + Valkey MetalLB port separation

This file exists so a fresh Claude Code session can pick up two pieces of
work without a discovery phase. It has three parts:

1. **Repo dump** — the pertinent context: what the project is, how it's
   shaped, and the specific pieces we're about to touch.
2. **Task 1 — pre-pull images at install time** (corporate MITM friendly).
3. **Task 2 — swap Valkey's MetalLB IP-per-pod for shared-IP-per-port**
   (no NodePort).

Read Part 1 first; the tasks reference it.

---

## Part 1 — Repo dump

### What this project is

A Spring Boot 3.3 / **Java 21** service (`app/`) on Kubernetes (Rancher
Desktop on Apple Silicon) that acts as the **patient** for a JVM
diagnostic toolkit. CRUD API + Helm charts exist to give the tooling
something realistic to poke at: heap pressure, GC thrash, thread
starvation, JDBC/JMS/Valkey hand-offs. The service depends on Oracle
23ai, IBM MQ, and a 6-node Valkey 8 cluster.

Runtime image is deliberately **JRE-only** (`eclipse-temurin:21-jre-alpine`).
No `jstack`/`jmap`/`jcmd` baked in. Diagnostics go through:

1. Actuator (`/actuator/threaddump`, `/actuator/heapdump`) — default.
2. `jattach` (installed on-demand into `/tmp/jattach` by
   `scripts/dump-jattach.sh`) — when actuator isn't enough.
3. `kubectl debug` with a JDK ephemeral container — last resort.

### External access model — Pattern D

Two entry points by traffic type:

- **HTTP**: HAProxy VM (F5 stand-in, `192.168.105.x`, provisioned by
  `scripts/install-haproxy-vm.sh` via Lima) → RD node `:80` →
  `ingress-nginx-controller` pod (`hostNetwork: true`) → app ClusterIP.
  Mac IP forwarding is enabled so the HAProxy VM's subnet can reach
  the RD VM subnet through the Mac. `/etc/hosts` maps `debug-demo.local`
  to the HAProxy VM IP.
- **Valkey TCP**: MetalLB assigns per-pod LoadBalancer IPs
  `192.168.64.51-56`. Each pod announces its own external IP via
  `cluster-announce-ip` so MOVED redirects point at externally-reachable
  endpoints. **This is what Task 2 changes.**

Full A/B/C/D pattern comparison lives in `CLAUDE.md` under *"Four
patterns for how external LB traffic reaches in-cluster ingress-nginx"*.
This POC is Pattern D for HTTP.

### Repo layout (only the important paths)

```
app/                                  Spring Boot service (Maven, single module)
  pom.xml                             Java 21, Spring Boot 3.3.5, springdoc 2.6.0
  Dockerfile                          multi-stage: maven:3.9-eclipse-temurin-21 → eclipse-temurin:21-jre-alpine
  src/main/java/com/example/debugdemo/
    valkey/                           streams, pub/sub, hash, zset, list + ValkeyPlaygroundController
    customer/, order/, batch/         CRUD + Spring Batch CSV→JDBC load
    messaging/                        IBM MQ producer + @JmsListener consumer
    config/OpenApiConfig.java         Swagger UI wiring (4 tags)
charts/
  debug-demo-app/                     app; ClusterIP Service + Ingress; HPA 1→10 @ 20% CPU
  oracle/                             gvenzl/oracle-free:23-slim-faststart, PVC-seeded initContainer
  ibm-mq/                             icr.io/ibm-messaging/mq (amd64, Rosetta on Apple Silicon)
  valkey/                             6-node (3 primary + 3 secondary); per-pod LoadBalancer (Task 2 target)
    templates/
      configmap.yaml                  valkey.conf w/ cluster-announce-port + bus-port
      statefulset-primary.yaml        ANNOUNCE_IPS env → cluster-announce-ip per ordinal
      statefulset-secondary.yaml      same pattern
      service-loadbalancer.yaml       6 Services w/ pinned loadBalancerIP
      job-cluster-create.yaml         self-healing bootstrap (CLUSTER RESET HARD on stale PVC state)
  artifactory/                        JFrog JCR + Postgres sidecar; local Docker + Helm repo
scripts/
  install-stack.sh                    9-phase installer (MetalLB, ingress, tools, app, HAProxy VM, host wiring)
  uninstall-stack.sh                  symmetric teardown (kubectl delete ns cascade + HAProxy VM + host)
  install-haproxy-vm.sh               Lima VM provisioning (Alpine cloudinit qcow2 + apk add haproxy)
  smoke-test.sh                       43-check verification (internal + external + MOVED tests)
  test-external-access.sh             4-step lightweight external touch
  dump-threads.sh, dump-heap.sh       actuator-based capture
  dump-jattach.sh                     lazy-installs jattach into pod for jcmd access
  memory-report.sh                    cgroup + actuator memory reconciliation
  host-routes.sh                      static routes for Valkey MetalLB IPs (Mac side)
  valkey-tour.sh                      read-only tour of every op type
  lib/common.sh                       shared bash helpers
CLAUDE.md                             comprehensive project instructions (read first)
README.md                             quickstart + Pattern A/B/C/D explanation
```

### Image inventory (what Task 1 must pre-pull)

Enumerated from `charts/*/values.yaml`, `scripts/install-stack.sh`, and
the Dockerfile:

| Image | Version | Source | Consumed by |
|---|---|---|---|
| `valkey/valkey` | `8.0.1-alpine` | Docker Hub | `charts/valkey` |
| `gvenzl/oracle-free` | `23-slim-faststart` | Docker Hub | `charts/oracle` (install-stack.sh sets this) |
| `container-registry.oracle.com/database/free` | `latest` | Oracle registry | `charts/oracle/values.yaml` default |
| `icr.io/ibm-messaging/mq` | `9.4.5.1-r1-amd64` (install-stack.sh) / `9.4.0.0-r3` (values default) | IBM registry | `charts/ibm-mq` |
| `releases-docker.jfrog.io/jfrog/artifactory-jcr` | `7.90.10` | JFrog | `charts/artifactory` |
| `postgres` | `16-alpine` | Docker Hub | `charts/artifactory` (sidecar) |
| `registry.k8s.io/ingress-nginx/controller` | (chart-selected) | k8s registry | ingress-nginx helm chart |
| `registry.k8s.io/ingress-nginx/kube-webhook-certgen` | (chart-selected) | k8s registry | ingress-nginx helm chart |
| `quay.io/metallb/controller` | `v0.14.8` | Quay | MetalLB manifest |
| `quay.io/metallb/speaker` | `v0.14.8` | Quay | MetalLB manifest |
| `eclipse-temurin` | `21-jre-alpine` | Docker Hub | `app/Dockerfile` runtime |
| `maven` | `3.9-eclipse-temurin-21` | Docker Hub | `app/Dockerfile` builder |
| `debug-demo-app` | `dev` | **local build**, not pulled | `charts/debug-demo-app` |

The runtime image of the app is built locally by `docker build -t
debug-demo-app:dev app/` and injected with `image.pullPolicy=Never`.
Task 1 should still pre-pull the base image (`eclipse-temurin:21-jre-alpine`)
and the builder image so the app build itself works offline.

### Current Valkey external-access model (what Task 2 changes)

- MetalLB IPAddressPool `bridge-pool` = `192.168.64.51-192.168.64.56`
  (created by `install-stack.sh` Phase 1).
- Six per-pod `Service type: LoadBalancer` — see
  `charts/valkey/templates/service-loadbalancer.yaml`. Each pins
  `loadBalancerIP` to one of the six IPs from
  `values.yaml → loadBalancer.{primary,secondary}IPs`, selector by
  `statefulset.kubernetes.io/pod-name`, `externalTrafficPolicy: Local`.
- Both `port: client` (6379) and `port: bus` (16379) exposed per LB.
- Each pod's entrypoint (see `templates/statefulset-primary.yaml`
  lines 27-41) reads `ANNOUNCE_IPS` env (a comma-separated list of the
  six IPs), picks its ordinal, and passes
  `--cluster-announce-ip $ANNOUNCE_IP` to `valkey-server`.
- `configmap.yaml` sets `cluster-announce-port` and
  `cluster-announce-bus-port` to `.Values.ports.client` and
  `.Values.ports.bus` respectively — **the same value for every pod**.
- Mac side: `scripts/host-routes.sh add` installs 6 static routes so
  each MetalLB IP is reachable via the RD VM.

### Where install-stack.sh lives (Task 1 plug-in point)

`scripts/install-stack.sh` is a 9-phase installer:

```
Phase 0: preflight (rdctl memory/CPU, docker daemon, host tools)
Phase 1: MetalLB + IPAddressPool + L2Advertisement
Phase 2: ingress-nginx (hostNetwork=true, replicaCount=1, service.type=ClusterIP)
Phase 3: install Oracle, IBM MQ, Valkey, Artifactory (in-parallel or sequential)
Phase 4: build debug-demo-app:dev image locally
Phase 5: install debug-demo-app chart
Phase 6: provision HAProxy Lima VM (install-haproxy-vm.sh)
Phase 7: validate HAProxy path (curl through VM to ingress → app, 6-attempt retry loop)
Phase 8: Mac-side networking (static routes, /etc/hosts, sysctl ip forwarding — needs sudo)
Phase 9: smoke test hand-off (prompt to run scripts/smoke-test.sh)
```

Task 1 should insert a **new Phase 0.5** (image pre-pull) that runs
after preflight and before MetalLB install. Rationale: MetalLB
manifest pulls two container images (`controller`, `speaker`); if
those pulls MITM, Phase 1 hangs at pod creation.

### Known gotchas that constrain design choices

Documented in
`~/.claude/projects/-Users-techdesigns-dev-debugging-java-springboot-k8s/memory/k8s_gotchas.md`
— read before "simplifying" anything. Highlights that touch our tasks:

- **Valkey StatefulSet PVCs survive `helm uninstall`.** New pods on
  reinstall inherit stale `nodes.conf` referencing dead peer IPs →
  split-brain. The bootstrap Job (`job-cluster-create.yaml`) detects
  `disconnected|handshake|noaddr` peer entries or `n_peers > 1` and
  runs `CLUSTER RESET HARD` + `FLUSHALL` on every node before
  `--cluster create`. **Do not remove this self-heal in Task 2.**
- **Oracle 23ai PVC seeding via initContainer** — image pre-bakes the
  DB into an image layer; initContainer copies it to the PVC on first
  mount. Volume mounts hide image content — don't "simplify" this
  either.
- **IBM MQ amd64 only on Apple Silicon**. Runs via Rosetta emulation.
  Image pull must not attempt to resolve arm64 (there is no arm64
  manifest for the version we use).
- **Spring AOP self-invocation** breaks `@Cacheable` on same-class
  method calls — irrelevant to these tasks but classic gotcha.

---

## Part 2 — Task 1: Pre-pull all container images at install time

### Motivation

The user works on a corporate network with **MITM inspection** of TLS
traffic to arbitrary image registries. Pulling `icr.io`,
`container-registry.oracle.com`, `quay.io`, and `docker.io` mid-install
can fail with cert errors or unpredictable slowdowns. Pulling them once,
up-front, with clear errors when a pull fails, makes the install
predictable and recoverable.

### Requirements

- Runs as a **new phase in `scripts/install-stack.sh`** (proposed:
  **Phase 0.5**, after preflight, before MetalLB).
- Pulls every image from the inventory table in Part 1 *except* the
  local `debug-demo-app:dev` (which is built later in Phase 4).
- Uses the Rancher Desktop `docker` engine (the active moby engine).
  No `nerdctl`, no manual VM ssh — the `docker` CLI on the Mac talks
  to the RD VM's containerd via moby.
- **Idempotent**: skips images already present locally (`docker image
  inspect <ref> >/dev/null 2>&1`). Prints one line per image
  (`[cached]` or `[pulling]`).
- **Fail-fast**: exits non-zero on the first pull failure with a clear
  message: which image, which registry, the underlying error. Do not
  swallow errors — the whole point of this phase is to surface MITM
  early.
- Supports `--skip-image-preload` on `install-stack.sh` so users on
  the "clean" network can bypass it.
- Supports a `--image-manifest-only` mode that just prints the list of
  images it would pull (for security review / air-gap prep).

### Design sketch

New file: `scripts/preload-images.sh`. Sourced or exec'd from
`install-stack.sh` Phase 0.5.

```
#!/usr/bin/env bash
# preload-images.sh — pull every container image the stack needs, before
# the install kicks off. Designed to surface corporate-MITM cert
# failures at the earliest possible point.

IMAGES=(
  # MetalLB (Phase 1)
  "quay.io/metallb/controller:v0.14.8"
  "quay.io/metallb/speaker:v0.14.8"

  # ingress-nginx (Phase 2) — versions come from the helm chart's
  # values.yaml; document how we pinned them (see below).
  "registry.k8s.io/ingress-nginx/controller:v1.11.3"
  "registry.k8s.io/ingress-nginx/kube-webhook-certgen:v1.4.4"

  # Stateful backends (Phase 3)
  "gvenzl/oracle-free:23-slim-faststart"
  "icr.io/ibm-messaging/mq:9.4.5.1-r1-amd64"
  "valkey/valkey:8.0.1-alpine"
  "releases-docker.jfrog.io/jfrog/artifactory-jcr:7.90.10"
  "postgres:16-alpine"

  # App build (Phase 4)
  "maven:3.9-eclipse-temurin-21"
  "eclipse-temurin:21-jre-alpine"
)
```

For **ingress-nginx and MetalLB** we should pin the exact image refs
that the chart / manifest will pull. Two ways to source them, both
non-destructive:

1. `helm template ingress-nginx ingress-nginx --repo ...` and grep
   `image:`.
2. Hardcode in `preload-images.sh` and add a CI check that renders the
   manifest and diffs the image list. (Simpler; picks up when they
   drift.)

Go with hardcode + comment referencing the chart version so future
upgrades update both.

### Wiring into install-stack.sh

```
# Existing:
phase_0_preflight
phase_1_metallb
phase_2_ingress_nginx
...

# New:
phase_0_preflight
phase_0_5_preload_images         # <-- new
phase_1_metallb
...
```

`phase_0_5_preload_images` should:

1. Print a section header.
2. Respect `--skip-image-preload` (skip with a clear "SKIPPING — you
   asked to bypass image pre-pull" message).
3. Delegate to `scripts/preload-images.sh` (fail-fast, propagate exit
   code).

Add corresponding `--image-manifest-only` handling that prints the
list and exits — useful for the user's team to review before running.

### Verification

- Fresh install with `--skip-image-preload` should behave exactly as
  today.
- Fresh install *without* skip should complete without additional
  registry hits during MetalLB / ingress-nginx / helm install phases
  (verify with `kubectl describe pod` — `Pulled` events should say
  `Container image "..." already present on machine`).
- Delete one image (`docker rmi valkey/valkey:8.0.1-alpine`) and
  re-run — script should print `[cached]` for the others and
  `[pulling]` for the one that's missing.
- Simulate a pull failure (e.g., point one image at a nonexistent tag)
  — script must exit non-zero at that image with a message identifying
  which one and the underlying `docker pull` error.

### Files to touch

- `scripts/preload-images.sh` — NEW.
- `scripts/install-stack.sh` — new phase call + `--skip-image-preload`
  + `--image-manifest-only` flags.
- `README.md` — document the new phase and flags under the install
  section.
- `CLAUDE.md` — update the "How to install everything" section to note
  the pre-pull phase and where the image list lives.

---

## Part 3 — Task 2: Valkey MetalLB → shared IP, port-separated (no NodePort)

### Motivation

Six MetalLB IPs (192.168.64.51-56) is fine on Rancher Desktop where we
can advertise them via L2 on a bridge network, but in restricted
enterprise networks the security team may allocate **one VIP per app**,
not six. We want to prove the Valkey cluster can work behind a single
LB IP with **port separation** for the six nodes — the same shape
you'd get behind an F5 VIP with different destination ports.

**Hard constraint**: no NodePort. The whole point is to keep the shape
Service-type-`LoadBalancer` (so MetalLB / F5 / cloud CCM can fulfill it)
and preserve `externalTrafficPolicy: Local` for source IP.

### Design

**One shared LoadBalancer IP, one Service per pod, unique port per Service.**

MetalLB supports multiple Services sharing a single loadBalancerIP via
the `metallb.universe.tf/allow-shared-ip` annotation, provided:
- All Services share the same annotation value (e.g. `"valkey"`).
- Ports do not overlap across Services.
- `externalTrafficPolicy` is consistent across all sharing Services.

#### Port allocation

Client ports (external): sequential from a configurable base.
```
primary-0    client 6379   bus 16379
primary-1    client 6380   bus 16380
primary-2    client 6381   bus 16381
secondary-0  client 6382   bus 16382
secondary-1  client 6383   bus 16383
secondary-2  client 6384   bus 16384
```

Internal pod ports are unchanged — every pod still listens on `6379` /
`16379` in the container. Each Service maps its **external** port to
the pod's targetPort `6379` / `16379`. Only the *announce* values
differ per pod.

#### cluster-announce-* per pod

Every pod:
- `cluster-announce-ip = <shared IP>` (single value; put in ConfigMap
  or env).
- `cluster-announce-port = <base client port> + ordinal_offset`
- `cluster-announce-bus-port = <base bus port> + ordinal_offset`

Where `ordinal_offset` is:
- 0, 1, 2 for primary-0/1/2
- 3, 4, 5 for secondary-0/1/2

The entrypoint script in each StatefulSet template already computes
`ORDINAL` from `$HOSTNAME`. Extend it to compute the announce port
(offset by 3 for secondaries via a second env var or a role marker).

**Why bus port needs to be externally reachable**: bus advertisements
in `cluster-announce-bus-port` are used by peer cluster nodes for
gossip. If we set `cluster-announce-ip` to the shared external IP, peers
try to reach the shared IP:announced-bus-port for gossip — so the bus
port MUST have an external LB path too. (Internal-only pod-IP bus would
require the announce to advertise internal addressing, which defeats
the point of external LB.)

#### Service manifests

Rewrite `charts/valkey/templates/service-loadbalancer.yaml` so that:

- Loop over primaries with `$i` in 0..2:
  - Service name: `valkey-primary-$i-ext`
  - `loadBalancerIP: {{ .Values.loadBalancer.sharedIP | quote }}`
  - Annotation: `metallb.universe.tf/allow-shared-ip: "valkey"`
  - `externalTrafficPolicy: Local`
  - Ports: `client` external `{{ add .Values.loadBalancer.basePorts.client $i }}`, targetPort `client` (6379); `bus` similarly.
  - Selector: `statefulset.kubernetes.io/pod-name: valkey-primary-$i`
- Same for secondaries with `$i in 0..2` and offset of 3.

New values under `charts/valkey/values.yaml`:
```yaml
loadBalancer:
  enabled: true
  pool: bridge-pool
  mode: sharedIP-perPort         # new — accepts "sharedIP-perPort" | "perPodIP" (legacy)
  sharedIP: "192.168.64.51"      # single IP for all 6 services
  basePorts:
    client: 6379                 # primary-0 exposed as 6379; primary-1 6380; ...
    bus:    16379                # same offset for bus
```

The `mode` field lets both models coexist during migration — keep the
current per-pod-IP template behind `mode: perPodIP` for one release,
then drop it. Practical value: sanity-check the port-separated path
against the known-good IP path.

#### StatefulSet entrypoint changes

Both `statefulset-primary.yaml` and `statefulset-secondary.yaml`:

- Add env vars for `SHARED_IP`, `BASE_CLIENT_PORT`, `BASE_BUS_PORT`,
  and `ORDINAL_OFFSET` (0 for primary chart, 3 for secondary chart).
- Entrypoint computes:
  ```
  ORDINAL=$(echo "$HOSTNAME" | grep -oE '[0-9]+$')
  IDX=$((ORDINAL + ORDINAL_OFFSET))
  ANNOUNCE_PORT=$((BASE_CLIENT_PORT + IDX))
  ANNOUNCE_BUS=$((BASE_BUS_PORT + IDX))
  exec valkey-server /etc/valkey/valkey.conf \
    --cluster-announce-ip "$SHARED_IP" \
    --cluster-announce-port "$ANNOUNCE_PORT" \
    --cluster-announce-bus-port "$ANNOUNCE_BUS"
  ```
- `configmap.yaml`: drop the fixed `cluster-announce-port` /
  `cluster-announce-bus-port` lines from `valkey.conf` — those move to
  the command-line flags so they can be per-pod. Keep the listen `port
  6379` line intact (pods still listen on 6379 internally).

#### MetalLB pool sizing

With the shared-IP model, we only need **one** IP from the pool
(instead of six). Update `install-stack.sh` MetalLB IPAddressPool
`addresses:` — if valkey is the only consumer of `bridge-pool`,
shrink the pool. If other services in this repo consume it (grep for
`bridge-pool` first), keep the range and just document.

#### Host-side networking

`scripts/host-routes.sh` currently installs 6 static routes for
`192.168.64.51-56`. New model needs **one** route for the shared IP.
Update the script's `LIST` array to be derived from the shared IP
(single entry). Old routes should be cleaned up on `remove` — cover
the migration case.

### Files to touch

- `charts/valkey/values.yaml` — new `mode`, `sharedIP`, `basePorts`;
  keep legacy `primaryIPs`/`secondaryIPs` behind `mode: perPodIP` for
  one release.
- `charts/valkey/templates/service-loadbalancer.yaml` — full rewrite
  for shared-IP + per-port mode; guard legacy path with `if
  eq .Values.loadBalancer.mode "perPodIP"`.
- `charts/valkey/templates/configmap.yaml` — drop static
  `cluster-announce-port`/`cluster-announce-bus-port`; those become
  CLI args.
- `charts/valkey/templates/statefulset-primary.yaml` — new env vars,
  new entrypoint math, new `--cluster-announce-*` CLI flags.
- `charts/valkey/templates/statefulset-secondary.yaml` — same, with
  `ORDINAL_OFFSET=3`.
- `scripts/install-stack.sh` — MetalLB pool sizing, host-route call
  passes shared IP.
- `scripts/host-routes.sh` — single-IP route; teardown handles the old
  6-IP set.
- `scripts/smoke-test.sh` — external Valkey checks currently connect
  to `192.168.64.51-56:6379`; convert to `<sharedIP>:6379..6384`. The
  MOVED tests (section 7) already tolerate any endpoint returned by
  `CLUSTER SHARDS`, so as long as the announce values are right, they
  pass.
- `scripts/test-external-access.sh` — SEED_IP + SEED_PORT wiring.
- `scripts/valkey-tour.sh` — for-loop over 6 IPs → for-loop over 6
  ports on one IP.
- `README.md` + `CLAUDE.md` — update the Valkey L4 section to describe
  both modes, why we made this change, and how MetalLB
  `allow-shared-ip` works.

### Gotchas to watch for

1. **`allow-shared-ip` requires matching `externalTrafficPolicy`
   across sharing Services.** All 6 must be `Local` (they already are
   in the current template — don't regress).
2. **Cluster bootstrap timing.** `charts/valkey/templates/job-cluster-create.yaml`
   already handles stale-PVC recovery, but if you change the announce
   port mid-bootstrap the recorded `nodes.conf` on the PVC will still
   reference old ports. The self-heal (`CLUSTER RESET HARD` +
   `FLUSHALL`) covers that — verify it triggers on the mode switch by
   reinstalling into an existing PVC set.
3. **MOVED redirect semantics don't change.** Clients still receive
   `MOVED <slot> <ip>:<port>`; the difference is the `ip` is the same
   across all 6 responses and the `port` distinguishes the shard. Any
   cluster-aware client (`valkey-cli -c`, Lettuce) handles this
   natively.
4. **Bus port announcements.** If you forget to set
   `cluster-announce-bus-port`, peers try to gossip on the default
   16379 across the shared IP, which routes to some arbitrary shard
   — cluster ends up in `cluster_state:fail`. `smoke-test.sh` section
   1 (cluster_state check) catches this immediately.
5. **HPA scale during smoke test** — leave the existing
   `debug-demo:1` minimum-ready tolerance in `smoke-test.sh` intact.
6. **Retain the `mode: perPodIP` fallback for one release.** Users
   with existing PVCs from the old model will need to reinstall into
   fresh volumes if they switch to `sharedIP-perPort`; the
   `perPodIP` fallback lets them stay on the old shape while migrating.

### Verification plan

1. `helm template charts/valkey --set loadBalancer.mode=sharedIP-perPort`
   — diff the rendered Services and confirm:
   - All 6 have the same `loadBalancerIP`.
   - All 6 have `metallb.universe.tf/allow-shared-ip: valkey`.
   - Ports are unique across the 6 Services (6379-6384 client, 16379-16384 bus).
   - `externalTrafficPolicy: Local` on all 6.
2. Clean uninstall (`scripts/uninstall-stack.sh --full --yes`) then
   fresh install → cluster reaches `cluster_state:ok` within the
   bootstrap Job's timeout.
3. From outside cluster:
   - `valkey-cli -h <sharedIP> -p 6379 -a $PASS ping` → PONG.
   - `valkey-cli -h <sharedIP> -p 6379 -a $PASS cluster shards` returns
     entries whose IP is `<sharedIP>` and whose ports are the 6
     announced ones.
   - `valkey-cli -c -h <sharedIP> -p 6379 -a $PASS set moved-test hi`
     follows a MOVED to `<sharedIP>:<other-port>` and returns OK.
   - `valkey-cli -h <sharedIP> -p 6379 -a $PASS cluster info` shows
     `cluster_state:ok`, `cluster_size:3`.
4. From inside cluster (app-to-Valkey path): app pod `curl
   /actuator/health` reports Valkey UP (this uses in-cluster DNS, not
   the LB path — should be entirely unaffected).
5. `scripts/smoke-test.sh` end-to-end passes with 0 failures. The
   MOVED tests in section 7 exercise GET/SET, XADD, and SPUBLISH
   across shards.

### Non-goals

- Do NOT introduce NodePort. If MetalLB shared-IP doesn't work for a
  reason we haven't identified, stop and ask — don't fall back to
  NodePort silently.
- Do NOT delete the `perPodIP` mode in the same PR that adds
  `sharedIP-perPort`. Keep both for one release.
- Do NOT change the app's internal Valkey client wiring — that uses
  in-cluster DNS (`valkey-primary-{0,1,2}.valkey-primary-headless...`)
  and is orthogonal to the external LB shape.

---

## How to use this file

Open a fresh Claude Code session in `~/dev/debugging_java_springboot_k8s`
and paste:

> Read `docs/next-session-prompt.md`. Do Task 1 first, verify per the
> checklist, commit. Then do Task 2, verify per the checklist, commit.
> Ask if anything in Part 1 is stale before starting.
