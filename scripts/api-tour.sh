#!/usr/bin/env bash
#
# api-tour.sh — a narrated, runnable tour of the debug-demo API from the
# outside (your Mac), through the k3s path: keepalived VIP → ingress-nginx →
# app, all by hostname (debug-demo.local via curl --resolve). Every step PRINTS
# the exact command before running it, so the tour doubles as a copy-paste
# cookbook.
#
# Stops (pass one as an arg to jump straight there):
#   health      actuator health + per-subsystem detail
#   customers   CRUD lifecycle: create, read, update, list, delete
#   orders      the integration fan-out: one POST hits Oracle + MQ + 5 Valkey op types
#   valkey      playground endpoints: kv, stats hash, leaderboard, recent, streams, pubsub
#   batch       Spring Batch CSV load trigger
#   diag        thread dump, metrics, log-level toggling
#
# Usage:
#   ./api-tour.sh              # the full tour, in order
#   ./api-tour.sh orders       # just one stop
#   PAUSE=1 ./api-tour.sh      # wait for Enter between steps (demo mode)

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/k3s-env.sh
source "$SCRIPT_DIR/lib/k3s-env.sh" 2>/dev/null || true
set +e   # common.sh sets -e; a tour should narrate failures, not die on them

require_cmd curl python3 kubectl

# --- entry point: the keepalived VIP, reached BY HOSTNAME -------------------
# curl --resolve puts the hostname in the Host header (so ingress routes it)
# while dialing the VIP, so no Mac /etc/resolver is needed for this path.
ENTRY_IP="${K3S_VIP:-192.168.105.100}"
VIA="keepalived VIP → ingress-nginx"
HOST="${APP_HOST:-debug-demo.local}"
BASE="http://${HOST}"
CURL=(curl -fsS -m 10 --resolve "${HOST}:80:${ENTRY_IP}")

bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
dim()   { printf '\033[2m%s\033[0m\n' "$*"; }
step()  {
    echo
    bold "▶ $1"
    if [[ -n "${2:-}" ]]; then dim "  $2"; fi
    if [[ "${PAUSE:-0}" == "1" ]]; then printf '  [Enter to run] '; read -r; fi
    return 0
}
show() {  # show <curl args...> — print the command, run it, pretty-print JSON
    printf '  \033[36m$ curl %s\033[0m\n' "$*"
    local out
    if out="$("${CURL[@]}" "$@" 2>&1)"; then
        echo "$out" | python3 -m json.tool 2>/dev/null | sed 's/^/  /' || echo "$out" | sed 's/^/  /'
    else
        printf '  \033[31m(request failed)\033[0m %s\n' "$out"
        return 1
    fi
}

jsonval() { python3 -c "import json,sys; print(json.load(sys.stdin)$1)" 2>/dev/null; }

SECTION="${1:-all}"
want() { [[ "$SECTION" == "all" || "$SECTION" == "$1" ]]; }

echo "API tour — entry: ${BASE} via ${ENTRY_IP} (${VIA})"
echo "Interactive API explorer any time: ${BASE}/swagger-ui.html"

# ===========================================================================
if want health; then
    step "Health — the overall verdict" \
         "One UP aggregated from every subsystem: Oracle (db), Valkey (redis), MQ (jms), disk."
    show "$BASE/actuator/health"

    step "Liveness vs readiness — what k8s probes actually ask" \
         "Liveness = 'restart me?'; readiness = 'send me traffic?'. They can disagree."
    show "$BASE/actuator/health/liveness"
    show "$BASE/actuator/health/readiness"
fi

# ===========================================================================
if want customers; then
    TS="$(date +%s)"
    step "Create a customer (POST → 201 + Location header)" \
         "Email must be unique — Oracle enforces it with a unique constraint."
    show -X POST "$BASE/api/customers" -H 'Content-Type: application/json' \
         -d "{\"name\":\"Tour ${TS}\",\"email\":\"tour-${TS}@example.com\"}"
    CID="$("${CURL[@]}" "$BASE/api/customers" 2>/dev/null | python3 -c "
import json,sys
rows=json.load(sys.stdin)
print(max(r['id'] for r in rows))" 2>/dev/null)"

    step "Read it back — twice. Watch the cache." \
         "First GET logs 'DB hit' in the app pod; second is served from Valkey (customers::${CID}). Verify: kubectl -n debug-demo logs -l app.kubernetes.io/name=debug-demo-app --tail=20 | grep 'DB hit'"
    show "$BASE/api/customers/$CID"
    show "$BASE/api/customers/$CID"

    step "Validation is server-side — a bad email is a 400 with detail" ""
    printf '  \033[36m$ curl -X POST %s/api/customers -d {"name":"x","email":"nope"}\033[0m\n' "$BASE"
    "${CURL[@]}" -X POST "$BASE/api/customers" -H 'Content-Type: application/json' \
        -d '{"name":"x","email":"nope"}' 2>/dev/null | python3 -m json.tool 2>/dev/null | sed 's/^/  /' || true

    step "A missing id is a 404 problem body, not a stack trace" ""
    "${CURL[@]}" "$BASE/api/customers/999999" 2>/dev/null | python3 -m json.tool 2>/dev/null | sed 's/^/  /' || dim "  (404 — as expected)"
fi

# ===========================================================================
if want orders; then
    TS="$(date +%s)"
    CID="$("${CURL[@]}" -X POST "$BASE/api/customers" -H 'Content-Type: application/json' \
          -d "{\"name\":\"Fanout ${TS}\",\"email\":\"fanout-${TS}@example.com\"}" 2>/dev/null | jsonval "['id']")"

    step "Snapshot the Valkey counters BEFORE the order" \
         "So you can see exactly what one POST /api/orders touches."
    XLEN_B="$("${CURL[@]}" "$BASE/api/valkey/streams/length" 2>/dev/null | jsonval "['length']")"
    RECV_B="$("${CURL[@]}" "$BASE/api/valkey/pubsub/received" 2>/dev/null | jsonval "['received']")"
    echo "  stream XLEN=${XLEN_B}   pubsub received=${RECV_B}"

    step "POST one order — the integration fan-out" \
         "One request = Oracle INSERT + MQ publish + XADD + PUBLISH + HINCRBY + ZINCRBY + LPUSH, across 5 different Valkey shards."
    show -X POST "$BASE/api/orders" -H 'Content-Type: application/json' \
         -d "{\"customerId\":${CID},\"amount\":42.50}"
    sleep 1

    step "Now watch every side-effect land" ""
    echo "  stream grew:      XLEN $XLEN_B → $("${CURL[@]}" "$BASE/api/valkey/streams/length" 2>/dev/null | jsonval "['length']")"
    echo "  subscriber heard: received $RECV_B → $("${CURL[@]}" "$BASE/api/valkey/pubsub/received" 2>/dev/null | jsonval "['received']")"
    show "$BASE/api/valkey/stats/$CID"
    show "$BASE/api/valkey/recent?n=3"

    step "MQ got the event too" \
         "Check queue depth: kubectl -n mq exec ibm-mq-ibm-mq-0 -- bash -c 'echo \"DISPLAY QSTATUS(DEV.QUEUE.1) CURDEPTH\" | runmqsc QM1'"
fi

# ===========================================================================
if want valkey; then
    step "Direct KV — SET with TTL, then GET" \
         "Keys route to shards by CRC16(key) mod 16384; the app's Lettuce client follows MOVED transparently."
    show -X POST "$BASE/api/valkey/kv/tour-key?value=hello-from-the-tour&ttlSeconds=120"
    show "$BASE/api/valkey/kv/tour-key"

    step "Leaderboard — customers ranked by total spend (ZREVRANGE)" ""
    show "$BASE/api/valkey/leaderboard?n=5"

    step "Streams — append, length, read" \
         "Each app replica is in consumer group 'order-processors'; XADDs are distributed across replicas."
    show -X POST "$BASE/api/valkey/streams/append"
    show "$BASE/api/valkey/streams/read?count=2"
    show "$BASE/api/valkey/streams/consumed"

    step "Pub/sub — classic broadcast vs sharded" \
         "Classic PUBLISH reaches every subscriber on every node; SPUBLISH stays on the shard owning the channel's slot."
    show -X POST "$BASE/api/valkey/pubsub/publish?msg=tour-classic"
    show -X POST "$BASE/api/valkey/pubsub/spublish?msg=tour-sharded"
    show "$BASE/api/valkey/pubsub/received"
fi

# ===========================================================================
if want batch; then
    step "Spring Batch — CSV → JDBC bulk load (202 + execution id)" \
         "The chunk-oriented step commits every 1000 rows; a long run gives the debug tooling something to profile."
    show -X POST "$BASE/api/batch/customers/load"
fi

# ===========================================================================
if want diag; then
    step "Thread dump — text format, straight from actuator" \
         "This is capture path #1 (no JDK in the image). Full file: add -o dump.txt"
    printf '  \033[36m$ curl -H "Accept: text/plain" %s/actuator/threaddump | head -20\033[0m\n' "$BASE"
    "${CURL[@]}" -H 'Accept: text/plain' "$BASE/actuator/threaddump" 2>/dev/null | head -20 | sed 's/^/  /'

    step "JVM metrics — heap, GC pause, live threads" ""
    show "$BASE/actuator/metrics/jvm.memory.used?tag=area:heap"
    show "$BASE/actuator/metrics/jvm.gc.pause"

    step "Log levels at runtime — no restart" \
         "scripts/set-log-level.sh com.example.debugdemo DEBUG   (then watch: scripts/tail-logs.sh)"
fi

echo
bold "Tour done. Next stops:"
echo "  scripts/k3s-smoke.sh              full 14-check verification"
echo "  scripts/valkey-cluster-tests.sh   MOVED / ASK / failover semantics"
echo "  scripts/chaos.sh                  break things on purpose and watch"
echo "  scripts/valkey-tour.sh            the Valkey cluster from the outside"
echo "  ${BASE}/swagger-ui.html           interactive API explorer"
