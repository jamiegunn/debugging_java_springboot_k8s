#!/usr/bin/env bash
#
# test-external-access.sh — end-to-end check that external clients (running
# on this Mac, NOT in the cluster) can reach the app and the Valkey cluster
# through their MetalLB-assigned IPs.
#
# Prereqs:
#   - scripts/host-routes.sh add   (the static routes for the LB IPs)
#   - The valkey-cli or redis-cli command on PATH (brew install valkey or redis)
#
# Usage:
#   ./test-external-access.sh

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_cmd kubectl curl

APP_IP="${APP_IP:-192.168.64.50}"
APP_PORT="${APP_PORT:-8080}"
SEED_IP="${SEED_IP:-192.168.64.51}"
SEED_PORT="${SEED_PORT:-6379}"

VALKEY_CLI="$(command -v valkey-cli || command -v redis-cli || true)"
PASS="$(kubectl -n valkey get secret valkey -o jsonpath='{.data.password}' | base64 -d)"

echo "Target endpoints:"
echo "  app    = http://$APP_IP:$APP_PORT"
echo "  valkey = $SEED_IP:$SEED_PORT (seed; the rest of the cluster is announced via CLUSTER SHARDS)"
echo

# 1. App over the MetalLB IP — plain HTTP
echo "[1/4] curl app /actuator/health  (HTTP via MetalLB IP)"
if curl -fsS -m 5 "http://$APP_IP:$APP_PORT/actuator/health" | tee /dev/null; then
    echo
    echo "  -> OK"
else
    echo "  -> FAIL — no response from $APP_IP:$APP_PORT"
    echo "     Did you run 'scripts/host-routes.sh add' first?"
    exit 1
fi
echo

# 2. App CRUD via Postman-style POST
echo "[2/4] POST /api/customers  (HTTP via MetalLB IP)"
ID=$(curl -fsS -m 5 -X POST "http://$APP_IP:$APP_PORT/api/customers" \
     -H 'Content-Type: application/json' \
     -d '{"name":"Path2 External","email":"path2-ext@example.com"}' \
     | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")
echo "  -> created id=$ID"
echo

# 3. Valkey reachability
if [[ -z "$VALKEY_CLI" ]]; then
    echo "[3/4] SKIP — neither valkey-cli nor redis-cli on PATH"
    echo "       Install with: brew install valkey  (or  brew install redis)"
else
    echo "[3/4] $VALKEY_CLI -h $SEED_IP -p $SEED_PORT ... PING"
    PONG="$($VALKEY_CLI -h "$SEED_IP" -p "$SEED_PORT" -a "$PASS" --no-auth-warning ping 2>&1 | tail -1)"
    if [[ "$PONG" == "PONG" ]]; then
        echo "  -> $PONG"
    else
        echo "  -> FAIL: $PONG"
        exit 1
    fi
    echo

    echo "[4/4] CLUSTER INFO + write through MOVED redirect (cluster mode)"
    echo "  CLUSTER NODES (truncated):"
    $VALKEY_CLI -h "$SEED_IP" -p "$SEED_PORT" -a "$PASS" --no-auth-warning cluster nodes \
        | awk '{print "    " $2, $3}' | head -10
    echo
    echo "  SET hello world  (will MOVED-redirect if seed doesn't own the slot — -c handles it):"
    OK="$($VALKEY_CLI -c -h "$SEED_IP" -p "$SEED_PORT" -a "$PASS" --no-auth-warning set hello world 2>&1 | tail -1)"
    GOT="$($VALKEY_CLI -c -h "$SEED_IP" -p "$SEED_PORT" -a "$PASS" --no-auth-warning get hello 2>&1 | tail -1)"
    echo "    SET hello -> $OK"
    echo "    GET hello -> $GOT"

    if [[ "$OK" == "OK" && "$GOT" == "world" ]]; then
        echo
        echo "All checks passed. Topology is reachable from this Mac."
    else
        echo
        echo "Cluster reachable, but SET/GET via MOVED redirect failed — investigate cluster-announce-ip."
        exit 1
    fi
fi
