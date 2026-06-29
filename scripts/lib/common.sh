#!/usr/bin/env bash
# Shared helpers for debug-demo-app scripts.
# Source this from any script: source "$(dirname "$0")/lib/common.sh"

set -euo pipefail

: "${NAMESPACE:=debug-demo}"
: "${SELECTOR:=app.kubernetes.io/name=debug-demo-app}"
: "${APP_CONTAINER:=app}"
: "${JDK_DEBUG_IMAGE:=eclipse-temurin:21-jdk-alpine}"

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
