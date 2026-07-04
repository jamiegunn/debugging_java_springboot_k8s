#!/usr/bin/env bash
#
# jdebug.sh — the front door for the JVM debug kit. Cluster-agnostic: works
# against ANY Spring Boot pod on ANY cluster your KUBECONFIG points at (with
# no KUBECONFIG set it auto-targets this repo's k3s kubeconfig if present).
# Every command takes -n <ns> -l <selector> [--container <name>] [pod];
# defaults target this repo's app (debug-demo / debug-demo-app).
#
# Run with NO arguments (or `tui`) for the interactive menu.
#
#   Triage (runbook steps 1–4)
#     status        pod status, restarts, recent events
#     health        actuator health, incl. per-subsystem + liveness/readiness
#     top           kubectl top pods + HPA state
#     logs          stream logs from all replicas         (tail-logs.sh)
#     log-level     runtime logger change: log-level <logger> <LEVEL>
#
#   Capture (three tiers — prefer actuator, then jattach, then jdk)
#     threads       thread dump: --via actuator (default) | jattach | jdk
#     heap          heap dump — PAUSES THE JVM, needs --confirm; same --via
#     jcmd          any jcmd command via jattach: jcmd "GC.heap_info"
#
#   Memory / bundle (runbook steps 5–6)
#     memory        RSS vs JVM anatomy, reconciled        (memory-report.sh)
#     snapshot      one-shot offline-analysis bundle      (snapshot.sh)
#
#   Setup
#     install-jattach   pre-stage jattach into the pod before an incident
#
# Examples:
#   scripts/jdebug.sh threads                        # actuator, this repo's app
#   scripts/jdebug.sh heap --confirm --via jattach
#   scripts/jdebug.sh snapshot -n prod -l app=payments
#   scripts/jdebug.sh jcmd "VM.native_memory summary"

set -uo pipefail
D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$D/lib/common.sh"

usage_top() { sed -n '2,/^set /p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

cmd="${1:-}"; shift 2>/dev/null || true

# Extract --via <tier> (threads/heap); pass everything else through.
VIA="actuator"
ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --via) VIA="$2"; shift 2 ;;
        *)     ARGS+=("$1"); shift ;;
    esac
done
# bash 3.2 (stock macOS) empty-array guard
fwd() { "$@" ${ARGS[@]+"${ARGS[@]}"}; }

triage_parse() { parse_common_args ${ARGS[@]+"${ARGS[@]}"}; }

case "$cmd" in
    tui|menu|"")     exec "$D/jdebug/ui/tui.sh" ;;

    status)
        triage_parse
        show_cmd kubectl -n "$NAMESPACE" get pods -l "$SELECTOR" -o wide
        kubectl -n "$NAMESPACE" get pods -l "$SELECTOR" -o wide
        echo
        show_cmd kubectl -n "$NAMESPACE" get events --sort-by=.lastTimestamp "| tail -15"
        kubectl -n "$NAMESPACE" get events --sort-by=.lastTimestamp 2>/dev/null | tail -15
        ;;

    health)
        triage_parse
        POD="$(resolve_one_pod "${REMAINING_ARGS[0]:-}")"
        show_cmd kubectl -n "$NAMESPACE" exec "$POD" -c "$APP_CONTAINER" -- curl -s http://localhost:8080/actuator/health
        if command -v python3 >/dev/null 2>&1; then
            kubectl -n "$NAMESPACE" exec "$POD" -c "$APP_CONTAINER" -- curl -s http://localhost:8080/actuator/health | python3 -m json.tool
        else
            kubectl -n "$NAMESPACE" exec "$POD" -c "$APP_CONTAINER" -- curl -s http://localhost:8080/actuator/health; echo
        fi
        for probe in liveness readiness; do
            printf '%-10s: ' "$probe"
            kubectl -n "$NAMESPACE" exec "$POD" -c "$APP_CONTAINER" -- curl -s "http://localhost:8080/actuator/health/$probe"; echo
        done
        ;;

    top)
        triage_parse
        show_cmd kubectl -n "$NAMESPACE" top pods
        kubectl -n "$NAMESPACE" top pods 2>/dev/null || echo "  (metrics-server not answering)"
        echo
        show_cmd kubectl -n "$NAMESPACE" get hpa
        kubectl -n "$NAMESPACE" get hpa 2>/dev/null || echo "  (no HPA in $NAMESPACE)"
        ;;

    threads)
        case "$VIA" in
            actuator) fwd "$D/jdebug/capture/actuator.sh" threads ;;
            jattach)  fwd "$D/jdebug/capture/jattach.sh"  threads ;;
            jdk)      fwd "$D/jdebug/capture/jdk-threads.sh" ;;
            *) err "unknown --via '$VIA' (actuator|jattach|jdk)"; exit 64 ;;
        esac ;;

    heap)
        case "$VIA" in
            actuator) fwd "$D/jdebug/capture/actuator.sh" heap ;;
            jattach)  fwd "$D/jdebug/capture/jattach.sh"  heap ;;
            jdk)      fwd "$D/jdebug/capture/jdk-heap.sh" ;;
            *) err "unknown --via '$VIA' (actuator|jattach|jdk)"; exit 64 ;;
        esac ;;

    jcmd)            fwd "$D/jdebug/capture/jattach.sh" jcmd ;;
    memory)          fwd "$D/jdebug/observe/memory-report.sh" ;;
    snapshot)        fwd "$D/jdebug/observe/snapshot.sh" ;;
    logs)            fwd "$D/jdebug/observe/tail-logs.sh" ;;
    log-level)       fwd "$D/jdebug/observe/set-log-level.sh" ;;
    install-jattach) fwd "$D/jdebug/capture/jattach.sh" install ;;

    -h|--help)       usage_top ;;
    *) echo "unknown command: $cmd"; echo; usage_top; exit 64 ;;
esac
