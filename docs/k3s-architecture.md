# Multi-node k3s architecture

The design reference for the stack: a **purpose-built 3-node k3s cluster on
Lima VMs**, fronted by a **dedicated load-balancer VM** (`ddk3s-lb`) that owns
the **keepalived VRRP VIP** and HAProxy-pools to the cluster, with **dnsmasq
hostnames** and a **fully air-gapped image supply** suitable for a corporate
network where pods and VMs cannot reach the internet.

The VIP lives on the LB tier, **not on a cluster node** — a separate F5/
NetScaler-shaped appliance in front of a backend pool of k3s nodes, so a
thrashing or starved node can never take the VIP down with it.

This is Kubernetes-admin-level implementation detail, included to explain how
the lab routes traffic and why the scripts can test everything by hostname. The
primary intent of the repository is to prove the debugging, validation, and
operational tooling workflow. This local k3s design is the testbed that makes
that workflow realistic; it is not presented as a production Kubernetes
blueprint.

Config for all of it lives in `scripts/lib/k3s-env.sh` (override via env).

For focused companion references, see [docs/valkey-tcp-ingress-routing.md](valkey-tcp-ingress-routing.md)
for the RESP/TCP path, [docs/production-translation-guide.md](production-translation-guide.md)
for lab-to-production mapping, and [docs/stateful-storage-poc.md](stateful-storage-poc.md)
for POC-only storage caveats.

## Why the shared L2 network matters in the lab

The lab intentionally uses one property to keep the local install simple: **the
Mac and all VMs sit on a single L2 segment** — Lima's **`shared` network**
(socket_vmnet, `192.168.105.0/24`). A keepalived VIP on that segment is directly
reachable from the Mac, the LB VM can reach the worker nodes, and HAProxy can
reach the MetalLB backend IP without extra routes.

Without that shared segment, the lab would need an explicit replacement for L2
reachability. ARP for the keepalived VIP and MetalLB IPs does not cross NAT or a
normal routed boundary. In concrete terms, "the Mac is behind NAT" would mean
the k3s VMs live on a NAT-only VM subnet and the Mac is not directly attached to
`192.168.105.0/24`. The Mac might be able to reach a translated localhost port
or a NAT gateway address, but it could not directly ask "who has
`192.168.105.100`?" or "who has `192.168.105.200`?" on the VM subnet. If the
Mac were outside the Lima subnet, it would need a route to `192.168.105.0/24`, a
port-forward/NAT rule into the VM network, or a proxy/load-balancer endpoint
that is reachable from the Mac and can also reach the cluster backends.
Likewise, if the LB VM were not on the backend worker network, HAProxy would
need either a second interface on that network or a routed path to the worker
and MetalLB backend IPs. The shared L2 network removes those extra moving parts
for the POC.

That flat network is a lab convenience, not a production requirement. The
production pattern is the same two-sided load-balancer shape with explicit
networking between the sides:

```text
client/application network
  -> frontend VIP on F5 / load-balancer tier
  -> routed or directly attached backend path
  -> Kubernetes worker/server network
  -> ingress worker IPs or MetalLB backend IPs
```

The important invariant is not that every address shares one subnet. The
important invariant is that clients reach a stable frontend VIP, and the LB tier
can reach the Kubernetes backend targets. In the lab, that reachability comes
from one flat L2 network. In production, it usually comes from dual-homed load
balancer interfaces, firewall/routing policy, BGP-advertised backend networks,
or a platform-native load balancer integration.

See [docs/lb-tier-keepalived-haproxy.md](lb-tier-keepalived-haproxy.md) for the
lab-to-F5 mapping and [docs/metallb-configuration.md](metallb-configuration.md)
for the MetalLB backend IP assumptions.

## Topology (4 VMs)

```
                 keepalived VIP 192.168.105.100  (on the LB VM)
                              │
                     ddk3s-lb  (1 cpu/1 GiB)   ← keepalived + HAProxy
                     :80 → agents' ingress
                     :6379-6384 → shared MetalLB IP (Valkey, port-selected)
                              │
        ┌─────────────────────┼─────────────────────┐
   ddk3s-server            ddk3s-agent-1         ddk3s-agent-2
   control-plane            worker (7 GiB)        worker (7 GiB)
   TAINTED NoSchedule       ingress, MetalLB,     ingress, MetalLB,
   (no workloads)           app, Oracle, MQ,      app, Oracle, MQ,
   3 GiB / 2 cpu            Valkey                Valkey
```

All 4 VMs + the Mac sit on Lima's `shared` L2 segment (socket_vmnet,
`192.168.105.0/24`) — directly reachable from the Mac and between VMs, no NAT,
no routes. ingress-nginx runs as a DaemonSet (hostPort 80/443) and MetalLB
(L2/ARP mode; k3s servicelb/klipper is disabled) assigns the Valkey Services a
shared pool IP and ARP-announces it from **the two worker agents** (its
`L2Advertisement` excludes the tainted server, so neither lands there); HAProxy
on the LB VM health-checks and pools to those agents. The Valkey Services share
one MetalLB IP but keep distinct ports (6379-6384, +bus 16379-16384), so the
port still selects the shard from the client's view and kube-proxy DNATs to the
owning pod.

- **keepalived** runs on `ddk3s-lb` only — one VRRP instance
  (`virtual_router_id 51`), state MASTER, priority 150, holding the VIP. It is
  started **self-daemonized** (`keepalived --use-file=…`), not via the openrc
  `--dont-fork` service (which dies in the transient install shell). There is no
  health-track script (the old one was fragile); the VIP is held by VRRP
  priority alone, and it is independent of any cluster node's health.
- **HAProxy** on `ddk3s-lb` is the backend-pool half of the "external VIP →
  cluster nodes" model: `:80` HTTP round-robins (with `GET /healthz` checks) to
  each agent's ingress, so it routes around a starved/down node; one TCP
  frontend per Valkey client port maps 6379-6384 to the shared MetalLB IP on
  that same port (per-shard by port; MOVED-by-hostname preserved).
  See [docs/lb-tier-keepalived-haproxy.md](lb-tier-keepalived-haproxy.md) for the LB-tier design and
  production F5 mapping, and [docs/metallb-configuration.md](metallb-configuration.md) for the
  Kubernetes-level MetalLB resources, assumptions, limits, and routing details.
- **dnsmasq** runs as a host service on the server node. It answers
  `debug-demo.local`, `valkey.debug-demo.local`, `*.debug-demo.local` → the
  VIP. The Mac points at it via `/etc/resolver/debug-demo.local`; the cluster
  points at it via a CoreDNS stub zone (so pods resolve the same names).

## Everything is a hostname

The user requirement: **tests use hostnames, never IPs.** Mechanisms:

| Consumer | How it resolves names | To |
|---|---|---|
| Mac (curl, valkey-cli) | `/etc/resolver/debug-demo.local` → dnsmasq on server VM | VIP |
| Pods (Valkey gossip, app) | CoreDNS stub `debug-demo.local → dnsmasq` | VIP |
| Valkey `MOVED`/`CLUSTER SHARDS` | Valkey announces a **hostname**, not an IP | `valkey.debug-demo.local:<port>` |

Valkey 8 supports hostname endpoints: set `cluster-announce-hostname
valkey.debug-demo.local` and `cluster-preferred-endpoint-type hostname`. Then
`CLUSTER SHARDS`/`CLUSTER NODES`/`MOVED` return `valkey.debug-demo.local:6380`,
which every client (Mac or pod) resolves to the VIP and dials on that port,
where HAProxy forwards to the shared MetalLB IP on that same port and kube-proxy
DNATs to the owning pod. Per-shard addressability comes from the **port**
(6379-6384); the client-facing *address* is a single hostname→VIP, while the
MetalLB backend address is also shared across the per-pod Services.

## Air-gap: no image ever pulled inside a VM or pod

`scripts/bundle-images.sh` runs on the **Mac** (which has internet or a
corporate mirror) and produces a self-contained bundle in `dumps/airgap/`:

1. `docker pull` every third-party image in `K3S_IMAGES` (pinned refs) and
   `docker save` each to a `.tar`.
2. Build the app image (`docker build app/`) and `docker save` it.
3. Download the k3s **binary** and the **k3s-airgap-images-<arch>.tar.zst**
   (pause, coredns, metrics-server, local-path-provisioner) for the pinned
   `K3S_VERSION`.

`scripts/k3s-cluster.sh` then, per node, `limactl copy`s the bundle in and:
- places the k3s airgap images tar at `/var/lib/rancher/k3s/agent/images/`
  (k3s imports it automatically at startup — no pull),
- installs k3s with `INSTALL_K3S_SKIP_DOWNLOAD=true` pointing at the copied
  binary, `--disable traefik,servicelb` (we use ingress-nginx for HTTP and
  MetalLB for LoadBalancer Services), and the server node with
  `--node-taint node-role.kubernetes.io/control-plane=true:NoSchedule` so all
  workloads land on the agents. MetalLB (L2 mode) fulfills the Valkey
  LoadBalancer Services by assigning them a shared pool IP and ARP-announcing it
  from the agents only; HAProxy on the LB tier maps VIP:port → shared MetalLB IP:port, behind the one
  stable VIP (complementary, not either/or),
- imports every app/backend image tar into containerd via
  `k3s ctr images import`.

Charts run with `imagePullPolicy: Never` (or `IfNotPresent` against the
pre-imported images). A pod that tries to pull would fail — which is the point:
it proves nothing reaches out. The image list lives in `K3S_IMAGES`
(`scripts/lib/k3s-env.sh`); `scripts/bundle-images.sh` builds the bundle and
`scripts/k3s-cluster.sh` imports it.

## Phased implementation

- [x] **P0 — foundation**: `scripts/lib/k3s-env.sh`, this doc,
  `scripts/bundle-images.sh` (air-gap bundle), `scripts/k3s-cluster.sh` (VMs +
  k3s + image import).
- [x] **P1 — DNS**: dnsmasq on server, Mac `/etc/resolver`, CoreDNS stub zone —
  all answering `*.debug-demo.local → VIP`. `scripts/k3s-net.sh` is **DNS-only**
  now; the VIP itself is served by the LB tier (see the LB-tier phase below).
- [x] **P2 — platform**: ingress-nginx DaemonSet chart values (VIP-fronted),
  namespaces, storage (local-path). Verify hostname resolution reaches the VIP.
  See [docs/stateful-storage-poc.md](stateful-storage-poc.md) for why the default
  StatefulSet/PVC storage is POC-only and not production-grade HA storage.
- [x] **P3 — charts** — DONE and VALIDATED END TO END. Each Valkey pod
  listens on its own unique port (base+idx) and announces its POD IP + that
  port, so gossip/replication are DIRECT pod-to-pod on the CNI network (VIP and
  MetalLB are out of the bus path — the earlier VIP-announce hung replica
  joins). Clients get valkey.debug-demo.local:<port> (hostname endpoints),
  which resolves to the VIP → HAProxy → MetalLB IP → the owning pod (Service
  targetPort = the pod's unique port). The app pins the Valkey hostname → VIP via hostAliases,
  because Lettuce/netty's resolver mishandles Kubernetes ndots:5 search-domain
  expansion (getent resolves it, netty doesn't). Live proof on the 3-node k3s
  cluster: 6-node Valkey cluster forms (cluster_state:ok, 3 masters + 3 paired
  replicas), CLUSTER SHARDS/MOVED return valkey.debug-demo.local, a valkey-cli
  from the Mac follows MOVED by hostname and SET/GET round-trips, the app is UP
  through debug-demo.local, and POST /api/orders (Oracle + MQ + Valkey fan-out)
  returns 201 — all air-gapped, all by hostname.
- [x] **P4 — installer**: `scripts/k3s-install.sh` orchestrates the full phase
  chain and a final smoke; `scripts/k3s-uninstall.sh` (delete all VMs —
  **including `ddk3s-lb`** — resolver, kubeconfig; retries and verifies each VM
  is actually gone). Current phase order:
  **0 preflight** (`k3s-preflight.sh` — Mac prerequisite check + auto-setup;
  see below) → **air-gap bundle** → **cluster** (`k3s-cluster.sh`, installs the
  server **tainted** `node-role.kubernetes.io/control-plane=true:NoSchedule`) →
  **DNS** (`k3s-net.sh`) → **platform** (ingress) → **charts** → **LB tier**
  (`k3s-lb.sh up` — creates `ddk3s-lb`, brings up keepalived + HAProxy pooled to
  the agents) → **verify + smoke**.
- [x] **P5 — tests**: DONE. scripts/k3s-smoke.sh (14/14, all by hostname);
  scripts/k3s-chaos.sh (node-down / lb-down / valkey-freeze / backend
  scale-downs; node-down validated live — valkey stayed cluster_state:ok
  through the outage); valkey-cluster-tests.sh ported and ALL 58 checks pass
  (MOVED, ASK, migration, replicas, pub/sub, full crash-failover — client
  ops by hostname in-cluster, MIGRATE by pod-IP since the pod→VIP→HAProxy
  hairpin times out); api-tour.sh + valkey-tour.sh re-pointed at the VIP /
  in-cluster hostname. common.sh auto-targets the k3s kubeconfig for the
  whole suite.
- [x] **P6 — troubleshooting kit**: scripts/k3s-doctor.sh — one command
  checks every layer (tooling → VMs → nodes → VIP → DNS → MetalLB + ingress →
  workloads → Valkey cluster → end-to-end), and for anything broken prints the
  exact fix command. It counts passes dynamically; the only expected ✘ on a
  healthy stack is the optional Mac resolver (cleared by `./tui resolver`). `./tui` (root launcher) / `scripts/k3s.sh` is the single front
  door: bare `./tui` opens an interactive menu (option 1 = preflight, 9 = lb);
  subcommands are **preflight** / bundle / install / resolver / **lb** / doctor
  / smoke / status / chaos / tour / valkey / uninstall. `k3s-doctor.sh`
  section 4 now checks the **LB VM's** VIP + HAProxy (not the k3s nodes);
  section 2 lists `ddk3s-lb`.

## The troubleshooting kit (built)

The kit: **`./tui`** (or `scripts/k3s.sh`) as the one front door → `doctor`
(one command that checks every layer: VMs up, the LB VM holding the VIP +
HAProxy serving, dnsmasq answering, CoreDNS stub, node Ready, pods Ready,
ingress serving, Valkey cluster_state, each hostname resolving+dialing) →
`smoke` / `chaos` / the tours → the existing dump/jattach/memory tooling, all
addressed by hostname.

## Robustness hardening (post-P6)

- **VIP moved off the cluster nodes onto the LB tier.** keepalived used to run
  on all three k3s nodes with the VIP floating to whichever was MASTER. A node
  under load (the app JVM starving the small server, GC thrash, etc.) could drag
  the VIP down with it — the exact outage that drove this change. The VIP now
  lives on the dedicated `ddk3s-lb` VM, decoupled from cluster-node health;
  HAProxy there health-checks the node pool and routes around a bad node without
  the VIP ever moving. keepalived is self-daemonized (survives the transient
  install shell) with no health-track script.
- **Control-plane taint + app scheduling for two agents.** The server is
  tainted `node-role.kubernetes.io/control-plane=true:NoSchedule`, so **all**
  workloads land on the two worker agents (CoreDNS reschedules onto an agent;
  ingress runs on the agents and MetalLB's `L2Advertisement` excludes the
  server, so it never ARP-announces there — which is why HAProxy pools to the
  agents only). To fit that footprint, `charts/debug-demo-app` adds soft
  **pod-anti-affinity** (`spreadAcrossNodes`, default on) so replicas spread
  across the two agents (plus `affinity`/`tolerations` value hooks); the **HPA
  is capped at `maxReplicas: 4`** via `k3s-charts.sh --set` (chart default stays
  10 for larger clusters); and a **`startupProbe`** (default 40 × 5s ≈ 200s)
  gates liveness/readiness so a slow JVM boot under CPU contention isn't
  liveness-killed into a CrashLoop.
- **Memory sizing is against the container limit, not the node.** The app sets
  `resources.limits.memory: 1Gi`; with `-XX:+UseContainerSupport`,
  `-XX:MaxRAMPercentage=75` sizes the heap to ~0.73 GiB **of that 1 GiB limit**
  (MaxRAMPercentage reads the cgroup limit, not the 7 GiB node — it would only
  see the node if no limit were set).
- **VIP pre-flight + override.** `k3s-lb.sh` refuses to claim the keepalived VIP
  if a foreign device (or one of our own VMs' DHCP address) already holds it —
  the shared-network DHCP range isn't reserved — and prints the exact fix. The
  VIP is overridable (`K3S_VIP=… ./tui install`) and persists to `dumps/k3s-vip`
  so every later command agrees on it. `k3s-preflight.sh` (install step 0)
  additionally auto-sets-up the Mac side — Homebrew, CLI tools, **socket_vmnet**
  (the Lima shared-network backend), and the **Lima sudoers** file
  (`limactl sudoers --check` → `limactl sudoers | sudo tee /etc/sudoers.d/lima`),
  which used to be an undocumented manual step.
- **Verified teardown.** `k3s-uninstall.sh` retries and verifies each VM
  (including `ddk3s-lb`) is actually gone (the old silent-`2>/dev/null`-delete
  could leave VMs — and the VIP — running under an "uninstall complete").
