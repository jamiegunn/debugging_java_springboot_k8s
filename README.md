# debugging_java_springboot_k8s

A Spring Boot 3.3 / Java 25 service with Oracle + IBM MQ + Valkey,
deployable to Kubernetes via independent Helm charts. The primary goal
of the repo is the **debug tooling layer** in `scripts/` — kubectl-driven
tools for grabbing thread/heap dumps and toggling Logback levels at
runtime without restarting the pod.

The stack runs on a **purpose-built 3-node k3s cluster on Lima VMs**
(1 tainted control-plane server + 2 worker agents), fronted by a
**dedicated load-balancer VM** (`ddk3s-lb`, the F5/NetScaler stand-in)
that owns a **keepalived VIP** and HAProxy-pools to the workers. The
stack is addressed entirely **by hostname** and fed from a **fully
air-gapped image bundle** (nothing pulls from inside a VM or pod). The
full design reference is
[`docs/k3s-architecture.md`](docs/k3s-architecture.md); the front door is
`scripts/k3s.sh`.

## Layout

| Path | Purpose |
|------|---------|
| `app/` | Spring Boot service (Maven). CRUD API for `Customer` + `Order`, MQ producer/consumer, Spring Batch CSV loader. |
| `charts/debug-demo-app/` | Helm chart for the app. ClusterIP Service + Ingress; external traffic enters via ingress-nginx behind the VIP. |
| `charts/oracle/` | Helm chart for Oracle Database Free. |
| `charts/ibm-mq/` | Helm chart for IBM MQ. |
| `charts/artifactory/` | Helm chart for JFrog Artifactory OSS (local Docker + Helm registry). |
| `charts/valkey/` | Valkey 8 — 6-node cluster (3 primaries + 3 secondaries). Each pod listens on its own unique client port (6379-6384) and announces its **pod IP + port** for gossip/replication (direct pod-to-pod) while clients get **hostname endpoints** (`valkey.debug-demo.local:<port>`) via `cluster-announce-hostname`. |
| `scripts/` | Debug + ops tools. `k3s.sh` is the single front door; `k3s-*.sh` are the phase scripts; `bundle-images.sh` builds the air-gap bundle. See "Debug tooling" below. |
| `scripts/lib/k3s-env.sh` | Central config for the whole k3s stack (VM sizes, hostnames, image list, versions) — override via env. |
| `docs/k3s-architecture.md` | Full design reference: topology, VIP/DNS, air-gap, the hostname Valkey model. |
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

Reachable through the same nginx-ingress that serves the API, no extra
config. Set `springdoc.show-actuator: true` in `application.yml` to also
document the actuator endpoints.

## Local dev

Run Oracle + MQ standalone (the simplest way is the Helm charts against
the k3s cluster — see below). Then:

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
(a Valkey outage fails order creation *after* DB+MQ succeeded — deliberate),
and a **cluster-slot proof** that the `{customerId}` hash-tag pinning
actually co-locates keys (real CRC16 slot math in `ValkeyKeysTest`).

Cluster-protocol tests run against the live stack, not in JUnit — 58
checks, each narrating why it runs / what it proves / how it fails. All
client ops go **by hostname, in-cluster** (`kubectl exec` so names resolve
via CoreDNS); `MIGRATE` targets the pod IP because the pod→VIP→HAProxy
hairpin times out:

```sh
scripts/valkey-cluster-tests.sh              # topology, slot routing, MOVED,
                                             # ASK (live slot migration), replica
                                             # reads, pub/sub, failover + failback
scripts/valkey-cluster-tests.sh --skip-failover   # non-disruptive subset
scripts/valkey-cluster-tests.sh --no-commands     # hide the echoed commands
```

By default every check echoes the underlying `kubectl` / `curl` /
`valkey-cli` command (with concrete resolved values), so you always see
what was run and the suite doubles as a runnable cookbook. Pass
`--no-commands` to hide them. For Valkey commands,
`export PASS=$(kubectl -n valkey get secret valkey -o jsonpath='{.data.password}' | base64 -d)`
first to make the printed commands directly runnable.

### Chaos: break things and diagnose them

`scripts/k3s.sh chaos` (a wrapper over `scripts/k3s-chaos.sh`) injects one
failure at a time so you can investigate:

```sh
scripts/k3s.sh chaos status              # what's up right now: VMs, VIP owner, nodes
scripts/k3s.sh chaos node-down agent-1   # stop a VM — pods reschedule onto survivors
scripts/k3s.sh chaos lb-down             # stop the LB VM — VIP + access down (SPOF drill)
scripts/k3s.sh chaos valkey-freeze       # freeze a primary — real election (self-heals)
scripts/k3s.sh chaos heal                # restore everything
```

`node-down` has been validated live — Valkey stayed `cluster_state:ok`
through the outage while pods rescheduled.

## Getting started (from a clean macOS install)

This section assumes **nothing**: no Homebrew, no cluster running. The
whole stack is built and installed from the Mac; the k3s VMs and their
pods never reach the internet (air-gapped), so the Mac (which has internet
or a corporate mirror) builds an image bundle first, then hands it in.

`./tui install` runs a **pre-flight** (`scripts/k3s-preflight.sh`) as its
very first step, so you can realistically just run `./tui install` on a
clean Mac. Pre-flight is idempotent and checks + auto-fixes the Mac
prerequisites — Homebrew, the CLI tools (`limactl`/`kubectl`/`helm`/
`curl`), **sudo/admin access** (the sudoers + resolver need it),
**`socket_vmnet`** (the backend for Lima's `shared` network), the **Lima
sudoers** entry (`/etc/sudoers.d/lima`, which `limactl sudoers --check`
also validates the shared network against), **k3s + images** (the air-gap
bundle offline, or Docker + `github.com` reachable to build it — where a
corporate proxy/MITM bites first), and RAM — printing the exact fix
command for anything it can't safely do itself. socket_vmnet + Lima
sudoers used to be a manual step; pre-flight now handles them. Run it
standalone any time with `./tui preflight`.

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

### 1. Install the toolchain

You can skip this section — `./tui install`'s pre-flight installs these for
you (via Homebrew) and configures socket_vmnet + Lima sudoers. It's listed
here so you know what the stack depends on. The install needs `limactl`
(VMs), `kubectl`, `helm`, `docker` (only to build the air-gap bundle), and
`curl`:

```sh
brew install lima kubernetes-cli helm curl
brew install --cask docker            # Docker Desktop — used only to build the bundle
brew install valkey                   # optional: valkey-cli for hands-on cluster tests
brew install stern                    # optional: prettier multi-pod log tailing
```

Verify:
```sh
limactl --version
kubectl version --client --short
helm version --short
docker info | head -1                  # Docker daemon must be running for the bundle build
```

### 2. Clone this repo

```sh
git clone https://github.com/<your-org>/debugging_java_springboot_k8s.git
cd debugging_java_springboot_k8s
```

### 3. Bring the stack up

`scripts/k3s.sh` is the single front door (or run **`./tui`** from the repo
root for an interactive menu over everything — bare `./tui` opens the menu,
`./tui <cmd>` forwards to the same commands below). One command pre-flights
the Mac, builds the air-gap bundle, creates the VMs, installs k3s, wires DNS,
deploys ingress-nginx and every chart, stands up the LB tier, and
smoke-tests it:

```sh
./tui install            # or: scripts/k3s.sh install
```

What `install` chains (orchestrated by `scripts/k3s-install.sh`):

1. **Pre-flight** — `scripts/k3s-preflight.sh` checks + auto-fixes the Mac
   prerequisites (Homebrew, CLI tools, sudo/admin access, socket_vmnet, Lima
   sudoers + shared network, k3s+images present-or-reachable, RAM) so the
   install can't fail obscurely deep inside VM creation.
2. **Bundle** — `scripts/bundle-images.sh` runs on the Mac: `docker pull`
   + `docker save` every third-party image (list = `K3S_IMAGES` in
   `scripts/lib/k3s-env.sh`), builds + saves the app image, and downloads
   the k3s binary + `k3s-airgap-images-<arch>.tar.zst`. Everything lands
   in `dumps/airgap/`. (Already have a bundle? `scripts/k3s.sh install`
   reuses it; build one explicitly with `scripts/k3s.sh bundle`.)
3. **VMs + k3s** (`k3s-cluster.sh`) — creates 3 Lima VMs (`ddk3s-server`,
   `ddk3s-agent-1`, `ddk3s-agent-2`) on Lima's `shared` network
   (`192.168.105.0/24`), copies the bundle into each, installs k3s
   v1.31.5 with `INSTALL_K3S_SKIP_DOWNLOAD=true`, and
   `k3s ctr images import`s every tar into containerd. The server is
   installed with `--node-taint node-role.kubernetes.io/control-plane=true:NoSchedule`,
   so all workloads land on the two agents. A pod that tried to pull would
   fail — which is the point.
4. **DNS** (`k3s-net.sh`) — dnsmasq on the server node for
   `*.debug-demo.local`, a CoreDNS stub so pods resolve the same
   hostnames, and the Mac `/etc/resolver` — all answering to the VIP.
   This script is DNS-only; the VIP itself is served by the LB tier below.
5. **Platform** (`k3s-platform.sh`) — ingress-nginx as a hostPort
   DaemonSet (on the agents), namespaces, and `local-path` storage.
6. **Charts** (`k3s-charts.sh`) — Oracle, IBM MQ, Valkey, and the app
   (Artifactory is optional — only for the `scripts/local-ci.sh`
   in-cluster registry loop — and is skipped by default).
7. **LB tier** (`k3s-lb.sh`) — creates the `ddk3s-lb` VM running keepalived
   (owns the VIP `192.168.105.100`) + HAProxy (pools HTTP `:80` to the
   agents' ingress and Valkey TCP `:6379-6384` to each shard's MetalLB IP).
   Runs last, since it pools to the ingress + Valkey that must already exist.
8. **Smoke** — `scripts/k3s-smoke.sh` (14 checks, all by hostname).

The kubeconfig is written to `dumps/k3s.kubeconfig`;
`scripts/lib/common.sh` auto-points every script's `kubectl` at it, so
you don't have to export `KUBECONFIG`.

Other `scripts/k3s.sh` subcommands (all also reachable as `./tui <cmd>`):

```sh
scripts/k3s.sh              # (no args) open the interactive TUI — same as ./tui
scripts/k3s.sh preflight    # check + auto-fix Mac prerequisites (socket_vmnet, sudoers, tools, RAM)
scripts/k3s.sh bundle       # (re)build the air-gap image bundle on the Mac
scripts/k3s.sh install      # full install (preflight → bundle → VMs → k3s → DNS → ingress → charts → LB → smoke)
scripts/k3s.sh lb           # the LB tier VM (ddk3s-lb): keepalived VIP + HAProxy (up/down/status)
scripts/k3s.sh resolver     # write the Mac /etc/resolver so hostnames resolve (sudo; optional)
scripts/k3s.sh doctor       # one-shot health check across EVERY layer (start here if broken)
scripts/k3s.sh smoke        # 14-check end-to-end verification, all by hostname
scripts/k3s.sh status       # VMs + VIP owner + nodes
scripts/k3s.sh chaos ...    # inject failures (node-down, lb-down, valkey-freeze, ...)
scripts/k3s.sh tour         # narrated API walk-through (api-tour.sh)
scripts/k3s.sh valkey       # the Valkey cluster from outside (valkey-tour.sh)
scripts/k3s.sh uninstall    # delete the VMs, resolver, kubeconfig
```

#### If the VIP is already taken

The VIP defaults to `192.168.105.100`, which lives inside the Lima shared
network's DHCP range — it is **not reserved**. The LB tier pre-flights it:
if another device on the segment already holds it, `k3s-lb.sh` aborts with
the exact fix. Pick a free address and install with it — the value **persists**
(to `dumps/k3s-vip`) so every later `doctor`/`smoke`/`tui`/chart command agrees
on it without re-exporting:

```sh
# find a free one
for i in 200 210 220 230 240 250; do
  ping -c1 -t1 192.168.105.$i >/dev/null 2>&1 || echo "192.168.105.$i is free"; done
# install with it (sticks for all later commands)
K3S_VIP=192.168.105.240 ./tui install
```

### 4. Resolve hostnames from the Mac (optional)

Everything is addressed by hostname. Inside the cluster, pods resolve
`*.debug-demo.local` via a CoreDNS stub. From the **Mac** you have two
choices:

- **`curl --resolve`** — the smoke/test scripts already use this, so no
  setup is needed to run them:
  ```sh
  curl --resolve debug-demo.local:80:192.168.105.100 \
    http://debug-demo.local/actuator/health
  ```
- **`/etc/resolver`** — for plain `curl http://debug-demo.local/...` (and
  browser use), write a macOS resolver entry pointing at the server VM's
  dnsmasq (needs sudo, one-time):
  ```sh
  scripts/k3s.sh resolver
  ```

### 5. Verify end-to-end

```sh
scripts/k3s.sh doctor    # checks every layer (tooling → VMs → nodes → VIP →
                         # DNS → ingress → workloads + air-gap → Valkey → e2e)
                         # and prints the exact fix command for anything broken
scripts/k3s.sh smoke     # 14 checks, all by hostname
```

`doctor` is the place to start whenever something looks wrong: it walks
every layer bottom-up and, for each failure, prints the command that fixes
it. (The one non-fatal item it may flag is the optional Mac `/etc/resolver`
from step 4.)

### 6. Use it

```sh
# From the Mac — HTTP enters through the VIP (on ddk3s-lb) → HAProxy →
# the agents' ingress-nginx → app.
# With the /etc/resolver entry (step 4) plain curl works:
BASE=http://debug-demo.local
curl $BASE/actuator/health
curl -X POST $BASE/api/customers \
  -H 'Content-Type: application/json' \
  -d '{"name":"Alice","email":"alice-1@example.com"}'

# Without /etc/resolver, resolve explicitly:
curl --resolve debug-demo.local:80:192.168.105.100 $BASE/actuator/health

# From inside the cluster (always works)
POD=$(kubectl -n debug-demo get pod -l app.kubernetes.io/name=debug-demo-app \
       -o jsonpath='{.items[?(@.status.containerStatuses[0].ready==true)].metadata.name}' | awk '{print $1}')
kubectl -n debug-demo exec $POD -- curl -s http://localhost:8080/actuator/health
```

See **API** (above) for every endpoint and **CLAUDE.md** for the full
runbook (logs, memory triage, dump capture without JDK tools).

### 7. Tear down

```sh
scripts/k3s.sh uninstall    # delete all 4 VMs (3 k3s + ddk3s-lb), the Mac /etc/resolver entry, and the kubeconfig
```

### Troubleshooting

| Symptom | Likely cause + fix |
|---|---|
| Anything looks broken | Run `scripts/k3s.sh doctor` first — it pinpoints the failing layer and prints the fix command |
| `kubectl` can't reach the cluster | Kubeconfig is at `dumps/k3s.kubeconfig`; the scripts auto-target it. For raw `kubectl`, `export KUBECONFIG=$PWD/dumps/k3s.kubeconfig` |
| VMs won't start / wrong sizes | `limactl list` shows the 4 `ddk3s-*` VMs (server, agent-1, agent-2, lb); sizes come from `scripts/lib/k3s-env.sh` |
| `curl http://debug-demo.local/...` fails from the Mac | Missing resolver — either run `scripts/k3s.sh resolver` or use `curl --resolve debug-demo.local:80:192.168.105.100 ...` |
| A pod is `ImagePullBackOff` | The air-gap bundle is missing that image — rebuild with `scripts/k3s.sh bundle` (add the ref to `K3S_IMAGES` in `scripts/lib/k3s-env.sh` if new) |
| Stale `/etc/hosts` line for `debug-demo.local` | Left over from an older setup — remove it by hand; the k3s flow does not write `/etc/hosts` |
| Oracle pod in CrashLoopBackOff | gvenzl image PVC seeding — the chart's `seed-oradata` initContainer handles it; see `~/.claude/projects/.../memory/k8s_gotchas.md` |

## Architecture

### Cluster topology (4 VMs, one L2 segment)

```
                          Mac (192.168.105.1 on the shared subnet)
                                     │  resolves *.debug-demo.local via dnsmasq
                                     │  reaches the VIP directly (same L2)
                                     ▼
                    ┌──────────────────────────────────┐
                    │ ddk3s-lb   (1 cpu / 1 GiB)        │  ← F5/NetScaler stand-in
                    │ keepalived  — owns VIP .100       │
                    │ HAProxy     — :80 → agents' ingress
                    │               :6379-6384 → MetalLB│
                    └──────────────┬───────────────────┘
                                   │  pools to the WORKER agents only
        ┌──────────────────────────┼──────────────────────────┐
   ┌────┴─────────┐      ┌──────────┴────────┐     ┌───────────┴───┐
   │ ddk3s-server │      │  ddk3s-agent-1    │     │ ddk3s-agent-2 │
   │ k3s server   │      │  k3s agent        │     │ k3s agent     │
   │ control-plane│      │  worker           │     │ worker        │
   │ TAINTED —    │      │  ingress, MetalLB,│     │ ingress, MetalLB,
   │ NoSchedule   │      │  app, Oracle, MQ, │     │ app, Oracle, MQ,
   │ dnsmasq      │      │  Valkey           │     │ Valkey        │
   │ 3 GB / 2 cpu │      │  7 GB / 3 cpu     │     │ 7 GB / 3 cpu  │
   └──────────────┘      └───────────────────┘     └───────────────┘
```

All 4 VMs **and the Mac** sit on Lima's `shared` network (socket_vmnet,
`192.168.105.0/24`) — one L2 segment. That directness is the whole point:
the VIP is reachable from the Mac and from every pod with no NAT, no
static routes. See
[`docs/k3s-architecture.md`](docs/k3s-architecture.md) for the full
rationale.

Key pieces:

- **The LB tier is a separate VM** (`ddk3s-lb`, managed by
  `scripts/k3s-lb.sh up/down/status`) — the "external VIP → backend pool
  of cluster nodes" model. **keepalived** owns the VIP
  `192.168.105.100` here, **independent of cluster-node health**: a
  thrashing k3s node can't drag the VIP down with it (the outage that
  drove this change). It self-daemonizes (`keepalived --use-file=...`)
  and holds the VIP by VRRP priority — no ingress health-track script.
  **HAProxy** fronts HTTP (`:80`, health-checked, so it routes around a
  starved/down node) and Valkey TCP (`:6379-6384`). Both pool to the
  **worker agents only** — the control-plane node is tainted, so ingress
  runs there only on the agents and MetalLB never ARP-announces there.
- **The control-plane server is tainted** (`node-role.kubernetes.io/control-plane=true:NoSchedule`),
  so ALL workloads (app, Oracle, MQ, Valkey, ingress-nginx DaemonSet,
  MetalLB speaker) run on the two worker agents; the small 3 GiB server
  runs only in-process k3s components. Without the taint the app JVM
  starved the server.
- **flannel host-gw** backend (not VXLAN — VXLAN's tx-checksum-offload bug
  drops UDP on nested VMs and breaks cluster DNS), pinned with
  `--flannel-iface=lima0`.
- **MetalLB (L2/ARP mode)** fulfills `type: LoadBalancer` Services (k3s's
  built-in klipper/servicelb is disabled) — each shard gets its own IP from a
  pool, ARP-announced from the agents only (no shared-IP annotations, no per-pod
  IPs); HAProxy on the LB tier maps each external port to that shard's MetalLB IP.

### DNS — everything is a hostname

`APP_HOST=debug-demo.local`, `VALKEY_HOST=valkey.debug-demo.local` (both in
`scripts/lib/k3s-env.sh`).

| Consumer | Resolves via | To |
|---|---|---|
| Mac (`curl`, `valkey-cli`) | `/etc/resolver/debug-demo.local` → dnsmasq on the server VM (or `curl --resolve`) | VIP |
| Pods (app, Valkey gossip) | CoreDNS custom stub (the `template` plugin answers the zone directly) | VIP |
| Valkey `MOVED` / `CLUSTER SHARDS` | Valkey announces a **hostname**, not an IP | `valkey.debug-demo.local:<port>` |

The CoreDNS stub answers the zone directly rather than forwarding to host
dnsmasq, because pod → node-shared-IP UDP fails. No Mac static routes and
no `/etc/hosts` writes are involved.

### HTTP path

```
client → debug-demo.local → VIP 192.168.105.100 (on ddk3s-lb)
       → HAProxy :80 → agents' ingress-nginx (hostPort DaemonSet)
       → app ClusterIP → app pod
```

The ingress-nginx controller runs as a DaemonSet with
`controller.hostPort.enabled` and `service.type=ClusterIP`, so exactly one
pod per agent binds :80/:443 on the host. HAProxy on the LB VM
health-checks the agents' ingress and routes around a down/starved one, so
the VIP (held by keepalived on that same LB VM) is always a live front door.

### Air-gap: no image ever pulled inside a VM or pod

`scripts/bundle-images.sh` (on the Mac) produces a self-contained bundle in
`dumps/airgap/`: `docker save` of every third-party image in `K3S_IMAGES`,
the built app image, and the k3s binary + `k3s-airgap-images-<arch>.tar.zst`.
`scripts/k3s-cluster.sh` copies the bundle into each VM, installs k3s with
`INSTALL_K3S_SKIP_DOWNLOAD=true`, and imports every tar into containerd.
Charts run `imagePullPolicy: Never`/`IfNotPresent` — a pod that tried to
pull would fail, which proves nothing reaches out.

## Valkey topology (the hostname cluster)

`charts/valkey` ships a 6-node Valkey 8 cluster: 3 primaries (StatefulSet
`valkey-primary`) and 3 secondaries (StatefulSet `valkey-secondary`), with
explicit by-index pairing — `valkey-secondary-N` replicates
`valkey-primary-N` — which makes failover scenarios predictable in the
debug scripts.

The subtle part is how addresses work:

- **Each pod listens on its own unique port**: client `6379+idx`
  (primary-0 = 6379 … secondary-2 = 6384), bus `16379+idx`. It announces
  its **pod IP + those ports**, so **gossip and replication run direct
  pod-to-pod on the CNI network** — the VIP and MetalLB are out of the bus
  path. (That is what makes replica joins reliable; announcing the VIP
  used to hang them.)
- **Clients get hostname endpoints**: `cluster-announce-hostname` +
  `cluster-preferred-endpoint-type hostname`, so `CLUSTER SHARDS` / `MOVED`
  return `valkey.debug-demo.local:<port>` → VIP → HAProxy → MetalLB IP → the
  owning pod (each pod has a per-pod `LoadBalancer` Service, fulfilled by
  MetalLB with its own pool IP, whose `targetPort` is that pod's unique client
  port; only the client port is exposed — the bus stays pod-to-pod). Per-shard
  addressability comes from the **port**.
- **`MIGRATE` targets the pod IP**, not the hostname: MIGRATE opens a
  node→node connection and the pod→VIP→HAProxy hairpin times out (IOERR) —
  the same VIP-hairpin limit that keeps the bus pod-to-pod.
- **The app pins `valkey.debug-demo.local → VIP`** via `hostAliases` in its
  Deployment, because Lettuce/netty's resolver mishandles Kubernetes
  `ndots:5` search-domain expansion (getent resolves it, netty throws
  `UnknownHostException`).

### Investigating the cluster

`scripts/valkey-tour.sh` (or `scripts/k3s.sh valkey`) walks the topology,
every op type, `INFO`, and latency — all by hostname, with `valkey-cli` run
in-cluster so names resolve via CoreDNS:

```sh
scripts/k3s.sh valkey                          # full read-only tour
scripts/valkey-tour.sh --section pubsub        # just one section
```

The app uses Valkey via Spring Cache: `@Cacheable("customers")` on
`CustomerService.findById`, `@CacheEvict` on `update` / `delete`, plus the
same for `OrderService`. TTLs: customers 10 min, orders 2 min, default 5
min — configurable in `ValkeyCacheConfig`.

```sh
POD=$(kubectl -n debug-demo get pod -l app.kubernetes.io/name=debug-demo-app -o jsonpath='{.items[0].metadata.name}')
kubectl -n debug-demo exec $POD -- curl -s http://localhost:8080/api/customers/1   # DB hit
kubectl -n debug-demo exec $POD -- curl -s http://localhost:8080/api/customers/1   # cache hit
kubectl -n debug-demo logs $POD --tail=50 | grep 'DB hit'
PASS=$(kubectl -n valkey get secret valkey -o jsonpath='{.data.password}' | base64 -d)
kubectl -n valkey exec valkey-primary-0 -- valkey-cli -a $PASS --scan --pattern 'customers::*'
```

## Debug tooling

All scripts default to namespace `debug-demo` and selector
`app.kubernetes.io/name=debug-demo-app`. Override with `-n` / `-l`. The
runtime image is JRE-only (`eclipse-temurin:25-jre-alpine`) — no JDK is
baked in. **See CLAUDE.md for the three-tier capture story
(actuator → jattach → JDK ephemeral container).**

```sh
# Logs + log-level toggle
scripts/tail-logs.sh                                    # multi-replica log stream, prefers stern
scripts/set-log-level.sh com.example.debugdemo DEBUG    # runtime log-level via /actuator/loggers

# Memory triage — heap vs everything else, reconciled to container RSS
scripts/memory-report.sh                                # one-shot table (cgroup + actuator)

# JVM dumps — preferred path is actuator-only, no JDK tools in the pod
scripts/dump-jattach.sh install                         # one-time install of jattach into the pod
scripts/dump-jattach.sh threads                         # Thread.print via jattach
scripts/dump-jattach.sh heap --confirm                  # jmap-equivalent dump (pauses JVM)
scripts/dump-jattach.sh jcmd "GC.heap_info"             # any jcmd-style command

# Fallback path — kubectl debug with an ephemeral JDK container (last resort)
scripts/dump-threads.sh                                 # ./dumps/threads/<pod>-thread-*.txt
scripts/dump-heap.sh --confirm                          # ./dumps/heap/<pod>-heap-*.hprof

# In-cluster CI loop against the local Artifactory
scripts/local-ci.sh                                     # build app image, push image + charts
```

Why three capture paths exist (actuator, jattach, kubectl-debug + JDK):
the runtime image deliberately ships no JDK tools, so any "give me a thread
dump" workflow has to either (a) go through actuator endpoints the JRE
already serves, (b) install a tiny static binary like jattach into the pod
on demand, or (c) attach a JDK ephemeral container with
`shareProcessNamespace: true`. CLAUDE.md walks through when to reach for
each.

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

## Horizontal pod autoscaling

The app chart ships an HPA enabled by default: 1 → N replicas, target 20%
CPU utilization (relative to the `requests.cpu` of 50m, so it scales out as
soon as a pod is doing ~10 millicores of work). The chart default is
`maxReplicas: 10`, but on this two-agent footprint `k3s-charts.sh` **caps it
at 4** (via `--set`) so the fleet fits the two 7 GiB agents; bump it back up
on a bigger cluster. Scale-up is aggressive — up to 4 new pods per minute or
100% of current count, whichever is greater. Scale-down has a 180s
stabilization window to avoid thrashing.

Two tuning notes for the small footprint: the pods carry a soft
**pod-anti-affinity** (`spreadAcrossNodes`, on by default) so replicas spread
across the agents, and a **`startupProbe`** (≈200s: 40 × 5s) gates
liveness/readiness so a slow JVM boot under CPU contention isn't
liveness-killed into a CrashLoop.

On heap sizing: the app sets `resources.limits.memory: 1Gi`, and
`-XX:MaxRAMPercentage=75` (with `-XX:+UseContainerSupport`) sizes the heap
to ~0.73 GiB **against that container limit, not the node** — the JVM reads
the cgroup limit, so the node's total RAM is irrelevant here.

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
deployment strategy must be `RollingUpdate` (not `Recreate`) for HPA to add
pods without taking the existing one down — the chart defaults to the right
setting.

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

The `charts/artifactory` chart installs JFrog Container Registry (JCR) into
the local cluster, with a bundled PostgreSQL StatefulSet (modern
Artifactory requires Postgres — Derby support was removed). A post-install
Job patches Artifactory's system configuration to add `debug-demo-docker`
and `debug-demo-helm` local repos. Combined with `scripts/local-ci.sh`,
this lets you exercise the full CI flow (image push, chart push,
deploy-from-registry) without a remote Artifactory or GitHub Actions runner.

```sh
scripts/local-ci.sh                  # build + push image + package + push charts
scripts/local-ci.sh --tag v0.0.1     # explicit tag
scripts/local-ci.sh --skip-build     # reuse existing debug-demo-app:dev

# UI:  kubectl -n artifactory port-forward svc/artifactory-artifactory 8081:8081
#      then http://localhost:8081/  (admin / password — change in UI on first login)
```

## Known limitations

- No transactional outbox: order persistence and MQ publish are not
  atomic. A crash between the two will lose the event. Fine for the
  debugging-tooling focus of this project; not production-ready as-is.
- Oracle Free image requires accepting the Oracle license; the image is
  pulled once on the Mac into the air-gap bundle, not inside the cluster.
- IBM MQ image (`icr.io/ibm-messaging/mq`) is Developer license only.
</content>
</invoke>
