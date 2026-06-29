#!/usr/bin/env bash
#
# dump-heap.sh — capture a heap dump from a running debug-demo-app pod.
#
# WARNING: jmap -dump pauses the JVM for the duration of the dump. On a multi-GB
# heap this can be seconds to minutes. Requires explicit --confirm.
#
# Usage:
#   ./dump-heap.sh --confirm [-n namespace] [-l selector] [--container name] [pod-name]

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_cmd kubectl

CONFIRMED=0
FILTERED_ARGS=()
for a in "$@"; do
    if [[ "$a" == "--confirm" ]]; then CONFIRMED=1; else FILTERED_ARGS+=("$a"); fi
done

if [[ $CONFIRMED -ne 1 ]]; then
    err "heap dumps freeze the JVM. Re-run with --confirm to proceed."
    exit 64
fi

parse_common_args "${FILTERED_ARGS[@]}"
POD="$(resolve_one_pod "${REMAINING_ARGS[0]:-}")"

OUT_DIR="${OUT_DIR:-./dumps/heap}"
ensure_dir "$OUT_DIR"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
DEBUG_CONTAINER="heap-dump-$TS"
REMOTE_PATH="/tmp/heap-$TS.hprof"
LOCAL_PATH="$OUT_DIR/${POD}-heap-$TS.hprof"

info "dumping heap from pod=$POD container=$APP_CONTAINER (ephemeral=$DEBUG_CONTAINER)"
info "this will pause the JVM briefly"

kubectl -n "$NAMESPACE" debug "$POD" \
    --image="$JDK_DEBUG_IMAGE" \
    --target="$APP_CONTAINER" \
    --container="$DEBUG_CONTAINER" \
    --profile=general \
    -- sh -c "jmap -dump:live,format=b,file=$REMOTE_PATH 1 && ls -l $REMOTE_PATH" >/dev/null

info "copying $REMOTE_PATH -> $LOCAL_PATH"
kubectl -n "$NAMESPACE" exec "$POD" -c "$DEBUG_CONTAINER" -- cat "$REMOTE_PATH" > "$LOCAL_PATH"

info "wrote $LOCAL_PATH ($(du -h "$LOCAL_PATH" | cut -f1))"
