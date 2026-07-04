# LB tier: keepalived, HAProxy, and the production F5 shape

This document explains why the lab has both keepalived and HAProxy, what each component owns, how they interact with MetalLB, and what the equivalent production design would look like with an external load balancer such as F5 BIG-IP.

Short version: keepalived owns the stable frontend VIP in the lab. HAProxy makes that VIP useful by forwarding HTTP and Valkey TCP traffic to the correct backend targets. In production, an F5 or equivalent usually replaces both keepalived and HAProxy at the frontend tier, while MetalLB remains the Kubernetes-side backend IP provider unless the production platform has a native load balancer integration.

Related documents:

- [docs/metallb-configuration.md](metallb-configuration.md) explains the Kubernetes-level MetalLB resources and shared backend IP model.
- [docs/valkey-tcp-ingress-routing.md](valkey-tcp-ingress-routing.md) is the canonical Valkey RESP/TCP routing guide.
- [docs/production-translation-guide.md](production-translation-guide.md) is the canonical lab-to-production translation guide.
- [docs/k3s-architecture.md](k3s-architecture.md) explains the full local k3s topology.

## Scope

This document covers:

- why the lab has a dedicated `ddk3s-lb` VM
- why keepalived alone is not enough
- why HAProxy is still needed in the lab
- how HTTP and Valkey traffic flow through the LB tier
- how the lab maps to a production F5 design
- what IPs, routes, DNS records, and firewall rules production would need

This document does not cover:

- the internal Valkey cluster protocol in depth
- MetalLB CRD details beyond how the LB tier consumes MetalLB IPs
- F5 product-specific UI steps, iRules, AS3 declarations, or BIG-IP device-service clustering
- cloud-provider-specific load balancer controllers

## The roles are separate

The lab uses three different network functions, each with a different job:

| Component | Lab implementation | Production equivalent | Job |
|---|---|---|---|
| Frontend VIP ownership | keepalived on `ddk3s-lb` | F5 virtual server address, NetScaler VIP, cloud LB frontend, or equivalent | Own one stable client-facing address. |
| Traffic forwarding and health checks | HAProxy on `ddk3s-lb` | F5 virtual server with pools, monitors, and TCP/HTTP profiles | Accept client connections and forward them to healthy backends. |
| Kubernetes Service external IPs | MetalLB in the k3s cluster | MetalLB, BGP integration, cloud LB controller, or platform-native service LB | Give Kubernetes `LoadBalancer` Services reachable backend addresses. |

These roles are complementary. keepalived does not replace HAProxy. HAProxy does not replace MetalLB. MetalLB does not replace the frontend load balancer.

## Why keepalived exists in the lab

keepalived gives the lab a stable VIP on the Lima shared network:

```text
K3S_VIP=192.168.105.100
```

The VIP lives on the LB VM, not on a k3s worker and not on the control-plane node. That is intentional. If a k3s worker is starved, rebooted, or overloaded, the frontend address should not disappear just because the node is unhealthy.

In this lab, keepalived is configured by `scripts/k3s-lb.sh` with a single VRRP instance:

```text
state MASTER
virtual_router_id 51
priority 150
virtual_ipaddress 192.168.105.100/24
```

There is only one LB VM today, so keepalived is not providing active/standby redundancy between two LB VMs. It is still useful because it makes the lab use a VIP model instead of requiring clients to connect to the VM's DHCP-assigned address.

The important behavior is:

```text
client connects to stable VIP
not to a specific k3s worker
not to a specific DHCP address on the LB VM
```

## Why keepalived alone is not enough

keepalived owns an IP address. It does not proxy traffic.

It can answer this question:

```text
Which machine currently owns 192.168.105.100?
```

It cannot answer these questions:

```text
For HTTP :80, which worker ingress endpoints are healthy?
For Valkey :6380, which backend IP and port should receive the TCP connection?
Should this request avoid a worker whose ingress is down?
Should this TCP port map to a MetalLB backend IP instead of a worker node IP?
```

Those are load-balancing and forwarding decisions. In the lab, HAProxy owns those decisions.

Without HAProxy, a client could connect to the keepalived VIP, but nothing would be listening on the VIP ports unless some process bound those ports. keepalived does not create `:80`, `:6379`, `:6380`, or any other frontend listener.

## Why HAProxy exists in the lab

HAProxy turns the keepalived VIP into an actual external load balancer.

`scripts/k3s-lb.sh` configures HAProxy to listen on the LB VM and bind frontend ports:

```text
VIP:80          -> worker ingress-nginx hostPort :80
VIP:6379-6384   -> Valkey MetalLB shared backend IP on the same port
```

HAProxy provides:

- TCP and HTTP listeners on the VIP
- backend selection
- health checks
- retry and redispatch behavior
- a single place to model the external load balancer tier
- production-like separation between client-facing VIP and Kubernetes backends

For HTTP, HAProxy uses an HTTP health check:

```text
GET /healthz
```

The HTTP backend is the worker agents' ingress-nginx hostPort `:80`. The control-plane node is intentionally not in that pool because workloads and ingress run on the workers.

For Valkey, HAProxy uses one TCP frontend/backend pair per client port:

```text
frontend valkey_6379 -> backend 192.168.105.200:6379
frontend valkey_6380 -> backend 192.168.105.200:6380
frontend valkey_6381 -> backend 192.168.105.200:6381
frontend valkey_6382 -> backend 192.168.105.200:6382
frontend valkey_6383 -> backend 192.168.105.200:6383
frontend valkey_6384 -> backend 192.168.105.200:6384
```

With the current shared-IP MetalLB design, all Valkey ports normally forward to the same backend IP, but the port remains different. Kubernetes then maps each port to a different per-pod Service and pod.

## Lab HTTP traffic path

For the Spring Boot API, Swagger UI, and actuator endpoints, the local path is:

```text
client
  -> debug-demo.local
  -> DNS resolves to K3S_VIP
  -> keepalived VIP on ddk3s-lb
  -> HAProxy :80 HTTP frontend
  -> healthy worker node ingress-nginx hostPort :80
  -> Kubernetes Ingress rule
  -> debug-demo-app ClusterIP Service
  -> app pod
```

The important point is that MetalLB is not in the HTTP path. HTTP uses ingress-nginx on the workers, with HAProxy pooling to the worker ingress endpoints.

## Lab Valkey traffic path

For Valkey client traffic, the local path is:

```text
client
  -> valkey.debug-demo.local:<port>
  -> DNS resolves to K3S_VIP
  -> keepalived VIP on ddk3s-lb
  -> HAProxy TCP frontend for that port
  -> shared MetalLB backend IP:<same port>
  -> worker currently announcing the MetalLB IP
  -> Kubernetes LoadBalancer Service for that port
  -> selected Valkey pod
```

Example for `valkey-primary-1`:

```text
client
  -> valkey.debug-demo.local:6380
  -> 192.168.105.100:6380
  -> HAProxy frontend valkey_6380
  -> 192.168.105.200:6380
  -> valkey-primary-1-ext Service
  -> valkey-primary-1 pod
```

HAProxy does not understand Valkey cluster slots. It only forwards TCP by port. Valkey cluster clients still follow MOVED and ASK redirects. The redirect endpoint is a hostname plus port, and that hostname resolves back to the frontend VIP.

## How this maps to production with F5

In production, F5 or an equivalent external load balancer usually replaces the
lab's keepalived and HAProxy functions:

| Lab | Production F5 equivalent |
|---|---|
| keepalived VIP `192.168.105.100` | F5 virtual server IP on the client-facing network |
| HAProxy HTTP frontend `:80` | F5 HTTP virtual server, profile, pool, and monitor |
| HAProxy Valkey TCP frontends `:6379-6384` | F5 TCP virtual server or multiple listeners with TCP monitors |
| HAProxy backend servers | F5 pool members or nodes |
| `scripts/k3s-lb.sh` generated config | F5 configuration managed by the network/platform team |

The production frontend VIP and the Kubernetes backend IPs usually do not live
in the same subnet. That is normal. The load balancer needs a backend path to
worker IPs, ingress IPs, or MetalLB backend IPs; clients do not need direct
access to those backend addresses.

The canonical production mapping is maintained in
[docs/production-translation-guide.md](production-translation-guide.md). The
Valkey-specific TCP/RESP path is maintained in
[docs/valkey-tcp-ingress-routing.md](valkey-tcp-ingress-routing.md).

## Why the lab network shape still maps to production

The lab collapses the frontend and backend networks onto one Lima shared L2
segment for local operability, but the responsibility split is identical to
production:

```text
client-facing entry point
  -> load balancer decision point
  -> Kubernetes backend target
```

The real boundary is that split, not the subnet boundary. How the two sides are
separated in production — routing, dual-homing, BGP, or a platform load-balancer
integration — lives in
[docs/production-translation-guide.md](production-translation-guide.md); the
L2-vs-routed-vs-NAT background is in
[docs/networking-l2-primer.md](networking-l2-primer.md).

## IP ownership in production

Production usually separates frontend VIP ownership from Kubernetes backend IP
ownership. For this repo's Valkey shape, the target is one frontend VIP for
clients and one shared backend IP for the Valkey per-pod Services. The ownership
and IPAM translation is maintained in
[docs/production-translation-guide.md](production-translation-guide.md).

## DNS expectations

Clients should resolve service names to the frontend VIP, not the MetalLB backend IP:

```text
debug-demo.company.example  -> F5 HTTP VIP
valkey.company.example      -> F5 Valkey VIP
```

For this lab:

```text
debug-demo.local        -> keepalived VIP on ddk3s-lb
valkey.debug-demo.local -> keepalived VIP on ddk3s-lb
```

Valkey announces hostname endpoints such as:

```text
valkey.debug-demo.local:6380
```

In production, the equivalent hostname should resolve to the F5 frontend VIP. The F5 then forwards the port to the MetalLB backend IP on the same port.

## Firewall and routing requirements

The production network must allow:

- client networks to reach the F5 frontend VIP on HTTP ports and Valkey client ports
- F5 backend self IPs to reach Kubernetes worker or MetalLB backend networks
- F5 to reach Valkey backend ports `6379-6384`
- F5 to reach ingress backend ports if using worker-node ingress pooling
- Kubernetes workers to announce or route MetalLB IPs according to the chosen MetalLB mode

If MetalLB L2 mode is used, the backend network must support ARP for the MetalLB backend IP on the worker/server segment. If the F5 is not directly on that L2 segment, routing must carry traffic to a gateway or interface that can reach the segment where the MetalLB IP is announced.

If that is difficult in production, evaluate MetalLB BGP mode or a load balancer integration that programs F5 or the platform directly.

## Health checks

Lab HAProxy health checks are intentionally simple:

- HTTP ingress uses `GET /healthz`
- Valkey TCP backends use TCP connect checks

Production F5 should use equivalent monitors:

| Path | Suggested monitor |
|---|---|
| HTTP ingress | HTTP or HTTPS monitor against ingress health endpoint |
| Valkey TCP ports | TCP connect monitor per port, or a Redis/Valkey-aware monitor if approved and tested |
| MetalLB backend IP reachability | Route/ARP visibility plus backend monitor status |

Be careful with Valkey application-level monitors. A monitor that sends commands to one node can create noise, require credentials, or behave poorly during failover. A TCP monitor is simpler and matches the lab model.

## What can be removed in the lab

The pieces can be removed only if another component takes over their role.

| Remove | What must replace it | Tradeoff |
|---|---|---|
| keepalived | Fixed LB VM IP or another VIP owner | Lose floating/stable VIP semantics unless replaced. |
| HAProxy | F5, another proxy, direct-to-MetalLB DNS, or direct worker access | Lose frontend forwarding and health checks unless replaced. |
| MetalLB | NodePort, ingress-only design, cloud LB controller, or F5-integrated Service controller | Lose Kubernetes `LoadBalancer` Service IPs unless replaced. |

In the current lab, keep both keepalived and HAProxy. keepalived gives the stable VIP. HAProxy makes that VIP route useful traffic.

## Operational checks

Check the LB VM tier:

```sh
scripts/k3s-lb.sh status
```

Expected shape:

```text
ddk3s-lb: Running
VIP 192.168.105.100: held
keepalived: up
haproxy: up
VIP reachable from Mac: yes
```

Check HAProxy-generated Valkey backends by inspecting the config on the LB VM:

```sh
limactl shell ddk3s-lb -- sudo cat /etc/haproxy/haproxy.cfg
```

Check the MetalLB backend Services that HAProxy targets:

```sh
kubectl --kubeconfig dumps/k3s.kubeconfig -n valkey get svc -o wide
```

Check the whole stack:

```sh
scripts/k3s.sh doctor
scripts/k3s.sh smoke
```

## Troubleshooting map

| Symptom | Likely layer | First check |
|---|---|---|
| DNS resolves but connection refused | HAProxy not listening | `scripts/k3s-lb.sh status` |
| VIP not reachable | keepalived or LB VM | `scripts/k3s-lb.sh status`, `limactl list ddk3s-lb` |
| HTTP works on one worker but not through VIP | HAProxy HTTP backend | HAProxy config and ingress health checks |
| Valkey hostname resolves but one port fails | HAProxy port mapping or Valkey Service | HAProxy config, `kubectl -n valkey get svc -o wide` |
| Valkey Services have no backend IP | MetalLB | [docs/metallb-configuration.md](metallb-configuration.md) operational checks |
| Production F5 can reach VIP but not backends | routing or firewall | F5 route table, firewall policy, backend VLAN reachability |

## Design summary

The lab stack intentionally models a production load-balancer tier:

```text
keepalived VIP + HAProxy on ddk3s-lb
  approximates
F5 virtual server + pools + monitors
```

The clean separation is:

```text
frontend entry point: keepalived in lab, F5 in production
traffic forwarding: HAProxy in lab, F5 pools/monitors in production
Kubernetes backend IPs: MetalLB in lab, MetalLB or platform integration in production
```

That separation is why keepalived does not eliminate the need for HAProxy in the lab. keepalived owns the address. HAProxy moves the traffic.
