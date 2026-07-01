#!/usr/bin/env bash
#
# host-routes.sh — add or remove macOS static routes that point Valkey's
# MetalLB per-pod LoadBalancer IPs (192.168.64.51-56) at the Rancher Desktop VM.
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

cmd_add() {
    info "VM gateway: $VM_IP"
    info "discovering MetalLB-assigned IPs..."
    discover_ips | while IFS=$'\t' read -r svc ip; do
        if [[ -z "$ip" ]]; then continue; fi
        info "  + $ip  ($svc)"
        sudo route -nv add -host "$ip" "$VM_IP" 2>&1 | tail -1 || true
    done
}

cmd_remove() {
    info "removing static routes for MetalLB IPs"
    discover_ips | while IFS=$'\t' read -r svc ip; do
        if [[ -z "$ip" ]]; then continue; fi
        info "  - $ip  ($svc)"
        sudo route -nv delete "$ip" 2>&1 | tail -1 || true
    done
}

cmd_list() {
    info "current routes for MetalLB-assigned IPs:"
    discover_ips | while IFS=$'\t' read -r svc ip; do
        if [[ -z "$ip" ]]; then continue; fi
        local gw iface
        gw="$(route -n get "$ip" 2>/dev/null | awk '/gateway/ {print $2}' | head -1)"
        iface="$(route -n get "$ip" 2>/dev/null | awk '/interface/ {print $2}' | head -1)"
        printf "  %-22s %-15s gw=%-18s iface=%s\n" "$svc" "$ip" "${gw:-<none>}" "${iface:-<none>}"
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
