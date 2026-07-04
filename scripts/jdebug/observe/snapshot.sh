#!/usr/bin/env bash
#
# snapshot.sh — one-shot diagnostic bundle for offline analysis.
#
# Automates the "Step 6" snapshot from the CLAUDE.md runbook: everything an
# offline analysis (Eclipse MAT, VisualVM, fastthread.io) or a colleague
# needs, captured in one command while the incident is live.
#
# Collects into ./dumps/snapshot-<ts>/ :
#   pod.txt              kubectl describe pod (recent events at the bottom)
#   health.json          /actuator/health
#   metrics.json         /actuator/metrics index
#   threads.txt          /actuator/threaddump (text/plain, jstack-style)
#   memory-report.txt    scripts/jdebug/observe/memory-report.sh (RSS vs JVM anatomy)
#   gc-heap-info.txt     jattach jcmd GC.heap_info
#   vm-flags.txt         jattach jcmd VM.flags
#   codecache.txt        jattach jcmd Compiler.codecache
#   classloaders.txt     jattach jcmd VM.classloader_stats
#   nmt-summary.txt      jattach jcmd VM.native_memory summary (best effort —
#                        needs -XX:NativeMemoryTracking=summary in JAVA_OPTS)
#   heap.hprof           ONLY with --heap --confirm (PAUSES the JVM)
#
# Read-only except that the jattach sections install a ~80 KB static binary
# into the pod's /tmp (gone on restart) — skip them with --no-jattach.
# Sections are best-effort: a failed capture is noted, the rest continues.
#
# Usage:
#   ./snapshot.sh [-n ns] [-l selector] [--container name] [pod]
#   ./snapshot.sh --heap --confirm     # also grab an hprof (pauses the JVM)
#   ./snapshot.sh --no-jattach         # actuator-only capture

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_ROOT="$SCRIPT_DIR"; while [[ "$SCRIPTS_ROOT" != / && ! -f "$SCRIPTS_ROOT/lib/common.sh" ]]; do SCRIPTS_ROOT="$(dirname "$SCRIPTS_ROOT")"; done
# shellcheck source=lib/common.sh
source "$SCRIPTS_ROOT/lib/common.sh"

require_cmd kubectl

: "${ACTUATOR_BASE:=http://localhost:8080/actuator}"

WANT_HEAP=0
CONFIRMED=0
NO_JATTACH=0
FILTERED_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --heap)       WANT_HEAP=1; shift ;;
        --confirm)    CONFIRMED=1; shift ;;
        --no-jattach) NO_JATTACH=1; shift ;;
        -h|--help)    usage; exit 0 ;;
        --) shift; FILTERED_ARGS+=("$@"); break ;;
        *)  FILTERED_ARGS+=("$1"); shift ;;
    esac
done

# bash 3.2 (stock macOS) empty-array guard
parse_common_args ${FILTERED_ARGS[@]+"${FILTERED_ARGS[@]}"}

if [[ $WANT_HEAP -eq 1 && $CONFIRMED -ne 1 ]]; then
    err "--heap pauses the JVM (destructive in production). Add --confirm."
    exit 64
fi

POD="$(resolve_one_pod "${REMAINING_ARGS[0]:-}")"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
SNAP="${OUT_DIR:-./dumps}/snapshot-$TS"
ensure_dir "$SNAP"

PASS=0; FAIL=0
step() {  # step <outfile> <description> <cmd...>
    local out="$1" what="$2"; shift 2
    if "$@" > "$SNAP/$out" 2>"$SNAP/.err"; then
        PASS=$((PASS+1)); info "  ✔ $out  ($what)"
    else
        FAIL=$((FAIL+1))
        { echo "CAPTURE FAILED: $what"; echo "--- stderr ---"; cat "$SNAP/.err"; } > "$SNAP/$out"
        info "  ✘ $out  ($what) — failed, details inside"
    fi
}

aexec() { kubectl -n "$NAMESPACE" exec "$POD" -c "$APP_CONTAINER" -- "$@"; }

info "snapshot of pod $POD → $SNAP"

step pod.txt           "kubectl describe pod"        kubectl -n "$NAMESPACE" describe pod "$POD"
# no -f: a DOWN health is HTTP 503 *with* the diagnostic body — that body is
# exactly what an incident snapshot needs, not a curl error.
step health.json       "actuator health"             aexec curl -sS "$ACTUATOR_BASE/health"
step metrics.json      "actuator metrics index"      aexec curl -fsS "$ACTUATOR_BASE/metrics"
step threads.txt       "actuator threaddump (text)"  aexec curl -fsS -H 'Accept: text/plain' "$ACTUATOR_BASE/threaddump"
step memory-report.txt "memory anatomy"              "$SCRIPTS_ROOT/jdebug/observe/memory-report.sh" -n "$NAMESPACE" -l "$SELECTOR" --container "$APP_CONTAINER" "$POD"

if [[ $NO_JATTACH -ne 1 ]]; then
    jat() { "$SCRIPTS_ROOT/jdebug/capture/jattach.sh" jcmd "$1" -n "$NAMESPACE" -l "$SELECTOR" --container "$APP_CONTAINER" "$POD"; }
    step gc-heap-info.txt  "jcmd GC.heap_info"           jat "GC.heap_info"
    step vm-flags.txt      "jcmd VM.flags"               jat "VM.flags"
    step codecache.txt     "jcmd Compiler.codecache"     jat "Compiler.codecache"
    step classloaders.txt  "jcmd VM.classloader_stats"   jat "VM.classloader_stats"
    step nmt-summary.txt   "jcmd VM.native_memory (needs NMT enabled)" jat "VM.native_memory summary"
else
    info "  - skipping jattach sections (--no-jattach)"
fi

if [[ $WANT_HEAP -eq 1 ]]; then
    info "  capturing heap dump via actuator (PAUSES the JVM)..."
    if aexec curl -fsS -o - "$ACTUATOR_BASE/heapdump" > "$SNAP/heap.hprof" \
       && head -c 12 "$SNAP/heap.hprof" | grep -q "JAVA PROFILE"; then
        PASS=$((PASS+1)); info "  ✔ heap.hprof ($(du -h "$SNAP/heap.hprof" | cut -f1 | tr -d ' '))"
    else
        FAIL=$((FAIL+1)); rm -f "$SNAP/heap.hprof"
        info "  ✘ heap.hprof — actuator heapdump failed (try scripts/jdebug/capture/jattach.sh heap --confirm)"
    fi
fi

rm -f "$SNAP/.err"
echo
info "snapshot complete: $SNAP  ($PASS captured, $FAIL failed)"
info "next steps:"
info "  threads.txt      → fastthread.io or VisualVM (no PII in prod dumps!)"
info "  heap.hprof       → Eclipse MAT: ParseHeapDump.sh heap.hprof org.eclipse.mat.api:suspects"
info "  memory-report.txt→ compare against an earlier snapshot to spot growth"
[[ $FAIL -eq 0 ]] || exit 1
