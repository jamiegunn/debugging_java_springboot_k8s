# Valkey TCP ingress and RESP routing

This document explains the Valkey TCP ingress POC: how clients reach Valkey over RESP, why HTTP ingress is not involved, why there is one Kubernetes Service per Valkey pod, and why those Services share one MetalLB backend IP.

Short version: Valkey speaks RESP over TCP, not HTTP. The cluster needs clients to reach specific Valkey nodes by hostname and port. The repo proves that Kubernetes can expose that shape with per-pod `LoadBalancer` Services, one shared MetalLB backend IP, and unique ports that preserve Valkey node identity.

Related documents:

- [docs/metallb-configuration.md](metallb-configuration.md) explains the MetalLB resources that assign and announce the shared backend IP.
- [docs/lb-tier-keepalived-haproxy.md](lb-tier-keepalived-haproxy.md) explains the frontend VIP and HAProxy/F5 mapping.
- [docs/production-translation-guide.md](production-translation-guide.md) explains what carries forward to production.
- [docs/k3s-architecture.md](k3s-architecture.md) explains the full lab topology.

## What this POC proves

The POC proves that a non-HTTP TCP service can be exposed through Kubernetes while preserving application-level node identity.

For Valkey cluster mode, node identity matters because clients receive redirects like:

```text
MOVED <slot> valkey.debug-demo.local:6380
ASK <slot> valkey.debug-demo.local:6381
```

A redirect must land on the specific Valkey node that owns or is temporarily serving the slot. The load-balancer path cannot randomly distribute all TCP connections across all Valkey pods.

The intended external contract is:

```text
one hostname
multiple ports
one reachable Valkey node per port
```

## Required Valkey semantics

This is not only a socket-connectivity test. The route must preserve the normal
Valkey/Redis cluster semantics that the application uses.

The app and scripts exercise these command families:

| Semantic area | App surface | Representative commands | Why it matters |
|---|---|---|---|
| Basic cache / KV | `POST /api/valkey/kv/{key}`, `GET /api/valkey/kv/{key}`, Spring Cache for customers/orders | `SET`, `GET`, `EX`, `TTL`, `DEL` through cache eviction | Proves ordinary cache verbs survive hostname redirects and TTL handling. |
| Hashes | `GET /api/valkey/stats/{customerId}` and order creation fan-out | `HSET`, `HINCRBY`, `HINCRBYFLOAT`, `HGETALL` | Tracks per-customer order counters and spend. Hash tags like `{customerId}` keep related keys on one slot. |
| Lists | `GET /api/valkey/recent?n=...` and order creation fan-out | `LPUSH`, `LTRIM`, `LRANGE`, `LLEN` | Maintains a capped recent-orders feed with bounded memory. |
| Sorted sets | `GET /api/valkey/leaderboard?n=...` and order creation fan-out | `ZINCRBY`, `ZREVRANGE WITHSCORES`, `ZCARD` | Maintains a customer-spend leaderboard. |
| Streams | `/api/valkey/streams/*` and order creation fan-out | `XADD`, `XLEN`, `XREAD`, `XINFO`, consumer-group `XREADGROUP`/`XACK` behavior | Appends order events and lets each app replica consume from the `order-processors` group. |
| Classic pub/sub | `/api/valkey/pubsub/publish`, `/api/valkey/pubsub/received`, order creation fan-out | `PUBLISH`, `SUBSCRIBE`, `PUBSUB NUMSUB` | Broadcasts order notifications across the cluster bus. |
| Sharded pub/sub | `/api/valkey/pubsub/spublish` | `SPUBLISH`, `PUBSUB SHARDCHANNELS` | Exercises slot-pinned pub/sub behavior for `{orders}:sharded`. |
| Cluster redirects | smoke and cluster tests | `MOVED`, `ASK`, `ASKING`, cluster-aware `valkey-cli -c` behavior | Proves redirect targets are reachable as hostname-plus-port endpoints. |
| Replica behavior | cluster tests | `READONLY`, `READWRITE`, `WAIT`, replica `GET` redirects | Proves replica reads and acknowledgement semantics still behave like a real Valkey cluster. |

The order write path intentionally fans out across several of these operations:

```text
POST /api/orders
  -> Oracle write
  -> IBM MQ publish
  -> XADD orders:events
  -> PUBLISH orders:notifications
  -> HINCRBY/HSET customer:stats:{customerId}
  -> ZINCRBY customers:top
  -> LPUSH + LTRIM orders:recent
```

That is the semantic contract the TCP ingress path must support. A route that
can only complete `PING` or a single `GET` is not enough for this POC.

## How the semantics are validated

Validation is split by depth:

- `scripts/k3s-smoke.sh` proves the happy path: app order creation fans out to
  Oracle, MQ, and Valkey; direct app KV `SET`/`GET` works; the cluster reports
  healthy; hostname-based MOVED targets are returned and reachable.
- `scripts/valkey-tour.sh` is a read-oriented operational tour of strings,
  hashes, lists, sorted sets, streams, pub/sub, command stats, slowlog, and
  latency.
- `scripts/valkey-cluster-tests.sh` is the deep cluster-semantics suite for
  MOVED, ASK, slot migration, replicas, classic pub/sub, sharded pub/sub, and
  failover/failback.

## Why HTTP ingress is not used

HTTP ingress controllers understand HTTP routing concepts:

- host headers
- paths
- TLS termination
- HTTP headers
- HTTP health behavior
- HTTP redirects

Valkey uses RESP over TCP. A normal HTTP Ingress cannot parse or route Valkey commands safely because Valkey traffic is not HTTP.

Therefore:

```text
Spring Boot API / Swagger / actuator -> HTTP ingress-nginx path
Valkey RESP traffic                  -> TCP LoadBalancer Service path
```

This separation is intentional. HTTP and Valkey use different protocols and need different ingress patterns.

## Why one Service per Valkey pod

A Kubernetes Service has one selector for all of its ports. That means one Service cannot say:

```text
port 6379 -> valkey-primary-0 only
port 6380 -> valkey-primary-1 only
port 6381 -> valkey-primary-2 only
```

If a single Service selected all Valkey pods, each port would target the same endpoint set. kube-proxy could send a connection for port `6380` to the wrong pod, breaking Valkey cluster redirects.

The chart instead renders one Service per pod:

```text
valkey-primary-0-ext   -> valkey-primary-0   -> 6379
valkey-primary-1-ext   -> valkey-primary-1   -> 6380
valkey-primary-2-ext   -> valkey-primary-2   -> 6381
valkey-secondary-0-ext -> valkey-secondary-0 -> 6382
valkey-secondary-1-ext -> valkey-secondary-1 -> 6383
valkey-secondary-2-ext -> valkey-secondary-2 -> 6384
```

Each Service selector matches one pod using `statefulset.kubernetes.io/pod-name`.

## Why the Services share one MetalLB IP

The chart needs one Service per pod for selector correctness, but it does not need one backend IP per pod.

Each Service uses a unique TCP port. That allows the Services to share one MetalLB IP:

```text
192.168.105.200:6379 -> valkey-primary-0
192.168.105.200:6380 -> valkey-primary-1
192.168.105.200:6381 -> valkey-primary-2
192.168.105.200:6382 -> valkey-secondary-0
192.168.105.200:6383 -> valkey-secondary-1
192.168.105.200:6384 -> valkey-secondary-2
```

This reduces IPAM and firewall complexity. In a corporate environment, the difference is important:

```text
naive model: one backend IP per Valkey pod
chosen model: one shared backend IP for the Valkey cluster, distinguished by port
```

MetalLB allows this through shared-IP annotations when the Services share a key and do not conflict on ports.

## Port identity

The Valkey chart assigns unique client and bus ports by ordinal:

```text
primary-0   client 6379, bus 16379
primary-1   client 6380, bus 16380
primary-2   client 6381, bus 16381
secondary-0 client 6382, bus 16382
secondary-1 client 6383, bus 16383
secondary-2 client 6384, bus 16384
```

Only the client ports are exposed through the external LoadBalancer Services. The bus ports are for pod-to-pod cluster internals.

The external node identity is therefore:

```text
valkey.debug-demo.local:<client-port>
```

not:

```text
unique hostname per pod
unique external IP per pod
pod IP exposed to clients
```

## Lab traffic path

For a GET or SET that reaches `valkey-primary-1`, the path is:

```text
client
  -> valkey.debug-demo.local:6380
  -> DNS resolves hostname to keepalived VIP
  -> HAProxy TCP frontend on ddk3s-lb
  -> shared MetalLB backend IP:6380
  -> valkey-primary-1-ext LoadBalancer Service
  -> valkey-primary-1 pod
```

The same rule applies to every port:

```text
VIP:6379 -> MetalLB IP:6379 -> valkey-primary-0
VIP:6380 -> MetalLB IP:6380 -> valkey-primary-1
VIP:6381 -> MetalLB IP:6381 -> valkey-primary-2
VIP:6382 -> MetalLB IP:6382 -> valkey-secondary-0
VIP:6383 -> MetalLB IP:6383 -> valkey-secondary-1
VIP:6384 -> MetalLB IP:6384 -> valkey-secondary-2
```

HAProxy is not Valkey-aware. It forwards TCP by port. Kubernetes Service routing then sends that port to the Service's selected pod.

## Production traffic path

The production shape is the same responsibility split with production components:

```text
client
  -> valkey.company.example:<6379-6384>
  -> F5 / NetScaler / cloud LB frontend VIP
  -> TCP virtual server or listener for that port
  -> shared Kubernetes backend IP:<same port>
  -> per-pod LoadBalancer Service
  -> Valkey pod
```

Production does not require the frontend VIP and backend MetalLB IP to be on the same subnet. It does require the load balancer to reach the backend IP and ports through routing, dual-homing, BGP, or platform integration.

## MOVED and ASK redirects

Valkey cluster clients are expected to follow redirects.

A redirect such as:

```text
MOVED 1234 valkey.debug-demo.local:6380
```

means:

```text
connect to the same hostname, but use port 6380
```

Because every port maps to exactly one Valkey node, the redirect lands on the intended pod.

This is why the chart sets Valkey hostname endpoint behavior instead of exposing pod IPs to clients. Clients get a stable DNS name and a node-specific port.

## Cluster bus and replication path

The Valkey cluster bus is not exposed through MetalLB, HAProxy, the VIP, or F5.

Cluster bus and replication use pod IPs directly on the Kubernetes network:

```text
valkey-primary-0 pod IP:16379 <-> other Valkey pod IP:bus-port
```

This avoids hairpinning node-to-node traffic through the frontend path.

The split is:

```text
client RESP traffic      -> hostname/VIP/HAProxy/MetalLB/client ports
cluster bus/replication  -> pod IPs/CNI/bus ports
```

## MIGRATE exception

Slot migration uses Valkey node-to-node connections. In this lab, `MIGRATE` must target the pod IP, not the frontend hostname.

Reason:

```text
MIGRATE is node-to-node traffic
node-to-node traffic should stay on pod IPs / CNI
pod -> VIP -> HAProxy -> MetalLB -> pod hairpin can time out
```

The live cluster tests derive the target pod IP for migration scenarios. This exception does not change client redirect behavior; clients still use hostname-plus-port.

## What can break this design

This routing model depends on these invariants:

- each Valkey pod listens on a unique client port
- each external Service selects exactly one pod
- shared MetalLB IP is used only with non-overlapping ports
- Valkey announces hostname endpoints
- DNS resolves the Valkey hostname to the frontend VIP
- HAProxy/F5 preserves the destination port mapping
- the cluster bus stays on pod IPs
- clients are cluster-aware and follow MOVED/ASK redirects

Breaking any of those can produce symptoms like redirect loops, connections to the wrong node, timeouts, or a cluster that forms internally but is unreachable from clients.

## Operational checks

Render the Services:

```sh
helm template valkey charts/valkey \
  --set loadBalancer.sharedIP=192.168.105.200 \
  --set loadBalancer.sharingKey=valkey-cluster
```

Check Services in the live lab:

```sh
kubectl --kubeconfig dumps/k3s.kubeconfig -n valkey get svc -o wide
```

Check Valkey cluster topology:

```sh
scripts/valkey-cluster-tests.sh --skip-failover
```

Inspect HAProxy mapping:

```sh
limactl shell ddk3s-lb -- sudo cat /etc/haproxy/haproxy.cfg
```

## Design summary

The Valkey TCP ingress POC is intentionally narrow:

```text
RESP is TCP
TCP ingress needs port-preserving routing
Valkey cluster redirects require deterministic node reachability
Kubernetes needs one Service per pod for one-pod selectors
MetalLB shared IP reduces backend IP consumption
HAProxy/F5 forwards TCP by port, not by Valkey command
```

That is the core networking behavior this repo proves.
