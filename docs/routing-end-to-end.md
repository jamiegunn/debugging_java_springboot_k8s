# Routing, end to end — every packet walk in this stack

The literal hop-by-hop story for each traffic path. Companion to
`docs/valkey-networking-architecture.md` (which explains *why* each layer
exists); this document explains *what actually happens to the packets*.

Cast of addresses (a fresh install; the HAProxy IP is DHCP-assigned, cached
at `dumps/haproxy-vm-ip`):

| Who | Address | Network |
|---|---|---|
| Mac (host) | 192.168.64.1 on `bridge100`, 192.168.105.1 on `bridge101` | routes between them (`net.inet.ip.forwarding=1`) |
| Rancher Desktop VM (the k8s node) | 192.168.64.2 (`vznat`), 192.168.5.15 (`eth0`, Lima usernet) | vz NAT / user-mode net |
| Pods | 10.42.0.x (`cni0`) | flannel, inside the RD VM |
| MetalLB shared LB IP | 192.168.64.51 | virtual — exists only in ARP + iptables |
| HAProxy VM (F5 stand-in) | 192.168.105.16 | Lima `shared` (socket_vmnet) |
| App ClusterIP | 10.43.x.x | virtual — exists only in iptables |

Announced Valkey endpoints (what every redirect names): `192.168.105.16:6379-6384`.

---

## Path 1 — HTTP: Mac → `http://debug-demo.local/api/...`

```
Mac browser/curl
  │ 1. DNS: /etc/hosts says debug-demo.local = 192.168.105.16
  │ 2. TCP SYN → 192.168.105.16:80. The Mac has bridge101 (192.168.105.1/24)
  │    directly attached — no gateway needed, plain L2 delivery.
  ▼
HAProxy VM :80  (frontend http_front)
  │ 3. HAProxy terminates TCP, applies its HTTP config (adds X-Forwarded-For),
  │    picks backend ingress_nginx = 192.168.64.2:80.
  │ 4. VM's route table: 192.168.64.0/24 is NOT local → default gw
  │    192.168.105.1 (the Mac). Packet goes back to the Mac.
  │ 5. Mac forwards it (net.inet.ip.forwarding=1) out bridge100 → 192.168.64.2.
  ▼
RD VM :80 — the ingress-nginx-controller POD, not a Service
  │ 6. The pod runs hostNetwork:true and binds the node's :80 directly.
  │    No NodePort, no kube-proxy, no Service in this hop (Pattern D).
  │ 7. nginx matches Host: debug-demo.local → Ingress rule → upstream =
  │    the app Service's endpoints.
  ▼
kube-proxy DNAT: app ClusterIP:8080 → app pod 10.42.0.x:8080
  ▼
Spring Boot app pod
```

Return traffic retraces exactly (conntrack un-DNATs at each hop). Three
distinct proxies touch an HTTP request: HAProxy (L7), nginx (L7), kube-proxy
(L4 NAT). Only the first two appear in `X-Forwarded-For`.

## Path 2 — Valkey from the Mac (the two-layer client path)

`valkey-cli -c -h 192.168.105.16 -p 6380 ... set foo bar`

```
Mac
  │ 1. TCP → 192.168.105.16:6380. Direct L2 on bridge101, as in Path 1.
  ▼
HAProxy VM  (listen valkey_client_6380, mode tcp — pure passthrough)
  │ 2. Forwards to 192.168.64.51:6380. Route: via default gw 192.168.105.1.
  ▼
Mac as router
  │ 3. Mac's route table has a HOST ROUTE: 192.168.64.51 via 192.168.64.2
  │    (installed by scripts/host-routes.sh — vz NAT never passes MetalLB's
  │    gratuitous ARP to macOS, so without the route the Mac would ARP into
  │    the void). Forwards out bridge100 to the RD VM's MAC.
  ▼
RD VM — kube-proxy iptables
  │ 4. 192.168.64.51 is not a real interface anywhere. KUBE-SERVICES matches
  │    dst=192.168.64.51:6380 = Service valkey-primary-1-ext → DNAT to pod
  │    valkey-primary-1 10.42.0.x:6379. (externalTrafficPolicy: Cluster —
  │    also SNATs, so the pod sees a node address, not the Mac.)
  ▼
valkey-primary-1 pod :6379
  │ 5. If slot(foo) belongs to this node → executes.
  │ 6. If not → replies "MOVED 12182 192.168.105.16:6381" (the ANNOUNCED
  │    endpoint of the owner). valkey-cli -c dials that → back to step 1
  │    with port 6381. One extra round trip, then sticks to the owner.
```

## Path 3 — Valkey gossip: pod → pod, via the announced VIP

valkey-primary-0 needs to gossip with valkey-primary-1, which announces
`192.168.105.16:6380` (bus `16380`).

```
valkey-primary-0 pod (10.42.0.a)
  │ 1. TCP → 192.168.105.16:16380. Pod default route → node (cni0).
  ▼
RD VM routing decision
  │ 2. 192.168.105.16 is a LOCAL address! The dev VIP shim's initContainer
  │    did `ip addr add 192.168.105.16/32 dev lo`. Local delivery → INPUT.
  │    ★ Without the shim the packet would head for the real HAProxy VM and
  │      die at the vz NAT wall (see "The wall" below) — this hop is the
  │      entire reason the shim exists.
  ▼
vip-shim HAProxy (hostNetwork pod, bound to 192.168.105.16:16380)
  │ 3. mode tcp → forwards to valkey-primary-1-ext.valkey.svc:16380.
  ▼
kube-proxy DNAT: Service:16380 → valkey-primary-1 pod :16379
  ▼
valkey-primary-1 bus port
```

In production there is no shim: step 2 routes over the corporate LAN to the
real F5, which forwards to the in-cluster LB IP — same shape, real hairpin.

## Path 4 — the app → Valkey (in-cluster client)

Lettuce bootstraps via headless DNS
(`valkey-primary-0.valkey-primary-headless.valkey.svc`, resolves to the pod
IP), then asks for `CLUSTER SHARDS` and — like every cluster-aware client —
switches to the **announced** endpoints `192.168.105.16:637x`. From there
each connection is Path 3 without the bus: node-local VIP → shim →
Service → pod. So the app's steady-state Valkey traffic transits the shim
too, which is exactly what prod does through the F5.

## Path 5 — HAProxy VM health checks (the reverse direction)

The VM's `check` probes (HTTP `/healthz` against 192.168.64.2:80; TCP against
192.168.64.51:637x/1637x) all originate at 192.168.105.16, route via the Mac
(192.168.105.1 → forwarding → bridge100), and terminate per Paths 1/2. This
direction — Lima subnet → Mac → RD subnet — **works**; it's the opposite
direction that vz NAT kills.

## The wall — why pods can't reach the HAProxy VM

Empirically established (this repo, vz mode RD + vz-based Lima):

| From | To | ICMP | TCP |
|---|---|---|---|
| RD VM via usernet default route (gw 192.168.5.2) | 192.168.105.16 | ✔ | ✘ silently dropped |
| RD VM via vznat (gw 192.168.64.1, manual route) | 192.168.105.16 | ✘ | ✘ |
| HAProxy VM (gw 192.168.105.1 = Mac) | 192.168.64.2 / .51 | ✔ | ✔ |
| Mac | either VM | ✔ | ✔ |

Apple's Virtualization-framework NAT forwards guest traffic to *real*
external destinations only; guest→guest across two different NAT bridges is
dropped regardless of macOS `ip.forwarding`. The asymmetry (VM→RD works,
RD→VM doesn't) is because the HAProxy VM's subnet is socket_vmnet with the
Mac as an ordinary L3 gateway, while RD's egress paths are both NATs with
opinions. Hence the shim (Path 3) — or a multi-node k3s-on-Lima-VMs topology
where the nodes sit on bridge101 themselves (see the architecture doc §5).

## Path 6 — bootstrap & failover control flows

- **Cluster create** (Job, in-cluster): pure pod-DNS traffic
  (`*-headless` names → pod IPs). No LB, no announce involvement — which is
  why bootstrap works even when announce values are misconfigured, and why a
  broken announce only shows up later as client redirects to nowhere.
- **Failover election**: bus messages (Path 3). FAILOVER_AUTH_REQUEST /
  ACK ride the same announced-bus-port connections as ordinary gossip.
- **`kubectl exec` paths** (smoke/chaos/dump scripts): Mac → RD VM's
  kubelet API — a completely separate control-plane path that keeps working
  when *any* of the data paths above are broken. That's why chaos.sh can
  observe and heal a cluster whose external path it just destroyed.

## Debug cheat-sheet — "which hop is broken?"

| Symptom | Broken hop | Check |
|---|---|---|
| `debug-demo.local` times out from Mac | /etc/hosts, VM down, or Mac↛VM | `grep debug-demo /etc/hosts`; `limactl list`; `curl http://<vm-ip>:8404/` |
| HTTP 503 from HAProxy | VM↛RD node (Path 1 steps 4-5) | `sysctl net.inet.ip.forwarding`; HAProxy stats backend row |
| `valkey-cli` to VIP: connection refused on 637x | VM listeners missing | re-run `scripts/install-haproxy-vm.sh` (regenerates haproxy.cfg) |
| `valkey-cli` to VIP: timeout | Mac host-route gone (Path 2 step 3) | `scripts/host-routes.sh list` |
| `cluster_state:fail`, nodes flagging peers `fail?` | gossip path (Path 3) — shim down or VIP /32 lost | `kubectl -n valkey get ds valkey-vip-shim`; `kubectl -n valkey logs -l app.kubernetes.io/name=valkey-vip-shim` |
| MOVED points at an address you can't dial | announce misconfigured | `valkey-cli cluster nodes` — compare col 2 with `valkey_announced_endpoints` in scripts/lib/common.sh |
| Works in-cluster, dead outside | Paths 1/2 entry legs | `scripts/test-external-access.sh` bisects it |
