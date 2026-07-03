# Valkey networking architecture — MetalLB, proxies, DNS, and routing

How the 6-node Valkey cluster is made reachable from four different places —
other pods, the app, the Mac, and "the outside" (the F5 stand-in) — and why
each layer exists. Read `docs/routing-end-to-end.md` afterwards for literal
packet walks through every path described here.

---

## 1. The problem Valkey Cluster creates

A Valkey/Redis cluster is not one endpoint. Data is split into **16384
slots**, each owned by exactly one primary. Every node knows the full
slot→node map and enforces it:

- A command for a key the node doesn't own is answered with
  `MOVED <slot> <ip>:<port>` — a *permanent* redirect to the owner.
- During a live slot migration, requests for keys already moved get
  `ASK <slot> <ip>:<port>` — a *temporary* redirect for one request.
- Nodes gossip over a second port (the **cluster bus**, client port +10000)
  to share topology, detect failures, and elect replacements.

The addresses in those redirects — and in `CLUSTER NODES` / `CLUSTER SHARDS`
output — are whatever each node **announces**. This is the single most
important fact in this document:

> **Every client, and every peer node, dials the announced addresses.
> Networking design for a Valkey cluster is the art of choosing announce
> values that everyone who needs to dial them can actually reach.**

Consequences:

1. Per-shard addressability is non-negotiable. Each of the 6 nodes needs its
   own dialable `ip:port`. A single ip:port that round-robins across nodes
   breaks `MULTI`/`EXEC`, `WAIT`, sharded `SSUBSCRIBE`/`SPUBLISH`, and makes
   redirects meaningless.
2. An address is a **pair**. Uniqueness can come from the IP *or* the port.
3. No L7 proxy can sit in the path. The protocol is stateful TCP; the only
   things allowed between client and node are L4 passthroughs.

## 2. The layers, bottom-up

```
[E]  Mac / external clients          dials the ANNOUNCED endpoints
      │
[D]  HAProxy Lima VM (F5 stand-in)   192.168.105.x:6379-6384 + bus 1637x-1638x
      │  TCP passthrough, 1:1 ports
[C]  MetalLB shared LoadBalancer IP  192.168.64.51:6379-6384 + bus
      │  (six Services, allow-shared-ip, port-separated)
[B]  kube-proxy (iptables DNAT)      Service port → the ONE selected pod
      │
[A]  Valkey pods                     all listen on plain 6379 / 16379
      valkey-primary-{0,1,2}, valkey-secondary-{0,1,2}
```

### [A] Pods and DNS — the in-cluster identity layer

Two StatefulSets (`valkey-primary`, `valkey-secondary`, 3 replicas each) with
**headless Services** (`valkey-primary-headless`, `valkey-secondary-headless`).
Headless means no virtual IP: cluster DNS resolves
`valkey-primary-0.valkey-primary-headless.valkey.svc.cluster.local` straight
to that pod's IP. That per-pod DNS identity is used exactly twice:

- The **bootstrap Job** (`job-cluster-create.yaml`) welds 6 fresh pods into a
  cluster: `--cluster create` against the three primary DNS names, then
  `add-node --cluster-slave` pairing `secondary-N` to `primary-N` by index.
- The **app's Lettuce client** uses the DNS names as *contact points* only.
  After the first `CLUSTER SHARDS`, Lettuce talks to the announced endpoints
  like every other cluster-aware client.

Pod IPs are ephemeral (10.42.x.x, change on every restart) and are **never
announced** — announcing them is the classic mistake that makes a cluster
work until the first pod restart, then strand every client with dead
redirect targets.

### [B] Per-pod Services — the "one dialable endpoint per node" layer

Six Services, one per pod, selected via the label the StatefulSet controller
stamps on each pod:

```yaml
selector:
  statefulset.kubernetes.io/pod-name: valkey-primary-1
```

kube-proxy programs iptables so traffic to a Service lands on the selected
pod — and because the selector matches exactly one pod, there is no
load-balancing ambiguity. Each Service exposes a **client** port and a
**bus** port, both mapping back to the pod's fixed internal ports
(6379/16379 via `targetPort`).

### [C] MetalLB — who fulfills `type: LoadBalancer`

`type: LoadBalancer` is a request; something must assign the external IP. On
cloud it's the cloud controller; on Rancher Desktop it's **MetalLB in L2
mode**: the speaker answers ARP for the assigned IP on the node's interface,
attracting the traffic to the node, where kube-proxy takes over.

Two shapes, selected by `charts/valkey values: loadBalancer.mode`:

| | `sharedIP-perPort` (default) | `perPodIP` (legacy) |
|---|---|---|
| IPs from the pool | **1** (192.168.64.51) | 6 (.51–.56) |
| Ports | client 6379-6384, bus 16379-16384 | 6379/16379 everywhere |
| MetalLB mechanics | `metallb.universe.tf/allow-shared-ip: "valkey"` on all six Services | one pinned `loadBalancerIP` each |
| `externalTrafficPolicy` | **must be `Cluster`** | `Local` |
| Models | enterprise "one VIP per app, pool members by port" | "one IP per backend" |

Why `Cluster` in shared mode: MetalLB only lets `Local`-policy Services share
an IP when their pod selectors are identical (with `Local`, only nodes
hosting a selected pod may attract the traffic; six different single-pod
selectors give MetalLB no node that is simultaneously correct for all six).
`Cluster` lets any node accept and forward. The cost is source-IP
preservation, which Valkey doesn't use.

### The announce values — tying [A] through [C] together

Every pod computes its announce triple at startup
(`statefulset-{primary,secondary}.yaml` entrypoint):

```
IDX          = ordinal + offset        # primaries 0-2, secondaries 3-5
announce-ip  = loadBalancer.announceIP (if set) else loadBalancer.sharedIP
announce-port     = basePorts.client + IDX     # 6379..6384
announce-bus-port = basePorts.bus    + IDX     # 16379..16384
```

and passes them as `--cluster-announce-{ip,port,bus-port}` flags. From that
moment, every `MOVED`, every `ASK`, every `CLUSTER SHARDS` row, and every
gossip packet names those values.

### [D] The external VIP — one layer or two

- **One-layer** (`announceIP` unset): clients dial the MetalLB IP directly.
  Simple; what `--skip-haproxy-vm` installs give you.
- **Two-layer** (`announceIP` = the VIP): an external LB **not integrated
  with the cluster** fronts the MetalLB IP. This is our production shape —
  an F5 without CIS — and the full dev install rehearses it with the HAProxy
  Lima VM as the F5. The VM carries 12 TCP passthrough listeners
  (6379-6384, 16379-16384), each forwarding **1:1** to the same port on the
  MetalLB IP.

Two-layer hard requirements (all four bit us or would have):

1. **Ports forward 1:1.** The announced port must be dialable *as announced*.
2. **Plain L4** (F5 fastL4 / HAProxy `mode tcp`). No TLS termination, no
   inspection.
3. **Bus ports on the VIP.** Peers gossip via announced addresses, so
   `VIP:1637x-1638x` must route to the right pod. Blocked bus ports =
   `cluster_state:fail`.
4. **SNAT is fine.** Same trade-off as `externalTrafficPolicy: Cluster`.

### The dev VIP shim — restoring one prod property RD takes away

Requirement 3 means **the k8s nodes themselves must be able to dial the
VIP** (gossip originates in the pods). In production that's free — nodes and
the F5 share the corporate LAN. On Rancher Desktop it is impossible:
Apple's vz NAT will not forward VM→VM traffic between the RD subnet
(192.168.64.0/24) and the Lima shared subnet (192.168.105.0/24), in either
framing we tried (usernet path: TCP silently dropped; vznat path: nothing
forwarded). Pods can *never* reach the HAProxy VM.

The chart's `devVipShim` (dev-only, enabled by the installer alongside
`announceIP`) restores the property without touching RD internals:

- a hostNetwork DaemonSet initContainer runs `ip addr add <VIP>/32 dev lo`
  on the node — the VIP becomes a **local** address for node-originated and
  pod-originated traffic;
- an HAProxy container binds `VIP:<all 12 ports>` and forwards to the
  in-cluster `valkey-*-ext` Services.

Split-horizon result: **inside the cluster** the VIP resolves on-node
through the shim; **outside** it's still the real HAProxy VM. Gossip
functionally hairpins through the shim where prod hairpins through the real
F5. Never enable it where the VIP is genuinely reachable.

### [E] The Mac — dev-only route plumbing

Two pieces, both automated by install Phase 9:

- `/etc/hosts`: `debug-demo.local → <HAProxy VM IP>` (HTTP convenience).
- One static route: `192.168.64.51 via 192.168.64.2`. RD's vz NAT only
  answers ARP for the VM's own IP, so MetalLB's gratuitous ARP for the
  shared IP never reaches macOS; the route pins the next hop manually. The
  HAProxy VM's backend leg (VM → MetalLB IP) rides the same route, through
  the Mac as router (`net.inet.ip.forwarding=1`).

## 3. Failure semantics on this topology

- **Primary freeze/crash** (chaos `valkey-failover`, cluster-tests §4): peers
  miss bus PONGs for `cluster-node-timeout` (5s), mark it `fail`, the
  by-index replica wins the election and starts announcing *its own* endpoint
  as the slot owner. Redirects immediately point at the survivor. The frozen
  node wakes, sees the epoch moved on, demotes itself.
  Note: `kubectl delete pod` does **not** trigger this — the StatefulSet
  resurrects the pod (cached image + PVC) faster than failure detection.
  The tooling uses `DEBUG SLEEP` (enabled for local connections) instead.
- **Slot migration** (cluster-tests §2): `SETSLOT MIGRATING/IMPORTING`
  produces real `ASK` redirects; cluster-aware clients send `ASKING` and
  retry at the target. All through the same announced endpoints.
- **Stale PVC state**: StatefulSet PVCs survive `helm uninstall`; a
  reinstall inherits `nodes.conf` full of dead peers. The bootstrap Job
  detects it and runs `CLUSTER RESET HARD` + `FLUSHALL` before re-creating.

## 4. What changes in production

| Layer | Dev (this repo) | Prod (F5, no CIS) |
|---|---|---|
| VIP | HAProxy Lima VM, DHCP IP | F5 VIP, allocated by netops |
| `loadBalancer.sharedIP` | 192.168.64.51 (MetalLB) | whatever the in-cluster LB controller assigns |
| `loadBalancer.announceIP` | HAProxy VM IP | the F5 VIP |
| `devVipShim` | **enabled** (vz NAT workaround) | **disabled** — nodes reach the VIP over the LAN |
| Mac route / /etc/hosts | needed | not needed — corporate routing |
| Gossip hairpin | through the shim | through the real F5 (budget for it) |

The Helm chart is identical in both; only values differ.

## 5. Would a multi-node k3s cluster (1 CP + 3 workers) fix the shim?

**Yes — if the nodes are Lima VMs attached to the same Lima `shared` network
as the HAProxy VM.** Then nodes and the F5 stand-in share an L2 segment
(exactly the corporate-LAN property), pods reach the VIP through normal node
routing, gossip hairpins through the *real* VM, and `devVipShim` is deleted.
It also unlocks failure modes a single node cannot express:

- MetalLB L2 leader election and IP failover between speakers
- `externalTrafficPolicy` actually mattering (which node attracts traffic)
- pod anti-affinity spreading primaries/replicas across nodes
- **node-level chaos**: kill a whole worker and watch both k8s rescheduling
  and Valkey failover interact

What it costs:

- **It must be VMs, not k3d/kind.** Containerized "nodes" live inside one
  VM's network namespace — same vz NAT wall, nothing fixed.
- **Resources.** 4 × (2 CPU / 4-6 GB) VMs plus Oracle/MQ/Artifactory ≈
  20-24 GB committed; the current single-VM stack fits in 16 GB.
- **Image distribution.** Today `docker build` lands directly in the one
  node's moby. Multi-node needs a registry path (the in-cluster Artifactory
  finally earns its keep, or `k3s ctr images import` per node — which the
  preload phase would orchestrate).
- **Storage.** local-path PVCs pin workloads to whichever node first
  scheduled them; Oracle's seeded PVC makes that node special. Fine for dev,
  worth knowing.
- **Installer rewrite.** Phases 1/3/9 (rdctl sizing, MetalLB pool subnet,
  Mac routes) all change; the HAProxy VM phase stays.

Verdict: a genuinely better prod rehearsal and the *correct* fix for the
shim — as a **second profile** (`k3s-multinode`) alongside the fast
single-VM RD flow, not a replacement. The RD flow remains the "clone to
working stack in 10 minutes" path; the k3s profile is the "rehearse the
enterprise topology honestly" path.
