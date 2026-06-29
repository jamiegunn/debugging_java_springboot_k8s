#!/usr/bin/env bash
#
# dump-threads.sh — grab a jstack thread dump from a running debug-demo-app pod
# using an ephemeral JDK container, then copy it locally.
#
# Usage:
#   ./dump-threads.sh [-n namespace] [-l selector] [--container name] [pod-name]
#
# The app image is JRE-only, so this attaches an ephemeral container with the
# matching JDK (eclipse-temurin:25-jdk-alpine) via `kubectl debug`. Because the
# app Deployment sets shareProcessNamespace=true, jstack targets PID 1.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_cmd kubectl

parse_common_args "$@"
POD="$(resolve_one_pod "${REMAINING_ARGS[0]:-}")"

OUT_DIR="${OUT_DIR:-./dumps/threads}"
ensure_dir "$OUT_DIR"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
DEBUG_CONTAINER="thread-dump-$TS"
REMOTE_PATH="/tmp/thread-$TS.txt"
LOCAL_PATH="$OUT_DIR/${POD}-thread-$TS.txt"

info "dumping threads from pod=$POD container=$APP_CONTAINER (ephemeral=$DEBUG_CONTAINER)"

kubectl -n "$NAMESPACE" debug "$POD" \
    --image="$JDK_DEBUG_IMAGE" \
    --target="$APP_CONTAINER" \
    --container="$DEBUG_CONTAINER" \
    --profile=general \
    -- sh -c "jstack 1 > $REMOTE_PATH && echo done" >/dev/null

# kubectl debug returns immediately on completion, but we need to copy the file
# out via the debug container's filesystem (shared with the target via PID/IPC).
# Use exec on the ephemeral container to cat the file.
info "copying $REMOTE_PATH -> $LOCAL_PATH"
kubectl -n "$NAMESPACE" exec "$POD" -c "$DEBUG_CONTAINER" -- cat "$REMOTE_PATH" > "$LOCAL_PATH"

info "wrote $LOCAL_PATH ($(wc -l <"$LOCAL_PATH") lines)"
