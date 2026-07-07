#!/usr/bin/env bash
# k3s-env.sh — single source of truth for the multi-node k3s stack. Every
# k3s-* script sources this. Override any value via the environment.
#
# Topology: 3 Lima VMs on Lima's `shared` network (socket_vmnet, 192.168.105/24
# — directly reachable from the Mac AND between VMs, so no NAT/route hacks).
#   ddk3s-server   k3s server (control-plane) + keepalived MASTER + dnsmasq
#   ddk3s-agent-1  k3s agent + keepalived BACKUP
#   ddk3s-agent-2  k3s agent + keepalived BACKUP
#
# One keepalived VRRP VIP floats across the three nodes. dnsmasq (on the
# server) resolves every service hostname to that VIP. ingress-nginx runs as a
# DaemonSet on hostPort 80/443, so wherever the VIP lands, HTTP is answered;
# Valkey is reached on the same VIP, port-separated 6379-6384, and announces a
# HOSTNAME (cluster-preferred-endpoint-type hostname) so MOVED/CLUSTER SHARDS
# return names, never IPs.

# --- VMs --------------------------------------------------------------------
: "${K3S_VM_PREFIX:=ddk3s}"
: "${K3S_SERVER_VM:=${K3S_VM_PREFIX}-server}"
K3S_AGENT_VMS=("${K3S_VM_PREFIX}-agent-1" "${K3S_VM_PREFIX}-agent-2")
K3S_ALL_VMS=("$K3S_SERVER_VM" "${K3S_AGENT_VMS[@]}")

# Pin the single-replica stateful backends (Oracle, MQ) to ONE node so node-kill
# tests are deterministic: kill this node → both go down; kill the other agent →
# they survive. (k3s node names are lima-<vm>.) Empty = let the scheduler choose.
: "${K3S_STATEFUL_NODE:=lima-${K3S_VM_PREFIX}-agent-2}"

# Valkey node-split for node-failure resilience: pin all PRIMARY pods to one
# agent and all SECONDARY pods to the other, so every shard has a member on each
# node — kill either agent and Valkey cluster failover keeps the app working.
# Secondaries go with the stateful node (Oracle/MQ) by default; primaries to the
# other agent. On by default; set K3S_VALKEY_SPLIT="" to let the scheduler choose.
: "${K3S_VALKEY_SPLIT:=1}"
: "${K3S_VALKEY_SECONDARY_NODE:=$K3S_STATEFUL_NODE}"
: "${K3S_VALKEY_PRIMARY_NODE:=lima-${K3S_VM_PREFIX}-agent-1}"

# The load-balancer tier: a SEPARATE VM (the F5/NetScaler stand-in) that runs
# keepalived (owns the VIP) + HAProxy (pools to the k3s nodes). The VIP lives
# here, NOT on the cluster nodes — so it's independent of cluster-node health.
: "${K3S_LB_VM:=${K3S_VM_PREFIX}-lb}"

# Per-VM sizing (24 GB Mac budget: 3 + 7 + 7 + 1 = 18 GB VMs, ~6 GB left).
: "${K3S_SERVER_CPUS:=2}"; : "${K3S_SERVER_MEM:=3}"       # GiB
: "${K3S_AGENT_CPUS:=3}";  : "${K3S_AGENT_MEM:=7}"        # GiB
: "${K3S_LB_CPUS:=1}";     : "${K3S_LB_MEM:=1}"           # tiny: just haproxy+keepalived
: "${K3S_DISK:=40}"                                       # GiB per VM

# --- network / VIP / DNS ----------------------------------------------------
: "${LIMA_SHARED_SUBNET:=192.168.105}"   # socket_vmnet shared network
# K3S_VIP (keepalived VRRP VIP) is resolved further down, once REPO_ROOT is
# known: env override > persisted dumps/k3s-vip (what the last install used) >
# default .100. The install pre-flights it for conflicts and persists the value.
: "${K3S_VRRP_ROUTER_ID:=51}"
: "${K3S_VRRP_AUTH_PASS:=debugdemo}"

# The base domain and the service hostnames everything resolves to the VIP.
: "${BASE_DOMAIN:=debug-demo.local}"
: "${APP_HOST:=${BASE_DOMAIN}}"                    # http://debug-demo.local
: "${VALKEY_HOST:=valkey.${BASE_DOMAIN}}"          # valkey.debug-demo.local:6379-6384
: "${SWAGGER_HOST:=${BASE_DOMAIN}}"

# Valkey external port block (client base + 0..5; bus = client + 10000).
: "${VALKEY_CLIENT_BASE:=6379}"
: "${VALKEY_BUS_BASE:=16379}"
: "${VALKEY_NODE_COUNT:=6}"

# --- versions (pinned; air-gap bundles these exact refs) --------------------
: "${K3S_VERSION:=v1.31.5+k3s1}"          # k3s release tag (binary + airgap tar)
: "${NGINX_INGRESS_VERSION:=4.11.3}"      # helm chart; controller v1.11.3
: "${METALLB_VERSION:=v0.14.9}"           # native manifest (k3s/manifests) + images
# MetalLB L2 IP pool for the Valkey LoadBalancer Services. Must avoid the VIP
# (.100) and the VMs' DHCP leases (low addresses); a high static range is safe.
: "${METALLB_POOL:=${LIMA_SHARED_SUBNET}.200-${LIMA_SHARED_SUBNET}.209}"
# Valkey keeps one LoadBalancer Service per pod for deterministic selectors, but
# those Services can share one MetalLB IP because each exposes a unique port.
# Default to the first IP in the local MetalLB range; override or blank this for
# environments that want independent Service IPs.
: "${VALKEY_SHARED_LB_IP:=${METALLB_POOL%%-*}}"

# Third-party images pulled on the Mac, saved to tars, imported into every
# node's containerd (NOTHING is pulled from the internet inside a VM/pod).
# NOTE: MetalLB fulfills the Valkey type:LoadBalancer Services in-cluster (k3s
# servicelb/klipper is DISABLED at install); the ddk3s-lb keepalived VIP +
# HAProxy front the shared MetalLB IP by port. No VIP-shim (VIP is directly reachable).
K3S_IMAGES=(
    "quay.io/metallb/controller:${METALLB_VERSION}"
    "quay.io/metallb/speaker:${METALLB_VERSION}"
    "registry.k8s.io/ingress-nginx/controller:v1.11.3@sha256:d56f135b6462cfc476447cfe564b83a45e8bb7da2774963b00d12161112270b7"
    "registry.k8s.io/ingress-nginx/kube-webhook-certgen:v1.4.4@sha256:a9f03b34a3cbfbb26d103a14046ab2c5130a80c3d69d526ff8063d2b37b9fd3f"
    "gvenzl/oracle-free:23-slim-faststart"
    "icr.io/ibm-messaging/mq:9.4.5.1-r1-amd64"
    "valkey/valkey:8.0.1-alpine"
    "releases-docker.jfrog.io/jfrog/artifactory-jcr:7.90.10"
    "postgres:16-alpine"
    "maven:3.9-eclipse-temurin-21"
    "eclipse-temurin:21-jre-alpine"
    "eclipse-temurin:21-jdk-alpine"   # ephemeral debug container (dump-threads/dump-heap tier 3)
)
# The app image is built locally (not pulled); this is its ref.
: "${APP_IMAGE:=debug-demo-app:dev}"

# --- paths ------------------------------------------------------------------
# REPO_ROOT is set by the sourcing script; fall back if not.
: "${REPO_ROOT:=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
: "${AIRGAP_DIR:=$REPO_ROOT/dumps/airgap}"        # image tars + k3s binary (gitignored)
: "${K3S_KUBECONFIG:=$REPO_ROOT/dumps/k3s.kubeconfig}"

# VIP resolution: env override wins; else the value the last install persisted
# (dumps/k3s-vip); else the default. This keeps doctor/charts/tui/etc. all
# agreeing on whatever VIP the running cluster actually uses.
K3S_VIP_FILE="$REPO_ROOT/dumps/k3s-vip"
if [[ -z "${K3S_VIP:-}" ]]; then
    if [[ -s "$K3S_VIP_FILE" ]]; then K3S_VIP="$(tr -dc '0-9.' < "$K3S_VIP_FILE")"
    else K3S_VIP="${LIMA_SHARED_SUBNET}.100"; fi
fi

# Arch for k3s airgap artifacts (Apple Silicon → arm64).
case "$(uname -m)" in
    arm64|aarch64) K3S_ARCH=arm64 ;;
    x86_64|amd64)  K3S_ARCH=amd64 ;;
    *) K3S_ARCH="$(uname -m)" ;;
esac
: "${K3S_ARCH:=arm64}"

# kubectl against the k3s cluster (not whatever the Mac's default context is).
kc() { kubectl --kubeconfig "$K3S_KUBECONFIG" "$@"; }

# Resolve a VM's IP on the shared subnet.
k3s_vm_ip() {
    limactl shell "$1" -- ip -4 -o addr show 2>/dev/null \
        | awk -v n="$LIMA_SHARED_SUBNET" '$4 ~ ("^" n "\\.") {sub("/.*","",$4); print $4; exit}'
}

# Confirm each image ref exists in AT LEAST ONE workload (agent) node's
# containerd — i.e. the air-gap tar was actually imported into the cluster. This
# catches the real failure (a tar missing from the bundle, or a wholesale import
# failure) where the image is absent everywhere. We deliberately do NOT require
# it on every node: containerd garbage-collects images off nodes that aren't
# running the pod, so a per-node presence check false-fails on a mature cluster
# or an install re-run. The rarer "imported but on the wrong node" case is caught
# downstream by each phase's rollout wait (which now dumps pod status + events).
# Digests (@sha256:...) are stripped before matching (`ctr images ls` shows the
# repo:tag ref). Prints "  MISSING from all agent nodes: <repo:tag>"; returns 1
# if any image is absent from every agent.
#   usage: verify_images_importable <ref> [ref...]
verify_images_importable() {
    local rc=0 want tag found listing
    local -a lists=()
    local vm
    for vm in "${K3S_AGENT_VMS[@]}"; do
        lists+=("$(limactl shell "$vm" -- sudo k3s ctr images ls -q 2>/dev/null)")
    done
    local dig repo nod
    for want in "$@"; do
        nod="${want%%@*}"                                    # repo[:tag]
        repo="${nod%:*}"                                     # repo path (strip :tag; a registry :port survives — it's before the last /)
        dig=""; case "$want" in *@*) dig="${want#*@}";; esac # sha256:... (the manifest-LIST/index digest)
        found=0
        for listing in "${lists[@]}"; do
            # Match on the REPO PATH — it's always in the stored ref, whether the
            # image kept its tag, is stored by digest only, or (after a --platform
            # import) under a sub-manifest digest that differs from the index one.
            # Fall back to the index digest for good measure.
            if printf '%s\n' "$listing" | grep -qF "$repo" \
               || { [[ -n "$dig" ]] && printf '%s\n' "$listing" | grep -qF "$dig"; }; then found=1; break; fi
        done
        [[ $found -eq 1 ]] || { printf '  MISSING from all agent nodes: %s\n' "$nod" >&2; rc=1; }
    done
    return $rc
}
