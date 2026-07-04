#!/usr/bin/env bash
#
# jattach.sh — capture JVM thread/heap dumps using jattach
# (https://github.com/jattach/jattach), a single statically-linked binary
# (~80 KB) that speaks the JVM Hotspot attach protocol.
#
# Why this path:
#   - Smaller than `kubectl debug` with a JDK ephemeral container
#   - Doesn't need an ephemeral container at all (some clusters disable that)
#   - Gives access to jcmd-style operations (Thread.print -l, GC.heap_info,
#     JFR.start, VM.native_memory, ...) that actuator doesn't expose
#
# What this path is NOT:
#   - Not the preferred default. Prefer the actuator endpoints first
#     (see scripts that hit /actuator/threaddump and /actuator/heapdump).
#   - jattach is a binary you install INTO the pod. The runtime image
#     ships JRE-only, so this script handles the install:
#       1. --binary <path>           kubectl cp a local copy you provide
#       2. $JATTACH_BINARY env       same as --binary
#       3. scripts/.cache/jattach-*  reuse from prior runs
#       4. curl from GitHub releases on the HOST, then kubectl cp in
#          (we download on the host, not in the pod, to avoid relying
#          on pod egress)
#
# Usage:
#   ./dump-jattach.sh threads [pod]
#   ./dump-jattach.sh heap --confirm [pod]
#   ./dump-jattach.sh jcmd "GC.heap_info" [pod]
#   ./dump-jattach.sh jcmd "VM.native_memory summary" [pod]
#   ./dump-jattach.sh install [pod]                    # just install, do nothing
#
# Common flags from lib/common.sh: -n <ns>, -l <selector>, --container <name>

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_ROOT="$SCRIPT_DIR"; while [[ "$SCRIPTS_ROOT" != / && ! -f "$SCRIPTS_ROOT/lib/common.sh" ]]; do SCRIPTS_ROOT="$(dirname "$SCRIPTS_ROOT")"; done
# shellcheck source=lib/common.sh
source "$SCRIPTS_ROOT/lib/common.sh"

require_cmd kubectl curl

: "${JATTACH_VERSION:=v2.2}"
: "${JATTACH_REMOTE_PATH:=/tmp/jattach}"
: "${JATTACH_CACHE_DIR:=$JDEBUG_CACHE_DIR}"

ACTION=""
CONFIRMED=0
JCMD_ARG=""
LOCAL_BINARY="${JATTACH_BINARY:-}"
FILTERED_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        threads|heap|jcmd|install) ACTION="$1"; shift ;;
        --binary)                  LOCAL_BINARY="$2"; shift 2 ;;
        --confirm)                 CONFIRMED=1; shift ;;
        -h|--help)
            usage
            exit 0 ;;
        --) shift; FILTERED_ARGS+=("$@"); break ;;
        *)  FILTERED_ARGS+=("$1"); shift ;;
    esac
done

if [[ "$ACTION" == "jcmd" ]]; then
    JCMD_ARG="${FILTERED_ARGS[0]:-}"
    if [[ -z "$JCMD_ARG" ]]; then
        err "jcmd action requires a command string (e.g. 'GC.heap_info')"
        exit 64
    fi
    FILTERED_ARGS=("${FILTERED_ARGS[@]:1}")
fi

# ${arr[@]+...} guard: bash 3.2 (stock macOS) treats "${arr[@]}" on an empty
# array as unbound under `set -u`; fixed only in bash 4.4.
parse_common_args ${FILTERED_ARGS[@]+"${FILTERED_ARGS[@]}"}
POD="$(resolve_one_pod "${REMAINING_ARGS[0]:-}")"

if [[ -z "$ACTION" ]]; then
    err "usage: dump-jattach.sh {threads|heap|jcmd|install} [args] [pod]"
    exit 64
fi
if [[ "$ACTION" == "heap" && $CONFIRMED -ne 1 ]]; then
    err "heap dump pauses the JVM. Re-run with --confirm to proceed."
    exit 64
fi

# ---------------------------------------------------------------------------
# Install jattach into the pod if it's not already there.
# ---------------------------------------------------------------------------
install_jattach() {
    if kubectl -n "$NAMESPACE" exec "$POD" -c "$APP_CONTAINER" -- \
            test -x "$JATTACH_REMOTE_PATH" 2>/dev/null; then
        info "jattach already present at $JATTACH_REMOTE_PATH (in $POD)"
        return
    fi

    # 1. Explicit binary the caller handed us
    if [[ -n "$LOCAL_BINARY" ]]; then
        if [[ ! -f "$LOCAL_BINARY" ]]; then
            err "--binary path not found: $LOCAL_BINARY"
            exit 1
        fi
        info "installing jattach from local file: $LOCAL_BINARY"
        kubectl -n "$NAMESPACE" cp "$LOCAL_BINARY" "$POD:$JATTACH_REMOTE_PATH" -c "$APP_CONTAINER"
        kubectl -n "$NAMESPACE" exec "$POD" -c "$APP_CONTAINER" -- chmod +x "$JATTACH_REMOTE_PATH"
        return
    fi

    # 2/3/4. Auto-detect arch, use cached or download tarball to cache, kubectl cp in
    local arch tarball_arch
    arch="$(kubectl -n "$NAMESPACE" exec "$POD" -c "$APP_CONTAINER" -- uname -m)"
    case "$arch" in
        x86_64|amd64)  tarball_arch="x64"   ;;
        aarch64|arm64) tarball_arch="arm64" ;;
        *) err "unsupported pod arch: $arch (provide --binary instead)"; exit 1 ;;
    esac

    local cache_file="$JATTACH_CACHE_DIR/jattach-${arch}-${JATTACH_VERSION}"
    if [[ ! -f "$cache_file" ]]; then
        ensure_dir "$JATTACH_CACHE_DIR"
        local tarball_url="https://github.com/jattach/jattach/releases/download/${JATTACH_VERSION}/jattach-linux-${tarball_arch}.tgz"
        local tmp_dir; tmp_dir="$(mktemp -d -t jattach.XXXXXX)"
        local tmp_tgz="$tmp_dir/jattach.tgz"
        info "downloading jattach ${JATTACH_VERSION} (linux-${tarball_arch}) from upstream..."
        info "  $tarball_url"
        curl -fsSL -o "$tmp_tgz" "$tarball_url" || {
            err "download failed. Provide a binary with --binary <path>."
            rm -rf "$tmp_dir"
            exit 1
        }
        # Tarball contains a single 'jattach' file at the top level. Extract
        # to a temp dir and move into cache — portable across GNU and BSD tar.
        tar -xzf "$tmp_tgz" -C "$tmp_dir"
        mv "$tmp_dir/jattach" "$cache_file"
        chmod +x "$cache_file"
        rm -rf "$tmp_dir"
        info "cached at $cache_file"
    else
        info "using cached jattach: $cache_file"
    fi

    info "kubectl cp $cache_file $POD:$JATTACH_REMOTE_PATH"
    kubectl -n "$NAMESPACE" cp "$cache_file" "$POD:$JATTACH_REMOTE_PATH" -c "$APP_CONTAINER"
    kubectl -n "$NAMESPACE" exec "$POD" -c "$APP_CONTAINER" -- chmod +x "$JATTACH_REMOTE_PATH"

    # Sanity check: jattach with no args prints "Usage: jattach <pid>..." to
    # stderr and exits non-zero. We capture both streams and only fail if
    # we see nothing at all (i.e. exec/libc broke).
    local probe
    probe="$(kubectl -n "$NAMESPACE" exec "$POD" -c "$APP_CONTAINER" -- "$JATTACH_REMOTE_PATH" 2>&1 || true)"
    if [[ -z "$probe" ]]; then
        err "jattach binary produced no output inside the pod (libc/arch mismatch?)."
        err "Provide a binary that matches the pod with --binary."
        exit 1
    fi
    info "jattach installed and working ($(echo "$probe" | head -1 | head -c 60)...)"
}

# Find the actual JVM PID inside the pod. With shareProcessNamespace=true,
# pod PID 1 is the pause sandbox container — the JVM is somewhere else.
# We look for the first process whose comm is "java".
find_jvm_pid() {
    local pid
    pid="$(kubectl -n "$NAMESPACE" exec "$POD" -c "$APP_CONTAINER" -- sh -c '
        for p in $(ls /proc 2>/dev/null | grep -E "^[0-9]+$"); do
            if [ "$(cat /proc/$p/comm 2>/dev/null)" = "java" ]; then
                echo "$p"; exit 0
            fi
        done
        exit 1
    ' 2>/dev/null || true)"
    if [[ -z "$pid" ]]; then
        err "no 'java' process found inside pod $POD container $APP_CONTAINER"
        exit 1
    fi
    echo "$pid"
}

install_jattach

if [[ "$ACTION" == "install" ]]; then
    info "done."
    exit 0
fi

JVM_PID="$(find_jvm_pid)"
info "JVM PID inside pod: $JVM_PID"

# ---------------------------------------------------------------------------
# Run the requested action.
#
# jattach has several actions; we want the one it calls `jcmd`. This is
# NOT the standalone JDK `jcmd` tool — it's a jattach action that proxies
# a jcmd-syntax command string into the JVM through the attach socket and
# writes the response back to jattach's own stdout. So
# `kubectl exec ... > local-file` captures cleanly, no `kubectl logs`
# scraping needed. Contrast with `jattach <pid> threaddump`, which makes
# the JVM print to its own stdout (the container log stream).
# ---------------------------------------------------------------------------
TS="$(date -u +%Y%m%dT%H%M%SZ)"
case "$ACTION" in
    threads)
        OUT_DIR="${OUT_DIR:-./dumps/threads}"
        ensure_dir "$OUT_DIR"
        LOCAL_PATH="$OUT_DIR/${POD}-jattach-thread-$TS.txt"
        info "running jattach jcmd 'Thread.print -l' on PID $JVM_PID"
        kubectl -n "$NAMESPACE" exec "$POD" -c "$APP_CONTAINER" -- \
            "$JATTACH_REMOTE_PATH" "$JVM_PID" jcmd "Thread.print -l" > "$LOCAL_PATH"
        info "wrote $LOCAL_PATH ($(wc -l <"$LOCAL_PATH") lines)"
        ;;
    heap)
        OUT_DIR="${OUT_DIR:-./dumps/heap}"
        ensure_dir "$OUT_DIR"
        REMOTE_PATH="/tmp/heap-jattach-$TS.hprof"
        LOCAL_PATH="$OUT_DIR/${POD}-jattach-heap-$TS.hprof"
        info "running jattach dumpheap (PAUSES JVM)"
        kubectl -n "$NAMESPACE" exec "$POD" -c "$APP_CONTAINER" -- \
            "$JATTACH_REMOTE_PATH" "$JVM_PID" dumpheap "$REMOTE_PATH"
        info "copying $REMOTE_PATH -> $LOCAL_PATH"
        kubectl -n "$NAMESPACE" cp "$POD:$REMOTE_PATH" "$LOCAL_PATH" -c "$APP_CONTAINER"
        kubectl -n "$NAMESPACE" exec "$POD" -c "$APP_CONTAINER" -- rm -f "$REMOTE_PATH" || true
        info "wrote $LOCAL_PATH ($(du -h "$LOCAL_PATH" | cut -f1))"
        ;;
    jcmd)
        info "running jcmd '$JCMD_ARG' on PID $JVM_PID"
        kubectl -n "$NAMESPACE" exec "$POD" -c "$APP_CONTAINER" -- \
            "$JATTACH_REMOTE_PATH" "$JVM_PID" jcmd "$JCMD_ARG"
        ;;
esac
