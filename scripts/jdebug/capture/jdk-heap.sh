#!/usr/bin/env bash
#
# dump-heap.sh — heap dump (hprof) via an ephemeral JDK container.
#
# WARNING — DESTRUCTIVE IN PRODUCTION: `jmap -dump:live` triggers a full GC
# and pauses the JVM for the duration of the dump (seconds on a small heap,
# minutes on multi-GB). Requires explicit --confirm.
#
# LAST-RESORT capture path (tier 3). Prefer, in order:
#   1. scripts/jdebug/capture/actuator.sh heap --confirm   (actuator, JRE-only)
#   2. scripts/jdebug/capture/jattach.sh heap --confirm    (tiny binary, jcmd surface)
#   3. this script — when policy allows ephemeral containers but not
#      installing binaries into pods.
#
# The pod runs shareProcessNamespace=true, so PID 1 is the /pause sandbox —
# the debug container discovers the java PID from /proc, aligns uid with the
# JVM (HotSpot attach requires it), and runs jmap. jmap asks the TARGET JVM
# to write the file, so the hprof lands in the app container's /tmp; it is
# copied out with `kubectl cp` afterwards and deleted from the pod.
#
# Air-gap note: the JDK image must be pre-imported into containerd (it is in
# K3S_IMAGES). The terminated ephemeral container stays visible in the pod
# spec until the pod restarts — harmless.
#
# Usage:
#   ./dump-heap.sh --confirm [-n namespace] [-l selector] [--container name] [pod-name]
#
# Output: ./dumps/heap/<pod>-jdk-heap-<ts>.hprof

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_ROOT="$SCRIPT_DIR"; while [[ "$SCRIPTS_ROOT" != / && ! -f "$SCRIPTS_ROOT/lib/common.sh" ]]; do SCRIPTS_ROOT="$(dirname "$SCRIPTS_ROOT")"; done
# shellcheck source=lib/common.sh
source "$SCRIPTS_ROOT/lib/common.sh"

require_cmd kubectl

CONFIRMED=0
FILTERED_ARGS=()
for a in "$@"; do
    if [[ "$a" == "--confirm" ]]; then CONFIRMED=1; else FILTERED_ARGS+=("$a"); fi
done

# ${arr[@]+...} guard: bash 3.2 (stock macOS) treats "${arr[@]}" on an empty
# array as unbound under `set -u`; fixed only in bash 4.4.
parse_common_args ${FILTERED_ARGS[@]+"${FILTERED_ARGS[@]}"}

if [[ $CONFIRMED -ne 1 ]]; then
    err "heap dumps pause the JVM (destructive in production). Re-run with --confirm."
    exit 64
fi

POD="$(resolve_one_pod "${REMAINING_ARGS[0]:-}")"

OUT_DIR="${OUT_DIR:-./dumps/heap}"
ensure_dir "$OUT_DIR"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
DEBUG_CONTAINER="jmap-$(date +%s)"       # RFC 1123: lowercase alnum + '-' only
REMOTE_PATH="/tmp/heap-jdk-$TS.hprof"    # written by the JVM → app container's /tmp
LOCAL_PATH="$OUT_DIR/${POD}-jdk-heap-$TS.hprof"

# Runs inside the debug container: find the JVM PID, hand-shake the HotSpot
# attach protocol across the container boundary (see dump-threads.sh for the
# full explanation: trigger file via /proc/<pid>/root/tmp needs root, socket
# symlinked into our /tmp, root peer accepted), then run jmap. The dump path
# is opened by the TARGET JVM, so the hprof lands in the app container's /tmp.
REMOTE_CMD='
JPID=""
for p in /proc/[0-9]*/comm; do
    [ "$(cat "$p" 2>/dev/null)" = "java" ] && { JPID="${p#/proc/}"; JPID="${JPID%/comm}"; break; }
done
[ -n "$JPID" ] || { echo "ERROR: no java process visible in the shared PID namespace" >&2; exit 1; }
SOCK="/proc/$JPID/root/tmp/.java_pid$JPID"
if [ ! -S "$SOCK" ]; then
    touch "/proc/$JPID/root/tmp/.attach_pid$JPID" \
        || { echo "ERROR: cannot reach the JVM /tmp via /proc/$JPID/root (need root in the debug container)" >&2; exit 1; }
    kill -QUIT "$JPID"
    n=0; while [ $n -lt 50 ] && [ ! -S "$SOCK" ]; do sleep 0.2; n=$((n+1)); done
fi
[ -S "$SOCK" ] || { echo "ERROR: JVM never opened the attach socket ($SOCK)" >&2; exit 1; }
ln -sf "$SOCK" "/tmp/.java_pid$JPID"
exec jmap -dump:live,format=b,file=REMOTE_PATH_TOKEN "$JPID"
'
REMOTE_CMD="${REMOTE_CMD//REMOTE_PATH_TOKEN/$REMOTE_PATH}"

info "heap dump via ephemeral JDK container (pod=$POD target=$APP_CONTAINER image=$JDK_DEBUG_IMAGE)"
info "this PAUSES the JVM for the duration of the dump"
show_cmd kubectl -n "$NAMESPACE" debug "$POD" --image="$JDK_DEBUG_IMAGE" \
    --target="$APP_CONTAINER" --container="$DEBUG_CONTAINER" --profile=general \
    -q -- sh -c "'<find java pid; trigger attach via /proc/<pid>/root/tmp; jmap -dump:live,file=$REMOTE_PATH>'"
kubectl -n "$NAMESPACE" debug "$POD" \
    --image="$JDK_DEBUG_IMAGE" \
    --target="$APP_CONTAINER" \
    --container="$DEBUG_CONTAINER" \
    --profile=general -q \
    -- sh -c "$REMOTE_CMD" >/dev/null

# Block until jmap finishes by following the ephemeral container's log stream
# (works during and after termination), then check jmap reported success.
JMAP_LOG=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
    if JMAP_LOG="$(kubectl -n "$NAMESPACE" logs "$POD" -c "$DEBUG_CONTAINER" -f 2>/dev/null)"; then
        break
    fi
    sleep 1
done
if ! grep -q "Heap dump file created" <<<"$JMAP_LOG"; then
    err "jmap did not report success. Output was:"
    sed 's/^/    /' <<<"$JMAP_LOG" >&2
    exit 1
fi

info "copying $REMOTE_PATH -> $LOCAL_PATH"
show_cmd kubectl -n "$NAMESPACE" cp "$POD:$REMOTE_PATH" "$LOCAL_PATH" -c "$APP_CONTAINER"
kubectl -n "$NAMESPACE" cp "$POD:$REMOTE_PATH" "$LOCAL_PATH" -c "$APP_CONTAINER"
kubectl -n "$NAMESPACE" exec "$POD" -c "$APP_CONTAINER" -- rm -f "$REMOTE_PATH" || true

# hprof files start with the magic "JAVA PROFILE 1.0.x".
if ! head -c 12 "$LOCAL_PATH" 2>/dev/null | grep -q "JAVA PROFILE"; then
    err "downloaded file is not a valid hprof (bad magic) — leaving it for inspection: $LOCAL_PATH"
    exit 1
fi
info "wrote $LOCAL_PATH ($(du -h "$LOCAL_PATH" | cut -f1 | tr -d ' '))"
