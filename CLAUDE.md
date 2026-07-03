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
   │   style PVC │      │             │  │ LoadBalancer via MetalLB │
   │   seeding   │      │             │  │  one shared IP :6379-84  │
   └─────────────┘      └─────────────┘  └──────────────────────────┘

  artifactory namespace                  metallb-system namespace
   ┌─────────────────────┐               ┌─────────────────────────┐
   │ JFrog Container Reg │               │ MetalLB controller +    │
   │ (artifactory-jcr)   │               │ speaker DaemonSet,      │
   │ + Postgres sidecar  │               │ L2Advertisement on the  │
   │ Docker + Helm repos │               │ Lima eth0 subnet.       │
   │  debug-demo-docker  │               └─────────────────────────┘
   │  debug-demo-helm    │
   └─────────────────────┘
```

Each box is a separate Helm chart in `charts/`. Charts have no
inter-dependencies — install order is whatever fits the user's flow.

## External access (production-shape topology)

**Two distinct entry-points by traffic type**, with two different
fulfillment models:

- **HTTP → Pattern D (hostNetwork ingress + external LB)**. The
  ingress-nginx controller pod runs with `hostNetwork: true` and
  binds directly to port 80 on the k8s node. An external L4 LB
  (F5 in production; an HAProxy-on-Lima-VM stand-in here) fronts
  the node IPs. No MetalLB in this path.
- **Valkey → Layer 4 (MetalLB direct, per-pod Services)**. Each
  Valkey pod has its own `LoadBalancer` Service. By default all six
  Services SHARE one MetalLB IP (`allow-shared-ip`) and are split by
  port — client 6379-6384, bus 16379-16384 — the same shape as an F5
  VIP with port-based pool members. No proxy in the middle — the
  Valkey wire protocol is TCP and stateful (MOVED redirects must
  resolve to externally-reachable per-shard endpoints; here the
  endpoint is distinguished by port, not IP). Legacy `perPodIP` mode
  (six pinned IPs, one port) is kept behind
  `--set loadBalancer.mode=perPodIP`.

```
                              External clients
                                    │
                       prod: F5 VIP on corporate LAN
                       dev:  HAProxy on second Lima VM (192.168.105.x)
                                    │
            ┌───────────────────────┼─────────────────────────────────┐
            │ HTTP (L7)             │ TCP (L4)                        │
            ▼                       ▼                                 │
   HAProxy VM :80              HAProxy VM :6379-6384 (+bus 1637x)     │
   backend → RD VM :80         backend → MetalLB shared 192.168.64.51 │
            │                  valkey-{primary,secondary}-N-ext       │
            │                  (per-pod Services, allow-shared-ip)    │
            ▼                       │                                 │
   RD VM 192.168.64.2 :80           │                                 │
   ingress-nginx-controller         │ TCP, no proxy                   │
   pod (hostNetwork=true,           │ kube-proxy DNATs to one pod     │
    binds node :80 directly)        ▼                                 │
            │                  valkey-primary-0  ... -2,              │
            │ Ingress rules    valkey-secondary-0 ... -2              │
            │ host: debug-demo.local                                  │
            ▼                       │                                 │
   app-debug-demo-app               │ cluster-announce =              │
   (ClusterIP, port 8080)           │ HAProxy VM IP + its own port    │
                                    │ (MOVED redirects name the VIP)  │
            ────────────────────────┴─────────────────────────────────┘
```

The HTTP path now has **three layers**: external LB (F5/HAProxy)
→ hostNetwork ingress controller → app ClusterIP. This matches
Pattern D in the "Four patterns" section below — the F5 layer is
real (a separate VM, not a pod), and the ingress controller binds
the node's port 80 directly with no Service in front of it.

### Why an ingress controller for HTTP

- **Host/path-based routing**: lets one VIP serve multiple services
  (Postman talks to `debug-demo.local`; if you add a second app,
  it can share the same VIP via a different host).
- **TLS termination**: drop a TLS Secret in, get HTTPS for free.
- **HTTP-aware features**: rewrites, headers, rate limiting, auth.
- **Standard k8s pattern**: `Ingress` + `IngressClass` are the
  primitives; the controller is the implementation. Swapping
  nginx-ingress for any other (Traefik, Contour, Envoy) is a
  controller swap, not an app-config change.

### Why per-pod Services (no proxy) for Valkey

- Valkey cluster mode sends `MOVED <slot> <ip>:<port>` redirects.
  External clients must be able to dial those addresses directly, and
  each address must land on exactly ONE node. A single ip:port that
  round-robins across nodes would break `MULTI`/`EXEC`, `WAIT`,
  sharded `SSUBSCRIBE`/`SPUBLISH`. What's non-negotiable is per-shard
  ADDRESSABILITY — six distinct Services — not six distinct IPs.
- Default mode (`sharedIP-perPort`): all six Services pin the same
  MetalLB IP via `metallb.universe.tf/allow-shared-ip`; each exposes
  a unique external port pair (client 6379-6384, bus 16379-16384).
  Each pod announces the shared IP plus its own ports via
  `cluster-announce-{ip,port,bus-port}` (derived from pod ordinal at
  startup — see `statefulset-primary.yaml` entrypoint; secondaries
  offset by replicaCount). `CLUSTER NODES` / `CLUSTER SHARDS`
  therefore return externally-resolvable endpoints where the PORT
  identifies the shard. Matches enterprise "one VIP per app, pool
  members by port" F5 allocations.
- Shared-IP constraint: `externalTrafficPolicy` must be `Cluster` —
  MetalLB only lets Local-policy Services share an IP when their pod
  selectors are identical, and ours select one pod each. Cluster
  policy loses source-IP preservation, which Valkey doesn't need.
- Legacy mode (`perPodIP`): one pinned IP per pod (.51-.56), one
  port. Same MOVED semantics, distinguished by IP instead of port.
- Bus ports are exposed externally too: peers gossip using announced
  addresses, so shared-IP:bus-port must route to the right pod.
- Nginx-ingress is **only** for HTTP traffic; no L7 proxy can sit in
  the Valkey path.

### Production shape: F5 VIP without CIS → set announceIP

Production uses an F5 that is NOT cluster-integrated (no CIS), so the
F5 VIP forwards to the in-cluster LB IP — two LB layers, the same
model as the HTTP path here (HAProxy VM fronting the cluster). The
chart decouples the two roles an address plays:

- `loadBalancer.sharedIP` — what the six Services pin as
  `loadBalancerIP` (fulfilled by MetalLB here, whatever controller in
  prod).
- `loadBalancer.announceIP` — what the pods ADVERTISE in cluster
  metadata (`CLUSTER NODES` / `CLUSTER SHARDS` / MOVED redirects).
  This must be the address CLIENTS dial. Empty = announce sharedIP
  (one-layer). Set it to the F5 VIP in prod (two-layer): clients dial
  the VIP, so redirects must name the VIP. **The full install
  rehearses the two-layer shape**: install-stack.sh sets announceIP
  to the HAProxy VM's IP and enables the chart's `devVipShim`, so
  MOVED redirects name the F5 stand-in and external clients genuinely
  traverse it. `--skip-haproxy-vm` falls back to one-layer.

```sh
helm upgrade valkey ./charts/valkey -n valkey \
  --set loadBalancer.sharedIP=<metallb-ip> \
  --set loadBalancer.announceIP=<f5-vip>
```

Non-negotiable F5 config when announceIP is set (also documented in
`charts/valkey/values.yaml`):

1. Ports forward 1:1 — client 6379-6384 AND bus 16379-16384, VIP
   port = backend port. The announced ports must be dialable exactly
   as announced; no port rewriting.
2. Plain L4 TCP passthrough (fastL4 / standard TCP); no L7/TLS in
   the path — the Valkey wire protocol is stateful TCP.
3. **Bus ports open on the VIP — gossip hairpins through the F5.**
   Nodes gossip with each other via the ANNOUNCED addresses.
   kube-proxy short-circuits traffic to the Service IP inside the
   node, but knows nothing about the F5 VIP, so pod↔pod gossip
   genuinely leaves the cluster, traverses the F5 on 16379-16384,
   and returns. Blocked bus ports → `cluster_state:fail`. Budget the
   VIP for that standing gossip traffic.
4. SNAT automap is fine — Valkey sees the F5 as the client, the same
   source-IP trade-off as `externalTrafficPolicy: Cluster`, which
   Valkey doesn't care about.

Dev caveat behind requirement 3: on Rancher Desktop, pods CANNOT reach
the HAProxy VM — Apple's vz NAT refuses to forward VM-to-VM traffic
between the RD subnet (192.168.64.x) and the Lima shared subnet
(192.168.105.x) — so gossip via the announced VIP would fail. The
chart's `devVipShim` (dev-only, hostNetwork DaemonSet) restores the
prod property "nodes can reach the VIP": it adds the VIP as a /32 on
the node's loopback and proxies VIP:<client+bus ports> to the
in-cluster valkey-*-ext Services. Inside the cluster the VIP resolves
on-node; outside it's still the real HAProxy VM. Never enable it in
prod. Leftover on teardown: the /32 on lo persists until the RD VM
restarts (harmless; the shim re-adds it on install).

### Why MetalLB hands out the IPs (and what replaces it elsewhere)

A `Service type=LoadBalancer` is *a request*, not an implementation.
When you create one, k8s sets `.status.loadBalancer.ingress` to
whatever IP an external **load-balancer controller** assigns. If
nothing in the cluster fulfills that request, the Service sits in
`<pending>` forever.

On cloud k8s (EKS/GKE/AKS) the cloud-controller-manager fills that
role — it sees the Service, calls the cloud API to provision an
ELB/NLB/GLB, and writes the IP/hostname back. On bare-metal,
on-prem, and dev clusters (Rancher Desktop, kind, minikube, k3s) no
such controller exists by default. **MetalLB is the bare-metal
implementation of that contract.** Same Service spec, different
provider behind the scenes.

```
┌─ Cluster type ─────────┬─ What fulfills type=LoadBalancer ──────────┬─ How your manifests change ─┐
│ EKS                    │ AWS cloud-controller → ELB/NLB/ALB         │ none — annotations tune it  │
│ GKE                    │ GCP cloud-controller → Google LB           │ none                        │
│ AKS                    │ Azure cloud-controller → Azure LB          │ none                        │
│ OpenShift on-prem      │ Often MetalLB; sometimes F5 BIG-IP CIS,    │ none — controller-agnostic  │
│                        │ Citrix CPX, AVI / NSX ALB controller       │                             │
│ Rancher / k3s          │ Klipper LB (built-in) or MetalLB           │ none                        │
│ kind / minikube        │ MetalLB, or `minikube tunnel`              │ none                        │
│ "Plain" bare-metal     │ MetalLB (L2 or BGP mode)                   │ none                        │
│ No LB controller       │ Service stays `<pending>` → use NodePort + │ chart must offer NodePort   │
│                        │ external device pointed at node IPs        │ option, no LoadBalancer     │
└────────────────────────┴────────────────────────────────────────────┴─────────────────────────────┘
```

Crucially, the **Helm charts in this repo don't change** when you
move from MetalLB to a real cloud LB. The Valkey per-pod Services
are still `type: LoadBalancer`; whatever controller is installed
assigns IPs. Only the *IP source* differs. For ingress-nginx, this
POC uses Pattern D (`hostNetwork=true`, no LoadBalancer Service) —
see the "Four patterns" section below for A/B/C alternatives.

### Four patterns for how external LB traffic reaches in-cluster ingress-nginx

The previous section answers "who fulfills `type=LoadBalancer`."
This section answers a different question: when the external LB
(F5, NetScaler, cloud LB, HAProxy VM, etc.) is in front, what's in
its backend pool, and what's listening on those addresses? Four
real-world patterns, all in production use:

```
Pattern A — External LB → NodePort
─────────────────────────────────────
F5 VIP 10.0.0.50  ──pool──> node1:32080, node2:32080, node3:32080 ...
                            ↑
                   ingress-nginx Service: type=NodePort, port=80, nodePort=32080
                            ↓ kube-proxy iptables on the chosen node
                            ↓
                   ingress-nginx-controller pod
```
- Pool members: **all node IPs on a high port** (e.g. 32080).
- Simple, works anywhere. Loses client source IP unless
  `externalTrafficPolicy: Local` is set on the NodePort Service.
- Exposes a non-standard port on every node — some shops dislike
  this for security/auditing reasons.

```
Pattern B — External LB → pod IPs directly  (most common in mature F5+k8s shops)
────────────────────────────────────────────────────────────────────────────────
F5 VIP 10.0.0.50  ──pool──> 10.244.1.5:80, 10.244.2.7:80, ...
                            (these are real ingress-nginx-controller POD IPs)
                            ↑
                   ingress-nginx Service: type=ClusterIP (or anything — F5 ignores it)
                            ↓
                   ingress-nginx-controller pod  (no kube-proxy hop, no NodePort)
```
- Pool members: **pod IPs of the ingress controller**, populated
  by an in-cluster controller (F5 BIG-IP CIS, Citrix CPX, AVI
  Kubernetes Operator) that watches Endpoints/EndpointSlices and
  programs the F5 pool dynamically as pods scale.
- Requires the F5 (or other appliance) to have **L3 reachability
  to the pod network**. Typically achieved via BGP peering with
  the CNI (Calico, Cilium) advertising pod CIDR routes to F5.
- No kube-proxy hop, real source IPs, real health checks against
  the actual pod. **The cleanest enterprise pattern.**

```
Pattern C — External LB → LoadBalancer IP  (two LB layers; usually transitional)
────────────────────────────────────────────────────────────────────────────────
F5 VIP 10.0.0.50  ──pool──> 10.10.50.7:80
                            ↑
                   ingress-nginx Service: type=LoadBalancer
                   ↑ IP allocated by something inside cluster (MetalLB / cloud CCM / F5 CIS as LB-class)
                            ↓
                   ingress-nginx-controller pod
```
- Pool members: **one IP per ingress-nginx Service**, which itself
  is allocated by some other LB controller in the cluster.
- Two LB layers stacked. Most often seen during migrations
  (you were on MetalLB-only, you're rolling F5 in front, you haven't
  migrated the inner LB yet) rather than as a steady state.

```
Pattern D — External LB → node IPs on :80, hostNetwork ingress  (← this POC)
────────────────────────────────────────────────────────────────────────────
F5 VIP 10.0.0.50  ──pool──> node1:80, node2:80, node3:80 ...
                            ↑
                   ingress-nginx pod with hostNetwork=true
                   (binds directly to the node's :80 — Service is bypassed entirely)
                            ↓
                   forwards to app ClusterIP, then to app pod
```
- Pool members: **all node IPs on standard 80/443**.
- ingress-nginx runs as a DaemonSet (or a small Deployment with
  node anti-affinity) so exactly one pod per node owns the port.
- Service still exists for cluster-internal access but external
  traffic bypasses it — the pod's container is bound to the host's
  port via `hostNetwork: true`.
- Trade-offs: ingress controller can't share a node with anything
  else that needs :80; you need namespace-level coordination on
  what gets the host port. **What this POC implements** because it
  matches the enterprise we're modeling.

#### How to tell which pattern an existing cluster uses

```sh
# What type is the ingress controller's Service?
kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.spec.type}'

# Is the pod hostNetwork?
kubectl -n ingress-nginx get pod -l app.kubernetes.io/name=ingress-nginx \
  -o jsonpath='{.items[0].spec.hostNetwork}'

# Is F5 BIG-IP CIS (or another CCM-style controller) running?
kubectl get pods -A | grep -iE 'f5-bigip|cis|k8s-bigip-ctlr|citrix|avi-controller'
```

| Service type | hostNetwork | CCM-style controller? | → Pattern |
|---|---|---|---|
| `ClusterIP` | `true` | no | **D** (hostNetwork; this POC) |
| `ClusterIP` | `false` | yes | **B** (CIS → pod IPs) |
| `NodePort` | `false` | no | **A** (LB → NodePort) |
| `LoadBalancer` | `false` | maybe | **B** (CIS as LB-class) or **C** (two-layer) |

The Helm charts in this repo don't change between patterns — the
chart's `controller.hostNetwork` value or `controller.service.type`
value flips, but everything else stays. The MetalLB-allocated
Valkey per-pod IPs are unchanged regardless of which HTTP pattern
you pick, because Valkey's `MOVED` semantics need per-shard
addressability and no L7 ingress controller is in the path.

#### How this POC models Pattern D (the F5 simulation)

Real Pattern D requires a separate external LB device. In this POC
we approximate that with a **second Lima VM** running HAProxy:

```
Mac (host)
├── Lima VM "haproxy-lb"  192.168.105.x   ← F5 stand-in
│      HAProxy 2.x, frontend :80
│      backend = $RD_VM_IP:80 (single node in dev)
│
└── Rancher Desktop VM   192.168.64.2     ← the k8s node
       ingress-nginx-controller pod (hostNetwork=true, binds :80 directly)
       app pods (ClusterIP, reached by ingress)

Mac IP forwarding enabled (sysctl net.inet.ip.forwarding=1)
so the HAProxy VM (on its own subnet) can reach the RD VM (on bridge100)
via the Mac as a router. In production this hop doesn't exist — F5
and the k8s nodes share the corporate LAN.
```

In production, swap "Lima VM running HAProxy" for "F5 BIG-IP cluster
in the network DMZ" and "Mac IP forwarding" for "actual L3 routing
between F5 and node subnets." The k8s side is identical.

### Why the dev `sudo route` hop exists (still needed for Valkey)

Rancher Desktop's vz-NAT mode only ARP-responds for the VM's own
IP (`192.168.64.2`). MetalLB advertises the Valkey LB IP(s) —
one shared IP (192.168.64.51) in the default mode, six
(192.168.64.51-56) in perPodIP mode — in the bridge subnet via
gratuitous ARP, but those ARP responses don't pass through the NAT
to the host. The static routes tell macOS to use the RD VM as
next-hop for each MetalLB IP; the VM's kube-proxy iptables then
DNATs to the right pod (in shared mode the destination PORT selects
the pod).

**This hop is no longer needed for HTTP** — the HAProxy VM is on
its own Lima-managed subnet (`192.168.105.x`) that the Mac talks
to directly, and HAProxy reaches the RD VM through Mac IP
forwarding (`sysctl net.inet.ip.forwarding=1`, set by
install-stack.sh). So:

- HTTP (`http://debug-demo.local`) → goes through HAProxy VM, no
  host-route needed
- Valkey (`192.168.64.51:6379-6384` default; `.51-.56:6379` in perPodIP mode) → still goes through host-routes

In production neither hop exists — F5 sits on the corporate LAN,
clients dial its VIP directly. The "VM next-hop" trick is only
necessary because Rancher Desktop puts the k8s pod and Service
network behind NAT.

```sh
# All three handled automatically by install-stack.sh (Phase 9). Manual:
scripts/host-routes.sh add        # static routes for Valkey IPs (sudo)
sudo sysctl -w net.inet.ip.forwarding=1        # so HAProxy VM can reach RD node
HAPROXY_IP="$(cat dumps/haproxy-vm-ip)"
sudo sh -c "echo '$HAPROXY_IP debug-demo.local' >> /etc/hosts"    # HTTP entry
```

After `add`:

```sh
# L7 (HTTP) — through nginx-ingress
curl http://debug-demo.local/actuator/health
curl http://debug-demo.local/api/customers
open http://debug-demo.local/swagger-ui.html        # interactive API explorer

# L4 (TCP) — directly to Valkey per-pod LBs
valkey-cli -c -h 192.168.64.51 -p 6379 -a <pwd> cluster info
valkey-cli -c -h 192.168.64.51 -p 6379 -a <pwd> set hello world   # follows MOVED
```

### OpenAPI / Swagger UI

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
| `charts/debug-demo-app/` | The app, with HPA (1→10 @ 20% CPU), Valkey/Oracle/MQ wiring. **ClusterIP Service + Ingress** — external traffic arrives via nginx-ingress in hostNetwork mode (Pattern D). |
| `charts/oracle/` | Oracle Free with PVC-seeding initContainer (image pre-bakes the DB). |
| `charts/ibm-mq/` | IBM MQ amd64 (no arm64 image; runs under Rosetta on Apple Silicon). |
| `charts/valkey/` | 6-node Valkey 8 cluster; primary-N ↔ secondary-N pairing; **per-service-per-pod LoadBalancer**; default = ONE shared LB IP split by port (client 6379-6384, `allow-shared-ip`), each pod announcing shared-IP:its-port via `cluster-announce-{ip,port,bus-port}` from pod ordinal; legacy `perPodIP` mode = six pinned IPs. |
| `charts/artifactory/` | JFrog Container Registry + Postgres sidecar; local Docker + Helm repo. |
| `scripts/` | `dump-threads.sh`, `dump-heap.sh`, `dump-jattach.sh`, `memory-report.sh`, `tail-logs.sh`, `set-log-level.sh`, `local-ci.sh`, `host-routes.sh` (dev VIP stand-in), `test-external-access.sh` |
| `harness/pipeline.yaml` | Harness CD pipeline (Native Helm). |
| `.github/workflows/` | CI: PR validation + main build → Artifactory. |
| `~/.claude/projects/.../memory/k8s_gotchas.md` | Non-obvious workarounds — read this first when something breaks. |

## How to install everything

Preferred: `scripts/install-stack.sh` (10 phases, idempotent). Phase 2
pre-pulls every registry image via `scripts/preload-images.sh` so
corporate-MITM TLS failures surface as one clear error up-front instead
of an ImagePullBackOff mid-install. The image list lives in the `IMAGES`
array at the top of `preload-images.sh` — update it whenever a version
is bumped in install-stack.sh or a chart's values.yaml.
`--image-manifest-only` prints the list (air-gap / security review);
`--skip-image-preload` bypasses the phase on clean networks.

Manual equivalent:

```sh
# 0. One-time RD bump (default 2 CPU / 6 GB is too small for the full stack)
rdctl set --virtual-machine.memory-in-gb=16 --virtual-machine.number-cpus=8

# 0.5. Pre-pull all registry images (surfaces corporate-MITM failures early)
scripts/preload-images.sh

# 1. MetalLB + IP pool (for the Valkey LoadBalancer)
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.8/config/manifests/metallb-native.yaml
# wait for metallb pods Ready, then:
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

# 2. Integration tools (no inter-deps — install in parallel if you want)
helm upgrade --install oracle      ./charts/oracle      -n oracle      --create-namespace \
  --set image.repository=gvenzl/oracle-free --set image.tag=23-slim-faststart
helm upgrade --install ibm-mq      ./charts/ibm-mq      -n mq          --create-namespace \
  --set image.tag=9.4.5.1-r1-amd64
helm upgrade --install valkey      ./charts/valkey      -n valkey      --create-namespace
helm upgrade --install artifactory ./charts/artifactory -n artifactory --create-namespace

# 3. Build the app image (Rancher Desktop moby is the active docker engine)
cd app && docker build -t debug-demo-app:dev . && cd ..

# 4. Install the app (defaults assume the four service namespaces above)
helm upgrade --install app ./charts/debug-demo-app -n debug-demo --create-namespace \
  --set image.repository=debug-demo-app \
  --set image.tag=dev \
  --set image.pullPolicy=Never \
  --set oracle.host=oracle-oracle.oracle.svc.cluster.local \
  --set oracle.service=FREEPDB1 \
  --set mq.host=ibm-mq-ibm-mq.mq.svc.cluster.local \
  --set mq.user=app --set mq.password=passw0rd

# 5. Smoke test
POD=$(kubectl -n debug-demo get pod -l app.kubernetes.io/name=debug-demo-app -o jsonpath='{.items[0].metadata.name}')
kubectl -n debug-demo exec $POD -- curl -s http://localhost:8080/actuator/health
```

Local CI loop (push image + charts to in-cluster Artifactory): see
`scripts/local-ci.sh` and the README — needs a one-time daemon.json
edit to allow `host.docker.internal:8081` as an insecure registry.

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

### Step 1 — pod status

```sh
kubectl get pods -A | grep -vE 'Running|Completed'   # anything wrong?
kubectl -n debug-demo get pods -o wide               # IPs, nodes, restarts
kubectl -n debug-demo describe pod <pod> | tail -50  # recent events at the bottom
kubectl get events -n debug-demo --sort-by=.lastTimestamp | tail -20
```

What to look for: `CrashLoopBackOff`, `ImagePullBackOff`, `OOMKilled` (in
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
| MetalLB | `kubectl -n metallb-system logs -l app=metallb` | "speaker" lines for L2 advertisement issues |

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

## Valkey runbook — investigating the cluster from outside

Prereq: `scripts/host-routes.sh add` is in effect (the 7 LB IPs are
routable from this Mac), and `valkey-cli` is on PATH
(`brew install valkey`).

```sh
PASS=$(kubectl -n valkey get secret valkey -o jsonpath='{.data.password}' | base64 -d)
# Clients must dial the ANNOUNCED address. Full install (two-layer): the
# HAProxy VM IP, cached in dumps/haproxy-vm-ip. --skip-haproxy-vm install
# (one-layer): the shared MetalLB IP 192.168.64.51.
SEED=$(cat dumps/haproxy-vm-ip 2>/dev/null || echo 192.168.64.51)
# Client ports by node: primary-0/1/2 = 6379/6380/6381, secondary-0/1/2 = 6382/6383/6384.
# Primaries take writes; secondaries also work for reads. (In legacy perPodIP
# mode the ports are all 6379 and the IPs are .51-.56 instead.)
```

The cluster-aware `-c` flag makes `valkey-cli` follow MOVED redirects;
omit it for commands that need to be pinned to a specific node
(`CLUSTER *`, `INFO`, `LATENCY`, `SLOWLOG`, `CONFIG`, `CLIENT *`).

### One-shot tour (read-only)

```sh
scripts/valkey-tour.sh                       # everything
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
valkey-cli -h $SEED -p 6379 -a $PASS cluster info             # cluster_state:ok, cluster_size:3
valkey-cli -h $SEED -p 6379 -a $PASS cluster nodes            # id, role, addr, master_id, slots
valkey-cli -h $SEED -p 6379 -a $PASS cluster shards           # slot ranges → primary id
valkey-cli -h $SEED -p 6379 -a $PASS cluster slots            # legacy form

# Per-node role / uptime sweep — one IP, six ports (default mode)
for port in 6379 6380 6381 6382 6383 6384; do
  echo "=== $SEED:$port ==="
  valkey-cli -h $SEED -p $port -a $PASS info replication | grep -E '^role|^connected_slaves|^master_host'
done
```

### Demonstrate MOVED redirect routing

```sh
# Pick a key, see which slot it hashes to and which node owns that slot.
KEY=foo
SLOT=$(valkey-cli -h $SEED -p 6379 -a $PASS cluster keyslot $KEY)
echo "key=$KEY -> slot=$SLOT"
valkey-cli -h $SEED -p 6379 -a $PASS cluster nodes | awk -v s=$SLOT '
  /master/ { for(i=9;i<=NF;i++) if(match($i,/([0-9]+)-([0-9]+)/,m) && s>=m[1] && s<=m[2]) print $2 }'

# Now SET that key WITHOUT -c, hitting a node that doesn't own it. In the
# default shared-IP mode "the wrong node" means the wrong PORT.
# You should get back: (error) MOVED <slot> <ip>:<owner-port>
WRONG_PORT=6381                 # primary-2; change if it happens to own this slot
valkey-cli -h $SEED -p $WRONG_PORT -a $PASS set $KEY bar

# With -c, the cli follows the redirect transparently.
valkey-cli -c -h $SEED -p $WRONG_PORT -a $PASS set $KEY bar    # → OK
valkey-cli -c -h $SEED -p $WRONG_PORT -a $PASS get $KEY        # → "bar"
```

### Exercise each op type directly

```sh
# Strings
valkey-cli -c -h $SEED -p 6379 -a $PASS set tour:str "hello"  EX 60
valkey-cli -c -h $SEED -p 6379 -a $PASS get tour:str
valkey-cli -c -h $SEED -p 6379 -a $PASS ttl tour:str

# Hash (with hash-tag pinning)
KEY='customer:stats:{99}'
valkey-cli -c -h $SEED -p 6379 -a $PASS hset $KEY order_count 0 total_spend 0
valkey-cli -c -h $SEED -p 6379 -a $PASS hincrby $KEY order_count 1
valkey-cli -c -h $SEED -p 6379 -a $PASS hincrbyfloat $KEY total_spend 19.99
valkey-cli -c -h $SEED -p 6379 -a $PASS hgetall $KEY

# List (capped — same pattern as orders:recent)
valkey-cli -c -h $SEED -p 6379 -a $PASS lpush tour:list a b c d e
valkey-cli -c -h $SEED -p 6379 -a $PASS ltrim tour:list 0 2
valkey-cli -c -h $SEED -p 6379 -a $PASS lrange tour:list 0 -1
valkey-cli -c -h $SEED -p 6379 -a $PASS llen  tour:list

# Sorted set
valkey-cli -c -h $SEED -p 6379 -a $PASS zincrby tour:zset 100  alice
valkey-cli -c -h $SEED -p 6379 -a $PASS zincrby tour:zset  50  bob
valkey-cli -c -h $SEED -p 6379 -a $PASS zincrby tour:zset 175  carol
valkey-cli -c -h $SEED -p 6379 -a $PASS zrevrange tour:zset 0 -1 WITHSCORES

# Stream
valkey-cli -c -h $SEED -p 6379 -a $PASS xadd  tour:stream '*' event login user 1
valkey-cli -c -h $SEED -p 6379 -a $PASS xadd  tour:stream '*' event logout user 1
valkey-cli -c -h $SEED -p 6379 -a $PASS xlen  tour:stream
valkey-cli -c -h $SEED -p 6379 -a $PASS xrange tour:stream - +
valkey-cli -c -h $SEED -p 6379 -a $PASS xinfo stream tour:stream
```

### Pub/sub — live, in two terminals

Classic pub/sub: messages broadcast across all nodes via cluster bus,
so any seed works as the subscribe endpoint.

```sh
# Terminal 1 — subscribe (any node; classic pub/sub broadcasts on the cluster bus)
valkey-cli -h 192.168.64.51 -p 6379 -a $PASS subscribe orders:notifications
# leave running

# Terminal 2 — publish (either through the app, or directly)
curl -X POST http://debug-demo.local/api/orders \
  -H 'Content-Type: application/json' \
  -d '{"customerId":1,"amount":1.00}'
# OR direct:
valkey-cli -h 192.168.64.51 -p 6380 -a $PASS publish orders:notifications "hello from outside"
```

Sharded pub/sub: messages stay on the shard owning the channel name's
slot. Pick a sharded channel by computing its slot:

```sh
CH='{orders}:sharded'
SLOT=$(valkey-cli -h $SEED -p 6379 -a $PASS cluster keyslot $CH)
OWNER=$(valkey-cli -h $SEED -p 6379 -a $PASS cluster nodes | awk -v s=$SLOT '
  /master/ { for(i=9;i<=NF;i++) if(match($i,/([0-9]+)-([0-9]+)/,m) && s>=m[1] && s<=m[2]) print $2 }' | cut -d: -f1 | cut -d@ -f1)

# Terminal 1 — subscribe ON THE OWNING SHARD (else SSUBSCRIBE returns MOVED)
valkey-cli -h $OWNER -p 6379 -a $PASS ssubscribe "$CH"

# Terminal 2 — publish (any node, command is forwarded to the owner)
curl -X POST 'http://debug-demo.local/api/valkey/pubsub/spublish?msg=hello-sharded'
```

### Memory + performance probes

```sh
# Memory snapshot per primary — one IP, per-node ports (default mode)
for port in 6379 6380 6381; do
  echo "=== $SEED:$port ==="
  valkey-cli -h $SEED -p $port -a $PASS info memory | grep -E '^(used_memory_human|used_memory_peak_human|used_memory_rss_human|mem_fragmentation_ratio|maxmemory_human|maxmemory_policy|evicted_keys)'
done

# Latency monitor (this seed only) — 5 seconds of pings, distribution at the end
valkey-cli -h $SEED -p 6379 -a $PASS --latency -i 1 &
sleep 5; kill %1 2>/dev/null; wait 2>/dev/null

# Latency events (commands that exceeded the configured threshold)
valkey-cli -h $SEED -p 6379 -a $PASS config set latency-monitor-threshold 100   # 100 ms; default is 0=disabled
valkey-cli -h $SEED -p 6379 -a $PASS latency latest
valkey-cli -h $SEED -p 6379 -a $PASS latency history event-name
valkey-cli -h $SEED -p 6379 -a $PASS latency reset

# Slow queries (default threshold 10ms, 128-entry ring)
valkey-cli -h $SEED -p 6379 -a $PASS slowlog get 10
valkey-cli -h $SEED -p 6379 -a $PASS slowlog reset
valkey-cli -h $SEED -p 6379 -a $PASS config get slowlog-log-slower-than

# Find big keys (read-only scan, safe on prod)
valkey-cli -h $SEED -p 6379 -a $PASS --bigkeys
valkey-cli -h $SEED -p 6379 -a $PASS --memkeys     # like bigkeys but ranked by memory footprint

# Hot keys (sampling, more invasive)
valkey-cli -h $SEED -p 6379 -a $PASS --hotkeys

# Per-command stats — what the app is actually calling
valkey-cli -h $SEED -p 6379 -a $PASS info commandstats | grep -E '^cmdstat_(xadd|hincrby|zincrby|publish|spublish|lpush|get|set)' | sort

# Keyspace overview
valkey-cli -h $SEED -p 6379 -a $PASS info keyspace
```

### Failover test (manual — only do this on a non-prod cluster)

Promotes a replica to take over its primary's slots.

```sh
# Pick a primary. In the default shared-IP mode nodes are addressed by PORT:
# primary-1 = $SEED:6380, its by-index replica secondary-1 = $SEED:6383.
PRIMARY=valkey-primary-1
PRIMARY_PORT=6380
SECONDARY=valkey-secondary-1     # the replica that backs it (chart pairing is by-index)
SECONDARY_PORT=6383

# Before — confirm topology
valkey-cli -h $SEED -p $PRIMARY_PORT -a $PASS info replication

# Take the primary offline (cleanest way: kubectl delete pod — the StatefulSet recreates it)
kubectl -n valkey delete pod $PRIMARY

# Within a few seconds the secondary should promote itself.
# Watch from any other primary:
watch "valkey-cli -h $SEED -p 6379 -a $PASS cluster nodes | grep -E 'master|slave'"
# You should see the $SEED:$SECONDARY_PORT entry flip from 'slave' to 'master'.

# When the StatefulSet recreates the original primary pod, it comes back as a replica.
# Verify:
sleep 30
valkey-cli -h $SEED -p $PRIMARY_PORT -a $PASS info replication | grep -E '^role|^master_host'
```

### When something looks wrong

| Symptom | First check |
|---|---|
| `valkey-cli` connects but most commands time out | `cluster info` — if `cluster_state:fail`, a primary lost quorum |
| `MOVED` to an IP that's `(error) Could not connect` | `host-routes.sh list` — route hop missing or `iface != bridge100`; or that pod is down |
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
cd app
mvn test       # unit (Mockito + @WebMvcTest)
mvn verify     # adds Testcontainers integration tests (needs docker)
```

`*IT.java` tests under `src/it/java` use Testcontainers to spin up
Oracle Free + IBM MQ. They're bound to `mvn verify` via Failsafe.

## When something breaks

1. Read `~/.claude/projects/-Users-techdesigns-dev-debugging-java-springboot-k8s/memory/k8s_gotchas.md`
   — most "surprises" are documented there with the root cause.
2. The most common categories of breakage:
   - **Volume mount hiding image content** (Oracle PVC, MQ MQSC,
     Artifactory security files)
   - **Apple Silicon arm64 vs amd64 manifest lists** (IBM MQ)
   - **Flyway baseline-on-migrate** masking unrun migrations
   - **Spring AOP self-invocation** for `@Cacheable`
   - **HPA + Recreate** silently disabling scale-out
3. For chart-level issues, `helm get manifest <release> -n <ns>` shows
   exactly what was applied; compare to template output via
   `helm template`.
