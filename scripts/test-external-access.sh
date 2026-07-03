#!/usr/bin/env bash
#
# test-external-access.sh — quick end-to-end sanity check that external
# clients (running on this Mac, NOT in the cluster) can reach the app
# through the Pattern D path (HAProxy VM → hostNetwork ingress → app) and
# the Valkey cluster through the MetalLB per-pod LB IPs.
#
# For the full 43-check verification (including explicit MOVED tests for
# GET/SET, XADD, and SPUBLISH), use scripts/smoke-test.sh. This script is
# a lightweight 4-step touch when you just want to confirm the network is
# wired up.
#
# Prereqs:
#   - scripts/install-stack.sh has been run (or you've done its Phase 9
#     equivalents by hand: static routes, /etc/hosts entry, IP forwarding)
#   - valkey-cli or redis-cli on PATH (brew install valkey or redis)
#
# Usage:
#   ./test-external-access.sh

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_cmd kubectl curl

# Prefer the HAProxy VM IP (Pattern D entry point) if install-stack.sh
# provisioned it; fall back to the RD node ExternalIP for the --skip-haproxy-vm
# degraded mode.
HAPROXY_VM_IP_FILE="$(cd "$SCRIPT_DIR/.." && pwd)/dumps/haproxy-vm-ip"
if [[ -f "$HAPROXY_VM_IP_FILE" ]]; then
    APP_HOST_DEFAULT="$(cat "$HAPROXY_VM_IP_FILE")"
    APP_VIA_DEFAULT="HAProxy VM (F5 stand-in)"
else
    APP_HOST_DEFAULT="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="ExternalIP")].address}' 2>/dev/null || echo 192.168.64.2)"
    APP_VIA_DEFAULT="RD node ExternalIP (no F5 stand-in)"
fi

APP_HOST="${APP_HOST:-$APP_HOST_DEFAULT}"
APP_VIA="${APP_VIA:-$APP_VIA_DEFAULT}"
APP_INGRESS_HOST="${APP_INGRESS_HOST:-debug-demo.local}"
# Valkey seed: primary-0's ANNOUNCED endpoint (what clients must dial) — the
# VIP in two-layer mode, the Service's MetalLB IP in one-layer mode. Works in
# both port shapes too (sharedIP-perPort: one IP, ports 6379-6384; legacy
# perPodIP: six IPs, one port). SEED_IP/SEED_PORT env vars override.
# Capture the helper output before filtering — piping it straight into an
# awk that exits early would SIGPIPE the kubectl loop under pipefail.
VK_EPS_ALL="$(valkey_announced_endpoints valkey)"
SEED_EP_DEFAULT="$(printf '%s\n' "$VK_EPS_ALL" | awk -F'\t' '$1=="valkey-primary-0" {print $2; exit}')"
SEED_IP="${SEED_IP:-${SEED_EP_DEFAULT%%:*}}"
SEED_PORT="${SEED_PORT:-${SEED_EP_DEFAULT##*:}}"
SEED_IP="${SEED_IP:-192.168.64.51}"
SEED_PORT="${SEED_PORT:-6379}"

VALKEY_CLI="$(command -v valkey-cli || command -v redis-cli || true)"
PASS="$(kubectl -n valkey get secret valkey -o jsonpath='{.data.password}' | base64 -d)"

echo "Target endpoints:"
echo "  app    = http://${APP_INGRESS_HOST}/  (via ${APP_HOST}, ${APP_VIA})"
echo "  valkey = ${SEED_IP}:${SEED_PORT}       (announced seed; the rest via CLUSTER SHARDS)"
echo

# 1. App via L7 through HAProxy VM (or RD node)
echo "[1/4] curl app /actuator/health  (L7 via ${APP_VIA})"
if curl -fsS -m 5 --resolve "${APP_INGRESS_HOST}:80:${APP_HOST}" "http://${APP_INGRESS_HOST}/actuator/health" | tee /dev/null; then
    echo
    echo "  -> OK"
else
    echo "  -> FAIL — no response through ${APP_HOST} for Host: ${APP_INGRESS_HOST}"
    echo "     Check: limactl list | grep debug-demo-haproxy"
    echo "     Check: sysctl net.inet.ip.forwarding    (should be 1)"
    echo "     Check: grep debug-demo.local /etc/hosts"
    exit 1
fi
echo

# 2. App CRUD via Postman-style POST
echo "[2/4] POST /api/customers  (L7 CRUD through ingress → app)"
TS=$(date -u +%s)
ID=$(curl -fsS -m 5 --resolve "${APP_INGRESS_HOST}:80:${APP_HOST}" \
     -X POST "http://${APP_INGRESS_HOST}/api/customers" \
     -H 'Content-Type: application/json' \
     -d "{\"name\":\"external-touch-${TS}\",\"email\":\"external-touch-${TS}@example.com\"}" \
     | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")
echo "  -> created id=$ID"
echo

# 3. Valkey reachability
if [[ -z "$VALKEY_CLI" ]]; then
    echo "[3/4] SKIP — neither valkey-cli nor redis-cli on PATH"
    echo "       Install with: brew install valkey  (or  brew install redis)"
else
    echo "[3/4] $VALKEY_CLI -h $SEED_IP -p $SEED_PORT ... PING  (L4 via MetalLB)"
    PONG="$($VALKEY_CLI -h "$SEED_IP" -p "$SEED_PORT" -a "$PASS" --no-auth-warning ping 2>&1 | tail -1)"
    if [[ "$PONG" == "PONG" ]]; then
        echo "  -> $PONG"
    else
        echo "  -> FAIL: $PONG"
        echo "     Check: scripts/host-routes.sh list   (route to $SEED_IP should go via 192.168.64.2)"
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
        echo "All checks passed. Pattern D topology is reachable from this Mac."
    else
        echo
        echo "Cluster reachable, but SET/GET via MOVED redirect failed — investigate cluster-announce-ip."
        exit 1
    fi
fi
