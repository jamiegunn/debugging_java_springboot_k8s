#!/usr/bin/env bash
# Shared helpers for debug-demo-app scripts.
# Source this from any script: source "$(dirname "$0")/lib/common.sh"

set -euo pipefail

: "${NAMESPACE:=debug-demo}"
: "${SELECTOR:=app.kubernetes.io/name=debug-demo-app}"
: "${APP_CONTAINER:=app}"
: "${JDK_DEBUG_IMAGE:=eclipse-temurin:25-jdk-alpine}"

# Target the multi-node k3s cluster automatically: if the project kubeconfig
# exists and KUBECONFIG isn't already set, point every `kubectl` here. This is
# what makes the whole test/tooling suite run against k3s instead of whatever
# the Mac's default context happens to be.
if [[ -z "${KUBECONFIG:-}" ]]; then
    _COMMON_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)"
    if [[ -s "$_COMMON_REPO/dumps/k3s.kubeconfig" ]]; then
        export KUBECONFIG="$_COMMON_REPO/dumps/k3s.kubeconfig"
    fi
fi

err()  { printf 'error: %s\n' "$*" >&2; }
info() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }

require_cmd() {
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || { err "missing required command: $cmd"; exit 127; }
    done
}

# parse_common_args <args...> — consumes -n/--namespace, -l/--selector, --container.
# Sets NAMESPACE, SELECTOR, APP_CONTAINER. Leaves remaining args in REMAINING_ARGS.
parse_common_args() {
    REMAINING_ARGS=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -n|--namespace) NAMESPACE="$2"; shift 2 ;;
            -l|--selector)  SELECTOR="$2";  shift 2 ;;
            --container)    APP_CONTAINER="$2"; shift 2 ;;
            --) shift; REMAINING_ARGS+=("$@"); break ;;
            *)  REMAINING_ARGS+=("$1"); shift ;;
        esac
    done
}

# resolve_pods — echoes pod names matching selector in namespace.
resolve_pods() {
    kubectl -n "$NAMESPACE" get pods -l "$SELECTOR" \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'
}

# resolve_one_pod [explicit-name] — picks a single pod (explicit, or first match).
resolve_one_pod() {
    local explicit="${1:-}"
    if [[ -n "$explicit" ]]; then
        echo "$explicit"
        return
    fi
    local pod
    pod="$(resolve_pods | head -n1)"
    if [[ -z "$pod" ]]; then
        err "no pod matched namespace=$NAMESPACE selector=$SELECTOR"
        exit 2
    fi
    echo "$pod"
}

# ensure_dir <dir> — mkdir -p with friendly error.
ensure_dir() {
    mkdir -p "$1" || { err "cannot create directory: $1"; exit 1; }
}

# valkey_announced_endpoints [namespace] — the Valkey cluster's ANNOUNCED
# external endpoints, i.e. what clients must dial. One "name<TAB>ip:port"
# line per node. The announce IP comes from the StatefulSet's ANNOUNCE_IP
# env when present (two-layer shape: an external VIP — F5 in prod, the
# HAProxy Lima VM here — fronts the Service IP), else each Service's own
# LoadBalancer IP (one-layer). Ports always come from the Services.
valkey_announced_endpoints() {
    local ns="${1:-valkey}"
    # On k3s the announced address is the HOSTNAME (cluster-announce-hostname),
    # resolved to the VIP by dnsmasq/CoreDNS; the per-node distinguisher is the
    # port. Read the hostname from the chart's config so it tracks values, and
    # the ports from each -ext Service.
    local host role i port
    host="$(kubectl -n "$ns" get cm valkey -o jsonpath='{.data.valkey\.conf}' 2>/dev/null \
            | awk '$1=="cluster-announce-hostname" {print $2; exit}' | tr -d '\r')"
    : "${host:=${VALKEY_HOST:-valkey.debug-demo.local}}"
    for role in primary secondary; do
        for i in 0 1 2; do
            port="$(kubectl -n "$ns" get svc "valkey-${role}-${i}-ext" -o jsonpath='{.spec.ports[?(@.name=="client")].port}' 2>/dev/null || true)"
            [[ -n "$port" ]] || continue
            printf 'valkey-%s-%s\t%s:%s\n' "$role" "$i" "$host" "$port"
        done
    done
}

# vkexec <valkey-cli-args...> — run valkey-cli INSIDE the cluster (from an
# ephemeral pod) so hostnames resolve via CoreDNS → VIP with no Mac /etc/resolver
# needed. This is how the test suites reach valkey.debug-demo.local:port by name.
# VK_PASS must be exported by the caller.
vkexec() {
    kubectl -n "${VALKEY_NS:-valkey}" exec -i valkey-primary-0 -- \
        valkey-cli -a "${VK_PASS:-}" --no-auth-warning "$@" 2>/dev/null
}
