#!/usr/bin/env bash
#
# smoke-test.sh — end-to-end verification of the full stack.
#
# Runs both in-cluster checks (via `kubectl exec`) AND external-path checks
# (from the Mac, through the HAProxy VM for L7 and the MetalLB LoadBalancer
# endpoints for L4). External tests always run — if the HAProxy VM isn't up
# or the Valkey routes aren't installed, those tests fail with clear signal.
# There is no opt-out flag; the whole point is to verify the whole path.
#
# The Valkey L4 section explicitly exercises MOVED redirect semantics for
# GET/SET, XADD (streams), and SPUBLISH (sharded pub/sub), because that's
# the specific behavior our per-pod-Service topology exists to make work.
# Endpoints are discovered from the valkey-*-ext Services, so the tests work
# in both endpoint modes: sharedIP-perPort (one IP, ports 6379-6384) and
# legacy perPodIP (six IPs, one port).
#
# Each check prints [PASS]/[FAIL] with detail. Exit code = number of failures.
#
# Usage:
#   ./smoke-test.sh                     # everything (default)
#   ./smoke-test.sh --skip-artifactory  # don't expect artifactory Ready

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

SKIP_ARTIFACTORY=0
for a in "$@"; do
    case "$a" in
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

check "each expected namespace has its minimum Ready pod count" \
    bash -c '
        # Format: <namespace>:<min-ready>. Debug-demo is 1 (not the full
        # replica count) because the smoke test triggers HPA scale-up mid-run
        # and new pods may still be starting — as long as at least one is
        # Ready, the tests can run. Everything else is a StatefulSet or
        # DaemonSet with a fixed count.
        entries="metallb-system:2 ingress-nginx:1 oracle:1 mq:1 valkey:6 debug-demo:1"
        '"$( [[ $SKIP_ARTIFACTORY -eq 0 ]] && echo 'entries="$entries artifactory:1"' )"'
        for entry in $entries; do
            ns="${entry%%:*}"
            min="${entry##*:}"
            r=$(kubectl -n "$ns" get pods --no-headers 2>/dev/null | awk "{split(\$2,a,\"/\"); if(a[1]==a[2] && a[1]>0) c++} END{print c+0}")
            n=$(kubectl -n "$ns" get pods --no-headers 2>/dev/null | wc -l | tr -d " ")
            if [[ "$r" -lt "$min" ]]; then
                echo "ns=$ns $r/$n Ready — need at least $min"; exit 1
            fi
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
# kx(): same thing, callable from inside `bash -c` (arrays don't propagate, but
# `export -f` does). Use kx in bash -c checks; use kx elsewhere.
export POD
kx() { kubectl -n debug-demo exec "$POD" -- "$@"; }
export -f kx

# ----------------------------------------------------------------------------
# Section 2: actuator health (per-subsystem)
# ----------------------------------------------------------------------------
echo
echo "=== 2. Actuator health ============================================"

check "/actuator/health overall = UP" \
    bash -c 'kx curl -fsS http://localhost:8080/actuator/health | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d[\"status\"] == \"UP\", d
"'

# The composite endpoint sets show-details based on auth, but liveness/readiness
# are always accessible without details.
check "/actuator/health/liveness = UP" \
    bash -c 'kx curl -fsS http://localhost:8080/actuator/health/liveness | grep -q UP'
check "/actuator/health/readiness = UP" \
    bash -c 'kx curl -fsS http://localhost:8080/actuator/health/readiness | grep -q UP'

# OpenAPI / Swagger UI (springdoc) — verify the spec is generated and the UI is served.
check "/v3/api-docs returns OpenAPI 3 with the 4 controller tags" \
    bash -c 'kx curl -fsS http://localhost:8080/v3/api-docs | python3 -c "
import json,sys
d = json.load(sys.stdin)
tags = {t[\"name\"] for t in d.get(\"tags\", [])}
need = {\"customers\", \"orders\", \"batch\", \"valkey\"}
missing = need - tags
assert d.get(\"openapi\", \"\").startswith(\"3.\"), \"not OpenAPI 3.x: \" + d.get(\"openapi\", \"?\")
assert not missing, \"missing tags: \" + str(missing)
"'
check "/swagger-ui.html → /swagger-ui/index.html (302)" \
    bash -c 'kx curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/swagger-ui.html | grep -q 302'
check "/swagger-ui/index.html serves the UI (200)" \
    bash -c 'kx curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/swagger-ui/index.html | grep -q 200'

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
    bash -c 'kx curl -fsS http://localhost:8080/api/customers/'"$CID"' | grep -q "'"$EMAIL"'"'

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
    bash -c 'kx curl -fsS http://localhost:8080/api/valkey/stats/'"$CID"' | python3 -c "
import json, sys
d = json.load(sys.stdin)
s = d[\"stats\"]
assert int(s[\"order_count\"]) >= 1, s
assert float(s[\"total_spend\"]) >= 42.50, s
assert s[\"last_order_at\"], s
"'

check "Sorted set: customer ${CID} present in customers:top leaderboard" \
    bash -c 'kx curl -fsS http://localhost:8080/api/valkey/leaderboard?n=50 | python3 -c "
import json, sys
e = json.load(sys.stdin)
assert any(x[\"customerId\"] == '"$CID"' for x in e), e
"'

check "List: orders:recent contains order ${OID}" \
    bash -c 'kx curl -fsS http://localhost:8080/api/valkey/recent?n=50 | python3 -c "
import json, sys
e = json.load(sys.stdin)[\"entries\"]
assert any(x.startswith(\"'"$OID"',\") for x in e), e
"'

PUBSUB_AFTER=$("${EXEC[@]}" curl -fsS http://localhost:8080/api/valkey/pubsub/received 2>/dev/null \
               | python3 -c 'import json,sys; print(json.load(sys.stdin)["received"])' 2>/dev/null || echo 0)
check "Classic pub/sub: subscriber received counter grew (was ${PUBSUB_BEFORE}, now ${PUBSUB_AFTER})" \
    bash -c '[[ "'"$PUBSUB_AFTER"'" -gt "'"$PUBSUB_BEFORE"'" ]]'

check "Sharded SPUBLISH returns a subscriber count (0 is fine, just must not 500)" \
    bash -c 'kx curl -fsS -X POST "http://localhost:8080/api/valkey/pubsub/spublish?msg=smoke" | grep -q deliveredTo'

check "SET / GET via playground (cluster shard routing)" \
    bash -c '
        kx curl -fsS -X POST "http://localhost:8080/api/valkey/kv/smoke-key?value=smoke-val&ttlSeconds=60" >/dev/null
        v=$(kx curl -fsS "http://localhost:8080/api/valkey/kv/smoke-key" | python3 -c "import json,sys; print(json.load(sys.stdin)[\"value\"])")
        [[ "$v" == "smoke-val" ]]
    '

# Valkey cluster sanity
VK_PASS="$(kubectl -n valkey get secret valkey -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null)"
check "Valkey cluster_state = ok with 6 known nodes" \
    bash -c '
        out=$(kubectl -n valkey exec valkey-primary-0 -- valkey-cli -a "'"$VK_PASS"'" cluster info 2>/dev/null | grep -v Warning)
        echo "$out" | grep -q "cluster_state:ok" && echo "$out" | grep -q "cluster_known_nodes:6"
    '

# Discover the external endpoints from the valkey-*-ext LoadBalancer Services.
# In sharedIP-perPort mode this yields one IP with 6 distinct client ports;
# in perPodIP mode, 6 IPs with the same port. Everything downstream (announce
# check here, section 7 MOVED tests) keys off these ip:port pairs, so the
# tests are endpoint-shape agnostic.
VK_ALL_EPS=""       # all 6 nodes,     "ip:port ip:port ..."
VK_PRIMARY_EPS=""   # primaries only,  same format
for role in primary secondary; do
    for i in 0 1 2; do
        ip=$(kubectl -n valkey get svc "valkey-${role}-${i}-ext" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
        port=$(kubectl -n valkey get svc "valkey-${role}-${i}-ext" -o jsonpath='{.spec.ports[?(@.name=="client")].port}' 2>/dev/null)
        [[ -n "$ip" && -n "$port" ]] || continue
        VK_ALL_EPS="${VK_ALL_EPS:+$VK_ALL_EPS }${ip}:${port}"
        [[ "$role" == "primary" ]] && VK_PRIMARY_EPS="${VK_PRIMARY_EPS:+$VK_PRIMARY_EPS }${ip}:${port}"
    done
done
export VK_ALL_EPS VK_PRIMARY_EPS

check "Valkey ext Services: 6 LoadBalancer endpoints assigned by MetalLB" \
    bash -c 'n=$(echo "$VK_ALL_EPS" | wc -w | tr -d " "); [[ "$n" == "6" ]] || { echo "have: $VK_ALL_EPS"; exit 1; }'

check "Valkey cluster-announce address of every node is an external LB endpoint (not a pod IP)" \
    bash -c '
        addrs=$(kubectl -n valkey exec valkey-primary-0 -- valkey-cli -a "'"$VK_PASS"'" cluster nodes 2>/dev/null | grep -v Warning | awk "{split(\$2,a,\"@\"); print a[1]}")
        for addr in $addrs; do
            case " $VK_ALL_EPS " in
                *" $addr "*) ;;
                *) echo "node announces $addr — not one of: $VK_ALL_EPS"; exit 1 ;;
            esac
        done
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
    bash -c 'kx curl -fsS -H "Accept: text/plain" http://localhost:8080/actuator/threaddump | wc -l | awk "{exit !(\$1>100)}"'

# ----------------------------------------------------------------------------
# Section 6: external path (always runs — the whole point is proving both work)
# ----------------------------------------------------------------------------
echo
echo "=== 6. External access ==========================================="

# Discover the HTTP entry-point IP. With the F5 stand-in installed it's
# the HAProxy VM IP (cached by install-haproxy-vm.sh). Without it, we
# fall back to the RD node ExternalIP (hostNetwork pod binds there).
HAPROXY_VM_IP_FILE="$REPO_ROOT/dumps/haproxy-vm-ip"
if [[ -f "$HAPROXY_VM_IP_FILE" ]] && curl -fsS -m 3 -o /dev/null "http://$(cat "$HAPROXY_VM_IP_FILE")/healthz" 2>/dev/null; then
    HTTP_ENTRY_IP="$(cat "$HAPROXY_VM_IP_FILE")"
    HTTP_ENTRY_VIA="HAProxy VM (F5 stand-in)"
else
    HTTP_ENTRY_IP="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="ExternalIP")].address}' 2>/dev/null)"
    HTTP_ENTRY_VIA="RD node ExternalIP (hostNetwork direct — no F5 stand-in)"
fi
export HTTP_ENTRY_IP
echo "    L7 path: http://debug-demo.local  →  ${HTTP_ENTRY_IP} (${HTTP_ENTRY_VIA})  →  ingress-nginx → app"
echo "    L4 path: ${VK_ALL_EPS:-<no valkey LB endpoints assigned>}  →  Valkey per-pod Services (MetalLB)"

# Pattern D check — ingress-nginx pod must be hostNetwork=true
check "Pattern D — ingress-nginx pod runs with hostNetwork=true" \
    bash -c 'kubectl -n ingress-nginx get pod -l app.kubernetes.io/name=ingress-nginx -o jsonpath="{.items[0].spec.hostNetwork}" | grep -q "^true$"'

# If the HAProxy stand-in is in play, confirm the VM is up
if [[ "$HTTP_ENTRY_VIA" == "HAProxy VM (F5 stand-in)" ]]; then
    check "HAProxy F5 stand-in VM (Lima 'debug-demo-haproxy') is Running" \
        bash -c 'limactl list --format=json | python3 -c "
import json,sys
for ln in sys.stdin:
    try: v=json.loads(ln.strip())
    except: continue
    if v.get(\"name\")==\"debug-demo-haproxy\" and v.get(\"status\")==\"Running\":
        sys.exit(0)
sys.exit(1)
"'
    check "HAProxy stats endpoint reachable — http://${HTTP_ENTRY_IP}:8404/" \
        bash -c 'curl -s -o /dev/null -w "%{http_code}" -m 5 "http://${HTTP_ENTRY_IP}:8404/" | grep -qE "^(200|301|302)$"'
fi

# L7 — HTTP through HAProxy VM → hostNetwork ingress
check "App reachable via L7 — http://debug-demo.local/actuator/health" \
    bash -c 'curl -fsS -m 5 --resolve "debug-demo.local:80:${HTTP_ENTRY_IP}" http://debug-demo.local/actuator/health | grep -q UP'

check "API CRUD reachable via L7 — POST /api/customers" \
    bash -c '
        ts=$(date -u +%s)
        curl -fsS -m 5 --resolve "debug-demo.local:80:${HTTP_ENTRY_IP}" \
             -X POST http://debug-demo.local/api/customers \
             -H "Content-Type: application/json" \
             -d "{\"name\":\"smoke-ext-$ts\",\"email\":\"smoke-ext-$ts@example.com\"}" \
             | grep -q "\"id\":"
    '

# Better proof that an L7 ingress controller (not a raw L4 LB) is doing the
# routing: host-based routing returns 404 for an unknown Host header.
check "L7 host-based routing — wrong Host returns 404, right Host returns 200" \
    bash -c '
        wrong=$(curl -s -o /dev/null -w "%{http_code}" -m 5 --resolve "other.example.com:80:${HTTP_ENTRY_IP}" http://other.example.com/actuator/health)
        right=$(curl -s -o /dev/null -w "%{http_code}" -m 5 --resolve "debug-demo.local:80:${HTTP_ENTRY_IP}" http://debug-demo.local/actuator/health)
        [[ "$wrong" == "404" && "$right" == "200" ]] || { echo "wrong=$wrong right=$right"; exit 1; }
    '

check "Swagger UI reachable via L7 — /swagger-ui/index.html = 200" \
    bash -c '
        code=$(curl -s -o /dev/null -w "%{http_code}" -m 5 --resolve "debug-demo.local:80:${HTTP_ENTRY_IP}" http://debug-demo.local/swagger-ui/index.html)
        [[ "$code" == "200" ]] || { echo "code=$code"; exit 1; }
    '

check "Ingress resource bound to nginx ingress class" \
    bash -c 'kubectl -n debug-demo get ingress app-debug-demo-app -o jsonpath="{.spec.ingressClassName}" | grep -q nginx'

# ----------------------------------------------------------------------------
# Section 7: Valkey MOVED semantics via L4 LoadBalancer endpoints
# ----------------------------------------------------------------------------
# This is the whole point of the per-pod-Service topology + cluster-announce —
# external clients receive MOVED redirects that point at externally-reachable
# per-shard endpoints. In sharedIP-perPort mode the redirect target differs by
# PORT (same IP); in perPodIP mode it differs by IP (same port). Either way,
# the ip:port must land on exactly one node. We verify explicitly for each op
# type that gets MOVED (GET/SET, XADD, SPUBLISH), and confirm classic PUBLISH
# does NOT (it broadcasts on the cluster bus).
# ----------------------------------------------------------------------------
echo
echo "=== 7. Valkey L4 + MOVED semantics ==============================="

if ! command -v valkey-cli >/dev/null 2>&1 && ! command -v redis-cli >/dev/null 2>&1; then
    echo "[SKIP] no valkey-cli/redis-cli on PATH (install with: brew install valkey)"
    FAIL_COUNT=$((FAIL_COUNT+1))
    FAIL_LINES+=("valkey-cli/redis-cli not on PATH — cannot run L4 MOVED tests")
elif [[ -z "$VK_PRIMARY_EPS" ]]; then
    echo "[SKIP] no valkey LB endpoints assigned — cannot run L4 MOVED tests"
    FAIL_COUNT=$((FAIL_COUNT+1))
    FAIL_LINES+=("valkey-*-ext Services have no LoadBalancer IPs — MetalLB not fulfilling them?")
else
    CLI=$(command -v valkey-cli || command -v redis-cli)
    SEED_EP="${VK_PRIMARY_EPS%% *}"
    SEED_HOST="${SEED_EP%%:*}"
    SEED_PORT="${SEED_EP##*:}"
    export CLI VK_PASS SEED_EP SEED_HOST SEED_PORT

    # Basic reachability first — if this fails, all downstream tests will fail
    # for the same reason (routes missing / MetalLB IP not reachable) and the
    # signal is more useful up front.
    check "Valkey PONG via L4 — ${SEED_EP} (MetalLB LB endpoint)" \
        bash -c '"$CLI" -h "$SEED_HOST" -p "$SEED_PORT" -a "$VK_PASS" --no-auth-warning ping 2>&1 | grep -q PONG'

    # Announce check from the OUTSIDE: every primary must announce one of the
    # external LB endpoints, not its internal pod IP:port — otherwise MOVED
    # redirects would point at addresses external clients can't dial.
    check "Every primary announces an external LB endpoint (seen from outside the cluster)" \
        bash -c '
            addrs=$("$CLI" -h "$SEED_HOST" -p "$SEED_PORT" -a "$VK_PASS" --no-auth-warning cluster nodes 2>&1 \
                | awk "/master/ { split(\$2, a, \"@\"); print a[1] }")
            for addr in $addrs; do
                case " $VK_ALL_EPS " in
                    *" $addr "*) ;;
                    *) echo "primary announces $addr — not one of: $VK_ALL_EPS"; exit 1 ;;
                esac
            done
        '

    # ------------------------------------------------------------------------
    # Helper: compute (OWNER, WRONG) endpoints for a given key/channel/stream.
    # OWNER is the ip:port of the primary that owns the slot; WRONG is any
    # OTHER primary's endpoint. All exported so `bash -c` subshells see them.
    # ------------------------------------------------------------------------
    moved_setup() {
        local key="$1"
        local slot
        slot=$("$CLI" -h "$SEED_HOST" -p "$SEED_PORT" -a "$VK_PASS" --no-auth-warning cluster keyslot "$key")
        OWNER_EP=$("$CLI" -h "$SEED_HOST" -p "$SEED_PORT" -a "$VK_PASS" --no-auth-warning cluster nodes 2>/dev/null \
            | awk -v s="$slot" '
                /master/ {
                    for (i=9; i<=NF; i++) {
                        split($i, r, "-")
                        if (r[1]+0 <= s+0 && r[2]+0 >= s+0) {
                            split($2, addr, "@")
                            print addr[1]
                            exit
                        }
                    }
                }')
        WRONG_EP=""
        for ep in $VK_PRIMARY_EPS; do
            if [[ "$ep" != "$OWNER_EP" ]]; then WRONG_EP=$ep; break; fi
        done
        OWNER_HOST="${OWNER_EP%%:*}"; OWNER_PORT="${OWNER_EP##*:}"
        WRONG_HOST="${WRONG_EP%%:*}"; WRONG_PORT="${WRONG_EP##*:}"
        export OWNER_EP OWNER_HOST OWNER_PORT WRONG_EP WRONG_HOST WRONG_PORT
    }

    # Fixed per-run suffix so every check sees the same key/channel/stream name.
    # `$$` inside `bash -c` expands to the CHILD bash's pid, which changes on
    # each invocation — using it as a suffix would give each check a different
    # key that hashes to a different slot, defeating the whole point.
    SMOKE_SUFFIX="$$-$(date +%s)"
    export SMOKE_SUFFIX

    # ---- GET/SET MOVED --------------------------------------------------
    MOVED_KEY="smoke-moved-getset-${SMOKE_SUFFIX}"
    moved_setup "$MOVED_KEY"
    export MOVED_KEY
    check "MOVED-GET/SET: raw MOVED response when hitting the wrong node (no -c flag)" \
        bash -c '
            out=$("$CLI" -h "$WRONG_HOST" -p "$WRONG_PORT" -a "$VK_PASS" --no-auth-warning set "$MOVED_KEY" v 2>&1)
            # Expect: "(error) MOVED <slot> <owner-ip>:<owner-port>"
            if [[ "$out" != *"MOVED"* ]]; then
                echo "expected MOVED in response, got: $out"; exit 1
            fi
            if [[ "$out" != *"$OWNER_EP"* ]]; then
                echo "MOVED did not point at expected owner $OWNER_EP: $out"; exit 1
            fi
        '
    check "MOVED-GET/SET: with -c the client follows MOVED to the owner and SET succeeds" \
        bash -c '
            "$CLI" -c -h "$WRONG_HOST" -p "$WRONG_PORT" -a "$VK_PASS" --no-auth-warning set "$MOVED_KEY" hello 2>&1 | grep -q OK
        '
    check "MOVED-GET/SET: GET from ANOTHER wrong node also -c-follows and returns the value" \
        bash -c '
            # Use a different non-owner seed to prove the client can chase
            # MOVED from any node (3 primaries -> at least 2 non-owners).
            SEED2=""
            for ep in $VK_PRIMARY_EPS; do
                [[ "$ep" != "$OWNER_EP" && "$ep" != "$WRONG_EP" ]] && { SEED2=$ep; break; }
            done
            [[ -n "$SEED2" ]] || SEED2=$WRONG_EP
            v=$("$CLI" -c -h "${SEED2%%:*}" -p "${SEED2##*:}" -a "$VK_PASS" --no-auth-warning get "$MOVED_KEY" 2>&1 | tail -1)
            [[ "$v" == "hello" ]] || { echo "expected hello, got: $v"; exit 1; }
        '

    # ---- XADD (stream) MOVED --------------------------------------------
    MOVED_STREAM="smoke-moved-stream-${SMOKE_SUFFIX}"
    moved_setup "$MOVED_STREAM"
    export MOVED_STREAM
    check "MOVED-XADD: raw MOVED response when adding to a stream from the wrong node" \
        bash -c '
            out=$("$CLI" -h "$WRONG_HOST" -p "$WRONG_PORT" -a "$VK_PASS" --no-auth-warning xadd "$MOVED_STREAM" "*" k v 2>&1)
            if [[ "$out" != *"MOVED"* ]]; then
                echo "expected MOVED, got: $out"; exit 1
            fi
            [[ "$out" == *"$OWNER_EP"* ]] || { echo "MOVED did not point at owner $OWNER_EP: $out"; exit 1; }
        '
    check "MOVED-XADD: with -c the client follows MOVED, XADD lands, XLEN=1 at owner" \
        bash -c '
            "$CLI" -c -h "$WRONG_HOST" -p "$WRONG_PORT" -a "$VK_PASS" --no-auth-warning xadd "$MOVED_STREAM" "*" event smoke 2>&1 | grep -qE "[0-9]+-[0-9]+"
            n=$("$CLI" -h "$OWNER_HOST" -p "$OWNER_PORT" -a "$VK_PASS" --no-auth-warning xlen "$MOVED_STREAM" 2>&1 | tail -1)
            [[ "$n" == "1" ]] || { echo "expected XLEN=1 at owner, got: $n"; exit 1; }
        '

    # ---- SPUBLISH (sharded pub/sub) MOVED -------------------------------
    # Sharded channels hash to a slot exactly like keys; SPUBLISH from a
    # non-owner returns MOVED with the owner's address. This is different
    # from classic PUBLISH which broadcasts on the cluster bus (below).
    MOVED_CH="{orders}:sharded-moved-${SMOKE_SUFFIX}"
    moved_setup "$MOVED_CH"
    export MOVED_CH
    check "MOVED-SPUBLISH: raw MOVED response when publishing to a sharded channel from wrong node" \
        bash -c '
            out=$("$CLI" -h "$WRONG_HOST" -p "$WRONG_PORT" -a "$VK_PASS" --no-auth-warning spublish "$MOVED_CH" hello 2>&1)
            if [[ "$out" != *"MOVED"* ]]; then
                echo "expected MOVED, got: $out"; exit 1
            fi
            [[ "$out" == *"$OWNER_EP"* ]] || { echo "MOVED did not point at owner $OWNER_EP: $out"; exit 1; }
        '
    check "MOVED-SPUBLISH: publishing directly to the owning shard succeeds (returns subscriber count)" \
        bash -c '
            out=$("$CLI" -h "$OWNER_HOST" -p "$OWNER_PORT" -a "$VK_PASS" --no-auth-warning spublish "$MOVED_CH" hello 2>&1 | tail -1)
            # SPUBLISH returns the number of receiving subscribers as an integer
            [[ "$out" =~ ^[0-9]+$ ]] || { echo "expected integer, got: $out"; exit 1; }
        '

    # ---- PUBLISH (classic pub/sub) does NOT get MOVED -------------------
    # Control test: classic PUBLISH broadcasts on the cluster bus. Any node
    # accepts it, no MOVED redirect. This is why classic pub/sub works
    # without hash-tagged channels — every subscriber on every node sees it.
    check "Classic PUBLISH: NO MOVED — any node accepts and returns a subscriber count" \
        bash -c '
            for ep in $VK_PRIMARY_EPS; do
                out=$("$CLI" -h "${ep%%:*}" -p "${ep##*:}" -a "$VK_PASS" --no-auth-warning publish orders:notifications hi 2>&1 | tail -1)
                if [[ "$out" == *"MOVED"* ]]; then echo "classic PUBLISH got MOVED on $ep: $out"; exit 1; fi
                [[ "$out" =~ ^[0-9]+$ ]] || { echo "expected int from PUBLISH on $ep, got: $out"; exit 1; }
            done
        '
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
