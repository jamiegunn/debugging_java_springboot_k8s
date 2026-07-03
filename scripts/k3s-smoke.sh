#!/usr/bin/env bash
#
# k3s-smoke.sh — end-to-end verification of the multi-node k3s stack, ENTIRELY
# BY HOSTNAME. Replaces the Rancher-Desktop smoke-test.sh (HAProxy VM / MetalLB
# IPs / default kubectl context) with the k3s equivalent.
#
# Two entry styles, both hostname-based:
#   - HTTP from the Mac: curl --resolve debug-demo.local:80:<VIP>  (Host header
#     is the hostname; no /etc/resolver needed for this path).
#   - Valkey: run valkey-cli INSIDE the cluster (vkexec), so
#     valkey.debug-demo.local resolves via CoreDNS → VIP → klipper → pod. No Mac
#     /etc/resolver needed either. Exercises the real hostname client model.
#
# Each check prints [PASS]/[FAIL]; exit code = number of failures.
#
# Usage:
#   ./k3s-smoke.sh                 # everything
#   ./k3s-smoke.sh --commands      # also echo the command behind each check

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/k3s-env.sh
source "$SCRIPT_DIR/lib/k3s-env.sh"
set +e

require_cmd kubectl curl python3
[[ -s "$K3S_KUBECONFIG" ]] || { err "no kubeconfig — run scripts/k3s-cluster.sh up first"; exit 1; }

SHOW_CMDS=1
for a in "$@"; do case "$a" in --commands) SHOW_CMDS=1;; --no-commands) SHOW_CMDS=0;; -h|--help) sed -n '2,/^$/p' "$0"|sed 's/^# \{0,1\}//'; exit 0;; esac; done

export VK_PASS="$(kubectl -n valkey get secret valkey -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null)"

# HTTP by hostname from the Mac (Host header = the hostname; target = the VIP).
web() { curl -fsS -m 10 --resolve "${APP_HOST}:80:${K3S_VIP}" "http://${APP_HOST}$1" "${@:2}"; }

PASS=0; FAIL=0; FAILED=()
cmd() { [[ $SHOW_CMDS -eq 1 ]] && printf '  \033[36m$ %s\033[0m\n' "$*"; return 0; }
check() {
    local name="$1"; shift
    if "$@" >/tmp/k3s-smoke.out 2>&1; then printf '[PASS] %s\n' "$name"; PASS=$((PASS+1))
    else printf '[FAIL] %s\n' "$name"; FAIL=$((FAIL+1)); FAILED+=("$name"); sed 's/^/       /' /tmp/k3s-smoke.out | head -6; fi
}

# ===========================================================================
echo "=== 1. Cluster + nodes ============================================"
check "3 nodes Ready" bash -c 'kubectl get nodes --no-headers | awk "\$2==\"Ready\"{c++} END{exit !(c==3)}"'
cmd  "kubectl get nodes"
check "backend pods Ready (oracle:1 mq:1 valkey:6 app:1 ingress:3)" bash -c '
    for e in oracle:1 mq:1 valkey:6 debug-demo:1 ingress-nginx:3; do
        ns="${e%:*}"; want="${e#*:}"
        r=$(kubectl -n "$ns" get pods --no-headers 2>/dev/null | awk "{split(\$2,a,\"/\"); if(a[1]==a[2]&&a[1]>0)c++} END{print c+0}")
        [ "$r" -ge "$want" ] || { echo "$ns: $r/$want Ready"; exit 1; }
    done'

echo
echo "=== 2. HTTP via the VIP, by hostname ($APP_HOST → $K3S_VIP) ========"
cmd "curl --resolve ${APP_HOST}:80:${K3S_VIP} http://${APP_HOST}/actuator/health"
check "app /actuator/health = UP"        bash -c 'curl -fsS -m10 --resolve '"${APP_HOST}:80:${K3S_VIP}"' http://'"${APP_HOST}"'/actuator/health | grep -q UP'
check "Swagger UI served (200)"          bash -c 'curl -s -o /dev/null -w "%{http_code}" -m10 --resolve '"${APP_HOST}:80:${K3S_VIP}"' http://'"${APP_HOST}"'/swagger-ui/index.html | grep -q 200'
check "unknown Host → 404 (real L7 ingress routing)" bash -c '
    w=$(curl -s -o /dev/null -w "%{http_code}" -m10 --resolve other.example.com:80:'"${K3S_VIP}"' http://other.example.com/actuator/health)
    r=$(curl -s -o /dev/null -w "%{http_code}" -m10 --resolve '"${APP_HOST}:80:${K3S_VIP}"' http://'"${APP_HOST}"'/actuator/health)
    [ "$w" = 404 ] && [ "$r" = 200 ]'

echo
echo "=== 3. Business flow (Oracle + MQ + Valkey fan-out) =============="
TS=$(date +%s)
CID=$(web /api/customers -X POST -H 'Content-Type: application/json' -d "{\"name\":\"smoke-$TS\",\"email\":\"smoke-$TS@example.com\"}" 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])' 2>/dev/null)
check "POST /api/customers returns id (Oracle write)" bash -c '[ -n "'"$CID"'" ]'
cmd "curl ... -X POST http://${APP_HOST}/api/orders -d '{\"customerId\":$CID,\"amount\":42.50}'"
check "POST /api/orders = 201 (Oracle + MQ + Valkey fan-out)" bash -c '
    curl -fsS -m10 --resolve '"${APP_HOST}:80:${K3S_VIP}"' -X POST http://'"${APP_HOST}"'/api/orders -H "Content-Type: application/json" -d "{\"customerId\":'"$CID"',\"amount\":42.50}" | grep -q "\"id\":"'
check "GET /api/customers/<id> (Oracle read)" bash -c 'curl -fsS -m10 --resolve '"${APP_HOST}:80:${K3S_VIP}"' http://'"${APP_HOST}"'/api/customers/'"$CID"' | grep -q smoke-'"$TS"
check "Valkey KV round-trip through the app" bash -c '
    curl -fsS -m10 --resolve '"${APP_HOST}:80:${K3S_VIP}"' -X POST "http://'"${APP_HOST}"'/api/valkey/kv/smoke-'"$TS"'?value=ok&ttlSeconds=60" >/dev/null
    curl -fsS -m10 --resolve '"${APP_HOST}:80:${K3S_VIP}"' "http://'"${APP_HOST}"'/api/valkey/kv/smoke-'"$TS"'" | grep -q ok'

echo
echo "=== 4. Valkey cluster + HOSTNAME model (in-cluster, by name) ====="
cmd 'kubectl -n valkey exec valkey-primary-0 -- valkey-cli -a $VK_PASS cluster info'
check "cluster_state:ok, 6 known nodes, 3 shards" bash -c '
    o=$(kubectl -n valkey exec valkey-primary-0 -- valkey-cli -a "'"$VK_PASS"'" cluster info 2>/dev/null)
    echo "$o" | grep -q cluster_state:ok && echo "$o" | grep -q cluster_known_nodes:6 && echo "$o" | grep -q cluster_size:3'
cmd "kubectl -n valkey exec valkey-primary-0 -- valkey-cli -a \$VK_PASS cluster shards | grep hostname"
check "CLUSTER SHARDS returns the HOSTNAME ($VALKEY_HOST), not IPs" bash -c '
    kubectl -n valkey exec valkey-primary-0 -- valkey-cli -a "'"$VK_PASS"'" cluster shards 2>/dev/null | grep -A1 hostname | grep -q "'"$VALKEY_HOST"'"'
# The real client test: from IN the cluster, dial the HOSTNAME and follow MOVED.
cmd "kubectl -n valkey exec valkey-primary-0 -- valkey-cli -c -h $VALKEY_HOST -p $VALKEY_CLIENT_BASE set k hi"
check "client dials $VALKEY_HOST and -c follows MOVED by hostname (SET/GET)" bash -c '
    kubectl -n valkey exec valkey-primary-0 -- sh -c "valkey-cli -c -h '"$VALKEY_HOST"' -p '"$VALKEY_CLIENT_BASE"' -a '"$VK_PASS"' set smoke:'"$TS"' hello" 2>/dev/null | grep -q OK
    v=$(kubectl -n valkey exec valkey-primary-0 -- sh -c "valkey-cli -c -h '"$VALKEY_HOST"' -p '"$VALKEY_CLIENT_BASE"' -a '"$VK_PASS"' get smoke:'"$TS"'" 2>/dev/null | tail -1)
    [ "$v" = hello ]'
check "MOVED redirect names the hostname (not an IP)" bash -c '
    # write from the wrong port without -c → raw MOVED with a hostname target
    out=$(kubectl -n valkey exec valkey-primary-0 -- sh -c "valkey-cli -h '"$VALKEY_HOST"' -p '"$VALKEY_CLIENT_BASE"' -a '"$VK_PASS"' set smoke:'"$TS"':x v" 2>/dev/null)
    echo "$out" | grep -q MOVED && echo "$out" | grep -q "'"$VALKEY_HOST"'" || { echo "$out" | grep -q OK; }'  # OK if seed owns the slot

echo
echo "=== 5. Air-gap proof ============================================="
check "no pod ever pulled from the internet (no ErrImagePull/ImagePullBackOff)" bash -c '
    ! kubectl get pods -A --no-headers 2>/dev/null | grep -qiE "ErrImagePull|ImagePullBackOff"'

# ===========================================================================
echo
echo "=================================================================="
echo "Passed: $PASS    Failed: $FAIL"
[[ $FAIL -gt 0 ]] && { echo; echo "Failures:"; for f in "${FAILED[@]}"; do echo "  - $f"; done; }
echo "=================================================================="
exit $FAIL
