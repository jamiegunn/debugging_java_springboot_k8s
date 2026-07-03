#!/usr/bin/env bash
#
# chaos.sh — incremental chaos engineering for the debug-demo stack. Break ONE
# dependency at a time and LEAVE IT BROKEN, so you can investigate at your own
# pace. For every scenario you get three things:
#
#   1. the exact command that broke it,
#   2. a probe showing the blast radius (what survived, what died),
#   3. copy-pasteable DEBUG commands to diagnose it, run live, and
#   4. copy-pasteable HEAL commands to bring it back.
#
# Nothing auto-heals (except the two scenarios that are self-healing BY DESIGN
# — app-kill and valkey-failover — which say so). Stack failures to see
# cumulative damage: break mq, then valkey, then oracle; the probe shows the
# API losing capabilities one by one. Restore with `chaos.sh heal <scenario>`
# or `chaos.sh heal` (everything).
#
# Scenarios:  valkey-down  oracle-down  mq-down  haproxy-stop
#             app-kill (self-heals)     valkey-failover (self-heals)
#
# Usage:
#   ./chaos.sh                      interactive menu
#   ./chaos.sh oracle-down          break it + probe + debug + how-to-heal (LEFT BROKEN)
#   ./chaos.sh heal oracle-down     run the heal commands for one scenario
#   ./chaos.sh heal                 restore everything
#   ./chaos.sh debug oracle-down    just re-run the debug commands
#   ./chaos.sh incremental          guided cumulative-degradation walkthrough
#   ./chaos.sh probe | status       observe current state
#
# Copy-pasteable commands reference $VK_PASS and $ENTRY_IP. Set them once:
#   export VK_PASS=$(kubectl -n valkey get secret valkey -o jsonpath='{.data.password}' | base64 -d)
#   export ENTRY_IP=$(cat dumps/haproxy-vm-ip)

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
set +e   # chaos EXPECTS failures; report them, don't die on them

require_cmd kubectl curl python3

export VK_PASS="$(kubectl -n valkey get secret valkey -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null)"
if [[ -f "$REPO_ROOT/dumps/haproxy-vm-ip" ]]; then
    export ENTRY_IP="$(cat "$REPO_ROOT/dumps/haproxy-vm-ip")"
else
    export ENTRY_IP="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="ExternalIP")].address}' 2>/dev/null)"
fi
export HOST="debug-demo.local"
CURL=(curl -fsS -m 6 --resolve "${HOST}:80:${ENTRY_IP}")

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
sect() { echo; printf '\033[1m── %s %s\033[0m\n' "$*" "$(printf '─%.0s' $(seq 1 $((58 - ${#1}))))"; }
ok()   { printf '  \033[32m✔ %s\033[0m\n' "$*"; }
bad()  { printf '  \033[31m✘ %s\033[0m\n' "$*"; }
note() { printf '  \033[33m● %s\033[0m\n' "$*"; }
dim()  { printf '  \033[2m%s\033[0m\n' "$*"; }

# --- command-list renderers -------------------------------------------------
# A "command list" is a heredoc, one command per line; lines starting with #
# are shown as dim comments. print_cmds echoes them (a copy-paste recipe);
# run_cmds echoes each then runs it live (for read-only diagnostics / heals).
# Commands are single, self-contained lines (POD lookups inlined) so each runs
# in its own fresh subshell and stays copy-pasteable.
print_cmds() {
    while IFS= read -r c; do
        [[ -z "$c" ]] && { echo; continue; }
        case "$c" in
            \#*) printf '  \033[2m%s\033[0m\n' "$c" ;;
            *)   printf '  \033[36m$ %s\033[0m\n' "$c" ;;
        esac
    done
}
run_cmds() {
    while IFS= read -r c; do
        [[ -z "$c" ]] && { echo; continue; }
        case "$c" in
            \#*) printf '  \033[2m%s\033[0m\n' "$c"; continue ;;
        esac
        printf '  \033[36m$ %s\033[0m\n' "$c"
        bash -c "$c" 2>&1 | sed 's/^/      /' | head -"${CMD_HEAD:-15}"
        echo   # guarantee separation (some endpoints return no trailing newline)
    done
}

pause() { [[ -t 0 ]] && { printf '\n  \033[2m[Enter to continue]\033[0m '; read -r; }; return 0; }

# ===========================================================================
# Per-scenario command lists. Defined ONCE; rendered by print_cmds (recipe) or
# run_cmds (execute). $VK_PASS / $ENTRY_IP expand at run time, print literally.
# ===========================================================================
POD_LOOKUP='POD=$(kubectl -n debug-demo get pod -l app.kubernetes.io/name=debug-demo-app -o jsonpath='"'"'{.items[0].metadata.name}'"'"')'

break_cmds_valkey_down() { cat <<'EOF'
kubectl -n valkey scale statefulset valkey-primary valkey-secondary --replicas=0
EOF
}
debug_cmds_valkey_down() { cat <<EOF
# Are the pods actually gone?
kubectl -n valkey get pods
kubectl -n valkey get statefulset
# What does the app's health say? (the redis indicator is DOWN)
${POD_LOOKUP}; kubectl -n debug-demo exec \$POD -- curl -s http://localhost:8080/actuator/health
# App logs — Lettuce connection failures / command timeouts:
kubectl -n debug-demo logs -l app.kubernetes.io/name=debug-demo-app --tail=40 | grep -iE 'redis|valkey|RedisConnection|timed out' | tail -8
# Behavior: the KV endpoint 500s (needs Valkey); confirm the status code:
curl -s -o /dev/null -w 'HTTP %{http_code}\n' --resolve debug-demo.local:80:\$ENTRY_IP http://debug-demo.local/api/valkey/kv/foo
EOF
}
heal_cmds_valkey_down() { cat <<'EOF'
# Scale both StatefulSets back to 3:
kubectl -n valkey scale statefulset valkey-primary valkey-secondary --replicas=3
kubectl -n valkey rollout status statefulset/valkey-primary --timeout=180s
kubectl -n valkey rollout status statefulset/valkey-secondary --timeout=180s
# The post-install Job self-heals stale nodes.conf from the surviving PVCs.
# Wait for the cluster to re-form (may take a few seconds after pods are Ready):
kubectl -n valkey exec valkey-primary-0 -- valkey-cli -a "$VK_PASS" cluster info | grep -E 'cluster_state|cluster_known_nodes'
EOF
}

break_cmds_oracle_down() { cat <<'EOF'
kubectl -n oracle scale statefulset oracle-oracle --replicas=0
EOF
}
debug_cmds_oracle_down() { cat <<EOF
kubectl -n oracle get pods
# Health: the db indicator is DOWN:
${POD_LOOKUP}; kubectl -n debug-demo exec \$POD -- curl -s http://localhost:8080/actuator/health
# HikariCP can't hand out a connection — look for the pool timeout:
kubectl -n debug-demo logs -l app.kubernetes.io/name=debug-demo-app --tail=60 | grep -iE 'HikariPool|Connection is not available|ORA-|SQLRecoverable' | tail -8
# CRUD returns 500 (needs Oracle); Valkey-only endpoints still work:
curl -s -o /dev/null -w 'GET /api/customers  -> HTTP %{http_code}\n' --resolve debug-demo.local:80:\$ENTRY_IP http://debug-demo.local/api/customers
curl -s -o /dev/null -w 'GET /api/valkey/leaderboard -> HTTP %{http_code}\n' --resolve debug-demo.local:80:\$ENTRY_IP 'http://debug-demo.local/api/valkey/leaderboard?n=5'
EOF
}
heal_cmds_oracle_down() { cat <<'EOF'
kubectl -n oracle scale statefulset oracle-oracle --replicas=1
# Oracle Free takes ~1-2 min to open the database — this waits for pod Ready:
kubectl -n oracle rollout status statefulset/oracle-oracle --timeout=300s
# Confirm the DB actually opened (not just the pod started):
kubectl -n oracle logs oracle-oracle-0 --tail=10 | grep -iE 'DATABASE.*READY|completed|open for'
EOF
}

break_cmds_mq_down() { cat <<'EOF'
kubectl -n mq scale statefulset ibm-mq-ibm-mq --replicas=0
EOF
}
debug_cmds_mq_down() { cat <<EOF
kubectl -n mq get pods
# Health: the jms indicator is DOWN:
${POD_LOOKUP}; kubectl -n debug-demo exec \$POD -- curl -s http://localhost:8080/actuator/health
# App logs — JMS connection failure at publish time:
kubectl -n debug-demo logs -l app.kubernetes.io/name=debug-demo-app --tail=60 | grep -iE 'JMS|MQJ|AMQ|jms|Connection refused' | tail -8
# The tell: order creation 500s (fan-out publishes to MQ) but customer CRUD is fine:
curl -s -o /dev/null -w 'POST /api/customers -> HTTP %{http_code}\n' --resolve debug-demo.local:80:\$ENTRY_IP -X POST http://debug-demo.local/api/customers -H 'Content-Type: application/json' -d '{"name":"mq-test","email":"mq-test-'\$RANDOM'@e.com"}'
EOF
}
heal_cmds_mq_down() { cat <<'EOF'
kubectl -n mq scale statefulset ibm-mq-ibm-mq --replicas=1
kubectl -n mq rollout status statefulset/ibm-mq-ibm-mq --timeout=300s
# Confirm the queue manager is Running:
kubectl -n mq exec ibm-mq-ibm-mq-0 -- dspmq
EOF
}

break_cmds_haproxy_stop() { cat <<'EOF'
limactl stop debug-demo-haproxy
EOF
}
debug_cmds_haproxy_stop() { cat <<EOF
# The VM (external F5 stand-in) is Stopped:
limactl list | grep debug-demo-haproxy
# External path is dead — the VIP no longer answers:
curl -m 5 -s -o /dev/null -w 'external -> HTTP %{http_code}\n' --resolve debug-demo.local:80:\$ENTRY_IP http://debug-demo.local/actuator/health || echo '  external -> timed out (VIP down, as expected)'
# But IN-CLUSTER traffic is fine (it never uses the external VIP):
${POD_LOOKUP}; kubectl -n debug-demo exec \$POD -- curl -s http://localhost:8080/actuator/health
# And the Valkey cluster is still healthy — gossip uses the in-cluster VIP
# shim, NOT the VM (this is exactly the split-horizon the shim provides):
kubectl -n valkey exec valkey-primary-0 -- valkey-cli -a "\$VK_PASS" cluster info | grep cluster_state
EOF
}
heal_cmds_haproxy_stop() { cat <<'EOF'
# Restart the VM and regenerate its haproxy.cfg (idempotent):
scripts/install-haproxy-vm.sh
# HAProxy's backend health check needs ~10s (inter 5s, rise 2) before it
# marks the node UP; then the external path returns:
sleep 12
curl -s -o /dev/null -w 'external -> HTTP %{http_code}\n' --resolve debug-demo.local:80:$(cat dumps/haproxy-vm-ip) http://debug-demo.local/actuator/health
EOF
}

break_cmds_app_kill() { cat <<'EOF'
kubectl -n debug-demo delete pod -l app.kubernetes.io/name=debug-demo-app --wait=false
EOF
}
debug_cmds_app_kill() { cat <<EOF
# The Deployment is already creating a replacement (self-healing by design):
kubectl -n debug-demo get pods
# During the gap the external path 503s until the new pod passes readiness:
curl -m 5 -s -o /dev/null -w 'external -> HTTP %{http_code}\n' --resolve debug-demo.local:80:\$ENTRY_IP http://debug-demo.local/actuator/health
# Watch the readiness/liveness probe events on the new pod:
kubectl -n debug-demo describe pod -l app.kubernetes.io/name=debug-demo-app | grep -A6 Events | tail -8
EOF
}
heal_cmds_app_kill() { cat <<'EOF'
# k8s already recreated the pod. Just wait for it to become Ready:
kubectl -n debug-demo wait --for=condition=Ready pod -l app.kubernetes.io/name=debug-demo-app --timeout=180s
EOF
}

break_cmds_valkey_failover() { cat <<'EOF'
# Freeze primary-1's event loop for 20s so peers detect a real failure. Run
# it DETACHED (it blocks for the full 20s):
kubectl -n valkey exec valkey-primary-1 -- valkey-cli -a "$VK_PASS" debug sleep 20 &
EOF
}
debug_cmds_valkey_failover() { cat <<EOF
# Who is master for shard 1 now? (secondary-1 should have been promoted)
kubectl -n valkey exec valkey-primary-0 -- valkey-cli -a "\$VK_PASS" cluster nodes | grep -E 'master|slave'
# Writes keep working — the cluster routes to the promoted replica:
valkey-cli -c -h \$ENTRY_IP -p 6379 -a "\$VK_PASS" set failover-probe ok
# Watch it live in another terminal:
# watch "kubectl -n valkey exec valkey-primary-0 -- valkey-cli -a \\\$VK_PASS cluster nodes | grep -E 'master|slave'"
EOF
}
heal_cmds_valkey_failover() { cat <<'EOF'
# The frozen node wakes at ~20s and demotes itself to a replica automatically.
# To restore the ORIGINAL role layout, fail back on the recovered node:
kubectl -n valkey exec valkey-primary-1 -- valkey-cli -a "$VK_PASS" cluster failover
sleep 5
kubectl -n valkey exec valkey-primary-0 -- valkey-cli -a "$VK_PASS" cluster nodes | grep -E 'master|slave'
EOF
}

SELF_HEALING=" app-kill valkey-failover "
SCENARIOS="valkey-down oracle-down mq-down haproxy-stop app-kill valkey-failover"
is_scenario() { case " $SCENARIOS " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# ===========================================================================
# The observation suite. In chaos, a red ✘ is not a bug — it's the blast
# radius. The interesting part is which rows stay green.
# ===========================================================================
probe() {
    sect "Observations (blast radius)"
    local ts cid R_READ=0 R_WRITE=0 R_ORDERS=0 R_VALKEY=0

    if "${CURL[@]}" "http://${HOST}/actuator/health/liveness" 2>/dev/null | grep -q UP; then
        ok "app liveness (pod running + reachable through the external path)"
    else
        bad "app liveness — pod down, or the external path (HAProxy VM) is down"
    fi

    if "${CURL[@]}" "http://${HOST}/api/customers" >/dev/null 2>&1; then
        ok "GET /api/customers            (needs: Oracle)"; R_READ=1
    else bad "GET /api/customers            (needs: Oracle)"; fi

    ts="$(date +%s)-$$"
    cid="$("${CURL[@]}" -X POST "http://${HOST}/api/customers" -H 'Content-Type: application/json' \
          -d "{\"name\":\"chaos-${ts}\",\"email\":\"chaos-${ts}@example.com\"}" 2>/dev/null \
          | python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])' 2>/dev/null)"
    if [[ -n "$cid" ]]; then ok "POST /api/customers           (needs: Oracle)"; R_WRITE=1
    else bad "POST /api/customers           (needs: Oracle)"; fi

    if [[ -n "$cid" ]] && "${CURL[@]}" -X POST "http://${HOST}/api/orders" -H 'Content-Type: application/json' \
            -d "{\"customerId\":${cid},\"amount\":1.00}" >/dev/null 2>&1; then
        ok "POST /api/orders              (needs: Oracle AND MQ AND Valkey)"; R_ORDERS=1
    else bad "POST /api/orders              (needs: Oracle AND MQ AND Valkey)"; fi

    if "${CURL[@]}" -X POST "http://${HOST}/api/valkey/kv/chaos-probe?value=alive&ttlSeconds=60" >/dev/null 2>&1 \
       && "${CURL[@]}" "http://${HOST}/api/valkey/kv/chaos-probe" 2>/dev/null | grep -q alive; then
        ok "Valkey KV round-trip          (needs: Valkey)"; R_VALKEY=1
    else bad "Valkey KV round-trip          (needs: Valkey)"; fi

    local cli seed
    cli="$(command -v valkey-cli || command -v redis-cli || true)"
    if [[ -n "$cli" ]]; then
        seed="$(valkey_announced_endpoints valkey 2>/dev/null | awk -F'\t' '$1=="valkey-primary-0"{print $2;exit}')"
        if [[ -n "$seed" ]] && "$cli" -h "${seed%%:*}" -p "${seed##*:}" -a "$VK_PASS" --no-auth-warning -t 3 ping 2>/dev/null | grep -q PONG; then
            ok "Valkey direct from the Mac    (external VIP path: ${seed})"
        else bad "Valkey direct from the Mac    (external VIP path)"; fi
    fi

    # Diagnosis from the green/red pattern
    if   [[ $R_READ -eq 1 && $R_WRITE -eq 1 && $R_VALKEY -eq 1 && $R_ORDERS -eq 0 ]]; then
        note "diagnosis → Oracle OK, Valkey OK, fan-out dead = IBM MQ is the broken link"
    elif [[ $R_READ -eq 0 && $R_WRITE -eq 0 && $R_VALKEY -eq 1 ]]; then
        note "diagnosis → Valkey OK, CRUD dead = Oracle is the broken link"
    elif [[ $R_READ -eq 1 && $R_VALKEY -eq 0 ]]; then
        note "diagnosis → Oracle OK, Valkey paths dead = Valkey is the broken link"
    fi
}

status() {
    sect "Current stack state"
    # Count only the 6 cluster nodes, not the vip-shim DaemonSet (also in this ns).
    printf '  %-16s %s\n' "valkey:" "$(kubectl -n valkey get pods -l app.kubernetes.io/name=valkey --no-headers 2>/dev/null | grep -c Running)/6 nodes Running"
    printf '  %-16s %s\n' "oracle:" "$(kubectl -n oracle get pods --no-headers 2>/dev/null | grep -c Running)/1 pods Running"
    printf '  %-16s %s\n' "mq:"     "$(kubectl -n mq get pods --no-headers 2>/dev/null | grep -c Running)/1 pods Running"
    printf '  %-16s %s\n' "app:"    "$(kubectl -n debug-demo get pods --no-headers 2>/dev/null | grep -c Running) pod(s) Running (HPA 1-10)"
    local vm; vm="$(limactl list --format=json 2>/dev/null)"
    if [[ "$vm" == *debug-demo-haproxy*Running* ]]; then printf '  %-16s %s\n' "haproxy VM:" "Running"
    else printf '  %-16s %s\n' "haproxy VM:" "NOT Running"; fi
}

# --- flows ------------------------------------------------------------------
break_scenario() {
    local sc="$1" fn="${1//-/_}"
    is_scenario "$sc" || { err "unknown scenario: $sc"; exit 64; }
    sect "BREAK: $sc"
    if [[ "$SELF_HEALING" == *" $sc "* ]]; then
        note "heads-up: $sc is SELF-HEALING by design — k8s (or Valkey) recovers on its own."
    else
        note "this LEAVES the stack broken. Heal with: scripts/chaos.sh heal $sc"
    fi
    echo
    "break_cmds_$fn" | run_cmds
    sleep 6

    probe

    sect "DEBUG: how to investigate"
    dim "(these run live below; copy any to re-run yourself)"
    echo
    "debug_cmds_$fn" | run_cmds

    sect "HEAL: how to recover"
    dim "run these yourself, or: scripts/chaos.sh heal $sc"
    echo
    "heal_cmds_$fn" | print_cmds
}

debug_scenario() {
    local sc="$1" fn="${1//-/_}"
    is_scenario "$sc" || { err "unknown scenario: $sc"; exit 64; }
    sect "DEBUG: $sc"
    "debug_cmds_$fn" | run_cmds
}

heal_scenario() {
    local sc="$1" fn="${1//-/_}"
    is_scenario "$sc" || { err "unknown scenario: $sc"; exit 64; }
    sect "HEAL: $sc"
    "heal_cmds_$fn" | run_cmds
    probe
}

heal_all() {
    sect "HEAL: everything → healthy"
    print_cmds <<'EOF'
kubectl -n valkey scale statefulset valkey-primary valkey-secondary --replicas=3
kubectl -n oracle scale statefulset oracle-oracle --replicas=1
kubectl -n mq     scale statefulset ibm-mq-ibm-mq  --replicas=1
scripts/install-haproxy-vm.sh
# ...then wait for all rollouts + the Valkey cluster to re-form.
EOF
    echo
    note "running the above..."
    kubectl -n valkey scale statefulset valkey-primary valkey-secondary --replicas=3 >/dev/null 2>&1
    kubectl -n oracle scale statefulset oracle-oracle --replicas=1 >/dev/null 2>&1
    kubectl -n mq scale statefulset ibm-mq-ibm-mq --replicas=1 >/dev/null 2>&1
    "$SCRIPT_DIR/install-haproxy-vm.sh" >/dev/null 2>&1
    kubectl -n valkey rollout status statefulset/valkey-primary --timeout=180s >/dev/null 2>&1
    kubectl -n valkey rollout status statefulset/valkey-secondary --timeout=180s >/dev/null 2>&1
    kubectl -n oracle rollout status statefulset/oracle-oracle --timeout=300s >/dev/null 2>&1
    kubectl -n mq rollout status statefulset/ibm-mq-ibm-mq --timeout=300s >/dev/null 2>&1
    ok "restore commands issued"
    probe
}

incremental() {
    bold "Incremental degradation — watch the API lose capabilities one backend"
    bold "at a time, then restore. Nothing auto-heals until the final step."
    sect "Step 0: clean slate"
    heal_all
    pause
    sect "Step 1: kill IBM MQ  (orders die; CRUD + cache live)"
    break_cmds_mq_down | run_cmds; sleep 6; probe
    pause
    sect "Step 2: ALSO kill Valkey  (cache + orders dead; CRUD still up)"
    break_cmds_valkey_down | run_cmds; sleep 6; probe
    pause
    sect "Step 3: ALSO kill Oracle  (everything the API needs is gone)"
    break_cmds_oracle_down | run_cmds; sleep 6; probe
    pause
    sect "Step 4: heal it all back"
    heal_all
}

menu() {
    while true; do
        sect "chaos.sh"
        cat <<'EOF'
  Break (leaves it broken; you get debug + heal commands):
    1) valkey-down      whole cache/streams tier
    2) oracle-down      the database
    3) mq-down          the message broker
    4) haproxy-stop     the external LB (F5 stand-in)
    5) app-kill         the app pod            (self-heals)
    6) valkey-failover  freeze a primary       (self-heals)

  Investigate / recover:
    i) incremental      guided cumulative-degradation walkthrough
    p) probe            blast-radius observations
    s) status           pod/VM counts
    d) debug <n>        re-run a scenario's debug commands
    h) heal <n>         heal one scenario   (blank = heal everything)
    q) quit
EOF
        printf '> '
        read -r choice rest
        case "$choice" in
            1) break_scenario valkey-down ;;
            2) break_scenario oracle-down ;;
            3) break_scenario mq-down ;;
            4) break_scenario haproxy-stop ;;
            5) break_scenario app-kill ;;
            6) break_scenario valkey-failover ;;
            i) incremental ;;
            p) probe ;;
            s) status ;;
            d) [[ -n "$rest" ]] && debug_scenario "$rest" || echo "usage: d <scenario>" ;;
            h) [[ -n "$rest" ]] && heal_scenario "$rest" || heal_all ;;
            q) exit 0 ;;
            *) echo "?" ;;
        esac
    done
}

case "${1:-menu}" in
    menu)        menu ;;
    probe)       probe ;;
    status)      status ;;
    incremental) incremental ;;
    debug)       [[ -n "${2:-}" ]] && debug_scenario "$2" || { err "usage: chaos.sh debug <scenario>"; exit 64; } ;;
    heal)        [[ -n "${2:-}" ]] && heal_scenario "$2" || heal_all ;;
    -h|--help)   sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//' ;;
    *)           break_scenario "$1" ;;
esac
