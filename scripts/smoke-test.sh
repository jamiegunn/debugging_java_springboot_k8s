#!/usr/bin/env bash
#
# smoke-test.sh — end-to-end verification of the full stack.
#
# Runs from the host but does its actual work via `kubectl exec` so it doesn't
# depend on the dev VIP / host-routes.sh layer. Pass --include-external to also
# exercise the routed Mac path (requires `scripts/host-routes.sh add` first).
#
# Each check prints [PASS]/[FAIL] with detail. Exit code = number of failures.
#
# Usage:
#   ./smoke-test.sh                     # in-cluster only
#   ./smoke-test.sh --include-external  # also test via 192.168.64.50 etc.
#   ./smoke-test.sh --skip-artifactory  # don't expect artifactory Ready

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

INCLUDE_EXTERNAL=0
SKIP_ARTIFACTORY=0
for a in "$@"; do
    case "$a" in
        --include-external) INCLUDE_EXTERNAL=1 ;;
        --skip-artifactory) SKIP_ARTIFACTORY=1 ;;
        -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) err "unknown arg: $a"; exit 64 ;;
    esac
done

require_cmd kubectl curl python3

PASS_COUNT=0
FAIL_COUNT=0
FAIL_LINES=()
check() {
    local name="$1"; shift
    if "$@" >/tmp/smoke.out 2>&1; then
        printf '[PASS] %s\n' "$name"
        PASS_COUNT=$((PASS_COUNT+1))
    else
        printf '[FAIL] %s\n' "$name"
        FAIL_COUNT=$((FAIL_COUNT+1))
        FAIL_LINES+=("$name")
        sed 's/^/        /' /tmp/smoke.out | head -10
    fi
}

# ----------------------------------------------------------------------------
# Section 1: cluster + pods
# ----------------------------------------------------------------------------
echo "=== 1. Cluster + pods ============================================="

check "kubectl can reach the cluster" \
    bash -c 'kubectl get nodes >/dev/null'

check "all expected namespaces have Ready pods" \
    bash -c '
        nss="metallb-system oracle mq valkey debug-demo"
        '"$( [[ $SKIP_ARTIFACTORY -eq 0 ]] && echo 'nss="$nss artifactory"' )"'
        for ns in $nss; do
            n=$(kubectl -n "$ns" get pods --no-headers 2>/dev/null | wc -l | tr -d " ")
            r=$(kubectl -n "$ns" get pods --no-headers 2>/dev/null | awk "{split(\$2,a,\"/\"); if(a[1]==a[2] && a[1]>0) c++} END{print c+0}")
            [[ "$r" -gt 0 && "$r" -eq "$n" ]] || { echo "ns=$ns $r/$n Ready"; exit 1; }
        done
    '

# Pick the app pod once
POD=$(kubectl -n debug-demo get pod -l app.kubernetes.io/name=debug-demo-app \
        -o jsonpath='{.items[?(@.status.containerStatuses[0].ready==true)].metadata.name}' 2>/dev/null | awk '{print $1}')
if [[ -z "$POD" ]]; then
    err "no Ready app pod found; aborting"
    exit 1
fi
EXEC=(kubectl -n debug-demo exec "$POD" --)

# ----------------------------------------------------------------------------
# Section 2: actuator health (per-subsystem)
# ----------------------------------------------------------------------------
echo
echo "=== 2. Actuator health ============================================"

check "/actuator/health overall = UP" \
    bash -c '"${EXEC[@]}" curl -fsS http://localhost:8080/actuator/health | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d[\"status\"] == \"UP\", d
"'

# The composite endpoint sets show-details based on auth, but liveness/readiness
# are always accessible without details.
check "/actuator/health/liveness = UP" \
    bash -c '"${EXEC[@]}" curl -fsS http://localhost:8080/actuator/health/liveness | grep -q UP'
check "/actuator/health/readiness = UP" \
    bash -c '"${EXEC[@]}" curl -fsS http://localhost:8080/actuator/health/readiness | grep -q UP'

# ----------------------------------------------------------------------------
# Section 3: CRUD + cache + integration fan-out
# ----------------------------------------------------------------------------
echo
echo "=== 3. Business flow (Oracle + MQ + Valkey fan-out) ==============="

UNIQ=$(date -u +%s)
EMAIL="smoke-${UNIQ}@example.com"

CREATE_RESP=$("${EXEC[@]}" curl -fsS -X POST -H 'Content-Type: application/json' \
              -d "{\"name\":\"Smoke ${UNIQ}\",\"email\":\"${EMAIL}\"}" \
              http://localhost:8080/api/customers 2>/dev/null)
CID=$(echo "$CREATE_RESP" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])' 2>/dev/null || echo "")
check "POST /api/customers returns id" \
    bash -c '[[ -n "'"$CID"'" ]] && echo "id=$CID"'

# Snapshot MQ depth + XLEN before the order so we can verify they grow
MQ_PASS="$(kubectl -n mq get secret ibm-mq-ibm-mq -o jsonpath='{.data.MQ_APP_PASSWORD}' 2>/dev/null | base64 -d 2>/dev/null || true)"
DEPTH_BEFORE=$(kubectl -n mq exec ibm-mq-ibm-mq-0 -- bash -c "echo 'DISPLAY QSTATUS(DEV.QUEUE.1) CURDEPTH' | runmqsc QM1 2>/dev/null" 2>/dev/null \
                | grep -oE 'CURDEPTH\([0-9]+\)' | head -1 | grep -oE '[0-9]+' || echo 0)
DEPTH_BEFORE=${DEPTH_BEFORE:-0}

XLEN_BEFORE=$("${EXEC[@]}" curl -fsS http://localhost:8080/api/valkey/streams/length 2>/dev/null \
               | python3 -c 'import json,sys; print(json.load(sys.stdin)["length"])' 2>/dev/null || echo 0)
PUBSUB_BEFORE=$("${EXEC[@]}" curl -fsS http://localhost:8080/api/valkey/pubsub/received 2>/dev/null \
                | python3 -c 'import json,sys; print(json.load(sys.stdin)["received"])' 2>/dev/null || echo 0)

ORDER_RESP=$("${EXEC[@]}" curl -fsS -X POST -H 'Content-Type: application/json' \
             -d "{\"customerId\":${CID},\"amount\":42.50}" \
             http://localhost:8080/api/orders 2>/dev/null)
OID=$(echo "$ORDER_RESP" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])' 2>/dev/null || echo "")
check "POST /api/orders returns id (Oracle write)" \
    bash -c '[[ -n "'"$OID"'" ]] && echo "id=$OID"'

# Give the pubsub listener a tick to receive
sleep 1

# Verify Oracle persisted
check "GET /api/customers/<id> returns the row (Oracle read)" \
    bash -c '"${EXEC[@]}" curl -fsS http://localhost:8080/api/customers/'"$CID"' | grep -q "'"$EMAIL"'"'

# Verify cache eviction → fresh read populates again. Hit twice, expect 1 DB-hit log.
"${EXEC[@]}" curl -fsS http://localhost:8080/api/customers/$CID >/dev/null
"${EXEC[@]}" curl -fsS http://localhost:8080/api/customers/$CID >/dev/null
HITS=$(kubectl -n debug-demo logs "$POD" --tail=300 2>/dev/null | grep -c "DB hit: loading customer id=$CID" || true)
check "Spring Cache: 2 GETs → exactly 1 DB-hit log (first hits DB, second is cache hit)" \
    bash -c '[[ "'"$HITS"'" -eq 1 ]] && echo "hits=$HITS"'

# Verify MQ depth grew
DEPTH_AFTER=$(kubectl -n mq exec ibm-mq-ibm-mq-0 -- bash -c "echo 'DISPLAY QSTATUS(DEV.QUEUE.1) CURDEPTH' | runmqsc QM1 2>/dev/null" 2>/dev/null \
              | grep -oE 'CURDEPTH\([0-9]+\)' | head -1 | grep -oE '[0-9]+' || echo 0)
DEPTH_AFTER=${DEPTH_AFTER:-0}
check "IBM MQ DEV.QUEUE.1 CURDEPTH grew by 1 (was ${DEPTH_BEFORE}, now ${DEPTH_AFTER})" \
    bash -c '[[ "'"$DEPTH_AFTER"'" -gt "'"$DEPTH_BEFORE"'" ]]'

# ----------------------------------------------------------------------------
# Section 4: Valkey op coverage (every type)
# ----------------------------------------------------------------------------
echo
echo "=== 4. Valkey ops ================================================="

XLEN_AFTER=$("${EXEC[@]}" curl -fsS http://localhost:8080/api/valkey/streams/length 2>/dev/null \
             | python3 -c 'import json,sys; print(json.load(sys.stdin)["length"])' 2>/dev/null || echo 0)
check "Stream XLEN grew by 1 (was ${XLEN_BEFORE}, now ${XLEN_AFTER})" \
    bash -c '[[ "'"$XLEN_AFTER"'" -gt "'"$XLEN_BEFORE"'" ]]'

check "Hash: customer:stats:{${CID}} populated by HINCRBY/HSET" \
    bash -c '"${EXEC[@]}" curl -fsS http://localhost:8080/api/valkey/stats/'"$CID"' | python3 -c "
import json, sys
d = json.load(sys.stdin)
s = d[\"stats\"]
assert int(s[\"order_count\"]) >= 1, s
assert float(s[\"total_spend\"]) >= 42.50, s
assert s[\"last_order_at\"], s
"'

check "Sorted set: customer ${CID} present in customers:top leaderboard" \
    bash -c '"${EXEC[@]}" curl -fsS http://localhost:8080/api/valkey/leaderboard?n=50 | python3 -c "
import json, sys
e = json.load(sys.stdin)
assert any(x[\"customerId\"] == '"$CID"' for x in e), e
"'

check "List: orders:recent contains order ${OID}" \
    bash -c '"${EXEC[@]}" curl -fsS http://localhost:8080/api/valkey/recent?n=50 | python3 -c "
import json, sys
e = json.load(sys.stdin)[\"entries\"]
assert any(x.startswith(\"'"$OID"',\") for x in e), e
"'

PUBSUB_AFTER=$("${EXEC[@]}" curl -fsS http://localhost:8080/api/valkey/pubsub/received 2>/dev/null \
               | python3 -c 'import json,sys; print(json.load(sys.stdin)["received"])' 2>/dev/null || echo 0)
check "Classic pub/sub: subscriber received counter grew (was ${PUBSUB_BEFORE}, now ${PUBSUB_AFTER})" \
    bash -c '[[ "'"$PUBSUB_AFTER"'" -gt "'"$PUBSUB_BEFORE"'" ]]'

check "Sharded SPUBLISH returns a subscriber count (0 is fine, just must not 500)" \
    bash -c '"${EXEC[@]}" curl -fsS -X POST "http://localhost:8080/api/valkey/pubsub/spublish?msg=smoke" | grep -q deliveredTo'

check "SET / GET via playground (cluster shard routing)" \
    bash -c '
        "${EXEC[@]}" curl -fsS -X POST "http://localhost:8080/api/valkey/kv/smoke-key?value=smoke-val&ttlSeconds=60" >/dev/null
        v=$("${EXEC[@]}" curl -fsS "http://localhost:8080/api/valkey/kv/smoke-key" | python3 -c "import json,sys; print(json.load(sys.stdin)[\"value\"])")
        [[ "$v" == "smoke-val" ]]
    '

# Valkey cluster sanity
VK_PASS="$(kubectl -n valkey get secret valkey -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null)"
check "Valkey cluster_state = ok with 6 known nodes" \
    bash -c '
        out=$(kubectl -n valkey exec valkey-primary-0 -- valkey-cli -a "'"$VK_PASS"'" cluster info 2>/dev/null | grep -v Warning)
        echo "$out" | grep -q "cluster_state:ok" && echo "$out" | grep -q "cluster_known_nodes:6"
    '

check "Valkey cluster-announce-ip points at external LB IPs (not pod IPs)" \
    bash -c '
        ips=$(kubectl -n valkey exec valkey-primary-0 -- valkey-cli -a "'"$VK_PASS"'" cluster nodes 2>/dev/null | grep -v Warning | awk "{print \$2}" | cut -d: -f1)
        # all 6 IPs should match 192.168.64.5x
        echo "$ips" | grep -cE "^192\.168\.64\.5[1-6]$" | grep -qx 6
    '

# ----------------------------------------------------------------------------
# Section 5: HPA + diagnostics
# ----------------------------------------------------------------------------
echo
echo "=== 5. HPA + diagnostics =========================================="

check "HPA present and reporting CPU metric" \
    bash -c '
        kubectl -n debug-demo get hpa app-debug-demo-app -o jsonpath="{.status.currentMetrics[0].resource.current.averageUtilization}" 2>/dev/null \
            | grep -qE "^[0-9]+$"
    '

check "scripts/memory-report.sh runs cleanly" \
    bash -c '"'"$SCRIPT_DIR"'/memory-report.sh" -n debug-demo > /tmp/smoke.memreport 2>&1 && grep -q "RSS / limit" /tmp/smoke.memreport'

check "/actuator/threaddump returns >100 lines of text" \
    bash -c '"${EXEC[@]}" curl -fsS -H "Accept: text/plain" http://localhost:8080/actuator/threaddump | wc -l | awk "{exit !(\$1>100)}"'

# ----------------------------------------------------------------------------
# Section 6: external path (optional)
# ----------------------------------------------------------------------------
if [[ $INCLUDE_EXTERNAL -eq 1 ]]; then
    echo
    echo "=== 6. External access (192.168.64.x via host-routes) ============"

    check "App reachable at http://192.168.64.50:8080/actuator/health" \
        bash -c 'curl -fsS -m 5 http://192.168.64.50:8080/actuator/health | grep -q UP'

    if command -v valkey-cli >/dev/null 2>&1 || command -v redis-cli >/dev/null 2>&1; then
        CLI=$(command -v valkey-cli || command -v redis-cli)
        check "Valkey PONG via 192.168.64.51:6379 (seed → MOVED redirect handling)" \
            bash -c '$CLI -h 192.168.64.51 -p 6379 -a "'"$VK_PASS"'" --no-auth-warning ping 2>&1 | grep -q PONG'

        check "Cluster-aware SET/GET via per-pod LBs (-c follows MOVED to externally-reachable IPs)" \
            bash -c '
                $CLI -c -h 192.168.64.51 -p 6379 -a "'"$VK_PASS"'" --no-auth-warning set smoke-ext yes 2>&1 | grep -q OK
                v=$($CLI -c -h 192.168.64.52 -p 6379 -a "'"$VK_PASS"'" --no-auth-warning get smoke-ext 2>&1 | tail -1)
                [[ "$v" == "yes" ]]
            '
    else
        echo "[SKIP] no valkey-cli/redis-cli on PATH (install with: brew install valkey)"
    fi
fi

# ----------------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------------
echo
echo "=================================================================="
echo "Passed: $PASS_COUNT    Failed: $FAIL_COUNT"
if [[ $FAIL_COUNT -gt 0 ]]; then
    echo
    echo "Failures:"
    for line in "${FAIL_LINES[@]}"; do echo "  - $line"; done
fi
echo "=================================================================="
exit $FAIL_COUNT
