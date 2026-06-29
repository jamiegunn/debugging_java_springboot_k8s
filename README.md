# debugging_java_springboot_k8s

A Spring Boot 3.3 / Java 25 service with Oracle + IBM MQ, deployable to
Kubernetes via three independent Helm charts. The primary goal of the
repo is the **debug tooling layer** in `scripts/` — kubectl-driven tools
for grabbing thread/heap dumps and toggling Logback levels at runtime
without restarting the pod.

## Layout

| Path | Purpose |
|------|---------|
| `app/` | Spring Boot service (Maven). CRUD API for `Customer` + `Order`, MQ producer/consumer, Spring Batch CSV loader. |
| `charts/debug-demo-app/` | Helm chart for the app. |
| `charts/oracle/` | Helm chart for Oracle Database Free. |
| `charts/ibm-mq/` | Helm chart for IBM MQ. |
| `charts/artifactory/` | Helm chart for JFrog Artifactory OSS (local Docker + Helm registry). |
| `charts/valkey/` | Valkey 8 — 6-node cluster (3 primaries + 3 secondaries) with **per-service-per-pod LoadBalancer** topology via MetalLB; each pod announces its own external IP via `cluster-announce-ip`. |
| `scripts/` | Debug + ops tools — see `scripts/` directory. Includes `host-routes.sh` (Mac-side stand-in for the production VIP layer) and `test-external-access.sh` (end-to-end check). |
| `load/sample-data/` | Tiny seed CSV; expand to millions for stress runs (see below). |
| `.github/workflows/` | CI: PR validation + main build → JFrog Artifactory. |
| `harness/pipeline.yaml` | Harness CD pipeline. |

## API

### Business endpoints

| Method | Path | Notes |
|--------|------|-------|
| GET / POST / PUT / DELETE | `/api/customers[/{id}]` | Standard CRUD; reads cached in Valkey (`@Cacheable`) |
| GET / POST / PUT / DELETE | `/api/orders[/{id}]` | POST drives the full integration fan-out: JPA save → MQ publish → Valkey XADD + PUBLISH + HINCRBY + ZINCRBY + LPUSH |
| POST | `/api/batch/customers/load?file=PATH` | Triggers Spring Batch CSV load |

### Valkey playground (every op type the cluster supports, no Lua)

| Method | Path | Valkey command(s) |
|--------|------|-------------------|
| POST | `/api/valkey/kv/{key}?value=...[&ttlSeconds=N]` | `SET` (optionally with `EX`) |
| GET | `/api/valkey/kv/{key}` | `GET` |
| POST | `/api/valkey/pubsub/publish?msg=...` | `PUBLISH orders:notifications` (classic, broadcasts cluster-wide via cluster bus) |
| POST | `/api/valkey/pubsub/spublish?msg=...` | `SPUBLISH {orders}:sharded` (sharded, slot-routed; sent via Lettuce raw dispatch since Spring Data Redis 3.3 has no SSUBSCRIBE binding) |
| GET | `/api/valkey/pubsub/received` | This replica's classic-subscriber receive counter |
| GET | `/api/valkey/streams/length` | `XLEN orders:events` |
| POST | `/api/valkey/streams/append` | `XADD orders:events ...` |
| GET | `/api/valkey/streams/read?count=N` | `XREAD COUNT N STREAMS orders:events 0` |
| GET | `/api/valkey/streams/consumed` | This replica's `XREADGROUP` consumer counter (group `order-processors`) |
| GET | `/api/valkey/stats/{customerId}` | `HGETALL customer:stats:{<id>}` — hash tag pins per-customer keys to one shard |
| GET | `/api/valkey/leaderboard?n=10` | `ZREVRANGE customers:top 0 N-1 WITHSCORES` |
| GET | `/api/valkey/recent?n=20` | `LRANGE orders:recent 0 N-1` + `LLEN` |

### Diagnostic / actuator

| Method | Path | Notes |
|--------|------|-------|
| GET | `/actuator/health/{liveness,readiness}` | k8s probes |
| GET/POST | `/actuator/loggers/{name}` | Runtime log-level changes |
| GET | `/actuator/threaddump`, `/actuator/heapdump`, `/actuator/prometheus` | Diagnostics (see "Debug tooling" below) |

## Local dev

Run Oracle + MQ standalone (the simplest way is the Helm charts against
minikube — see below). Then:

```sh
cd app
SPRING_PROFILES_ACTIVE=local mvn spring-boot:run
```

### Tests

```sh
cd app
mvn test       # unit
mvn verify     # unit + Testcontainers integration
```

## Getting Started (from a clean macOS install)

This section assumes **nothing**: no Homebrew, no Rancher Desktop, no
cluster running. Follow top to bottom. Every command tells you what it
does and what to expect; verification commands are inline so you catch
problems as they happen.

Time on a warm machine: ~10 minutes (most of it is image pulls).

### 0. macOS prereqs

```sh
# Apple's command-line tools (gives you git, make, clang). One-time per machine.
xcode-select --install   # opens a GUI dialog; click "Install"

# Homebrew — package manager for the rest. One-time per machine.
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# After Homebrew finishes, follow its "Next steps" — typically:
#   echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
#   eval "$(/opt/homebrew/bin/brew shellenv)"
```

Verify:
```sh
git --version       # any recent version is fine
brew --version      # 4.x
```

### 1. Install Rancher Desktop

```sh
brew install --cask rancher
```

Then **open Rancher Desktop** (Applications folder or
`open -a "Rancher Desktop"`). On first launch:

- Accept the licence terms.
- Choose **"dockerd (moby)"** as the container engine (this repo expects moby; containerd works too but you'll need to adjust `image.pullPolicy=Never` paths).
- Let it download the VM image and bootstrap (~2-3 min on first run).
- When the bottom-status row says "Kubernetes is running", proceed.

Add Rancher's bundled tools to your `$PATH` (covers `rdctl`, `kubectl`,
`helm`, `docker`, `nerdctl`):

```sh
# Add the line below to ~/.zshrc (or ~/.bash_profile) and reload your shell.
echo 'export PATH="$HOME/.rd/bin:$PATH"' >> ~/.zshrc
exec zsh
```

Verify each tool resolves and the cluster is up:

```sh
rdctl info             # should print VM state = Running
kubectl get nodes      # 1 node, STATUS Ready
helm version --short   # any v3.x
docker info            # Server.OperatingSystem mentions Alpine Linux (the RD VM)
```

### 2. Size the Rancher Desktop VM

The default 2 CPU / 6 GB is too small for the full stack. Bump it:

```sh
rdctl set --virtual-machine.memory-in-gb=16 --virtual-machine.number-cpus=8
```

This restarts the RD backend automatically (takes ~30s). Wait until
`kubectl get nodes` shows Ready again before continuing.

### 3. Clone this repo

```sh
git clone https://github.com/<your-org>/debugging_java_springboot_k8s.git
cd debugging_java_springboot_k8s
```

### 4. Bring the stack up

```sh
scripts/install-stack.sh
```

What this does (5 phases, all in-cluster, no `sudo`):

1. **Prereq check** — verifies `rdctl`, `kubectl`, `helm`, `docker`, `curl`, `python3` are on PATH; the VM is Running; CPU/memory meet the minimum.
2. **MetalLB** — applies the upstream manifest, then creates the `bridge-pool` IPAddressPool (`192.168.64.50-60`) and `L2Advertisement`.
3. **Integration charts** — installs Oracle, IBM MQ, Valkey, and Artifactory in parallel; waits for all pods to be Ready (~3-5 min).
4. **App image** — `docker build` into Rancher Desktop's local moby (no registry needed).
5. **App chart** — installs `debug-demo-app` with the right Valkey/Oracle/MQ wiring, plus the external LoadBalancer Service pinned to `192.168.64.50`.

Faster variants (use during iteration, not on a clean install):
```sh
scripts/install-stack.sh --skip-artifactory   # skip ~3-5 min Artifactory bootstrap
scripts/install-stack.sh --skip-build         # reuse an existing debug-demo-app:dev image
scripts/install-stack.sh --check              # just print what's installed; install nothing
```

Expected tail of the output:
```
=== done ===
  external IPs allocated by MetalLB:
    debug-demo/app-debug-demo-app-ext: 192.168.64.50
    valkey/valkey-primary-0-ext:       192.168.64.51
    ... (6 valkey IPs total)
  next steps:
    scripts/host-routes.sh add        # one-time sudo; makes the LB IPs reachable from this Mac
    scripts/smoke-test.sh             # end-to-end verification
```

### 5. Two manual steps install-stack.sh leaves to you

Both need `sudo` and would be unfriendly to bundle into the unattended
install. Run them by hand.

#### 5a. Required — install Mac-side static routes (so `192.168.64.x` reaches the cluster)

```sh
scripts/host-routes.sh add        # prompts for your sudo password once
```

What this does: adds 7 entries to your macOS routing table that say
"to reach `192.168.64.50-56`, send via the Rancher Desktop VM
(`192.168.64.2`)". The VM's kube-proxy iptables then DNATs each
incoming connection to the right pod. Without this step, MetalLB-assigned
IPs aren't reachable from your Mac because of how vz-NAT handles ARP.

Verify:
```sh
scripts/host-routes.sh list
# Every line should end with: gw=192.168.64.2  iface=bridge100

curl -fsS http://192.168.64.50:8080/actuator/health
# {"status":"UP","groups":["liveness","readiness"]}
```

In a real deployment this step is replaced by a real VIP/LB in front
of the cluster. The cluster config itself doesn't change.

#### 5b. Optional — Docker `insecure-registries` (only if you'll push images to the in-cluster Artifactory)

Skip this unless you'll use `scripts/local-ci.sh`. If you do:

```sh
rdctl shell -- sudo tee /etc/docker/daemon.json > /dev/null <<'EOF'
{
  "min-api-version": "1.41",
  "features": {"containerd-snapshotter": true},
  "seccomp-profile": "/etc/rancher-desktop/seccomp.json",
  "insecure-registries": ["host.docker.internal:8081"]
}
EOF
rdctl shell -- sudo rc-service docker restart
```

Verify:
```sh
docker info | grep -A2 'Insecure Registries'
# should list: host.docker.internal:8081
```

### 6. Verify end-to-end

```sh
scripts/smoke-test.sh --include-external
```

Expected output: **22 PASS / 0 FAIL**. Each line tells you which subsystem
it exercised. Non-zero exit code = the count of failures, and each failure
line shows you exactly which check broke (e.g., "IBM MQ DEV.QUEUE.1
CURDEPTH grew by 1" → MQ producer broken; "cluster-announce-ip points
at external LB IPs" → Valkey topology broken).

### 7. Use it

Two equivalent paths once everything is up:

```sh
# From the Mac (after step 5a)
BASE=http://192.168.64.50:8080
curl $BASE/actuator/health
curl -X POST $BASE/api/customers \
  -H 'Content-Type: application/json' \
  -d '{"name":"Alice","email":"alice-1@example.com"}'

# From inside the cluster (always works, no routes needed)
POD=$(kubectl -n debug-demo get pod -l app.kubernetes.io/name=debug-demo-app \
       -o jsonpath='{.items[?(@.status.containerStatuses[0].ready==true)].metadata.name}' | awk '{print $1}')
kubectl -n debug-demo exec $POD -- curl -s http://localhost:8080/actuator/health
```

See **API** (above) for every endpoint, **CLAUDE.md** for the full
runbook (logs, memory triage, dump capture without JDK tools).

### Optional convenience

```sh
brew install valkey            # gives you valkey-cli for direct cluster tests
brew install stern             # prettier multi-pod log tailing for scripts/tail-logs.sh
```

### Tear down

```sh
scripts/uninstall-stack.sh                # symmetric — helm uninstall, drop PVCs, drop pools
scripts/uninstall-stack.sh --keep-pvcs    # retain data for a re-install
scripts/uninstall-stack.sh --full         # also remove MetalLB controller
scripts/host-routes.sh remove             # tear down the static routes (matches step 5a)
```

If you also want to roll back the Docker daemon edit from step 5b:
```sh
rdctl shell -- sudo sh -c '
  cat > /etc/docker/daemon.json <<JSON
{ "min-api-version": "1.41",
  "features": {"containerd-snapshotter": true},
  "seccomp-profile": "/etc/rancher-desktop/seccomp.json" }
JSON
'
rdctl shell -- sudo rc-service docker restart
```

### Troubleshooting

| Symptom | Likely cause + fix |
|---|---|
| `install-stack.sh` says "RD VM is too small" | Run step 2 (`rdctl set --memory-in-gb=16 --number-cpus=8`) and wait for the cluster to come back |
| `kubectl get nodes` shows nothing or errors | Rancher Desktop isn't running or Kubernetes is disabled — open the app, check the status bar at bottom |
| Pods stuck in `Pending` with "Insufficient cpu/memory" | RD VM too small — re-run step 2 with larger numbers |
| `curl http://192.168.64.50:8080` times out | Step 5a not done. Run `scripts/host-routes.sh add` |
| smoke-test reports "ORA-00001 unique constraint" for customers | A previous run created the same email — smoke-test uses unique timestamps so this shouldn't recur on its own, but `scripts/uninstall-stack.sh && scripts/install-stack.sh` gets you fully clean |
| `docker push host.docker.internal:8081/...` fails with HTTPS error | Step 5b not done (only relevant if pushing to in-cluster Artifactory) |
| Oracle pod in CrashLoopBackOff | gvenzl image's pre-baked PVC seeding — the chart's `seed-oradata` initContainer handles this; if you see this, see `~/.claude/projects/.../memory/k8s_gotchas.md` |

## Deploying to a non-Rancher-Desktop cluster

Same charts work on any Kubernetes that has MetalLB (or a real cloud
LoadBalancer). The Rancher-Desktop-specific bits are:

- `192.168.64.x` IP range — replace with whatever your network gives you
- `scripts/host-routes.sh` — replace with your real LB pointing at the
  MetalLB IPs (or use the cloud provider's LoadBalancer impl directly
  and drop MetalLB)
- The `image.pullPolicy=Never` override in the app install — change to
  `IfNotPresent` and point at a real registry once you've pushed there
  (`scripts/local-ci.sh` or `.github/workflows/ci.yml` push to JFrog)

Otherwise the chart values and the entire smoke-test flow port as-is.

## Debug tooling

All scripts default to namespace `debug-demo` and selector
`app.kubernetes.io/name=debug-demo-app`. Override with `-n` / `-l`.
The runtime image is JRE-only (`eclipse-temurin:25-jre-alpine`) — no
JDK is baked in. **See CLAUDE.md for the three-tier capture story
(actuator → jattach → JDK ephemeral container).**

```sh
# Logs + log-level toggle
scripts/tail-logs.sh                                    # multi-replica log stream, prefers stern
scripts/set-log-level.sh com.example.debugdemo DEBUG    # runtime log-level via /actuator/loggers

# Memory triage — heap vs everything else, reconciled to container RSS
scripts/memory-report.sh                                # one-shot table (cgroup + actuator)

# JVM dumps — preferred path is actuator-only, no JDK tools in the pod
scripts/dump-jattach.sh install                         # one-time install of jattach into the pod
scripts/dump-jattach.sh threads                         # XREADGROUP/Thread.print via jattach
scripts/dump-jattach.sh heap --confirm                  # XADD/jmap-equivalent dump
scripts/dump-jattach.sh jcmd "GC.heap_info"             # any jcmd-style command

# Fallback path — kubectl debug with an ephemeral JDK container (last resort)
scripts/dump-threads.sh                                 # ./dumps/threads/<pod>-thread-*.txt
scripts/dump-heap.sh --confirm                          # ./dumps/heap/<pod>-heap-*.hprof

# External access stand-in for the production VIP layer (dev Mac only)
scripts/host-routes.sh add                              # sudo route add for each MetalLB IP
scripts/test-external-access.sh                        # curl + valkey-cli end-to-end check
scripts/host-routes.sh remove                          # tear down

# In-cluster CI loop against the local Artifactory
scripts/local-ci.sh                                     # build app image, push image + charts

# Comprehensive Valkey investigation from outside the cluster (read-only)
scripts/valkey-tour.sh                                  # topology, all op types, INFO, latency
scripts/valkey-tour.sh --section pubsub                 # just one section
scripts/valkey-tour.sh --seed 192.168.64.53             # use a different seed node
```

Why three capture paths exist (actuator, jattach, kubectl-debug+JDK):
the runtime image deliberately ships no JDK tools, so any "give me a
thread dump" workflow has to either (a) go through actuator endpoints
the JRE already serves, (b) install a tiny static binary like jattach
into the pod on demand, or (c) attach a JDK ephemeral container with
`shareProcessNamespace: true`. CLAUDE.md walks through when to reach
for each.

## Generating a large dataset

The sample CSV at `load/sample-data/customers.csv` has 10 rows. To
generate a million-row file for stress testing the batch loader:

```sh
{
  echo "name,email"
  awk 'BEGIN{for(i=0;i<1000000;i++) printf "User %07d,user%07d@example.com\n", i, i}'
} > /tmp/customers-1m.csv

# Mount the file into the pod (e.g. via a hostPath in dev) and trigger:
curl -X POST "http://localhost:8080/api/batch/customers/load?file=/data/customers-1m.csv"
```

## CI / CD

- **PR**: `.github/workflows/pr.yml` runs `mvn verify`, `helm lint`, shellcheck.
- **main / tag**: `.github/workflows/ci.yml` builds + pushes the image to
  JFrog Docker repo, packages all charts and uploads them to JFrog Helm
  repo, then notifies Harness.
- **Harness**: `harness/pipeline.yaml` deploys Oracle → IBM MQ → the app
  using Native Helm. `prod` is gated by an approval stage.

### Required GitHub secrets

`JFROG_HOST`, `JFROG_USER`, `JFROG_TOKEN`, `JFROG_DOCKER_REPO`,
`JFROG_HELM_REPO`, `HARNESS_WEBHOOK_URL` (optional).

### Local CI loop (Artifactory in-cluster)

The `charts/artifactory` chart installs JFrog Container Registry (JCR)
into the local cluster, with a bundled PostgreSQL StatefulSet (modern
Artifactory requires Postgres — Derby support was removed). A post-install
Job patches Artifactory's system configuration to add `debug-demo-docker`
and `debug-demo-helm` local repos. Combined with `scripts/local-ci.sh`,
this lets you exercise the full CI flow (image push, chart push,
deploy-from-registry) without a remote Artifactory or GitHub Actions runner.

```sh
helm upgrade --install artifactory ./charts/artifactory -n artifactory --create-namespace
# Bootstrap takes ~2-3 min: postgres comes up first, then Artifactory.
# Wait for: kubectl -n artifactory get pod artifactory-artifactory-0  →  1/1 Running

scripts/local-ci.sh                  # build + push image + package + push charts
scripts/local-ci.sh --tag v0.0.1     # explicit tag
scripts/local-ci.sh --skip-build     # reuse existing debug-demo-app:dev

# UI:  kubectl -n artifactory port-forward svc/artifactory-artifactory 8081:8081
#      then http://localhost:8081/  (admin / password — change in UI on first login)
```

**One-time setup for Apple Silicon Rancher Desktop.** Docker pushes to the
in-cluster registry go through `host.docker.internal:8081` (the RD VM's
docker daemon can't reach the host's `127.0.0.1`). That hostname isn't
insecure-by-default, so add it to the daemon allowlist:

```sh
rdctl shell -- sudo tee /etc/docker/daemon.json > /dev/null <<'EOF'
{
  "min-api-version": "1.41",
  "features": {"containerd-snapshotter": true},
  "seccomp-profile": "/etc/rancher-desktop/seccomp.json",
  "insecure-registries": ["host.docker.internal:8081"]
}
EOF
rdctl shell -- sudo rc-service docker restart
docker info | grep -A4 'Insecure Registries'   # verify
```

After that, `scripts/local-ci.sh` runs end-to-end: port-forward → `docker login`
→ `docker tag` + `docker push` → `helm package` + `curl -T upload`.

## Horizontal pod autoscaling

The app chart ships an HPA enabled by default: 1 → 10 replicas, target
20% CPU utilization (relative to the `requests.cpu` of 50m, so it scales
out as soon as a pod is doing ~10 millicores of work). Scale-up is
aggressive — up to 4 new pods per minute or 100% of current count,
whichever is greater. Scale-down has a 180s stabilization window to
avoid thrashing.

```sh
kubectl -n debug-demo get hpa app-debug-demo-app -w

# Drive load to see it scale:
SVC=app-debug-demo-app.debug-demo.svc.cluster.local
kubectl -n debug-demo run hpa-load --image=curlimages/curl:8.10.1 --restart=Never \
  --command -- sh -c 'while :; do for i in $(seq 1 16); do curl -s http://'$SVC':8080/api/customers >/dev/null & done; wait; done'

# Stop:
kubectl -n debug-demo delete pod hpa-load --force
```

Tune via `charts/debug-demo-app/values.yaml` under `autoscaling.*`. The
deployment strategy must be `RollingUpdate` (not `Recreate`) for HPA to
add pods without taking the existing one down — the chart defaults to
the right setting.

## External access (per-service-per-pod LB)

Production-shape topology. MetalLB allocates one pinned IP per
externally-reachable endpoint; each Valkey pod announces its own LB IP
via `cluster-announce-ip` so `CLUSTER SHARDS`/`CLUSTER NODES` return
externally-resolvable endpoints (not pod IPs).

| Endpoint | IP | Backed by |
|---|---|---|
| App (HTTP for Postman, anything) | `192.168.64.50:8080` | `app-debug-demo-app-ext` Service → all app replicas |
| Valkey primary-0 | `192.168.64.51:6379` | `valkey-primary-0-ext` Service → just that pod |
| Valkey primary-1 | `192.168.64.52:6379` | `valkey-primary-1-ext` |
| Valkey primary-2 | `192.168.64.53:6379` | `valkey-primary-2-ext` |
| Valkey secondary-0 | `192.168.64.54:6379` | `valkey-secondary-0-ext` |
| Valkey secondary-1 | `192.168.64.55:6379` | `valkey-secondary-1-ext` |
| Valkey secondary-2 | `192.168.64.56:6379` | `valkey-secondary-2-ext` |

In a real environment those IPs are reached through a VIP/LB layer
(F5/HAProxy/cloud NLB). On Rancher Desktop's vz-NAT, the dev-Mac
stand-in for that VIP is a one-time `sudo route add` per IP. The
`scripts/host-routes.sh add` helper installs them by discovering the
LB-assigned IPs at runtime; `scripts/host-routes.sh remove` tears down.
**The cluster config doesn't change between dev and prod** — only the
routing layer in front of it.

```sh
scripts/host-routes.sh add        # prompts for sudo
scripts/test-external-access.sh   # curl app, valkey-cli ping + cluster info + SET/GET
```

## Valkey + caching

`charts/valkey` ships a 6-node Valkey 8 cluster: 3 primaries (StatefulSet
`valkey-primary`) and 3 secondaries (StatefulSet `valkey-secondary`). The
post-install Job creates a 3-shard cluster on the primaries with no
replicas, then `add-node`s each `valkey-secondary-N` as a replica of
`valkey-primary-N`. The result is explicit by-index pairing (not the
default replica round-robin), which makes failover scenarios predictable
in the debug scripts.

External access goes through a single `LoadBalancer` Service that pulls
an IP from MetalLB's `debug-demo-pool`. Install MetalLB first (one-time):

```sh
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.8/config/manifests/metallb-native.yaml
# After all metallb pods are Running:
kubectl apply -f - <<'EOF'
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata: {name: debug-demo-pool, namespace: metallb-system}
spec: {addresses: ["192.168.5.200-192.168.5.220"]}
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata: {name: debug-demo-l2, namespace: metallb-system}
spec: {ipAddressPools: [debug-demo-pool]}
EOF

helm upgrade --install valkey ./charts/valkey -n valkey --create-namespace
```

The app uses Valkey via Spring Cache: `@Cacheable("customers")` on
`CustomerService.findById`, `@CacheEvict` on `update` / `delete`, plus
the same for `OrderService`. TTLs: customers 10 min, orders 2 min,
default 5 min — configurable in `ValkeyCacheConfig`.

Smoke test:
```sh
POD=$(kubectl -n debug-demo get pod -l app.kubernetes.io/name=debug-demo-app -o jsonpath='{.items[0].metadata.name}')
kubectl -n debug-demo exec $POD -- curl -s http://localhost:8080/api/customers/1   # DB hit
kubectl -n debug-demo exec $POD -- curl -s http://localhost:8080/api/customers/1   # cache hit
kubectl -n debug-demo logs $POD --tail=50 | grep 'DB hit'
PASS=$(kubectl -n valkey get secret valkey -o jsonpath='{.data.password}' | base64 -d)
kubectl -n valkey exec valkey-primary-0 -- valkey-cli -a $PASS --scan --pattern 'customers::*'
```

## Known limitations

- No transactional outbox: order persistence and MQ publish are not
  atomic. A crash between the two will lose the event. Fine for the
  debugging-tooling focus of this project; not production-ready as-is.
- Oracle Free image requires accepting the Oracle license; ensure your
  cluster can pull from `container-registry.oracle.com`.
- IBM MQ image (`icr.io/ibm-messaging/mq`) is Developer license only.
