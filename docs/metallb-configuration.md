# MetalLB configuration in this k3s stack

This document explains how MetalLB is configured at the Kubernetes level in this repository, what assumptions the design depends on, what it does not solve, and how Valkey traffic is routed through the installed MetalLB resources.

MetalLB gives Kubernetes `LoadBalancer` Services a real IP address on the local Lima network. In this stack, the Valkey Services share one MetalLB IP and use different ports to reach different Valkey pods. A separate LB VM owns the client-facing VIP and HAProxy forwards each Valkey port to the shared MetalLB IP on the same port. The local Mac setup uses one flat L2 network; production will often split the client-facing VIP network from the Kubernetes backend network.

Related documents:

- [docs/lb-tier-keepalived-haproxy.md](lb-tier-keepalived-haproxy.md) explains why the lab uses both keepalived and HAProxy.
- [docs/valkey-tcp-ingress-routing.md](valkey-tcp-ingress-routing.md) is the canonical Valkey RESP/TCP routing guide.
- [docs/production-translation-guide.md](production-translation-guide.md) explains how the local lab maps to production.

## Network assumptions

The local Lima environment puts the Mac, the LB VM, the k3s nodes, the
keepalived VIP, and the MetalLB pool on one shared L2 network
(`192.168.105.0/24`), so the shared backend IP is directly ARP-reachable:

```text
Mac / local client
  -> ddk3s-lb VIP on 192.168.105.0/24
  -> HAProxy on ddk3s-lb
  -> MetalLB shared backend IP on 192.168.105.0/24
  -> k3s worker node
  -> Valkey Service and pod
```

That flat layout is a local convenience; production usually splits the
client-facing VIP network from the Kubernetes backend network. Either way the
**Kubernetes Service model is unchanged**: the Valkey chart still uses one
per-pod `LoadBalancer` Service per node, all sharing one backend MetalLB IP and
distinguished by port. The MetalLB-specific production assumptions (IPAM,
backend reachability, L2 vs BGP) are collected under
[Production MetalLB assumptions](#production-metallb-assumptions) below.

For the L2-vs-routed-vs-NAT background see
[docs/networking-l2-primer.md](networking-l2-primer.md); for the full
lab-to-production mapping see
[docs/production-translation-guide.md](production-translation-guide.md).

## IP minimization constraint

a key design goal is to reduce the number of IP addresses that must be allocated for MetalLB. Ports identify Valkey nodes, so the Services do not need one backend IP per pod.

This repository intentionally minimizes the number of IPs associated with MetalLB `LoadBalancer` Services.

The original naive shape for six Valkey pods would be:

```text
valkey-primary-0   -> MetalLB IP A:6379
valkey-primary-1   -> MetalLB IP B:6380
valkey-primary-2   -> MetalLB IP C:6381
valkey-secondary-0 -> MetalLB IP D:6382
valkey-secondary-1 -> MetalLB IP E:6383
valkey-secondary-2 -> MetalLB IP F:6384
```

That shape is easy for Kubernetes to express, but it is expensive operationally because every Valkey pod consumes a separate backend IP. In a corporate environment, each backend IP may require IPAM allocation, firewall rules, routing review, load balancer configuration, documentation, and ongoing ownership.

The chosen shape is:

```text
valkey-primary-0   -> shared MetalLB IP:6379
valkey-primary-1   -> shared MetalLB IP:6380
valkey-primary-2   -> shared MetalLB IP:6381
valkey-secondary-0 -> shared MetalLB IP:6382
valkey-secondary-1 -> shared MetalLB IP:6383
valkey-secondary-2 -> shared MetalLB IP:6384
```

This preserves deterministic Valkey node addressing because each Valkey pod already has a unique client port. The port, not the IP, identifies the intended Valkey node.

The constraint can be stated as:

```text
Use the smallest practical number of MetalLB backend IPs while preserving deterministic per-Valkey-node routing.
```

For the current six-node Valkey chart, that means one shared MetalLB backend IP for all six per-pod Services. The design still uses multiple Kubernetes Services because each Service needs a different pod selector, but those Services share one external IP because their ports do not overlap.

## Scope

this doc is about MetalLB and the Kubernetes objects around it. It is not the full k3s, Valkey, or HAProxy manual.

This document covers:

- the MetalLB components installed by `scripts/k3s/phases/platform.sh`
- the repository-owned MetalLB CRs in `k3s/manifests/metallb-valkey-pool.yaml`
- the Valkey `type: LoadBalancer` Services rendered by `charts/valkey/templates/service-loadbalancer.yaml`
- how `scripts/k3s/phases/lb.sh` discovers those Services and generates HAProxy backends
- failure and scaling assumptions around worker nodes and control-plane nodes

This document does not cover:

- Valkey cluster slot ownership in depth
- the full Lima VM provisioning flow
- JVM debugging tools
- cloud-provider LoadBalancer implementations

## Resource inventory

MetalLB is installed from a vendored upstream manifest, then this repo adds a small custom MetalLB config that defines the IP pool and which nodes may announce it.

| Resource | Location | Owner | Purpose |
|---|---|---|---|
| MetalLB upstream native manifest | `k3s/manifests/metallb-native-v0.14.9.yaml` | vendored upstream | Installs namespace, CRDs, RBAC, controller Deployment, speaker DaemonSet, webhooks, and supporting resources. |
| MetalLB IP pool and L2 advertisement | `k3s/manifests/metallb-valkey-pool.yaml` | this repo | Defines the `valkey-pool` address range and restricts L2 advertisement to non-control-plane nodes. |
| Valkey per-pod LoadBalancer Services | `charts/valkey/templates/service-loadbalancer.yaml` | this repo | Creates one `type: LoadBalancer` Service per Valkey pod, all sharing one MetalLB IP and using unique ports. |
| MetalLB pool values | `scripts/lib/k3s-env.sh` | this repo | Defines `METALLB_POOL` and `VALKEY_SHARED_LB_IP`. |
| Platform installer | `scripts/k3s/phases/platform.sh` | this repo | Applies MetalLB, waits for readiness, renders/applies the pool manifest, then installs ingress-nginx. |
| LB tier installer | `scripts/k3s/phases/lb.sh` | this repo | Reads Valkey Service `EXTERNAL-IP`s and generates HAProxy TCP frontends/backends. |

## Installation sequence

first the cluster disables k3s's built-in service load balancer, then the platform script installs MetalLB, then the Valkey chart creates Services that MetalLB assigns an external IP to, then HAProxy points at that IP.

The relevant sequence is:

1. `scripts/k3s/phases/cluster.sh` installs k3s with `--disable servicelb`.
2. `scripts/k3s/phases/platform.sh up` applies `k3s/manifests/metallb-native-v0.14.9.yaml`.
3. `scripts/k3s/phases/platform.sh up` waits for `deploy/controller` in `metallb-system`.
4. `scripts/k3s/phases/platform.sh up` waits for `ds/speaker` in `metallb-system` best-effort.
5. `scripts/k3s/phases/platform.sh up` renders `k3s/manifests/metallb-valkey-pool.yaml` by replacing `__METALLB_POOL__` with `METALLB_POOL`.
6. `scripts/k3s/phases/platform.sh up` applies the rendered `IPAddressPool` and `L2Advertisement`.
7. `scripts/k3s/phases/charts.sh up` installs the Valkey Helm chart and passes `loadBalancer.sharedIP=$VALKEY_SHARED_LB_IP` by default.
8. MetalLB assigns the requested shared IP to the Valkey `type: LoadBalancer` Services.
9. `scripts/k3s/phases/lb.sh up` reads the Valkey Services' `.status.loadBalancer.ingress[0].ip` values and writes HAProxy TCP backends.

The install is split this way because MetalLB's validating webhook is served by the MetalLB controller. The pool CRs are retried after the controller rollout because applying CRs too early can fail while the webhook is not ready.

## MetalLB components

the controller assigns IPs and updates Service status; the speakers announce IPs on the network. The speaker is the part that matters for ARP traffic.

The vendored native manifest installs two main runtime components:

- `Deployment/metallb-system/controller`
- `DaemonSet/metallb-system/speaker`

The controller is the control-plane component for MetalLB. It watches Kubernetes Services and MetalLB CRs, allocates addresses from configured pools, serves validating webhooks, and writes LoadBalancer status back to Services.

The speaker is the node-level data-plane component. In L2 mode, speakers participate in deciding which eligible node announces a LoadBalancer IP. The announcing node answers ARP for the LoadBalancer IP, causing traffic for that IP to land on that node.

Important distinction: the controller being scheduled on a node is not the same thing as that node announcing a LoadBalancer IP. Announcement is controlled by MetalLB speaker behavior plus the `L2Advertisement` configuration.

## Repository-owned MetalLB configuration

this repo creates one IP pool for Valkey and tells MetalLB to announce that pool only from worker nodes.

The custom MetalLB config is in `k3s/manifests/metallb-valkey-pool.yaml`:

```yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: valkey-pool
  namespace: metallb-system
spec:
  addresses: ["__METALLB_POOL__"]
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: agents-only
  namespace: metallb-system
spec:
  ipAddressPools: [valkey-pool]
  nodeSelectors:
    - matchExpressions:
        - {key: node-role.kubernetes.io/control-plane, operator: DoesNotExist}
```

`scripts/k3s/phases/platform.sh` renders the placeholder:

```sh
render_metallb_pool() {
    sed "s#__METALLB_POOL__#$METALLB_POOL#g" "$METALLB_POOL_MANIFEST"
}
```

The default pool is defined in `scripts/lib/k3s-env.sh`:

```sh
METALLB_POOL=192.168.105.200-192.168.105.209
VALKEY_SHARED_LB_IP=${METALLB_POOL%%-*}
```

With defaults, the pool is `192.168.105.200-192.168.105.209`, and the Valkey shared backend IP is `192.168.105.200`.

## IP pool assumptions

these are not public IPs. They are private IPs on the Lima shared network. MetalLB can only safely use them if nothing else is using them.

The default MetalLB pool assumes:

- all Lima VMs and the Mac are on the same `192.168.105.0/24` L2 network
- `192.168.105.200-192.168.105.209` is not allocated by DHCP
- no other host on the Lima shared network is using those addresses
- the pool avoids the keepalived VIP, which defaults to `192.168.105.100`
- the pool avoids the low DHCP addresses normally assigned to the Lima VMs
- ARP works across the shared network
- clients that need to reach MetalLB IPs are either on that L2 network or reach them through the LB VM

In a corporate/on-prem environment, the equivalent addresses must be allocated or approved by the network/IPAM team. In this POC, the network is local to the Lima lab, so the repo chooses a high private range in the lab subnet.

## L2Advertisement and node eligibility

MetalLB is told not to advertise Valkey IPs from control-plane nodes. The shared backend IP should be announced from worker nodes only.

The `L2Advertisement` uses this selector:

```yaml
nodeSelectors:
  - matchExpressions:
      - {key: node-role.kubernetes.io/control-plane, operator: DoesNotExist}
```

This means an eligible announcing node must not have the `node-role.kubernetes.io/control-plane` label.

The k3s server is installed with a control-plane taint in `scripts/k3s/phases/cluster.sh`:

```sh
--node-taint node-role.kubernetes.io/control-plane=true:NoSchedule
```

The MetalLB selector and the k3s taint are separate mechanisms:

- the taint prevents ordinary workloads from scheduling on the control-plane node unless they tolerate it
- the `L2Advertisement` restricts which nodes may announce the `valkey-pool` IPs

The upstream MetalLB speaker DaemonSet tolerates control-plane taints. Therefore a speaker pod may exist on a control-plane node, but the Valkey pool's `L2Advertisement` should prevent that node from announcing the Valkey shared IP.

## Why shared IP with multiple Services

there are still multiple Services because each Service needs a different pod selector. They share one IP because the port already tells HAProxy and Valkey which pod is intended.

Valkey cluster clients must be able to reach a specific node when a MOVED/ASK redirect says `valkey.debug-demo.local:<port>`. A normal single Kubernetes Service cannot express this mapping:

```text
port 6379 -> valkey-primary-0 only
port 6380 -> valkey-primary-1 only
port 6381 -> valkey-primary-2 only
```

A Kubernetes Service has one selector for all of its ports. If one Service selected all Valkey pods, every exposed port would share the same backend pod set, which would break deterministic node routing.

This chart instead renders one Service per Valkey pod:

```text
valkey-primary-0-ext   selector pod-name=valkey-primary-0   port 6379
valkey-primary-1-ext   selector pod-name=valkey-primary-1   port 6380
valkey-primary-2-ext   selector pod-name=valkey-primary-2   port 6381
valkey-secondary-0-ext selector pod-name=valkey-secondary-0 port 6382
valkey-secondary-1-ext selector pod-name=valkey-secondary-1 port 6383
valkey-secondary-2-ext selector pod-name=valkey-secondary-2 port 6384
```

Each Service has a one-pod selector, but all Services request the same MetalLB IP when `loadBalancer.sharedIP` is set:

```yaml
metadata:
  annotations:
    metallb.io/allow-shared-ip: "valkey-cluster"
    metallb.io/loadBalancerIPs: "192.168.105.200"
spec:
  type: LoadBalancer
  loadBalancerIP: "192.168.105.200"
  externalTrafficPolicy: Cluster
```

This relies on MetalLB's IP sharing behavior. Services may share a LoadBalancer IP when they use the same sharing key and do not conflict on ports. This design satisfies that condition because each Valkey Service exposes a unique TCP port.

## Valkey Service rendering

the chart makes six Services. Each Service uses the same external IP but a different port and pod selector.

The values controlling this are:

```yaml
loadBalancer:
  enabled: true
  sharedIP: ""
  sharingKey: "valkey-cluster"
  announceHostname: "valkey.debug-demo.local"
  basePorts:
    client: 6379
    bus: 16379
```

`scripts/k3s/phases/charts.sh` passes the local shared IP during install:

```sh
--set loadBalancer.announceHostname="$VALKEY_HOST"
${VALKEY_SHARED_LB_IP:+--set loadBalancer.sharedIP=$VALKEY_SHARED_LB_IP}
```

With defaults, rendered Services request `192.168.105.200`.

The primary Services render ports `6379`, `6380`, and `6381`. The secondary Services render ports `6382`, `6383`, and `6384`.

Only the client port is exposed through these Services. The Valkey cluster bus ports are not exposed through MetalLB. Gossip and replication use pod IPs directly on the CNI network.

## Traffic path and HAProxy integration

This document owns the MetalLB side of the path: one shared backend IP assigned
to multiple per-pod `LoadBalancer` Services with non-overlapping ports. The full
Valkey RESP/TCP client path, including MOVED/ASK behavior, port-preserved node
identity, and cluster bus exceptions, is maintained in
[docs/valkey-tcp-ingress-routing.md](valkey-tcp-ingress-routing.md).

That Valkey path must support the application's real command families, not just
basic connectivity: cache/KV verbs, hashes, lists, sorted sets, streams,
classic pub/sub, sharded pub/sub, redirects, replica behavior, and failover
checks. The canonical semantic inventory is in
[docs/valkey-tcp-ingress-routing.md](valkey-tcp-ingress-routing.md#required-valkey-semantics).

At the MetalLB/HAProxy boundary, HAProxy maps each TCP port on the VIP to the
same port on the MetalLB IP that Kubernetes assigned to that Service.

`scripts/k3s/phases/lb.sh` discovers Valkey Service assignments using this JSONPath:

```sh
{range .items[?(@.spec.type=="LoadBalancer")]}{.spec.ports[0].port}{" "}{.status.loadBalancer.ingress[0].ip}{"\n"}{end}
```

That produces a port-to-IP map. With the shared-IP design, the IP is normally the same for all six ports:

```text
6379 192.168.105.200
6380 192.168.105.200
6381 192.168.105.200
6382 192.168.105.200
6383 192.168.105.200
6384 192.168.105.200
```

HAProxy then generates one TCP frontend/backend pair per port:

```text
frontend valkey_6380
    mode tcp
    bind *:6380
    default_backend valkey_6380_be
backend valkey_6380_be
    mode tcp
    server shard 192.168.105.200:6380 check
```

This means HAProxy is a TCP port router. It does not inspect Redis/Valkey protocol commands, slots, keys, MOVED redirects, streams, or pub/sub payloads.

## MetalLB is not an L7 proxy

MetalLB does not route a key to a shard. It only makes the Service IP reachable. Valkey and the client library still handle cluster routing.

MetalLB in this stack operates at L2/L3. It does not understand:

- Redis Serialization Protocol
- Valkey cluster slots
- GET/SET keys
- streams
- pub/sub channels
- MOVED or ASK semantics
- transactions
- blocking commands

MetalLB answers ARP for an IP. Kubernetes Service routing then forwards packets for a given service port to that Service's endpoints. The per-port Service shape is what preserves deterministic node reachability.

## Control plane behavior

the control plane can host Kubernetes control resources, but it should not announce the Valkey MetalLB IP. Existing traffic can survive a temporary control-plane outage only as long as the worker data plane remains intact.

The control-plane node is intentionally excluded from `L2Advertisement` eligibility. Therefore, the Valkey shared MetalLB IP should be announced from worker agents only.

If the control-plane node goes down while worker nodes remain up:

- existing node-level networking may continue
- HAProxy can continue forwarding to the MetalLB IP if the IP remains announced
- existing Service dataplane rules may continue to work
- Kubernetes reconciliation is impaired or unavailable
- pod rescheduling, endpoint updates, and Service status changes may not proceed correctly until the control plane returns

If additional control-plane nodes are added, they must carry the `node-role.kubernetes.io/control-plane` label if they should be excluded from MetalLB announcements. The current `L2Advertisement` excludes nodes by label, not by VM name.

## Worker failure behavior

if one worker dies, MetalLB can move the shared IP announcement to another eligible worker. Whether Valkey fully recovers depends on pod scheduling and storage.

If the worker currently announcing the shared MetalLB IP fails, MetalLB speaker on another eligible worker should take over announcement. Clients and HAProxy keep using the same IP and ports.

However, MetalLB IP failover is not the same as Valkey pod recovery. The Valkey chart uses StatefulSets with PVCs. In the local k3s setup, the default storage is often local-path storage, which is node-local. If a Valkey pod's PVC is tied to a failed worker, that pod may not be able to reschedule onto another worker with its existing data. See [docs/stateful-storage-poc.md](stateful-storage-poc.md) for the POC-only storage model and production caveats.

Therefore:

```text
MetalLB IP failover across workers: expected
Valkey pod failover with local-path storage: limited POC behavior
Valkey pod failover with reattachable network storage: production-friendly shape
```

For the POC, the current behavior is acceptable. For production, the Valkey storage class and pod placement rules must be revisited.

## DNS assumptions

clients do not dial the MetalLB IP by name. They dial `valkey.debug-demo.local`, which resolves to the VIP on the LB VM.

The important names are defined in `scripts/lib/k3s-env.sh`:

```sh
BASE_DOMAIN=debug-demo.local
APP_HOST=debug-demo.local
VALKEY_HOST=valkey.debug-demo.local
```

The Valkey chart sets `cluster-announce-hostname` to `VALKEY_HOST`. Valkey cluster clients see endpoint names like:

```text
valkey.debug-demo.local:6380
```

They do not see `192.168.105.200:6380` unless they inspect Kubernetes Service state or HAProxy configuration.

The hostname resolves to the keepalived VIP, not to the MetalLB IP. The VIP is owned by the LB VM. HAProxy then forwards to the MetalLB IP.

## Limitations

this is a good POC model, but it is still a local bare-metal-style design. It depends on L2 networking, static IP ownership, and non-cloud behavior.

Known limitations:

- L2 mode requires ARP reachability on the subnet where the MetalLB IP lives.
- The MetalLB pool must not overlap with DHCP or any other host allocation.
- MetalLB L2 mode has one active announcing node per IP at a time.
- MetalLB does not provide an L7 Valkey-aware proxy.
- A single shared MetalLB IP works only because each Service exposes a different port.
- A single ordinary Kubernetes Service cannot replace the per-pod Services because Kubernetes Services have one selector for all ports.
- The control plane is excluded from announcement, so at least one eligible worker must remain available.
- Local-path storage can limit StatefulSet pod recovery after worker failure.
- HAProxy reads Service status when `scripts/k3s/phases/lb.sh up` runs; if Service IPs or ports change later, HAProxy must be regenerated or restarted by rerunning the LB script.
- The design assumes k3s `servicelb` is disabled. If k3s klipper/servicelb is enabled, it may compete with MetalLB for `LoadBalancer` Services.

## Production MetalLB assumptions

This document keeps only the MetalLB-specific production assumptions. The broader
lab-to-production checklist is maintained in
[docs/production-translation-guide.md](production-translation-guide.md), and the
Valkey port-preserving path is maintained in
[docs/valkey-tcp-ingress-routing.md](valkey-tcp-ingress-routing.md).

For MetalLB itself, validate:

- the shared backend IP is allocated in IPAM and excluded from DHCP
- the load balancer can reach the MetalLB backend IP on ports `6379-6384`
- worker nodes are on the L2 segment where MetalLB will announce the backend IP, or BGP mode is used instead of L2 mode
- control-plane nodes are labeled so the `L2Advertisement` excludes them
- k3s `servicelb` or any other service load-balancer controller will not compete with MetalLB for the same `LoadBalancer` Services

## Operational checks

these commands tell you whether MetalLB is installed, whether the pool exists, whether Services got the shared IP, and whether HAProxy will have something to route to.

Check MetalLB pods:

```sh
kubectl --kubeconfig dumps/k3s.kubeconfig -n metallb-system get pods -o wide
```

Check the pool and advertisement:

```sh
kubectl --kubeconfig dumps/k3s.kubeconfig -n metallb-system get ipaddresspool,l2advertisement
kubectl --kubeconfig dumps/k3s.kubeconfig -n metallb-system get l2advertisement agents-only -o yaml
```

Check Valkey Services and shared IP assignment:

```sh
kubectl --kubeconfig dumps/k3s.kubeconfig -n valkey get svc -o wide
```

Expected shape with defaults:

```text
valkey-primary-0-ext    LoadBalancer   ...   192.168.105.200   6379/TCP
valkey-primary-1-ext    LoadBalancer   ...   192.168.105.200   6380/TCP
valkey-primary-2-ext    LoadBalancer   ...   192.168.105.200   6381/TCP
valkey-secondary-0-ext  LoadBalancer   ...   192.168.105.200   6382/TCP
valkey-secondary-1-ext  LoadBalancer   ...   192.168.105.200   6383/TCP
valkey-secondary-2-ext  LoadBalancer   ...   192.168.105.200   6384/TCP
```

Check the platform phase status:

```sh
scripts/k3s/phases/platform.sh status
```

Regenerate the LB VM HAProxy configuration after Service IP changes:

```sh
scripts/k3s/phases/lb.sh up
```

Run broad validation:

```sh
scripts/k3s.sh doctor
scripts/k3s.sh smoke
scripts/k3s/verify/valkey-cluster-tests.sh --skip-failover
```

## Troubleshooting map

if traffic fails, identify which layer is broken: DNS, VIP, HAProxy, MetalLB IP assignment, MetalLB announcement, Service endpoints, or Valkey cluster state.

| Symptom | Likely layer | First checks |
|---|---|---|
| `valkey.debug-demo.local` does not resolve | DNS | `scripts/k3s/phases/net.sh status`, CoreDNS custom ConfigMap, Mac resolver |
| VIP does not answer | LB VM / keepalived | `scripts/k3s/phases/lb.sh status`, `ping $K3S_VIP` |
| HAProxy has no Valkey backend | Service status | `kubectl -n valkey get svc`, rerun `scripts/k3s/phases/lb.sh up` |
| Valkey Services have no `EXTERNAL-IP` | MetalLB controller/pool | `kubectl -n metallb-system get pods`, `kubectl -n metallb-system describe ipaddresspool valkey-pool` |
| Shared IP is assigned but not reachable | MetalLB speaker/L2 | `kubectl -n metallb-system get pods -o wide`, check worker node health and L2Advertisement |
| A specific port fails | Per-pod Service or pod readiness | `kubectl -n valkey get svc valkey-primary-1-ext -o yaml`, `kubectl -n valkey get endpoints` |
| MOVED redirects loop or fail | Valkey cluster topology | `scripts/k3s/verify/valkey-cluster-tests.sh --skip-failover`, `valkey-cli cluster nodes` |
| Failure after worker loss | Storage/pod scheduling | `kubectl -n valkey get pods -o wide`, PVC/PV status, node status |

## Design summary

MetalLB is the backend IP provider, not the public front door. The public front door is the LB VM VIP. Valkey node identity is preserved by port, not by one IP per node.

The final routing model is:

```text
external client
  -> valkey.debug-demo.local:<node-port>
  -> keepalived VIP on ddk3s-lb
  -> HAProxy TCP frontend for that port
  -> shared MetalLB IP on that same port
  -> per-pod Kubernetes LoadBalancer Service
  -> exactly one Valkey pod
```

The design keeps these invariants:

- one client-facing hostname
- one client-facing VIP
- one shared MetalLB backend IP for Valkey
- one Kubernetes Service per Valkey pod
- one unique client port per Valkey pod
- no Valkey cluster bus traffic through VIP, HAProxy, or MetalLB
- no control-plane node announcement for Valkey LoadBalancer IPs
