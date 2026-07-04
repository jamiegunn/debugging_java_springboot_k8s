# Production translation guide

This document explains how to read the local k3s/Lima lab as a production-shaped POC without mistaking the lab implementation for the production target.

Short version: the repo uses local components to model production responsibilities. keepalived and HAProxy model an external load-balancer tier. MetalLB models Kubernetes `LoadBalancer` backend IP assignment for TCP services. local-path storage models StatefulSet/PVC mechanics only. The production implementation would replace or harden those pieces according to the target platform.

Related documents:

- [docs/k3s-architecture.md](k3s-architecture.md) is the local topology reference.
- [docs/networking-l2-primer.md](networking-l2-primer.md) is the L2/ARP/NAT background for the flat lab network.
- [docs/lb-tier-keepalived-haproxy.md](lb-tier-keepalived-haproxy.md) explains the lab LB tier and F5 shape.
- [docs/metallb-configuration.md](metallb-configuration.md) explains the MetalLB Kubernetes resources.
- [docs/stateful-storage-poc.md](stateful-storage-poc.md) explains why the current PVC storage is POC-only.
- [docs/valkey-tcp-ingress-routing.md](valkey-tcp-ingress-routing.md) explains the Valkey RESP TCP ingress path.

## What carries forward

The durable ideas are:

- client traffic enters through stable hostnames
- those hostnames resolve to a frontend VIP
- the frontend load balancer owns health checks and backend selection
- HTTP and TCP services can have different backend paths
- Valkey RESP traffic is TCP, not HTTP, so it cannot use ordinary HTTP ingress semantics
- Kubernetes `LoadBalancer` Services can provide backend IPs for non-HTTP services
- per-Valkey-node reachability is preserved by port
- the Valkey cluster bus stays pod-to-pod on the Kubernetes network
- network failover and storage recovery are separate concerns

These are the architectural lessons the POC is meant to prove.

## What is lab-specific

The local lab choices are intentionally convenient:

| Lab choice | Why it exists locally | Production translation |
|---|---|---|
| Lima VMs | Reproducible local cluster on a Mac | Real Kubernetes worker/control-plane infrastructure |
| One flat `192.168.105.0/24` L2 network | Avoids local routes, NAT, and port-forwarding | Frontend and backend networks are usually split and routed |
| keepalived on `ddk3s-lb` | Owns one stable local VIP | F5/NetScaler/cloud LB frontend VIP or equivalent |
| HAProxy on `ddk3s-lb` | Provides listeners, health checks, and backend forwarding | F5 virtual servers, pools, monitors, and profiles |
| MetalLB L2 mode | Provides `LoadBalancer` IPs in bare-metal-style k3s | MetalLB L2/BGP, cloud LB controller, F5 integration, or platform service LB |
| dnsmasq and CoreDNS stub | Makes local hostnames resolve to the VIP | Enterprise DNS records and delegated zones |
| local-path StorageClass | Simple local PVC provisioning | CSI-backed production storage with backup/restore and failure-domain design |
| air-gap image bundle | Forces no pod/VM internet pulls | Enterprise registry, artifact promotion, and image admission controls |

## Load balancer translation

The lab stack is:

```text
client
  -> keepalived VIP on ddk3s-lb
  -> HAProxy listener and health checks
  -> Kubernetes backend target
```

The production equivalent is normally:

```text
client
  -> F5 / NetScaler / cloud LB frontend VIP
  -> production load-balancer pools and monitors
  -> Kubernetes backend target
```

In production, the frontend VIP and Kubernetes backend targets usually do not live on the same subnet. That is fine. The requirement is that the load balancer has a backend path to the Kubernetes targets through direct attachment, routing, firewall policy, BGP, or a platform integration.

## MetalLB translation

In this repo, MetalLB is used as the Kubernetes-side provider for `type: LoadBalancer` Services, especially for Valkey TCP/RESP traffic.

The lab uses MetalLB L2 mode because it fits the flat Lima network. Production may use:

- MetalLB L2 if the backend network supports the required L2 adjacency
- MetalLB BGP if the network team wants routed advertisement of service IPs
- a cloud/provider load balancer controller
- an F5/Kubernetes integration that programs load-balancer objects directly
- a different platform-native service load balancer

The important production decision is not "must use MetalLB L2." The important decision is how Kubernetes non-HTTP TCP Services get stable backend reachability.

## Valkey TCP translation

The Valkey POC proves a TCP ingress shape for RESP traffic:

```text
client hostname:port
  -> frontend VIP
  -> TCP load balancer
  -> shared Kubernetes backend IP:port
  -> one per-pod Service
  -> one Valkey pod
```

Production should preserve the same semantic contract:

- clients use a hostname, not pod IPs
- the port identifies the Valkey node endpoint
- load balancers forward TCP without trying to be Valkey-aware unless a tested product feature explicitly supports that
- MOVED/ASK redirects remain hostname-plus-port reachable
- cluster bus, replication, and node-to-node operations do not hairpin through the frontend VIP

See [docs/valkey-tcp-ingress-routing.md](valkey-tcp-ingress-routing.md) for the detailed routing model.

## Storage translation

The lab's StatefulSet PVCs are intentionally not production grade.

In production, stateful services need service-specific storage and recovery decisions:

- Valkey needs a placement and persistence model that matches the desired cache/durable-store role
- Oracle needs supported database storage, backups, and recovery procedures
- IBM MQ needs durable queue-manager storage and HA strategy
- Artifactory and Postgres need supported filestore/database persistence and backups

Do not translate `storageClassName: ""` plus k3s `local-path` into production. Translate the intent instead: each stateful workload needs explicit storage ownership, durability, backup, restore, and failure-domain design.

## DNS and IPAM translation

The lab uses:

```text
debug-demo.local        -> keepalived VIP
valkey.debug-demo.local -> keepalived VIP
```

Production usually needs:

- DNS records owned by the enterprise DNS team
- frontend VIP allocation owned by the network/load-balancer team
- backend MetalLB or service IP allocation owned by network/platform teams
- firewall rules from client networks to frontend VIPs
- firewall rules from load-balancer backend interfaces to Kubernetes backend IPs/ports

For the Valkey shared-IP design, the target is to minimize backend IP allocation:

```text
one frontend VIP for clients
one shared backend IP for Valkey per-pod LoadBalancer Services
ports 6379-6384 distinguish Valkey nodes
```

## What not to copy blindly

Do not copy these lab choices into production without review:

- single LB VM as a front door
- keepalived-only VIP ownership with no redundant peer
- local-path PVCs
- default demo credentials
- tiny resource requests and limits
- DEBUG command enabled for Valkey local testing
- air-gap bundle mechanics as the only image promotion model
- single-subnet assumptions
- absence of production TLS/security policy

## Production readiness checklist

Before translating this POC to production, decide:

- who owns frontend VIPs
- who owns backend service IPs
- whether MetalLB is allowed, and whether it uses L2 or BGP
- how the external load balancer reaches Kubernetes backends
- which DNS names clients use
- which ports are opened through firewalls
- what storage classes are approved for StatefulSets
- how backups and restores are tested
- how Valkey primary/replica placement maps to failure domains
- how logs, metrics, and traces are collected
- how images are promoted into the runtime registry
- how TLS and authentication are enforced

## Design summary

The lab is not the production implementation. It is a production-shaped testbed for proving tooling and traffic behavior.

```text
Lab component       Production responsibility
-------------       -------------------------
keepalived          stable frontend VIP ownership
HAProxy             load-balancer forwarding and health checks
MetalLB             Kubernetes backend IP allocation for TCP Services
local-path          PVC mechanics only, not HA storage
Lima shared L2      simple local reachability, replaced by routing/LB design
```

Read the repo as a set of responsibilities, not as a literal production bill of materials.
