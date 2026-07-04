#!/usr/bin/env bash
#
# actuator.sh — thread + heap dumps via Spring Boot Actuator.
#
# PREFERRED capture path (tier 1): JRE-only, nothing installed into the pod,
# works whenever the app can still serve HTTP. When it can't, fall back to
# scripts/jdebug/capture/jattach.sh (tier 2) or scripts/jdebug/capture/jdk-threads.sh /
# scripts/jdebug/capture/jdk-heap.sh (tier 3, ephemeral JDK container).
#
# Usage:
#   ./dump-actuator.sh threads [--json] [-n ns] [-l selector] [--container name] [pod]
#   ./dump-actuator.sh heap --confirm [-n ns] [-l selector] [--container name] [pod]
#
# threads  text/plain by default (jstack-style — drop into fastthread.io /
#          VisualVM unchanged); --json for Spring's structured format.
# heap     downloads an hprof from /actuator/heapdump. DESTRUCTIVE IN
#          PRODUCTION: the JVM freezes for the duration of the dump
#          (seconds on small heaps, minutes on multi-GB). Requires --confirm.
#
# The actuator base URL inside the pod defaults to
# http://localhost:8080/actuator — override with $ACTUATOR_BASE.
#
# Output: ./dumps/threads/<pod>-actuator-thread-<ts>.{txt,json}
#         ./dumps/heap/<pod>-actuator-heap-<ts>.hprof

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_ROOT="$SCRIPT_DIR"; while [[ "$SCRIPTS_ROOT" != / && ! -f "$SCRIPTS_ROOT/lib/common.sh" ]]; do SCRIPTS_ROOT="$(dirname "$SCRIPTS_ROOT")"; done
# shellcheck source=lib/common.sh
source "$SCRIPTS_ROOT/lib/common.sh"

require_cmd kubectl

: "${ACTUATOR_BASE:=http://localhost:8080/actuator}"

ACTION=""
CONFIRMED=0
AS_JSON=0
FILTERED_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        threads|heap) ACTION="$1"; shift ;;
        --confirm)    CONFIRMED=1; shift ;;
        --json)       AS_JSON=1; shift ;;
        -h|--help)    usage; exit 0 ;;
        --) shift; FILTERED_ARGS+=("$@"); break ;;
        *)  FILTERED_ARGS+=("$1"); shift ;;
    esac
done

# ${arr[@]+...} guard: bash 3.2 (stock macOS) treats "${arr[@]}" on an empty
# array as unbound under `set -u`; fixed only in bash 4.4.
parse_common_args ${FILTERED_ARGS[@]+"${FILTERED_ARGS[@]}"}

if [[ -z "$ACTION" ]]; then
    err "usage: dump-actuator.sh {threads [--json] | heap --confirm} [-n ns] [-l selector] [pod]"
    exit 64
fi
if [[ "$ACTION" == "heap" && $CONFIRMED -ne 1 ]]; then
    err "heap dumps pause the JVM (destructive in production). Re-run with --confirm."
    exit 64
fi

POD="$(resolve_one_pod "${REMAINING_ARGS[0]:-}")"
TS="$(date -u +%Y%m%dT%H%M%SZ)"

case "$ACTION" in
    threads)
        OUT_DIR="${OUT_DIR:-./dumps/threads}"
        ensure_dir "$OUT_DIR"
        if [[ $AS_JSON -eq 1 ]]; then
            LOCAL_PATH="$OUT_DIR/${POD}-actuator-thread-$TS.json"
            ACCEPT="application/json"
        else
            LOCAL_PATH="$OUT_DIR/${POD}-actuator-thread-$TS.txt"
            ACCEPT="text/plain"
        fi
        info "thread dump via actuator (pod=$POD)"
        show_cmd kubectl -n "$NAMESPACE" exec "$POD" -c "$APP_CONTAINER" -- \
            curl -fsS -H "Accept: $ACCEPT" "$ACTUATOR_BASE/threaddump" "> $LOCAL_PATH"
        if ! kubectl -n "$NAMESPACE" exec "$POD" -c "$APP_CONTAINER" -- \
                curl -fsS -H "Accept: $ACCEPT" "$ACTUATOR_BASE/threaddump" > "$LOCAL_PATH"; then
            err "actuator threaddump failed — is the app serving HTTP? Fall back to:"
            err "  scripts/jdebug/capture/jattach.sh threads -n $NAMESPACE $POD"
            rm -f "$LOCAL_PATH"
            exit 1
        fi
        if [[ $AS_JSON -eq 1 ]]; then MARKER='"threads"'; else MARKER="Full thread dump"; fi
        if ! grep -q "$MARKER" "$LOCAL_PATH" 2>/dev/null; then
            err "capture looks wrong (no '$MARKER' marker) — leaving it for inspection: $LOCAL_PATH"
            exit 1
        fi
        info "wrote $LOCAL_PATH ($(wc -l <"$LOCAL_PATH" | tr -d ' ') lines)"
        ;;
    heap)
        OUT_DIR="${OUT_DIR:-./dumps/heap}"
        ensure_dir "$OUT_DIR"
        LOCAL_PATH="$OUT_DIR/${POD}-actuator-heap-$TS.hprof"
        info "heap dump via actuator (pod=$POD) — this PAUSES the JVM"
        show_cmd kubectl -n "$NAMESPACE" exec "$POD" -c "$APP_CONTAINER" -- \
            curl -fsS -o - "$ACTUATOR_BASE/heapdump" "> $LOCAL_PATH"
        if ! kubectl -n "$NAMESPACE" exec "$POD" -c "$APP_CONTAINER" -- \
                curl -fsS -o - "$ACTUATOR_BASE/heapdump" > "$LOCAL_PATH"; then
            err "actuator heapdump failed. Fall back to:"
            err "  scripts/jdebug/capture/jattach.sh heap --confirm -n $NAMESPACE $POD"
            rm -f "$LOCAL_PATH"
            exit 1
        fi
        # hprof files start with the magic "JAVA PROFILE 1.0.x".
        if ! head -c 12 "$LOCAL_PATH" 2>/dev/null | grep -q "JAVA PROFILE"; then
            err "downloaded file is not a valid hprof (bad magic) — leaving it for inspection: $LOCAL_PATH"
            exit 1
        fi
        info "wrote $LOCAL_PATH ($(du -h "$LOCAL_PATH" | cut -f1 | tr -d ' '))"
        info "analyze: Eclipse MAT (Leak Suspects) or VisualVM — both run on a JRE"
        ;;
esac
