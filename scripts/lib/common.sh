#!/usr/bin/env bash
# Shared helpers for debug-demo-app scripts.
# Source this from any script: source "$(dirname "$0")/lib/common.sh"

set -euo pipefail

: "${NAMESPACE:=debug-demo}"
: "${SELECTOR:=app.kubernetes.io/name=debug-demo-app}"
: "${APP_CONTAINER:=app}"
: "${JDK_DEBUG_IMAGE:=eclipse-temurin:25-jdk-alpine}"

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
    local announce_ip role i ip port
    announce_ip="$(kubectl -n "$ns" get statefulset valkey-primary \
        -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="ANNOUNCE_IP")].value}' 2>/dev/null || true)"
    for role in primary secondary; do
        for i in 0 1 2; do
            ip="$(kubectl -n "$ns" get svc "valkey-${role}-${i}-ext" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
            port="$(kubectl -n "$ns" get svc "valkey-${role}-${i}-ext" -o jsonpath='{.spec.ports[?(@.name=="client")].port}' 2>/dev/null || true)"
            [[ -n "$ip" && -n "$port" ]] || continue
            printf 'valkey-%s-%s\t%s:%s\n' "$role" "$i" "${announce_ip:-$ip}" "$port"
        done
    done
}
