# Stateful storage in this POC

This document explains how storage is configured for the repository's StatefulSets and PVCs, what Kubernetes creates from the Helm charts, and why this setup is only appropriate for the local POC.

Short version: the charts create `ReadWriteOnce` PVCs and leave `storageClassName` empty by default. On k3s, that normally binds to the default `local-path` StorageClass. That is useful for a local lab, but it is not production-grade HA storage.

Related documents:

- [docs/k3s-architecture.md](k3s-architecture.md) explains the overall lab topology.
- [docs/metallb-configuration.md](metallb-configuration.md) explains why MetalLB IP failover is separate from StatefulSet storage recovery.
- [docs/lb-tier-keepalived-haproxy.md](lb-tier-keepalived-haproxy.md) explains the frontend/load-balancer tier.

## Scope

This document covers storage for the charts that create StatefulSets and PVCs:

- Valkey primaries and secondaries
- Oracle Database Free
- IBM MQ
- Artifactory JCR
- Artifactory Postgres

It also notes the app's `emptyDir` heap-dump volume, because that is intentionally ephemeral and often confused with persistent storage.

This document does not describe production storage architecture for Oracle, IBM MQ, Valkey, or Artifactory in depth. Those systems each have their own production durability, backup, replication, and recovery requirements.

## POC-only constraint

The storage configuration in this repository is intentionally lightweight.

It is designed for:

- local k3s on Lima VMs
- reproducible demos
- debugger and failure-mode experiments
- quick reinstall/uninstall loops
- low operational complexity
- exercising StatefulSet/PVC mechanics without external storage dependencies

It is not designed for:

- production durability
- multi-zone or rack-aware failover
- transparent volume reattachment after node loss
- storage-level replication
- backup and restore compliance
- database-grade recovery objectives
- sustained enterprise workloads

Do not treat the default storage configuration as production-ready.

## How the charts request storage

The StatefulSet charts use `volumeClaimTemplates`. That means Kubernetes creates one PVC per StatefulSet pod ordinal.

The common pattern is:

```yaml
volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      accessModes: [ReadWriteOnce]
      resources:
        requests:
          storage: <chart value>
```

The chart values expose:

```yaml
storage:
  size: <size>
  storageClassName: ""
```

When `storage.storageClassName` is empty, the templates omit `storageClassName`. Kubernetes then uses the cluster's default StorageClass. In the local k3s lab, the default class is normally `local-path` from the k3s local-path provisioner.

## Storage inventory

| Chart | Kubernetes workload | PVC template | Default size | Default StorageClass behavior | Production grade by default? |
|---|---|---|---:|---|---|
| `charts/valkey` | `StatefulSet/valkey-primary` | `data` | `1Gi` | omitted, uses cluster default | No |
| `charts/valkey` | `StatefulSet/valkey-secondary` | `data` | `1Gi` | omitted, uses cluster default | No |
| `charts/oracle` | `StatefulSet/oracle` | `data` | `10Gi` | omitted, uses cluster default | No |
| `charts/ibm-mq` | `StatefulSet/ibm-mq` | `data` | `5Gi` | omitted, uses cluster default | No |
| `charts/artifactory` | `StatefulSet/artifactory` | `data` | `10Gi` | omitted, uses cluster default | No |
| `charts/artifactory` | `StatefulSet/artifactory-postgres` | `data` | `5Gi` | omitted, uses cluster default | No |

The Spring Boot app is a Deployment, not a StatefulSet. It mounts an `emptyDir` at `/tmp/heapdumps` for JVM OOM heap dumps. That data is pod-local and ephemeral.

## What local-path means in this lab

`local-path` dynamically provisions PersistentVolumes backed by disk on a Kubernetes node. It is simple and works well for a single-machine or small local cluster POC.

The tradeoff is that the data is tied to node-local storage. If the pod restarts on the same node, the data can remain available. If the node is lost or the workload must move to another node, the volume may not be attachable there.

In practical terms:

```text
pod restart on same node: usually fine
pod reschedule to another node: not guaranteed
worker VM deleted or corrupted: local data may be lost or stranded
cluster uninstall: data is expected to be removed with the lab
```

That is acceptable for this repository's local goals.

## StatefulSet behavior with local-path

StatefulSets provide stable pod names and stable PVC identities:

```text
valkey-primary-0      -> data-valkey-primary-0
valkey-primary-1      -> data-valkey-primary-1
valkey-primary-2      -> data-valkey-primary-2
valkey-secondary-0    -> data-valkey-secondary-0
...
```

That identity is useful, but it is not the same as storage HA.

StatefulSet gives you:

- stable pod ordinal
- stable network identity through headless Services
- stable PVC identity per pod
- predictable replacement behavior

StatefulSet does not automatically give you:

- replicated disk
- cross-node volume mobility
- automatic backup
- transparent storage failover
- zone-aware data placement
- application-consistent restore

The local chart setup deliberately keeps those concerns out of scope.

## Valkey-specific notes

Valkey has six StatefulSet pods:

```text
3 primaries:   valkey-primary-0..2
3 secondaries: valkey-secondary-0..2
```

Each pod has its own `data` PVC mounted at `/data`. Valkey persistence is enabled in the config with AOF:

```text
appendonly yes
dir /data
```

The Valkey cluster can handle some application-level failures through primary/replica behavior. That does not make the underlying PVCs HA.

Important distinction:

```text
Valkey replica promotion: application-level cluster behavior
PVC reattachment or replication: storage-platform behavior
```

With local-path storage, a worker failure can have two different outcomes:

- MetalLB may move the shared backend IP announcement to a surviving worker.
- Valkey pod recovery may still be blocked or degraded if the pod's PVC was on the failed worker.

Those are separate layers. Network failover does not imply storage failover.

## Oracle, IBM MQ, and Artifactory notes

Oracle, IBM MQ, Artifactory, and Artifactory Postgres are also configured for local POC persistence.

The charts use single-replica StatefulSets with one PVC each. This is enough to preserve state across pod restarts during local testing.

For production, each of these systems needs its own storage and recovery design:

- Oracle: supported database storage, backup/recovery, archive log strategy, and operational runbooks
- IBM MQ: durable queue manager storage, backup/restore, HA or multi-instance strategy where appropriate
- Artifactory: supported filestore/database architecture, object storage or shared storage where appropriate, and backup strategy
- Postgres: production-grade persistent storage, backup/restore, monitoring, and HA if required

## What would make this production-grade

A production storage design would need more than setting a larger PVC size.

At minimum, evaluate:

- a real CSI-backed StorageClass
- volume reattachment behavior after worker failure
- storage replication or platform-level durability
- backup and restore tooling
- restore testing
- application-consistent snapshots where required
- node, rack, or zone placement policies
- anti-affinity so primaries and replicas do not share one failure domain
- capacity planning and alerting
- filesystem and disk latency expectations
- upgrade and migration procedures

Depending on the platform, viable storage options might include cloud block storage, vSphere CNS, Portworx, Longhorn, OpenEBS, enterprise SAN-backed CSI, or a managed service-specific storage layer. The correct choice depends on the production Kubernetes platform and the stateful service's support matrix.

## How to override the StorageClass

Each stateful chart exposes `storage.storageClassName`.

Example:

```sh
helm upgrade --install valkey charts/valkey \
  --namespace valkey \
  --set storage.storageClassName=production-storage-class
```

The exact install scripts may pass additional values. The point is that the chart supports overriding the StorageClass, but the repository default intentionally does not pick a production class.

Changing `storageClassName` after PVCs already exist is not normally a safe in-place change. In Kubernetes, PVC storage class is effectively immutable for this purpose. Migrating existing data to a new storage class requires a deliberate migration plan.

## Operational checks

Check the default StorageClass:

```sh
kubectl --kubeconfig dumps/k3s.kubeconfig get storageclass
```

In the lab, expect `local-path` to be default.

Check PVCs:

```sh
kubectl --kubeconfig dumps/k3s.kubeconfig get pvc -A
```

Check where Valkey pods are running:

```sh
kubectl --kubeconfig dumps/k3s.kubeconfig -n valkey get pods -o wide
```

Check the PVs backing the claims:

```sh
kubectl --kubeconfig dumps/k3s.kubeconfig get pv -o wide
```

Inspect a specific PVC:

```sh
kubectl --kubeconfig dumps/k3s.kubeconfig -n valkey describe pvc data-valkey-primary-0
```

## Failure behavior summary

With the repository defaults:

```text
StatefulSet identity: yes
PVC per pod: yes
Persistent across pod restart: yes, when the node/local volume remains available
HA storage: no
Cross-node transparent failover: no
Production durability: no
```

This is intentional: the storage exists to support a local debugging and networking POC, including the MetalLB TCP ingress path for Valkey RESP.
