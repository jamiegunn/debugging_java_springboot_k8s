#!/usr/bin/env bash
#
# host-routes.sh — add or remove macOS static routes that point Valkey's
# MetalLB LoadBalancer IP(s) at the Rancher Desktop VM. In the default
# sharedIP-perPort mode that's ONE IP (192.168.64.51, all 6 nodes behind it
# on ports 6379-6384); in legacy perPodIP mode it's six (192.168.64.51-56).
# Either way the IPs are discovered from the cluster's LoadBalancer
# Services, deduplicated, and routed.
#
# Purpose: Rancher Desktop's vz-NAT networking doesn't pass L2 ARP for
# non-VM IPs through to the host, so we tell macOS to use the VM
# (192.168.64.2) as next-hop for each MetalLB IP. The VM's kube-proxy
# iptables rules then DNAT the traffic to the right pod.
#
# Only needed for Valkey L4 traffic. The HTTP path (Pattern D) uses the
# HAProxy Lima VM on its own subnet (192.168.105.x) which the Mac
# reaches directly — no static routes required for HTTP.
#
# This is dev-only: in production these routes are replaced by whatever
# real network path exists between clients and the Valkey nodes (usually
# direct — Valkey clients need per-pod IP addressability for MOVED redirects).
#
# Usage:
#   ./host-routes.sh add        # adds routes (prompts for sudo password)
#   ./host-routes.sh remove     # removes them
#   ./host-routes.sh list       # show current state from `route get`

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_cmd kubectl route sudo

: "${VM_IP:=192.168.64.2}"
: "${POOL_NAMESPACE:=metallb-system}"
: "${POOL_NAME:=bridge-pool}"

# Discover IPs from MetalLB rather than hardcoding — the pool is the source of truth.
discover_ips() {
    # IPs currently assigned to LoadBalancer Services across the cluster
    # (whether MetalLB picked them automatically or pinned via loadBalancerIP).
    kubectl get svc -A -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace}{"/"}{.metadata.name}{"\t"}{.status.loadBalancer.ingress[0].ip}{"\n"}{end}' \
        | awk -F'\t' '$2 ~ /^192\.168\.64\./ {print}'
}

# One line per unique IP, services that share it collapsed into one label.
# In sharedIP-perPort mode all 6 Valkey Services pin the same IP — the host
# needs exactly one route for it, not six attempts at the same route.
discover_unique_ips() {
    discover_ips | awk -F'\t' '
        { if (svcs[$2] == "") svcs[$2] = $1; else svcs[$2] = svcs[$2] "," $1 }
        END { for (ip in svcs) printf "%s\t%s\n", svcs[ip], ip }
    ' | sort -t$'\t' -k2
}

cmd_add() {
    info "VM gateway: $VM_IP"
    info "discovering MetalLB-assigned IPs..."
    discover_unique_ips | while IFS=$'\t' read -r svc ip; do
        if [[ -z "$ip" ]]; then continue; fi
        info "  + $ip  ($svc)"
        sudo route -nv add -host "$ip" "$VM_IP" 2>&1 | tail -1 || true
    done
}

cmd_remove() {
    info "removing static routes for MetalLB IPs"
    discover_unique_ips | while IFS=$'\t' read -r svc ip; do
        if [[ -z "$ip" ]]; then continue; fi
        info "  - $ip  ($svc)"
        sudo route -nv delete "$ip" 2>&1 | tail -1 || true
    done
}

cmd_list() {
    info "current routes for MetalLB-assigned IPs:"
    discover_unique_ips | while IFS=$'\t' read -r svc ip; do
        if [[ -z "$ip" ]]; then continue; fi
        local gw iface
        gw="$(route -n get "$ip" 2>/dev/null | awk '/gateway/ {print $2}' | head -1)"
        iface="$(route -n get "$ip" 2>/dev/null | awk '/interface/ {print $2}' | head -1)"
        printf "  %-15s gw=%-18s iface=%-10s %s\n" "$ip" "${gw:-<none>}" "${iface:-<none>}" "$svc"
    done
}

case "${1:-help}" in
    add)              cmd_add ;;
    remove|del|rm)    cmd_remove ;;
    list|status|ls)   cmd_list ;;
    *)
        cat <<EOF
Usage: $(basename "$0") {add|remove|list}

  add     install static routes pointing every MetalLB-assigned 192.168.64.x
          IP at the RD VM (192.168.64.2). Requires sudo.
  remove  uninstall them
  list    show current routing state for those IPs
EOF
        exit 64 ;;
esac
