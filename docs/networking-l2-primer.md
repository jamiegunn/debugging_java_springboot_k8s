# Networking primer: L2, ARP, and the flat lab network

This is a background primer on the one networking property the local lab leans
on: the Mac and all VMs sharing a single L2 segment. It explains what that
means, why it makes the keepalived VIP and the MetalLB IP directly reachable,
and how the routed (L3) and NATed alternatives differ. This is a networking
lesson, not a design reference — the topology itself lives in
[docs/k3s-architecture.md](k3s-architecture.md), and the lab-to-production
mapping lives in [docs/production-translation-guide.md](production-translation-guide.md).

Short version: an L2 segment is a single Ethernet broadcast domain, so hosts on
it can find each other with ARP and reach each other's MAC addresses without a
router. That is why a keepalived VIP or a MetalLB IP "announced" on the Lima
shared network becomes reachable immediately. Routed or NATed designs break that
direct ARP reachability, so they need explicit routes, port-forwarding, or a
proxy instead.

## The shared L2 segment

The lab intentionally uses one property to keep the local install simple: **the
Mac and all VMs sit on a single L2 segment** — Lima's **`shared` network**
(socket_vmnet, `192.168.105.0/24`). A keepalived VIP on that segment is directly
reachable from the Mac, the LB VM can reach the worker nodes, and HAProxy can
reach the MetalLB backend IP without extra routes.

An L2 segment is a single Ethernet broadcast domain: hosts on it can discover
each other directly with ARP, then send frames to each other's MAC addresses
without crossing a router. That is why a VIP or MetalLB address can be
"announced" on this network and become reachable immediately. The alternatives
are L3/routed or NATed designs. In a routed design, each subnet is separated by
a router or firewall, so traffic can still work, but only if routes and policy
allow the LB tier to reach the Kubernetes backend addresses. In a NATed design,
the VM network is hidden behind address translation, so outside clients usually
cannot reach arbitrary VIPs or MetalLB IPs directly; they need port forwarding,
a proxy, or a load-balancer address exposed on the client-facing network.

## What "no shared segment" would require

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
and MetalLB backend IPs. The shared L2 network removes those extra moving parts.

## The invariant that carries forward

The flat network is a lab convenience. The important invariant is not that every
address shares one subnet; it is that **clients reach a stable frontend VIP, and
the LB tier can reach the Kubernetes backend targets**. In the lab, that
reachability comes from one flat L2 network. In production, it usually comes from
dual-homed load-balancer interfaces, firewall/routing policy, BGP-advertised
backend networks, or a platform-native load-balancer integration. The full
lab-to-production mapping lives in
[docs/production-translation-guide.md](production-translation-guide.md).
