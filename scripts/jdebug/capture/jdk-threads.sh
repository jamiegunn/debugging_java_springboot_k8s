#!/usr/bin/env bash
#
# dump-threads.sh — jstack thread dump via an ephemeral JDK container.
#
# LAST-RESORT capture path (tier 3). Prefer, in order:
#   1. scripts/jdebug/capture/actuator.sh threads   (actuator, JRE-only, no install)
#   2. scripts/jdebug/capture/jattach.sh threads    (jcmd surface via a tiny binary)
#   3. this script — when you need the real jstack (e.g. `jstack -F` on a
#      wedged JVM) and cluster policy allows ephemeral containers.
#
# The app image is JRE-only, so this attaches a JDK image (default
# eclipse-temurin:21-jdk-alpine, override $JDK_DEBUG_IMAGE) with
# `kubectl debug --target=<app>`. The pod runs shareProcessNamespace=true,
# which makes PID 1 the /pause sandbox — NOT the JVM — so the command run in
# the debug container discovers the java PID from /proc first. HotSpot attach
# also requires uid parity with the target JVM (ours runs as uid 1000), so a
# matching user is created in the debug container and jstack runs as it.
#
# Air-gap note: the JDK image must be pre-imported into containerd (it is in
# K3S_IMAGES). The terminated ephemeral container stays visible in the pod
# spec until the pod restarts — harmless.
#
# Usage:
#   ./dump-threads.sh [-n namespace] [-l selector] [--container name] [pod-name]
#
# Output: ./dumps/threads/<pod>-jdk-thread-<ts>.txt

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_ROOT="$SCRIPT_DIR"; while [[ "$SCRIPTS_ROOT" != / && ! -f "$SCRIPTS_ROOT/lib/common.sh" ]]; do SCRIPTS_ROOT="$(dirname "$SCRIPTS_ROOT")"; done
# shellcheck source=lib/common.sh
source "$SCRIPTS_ROOT/lib/common.sh"

require_cmd kubectl

parse_common_args "$@"
POD="$(resolve_one_pod "${REMAINING_ARGS[0]:-}")"

OUT_DIR="${OUT_DIR:-./dumps/threads}"
ensure_dir "$OUT_DIR"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
DEBUG_CONTAINER="jstack-$(date +%s)"     # RFC 1123: lowercase alnum + '-' only
LOCAL_PATH="$OUT_DIR/${POD}-jdk-thread-$TS.txt"

# Runs inside the debug container: find the JVM PID (PID 1 is /pause under
# shareProcessNamespace), hand-shake the HotSpot attach protocol across the
# container boundary, then jstack to stdout. The debug container shares the
# pod's PID namespace but NOT the app container's mount namespace, so:
#   1. the .attach_pid trigger file must land in the JVM's OWN /tmp — reached
#      via /proc/<pid>/root/tmp, which needs root (kernel ptrace fs-access
#      check); HotSpot accepts root-owned trigger files,
#   2. the JVM then creates its socket in ITS /tmp; a symlink into the debug
#      container's /tmp puts it where jstack looks,
#   3. the attach listener accepts a root peer (JDK 10+), so no uid juggling.
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
exec jstack -l "$JPID"
'

info "thread dump via ephemeral JDK container (pod=$POD target=$APP_CONTAINER image=$JDK_DEBUG_IMAGE)"
show_cmd kubectl -n "$NAMESPACE" debug "$POD" --image="$JDK_DEBUG_IMAGE" \
    --target="$APP_CONTAINER" --container="$DEBUG_CONTAINER" --profile=general \
    -q -- sh -c "'<find java pid; trigger attach via /proc/<pid>/root/tmp; jstack -l>'"
kubectl -n "$NAMESPACE" debug "$POD" \
    --image="$JDK_DEBUG_IMAGE" \
    --target="$APP_CONTAINER" \
    --container="$DEBUG_CONTAINER" \
    --profile=general -q \
    -- sh -c "$REMOTE_CMD" >/dev/null

# Capture via the log stream: `logs -f` works while the ephemeral container
# runs AND after it terminates (no attach race, no exec-into-exited-container).
# Retry briefly while the container is still being created.
captured=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
    if kubectl -n "$NAMESPACE" logs "$POD" -c "$DEBUG_CONTAINER" -f > "$LOCAL_PATH" 2>/dev/null; then
        captured=1; break
    fi
    sleep 1
done

if [[ $captured -ne 1 ]] || ! grep -q "Full thread dump" "$LOCAL_PATH" 2>/dev/null; then
    err "capture failed — no 'Full thread dump' marker in the output:"
    sed 's/^/    /' "$LOCAL_PATH" >&2 2>/dev/null || true
    rm -f "$LOCAL_PATH"
    exit 1
fi
info "wrote $LOCAL_PATH ($(wc -l <"$LOCAL_PATH" | tr -d ' ') lines)"
