# docs — map

These documents describe the **k3s/Lima testbed** that the repository runs on.
The testbed is scaffolding: the actual deliverable is the **debugging,
validation, and operational tooling** (`scripts/`, the `./jdebug` JVM debug kit,
and the runbook in the top-level `CLAUDE.md`). Read these when you want to
understand *how the lab routes traffic and stores state* and *what the
production-shaped equivalents would be* — not as a production Kubernetes
blueprint.

Every claim these docs make about the running cluster is checkable:
`scripts/k3s.sh docs-verify` asserts them against the live stack (it exists
because a "shared MetalLB IP" claim was once silently false).

## Start here

| Doc | What it covers |
|-----|----------------|
| [k3s-architecture.md](k3s-architecture.md) | The design reference — 4-VM topology, the LB tier + VIP, DNS, air-gap, the hostname model. Start here, then follow the deep-dive links. |

## Deep dives (the non-obvious parts)

| Doc | What it covers |
|-----|----------------|
| [lb-tier-keepalived-haproxy.md](lb-tier-keepalived-haproxy.md) | Why the lab has *both* keepalived (owns the VIP) and HAProxy (backend pool), what each owns, and the F5 mapping. |
| [metallb-configuration.md](metallb-configuration.md) | MetalLB at the Kubernetes level — how the Valkey Services share **one** pool IP, the agents-only `L2Advertisement`, limits. |
| [valkey-tcp-ingress-routing.md](valkey-tcp-ingress-routing.md) | Why Valkey uses RESP/TCP (not HTTP ingress), one Service per pod, one shared IP, and how port identity preserves the shard. |
| [stateful-storage-poc.md](stateful-storage-poc.md) | How the StatefulSets request storage, what `local-path` means (node-local, RWO), and why it's POC-only. |
| [networking-l2-primer.md](networking-l2-primer.md) | Background: L2 segments, ARP, and how the routed/NATed alternatives differ. A networking lesson, not a design ref. |

## Lab → production

| Doc | What it covers |
|-----|----------------|
| [production-translation-guide.md](production-translation-guide.md) | The **canonical** mapping from every lab component to its production responsibility (F5, CSI storage, IPAM, BGP). The other docs link here instead of repeating it. |

## Verify + operate

| Doc / command | What it covers |
|---------------|----------------|
| [install-test-plan.md](install-test-plan.md) | Break→verify→restore playbook for each install prerequisite, plus the full install→doctor→smoke→uninstall flow. |
| `scripts/k3s.sh doctor` | One-shot health across every layer (start here if something's broken). |
| `scripts/k3s.sh docs-verify` | Asserts the design claims in *these docs* against the live cluster. |

## Reviews (point-in-time, dated — not current design)

| Doc | What it covers |
|-----|----------------|
| [reviews/debugging-tools-eval-2026-07.md](reviews/debugging-tools-eval-2026-07.md) | A senior-SRE review of the debugging tooling + TUI. |
| [reviews/debugging-tools-eval-prompt.md](reviews/debugging-tools-eval-prompt.md) | The reusable prompt that produced it. |

---

**The point of the repo isn't the cluster.** For the debugging capability the
testbed exists to exercise — thread/heap capture without a JDK, memory anatomy,
snapshot bundling — run `./jdebug` (the JVM debug kit) or read the runbook in
[`../CLAUDE.md`](../CLAUDE.md).
