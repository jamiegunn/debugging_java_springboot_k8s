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

# Third-party images pulled on the Mac, saved to tars, imported into every
# node's containerd (NOTHING is pulled from the internet inside a VM/pod).
# NOTE: no MetalLB (keepalived replaces it), no haproxy/busybox VIP-shim
# (the real VIP is directly reachable now).
K3S_IMAGES=(
    "registry.k8s.io/ingress-nginx/controller:v1.11.3@sha256:d56f135b6462cfc476447cfe564b83a45e8bb7da2774963b00d12161112270b7"
    "registry.k8s.io/ingress-nginx/kube-webhook-certgen:v1.4.4@sha256:a9f03b34a3cbfbb26d103a14046ab2c5130a80c3d69d526ff8063d2b37b9fd3f"
    "gvenzl/oracle-free:23-slim-faststart"
    "icr.io/ibm-messaging/mq:9.4.5.1-r1-amd64"
    "valkey/valkey:8.0.1-alpine"
    "releases-docker.jfrog.io/jfrog/artifactory-jcr:7.90.10"
    "postgres:16-alpine"
    "maven:3.9-eclipse-temurin-21"
    "eclipse-temurin:21-jre-alpine"
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
