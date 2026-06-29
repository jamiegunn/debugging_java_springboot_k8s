# Helm charts

Four independent charts. Install Oracle, IBM MQ, and Artifactory first (no
inter-dependencies), then the app last (depends on Oracle + MQ):

```sh
helm upgrade --install oracle      ./oracle      -n oracle      --create-namespace \
  --set image.repository=gvenzl/oracle-free \
  --set image.tag=23-slim-faststart

helm upgrade --install ibm-mq      ./ibm-mq      -n mq          --create-namespace \
  --set image.tag=9.4.5.1-r1-amd64        # arm64 needs the -amd64 tag

helm upgrade --install artifactory ./artifactory -n artifactory --create-namespace

helm upgrade --install valkey      ./valkey      -n valkey      --create-namespace
# Requires MetalLB pre-installed with an IPAddressPool named "debug-demo-pool"

helm upgrade --install app         ./debug-demo-app -n debug-demo --create-namespace \
  --set image.repository=debug-demo-app \
  --set image.tag=dev \
  --set image.pullPolicy=Never            # use locally-built image
```

Once you've pushed an image + charts to Artifactory via `scripts/local-ci.sh`,
swap the app install over to pull from the local registry:

```sh
helm upgrade --install app ./debug-demo-app -n debug-demo \
  --set image.repository=artifactory-artifactory.artifactory.svc.cluster.local:8082/debug-demo-docker/debug-demo-app \
  --set image.tag=$(git rev-parse --short HEAD) \
  --set image.pullPolicy=IfNotPresent
```

To uninstall: `helm uninstall` each release. The Oracle and MQ StatefulSets
keep their PVCs after `helm uninstall`; delete them explicitly if you want a
clean slate.

## Notes

- `debug-demo-app` reads Oracle + MQ passwords from a `Secret`. Override
  `oracle.existingSecret` / `mq.existingSecret` in `values.yaml` to use a
  pre-existing secret instead of one created by the chart.
- The app `Deployment` sets `shareProcessNamespace: true` so the debug
  scripts (`scripts/dump-threads.sh`, `scripts/dump-heap.sh`) can attach an
  ephemeral JDK container that targets the app's PID 1.
- Oracle Free image (`container-registry.oracle.com/database/free`)
  requires accepting the license — for local dev the chart defaults to
  `gvenzl/oracle-free` from Docker Hub. The Oracle chart's `initContainer`
  seeds the PVC with the image's pre-baked database; don't remove it.
- IBM MQ has no native arm64 image. On Apple Silicon you must use a
  `-amd64`-suffixed tag and rely on Rosetta emulation.
- Artifactory chart defaults: `admin / Admin123!`, web UI at port 8082,
  pre-creates `debug-demo-docker` and `debug-demo-helm` repos via a
  post-install Job. Needs ~1 GiB memory minimum — bump the Rancher Desktop
  VM memory if your default is below 8 GB.
- Valkey chart provisions 6 pods across two StatefulSets (`valkey-primary-{0..2}`
  and `valkey-secondary-{0..2}`). A post-install Job bootstraps the cluster
  with explicit `primary-N ↔ secondary-N` pairing. External access is via a
  LoadBalancer Service backed by MetalLB's `debug-demo-pool`. Install
  MetalLB + the IPAddressPool/L2Advertisement before this chart.
