#!/usr/bin/env bash
#
# k3s-chaos.sh — chaos for the multi-node k3s stack. Beyond the single-node
# failures the old chaos.sh could do, this adds the things a REAL cluster
# exposes: kill a whole node and watch the keepalived VIP fail over + pods
# reschedule. Break one thing at a time, LEAVE it broken, get debug + heal
# commands; nothing auto-heals unless it self-heals by design.
#
# Scenarios:
#   node-down <agent>   stop an agent VM → its pods reschedule onto the others
#   vip-failover        stop the node holding the VIP → keepalived moves it,
#                       HTTP keeps working on the same hostname
#   valkey-freeze       DEBUG SLEEP a Valkey primary → replica election
#   oracle-down / mq-down / valkey-down   scale a backend to 0
#
#   probe    observe the stack by hostname     heal <scenario>    recover one
#   status   VMs + VIP + pods                  heal               recover all
#
# Usage:
#   ./k3s-chaos.sh                    interactive menu
#   ./k3s-chaos.sh node-down agent-1  break it, probe, print heal
#   ./k3s-chaos.sh heal node-down
#   ./k3s-chaos.sh heal               everything

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/k3s-env.sh
source "$SCRIPT_DIR/lib/k3s-env.sh"
set +e

require_cmd kubectl limactl curl
export VK_PASS="$(kubectl -n valkey get secret valkey -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null)"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
sect() { echo; printf '\033[1m── %s ─────────────────────────────────────\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✔ %s\033[0m\n' "$*"; }
bad()  { printf '  \033[31m✘ %s\033[0m\n' "$*"; }
note() { printf '  \033[33m● %s\033[0m\n' "$*"; }
cmd()  { printf '  \033[36m$ %s\033[0m\n' "$*"; }
run()  { cmd "$1"; bash -c "$1" 2>&1 | sed 's/^/      /' | head -"${2:-12}"; echo; }

vip_owner() {
    for vm in "${K3S_ALL_VMS[@]}"; do
        limactl shell "$vm" -- ip -4 -o addr show 2>/dev/null | grep -q "$K3S_VIP" && { echo "$vm"; return; }
    done
    echo "(none)"
}

probe() {
    sect "Observations (by hostname)"
    if curl -fsS -m6 --resolve "${APP_HOST}:80:${K3S_VIP}" "http://${APP_HOST}/actuator/health" 2>/dev/null | grep -q UP; then
        ok "app health via http://${APP_HOST}/ (VIP $K3S_VIP)"
    else bad "app health via ${APP_HOST} — external path down"; fi

    local ts cid
    ts=$(date +%s)
    cid=$(curl -fsS -m8 --resolve "${APP_HOST}:80:${K3S_VIP}" -X POST "http://${APP_HOST}/api/customers" \
          -H 'Content-Type: application/json' -d "{\"name\":\"chaos-$ts\",\"email\":\"chaos-$ts@e.com\"}" 2>/dev/null \
          | python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])' 2>/dev/null)
    [[ -n "$cid" ]] && ok "POST /api/customers (Oracle)" || bad "POST /api/customers (Oracle)"
    if [[ -n "$cid" ]] && curl -fsS -m8 --resolve "${APP_HOST}:80:${K3S_VIP}" -X POST "http://${APP_HOST}/api/orders" \
          -H 'Content-Type: application/json' -d "{\"customerId\":$cid,\"amount\":1.0}" >/dev/null 2>&1; then
        ok "POST /api/orders (Oracle+MQ+Valkey fan-out)"
    else bad "POST /api/orders (needs Oracle+MQ+Valkey)"; fi

    local cs
    cs=$(kubectl -n valkey exec valkey-primary-0 -- valkey-cli -a "$VK_PASS" cluster info 2>/dev/null | grep -oE 'cluster_state:[a-z]+' | cut -d: -f2)
    [[ "$cs" == ok ]] && ok "Valkey cluster_state: ok" || bad "Valkey cluster_state: ${cs:-unreachable}"
    note "VIP $K3S_VIP held by: $(vip_owner)"
}

status() {
    sect "Cluster"
    for vm in "${K3S_ALL_VMS[@]}"; do
        st="$(limactl list --format '{{.Name}} {{.Status}}' 2>/dev/null | awk -v n="$vm" '$1==n{print $2}')"
        printf '  %-16s %s%s\n' "$vm" "$st" "$([ "$vm" = "$(vip_owner)" ] && echo '  ← VIP')"
    done
    echo
    kubectl get nodes --no-headers 2>/dev/null | awk '{print "  "$1, $2}'
}

# --- scenarios: break_X / debug_X (cmd list) / heal_X -----------------------
agent_arg() { case "$1" in agent-1|agent-2) echo "${K3S_VM_PREFIX}-$1";; ddk3s-*) echo "$1";; *) echo "${K3S_VM_PREFIX}-agent-1";; esac; }

break_node_down() {
    local vm; vm="$(agent_arg "${1:-agent-1}")"
    sect "BREAK: node-down ($vm)"
    note "stopping a whole node — its pods must reschedule onto the survivors."
    [[ "$vm" == "$(vip_owner)" ]] && note "(this node holds the VIP — keepalived will move it)"
    run "limactl stop $vm"
    sleep 10
}
debug_node_down() { local vm; vm="$(agent_arg "${1:-agent-1}")"; cat <<EOF
# The node goes NotReady; k8s reschedules its pods after ~40s eviction timeout.
kubectl get nodes
kubectl get pods -A -o wide | grep -v Running   # what's pending/rescheduling
# The VIP should still answer (moved to a live node if this one held it):
scripts/k3s-chaos.sh probe
kubectl -n valkey get pods -o wide              # valkey replicas cover the gap
EOF
}
heal_node_down() { local vm; vm="$(agent_arg "${1:-agent-1}")"; cat <<EOF
limactl start $vm
kubectl wait --for=condition=Ready node/lima-$vm --timeout=180s
EOF
}

break_vip_failover() {
    sect "BREAK: vip-failover"
    local owner; owner="$(vip_owner)"
    note "the VIP is on $owner; stopping it forces keepalived to elect a new holder."
    run "limactl stop $owner"
    sleep 8
    note "VIP now on: $(vip_owner)  (HTTP on http://${APP_HOST}/ should still work)"
}
debug_vip_failover() { cat <<EOF
# Which node holds the VIP now?
scripts/k3s-chaos.sh status
# HTTP by hostname should still resolve+serve (keepalived moved the VIP):
curl --resolve ${APP_HOST}:80:${K3S_VIP} http://${APP_HOST}/actuator/health
EOF
}
heal_vip_failover() { cat <<EOF
# Bring the stopped node back; keepalived may or may not move the VIP back
# (priority server 150 > agents), which is fine.
for vm in ${K3S_ALL_VMS[*]}; do limactl start \$vm 2>/dev/null; done
EOF
}

break_valkey_freeze() {
    sect "BREAK: valkey-freeze (primary-1, 20s DEBUG SLEEP)"
    note "freezing a primary so peers detect failure and its replica is elected."
    cmd 'kubectl -n valkey exec valkey-primary-1 -- valkey-cli -a $VK_PASS debug sleep 20  # (detached)'
    kubectl -n valkey exec valkey-primary-1 -- valkey-cli -a "$VK_PASS" --no-auth-warning debug sleep 20 >/dev/null 2>&1 &
    sleep 8
    note "election should have happened; self-heals in ~20s."
}
debug_valkey_freeze() { cat <<'EOF'
# Watch the by-index replica (secondary-1) take over shard 1:
kubectl -n valkey exec valkey-primary-0 -- valkey-cli -a "$VK_PASS" cluster nodes | grep -E 'master|slave'
# Writes keep working through the cluster (in-cluster, by hostname):
kubectl -n valkey exec valkey-primary-0 -- valkey-cli -c -h valkey.debug-demo.local -p 6379 -a "$VK_PASS" set freeze-probe ok
EOF
}
heal_valkey_freeze() { cat <<'EOF'
# Self-heals: the frozen node wakes and demotes. To restore canonical roles:
kubectl -n valkey exec valkey-primary-1 -- valkey-cli -a "$VK_PASS" cluster failover
EOF
}

break_backend() {  # $1 = oracle|mq|valkey
    local ns="$1" sts
    case "$ns" in oracle) sts="oracle-oracle";; mq) sts="ibm-mq-ibm-mq";; valkey) sts="valkey-primary valkey-secondary";; esac
    sect "BREAK: $ns-down (scale to 0)"
    run "kubectl -n $ns scale statefulset $sts --replicas=0"
    sleep 6
}
debug_backend() { local ns="$1"; cat <<EOF
kubectl -n $ns get pods
POD=\$(kubectl -n debug-demo get pod -l app.kubernetes.io/name=debug-demo-app -o jsonpath='{.items[0].metadata.name}')
kubectl -n debug-demo exec \$POD -- curl -s http://localhost:8080/actuator/health
kubectl -n debug-demo logs -l app.kubernetes.io/name=debug-demo-app --tail=40 | grep -iE '$ns|redis|jdbc|jms|connection' | tail -6
scripts/k3s-chaos.sh probe
EOF
}
heal_backend() { local ns="$1" sts reps
    case "$ns" in oracle) sts="oracle-oracle"; reps=1;; mq) sts="ibm-mq-ibm-mq"; reps=1;; valkey) sts="valkey-primary valkey-secondary"; reps=3;; esac
    cat <<EOF
kubectl -n $ns scale statefulset $sts --replicas=$reps
kubectl -n $ns rollout status statefulset/${sts%% *} --timeout=300s
EOF
}

run_break() {
    case "$1" in
        node-down)     break_node_down "${2:-}";  probe; sect "DEBUG"; debug_node_down "${2:-}" | while IFS= read -r l; do case "$l" in \#*) note "${l#\# }";; *) cmd "$l";; esac; done; sect "HEAL — run: scripts/k3s-chaos.sh heal node-down"; heal_node_down "${2:-}" | while IFS= read -r l; do cmd "$l"; done ;;
        vip-failover)  break_vip_failover; probe; sect "DEBUG"; debug_vip_failover | while IFS= read -r l; do case "$l" in \#*) note "${l#\# }";; *) cmd "$l";; esac; done; sect "HEAL — run: scripts/k3s-chaos.sh heal vip-failover"; heal_vip_failover | while IFS= read -r l; do case "$l" in \#*) note "${l#\# }";; *) cmd "$l";; esac; done ;;
        valkey-freeze) break_valkey_freeze; probe; sect "DEBUG"; debug_valkey_freeze | while IFS= read -r l; do case "$l" in \#*) note "${l#\# }";; *) cmd "$l";; esac; done; note "self-healing; heal restores canonical roles" ;;
        oracle-down|mq-down|valkey-down) ns="${1%-down}"; break_backend "$ns"; probe; sect "DEBUG"; debug_backend "$ns" | while IFS= read -r l; do case "$l" in \#*) note "${l#\# }";; *) cmd "$l";; esac; done; sect "HEAL — run: scripts/k3s-chaos.sh heal $1"; heal_backend "$ns" | while IFS= read -r l; do cmd "$l"; done ;;
        *) err "unknown scenario: $1"; exit 64 ;;
    esac
}

run_heal() {
    case "$1" in
        node-down)     eval "$(heal_node_down "${2:-}")" 2>&1 | tail -2 ;;
        vip-failover)  for vm in "${K3S_ALL_VMS[@]}"; do limactl start "$vm" >/dev/null 2>&1; done; echo "  nodes started" ;;
        valkey-freeze) kubectl -n valkey exec valkey-primary-1 -- valkey-cli -a "$VK_PASS" cluster failover >/dev/null 2>&1; echo "  failover issued" ;;
        oracle-down)   kubectl -n oracle scale statefulset oracle-oracle --replicas=1 >/dev/null 2>&1; echo "  oracle scaled up" ;;
        mq-down)       kubectl -n mq scale statefulset ibm-mq-ibm-mq --replicas=1 >/dev/null 2>&1; echo "  mq scaled up" ;;
        valkey-down)   kubectl -n valkey scale statefulset valkey-primary valkey-secondary --replicas=3 >/dev/null 2>&1; echo "  valkey scaled up" ;;
        "")            heal_all ;;
        *) err "unknown scenario: $1"; exit 64 ;;
    esac
    [[ -n "${1:-}" ]] && { sleep 5; probe; }
}

heal_all() {
    sect "HEAL: everything"
    for vm in "${K3S_ALL_VMS[@]}"; do limactl start "$vm" >/dev/null 2>&1; done
    kubectl -n oracle scale statefulset oracle-oracle --replicas=1 >/dev/null 2>&1
    kubectl -n mq scale statefulset ibm-mq-ibm-mq --replicas=1 >/dev/null 2>&1
    kubectl -n valkey scale statefulset valkey-primary valkey-secondary --replicas=3 >/dev/null 2>&1
    ok "recovery issued (nodes started, backends scaled up)"
    sleep 8; probe
}

menu() {
    while true; do
        sect "k3s-chaos"
        cat <<'EOF'
  1) node-down agent-1   stop a whole node (pods reschedule)
  2) vip-failover        stop the VIP holder (keepalived moves it)
  3) valkey-freeze       freeze a primary (self-heals)
  4) oracle-down   5) mq-down   6) valkey-down
  p) probe   s) status   h) heal <scenario> (blank=all)   q) quit
EOF
        printf '> '; read -r c rest
        case "$c" in
            1) run_break node-down "${rest:-agent-1}" ;;
            2) run_break vip-failover ;;
            3) run_break valkey-freeze ;;
            4) run_break oracle-down ;; 5) run_break mq-down ;; 6) run_break valkey-down ;;
            p) probe ;; s) status ;;
            h) run_heal "$rest" ;;
            q) exit 0 ;; *) echo "?" ;;
        esac
    done
}

case "${1:-menu}" in
    menu) menu ;;
    probe) probe ;;
    status) status ;;
    heal) run_heal "${2:-}" ;;
    -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//' ;;
    *) run_break "$1" "${2:-}" ;;
esac
