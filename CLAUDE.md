# debugging_java_springboot_k8s

A Spring Boot 3.3 / Java 25 service designed as the **target** for a
toolkit that diagnoses memory- and CPU-related issues in JVM pods on
Kubernetes — heap pressure, GC thrash, thread starvation, leaks, slow
JDBC/JMS hand-offs. The CRUD API and Helm charts exist mainly to give
the test tools something realistic to operate on.

## Constraint that shapes everything

**No JDK tools to capture or analyze thread/heap dumps.** The runtime
image is JRE-only (`eclipse-temurin:25-jre-alpine`) and the diagnostic
workflow must work in environments where you cannot pull a JDK image,
attach an ephemeral container with `kubectl debug`, or install
`jstack`/`jmap`/`jcmd` into the pod. Analysis goes through standalone
JRE-based tools (Eclipse MAT, VisualVM, online analyzers) or in-process
metrics (Micrometer/Prometheus).

### Three capture paths, in preference order

1. **Actuator (default).** `/actuator/threaddump` and `/actuator/heapdump`
   are built into Spring Boot and work with JRE-only images. Best when
   the pod is reachable and the app is responsive enough to serve HTTP.
2. **jattach (when actuator is insufficient).** A single ~80 KB
   statically-linked binary that speaks the JVM Hotspot attach protocol.
   Gives access to the full jcmd command surface (`Thread.print -l`,
   `GC.heap_info`, `VM.native_memory summary`, `JFR.start`,
   `Compiler.codecache`, …) that actuator doesn't expose. **Must be
   installed into the pod first** — see `scripts/dump-jattach.sh`.
3. **JDK ephemeral container (last resort).** `kubectl debug --target=app
  --image=eclipse-temurin:25-jdk-alpine ...` — `scripts/dump-threads.sh`
   and `scripts/dump-heap.sh`. Use when you need tools beyond jattach's
   reach (e.g., `jstack -F` for unresponsive JVMs, `jdb` for live
   debugging) or when policy forbids installing binaries into pods.

## Architecture

The workloads run on a **purpose-built 3-node k3s cluster on Lima VMs**
(see `docs/k3s-architecture.md` for the full design). Each box below is
a separate Helm chart in `charts/`; charts have no inter-dependencies —
install order is whatever fits the user's flow.

```
┌──────────────────────── debug-demo namespace ────────────────────────┐
│  ┌──────────────────────────────────────────────────────────────┐    │
│  │  Spring Boot app (JRE-only image, replicas 1..10 via HPA)    │    │
│  │  - CRUD: /api/customers, /api/orders                         │    │
│  │  - Spring Batch CSV→JDBC load: /api/batch/customers/load     │    │
│  │  - Actuator: health, threaddump, heapdump, loggers, metrics  │    │
│  │  - Spring Cache via Valkey Cluster (Lettuce)                 │    │
│  └────┬───────────────────┬──────────────────┬──────────────────┘    │
│       │                   │                  │                       │
│   JDBC│ Oracle 23ai   JMS │ IBM MQ      Redis│ Valkey 8 cluster      │
└───────┼───────────────────┼──────────────────┼───────────────────────┘
        ▼                   ▼                  ▼
  oracle namespace      mq namespace     valkey namespace
   ┌─────────────┐      ┌─────────────┐  ┌──────────────────────────┐
   │ Oracle Free │      │ IBM MQ      │  │ 6 nodes / 2 StatefulSets │
   │ (gvenzl)    │      │ (amd64,     │  │  primary-{0,1,2}         │
   │ + Postgres- │      │  Rosetta)   │  │  secondary-{0,1,2}       │
   │   style PVC │      │             │  │ per-pod LoadBalancer via │
   │   seeding   │      │             │  │  klipper; hostname ann.  │
   └─────────────┘      └─────────────┘  └──────────────────────────┘

  artifactory namespace
   ┌─────────────────────┐
   │ JFrog Container Reg │
   │ (artifactory-jcr)   │
   │ + Postgres sidecar  │
   │ Docker + Helm repos │
   │  debug-demo-docker  │
   │  debug-demo-helm    │
   └─────────────────────┘
```

Cluster infrastructure — 3 Lima VMs on one shared L2 segment
(`192.168.105.0/24`, socket_vmnet), a floating keepalived VIP, and
air-gapped images:

```
                     Mac (192.168.105.1)  — resolves *.debug-demo.local,
                                            reaches the VIP directly (same L2)
                                    │
        ┌───────── keepalived VRRP VIP 192.168.105.100 ──────────┐
        │            (floats to whichever node is MASTER)         │
   ┌────┴─────────┐      ┌───────────────────┐     ┌───────────────┐
   │ ddk3s-server │      │  ddk3s-agent-1    │     │ ddk3s-agent-2 │
   │ k3s server   │      │  k3s agent        │     │ k3s agent     │
   │ keepalived   │      │  keepalived       │     │ keepalived    │
   │  (MASTER,    │      │  (BACKUP, 100)    │     │ (BACKUP, 100) │
   │   prio 150)  │      │                   │     │               │
   │ dnsmasq      │      │  7 GB / 3 cpu     │     │ 7 GB / 3 cpu  │
   │ 3 GB / 2 cpu │      └───────────────────┘     └───────────────┘
   └──────────────┘
   ingress-nginx DaemonSet (hostPort 80/443) on every node — the VIP
   always lands on a node that answers HTTP (keepalived track_script
   pings the local ingress :80/healthz). klipper (k3s servicelb)
   fulfills type=LoadBalancer for the per-pod Valkey Services.
```

k3s v1.31.5 on Alpine 3.23. flannel uses the **host-gw** backend (NOT
VXLAN — VXLAN's tx-checksum-offload bug drops UDP on nested VMs and
breaks cluster DNS), pinned with `--flannel-iface=lima0`.

## External access — VIP + hostnames

Everything is addressed **by hostname → the keepalived VIP**; no static
routes, no per-service external IPs. Two config values in
`scripts/lib/k3s-env.sh` name the entry points:
`APP_HOST=debug-demo.local` and `VALKEY_HOST=valkey.debug-demo.local`,
both resolving to `K3S_VIP=192.168.105.100`.

- **HTTP** — `client → debug-demo.local → VIP → ingress-nginx → app
  ClusterIP → app pod`. ingress-nginx runs as a **DaemonSet on hostPort
  80/443** (`controller.kind=DaemonSet`, `controller.hostPort.enabled`,
  `service.type=ClusterIP`), so whichever node the VIP lands on answers
  HTTP. keepalived fronts the single VIP; `Ingress`/`IngressClass` do
  host/path routing (`host: debug-demo.local`).
- **Valkey** — `client → valkey.debug-demo.local:<port> → VIP →
  klipper → owning pod`. Client TCP only; the cluster **bus is
  pod-to-pod** on the CNI network (see below).

Who resolves what:

| Consumer | Resolves `*.debug-demo.local` via | To |
|---|---|---|
| Mac (curl, valkey-cli) | `/etc/resolver/debug-demo.local` → dnsmasq on server VM | VIP |
| Pods (app, Valkey gossip) | CoreDNS custom stub (`template` plugin answers the zone directly) | VIP |
| Valkey `MOVED`/`CLUSTER SHARDS` | Valkey announces a **hostname**, not an IP | `valkey.debug-demo.local:<port>` |

The Mac resolver is **optional** — `scripts/k3s.sh resolver` writes it
(needs sudo), but HTTP tests use `curl --resolve <host>:80:<VIP>` and
Valkey tests run in-cluster, so nothing on the Mac needs to resolve the
zone. The pod-side stub uses CoreDNS's `template` plugin (answers the
zone → VIP directly) rather than forwarding to host dnsmasq, because
pod→node-shared-IP UDP fails on this topology.

### Why an ingress controller for HTTP

- **Host/path-based routing**: one VIP serves multiple services (add a
  second app, give it a different host on the same VIP).
- **TLS termination**: drop a TLS Secret in, get HTTPS for free.
- **HTTP-aware features**: rewrites, headers, rate limiting, auth.
- **Standard k8s pattern**: `Ingress` + `IngressClass` are the
  primitives; the controller is the implementation. Swapping
  nginx-ingress for another (Traefik, Contour, Envoy) is a controller
  swap, not an app-config change.

### keepalived + klipper: who fulfills `type=LoadBalancer`

A `Service type=LoadBalancer` is *a request*, not an implementation.
On cloud k8s (EKS/GKE/AKS) the cloud-controller-manager fulfills it by
provisioning an ELB/NLB/GLB and writing the IP back. Here there is no
cloud controller, so two host-level components split the job:

- **klipper (k3s servicelb)** fulfills `type: LoadBalancer` — it runs
  one `svclb` pod per node that forwards each Service's port to the
  backing pod. This is the on-prem/dev stand-in for the cloud LB (it
  replaces what MetalLB did in the old single-node setup).
- **keepalived (VRRP)** floats **one stable VIP** across the three
  nodes so clients always have a single address to dial. One VRRP
  instance, `virtual_router_id 51`, priority server(150) > agents(100);
  a `track_script` pings the local ingress `:80/healthz` so the VIP
  only lives on a node whose ingress is serving.

They are **complementary, not either/or**: klipper does port→pod
forwarding on every node, keepalived picks which node's IP is live.
The Helm charts don't change moving to a real cloud LB — the Valkey
per-pod Services stay `type: LoadBalancer`; only the fulfiller differs.

### Valkey networking — unique listen ports, pod-IP gossip, hostname endpoints

This is the subtle part. Six pods —
`valkey-primary-{0,1,2}` + `valkey-secondary-{0,1,2}` (StatefulSets,
by-index pairing: `secondary-N` replicates `primary-N`). Three roles an
address plays are deliberately split apart:

- **Each pod listens on its own unique port.** Client port `6379+idx`
  (primary-0=6379 … secondary-2=6384), bus port `16379+idx`. The
  per-shard addressability that Valkey cluster mode needs (MOVED, MULTI/
  EXEC, WAIT, sharded SSUBSCRIBE/SPUBLISH must each resolve to exactly
  ONE node) comes from the **port**, not a distinct IP.
- **Gossip and replication are direct pod-to-pod on the CNI network.**
  Each pod announces its **pod IP + its own client/bus ports**, so the
  cluster bus and replica sync go straight pod→pod — the VIP and klipper
  are OUT of the bus path. This is what makes replica joins reliable;
  announcing the VIP hung them (the pod→VIP→klipper hairpin stalls).
  Only the **client** port is exposed through a Service.
- **Clients get hostname endpoints.** The chart sets
  `cluster-announce-hostname valkey.debug-demo.local` +
  `cluster-preferred-endpoint-type hostname`, so `CLUSTER SHARDS` /
  `CLUSTER NODES` / `MOVED` return `valkey.debug-demo.local:<port>`.
  Every client (Mac or pod) resolves that to the VIP and dials the
  port, where a per-pod `LoadBalancer` Service (klipper, `targetPort` =
  that pod's unique client port) lands it on the owning pod.
- **`MIGRATE` must target the pod IP, not the hostname.** MIGRATE opens
  a node→node connection; the pod→VIP→klipper hairpin times out (IOERR).
  Client redirects (MOVED/ASK) still use the hostname; only MIGRATE
  needs the pod IP (`scripts/valkey-cluster-tests.sh` derives it from
  `CLUSTER NODES`).
- **The app pins the Valkey hostname → VIP via `hostAliases`** in its
  Deployment, because Lettuce/netty's resolver mishandles Kubernetes
  `ndots:5` search-domain expansion (`getent` resolves it, netty throws
  `UnknownHostException`).

No L7 proxy can sit in the Valkey path — the wire protocol is stateful
TCP. Retired from the chart vs. the old single-node setup: MetalLB
shared-IP annotations, `perPodIP` mode, the dev VIP shim, and any fixed
announce port. See `docs/k3s-architecture.md` for the packet-level
walk-through.

## OpenAPI / Swagger UI

`springdoc-openapi-starter-webmvc-ui` (2.6.0) is on the classpath, no
codegen. Spec is generated at startup by reflecting on Spring MVC
mappings + Jackson + Bean Validation. Controllers are grouped by
`@Tag` (set on each `@RestController`):

| Path | Serves |
|------|--------|
| `/v3/api-docs` | OpenAPI 3.1 JSON (used by Swagger UI and any external tool) |
| `/v3/api-docs.yaml` | Same in YAML |
| `/swagger-ui.html` | 302 → `/swagger-ui/index.html` |
| `/swagger-ui/index.html` | Interactive UI; "try-it-out" enabled, request duration shown |

Config lives in `application.yml` under `springdoc:`. Notable
toggles: `show-actuator: true` adds the actuator endpoints to the
spec (off by default — actuator is documented separately); add a
Spring Security rule to gate `/v3/api-docs` + `/swagger-ui/**` in
prod profiles. Tag descriptions are set in
`config/OpenApiConfig.java` (one Java file, no logic).

## Valkey usage — every op type the cluster supports (no Lua, by design)

`com.example.debugdemo.valkey` exercises the full Valkey command surface.
Each op type lives in its own component, and `OrderService.create()`
calls them all so a single `POST /api/orders` exercises 5 different
cluster ops in 5 different shards.

| Op type | Component | Key(s) | Commands | Endpoint |
|---|---|---|---|---|
| **SET / GET** | controller direct | user-supplied | `SET`, `GET`, optional `EX` | `POST /api/valkey/kv/{key}?value=...[&ttlSeconds=N]` / `GET /api/valkey/kv/{key}` |
| **Cache** (string under the hood) | Spring Cache + `RedisCacheManager` | `customers::<id>`, `orders::<id>` | `SET`, `GET`, `DEL` | implicit via `@Cacheable`/`@CacheEvict` on `*Service.findById` |
| **Hash** | `CustomerStats` | `customer:stats:{<id>}` — `{...}` hash tag pins all keys for one customer to one shard | `HINCRBY`, `HINCRBYFLOAT`, `HSET`, `HGETALL` | `GET /api/valkey/stats/{customerId}` |
| **List** (capped at 100 via `LTRIM`) | `RecentOrders` | `orders:recent` | `LPUSH`, `LTRIM`, `LRANGE`, `LLEN` | `GET /api/valkey/recent?n=20` |
| **Sorted set** | `Leaderboard` | `customers:top` | `ZINCRBY`, `ZREVRANGE WITHSCORES` | `GET /api/valkey/leaderboard?n=10` |
| **Stream (XADD)** | `OrderEventStream` | `orders:events` | `XADD`, `XLEN`, `XREAD` | `POST /api/valkey/streams/append` / `GET /api/valkey/streams/length` / `GET /api/valkey/streams/read?count=N` |
| **Stream consumer group** | `ValkeyOpsConfig` + `StreamMessageListenerContainer` | `orders:events` group `order-processors` | `XGROUP CREATE`, `XREADGROUP`, auto-`XACK` | per-replica counter at `GET /api/valkey/streams/consumed` |
| **Classic pub/sub** | `OrderEventPubSub` + `RedisMessageListenerContainer` | channel `orders:notifications` | `PUBLISH`, `SUBSCRIBE` | `POST /api/valkey/pubsub/publish?msg=...` / `GET /api/valkey/pubsub/received` |
| **Sharded pub/sub** | `OrderEventPubSub` (raw Lettuce dispatch) | channel `{orders}:sharded` | `SPUBLISH` (subscriber not wired — Spring Data Redis 3.3 has no `SSUBSCRIBE` binding) | `POST /api/valkey/pubsub/spublish?msg=...` |

**What `POST /api/orders` actually does** (the integration write path):

```
OrderService.create()
├── DB write          → JPA save (Oracle)
├── MQ publish        → JmsTemplate.convertAndSend (IBM MQ)
├── XADD              → orders:events stream
├── PUBLISH           → orders:notifications channel
├── HINCRBY/HSET      → customer:stats:{customerId} hash (pinned shard per customer)
├── ZINCRBY           → customers:top sorted set
└── LPUSH + LTRIM     → orders:recent list (capped at 100)
```

Each of these lands on a different cluster slot (except per-customer
`{customerId}`-tagged keys, which deliberately share a slot). Every
replica's `StreamMessageListenerContainer` is in the `order-processors`
consumer group, so XADDs are distributed across replicas — one
replica's `streams/consumed` counter goes up per record.

**SPUBLISH workaround** lives in `OrderEventPubSub.publishSharded`.
Three traps to avoid (all documented in `k8s_gotchas.md`):
- `RedisTemplate.execute("SPUBLISH", ...)` fails — `ByteArrayOutput`
  can't decode integer responses
- Casting `LettuceConnection.getNativeConnection()` to
  `StatefulRedisClusterConnection` fails — it's the async *commands*,
  not the connection
- `CommandType.SPUBLISH` enum doesn't exist

The working pattern is custom `ProtocolKeyword` + `IntegerOutput` +
`asyncCmds.dispatch(...).get(5, SECONDS)`.

## Repo layout (only the important bits)

| Path | Purpose |
|------|---------|
| `app/` | Spring Boot service (Maven, single module). The "patient" under test. |
| `app/.../valkey/` | Valkey ops package — streams, pub/sub, hash, zset, list + `ValkeyPlaygroundController` for direct testing |
| `charts/debug-demo-app/` | The app, with HPA (1→10 @ 20% CPU), Valkey/Oracle/MQ wiring. **ClusterIP Service + Ingress** — external traffic arrives via ingress-nginx (DaemonSet, hostPort 80/443) behind the VIP. Pins the Valkey hostname → VIP via `hostAliases`. |
| `charts/oracle/` | Oracle Free with PVC-seeding initContainer (image pre-bakes the DB). |
| `charts/ibm-mq/` | IBM MQ amd64 (no arm64 image; runs under Rosetta on Apple Silicon). |
| `charts/valkey/` | 6-node Valkey 8 cluster; primary-N ↔ secondary-N pairing; **per-pod LoadBalancer** (klipper). Each pod listens on a unique client port (6379-6384) + bus port (16379-16384), announces its **pod IP + ports** for direct pod-to-pod gossip/replication, and announces `valkey.debug-demo.local` (`cluster-announce-hostname` + `cluster-preferred-endpoint-type hostname`) so clients get hostname endpoints → VIP → klipper → owning pod. |
| `charts/artifactory/` | JFrog Container Registry + Postgres sidecar; local Docker + Helm repo. |
| `scripts/k3s.sh` | Single front door: `bundle` / `install` / `resolver` / `doctor` / `smoke` / `status` / `chaos` / `tour` / `valkey` / `uninstall`. |
| `scripts/k3s-*.sh` | Phase scripts: `k3s-install.sh` (orchestrator), `k3s-cluster.sh` (Lima VMs + k3s + air-gap image import), `k3s-net.sh` (keepalived VIP + dnsmasq + CoreDNS stub), `k3s-platform.sh` (ingress-nginx + namespaces + storage), `k3s-charts.sh` (the five charts), `k3s-uninstall.sh`. Plus `k3s-doctor.sh`, `k3s-smoke.sh`, `k3s-chaos.sh`. |
| `scripts/bundle-images.sh` | Builds the air-gap bundle on the Mac (`docker pull`+`save` every image in `K3S_IMAGES`, builds+saves the app image, downloads the k3s binary + airgap tar) into `dumps/airgap/`. |
| `scripts/` (other) | `api-tour.sh` (narrated API walk-through via VIP), `valkey-tour.sh` / `valkey-cluster-tests.sh` (MOVED/ASK/failover, valkey-cli **in-cluster** by hostname), `dump-threads.sh`, `dump-heap.sh`, `dump-jattach.sh`, `memory-report.sh`, `tail-logs.sh`, `set-log-level.sh`, `run-unit-tests.sh`, `local-ci.sh` |
| `scripts/lib/` | `k3s-env.sh` (all config: VIP, hostnames, ports, `K3S_IMAGES`, versions), `common.sh` (auto-targets `dumps/k3s.kubeconfig`) |
| `docs/k3s-architecture.md` | Full 3-node k3s design: topology, keepalived/klipper, dnsmasq/CoreDNS, air-gap, Valkey hostname model. |
| `harness/pipeline.yaml` | Harness CD pipeline (Native Helm). |
| `.github/workflows/` | CI: PR validation + main build → Artifactory. |
| `~/.claude/projects/.../memory/k8s_gotchas.md` | Non-obvious workarounds — read this first when something breaks. |

## How to install everything

Everything runs **air-gapped**: no image is ever pulled inside a VM or
pod. `scripts/bundle-images.sh` runs on the **Mac** (which has internet
or a corporate mirror), `docker pull`+`save`s every image in
`K3S_IMAGES` (defined in `scripts/lib/k3s-env.sh`), builds+saves the app
image, and downloads the k3s binary + `k3s-airgap-images-<arch>.tar.zst`
into `dumps/airgap/`. `scripts/k3s-cluster.sh` copies the bundle into
each Lima VM, installs k3s with `INSTALL_K3S_SKIP_DOWNLOAD=true`, and
`k3s ctr images import`s every tar into containerd. Charts run
`imagePullPolicy: Never`/`IfNotPresent`; a pod that tried to pull would
fail — which is the point (it proves nothing reaches out).

Preferred: **`scripts/k3s.sh install`** — one command runs the full
flow (Lima VMs → k3s → keepalived VIP + dnsmasq/CoreDNS → ingress-nginx
→ namespaces/storage → the five charts → smoke test). It is idempotent.
The `install` phase orchestrates the `k3s-*.sh` scripts; the air-gap
bundle is built by `scripts/k3s.sh bundle` (or on demand by `install`).

```sh
# 0. Build the air-gap bundle on the Mac (needs docker + internet/mirror)
scripts/k3s.sh bundle

# 1. Stand up the whole stack (VMs, k3s, VIP/DNS, ingress, charts, smoke)
scripts/k3s.sh install

# 2. (optional) let the Mac resolve *.debug-demo.local via dnsmasq (sudo)
scripts/k3s.sh resolver

# 3. Health across every layer; prints the fix command for anything broken
scripts/k3s.sh doctor

# 4. Smoke test — 14 checks, all by hostname
scripts/k3s.sh smoke
```

Prereqs: `limactl`, `kubectl`, `helm`, `docker` (for the bundle build),
`curl`. Lima creates the three VMs (`ddk3s-server`, `ddk3s-agent-1`,
`ddk3s-agent-2`) — there is no separate VM-provisioning step. The
kubeconfig is written to `dumps/k3s.kubeconfig`; `scripts/lib/common.sh`
auto-points every script's `kubectl` at it, so no `KUBECONFIG` export is
needed. Config overrides (VIP, hostnames, memory/cpu, image list) all
live in `scripts/lib/k3s-env.sh`.

Tear down with `scripts/k3s.sh uninstall` (deletes the VMs, the Mac
resolver, and the kubeconfig).

Local CI loop (push image + charts to in-cluster Artifactory): see
`scripts/local-ci.sh` and the README — needs a one-time daemon.json
edit to allow the registry as insecure.

## Test tools: capturing memory/CPU diagnostics WITHOUT JDK

All capture goes through actuator. Exposure is already on
(`management.endpoints.web.exposure.include` in `application.yml`).
Adopt these patterns when extending tooling.

### Thread dump

```sh
# JSON format (Spring Boot native — programmatically parseable)
kubectl -n debug-demo exec $POD -- curl -fsS http://localhost:8080/actuator/threaddump \
  > ./dumps/threads/${POD}-$(date -u +%Y%m%dT%H%M%SZ).json

# Plain text format (what jstack would produce — drop into MAT/IntelliJ unchanged)
kubectl -n debug-demo exec $POD -- curl -fsS \
  -H 'Accept: text/plain' http://localhost:8080/actuator/threaddump \
  > ./dumps/threads/${POD}-$(date -u +%Y%m%dT%H%M%SZ).txt
```

The endpoint serves both content types from the same path via content
negotiation. Prefer `text/plain` for human reading and tooling, JSON
for parsing.

### Heap dump

```sh
# Returns a downloaded hprof file; Spring sets the right content-disposition.
kubectl -n debug-demo exec $POD -- curl -fsS -OJ \
  http://localhost:8080/actuator/heapdump \
  -o ./dumps/heap/${POD}-$(date -u +%Y%m%dT%H%M%SZ).hprof
```

Caveat: the heapdump endpoint freezes the JVM for the dump duration
(seconds on a small heap, minutes on multi-GB). Mark any new tooling
that invokes it as "destructive in production" and require an explicit
confirmation flag.

### jattach: capture path when actuator isn't enough

`scripts/dump-jattach.sh` installs jattach into the pod (downloads the
right Linux tarball from the upstream release on the host, `kubectl cp`s
the binary in, sanity-checks it), then runs the requested action. The
binary lands at `/tmp/jattach` and survives until pod restart, so
subsequent invocations skip the install step.

```sh
# One-shot install only — useful to pre-stage before an incident
scripts/dump-jattach.sh install -n debug-demo

# Thread dump (writes ./dumps/threads/<pod>-jattach-thread-<ts>.txt)
scripts/dump-jattach.sh threads -n debug-demo

# Heap dump — pauses JVM, requires --confirm
scripts/dump-jattach.sh heap --confirm -n debug-demo

# Any jcmd command — output streams to stdout, capture as needed
scripts/dump-jattach.sh jcmd "GC.heap_info" -n debug-demo
scripts/dump-jattach.sh jcmd "VM.native_memory summary" -n debug-demo
scripts/dump-jattach.sh jcmd "Compiler.codecache" -n debug-demo
scripts/dump-jattach.sh jcmd "JFR.start duration=60s filename=/tmp/r.jfr" -n debug-demo
```

Key implementation details to preserve when extending the script:

- **Find the JVM PID dynamically.** The app's Deployment sets
  `shareProcessNamespace: true` (so other debug paths can target PID 1
  from a sidecar). Side effect: pod PID 1 is the `/pause` sandbox, NOT
  the JVM. `find_jvm_pid` walks `/proc/*/comm` for `java`.
- **Use jattach's `jcmd` action, not its bare `threaddump` action.**
  jattach has multiple actions; the relevant ones here are:
  `jattach <pid> threaddump` — the JVM writes the dump to its own
  stdout, i.e. the container's log stream, so you'd have to scrape
  `kubectl logs`. `jattach <pid> jcmd "Thread.print -l"` — jattach's
  jcmd action proxies a jcmd-syntax command string into the JVM through
  the Hotspot attach socket; the response comes back through that same
  socket to jattach's own stdout, so `kubectl exec ... > file` captures
  it cleanly. ("jcmd" here is the *jattach action name* — we are NOT
  using the JDK's standalone `jcmd` tool; the syntax of the command
  string inside the quotes happens to match what that tool accepts
  because both speak the same Hotspot attach protocol.)
- **Download the tarball on the host, not in the pod.** Pod egress to
  GitHub is unreliable across environments. The script `curl`s the
  tarball on the host, extracts, and `kubectl cp`s the binary in. The
  cache lives in `scripts/.cache/` (gitignored).
- **Match arch and libc to the pod.** `uname -m` inside the pod tells
  us `x86_64` vs `aarch64`. jattach is statically linked so glibc/musl
  doesn't matter much, but the wrong arch obviously won't run.
- **`--binary <path>` override.** For air-gapped clusters: pre-place the
  binary on the host and pass `--binary /path/to/jattach`. The script
  skips the download step entirely.
- **Same-uid requirement.** jattach attaches as the same uid as the JVM.
  Our pods run as uid 1000 and `kubectl exec` inherits that user from
  the Dockerfile's `USER app` directive. If you change either, jattach
  will fail with `Failed to change credentials to match the target
  process: Operation not permitted`.

### Pre-trigger automatic capture

The Dockerfile sets `-XX:+HeapDumpOnOutOfMemoryError -XX:HeapDumpPath=/tmp/heapdumps`,
and the Deployment mounts an emptyDir at that path. If the JVM dies of
OOM, the hprof file is in `/tmp/heapdumps/` until pod restart. Pull it
out fast:

```sh
kubectl -n debug-demo cp $POD:/tmp/heapdumps/. ./dumps/heap/
```

For continuous capture, expose `/actuator/prometheus` via the included
Micrometer registry and let Prometheus/Grafana track JVM metrics
(heap_used, gc_pause, threads_live) over time — no JDK required.

## Analyzing dumps WITHOUT JDK

Standalone JRE tools are fine; full JDK is not required.

| Tool | What it analyzes | Notes |
|------|-----------------|-------|
| **Eclipse MAT** | heap (hprof) | Best-in-class leak suspect reports. Standalone JRE app — `wget` the platform bundle, no JDK install needed. CLI `ParseHeapDump.sh` runs reports headless for CI. |
| **VisualVM (standalone)** | heap + threads | Separate from any JDK — download from visualvm.github.io. Loads hprof/json/text dumps. Live attach over JMX optional. |
| **fastthread.io** | thread dumps | Free online analyzer for `text/plain` thread dumps. Highlights deadlocks, blocked threads, identical stacks. Don't upload prod dumps with PII in stack frames. |
| **heaphero.io** | hprof | Online counterpart for heap dumps. Same privacy caveat. |
| **IntelliJ IDEA Ultimate** | both | Built-in viewers; standalone JRE. Open hprof directly. |
| **`jvmtop` / `bpftrace` from a sidecar** | live profiling | When you can attach a sidecar (no JDK!) but cannot dump. Adds `top`-like per-thread CPU. |

For automated test pipelines, prefer **MAT's headless CLI**:

```sh
# Generate the Leak Suspects report from a hprof — no GUI, no JDK
ParseHeapDump.sh ./dumps/heap/foo.hprof org.eclipse.mat.api:suspects
# Outputs an HTML report next to the hprof. CI can artifact it.
```

## Recipes the toolkit targets

These are the failure modes the test tools should reproduce + diagnose.
Each script under `scripts/` should map to one or more of these.

1. **Slow leak under steady load.** Use `hpa-load`-style load gen
   against `/api/customers`. Take periodic actuator heap dumps; MAT
   leak-suspects across them shows retained objects growing.

2. **Sudden OOM from a single oversized request.** Trigger via the
   batch endpoint with an outsized CSV (`/api/batch/customers/load`).
   The pod hits the OOM hook, dumps to `/tmp/heapdumps`, exits, k8s
   restarts it. Test verifies the dump is captured before restart.

3. **GC thrash without OOM.** Tight cache TTL + high churn through
   Valkey. `/actuator/metrics/jvm.gc.pause` shows tail latencies
   climb. Toolkit alarms when p99 > N ms.

4. **Thread starvation / deadlock.** Slow JDBC (Oracle 23ai under
   memory pressure) + bounded HikariCP pool. Capture thread dump,
   feed to fastthread.io, expect "blocked on connection acquire".

5. **Hot-loop CPU spike.** A test endpoint that allocates + parses
   in a tight loop. HPA reacts (1 → 10 pods at 20% target). Toolkit
   verifies scale-up event timing.

6. **MQ consumer lag.** Hold the inbound queue listener so MQ depth
   grows. Toolkit pulls `/actuator/metrics/jms.message.processing.time`
   plus MQ depth from the broker REST, correlates.

## Troubleshooting runbook

Top-down triage: cheap/general checks first, drill down only when needed.
For cluster-infrastructure issues (VMs, VIP owner, dnsmasq/CoreDNS,
node Ready, ingress serving, Valkey cluster state, each hostname
resolving+dialing) run **`scripts/k3s.sh doctor`** first — it checks
every layer and prints the fix command for anything broken.

### Step 1 — pod status

```sh
kubectl get pods -A | grep -vE 'Running|Completed'   # anything wrong?
kubectl -n debug-demo get pods -o wide               # IPs, nodes, restarts
kubectl -n debug-demo describe pod <pod> | tail -50  # recent events at the bottom
kubectl get events -n debug-demo --sort-by=.lastTimestamp | tail -20
```

What to look for: `CrashLoopBackOff`, `ImagePullBackOff` (in the
air-gapped cluster this means an image tar was never imported — rerun
`scripts/k3s-cluster.sh` image import), `OOMKilled` (in
`lastState.terminated.reason`), `FailedScheduling` (insufficient
resources), `Unhealthy` events (probe failures), high `restartCount`.

### Step 2 — actuator health

```sh
POD=$(kubectl -n debug-demo get pod -l app.kubernetes.io/name=debug-demo-app -o jsonpath='{.items[0].metadata.name}')
kubectl -n debug-demo exec $POD -- curl -s http://localhost:8080/actuator/health | python3 -m json.tool
kubectl -n debug-demo exec $POD -- curl -s http://localhost:8080/actuator/health/liveness
kubectl -n debug-demo exec $POD -- curl -s http://localhost:8080/actuator/health/readiness
```

The full `/actuator/health` (configured `show-details: when_authorized`)
includes per-subsystem checks: `db` (Oracle JDBC ping), `redis`
(Valkey PING), `jms` (MQ connection), `diskSpace`, `livenessState`,
`readinessState`. A `DOWN` on any of these tells you which integration
tool to investigate next.

### Step 3 — logs

```sh
# Single pod
kubectl -n debug-demo logs <pod> --tail=200

# All app replicas, follow
scripts/tail-logs.sh                                 # uses stern if installed
kubectl -n debug-demo logs -f -l app.kubernetes.io/name=debug-demo-app --max-log-requests 10 --prefix

# Toggle log levels at runtime — no restart
scripts/set-log-level.sh com.example.debugdemo DEBUG
scripts/set-log-level.sh org.hibernate.SQL TRACE     # see actual JDBC SQL
scripts/set-log-level.sh ROOT INFO                   # back to baseline
```

**What to grep for**, by component:

| Component | Container / source | High-signal patterns |
|-----------|--------------------|----------------------|
| App (Spring Boot) | `kubectl logs <app-pod>` | `ERROR`, `OutOfMemoryError`, `^Caused by:`, `HikariPool.*timeout`, `Connection.*refused`, `Flyway.*failed`, `JMSException`, `RedisCommandTimeout` |
| App (MDC fields) | same | `[debug-demo-app,<traceId>,<spanId>]` — use the traceId to correlate across pods |
| Oracle | `kubectl -n oracle logs oracle-oracle-0` | `ORA-`, `alert log`, `archive log`, `tablespace.*full`, `block corruption` |
| Oracle alert log (deeper) | `kubectl -n oracle exec oracle-oracle-0 -- find /opt/oracle/diag -name 'alert*.log' -exec tail -50 {} +` | DB-level errors not surfaced to stdout |
| IBM MQ | `kubectl -n mq logs ibm-mq-ibm-mq-0` | `AMQ` codes; `AMQ9999` is a generic catch-all, `AMQ7234` = queue-manager start |
| MQ runtime depth | `kubectl -n mq exec ibm-mq-ibm-mq-0 -- bash -c 'echo "DISPLAY QSTATUS(*) CURDEPTH" | runmqsc QM1'` | growing depth = consumer lag |
| Valkey (one pod) | `kubectl -n valkey logs valkey-primary-0` | `cluster state changed`, `slave lost`, `eviction`, `fork failed` |
| Valkey cluster health | `kubectl -n valkey exec valkey-primary-0 -- valkey-cli -a $PASS cluster info` | `cluster_state:ok`, `cluster_size:3` |
| Valkey topology | `... valkey-cli -a $PASS cluster nodes` | watch for `fail?` / `disconnected` flags |
| Artifactory | `kubectl -n artifactory logs artifactory-artifactory-0` | `FATAL`, `master.key`, `join.key`, `Access service` |
| Artifactory detailed | `kubectl -n artifactory exec artifactory-artifactory-0 -- tail /opt/jfrog/artifactory/var/log/{artifactory-service,access-service,router-request}.log` | per-subsystem logs |
| Postgres (for Artifactory) | `kubectl -n artifactory logs artifactory-artifactory-postgres-0` | connection errors, slow queries |
| VIP / DNS / ingress | `scripts/k3s.sh doctor` | VIP owner, dnsmasq answering, CoreDNS stub, ingress serving — one command, per-layer |

### Step 4 — resource usage

```sh
kubectl top nodes
kubectl top pods -A --sort-by=cpu | head -20
kubectl top pods -A --sort-by=memory | head -20

# Per-pod over time (basic, no Prometheus needed)
watch -n 2 'kubectl top pods -n debug-demo'

# HPA — current load vs target, current vs desired replicas
kubectl -n debug-demo get hpa app-debug-demo-app
kubectl -n debug-demo describe hpa app-debug-demo-app | tail -20
```

For sustained observation, scrape `/actuator/prometheus` (Micrometer
emits everything below) and graph in Grafana.

### Step 5 — pod memory anatomy (heap vs rest)

This is the question that bites everyone: **"`jvm.memory.used.heap` is
only at 60% but my pod just got OOMKilled — why?"** The JVM heap is one
of *many* things consuming the container's memory budget.

```
Container memory limit          (set in Deployment.spec.resources.limits.memory)
└── Container RSS               (cgroup memory.current — what k8s OOM-kills on)
    ├── JVM heap                Eden + survivors + tenured
    ├── JVM non-heap
    │   ├── Metaspace           class metadata; leaks when classloaders aren't released
    │   ├── Compressed Class    OOP class pointer table
    │   ├── Code Cache          JIT-compiled methods
    │   └── (other reserved)
    ├── JVM internal
    │   ├── GC overhead         remembered sets, card tables, marking stacks
    │   ├── Symbol/String table native symbol cache
    │   ├── Thread stacks       ~1 MB per thread × thread count (xss)
    │   └── Code generators
    ├── Direct buffers          NIO direct, ByteBuffer.allocateDirect, Netty pools
    ├── Native libraries        OCI driver, anything via JNI
    └── glibc/musl overhead     allocator metadata, arena waste
```

**Read it all at once:**

```sh
scripts/memory-report.sh -n debug-demo
```

The script reads cgroup `memory.current`/`memory.max` + every actuator
memory metric (heap, per-pool non-heap, direct/mapped buffers, thread
count), classifies pools as heap vs non-heap, and prints a single
reconciled table that sums to container RSS. All parsing happens on
the host (alpine pods don't ship Python). Example output on an idle
app pod:

```
  Container RSS         :    396.0 MiB
  Container limit       :   1024.0 MiB     (= what k8s OOM-kills on)
  Heap pools (sum = area:heap = 77.4 MiB)
    Eden / Survivor / Tenured       77.9 MiB
  Non-heap pools (sum = area:nonheap = 189.3 MiB)
    Metaspace                      119.7 MiB
    CodeHeap (3 variants)           54.4 MiB
    Compressed Class Space          15.2 MiB
  direct buffers                     8.2 MiB
  thread stacks                     41.0 MiB  (41 × ~1 MiB)
  Accounted                        315.9 MiB
  Unaccounted                       80.2 MiB  ← JVM internal + native + glibc/musl
  RSS / limit                       38.7 %
```

For the deeper native breakdown (requires
`-XX:NativeMemoryTracking=summary` in `JAVA_OPTS`, off by default in
the Dockerfile to keep production overhead minimal):

```sh
scripts/dump-jattach.sh jcmd "VM.native_memory summary" -n debug-demo
```

**Common pod-OOM patterns:**

| Symptom | Likely cause | Where to look |
|---------|-------------|---------------|
| Heap <70%, pod OOMKilled | Direct buffers / native leak | Direct row in report; NMT summary via jattach; thread dump for stuck NIO threads |
| Heap <70%, OOMKilled after long runtime | Metaspace leak (classloader retention) | Metaspace row in report — trend over time |
| Heap full, frequent GC | Allocation pressure or memory leak | hprof diff in MAT (Leak Suspects) |
| RSS grows, heap stable | Code Cache fill (sustained JIT churn) | `scripts/dump-jattach.sh jcmd "Compiler.codecache"` |
| Sudden RSS spike → kill | Heap dump or Spring Batch chunk too large | `kubectl get events`; pre-trigger OOM hook may have left an hprof at `/tmp/heapdumps/` |

### Step 6 — capture a snapshot for offline analysis

When the live commands above point at the JVM but you can't keep
poking at it, take a snapshot bundle:

```sh
POD=$(kubectl -n debug-demo get pod -l app.kubernetes.io/name=debug-demo-app -o jsonpath='{.items[0].metadata.name}')
TS=$(date -u +%Y%m%dT%H%M%SZ)
SNAP=./dumps/snapshot-$TS
mkdir -p "$SNAP"

# Cheapest: actuator
kubectl -n debug-demo exec "$POD" -- curl -s http://localhost:8080/actuator/metrics                              > "$SNAP/metrics.json"
kubectl -n debug-demo exec "$POD" -- curl -s -H 'Accept: text/plain' http://localhost:8080/actuator/threaddump   > "$SNAP/threads.txt"
scripts/memory-report.sh -n debug-demo                                                                          > "$SNAP/memory-report.txt"

# JVM-internal detail via jattach (skips actuator)
scripts/dump-jattach.sh jcmd "GC.heap_info"               -n debug-demo > "$SNAP/gc-heap-info.txt"
scripts/dump-jattach.sh jcmd "VM.flags"                   -n debug-demo > "$SNAP/vm-flags.txt"
scripts/dump-jattach.sh jcmd "Compiler.codecache"         -n debug-demo > "$SNAP/codecache.txt"
scripts/dump-jattach.sh jcmd "VM.classloader_stats"       -n debug-demo > "$SNAP/classloaders.txt"
# NMT only works if -XX:NativeMemoryTracking=summary is set in JAVA_OPTS
scripts/dump-jattach.sh jcmd "VM.native_memory summary"   -n debug-demo > "$SNAP/nmt-summary.txt" 2>&1 || true

# Heaviest: heap dump (PAUSES JVM — only in non-production or with explicit OK)
scripts/dump-jattach.sh heap --confirm -n debug-demo
```

Feed the bundle to MAT (Leak Suspects on the hprof), VisualVM (load the
threads.txt as a "Thread Dump"), or any text editor for the jcmd
outputs. The recipes in the next section show specific paths through
this bundle for each failure mode.

## Valkey runbook — investigating the cluster

Valkey announces **hostname endpoints** (`valkey.debug-demo.local:<port>`),
which resolve to the VIP → klipper → the owning pod. Pods resolve that
hostname via the CoreDNS stub; the Mac only resolves it if you ran
`scripts/k3s.sh resolver`. To avoid depending on the Mac resolver — and
so that `MOVED`/redirect hostnames always resolve — run `valkey-cli`
**in-cluster** (kubectl exec into a Valkey pod), exactly as
`scripts/valkey-tour.sh` and `scripts/valkey-cluster-tests.sh` do.

```sh
PASS=$(kubectl -n valkey get secret valkey -o jsonpath='{.data.password}' | base64 -d)
HOST=valkey.debug-demo.local
# Run valkey-cli inside the cluster so the announced hostname resolves via CoreDNS:
vk()  { kubectl -n valkey exec -i valkey-primary-0 -- valkey-cli    -h "$HOST" "$@" -a "$PASS" --no-auth-warning; }
vkc() { kubectl -n valkey exec -i valkey-primary-0 -- valkey-cli -c -h "$HOST" "$@" -a "$PASS" --no-auth-warning; }
# Client ports by node: primary-0/1/2 = 6379/6380/6381, secondary-0/1/2 = 6382/6383/6384.
# Primaries take writes; secondaries also work for reads.
```

The cluster-aware `-c` flag (`vkc`) makes `valkey-cli` follow MOVED
redirects; the pinned form (`vk`) is for commands that must hit a
specific node (`CLUSTER *`, `INFO`, `LATENCY`, `SLOWLOG`, `CONFIG`,
`CLIENT *`).

### One-shot tour (read-only)

```sh
scripts/valkey-tour.sh                       # everything (valkey-cli in-cluster, by hostname)
scripts/valkey-tour.sh --section topology    # cluster_state, nodes, shards, role+uptime per node
scripts/valkey-tour.sh --section strings     # which keys land on which shards; SET/GET with TTL
scripts/valkey-tour.sh --section hash        # HSET/HINCRBY on customer:stats:{N}; hash-tag pinning demo
scripts/valkey-tour.sh --section list        # LLEN + LRANGE of orders:recent
scripts/valkey-tour.sh --section zset        # ZCARD + top-10 ZREVRANGE WITHSCORES
scripts/valkey-tour.sh --section stream      # XLEN, XINFO STREAM/GROUPS, XRANGE/XREVRANGE
scripts/valkey-tour.sh --section pubsub      # active channels + subscriber counts; sharded channels
scripts/valkey-tour.sh --section info        # INFO Server/Clients/Memory/Stats/Replication/Cluster
scripts/valkey-tour.sh --section latency     # --latency probe, LATENCY LATEST, SLOWLOG GET 5
```

### Topology + health

```sh
vk -p 6379 cluster info             # cluster_state:ok, cluster_size:3
vk -p 6379 cluster nodes            # id, role, addr (hostname:port), master_id, slots
vk -p 6379 cluster shards           # slot ranges → primary id
vk -p 6379 cluster slots            # legacy form

# Per-node role sweep — one hostname, six ports
for port in 6379 6380 6381 6382 6383 6384; do
  echo "=== $HOST:$port ==="
  vk -p $port info replication | grep -E '^role|^connected_slaves|^master_host'
done
```

### Demonstrate MOVED redirect routing

```sh
# Pick a key, see which slot it hashes to and which node owns that slot.
KEY=foo
SLOT=$(vk -p 6379 cluster keyslot $KEY)
echo "key=$KEY -> slot=$SLOT"
vk -p 6379 cluster nodes | awk -v s=$SLOT '
  /master/ { for(i=9;i<=NF;i++) if(match($i,/([0-9]+)-([0-9]+)/,m) && s>=m[1] && s<=m[2]) print $2 }'

# Now SET that key WITHOUT -c, hitting a node that doesn't own it — "the
# wrong node" means the wrong PORT. You get: (error) MOVED <slot> <host>:<owner-port>
WRONG_PORT=6381                 # primary-2; change if it happens to own this slot
vk -p $WRONG_PORT set $KEY bar

# With -c, the cli follows the redirect transparently.
vkc -p $WRONG_PORT set $KEY bar    # → OK
vkc -p $WRONG_PORT get $KEY        # → "bar"
```

### Exercise each op type directly

```sh
# Strings
vkc -p 6379 set tour:str "hello"  EX 60
vkc -p 6379 get tour:str
vkc -p 6379 ttl tour:str

# Hash (with hash-tag pinning)
KEY='customer:stats:{99}'
vkc -p 6379 hset $KEY order_count 0 total_spend 0
vkc -p 6379 hincrby $KEY order_count 1
vkc -p 6379 hincrbyfloat $KEY total_spend 19.99
vkc -p 6379 hgetall $KEY

# List (capped — same pattern as orders:recent)
vkc -p 6379 lpush tour:list a b c d e
vkc -p 6379 ltrim tour:list 0 2
vkc -p 6379 lrange tour:list 0 -1
vkc -p 6379 llen  tour:list

# Sorted set
vkc -p 6379 zincrby tour:zset 100  alice
vkc -p 6379 zincrby tour:zset  50  bob
vkc -p 6379 zincrby tour:zset 175  carol
vkc -p 6379 zrevrange tour:zset 0 -1 WITHSCORES

# Stream
vkc -p 6379 xadd  tour:stream '*' event login user 1
vkc -p 6379 xadd  tour:stream '*' event logout user 1
vkc -p 6379 xlen  tour:stream
vkc -p 6379 xrange tour:stream - +
vkc -p 6379 xinfo stream tour:stream
```

### Pub/sub — live, in two terminals

Classic pub/sub: messages broadcast across all nodes via cluster bus,
so any node works as the subscribe endpoint.

```sh
# Terminal 1 — subscribe (any node; classic pub/sub broadcasts on the cluster bus)
kubectl -n valkey exec -it valkey-primary-0 -- valkey-cli -h $HOST -p 6379 -a "$PASS" --no-auth-warning subscribe orders:notifications
# leave running

# Terminal 2 — publish (either through the app, or directly)
curl --resolve debug-demo.local:80:192.168.105.100 -X POST http://debug-demo.local/api/orders \
  -H 'Content-Type: application/json' \
  -d '{"customerId":1,"amount":1.00}'
# OR direct:
vk -p 6380 publish orders:notifications "hello from the runbook"
```

Sharded pub/sub: messages stay on the shard owning the channel name's
slot. Pick a sharded channel by computing its slot:

```sh
CH='{orders}:sharded'
SLOT=$(vk -p 6379 cluster keyslot $CH)
OWNER_PORT=$(vk -p 6379 cluster nodes | awk -v s=$SLOT '
  /master/ { for(i=9;i<=NF;i++) if(match($i,/([0-9]+)-([0-9]+)/,m) && s>=m[1] && s<=m[2]) print $2 }' | sed 's/.*://; s/@.*//')

# Terminal 1 — subscribe ON THE OWNING SHARD (else SSUBSCRIBE returns MOVED)
kubectl -n valkey exec -it valkey-primary-0 -- valkey-cli -h $HOST -p $OWNER_PORT -a "$PASS" --no-auth-warning ssubscribe "$CH"

# Terminal 2 — publish (any node, command is forwarded to the owner)
curl --resolve debug-demo.local:80:192.168.105.100 -X POST 'http://debug-demo.local/api/valkey/pubsub/spublish?msg=hello-sharded'
```

### Memory + performance probes

```sh
# Memory snapshot per primary — one hostname, per-node ports
for port in 6379 6380 6381; do
  echo "=== $HOST:$port ==="
  vk -p $port info memory | grep -E '^(used_memory_human|used_memory_peak_human|used_memory_rss_human|mem_fragmentation_ratio|maxmemory_human|maxmemory_policy|evicted_keys)'
done

# Latency events (commands that exceeded the configured threshold)
vk -p 6379 config set latency-monitor-threshold 100   # 100 ms; default is 0=disabled
vk -p 6379 latency latest
vk -p 6379 latency history event-name
vk -p 6379 latency reset

# Slow queries (default threshold 10ms, 128-entry ring)
vk -p 6379 slowlog get 10
vk -p 6379 slowlog reset
vk -p 6379 config get slowlog-log-slower-than

# Find big keys (read-only scan, safe on prod)
vk -p 6379 --bigkeys
vk -p 6379 --memkeys     # like bigkeys but ranked by memory footprint

# Hot keys (sampling, more invasive)
vk -p 6379 --hotkeys

# Per-command stats — what the app is actually calling
vk -p 6379 info commandstats | grep -E '^cmdstat_(xadd|hincrby|zincrby|publish|spublish|lpush|get|set)' | sort

# Keyspace overview
vk -p 6379 info keyspace
```

### Failover test (manual — only do this on a non-prod cluster)

Promotes a replica to take over its primary's slots. `scripts/k3s.sh
chaos valkey-freeze` automates this; the manual form:

```sh
# Nodes are addressed by PORT on the shared hostname:
# primary-1 = $HOST:6380, its by-index replica secondary-1 = $HOST:6383.
PRIMARY=valkey-primary-1
PRIMARY_PORT=6380
SECONDARY_PORT=6383

# Before — confirm topology
vk -p $PRIMARY_PORT info replication

# Take the primary offline (the StatefulSet recreates it)
kubectl -n valkey delete pod $PRIMARY

# Within a few seconds the secondary should promote itself.
# Watch from any other primary:
watch "kubectl -n valkey exec valkey-primary-0 -- valkey-cli -h $HOST -p 6379 -a '$PASS' --no-auth-warning cluster nodes | grep -E 'master|slave'"
# You should see the $HOST:$SECONDARY_PORT entry flip from 'slave' to 'master'.

# When the StatefulSet recreates the original primary pod, it comes back as a replica.
sleep 30
vk -p $PRIMARY_PORT info replication | grep -E '^role|^master_host'
```

Note: `scripts/valkey-cluster-tests.sh` freezes a primary with
`DEBUG SLEEP` rather than deleting the pod, because the StatefulSet
heals a deleted pod faster than the 5s `cluster-node-timeout` — no
election would ever happen. `MIGRATE` (slot-migration tests) targets the
**pod IP**, not the hostname, because the pod→VIP→klipper hairpin times
out for node-to-node connections.

### When something looks wrong

| Symptom | First check |
|---|---|
| `valkey-cli` connects but most commands time out | `cluster info` — if `cluster_state:fail`, a primary lost quorum, or the bus (pod-to-pod) is blocked |
| `MOVED` to a hostname that won't connect | run valkey-cli **in-cluster** so CoreDNS resolves the announced hostname; check `scripts/k3s.sh doctor` for VIP/DNS/klipper health, or that pod is down |
| `XADD` works but `XREADGROUP` returns nothing | the consumer-group offset is past the new entries OR no consumer is registered yet — `xinfo groups stream:name` |
| `PUBSUB NUMSUB` shows 0 subscribers but app receives messages | each app replica has its own subscriber connection; `NUMSUB` from a different node may not reflect peers — try the same query against each primary |
| Lots of `MOVED` traffic in `info commandstats` | client isn't cluster-aware (missing `-c` for cli, or Lettuce topology refresh disabled) |

## Integration tools — what to install for what

| Failure mode | Charts needed |
|--------------|---------------|
| Pure JVM heap/CPU experiments | `debug-demo-app` only (Valkey/Oracle/MQ optional, app starts without them in `local` profile) |
| JDBC contention | `oracle` + `debug-demo-app` |
| MQ producer/consumer scenarios | `ibm-mq` + `debug-demo-app` |
| Distributed cache scenarios | `valkey` + `debug-demo-app` |
| Full-stack flow | all four + (optionally) `artifactory` for local CI loop |

## Conventions

- **Image:** runtime is `eclipse-temurin:25-jre-alpine`. Do not bake
  the JDK in. If a tool needs `jstack`/`jmap`, that tool is wrong for
  this project — use actuator (preferred), jattach via
  `scripts/dump-jattach.sh` (when you need jcmd), or `kubectl debug`
  with an off-image JDK container (last resort).
- **jattach is a foreign binary in `/tmp`.** It's installed lazily by
  the dump script. Don't bake jattach into the image either — the
  install-on-demand pattern is part of what we're testing (operators
  in restricted environments need to know how to do this).
- **Dump output:** all capture scripts write to `./dumps/{threads,heap}/`
  with `${POD}-${ISO8601}` naming, gitignored.
- **Everything by hostname, never IP.** Tests, tours, and runbook
  commands address `debug-demo.local` / `valkey.debug-demo.local`
  (→ VIP). The one exception is `MIGRATE`, which needs the target pod
  IP (the pod→VIP→klipper hairpin times out for node-to-node
  connections).
- **Air-gapped by design.** No image is pulled inside a VM or pod;
  charts run `imagePullPolicy: Never`/`IfNotPresent` against images
  pre-imported into containerd. Bumping an image version means updating
  `K3S_IMAGES` in `scripts/lib/k3s-env.sh` and re-running the bundle.
- **Helm charts:** every chart that wraps a stateful service uses an
  `initContainer` to set up the data volume correctly (Oracle PVC
  seeding, Artifactory bootstrap.creds, MQ MQSC via `subPath`). The
  `~/.claude/projects/.../memory/k8s_gotchas.md` file has the *why*
  for each — read it before "simplifying" any initContainer.
- **Resource requests:** the app deliberately uses a tiny CPU request
  (50m) so HPA percentage math is meaningful at 20% target. Don't
  bump unless you also adjust the HPA target.
- **Deployment strategy:** `RollingUpdate`, not `Recreate`. Recreate
  is mutually exclusive with HPA scale-out.

## Build & test

```sh
# scripts/run-unit-tests.sh auto-detects a JDK 21 (Mockito can't instrument
# JDK 26+) and pins JAVA_HOME for the Maven run:
scripts/run-unit-tests.sh                # unit (Mockito + @WebMvcTest), no docker
scripts/run-unit-tests.sh --coverage     # + per-class test counts
scripts/run-unit-tests.sh --integration  # + Testcontainers ITs (needs docker)
scripts/run-unit-tests.sh -- -Dtest=Foo  # pass anything after -- to Maven
# Raw: cd app && JAVA_HOME=$(/usr/libexec/java_home -v 21) mvn test
```

Cluster-protocol semantics (MOVED, ASK via live slot migration, replica
reads, failover + failback) are tested against the LIVE stack by
`scripts/valkey-cluster-tests.sh` — deliberately not in JUnit, because
they need a real 6-node cluster and real failure detection. It runs all
58 checks by hostname with `valkey-cli` **in-cluster** (kubectl exec, so
the announced hostname resolves via CoreDNS); the failover section
freezes a primary with DEBUG SLEEP (enabled for local connections in the
chart) because `kubectl delete pod` is healed by the StatefulSet faster
than the 5s cluster-node-timeout — no election would ever happen. Slot
`MIGRATE` uses the pod IP.

Cluster/end-to-end verification is split across:
`scripts/k3s-smoke.sh` (14 checks, all by hostname — HTTP via
`curl --resolve`, Valkey in-cluster), `scripts/k3s-doctor.sh` (every
layer, tooling → VMs → nodes → VIP → DNS → ingress → workloads/air-gap →
Valkey → end-to-end, printing the fix command for anything broken), and
`scripts/k3s-chaos.sh` (node-down, vip-failover, valkey-freeze, backend
scale-downs). Each check echoes the exact kubectl/curl/valkey-cli
command behind it so the suites double as a copy-pasteable cookbook.
`scripts/k3s.sh` is the guided front door for all of them.

`*IT.java` tests under `src/it/java` use Testcontainers to spin up
Oracle Free + IBM MQ. They're bound to `mvn verify` via Failsafe.

## When something breaks

1. Run `scripts/k3s.sh doctor` — it checks every layer (VMs, VIP owner,
   dnsmasq, CoreDNS stub, node Ready, pods Ready, ingress serving,
   Valkey cluster_state, each hostname resolving+dialing) and prints the
   exact fix command for anything broken.
2. Read `~/.claude/projects/-Users-techdesigns-dev-debugging-java-springboot-k8s/memory/k8s_gotchas.md`
   — most "surprises" are documented there with the root cause.
3. The most common categories of breakage:
   - **Volume mount hiding image content** (Oracle PVC, MQ MQSC,
     Artifactory security files)
   - **Apple Silicon arm64 vs amd64 manifest lists** (IBM MQ)
   - **Flyway baseline-on-migrate** masking unrun migrations
   - **Spring AOP self-invocation** for `@Cacheable`
   - **HPA + Recreate** silently disabling scale-out
   - **Air-gap image not imported** → `ImagePullBackOff` (rerun the
     `k3s-cluster.sh` image-import step)
4. For chart-level issues, `helm get manifest <release> -n <ns>` shows
   exactly what was applied; compare to template output via
   `helm template`.
5. For the networking design (keepalived VIP, klipper, dnsmasq/CoreDNS,
   flannel host-gw, the Valkey hostname model), see
   `docs/k3s-architecture.md`.
```