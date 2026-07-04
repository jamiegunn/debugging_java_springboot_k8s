#!/usr/bin/env bash
# jdebug — shared helpers. PORTABLE: no assumptions about any particular app,
# namespace, or kubeconfig. Targets whatever `kubectl`/$KUBECONFIG is active.
# Override the target with -n/--namespace, -l/--selector, --container, or the
# JDEBUG_NAMESPACE / JDEBUG_SELECTOR / JDEBUG_CONTAINER environment variables.

set -euo pipefail

: "${NAMESPACE:=${JDEBUG_NAMESPACE:-default}}"
: "${SELECTOR:=${JDEBUG_SELECTOR:-}}"          # empty = any pod in the namespace
: "${APP_CONTAINER:=${JDEBUG_CONTAINER:-app}}" # common Spring Boot container name
: "${JDK_DEBUG_IMAGE:=${JDEBUG_JDK_IMAGE:-eclipse-temurin:21-jdk-alpine}}"

# Cache for the downloaded jattach binary — a standard per-user location so the
# kit works the same whether it's run from a repo checkout or installed on PATH.
: "${JDEBUG_CACHE_DIR:=${XDG_CACHE_HOME:-$HOME/.cache}/jdebug}"

# NOTE: no automatic KUBECONFIG rewriting. jdebug uses the ambient kubectl
# context. Point it at a cluster the normal way (KUBECONFIG=... or kubectl config
# use-context), exactly like kubectl itself.

err()  { printf 'error: %s\n' "$*" >&2; }
info() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }

require_cmd() {
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || { err "missing required command: $cmd"; exit 127; }
    done
}

# usage — print the calling script's header comment block (line 2 to the first
# blank line) as its --help text. Every tool keeps its docs in the header.
usage() {
    sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
}

# parse_common_args <args...> — consumes -n/--namespace, -l/--selector,
# --container, and -h/--help. Sets NAMESPACE/SELECTOR/APP_CONTAINER; leaves the
# rest in REMAINING_ARGS.
parse_common_args() {
    REMAINING_ARGS=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -n|--namespace) NAMESPACE="$2"; shift 2 ;;
            -l|--selector)  SELECTOR="$2";  shift 2 ;;
            --container)    APP_CONTAINER="$2"; shift 2 ;;
            -h|--help)      usage; exit 0 ;;
            --) shift; REMAINING_ARGS+=("$@"); break ;;
            *)  REMAINING_ARGS+=("$1"); shift ;;
        esac
    done
}

# show_cmd <words...> — echo the exact command a tool is about to run, so every
# capture doubles as a copy-pasteable cookbook.
show_cmd() { printf '  $ %s\n' "$*" >&2; }

# resolve_pods — pod names matching selector in namespace (empty selector = all).
resolve_pods() {
    if [[ -n "$SELECTOR" ]]; then
        kubectl -n "$NAMESPACE" get pods -l "$SELECTOR" \
            -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'
    else
        kubectl -n "$NAMESPACE" get pods \
            -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'
    fi
}

# resolve_one_pod [explicit-name] — a single pod (explicit, or first match).
resolve_one_pod() {
    local explicit="${1:-}"
    if [[ -n "$explicit" ]]; then echo "$explicit"; return; fi
    local pod; pod="$(resolve_pods | head -n1)"
    if [[ -z "$pod" ]]; then
        err "no pod matched namespace=$NAMESPACE selector='${SELECTOR:-<any>}' — pass -n/-l"
        exit 2
    fi
    echo "$pod"
}

# ensure_dir <dir> — mkdir -p with friendly error.
ensure_dir() {
    mkdir -p "$1" || { err "cannot create directory: $1"; exit 1; }
}
