# debugging_java_springboot_k8s

A Spring Boot 3.3 / Java 21 service designed as the **target** for a
toolkit that diagnoses memory- and CPU-related issues in JVM pods on
Kubernetes — heap pressure, GC thrash, thread starvation, leaks, slow
JDBC/JMS hand-offs. The CRUD API and Helm charts exist mainly to give
the test tools something realistic to operate on.

## Constraint that shapes everything

**No JDK tools to capture or analyze thread/heap dumps.** The runtime
image is JRE-only (`eclipse-temurin:21-jre-alpine`) and the diagnostic
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
   --image=eclipse-temurin:21-jdk-alpine ...` — `scripts/dump-threads.sh`
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
   │   seeding   │      │             │  │  pool 192.168.5.200-220  │
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

Cluster-side: per-service-per-pod LoadBalancer Services backed by
MetalLB, pinned to the `192.168.64.50-60` pool. Mac-side: a thin
static-route hop that stands in for the production VIP/LB.

```
   External clients (Postman, valkey-cli, anything off-cluster)
                         │
                         │   prod: real VIP / external LB
                         │   dev:  scripts/host-routes.sh add
                         │        (sudo route — next-hop = RD VM @ 192.168.64.2)
                         ▼
        ─── MetalLB pool 192.168.64.50–60 (bridge subnet) ───
                         │
                         ▼
   192.168.64.50 → app-debug-demo-app-ext   (selector: all app replicas)
   192.168.64.51 → valkey-primary-0-ext     (selector: just primary-0 by pod-name)
   192.168.64.52 → valkey-primary-1-ext     (just primary-1)
   192.168.64.53 → valkey-primary-2-ext     (just primary-2)
   192.168.64.54 → valkey-secondary-0-ext   (just secondary-0)
   192.168.64.55 → valkey-secondary-1-ext   (just secondary-1)
   192.168.64.56 → valkey-secondary-2-ext   (just secondary-2)
```

Each Valkey pod announces its **own external IP** via
`cluster-announce-ip` (derived from pod ordinal at startup, see
`statefulset-primary.yaml` entrypoint). So `CLUSTER NODES` / `CLUSTER
SHARDS` return externally-resolvable endpoints, and `MOVED` redirects
to external clients point at the right shard's per-pod LB.

**Why per-service-per-pod, not one shared LB:** round-robin across all
6 pods works *only* for stateless GET/SET and classic pub/sub. It breaks
`MULTI`/`EXEC`, multi-key Lua (which we don't use anyway), `WAIT`, and
sharded `SSUBSCRIBE`/`SPUBLISH` pinning. We model the production-correct
shape so the cluster config travels unchanged from POC → real
deployment; only the VIP layer in front swaps out.

**Why the dev `sudo route` hop exists:** Rancher Desktop's vz-NAT mode
only ARP-responds for the VM's own IP (`192.168.64.2`). MetalLB
advertises additional IPs in the bridge subnet, but those ARP
responses don't pass through the NAT to the host. The static route
tells macOS to use the VM as next-hop for each MetalLB IP; the VM's
kube-proxy iptables then DNATs to the right pod. In a real
environment, this hop is your real LB.

```sh
scripts/host-routes.sh add        # one-time per boot, prompts for sudo
scripts/test-external-access.sh   # curl app, valkey-cli ping + cluster info + SET/GET
scripts/host-routes.sh remove     # tear down
```

After `add`:

```sh
curl http://192.168.64.50:8080/actuator/health
valkey-cli -c -h 192.168.64.51 -p 6379 -a <pwd> cluster info
valkey-cli -c -h 192.168.64.51 -p 6379 -a <pwd> set hello world   # follows MOVED
```

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
| `charts/debug-demo-app/` | The app, with HPA (1→10 @ 20% CPU), Valkey/Oracle/MQ wiring, **internal ClusterIP + external LoadBalancer Service** (`192.168.64.50`). |
| `charts/oracle/` | Oracle Free with PVC-seeding initContainer (image pre-bakes the DB). |
| `charts/ibm-mq/` | IBM MQ amd64 (no arm64 image; runs under Rosetta on Apple Silicon). |
| `charts/valkey/` | 6-node Valkey 8 cluster; primary-N ↔ secondary-N pairing; **per-service-per-pod LoadBalancer** with `cluster-announce-ip` from pod ordinal. |
| `charts/artifactory/` | JFrog Container Registry + Postgres sidecar; local Docker + Helm repo. |
| `scripts/` | `dump-threads.sh`, `dump-heap.sh`, `dump-jattach.sh`, `memory-report.sh`, `tail-logs.sh`, `set-log-level.sh`, `local-ci.sh`, `host-routes.sh` (dev VIP stand-in), `test-external-access.sh` |
| `harness/pipeline.yaml` | Harness CD pipeline (Native Helm). |
| `.github/workflows/` | CI: PR validation + main build → Artifactory. |
| `~/.claude/projects/.../memory/k8s_gotchas.md` | Non-obvious workarounds — read this first when something breaks. |

## How to install everything

```sh
# 0. One-time RD bump (default 2 CPU / 6 GB is too small for the full stack)
rdctl set --virtual-machine.memory-in-gb=16 --virtual-machine.number-cpus=8

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

## Integration tools — what to install for what

| Failure mode | Charts needed |
|--------------|---------------|
| Pure JVM heap/CPU experiments | `debug-demo-app` only (Valkey/Oracle/MQ optional, app starts without them in `local` profile) |
| JDBC contention | `oracle` + `debug-demo-app` |
| MQ producer/consumer scenarios | `ibm-mq` + `debug-demo-app` |
| Distributed cache scenarios | `valkey` + `debug-demo-app` |
| Full-stack flow | all four + (optionally) `artifactory` for local CI loop |

## Conventions

- **Image:** runtime is `eclipse-temurin:21-jre-alpine`. Do not bake
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
