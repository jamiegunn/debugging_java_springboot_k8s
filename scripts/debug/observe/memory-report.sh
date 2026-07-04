#!/usr/bin/env bash
#
# memory-report.sh — full pod memory anatomy in one shot.
#
# Reconciles container RSS (what k8s OOM-kills on) against everything the
# JVM consumes: heap, non-heap pools, direct buffers, thread stacks. The
# remainder is JVM internal overhead + native libs + glibc/musl waste.
#
# All reads go through Spring Boot Actuator — no JDK tools, no jattach.
#
# Usage:
#   ./memory-report.sh [-n namespace] [-l selector] [--container name] [pod-name]

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_ROOT="$SCRIPT_DIR"; while [[ "$SCRIPTS_ROOT" != / && ! -f "$SCRIPTS_ROOT/lib/common.sh" ]]; do SCRIPTS_ROOT="$(dirname "$SCRIPTS_ROOT")"; done
# shellcheck source=lib/common.sh
source "$SCRIPTS_ROOT/lib/common.sh"

require_cmd kubectl python3

parse_common_args "$@"
POD="$(resolve_one_pod "${REMAINING_ARGS[0]:-}")"

EXEC=(kubectl -n "$NAMESPACE" exec "$POD" -c "$APP_CONTAINER" --)

# Container RSS + limit (cgroup v2 path with v1 fallback)
read_cgroup() {
    "${EXEC[@]}" sh -c '
        if [ -f /sys/fs/cgroup/memory.current ]; then
            printf "rss %s\nlimit %s\n" "$(cat /sys/fs/cgroup/memory.current)" "$(cat /sys/fs/cgroup/memory.max)"
        elif [ -f /sys/fs/cgroup/memory/memory.usage_in_bytes ]; then
            printf "rss %s\nlimit %s\n" \
                "$(cat /sys/fs/cgroup/memory/memory.usage_in_bytes)" \
                "$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes)"
        fi
    '
}

# Fetch raw JSON from actuator (in the pod) and parse on the host.
# Encoded the tag here so spaces / single-quotes in pool IDs survive.
actuator_json() {
    local path="$1"
    "${EXEC[@]}" curl -fsS "http://localhost:8080/actuator/$path" 2>/dev/null
}

url_encode() {
    python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1], safe=':'))" "$1"
}

# Pull one actuator metric measurement value (bytes) for an exact tag pair.
metric_value() {
    local metric="$1" tag="$2"
    local path="metrics/${metric}"
    if [[ -n "$tag" ]]; then path="${path}?tag=$(url_encode "$tag")"; fi
    actuator_json "$path" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print(int(d['measurements'][0]['value']))
except Exception:
    print(0)
"
}

# List available tag values for a (metric, tag-name) pair.
metric_tag_values() {
    local metric="$1" tag_name="$2"
    actuator_json "metrics/${metric}" | python3 -c "
import json, sys
d = json.load(sys.stdin)
for t in d.get('availableTags', []):
    if t.get('tag') == '$tag_name':
        for v in t.get('values', []):
            print(v)
        break
"
}

mib() { python3 -c "print(round($1/1048576, 1))"; }

info "reading pod $POD ..."

# Fail LOUDLY if actuator isn't answering — a report full of silent zeros is
# worse than no report during an incident.
if ! actuator_json metrics | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null; then
    err "actuator not reachable at http://localhost:8080/actuator/metrics in pod $POD"
    err "check: kubectl -n $NAMESPACE exec $POD -c $APP_CONTAINER -- curl -s http://localhost:8080/actuator/health"
    exit 3
fi

CG="$(read_cgroup)"
RSS_B=$(echo "$CG" | awk '/^rss/ {print $2}')
LIM_B=$(echo "$CG" | awk '/^limit/ {print $2}')
HEAP_USED=$(metric_value jvm.memory.used 'area:heap')
HEAP_COMMIT=$(metric_value jvm.memory.committed 'area:heap')
HEAP_MAX=$(metric_value jvm.memory.max 'area:heap')
NONHEAP_USED=$(metric_value jvm.memory.used 'area:nonheap')
DIRECT=$(metric_value jvm.buffer.memory.used 'id:direct')
MAPPED=$(metric_value jvm.buffer.memory.used 'id:mapped')
THREADS=$(metric_value jvm.threads.live '')

# A JVM with 0 bytes of heap doesn't exist — this means the metrics scrape
# failed mid-report. Refuse to print a misleading table.
if [[ "$HEAP_USED" -eq 0 ]]; then
    err "jvm.memory.used{area:heap} came back 0 — metrics scrape failed, aborting"
    exit 3
fi

# Per-pool non-heap breakdown — iterate whatever the JVM actually exposes
POOL_IDS="$(metric_tag_values jvm.memory.used id)"

echo
echo "== Pod $POD ===================================================="
printf "  Container RSS         : %8s MiB  (cgroup memory.current)\n" "$(mib "$RSS_B")"
# cgroup v2 reports the literal string "max" when no memory limit is set.
if [[ "$LIM_B" == "max" || -z "$LIM_B" ]]; then
    printf "  Container limit       : %8s      (no limit set — node OOM killer applies)\n" "none"
else
    printf "  Container limit       : %8s MiB  (cgroup memory.max — what k8s OOM-kills on)\n" "$(mib "$LIM_B")"
fi
echo
echo "  JVM heap"
printf "    used                : %8s MiB\n" "$(mib "$HEAP_USED")"
printf "    committed           : %8s MiB\n" "$(mib "$HEAP_COMMIT")"
printf "    max                 : %8s MiB\n" "$(mib "$HEAP_MAX")"
echo
# Pool classifier — heap pools have known suffixes across GCs.
is_heap_pool() {
    case "$1" in
        *Eden*|*Survivor*|*Tenured*|*Old*Gen*|"G1 "*|"ZHeap"*|"Shenandoah"*) return 0 ;;
        *) return 1 ;;
    esac
}

echo "  Heap pools (sum should match area:heap = $(mib "$HEAP_USED") MiB)"
while IFS= read -r pool; do
    [ -z "$pool" ] && continue
    if is_heap_pool "$pool"; then
        V=$(metric_value jvm.memory.used "id:$pool")
        printf "    %-32s: %8s MiB\n" "$pool" "$(mib "$V")"
    fi
done <<< "$POOL_IDS"
echo
echo "  Non-heap pools (sum should match area:nonheap = $(mib "$NONHEAP_USED") MiB)"
while IFS= read -r pool; do
    [ -z "$pool" ] && continue
    if ! is_heap_pool "$pool"; then
        V=$(metric_value jvm.memory.used "id:$pool")
        printf "    %-32s: %8s MiB\n" "$pool" "$(mib "$V")"
    fi
done <<< "$POOL_IDS"
echo
echo "  JVM off-heap"
printf "    direct buffers      : %8s MiB  (NIO/Netty/Lettuce)\n" "$(mib "$DIRECT")"
printf "    mapped buffers      : %8s MiB\n" "$(mib "$MAPPED")"
STACKS=$((THREADS * 1024 * 1024))
printf "    thread stacks       : %8s MiB  (%s threads × ~1 MiB)\n" "$(mib "$STACKS")" "$THREADS"

ACCOUNTED=$((HEAP_USED + NONHEAP_USED + DIRECT + MAPPED + STACKS))
UNACCOUNTED=$((RSS_B - ACCOUNTED))
echo
printf "  Accounted             : %8s MiB  (heap + nonheap pools + direct + mapped + stacks)\n" "$(mib "$ACCOUNTED")"
printf "  Unaccounted           : %8s MiB  (JVM internal overhead + native libs + allocator waste)\n" "$(mib "$UNACCOUNTED")"
if [[ "$LIM_B" != "max" && -n "$LIM_B" ]]; then
    printf "  RSS / limit           : %s%%\n" "$(python3 -c "print(round($RSS_B*100/$LIM_B, 1))")"
fi
echo "================================================================="
echo
echo "Hints:"
echo "  - If 'Unaccounted' is large AND growing → likely native leak (JNI, direct buffer)"
echo "    Enable NMT in JAVA_OPTS (-XX:NativeMemoryTracking=summary) then run:"
echo "    scripts/debug/capture/jattach.sh jcmd 'VM.native_memory summary' -n $NAMESPACE"
echo "  - If 'Metaspace' is large AND growing → classloader leak (Spring devtools, hot reloads)"
echo "  - If 'direct buffers' is large → check Lettuce / Tomcat NIO config"
echo "  - If RSS / limit > 90% under steady load → bump limits or reduce -Xmx"
