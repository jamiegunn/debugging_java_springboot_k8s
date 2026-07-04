# Multi-node k3s architecture (replaces Rancher Desktop end-to-end)

This is the blueprint for the surgery that replaces the single-node Rancher
Desktop stack (RD's embedded k3s + MetalLB + the HAProxy-VM F5 stand-in + the
dev VIP shim + Mac static routes) with a **purpose-built 3-node k3s cluster on
Lima VMs**, a **dedicated load-balancer VM** (`ddk3s-lb`) that owns the
**keepalived VRRP VIP** and fronts the cluster with HAProxy, **dnsmasq
hostnames**, and a **fully air-gapped image supply** suitable for a corporate
network where pods and VMs cannot reach the internet.

The VIP lives on the LB tier, **not on a cluster node** — a separate F5/
NetScaler-shaped appliance in front of a backend pool of k3s nodes. That's the
key change from earlier revisions, which floated the VIP between the k3s nodes
themselves; a thrashing/starved node could take the VIP down with it.

Config for all of it lives in `scripts/lib/k3s-env.sh` (override via env).

## Why this fixes what RD couldn't

RD ran everything in one vz-NAT VM. Two hard walls fell out of that:
- **The vz-NAT wall** — pods could not dial the external VIP (the HAProxy VM),
  so Valkey gossip via announced addresses was impossible; we papered over it
  with the `devVipShim` DaemonSet.
- **IP-only, route-hacked access** — MetalLB IPs needed `sudo route` entries on
  the Mac, and everything was addressed by IP.

On Lima's **`shared` network** (socket_vmnet, `192.168.105.0/24`) every VM and
the Mac sit on one L2 segment. A keepalived VIP on that segment is **directly
reachable from the Mac and from every pod** (pod → node → same-subnet VIP), no
NAT, no routes, no shim. That is exactly the corporate-LAN property, so the
shim is deleted and gossip hairpins through the real VIP like production.

## Topology (4 VMs)

```
                 keepalived VIP 192.168.105.100  (on the LB VM)
                              │
                     ddk3s-lb  (1 cpu/1 GiB)   ← keepalived + HAProxy
                     :80 → agents' ingress
                     :6379-6384 → agents' klipper (Valkey)
                              │
        ┌─────────────────────┼─────────────────────┐
   ddk3s-server            ddk3s-agent-1         ddk3s-agent-2
   control-plane            worker (7 GiB)        worker (7 GiB)
   TAINTED NoSchedule       ingress, klipper,     ingress, klipper,
   (no workloads)           app, Oracle, MQ,      app, Oracle, MQ,
   3 GiB / 2 cpu            Valkey                Valkey
```

All 4 VMs + the Mac sit on Lima's `shared` L2 segment (socket_vmnet,
`192.168.105.0/24`) — directly reachable from the Mac and between VMs, no NAT,
no routes. ingress-nginx runs as a DaemonSet (hostPort 80/443) and klipper
servicelb binds the Valkey ports on **the two worker agents** (the server is
tainted, so neither lands there); HAProxy on the LB VM health-checks and pools
to those agents. Valkey Services target their pods; the port (6379-6384, +bus
16379-16384) selects the shard, kube-proxy DNATs to the owning pod.

- **keepalived** runs on `ddk3s-lb` only — one VRRP instance
  (`virtual_router_id 51`), state MASTER, priority 150, holding the VIP. It is
  started **self-daemonized** (`keepalived --use-file=…`), not via the openrc
  `--dont-fork` service (which dies in the transient install shell). There is no
  health-track script (the old one was fragile); the VIP is held by VRRP
  priority alone, and it is independent of any cluster node's health.
- **HAProxy** on `ddk3s-lb` is the backend-pool half of the "external VIP →
  cluster nodes" model: `:80` HTTP round-robins (with `GET /healthz` checks) to
  each agent's ingress, so it routes around a starved/down node; one TCP
  frontend per Valkey client port passes 6379-6384 through to the agents'
  klipper LBs (per-shard by port; MOVED-by-hostname preserved).
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
where kube-proxy DNATs to the owning pod. Per-shard addressability comes from
the **port** (6379-6384), exactly as the current `sharedIP-perPort` model —
only the shared *address* is now a hostname→VIP instead of a MetalLB IP.

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
  binary, `--disable traefik` (we use ingress-nginx), and the server node with
  `--node-taint node-role.kubernetes.io/control-plane=true:NoSchedule` so all
  workloads land on the agents. klipper servicelb is KEPT: it forwards each
  LoadBalancer Service's port to the pod on every (untainted) node, and HAProxy
  on the LB tier pools those node ports behind the one stable VIP
  (complementary, not either/or),
- imports every app/backend image tar into containerd via
  `k3s ctr images import`.

Charts run with `imagePullPolicy: Never` (or `IfNotPresent` against the
pre-imported images). A pod that tries to pull would fail — which is the point:
it proves nothing reaches out. The old `preload-images.sh` (which pulled into
RD's shared moby) is replaced by this bundle→import flow.

## What gets retired vs. kept

| Retired (RD-specific) | Replaced by |
|---|---|
| `install-stack.sh` (RD 10-phase) | `k3s-install.sh` (preflight + VM + k3s + DNS + charts + LB tier) |
| `install-haproxy-vm.sh`, `lima-haproxy.yaml` | the `ddk3s-lb` VM (keepalived VIP + HAProxy), `scripts/k3s-lb.sh` |
| `host-routes.sh` (Mac static routes) | direct L2 reachability on the shared subnet |
| MetalLB (chart annotations, pool) | keepalived VRRP VIP on the LB tier + klipper svclb |
| `charts/valkey` `devVipShim` | deleted — pods reach the VIP directly |
| MetalLB `allow-shared-ip` / `sharedIP` / `announceIP` | `announceHostname` → VIP |
| Pattern D hostNetwork single-pod ingress | ingress-nginx DaemonSet behind the VIP |

Kept, adapted: the app, all four backend charts (Oracle/MQ/Valkey/Artifactory),
the whole test + troubleshooting suite (re-pointed at hostnames), the JRE-only
diagnostic constraint.

## Phased implementation

- [x] **P0 — foundation**: `scripts/lib/k3s-env.sh`, this doc,
  `scripts/bundle-images.sh` (air-gap bundle), `scripts/k3s-cluster.sh` (VMs +
  k3s + image import).
- [x] **P1 — DNS**: dnsmasq on server, Mac `/etc/resolver`, CoreDNS stub zone —
  all answering `*.debug-demo.local → VIP`. `scripts/k3s-net.sh` is **DNS-only**
  now; the VIP itself is served by the LB tier (see the LB-tier phase below).
- [x] **P2 — platform**: ingress-nginx DaemonSet chart values (VIP-fronted),
  namespaces, storage (local-path). Verify hostname resolution reaches the VIP.
- [x] **P3 — charts** — DONE and VALIDATED END TO END. Each Valkey pod
  listens on its own unique port (base+idx) and announces its POD IP + that
  port, so gossip/replication are DIRECT pod-to-pod on the CNI network (VIP and
  klipper are out of the bus path — the earlier VIP-announce hung replica
  joins). Clients get valkey.debug-demo.local:<port> (hostname endpoints),
  which resolves to the VIP → klipper → the owning pod (Service targetPort = the
  pod's unique port). The app pins the Valkey hostname → VIP via hostAliases,
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
  scripts/k3s-chaos.sh (node-down / vip-failover / valkey-freeze / backend
  scale-downs; node-down validated live — valkey stayed cluster_state:ok
  through the outage); valkey-cluster-tests.sh ported and ALL 58 checks pass
  (MOVED, ASK, migration, replicas, pub/sub, full crash-failover — client
  ops by hostname in-cluster, MIGRATE by pod-IP since the pod→VIP→klipper
  hairpin times out); api-tour.sh + valkey-tour.sh re-pointed at the VIP /
  in-cluster hostname. common.sh auto-targets the k3s kubeconfig for the
  whole suite.
- [x] **P6 — troubleshooting kit**: scripts/k3s-doctor.sh — one command
  checks every layer (tooling → VMs → nodes → VIP → DNS → ingress →
  workloads → Valkey cluster → end-to-end), and for anything broken prints
  the exact fix command (validated: 23/24, the 1 being the optional Mac
  resolver). `./tui` (root launcher) / `scripts/k3s.sh` is the single front
  door: bare `./tui` opens an interactive menu (option 0 = preflight, 12 = lb);
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
  ingress + klipper don't run on the server, which is why HAProxy pools to the
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
