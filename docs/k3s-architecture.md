# Multi-node k3s architecture (replaces Rancher Desktop end-to-end)

This is the blueprint for the surgery that replaces the single-node Rancher
Desktop stack (RD's embedded k3s + MetalLB + the HAProxy-VM F5 stand-in + the
dev VIP shim + Mac static routes) with a **purpose-built 3-node k3s cluster on
Lima VMs**, a **keepalived VRRP VIP**, **dnsmasq hostnames**, and a **fully
air-gapped image supply** suitable for a corporate network where pods and VMs
cannot reach the internet.

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

## Topology (3 VMs)

```
                          Mac (192.168.105.1 on bridge101)
                                     │  resolves *.debug-demo.local via dnsmasq
                                     │  reaches the VIP directly (same L2)
        ┌────────────────────────────┼────────────────────────────┐
        │                keepalived VRRP VIP 192.168.105.100        │
        │                 (floats to whichever node is MASTER)      │
   ┌────┴─────────┐      ┌───────────────────┐     ┌───────────────┐
   │ ddk3s-server │      │  ddk3s-agent-1    │     │ ddk3s-agent-2 │
   │ k3s server   │      │  k3s agent        │     │ k3s agent     │
   │ keepalived   │      │  keepalived       │     │ keepalived    │
   │  (MASTER)    │      │  (BACKUP)         │     │ (BACKUP)      │
   │ dnsmasq      │      │                   │     │               │
   │ 3 GB / 2 cpu │      │  7 GB / 3 cpu     │     │ 7 GB / 3 cpu  │
   └──────────────┘      └───────────────────┘     └───────────────┘
        ▲                        ▲                        ▲
   ingress-nginx DaemonSet (hostPort 80/443) on every node — the VIP always
   lands on a node that answers HTTP. Valkey Services target their pods; the
   VIP + kube-proxy DNAT reach them on ports 6379-6384 (+bus 16379-16384).
```

- **keepalived** runs as a host service (`apk add keepalived`) on all three
  nodes. One VRRP instance, `virtual_router_id 51`, priority server(150) >
  agents(100). A `track_script` pings the local ingress `:80/healthz` so the
  VIP only lives on a node whose ingress is actually serving.
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
  binary, `--disable traefik` (we use ingress-nginx). klipper servicelb is
  KEPT: it forwards each LoadBalancer Service's port to the pod on every node,
  while keepalived floats the VIP across nodes for one stable address
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
| `install-stack.sh` (RD 10-phase) | `k3s-install.sh` (VM + k3s + keepalived + dnsmasq + charts) |
| `install-haproxy-vm.sh`, `lima-haproxy.yaml` | keepalived VIP (no proxy VM) |
| `host-routes.sh` (Mac static routes) | direct L2 reachability on the shared subnet |
| MetalLB (chart annotations, pool) | keepalived VRRP VIP |
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
- [ ] **P1 — VIP + DNS**: keepalived config on all nodes, dnsmasq on server,
  Mac `/etc/resolver`, CoreDNS stub zone. `scripts/k3s-net.sh`.
- [ ] **P2 — platform**: ingress-nginx DaemonSet chart values (VIP-fronted),
  namespaces, storage (local-path). Verify VIP failover + hostname resolution.
- [ ] **P3 — charts**: strip MetalLB/shim from `charts/valkey`; hostname
  announce; Oracle/MQ/Artifactory unchanged but `imagePullPolicy: Never`;
  app ingress host = `debug-demo.local`.
- [ ] **P4 — installer**: `scripts/k3s-install.sh` orchestrates P0-P3 +
  smoke; `scripts/k3s-uninstall.sh` (delete VMs, resolver, kubeconfig).
- [ ] **P5 — tests**: convert smoke / cluster-tests / api-tour / chaos /
  valkey-tour to hostnames; add node-level chaos (kill an agent VM → VIP
  failover + pod reschedule); keep the `--commands` cookbook echoes.
- [ ] **P6 — troubleshooting kit**: the "make it dead easy" layer (see below).

## P6 preview — the troubleshooting kit

Once the cluster is hostname-native and multi-node, the kit becomes:
`stackctl.sh` as the one front door → `doctor` (one command that checks every
layer: VMs up, VIP owner, dnsmasq answering, CoreDNS stub, node Ready, pods
Ready, ingress serving, Valkey cluster_state, each hostname resolving+dialing)
→ guided capture bundles → the existing dump/jattach/memory tooling, all
addressed by hostname and aware of which node owns the VIP.
