#!/usr/bin/env bash
#
# chaos.sh — light chaos engineering for the debug-demo stack. Degrade one
# dependency at a time, then probe the API and watch which capabilities
# survive, which degrade, and which fail — the whole point of a stack with
# four independent backends.
#
# Scenarios:
#   valkey-failover   freeze one Valkey primary for 20s (DEBUG SLEEP) — real
#                     failure detection + replica election; API keeps working.
#                     SELF-HEALING (~40s), then fails back to canonical roles.
#   valkey-down       scale the whole Valkey cluster to 0. Cache reads fail,
#                     order fan-out fails, health goes DOWN(redis).
#   oracle-down       scale Oracle to 0. CRUD dies, Valkey-only endpoints live.
#   mq-down           scale IBM MQ to 0. Order creation dies at the publish,
#                     customer CRUD unaffected.
#   app-kill          delete the app pod. k8s restarts it; readiness gates
#                     traffic — watch the brief 503 window through ingress.
#   haproxy-stop      stop the F5 stand-in VM. External path dies; in-cluster
#                     traffic (and Valkey gossip, via the dev VIP shim) lives.
#
#   probe             just run the observation suite against the current state
#   status            what is currently broken?
#   heal              restore EVERYTHING to healthy
#
# Usage:
#   ./chaos.sh                 # interactive menu
#   ./chaos.sh oracle-down     # break it, probe, leave it broken (heal later)
#   ./chaos.sh oracle-down --heal-after   # break, probe, restore
#   ./chaos.sh heal

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
set +e   # chaos EXPECTS failures; report them, don't die on them

require_cmd kubectl curl python3

VK_PASS="$(kubectl -n valkey get secret valkey -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null)"
if [[ -f "$REPO_ROOT/dumps/haproxy-vm-ip" ]]; then
    ENTRY_IP="$(cat "$REPO_ROOT/dumps/haproxy-vm-ip")"
else
    ENTRY_IP="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="ExternalIP")].address}' 2>/dev/null)"
fi
HOST="debug-demo.local"
CURL=(curl -fsS -m 6 --resolve "${HOST}:80:${ENTRY_IP}")

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✔ %s\033[0m\n' "$*"; }
bad()  { printf '  \033[31m✘ %s\033[0m\n' "$*"; }
note() { printf '  \033[33m● %s\033[0m\n' "$*"; }

# ---------------------------------------------------------------------------
# The observation suite. In chaos, a red ✘ is not a bug — it's the blast
# radius. The interesting part is which rows stay green.
# ---------------------------------------------------------------------------
probe() {
    echo
    bold "── Observations ─────────────────────────────────────────────"
    local ts cid

    if "${CURL[@]}" "http://${HOST}/actuator/health/liveness" 2>/dev/null | grep -q UP; then
        ok "app liveness (pod is running and reachable through ingress)"
    else
        bad "app liveness — pod down or external path broken"
    fi

    local overall
    overall="$("${CURL[@]}" "http://${HOST}/actuator/health" 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin)["status"])' 2>/dev/null)"
    case "$overall" in
        UP)   ok  "aggregate health: UP" ;;
        "")   bad "aggregate health: unreachable" ;;
        *)    note "aggregate health: ${overall} (a subsystem is down — expected mid-chaos)" ;;
    esac
    # Behavior probes. Each exercises one dependency (or a known set), so the
    # pattern of green/red identifies the broken subsystem without needing
    # per-component actuator paths (this app hides them without auth).
    local R_READ=0 R_WRITE=0 R_ORDERS=0 R_VALKEY=0

    if "${CURL[@]}" "http://${HOST}/api/customers" >/dev/null 2>&1; then
        ok "GET /api/customers (needs: Oracle)"; R_READ=1
    else
        bad "GET /api/customers — needs Oracle"
    fi

    ts="$(date +%s)-$$"
    cid="$("${CURL[@]}" -X POST "http://${HOST}/api/customers" -H 'Content-Type: application/json' \
          -d "{\"name\":\"chaos-${ts}\",\"email\":\"chaos-${ts}@example.com\"}" 2>/dev/null \
          | python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])' 2>/dev/null)"
    if [[ -n "$cid" ]]; then
        ok "POST /api/customers (needs: Oracle)"; R_WRITE=1
    else
        bad "POST /api/customers — needs Oracle"
    fi

    if [[ -n "$cid" ]] && "${CURL[@]}" -X POST "http://${HOST}/api/orders" -H 'Content-Type: application/json' \
            -d "{\"customerId\":${cid},\"amount\":1.00}" >/dev/null 2>&1; then
        ok "POST /api/orders (needs: Oracle AND MQ AND Valkey — the full fan-out)"; R_ORDERS=1
    else
        bad "POST /api/orders — needs Oracle AND MQ AND Valkey"
    fi

    if "${CURL[@]}" -X POST "http://${HOST}/api/valkey/kv/chaos-probe?value=alive&ttlSeconds=60" >/dev/null 2>&1 \
       && "${CURL[@]}" "http://${HOST}/api/valkey/kv/chaos-probe" 2>/dev/null | grep -q alive; then
        ok "Valkey KV round-trip through the app (needs: Valkey)"; R_VALKEY=1
    else
        bad "Valkey KV round-trip — needs Valkey"
    fi

    # Diagnosis from the green/red pattern
    if [[ $R_READ -eq 1 && $R_WRITE -eq 1 && $R_VALKEY -eq 1 && $R_ORDERS -eq 0 ]]; then
        note "diagnosis: Oracle OK, Valkey OK, fan-out dead → IBM MQ is the broken link"
    elif [[ $R_READ -eq 0 && $R_WRITE -eq 0 && $R_VALKEY -eq 1 ]]; then
        note "diagnosis: Valkey OK, CRUD dead → Oracle is the broken link"
    elif [[ $R_READ -eq 1 && $R_VALKEY -eq 0 ]]; then
        note "diagnosis: Oracle OK, Valkey paths dead → Valkey is the broken link"
        note "note: GETs may still work briefly — Spring Cache errors fall through to the DB only on reads"
    fi

    local cli seed
    cli="$(command -v valkey-cli || command -v redis-cli || true)"
    if [[ -n "$cli" ]]; then
        seed="$(valkey_announced_endpoints valkey 2>/dev/null | awk -F'\t' '$1=="valkey-primary-0"{print $2;exit}')"
        if [[ -n "$seed" ]] && "$cli" -h "${seed%%:*}" -p "${seed##*:}" -a "$VK_PASS" --no-auth-warning -t 3 ping 2>/dev/null | grep -q PONG; then
            ok "Valkey direct from the Mac (${seed} — the announced VIP path)"
        else
            bad "Valkey direct from the Mac — VIP path broken"
        fi
    fi
    bold "──────────────────────────────────────────────────────────────"
}

# ---------------------------------------------------------------------------
# Scenarios
# ---------------------------------------------------------------------------
break_valkey_failover() {
    local victim="valkey-primary-1"
    bold "Freezing ${victim}'s event loop for 20s (DEBUG SLEEP) — peers will"
    bold "declare it failed after ~5s and its replica will win an election."
    kubectl -n valkey exec "$victim" -- valkey-cli -a "$VK_PASS" --no-auth-warning debug sleep 20 >/dev/null 2>&1 &
    sleep 8
    note "election should have happened — probing DURING the outage:"
    probe
    note "waiting for the frozen node to wake, demote itself, then failing back..."
    sleep 16
    kubectl -n valkey exec "$victim" -- valkey-cli -a "$VK_PASS" --no-auth-warning cluster failover >/dev/null 2>&1
    sleep 5
    ok "self-healed: roles restored (verify: scripts/valkey-tour.sh --section topology)"
}

break_valkey_down()  { bold "Scaling Valkey to 0 (both StatefulSets)...";
                       kubectl -n valkey scale statefulset valkey-primary valkey-secondary --replicas=0 >/dev/null; sleep 8; }
heal_valkey_down()   { bold "Scaling Valkey back to 3+3...";
                       kubectl -n valkey scale statefulset valkey-primary valkey-secondary --replicas=3 >/dev/null
                       kubectl -n valkey rollout status statefulset/valkey-primary --timeout=180s >/dev/null 2>&1
                       kubectl -n valkey rollout status statefulset/valkey-secondary --timeout=180s >/dev/null 2>&1
                       sleep 5; }

break_oracle_down()  { bold "Scaling Oracle to 0..."; kubectl -n oracle scale statefulset oracle-oracle --replicas=0 >/dev/null; sleep 8; }
heal_oracle_down()   { bold "Scaling Oracle back to 1 (startup takes ~1-2 min)...";
                       kubectl -n oracle scale statefulset oracle-oracle --replicas=1 >/dev/null
                       kubectl -n oracle rollout status statefulset/oracle-oracle --timeout=300s >/dev/null 2>&1; }

break_mq_down()      { bold "Scaling IBM MQ to 0..."; kubectl -n mq scale statefulset ibm-mq-ibm-mq --replicas=0 >/dev/null; sleep 8; }
heal_mq_down()       { bold "Scaling IBM MQ back to 1...";
                       kubectl -n mq scale statefulset ibm-mq-ibm-mq --replicas=1 >/dev/null
                       kubectl -n mq rollout status statefulset/ibm-mq-ibm-mq --timeout=300s >/dev/null 2>&1; }

break_app_kill()     { bold "Deleting the app pod (k8s will restart it)...";
                       kubectl -n debug-demo delete pod -l app.kubernetes.io/name=debug-demo-app --wait=false >/dev/null
                       note "probing IMMEDIATELY (expect the external path to 503 until readiness passes):"; }
heal_app_kill()      { kubectl -n debug-demo wait --for=condition=Ready pod -l app.kubernetes.io/name=debug-demo-app --timeout=180s >/dev/null 2>&1; }

break_haproxy_stop() { bold "Stopping the F5 stand-in VM (limactl stop debug-demo-haproxy)...";
                       limactl stop debug-demo-haproxy >/dev/null 2>&1; sleep 3
                       note "external path is now dead. In-cluster traffic — and Valkey gossip,"
                       note "which flows through the dev VIP shim, not the real VM — stays up."; }
heal_haproxy_stop()  { bold "Restarting the F5 stand-in VM...";
                       "$SCRIPT_DIR/install-haproxy-vm.sh" >/dev/null 2>&1
                       sleep 12   # HAProxy backend health check: inter 5s rise 2
                     }

status() {
    bold "── Current stack state ──────────────────────────────────────"
    printf '  %-22s %s\n' "valkey pods:"  "$(kubectl -n valkey get pods --no-headers 2>/dev/null | grep -c Running)/6 running"
    printf '  %-22s %s\n' "oracle pods:"  "$(kubectl -n oracle get pods --no-headers 2>/dev/null | grep -c Running)/1 running"
    printf '  %-22s %s\n' "mq pods:"      "$(kubectl -n mq get pods --no-headers 2>/dev/null | grep -c Running)/1 running"
    printf '  %-22s %s\n' "app pods:"     "$(kubectl -n debug-demo get pods --no-headers 2>/dev/null | grep -c Running) running"
    local vm; vm="$(limactl list --format=json 2>/dev/null)"
    if [[ "$vm" == *'"name":"debug-demo-haproxy"'*'"status":"Running"'* || "$vm" == *debug-demo-haproxy*Running* ]]; then
        printf '  %-22s %s\n' "haproxy VM:" "Running"
    else
        printf '  %-22s %s\n' "haproxy VM:" "NOT running"
    fi
}

heal_all() {
    bold "Healing everything..."
    kubectl -n valkey scale statefulset valkey-primary valkey-secondary --replicas=3 >/dev/null 2>&1
    kubectl -n oracle scale statefulset oracle-oracle --replicas=1 >/dev/null 2>&1
    kubectl -n mq scale statefulset ibm-mq-ibm-mq --replicas=1 >/dev/null 2>&1
    heal_haproxy_stop
    kubectl -n valkey rollout status statefulset/valkey-primary --timeout=180s >/dev/null 2>&1
    kubectl -n valkey rollout status statefulset/valkey-secondary --timeout=180s >/dev/null 2>&1
    kubectl -n oracle rollout status statefulset/oracle-oracle --timeout=300s >/dev/null 2>&1
    kubectl -n mq rollout status statefulset/ibm-mq-ibm-mq --timeout=300s >/dev/null 2>&1
    ok "all dependencies restored"
    probe
}

run_scenario() {
    local sc="$1" heal_after="${2:-0}"
    case "$sc" in
        valkey-failover) break_valkey_failover; return ;;   # self-healing
        valkey-down)     break_valkey_down ;;
        oracle-down)     break_oracle_down ;;
        mq-down)         break_mq_down ;;
        app-kill)        break_app_kill ;;
        haproxy-stop)    break_haproxy_stop ;;
        *) err "unknown scenario: $sc"; exit 64 ;;
    esac
    probe
    if [[ "$heal_after" == "1" ]]; then
        "heal_${sc//-/_}"
        note "healed. Final probe:"
        probe
    else
        echo
        note "left broken on purpose. Restore with: scripts/chaos.sh heal"
        [[ "$sc" == "app-kill" ]] && note "(app-kill self-heals — k8s is restarting the pod already)"
    fi
}

menu() {
    while true; do
        echo
        bold "chaos.sh — pick a failure to inject"
        cat <<'EOF'
  1) valkey-failover  freeze a primary; watch a real election (self-healing)
  2) valkey-down      whole cache/streams tier gone
  3) oracle-down      database gone
  4) mq-down          message broker gone
  5) app-kill         kill the app pod, watch k8s bring it back
  6) haproxy-stop     kill the external LB (F5 stand-in)
  p) probe            observe current state
  s) status           what's broken right now?
  h) heal             restore everything
  q) quit
EOF
        printf '> '
        read -r choice
        case "$choice" in
            1) run_scenario valkey-failover ;;
            2) run_scenario valkey-down 1 ;;
            3) run_scenario oracle-down 1 ;;
            4) run_scenario mq-down 1 ;;
            5) run_scenario app-kill 1 ;;
            6) run_scenario haproxy-stop 1 ;;
            p) probe ;;
            s) status ;;
            h) heal_all ;;
            q) exit 0 ;;
            *) echo "?" ;;
        esac
    done
}

case "${1:-menu}" in
    menu)   menu ;;
    probe)  probe ;;
    status) status ;;
    heal)   heal_all ;;
    -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//' ;;
    *)      HEAL_AFTER=0; [[ "${2:-}" == "--heal-after" ]] && HEAL_AFTER=1
            run_scenario "$1" "$HEAL_AFTER" ;;
esac
