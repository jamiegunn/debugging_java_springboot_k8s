# Helm charts

Four independent charts. Install Oracle, IBM MQ, and Artifactory first (no
inter-dependencies), then the app last (depends on Oracle + MQ). On the k3s
stack all of this is driven for you by `scripts/k3s-charts.sh` (part of
`scripts/k3s.sh install`), which points `helm` at `dumps/k3s.kubeconfig` and
runs against the air-gapped, pre-imported images. The manual equivalent:

```sh
export KUBECONFIG=dumps/k3s.kubeconfig      # the 3-node k3s cluster

helm upgrade --install oracle      ./oracle      -n oracle      --create-namespace \
  --set image.repository=gvenzl/oracle-free \
  --set image.tag=23-slim-faststart --set image.pullPolicy=IfNotPresent

helm upgrade --install ibm-mq      ./ibm-mq      -n mq          --create-namespace \
  --set image.tag=9.4.5.1-r1-amd64 --set image.pullPolicy=IfNotPresent  # arm64 → -amd64 tag

helm upgrade --install valkey      ./valkey      -n valkey      --create-namespace \
  --set image.pullPolicy=IfNotPresent \
  --set loadBalancer.announceHostname=valkey.debug-demo.local

helm upgrade --install app         ./debug-demo-app -n debug-demo --create-namespace \
  --set image.repository=debug-demo-app --set image.tag=dev --set image.pullPolicy=Never \
  --set ingress.enabled=true --set ingress.className=nginx \
  --set 'ingress.hosts[0].host=debug-demo.local' \
  --set 'hostAliases[0].ip=192.168.105.100' \
  --set 'hostAliases[0].hostnames[0]=valkey.debug-demo.local'
```

`type: LoadBalancer` Services (the Valkey per-pod endpoints) are fulfilled by
**MetalLB** (L2/ARP mode; k3s's built-in klipper/servicelb is disabled) — each
shard gets its own IP from a pool (no shared-IP annotations, no per-pod IPs).
External reach is via the **keepalived VIP `192.168.105.100`** on the LB VM,
whose HAProxy maps each port to that shard's MetalLB IP; Valkey's per-pod
Services are addressed by port and announced as `valkey.debug-demo.local:<port>`.

To uninstall: `scripts/k3s.sh uninstall`, or `helm uninstall` each release. The
Oracle and MQ StatefulSets keep their PVCs after `helm uninstall`; delete them
explicitly (`kubectl -n <ns> delete pvc --all`) for a clean slate.

## Notes

- `debug-demo-app` reads Oracle + MQ passwords from a `Secret`. Override
  `oracle.existingSecret` / `mq.existingSecret` in `values.yaml` to use a
  pre-existing secret instead of one created by the chart.
- The app `Deployment` sets `shareProcessNamespace: true` so debug
  sidecars / ephemeral containers (`scripts/dump-threads.sh`,
  `scripts/dump-heap.sh`) can see the JVM process. Side effect: PID 1 in
  the shared namespace is the `/pause` sandbox, NOT the JVM — every tool
  must discover the java PID dynamically (walk `/proc/*/comm`), never
  hardcode PID 1. It also pins
  `valkey.debug-demo.local → VIP` via `hostAliases` (Lettuce/netty mishandles
  k8s `ndots:5` search-domain expansion).
- Oracle Free image (`container-registry.oracle.com/database/free`)
  requires accepting the license — for local dev the chart defaults to
  `gvenzl/oracle-free` from Docker Hub. The Oracle chart's `initContainer`
  seeds the PVC with the image's pre-baked database; don't remove it.
- IBM MQ has no native arm64 image. On Apple Silicon you must use a
  `-amd64`-suffixed tag and rely on Rosetta emulation.
- Artifactory chart defaults: `admin / Admin123!`, web UI at port 8082,
  pre-creates `debug-demo-docker` and `debug-demo-helm` repos via a
  post-install Job. Needs ~1 GiB memory minimum. (Optional — only for the
  `scripts/local-ci.sh` in-cluster registry loop; not installed by default.)
- Valkey chart provisions 6 pods across two StatefulSets (`valkey-primary-{0..2}`
  and `valkey-secondary-{0..2}`). A post-install Job bootstraps the cluster
  with explicit `primary-N ↔ secondary-N` pairing. Each pod listens on a unique
  port (client `6379+idx`, bus `16379+idx`) and announces its **pod IP** for
  gossip/replication (direct pod-to-pod on the CNI network) plus the
  **hostname** `valkey.debug-demo.local` for clients — so `CLUSTER SHARDS` /
  `MOVED` hand clients a resolvable name, routed VIP → HAProxy → MetalLB IP →
  the owning pod.
