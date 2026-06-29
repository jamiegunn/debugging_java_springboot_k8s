# debugging_java_springboot_k8s

A Spring Boot 3.3 / Java 21 service with Oracle + IBM MQ, deployable to
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

| Method | Path | Notes |
|--------|------|-------|
| GET / POST / PUT / DELETE | `/api/customers[/{id}]` | Standard CRUD |
| GET / POST / PUT / DELETE | `/api/orders[/{id}]` | POST publishes `OrderCreatedEvent` to MQ |
| POST | `/api/batch/customers/load?file=PATH` | Triggers Spring Batch CSV load |
| GET | `/actuator/health/{liveness,readiness}` | k8s probes |
| GET/POST | `/actuator/loggers/{name}` | Runtime log-level changes |
| GET | `/actuator/threaddump`, `/actuator/heapdump`, `/actuator/prometheus` | Diagnostics |

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

## Deploying to local Kubernetes

```sh
minikube start --memory=8192 --cpus=4
kubectl create namespace debug-demo 2>/dev/null || true

helm upgrade --install oracle  ./charts/oracle  -n oracle --create-namespace
helm upgrade --install ibm-mq  ./charts/ibm-mq  -n mq     --create-namespace
helm upgrade --install app     ./charts/debug-demo-app -n debug-demo \
  --set image.repository=artifactory.example.com/debug-demo/debug-demo-app \
  --set image.tag=<sha>

kubectl -n debug-demo port-forward svc/app-debug-demo-app 8080:8080
curl -s localhost:8080/actuator/health
```

Install order matters: Oracle must be Ready before the app can pass
its readiness probe (Flyway runs at startup).

## Debug tooling

All scripts default to namespace `debug-demo` and selector
`app.kubernetes.io/name=debug-demo-app`. Override with `-n` / `-l`.

```sh
scripts/tail-logs.sh                                    # multi-replica log stream
scripts/set-log-level.sh com.example.debugdemo DEBUG    # runtime log-level toggle
scripts/dump-threads.sh                                 # writes ./dumps/threads/<pod>-thread-*.txt
scripts/dump-heap.sh --confirm                          # writes ./dumps/heap/<pod>-heap-*.hprof
```

The dump scripts use `kubectl debug` to attach an ephemeral
`eclipse-temurin:21-jdk-alpine` container — the runtime image is JRE only,
so `jstack` / `jmap` aren't present in the app container itself. The
Deployment sets `shareProcessNamespace: true`, which lets the debug
container address the JVM as PID 1.

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
