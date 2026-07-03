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
| `charts/valkey/` | Valkey 8 — 6-node cluster (3 primaries + 3 secondaries) with **per-service-per-pod LoadBalancer** topology via MetalLB. Default: all 6 Services share ONE LB IP, split by port (6379-6384); each pod announces its shared IP + unique port via `cluster-announce-{ip,port,bus-port}`. Legacy `perPodIP` mode (6 IPs, one port) still available. |
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

### OpenAPI / Swagger UI

Springdoc-openapi is wired in — every `@RestController` shows up
automatically, grouped by `@Tag` (`customers`, `orders`, `batch`,
`valkey`). No build-time codegen, no extra annotations required.

| URL | Serves |
|-----|--------|
| `http://debug-demo.local/swagger-ui.html` | Interactive UI (try-it-out enabled) |
| `http://debug-demo.local/v3/api-docs` | OpenAPI 3.1 JSON |
| `http://debug-demo.local/v3/api-docs.yaml` | OpenAPI 3.1 YAML |

Reachable through the same nginx-ingress that serves the API, no
extra config. Set `springdoc.show-actuator: true` in
`application.yml` to also document the actuator endpoints.

## Local dev

Run Oracle + MQ standalone (the simplest way is the Helm charts against
minikube — see below). Then:

```sh
cd app
SPRING_PROFILES_ACTIVE=local mvn spring-boot:run
```

### Tests

```sh
# Easiest — finds a JDK 21 for you (Mockito can't instrument JDK 26+) and
# runs Maven with it pinned:
scripts/run-unit-tests.sh                 # unit tests (35), no Docker needed
scripts/run-unit-tests.sh --coverage      # + per-class test counts
scripts/run-unit-tests.sh --integration   # + Testcontainers ITs (needs Docker)
scripts/run-unit-tests.sh -- -Dtest=OrderServiceTest   # one class

# Or raw Maven, pinning the JDK yourself:
cd app
JAVA_HOME=$(/usr/libexec/java_home -v 21) mvn test
```

Unit coverage worth knowing about: the order-creation **fan-out contract**
(one POST must hit MQ + 5 Valkey op types), **failure-propagation pinning**
(a Valkey outage fails order creation *after* DB+MQ succeeded — deliberate,
demonstrated by `scripts/chaos.sh`), and a **cluster-slot proof** that the
`{customerId}` hash-tag pinning actually co-locates keys (real CRC16 slot
math in `ValkeyKeysTest`).

Cluster-protocol tests run against the live stack, not in JUnit — 58 checks,
each narrating why it runs / what it proves / how it fails:

```sh
scripts/valkey-cluster-tests.sh              # topology, slot routing, MOVED,
                                             # ASK (live slot migration), replica
                                             # reads, pub/sub, failover + failback
scripts/valkey-cluster-tests.sh --skip-failover   # non-disruptive subset (46)
scripts/valkey-cluster-tests.sh --no-commands     # hide the echoed commands
```

**Both `smoke-test.sh` and `valkey-cluster-tests.sh` echo the underlying
`kubectl` / `curl` / `valkey-cli` command behind every check by default** (with
concrete resolved values), so you always see what was run and the suites double
as a runnable cookbook. Pass `--no-commands` to hide them. For Valkey commands,
`export PASS=$(kubectl -n valkey get secret valkey -o jsonpath='{.data.password}' | base64 -d)`
first to make the printed commands directly runnable.

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
scripts/stackctl.sh          # ← the guided front door: install, verify,
                             #   explore, break, tear down — with narration
# or directly:
scripts/install-stack.sh
```

What the install does (10 phases; Phase 9 prompts for `sudo` once):

1. **Prereq check** — verifies `rdctl`, `kubectl`, `helm`, `docker`, `curl`, `python3`, `limactl` are on PATH; the VM is Running; CPU/memory meet the minimum.
2. **Image preload** — `scripts/preload-images.sh` pulls every registry image the stack needs (MetalLB, ingress-nginx, Oracle, MQ, Valkey, Artifactory, Postgres, plus the app's builder/runtime base images) into RD's moby up-front. Exists so **corporate-MITM TLS failures** surface here as one clear error naming the image and registry, instead of as an `ImagePullBackOff` twenty minutes in. Idempotent (skips cached images); fails fast on the first bad pull.
3. **MetalLB + nginx-ingress** — MetalLB pool `192.168.64.50-60` (Valkey's shared LB IP comes from here; only `.51` is used in the default sharedIP-perPort mode), and installs nginx-ingress with **`hostNetwork=true`** so its pod binds directly to the RD node's :80 (Pattern D).
4. **HAProxy F5 stand-in** — provisions a second Lima VM (`debug-demo-haproxy`) with HAProxy on Lima's `shared` subnet (192.168.105.x). The VM plays the F5 role for BOTH traffic types: HTTP frontend :80 → RD node :80, and Valkey L4 passthrough 6379-6384/16379-16384 → the Valkey shared MetalLB IP. Provisioned before the charts so Valkey can announce the VM's IP. First boot pulls a small Alpine cloudinit image (~2-3 min).
5. **Integration charts** — installs Oracle, IBM MQ, Valkey, and Artifactory in parallel; waits for all pods to be Ready (~3-5 min). Valkey gets `loadBalancer.announceIP=<HAProxy VM IP>` + the dev VIP shim — the two-layer F5 shape (see "Production: F5 VIP in front" below).
6. **App image** — `docker build` into Rancher Desktop's local moby (no registry needed).
7. **App chart** — installs `debug-demo-app` with ClusterIP Service + Ingress (no direct LoadBalancer).
8. **Post-install validation** — in-cluster actuator/health, Valkey cluster state, `hostNetwork=true` on ingress-nginx pod, HAProxy VM → app end-to-end reachability.
9. **Host-side setup** (sudo) — static routes for the Valkey IPs, `/etc/hosts` entry `<HAProxy VM IP> debug-demo.local`, and `sysctl net.inet.ip.forwarding=1` (so the HAProxy VM can route to the RD VM via the Mac). Idempotent.
10. **End-to-end smoke test** — runs `scripts/smoke-test.sh` (in-cluster + external + explicit MOVED tests for GET/SET, XADD, SPUBLISH).

Faster variants (use during iteration, not on a clean install):
```sh
scripts/install-stack.sh --skip-artifactory     # skip ~3-5 min Artifactory bootstrap
scripts/install-stack.sh --skip-build           # reuse an existing debug-demo-app:dev image
scripts/install-stack.sh --skip-image-preload   # skip up-front pulls (clean networks; lazy pulls instead)
scripts/install-stack.sh --image-manifest-only  # print the image list Phase 2 would pull, then exit
scripts/install-stack.sh --skip-haproxy-vm      # skip the F5 stand-in; hit RD node IP directly
scripts/install-stack.sh --skip-host-setup      # don't touch routes / /etc/hosts (no sudo)
scripts/install-stack.sh --skip-smoke           # don't run the final smoke-test
scripts/install-stack.sh --check                # just print what's installed; install nothing
```

The image list lives in one place — the `IMAGES` array at the top of
`scripts/preload-images.sh`, grouped by the phase that consumes each
image. When you bump a version in `install-stack.sh` or a chart's
`values.yaml`, update the matching line there. `--image-manifest-only`
prints the list for security review or air-gap mirror prep.

Expected tail of the output:
```
=== done ===
  L7 (HTTP) entry — Pattern D (external LB → hostNetwork ingress):
    http://debug-demo.local/  →  HAProxy VM @ 192.168.105.15  →  RD node :80  →  ingress-nginx → app
    HAProxy stats UI:   http://192.168.105.15:8404/

  L4 (TCP) entry — MetalLB per-pod Services (Valkey only; default = one shared IP, unique client port per node):
    valkey/valkey-primary-{0,1,2}-ext:   192.168.64.51:{6379,6380,6381}
    valkey/valkey-secondary-{0,1,2}-ext: 192.168.64.51:{6382,6383,6384}
```

### 5. Legacy: manual host-side setup (only if you passed `--skip-host-setup`)

install-stack.sh Phase 9 handles this automatically. If you deferred
it with `--skip-host-setup`, run these by hand.

#### 5a. Required — install Mac-side static routes (so Valkey IPs reach the cluster)

```sh
scripts/host-routes.sh add        # prompts for your sudo password once
```

What this does: adds 6 entries to your macOS routing table that say
"to reach the Valkey LB IP(s), send via the Rancher Desktop VM
(`192.168.64.2`)". The VM's kube-proxy iptables then DNATs each
incoming connection to the right Valkey pod. Without this step,
MetalLB-assigned Valkey IPs aren't reachable from your Mac because
of how vz-NAT handles ARP. (Not needed for HTTP — the HAProxy VM is
on Lima's shared subnet and reachable from the Mac directly.)

Verify:
```sh
scripts/host-routes.sh list
# Every line should end with: gw=192.168.64.2  iface=bridge100

curl -fsS http://debug-demo.local/actuator/health
# {"status":"UP","groups":["liveness","readiness"]}
```

In a real deployment the HAProxy VM is replaced by a real VIP/LB
(F5, NetScaler, cloud LB) in front of the cluster. The cluster
config itself doesn't change.

##### Why MetalLB is handing out the IPs at all

`Service type=LoadBalancer` is a *request* to k8s — something else has
to actually provision the external IP. On EKS/GKE/AKS the cloud
provider's controller does it. On bare-metal, on-prem, or dev
clusters (Rancher Desktop, kind, minikube), there's no such
controller by default and the Service sits in `<pending>` forever.
**MetalLB is the bare-metal implementation of that contract.**

In this POC MetalLB only handles the **Valkey** per-pod LBs —
six `LoadBalancer` Services which by default share ONE IP
(192.168.64.51, split by port 6379-6384 via MetalLB's
`allow-shared-ip`; legacy perPodIP mode uses .51-.56). The
HTTP path uses Pattern D (see below): ingress-nginx runs with
`hostNetwork=true` and an HAProxy VM (F5 stand-in) fronts the
node, so MetalLB is *not* in the HTTP path at all.

Across environments the Helm charts in this repo work unchanged.
What differs is *who fulfills* `type: LoadBalancer` and *how
external traffic enters* the ingress controller:

| Where this stack runs | Who fulfills `type=LoadBalancer` for Valkey | HTTP entry to ingress-nginx |
|---|---|---|
| Rancher Desktop / kind / minikube (this repo) | **MetalLB** (L2 mode) | Pattern D — HAProxy VM → node :80 hostNetwork |
| EKS / GKE / AKS | The cloud provider's CCM → ELB / GCP LB / Azure LB | Usually Pattern A (cloud LB → NodePort) or AWS ALB Ingress Controller |
| OpenShift / vSphere on-prem | Usually MetalLB; sometimes F5 BIG-IP CIS, Citrix CPX, AVI/NSX ALB | Pattern B if CIS is installed (F5 → pod IPs via BGP); Pattern D if hostNetwork |
| On-prem with separate VM/appliance LB (F5, NetScaler, haproxy-keepalived) | None, or MetalLB for non-HTTP | Pattern A, B, or D — depends on F5 integration |
| Bare-metal with BGP router | **MetalLB** in BGP mode (peers with the router) | Any pattern, but MetalLB on the ingress Service is also viable |

##### Four patterns for HTTP entry into ingress-nginx (A, B, C, D)

`type: LoadBalancer` answers *who allocates the IP*. A different
question — *how does an external LB actually reach the ingress
controller* — has four real-world answers. The pool members and
the binding point on the cluster side differ in each:

**Pattern A — External LB → NodePort.** F5 backend = all node IPs
on a high port (e.g. 32080). ingress-nginx Service is `type:
NodePort`. kube-proxy on the chosen node forwards to the
ingress-nginx pod.
- *Pros*: simple, works without any in-cluster controller.
- *Cons*: loses client source IP unless `externalTrafficPolicy:
  Local`; exposes a non-standard port on every node.

**Pattern B — External LB → pod IPs directly** (the cleanest
enterprise pattern). F5 backend = pod IPs of the ingress
controller, programmed dynamically by an in-cluster controller
(F5 BIG-IP CIS, Citrix CPX, AVI Operator) that watches Endpoints.
ingress-nginx Service is `type: ClusterIP` (F5 ignores it). F5
must have **L3 reachability to the pod network**, typically via
BGP peering with the CNI (Calico/Cilium).
- *Pros*: no kube-proxy hop, real source IPs, real health checks
  against actual pods, scales with pod replicas automatically.
- *Cons*: requires F5 CIS (extra in-cluster controller) plus pod-
  network reachability (network team coordination).

**Pattern C — External LB → LoadBalancer IP** (two LB layers,
usually transitional). F5 backend = one IP that itself was
allocated by something inside the cluster (MetalLB, cloud CCM, or
F5 CIS as a `loadBalancerClass`). Stacks two LB layers.
- *Pros*: useful when migrating from MetalLB-only to F5-in-front
  without changing chart values.
- *Cons*: extra hop with no value-add at steady state.

**Pattern D — External LB → node IPs on :80, hostNetwork ingress**
(what this POC uses). F5 backend = all node IPs on standard 80/443.
ingress-nginx pod runs with `hostNetwork: true` and binds the
node's port 80 directly — Service is bypassed entirely.
- *Pros*: standard ports (no NodePort weirdness), simple to model
  in an F5 pool, no extra in-cluster controllers needed, real
  source IPs.
- *Cons*: ingress controller can't share a node with anything else
  needing :80; usually deployed as a DaemonSet so exactly one pod
  per node owns the port.

To detect which pattern an existing cluster uses, see CLAUDE.md →
"Four patterns for how external LB traffic reaches in-cluster
ingress-nginx" for the diagnostic decision table.

##### How this POC implements Pattern D

Two pieces of moving machinery vs. the "MetalLB in front of
ingress-nginx" version that came before:

1. **ingress-nginx runs with `controller.hostNetwork=true`**. The
   controller pod is bound directly to port 80 on the Rancher
   Desktop VM (192.168.64.2). No LoadBalancer Service. The Service
   still exists for cluster-internal lookups but external traffic
   never touches it.

2. **A second Lima VM** runs HAProxy as the F5 stand-in. The VM
   gets its own IP (e.g. 192.168.105.7 on Lima's shared subnet),
   reachable from the Mac. HAProxy's backend points at the RD VM's
   :80 where ingress-nginx is listening. The install script enables
   Mac IP forwarding (sysctl) so the HAProxy VM (on its own subnet)
   can route to the RD VM (on bridge100) via the Mac.

```
You (curl http://debug-demo.local) → HAProxy VM :80 → RD VM :80
       ↑                                ↑                ↑
       /etc/hosts: debug-demo.local =   F5 stand-in    ingress-nginx
       <HAProxy VM IP>                                 pod (hostNetwork)
                                                          ↓
                                                       app ClusterIP → app pod
```

In production, swap "Lima VM running HAProxy" for "F5 BIG-IP
appliance on the corporate LAN" and "Mac IP forwarding" for
"actual L3 routing between F5 and node subnets." The k8s side is
identical.

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
scripts/smoke-test.sh
```

Expected output: **22 PASS / 0 FAIL**. Each line tells you which subsystem
it exercised. Non-zero exit code = the count of failures, and each failure
line shows you exactly which check broke (e.g., "IBM MQ DEV.QUEUE.1
CURDEPTH grew by 1" → MQ producer broken; "cluster-announce-ip points
at external LB IPs" → Valkey topology broken).

### 7. Use it

Two equivalent paths once everything is up:

```sh
# From the Mac (through Pattern D: HAProxy VM → hostNetwork ingress → app)
BASE=http://debug-demo.local
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
| `curl http://debug-demo.local/...` times out | `/etc/hosts` entry missing, or HAProxy VM not running. Check: `grep debug-demo.local /etc/hosts` and `limactl list \| grep debug-demo-haproxy`. Re-run `scripts/install-stack.sh` to auto-fix |
| HTTP path works but slow / connection refused | Mac IP forwarding disabled. Fix: `sudo sysctl -w net.inet.ip.forwarding=1` |
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

## External access (per-service-per-pod LB, one shared IP split by port)

Production-shape topology. Every Valkey pod has its own `LoadBalancer`
Service (per-shard addressability is non-negotiable — MOVED redirects
must land on exactly one node), but by default all six Services **share
a single MetalLB IP** (`metallb.universe.tf/allow-shared-ip`) and are
distinguished by **port**: client `6379-6384`, bus `16379-16384`. Each
pod announces its shared IP + unique port via
`cluster-announce-{ip,port,bus-port}`, so `CLUSTER SHARDS`/`CLUSTER
NODES` return externally-resolvable endpoints (not pod IPs). This is
the same shape as an enterprise F5 setup where the security team
allocates **one VIP per app** and the pool members differ by port.

With the full install (F5 stand-in provisioned), clients dial the
**HAProxy VM IP** — the pods announce it, so MOVED redirects name it too
(two-layer). With `--skip-haproxy-vm`, clients dial the MetalLB IP
directly (one-layer):

| Endpoint | Full install (two-layer) | `--skip-haproxy-vm` (one-layer) | Backed by |
|---|---|---|---|
| App (HTTP) | `http://debug-demo.local/` via HAProxy VM | RD node :80 directly | hostNetwork ingress-nginx → app ClusterIP |
| Valkey primary-0 | `<haproxy-vm-ip>:6379` | `192.168.64.51:6379` | `valkey-primary-0-ext` Service → just that pod |
| Valkey primary-1 | `<haproxy-vm-ip>:6380` | `192.168.64.51:6380` | `valkey-primary-1-ext` |
| Valkey primary-2 | `<haproxy-vm-ip>:6381` | `192.168.64.51:6381` | `valkey-primary-2-ext` |
| Valkey secondary-0 | `<haproxy-vm-ip>:6382` | `192.168.64.51:6382` | `valkey-secondary-0-ext` |
| Valkey secondary-1 | `<haproxy-vm-ip>:6383` | `192.168.64.51:6383` | `valkey-secondary-1-ext` |
| Valkey secondary-2 | `<haproxy-vm-ip>:6384` | `192.168.64.51:6384` | `valkey-secondary-2-ext` |

(The HAProxy VM IP is cached at `dumps/haproxy-vm-ip`.)

The legacy shape — one pinned IP per pod (`192.168.64.51-56`, all on
`:6379`) — is still available via
`--set loadBalancer.mode=perPodIP` on the valkey chart. Two caveats
specific to the shared-IP mode:

- **`externalTrafficPolicy` must be `Cluster`.** MetalLB only lets
  `Local`-policy Services share an IP when their pod selectors are
  identical; ours deliberately select one pod each. `Cluster` policy
  costs source-IP preservation, which doesn't matter for Valkey.
- **Ports are Service-level, not pod-level.** Every pod still listens
  on 6379/16379 internally; the per-Service external port maps back to
  the same targetPort. Only the announce values differ per pod.

### Production: F5 VIP in front, no CIS (two-layer)

Our production target is an F5 that is **not** integrated with the
cluster (no F5 CIS controller). The F5 VIP forwards to the in-cluster
LB IP — two LB layers, exactly like the HTTP path in this POC where
the HAProxy VM (F5 stand-in) fronts the cluster. The chart supports
this with one value:

```sh
# Service IP stays whatever MetalLB (or any in-cluster controller)
# assigns; the pods ANNOUNCE the F5 VIP instead — because cluster
# metadata (CLUSTER NODES / CLUSTER SHARDS / MOVED redirects) must
# name the address CLIENTS dial, and clients dial the VIP.
helm upgrade valkey ./charts/valkey -n valkey \
  --set loadBalancer.sharedIP=<metallb-ip> \
  --set loadBalancer.announceIP=<f5-vip>
```

When `announceIP` is unset the pods announce `sharedIP` — the
one-layer shape where clients dial the MetalLB IP directly. **The full
install rehearses the two-layer shape**: `install-stack.sh` sets
`announceIP` to the HAProxy VM's IP and enables the chart's dev VIP
shim (below), so every MOVED redirect names the F5 stand-in and
external clients genuinely traverse it.

F5 configuration requirements for the two-layer shape:

1. **Ports forward 1:1.** Client `6379-6384` and bus `16379-16384` on
   the VIP must map to the same port numbers on the backend (the
   MetalLB IP). No port rewriting — the announced ports must be the
   ports clients actually reach.
2. **Plain L4 TCP passthrough** (fastL4 / standard TCP profile). The
   Valkey wire protocol is stateful TCP; no L7 inspection or TLS
   termination in the path.
3. **The bus ports must be open on the VIP.** Valkey nodes gossip
   with each other using the *announced* addresses. kube-proxy
   short-circuits traffic addressed to the Service IP, but it knows
   nothing about the F5 VIP — so node-to-node gossip genuinely leaves
   the cluster, hits the F5 on `16379-16384`, and comes back. If the
   F5 blocks those ports, the cluster degrades to
   `cluster_state:fail`. Budget for that hairpin traffic on the VIP.
4. **SNAT automap is fine.** Valkey sees the F5's address as the
   client — same trade-off as `externalTrafficPolicy: Cluster`,
   functionally harmless.

#### Dev-only VIP shim (`devVipShim` in the valkey chart)

Requirement 3 needs the k8s nodes to be able to DIAL the VIP — true on
any corporate LAN, false on Rancher Desktop: Apple's vz NAT refuses to
forward VM-to-VM traffic between the RD subnet (192.168.64.x) and the
Lima shared subnet (192.168.105.x), so pods can never reach the HAProxy
VM. The chart's `devVipShim` restores the prod property without touching
RD internals: a hostNetwork DaemonSet adds the VIP as a /32 on the
node's loopback and runs a tiny HAProxy that listens on
`VIP:<client+bus ports>`, forwarding to the in-cluster `valkey-*-ext`
Services. From inside the cluster the VIP resolves on-node; from the
Mac and anything external it is still the real HAProxy VM. Gossip
functionally hairpins through the shim instead of the real VM — in prod
it hairpins through the real F5. **Never enable this in prod** — there
the VIP is genuinely reachable and the shim would mask it.

In a real environment the shared IP is reached through a VIP/LB layer
(F5/HAProxy/cloud NLB). On Rancher Desktop's vz-NAT, the dev-Mac
stand-in for that VIP is a one-time `sudo route add` (one route in
shared mode, six in perPodIP mode). The `scripts/host-routes.sh add`
helper installs them by discovering the LB-assigned IPs at runtime and
deduplicating; `scripts/host-routes.sh remove` tears down.
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
