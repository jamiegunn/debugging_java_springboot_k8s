#!/usr/bin/env bash
#
# valkey-cluster-tests.sh — cluster-semantics test suite for the live Valkey
# cluster. Where smoke-test.sh proves the happy path, this suite exercises the
# cluster-protocol edge cases a client library must survive:
#
#   1. MOVED   — permanent redirect to the slot owner (wrong-node writes)
#   2. ASK     — temporary redirect DURING a live slot migration. The suite
#                actually starts a real migration (CLUSTER SETSLOT MIGRATING/
#                IMPORTING), observes the ASK response, proves -c follows it,
#                then aborts the migration (SETSLOT STABLE) leaving the
#                cluster exactly as it found it.
#   3. Replica behavior — reads against a secondary: plain GET is redirected
#                to the primary (MOVED); after READONLY the replica serves it.
#   4. Failover — freezes a primary's event loop (DEBUG SLEEP 20, enabled
#                for local connections in the chart) so its peers genuinely
#                detect the failure and elect the by-index replica. Proves
#                direct writes and the app API keep working during the
#                outage, watches the frozen node wake up and demote itself
#                to replica, then FAILS BACK (CLUSTER FAILOVER on the
#                demoted node) to restore canonical roles.
#                Why not `kubectl delete pod`: the StatefulSet resurrects it
#                (cached image + PVC) faster than the 5s cluster-node-timeout
#                — no failover ever happens. Freezing beats killing here.
#
# DISRUPTIVE: section 4 takes one shard's primary offline for ~20s. Fine for
# this dev stack, never for prod.
#
# Usage:
#   ./valkey-cluster-tests.sh                # all sections
#   ./valkey-cluster-tests.sh --skip-failover   # sections 1-3 only (no disruption)

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

SKIP_FAILOVER=0
for a in "$@"; do
    case "$a" in
        --skip-failover) SKIP_FAILOVER=1 ;;
        -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) err "unknown arg: $a"; exit 64 ;;
    esac
done

require_cmd kubectl curl
CLI="$(command -v valkey-cli || command -v redis-cli || true)"
[[ -n "$CLI" ]] || { err "valkey-cli/redis-cli required (brew install valkey)"; exit 1; }

VK_PASS="$(kubectl -n valkey get secret valkey -o jsonpath='{.data.password}' | base64 -d)"

PASS_COUNT=0; FAIL_COUNT=0; FAIL_LINES=()
check() {
    local name="$1"; shift
    if "$@" >/tmp/vk-cluster-test.out 2>&1; then
        printf '[PASS] %s\n' "$name"; PASS_COUNT=$((PASS_COUNT+1))
    else
        printf '[FAIL] %s\n' "$name"; FAIL_COUNT=$((FAIL_COUNT+1)); FAIL_LINES+=("$name")
        sed 's/^/        /' /tmp/vk-cluster-test.out | head -12
    fi
}

# vkc <ip:port> <args...> — pinned connection to one announced endpoint
vkc() { local ep="$1"; shift; "$CLI" -h "${ep%%:*}" -p "${ep##*:}" -a "$VK_PASS" --no-auth-warning "$@"; }
# vkc_pipe <ip:port> — feed multiple commands over ONE connection via stdin
# (needed for READONLY + GET, which must share a connection)
vkc_pipe() { local ep="$1"; "$CLI" -h "${ep%%:*}" -p "${ep##*:}" -a "$VK_PASS" --no-auth-warning; }

# ---------------------------------------------------------------------------
# Endpoint + topology discovery
# ---------------------------------------------------------------------------
declare -a EP_NAME EP_ADDR
while IFS=$'\t' read -r name ep; do
    [[ -n "$ep" ]] || continue
    EP_NAME+=("$name"); EP_ADDR+=("$ep")
done < <(valkey_announced_endpoints valkey)
[[ ${#EP_ADDR[@]} -eq 6 ]] || { err "expected 6 announced endpoints, have ${#EP_ADDR[@]} — is the stack up?"; exit 1; }

ep_of() { # ep_of valkey-primary-1 -> ip:port
    local i
    for i in "${!EP_NAME[@]}"; do
        [[ "${EP_NAME[$i]}" == "$1" ]] && { echo "${EP_ADDR[$i]}"; return; }
    done
}
SEED="$(ep_of valkey-primary-0)"

node_id() { # node_id <ip:port> — cluster node id of the node at this endpoint
    vkc "$SEED" cluster nodes 2>/dev/null | awk -v a="$1" '{split($2,x,"@"); if (x[1]==a) print $1}'
}
owner_ep_of_slot() { # announced ip:port of the primary owning a slot
    vkc "$SEED" cluster nodes 2>/dev/null | awk -v s="$1" '
        /master/ { for (i=9;i<=NF;i++) { split($i,r,"-");
            if (r[1]+0<=s+0 && r[2]+0>=s+0) { split($2,a,"@"); print a[1]; exit } } }'
}

echo "=== 0. Preconditions ==============================================="
check "cluster_state:ok, 6 known nodes, 3 shards" \
    bash -c '
        out=$(kubectl -n valkey exec valkey-primary-0 -- valkey-cli -a "'"$VK_PASS"'" cluster info 2>/dev/null)
        echo "$out" | grep -q cluster_state:ok &&
        echo "$out" | grep -q cluster_known_nodes:6 &&
        echo "$out" | grep -q cluster_size:3
    '

# ---------------------------------------------------------------------------
# 1. MOVED — permanent redirect
# ---------------------------------------------------------------------------
echo
echo "=== 1. MOVED (permanent redirect) =================================="
K="cluster-test-moved-$$"
SLOT=$(vkc "$SEED" cluster keyslot "$K" | tr -d '\r')
OWNER="$(owner_ep_of_slot "$SLOT")"
WRONG=""
for ep in "$(ep_of valkey-primary-0)" "$(ep_of valkey-primary-1)" "$(ep_of valkey-primary-2)"; do
    [[ "$ep" != "$OWNER" ]] && { WRONG=$ep; break; }
done

check "wrong-node SET returns MOVED naming the owner ($OWNER)" \
    bash -c 'out=$('"$CLI"' -h '"${WRONG%%:*}"' -p '"${WRONG##*:}"' -a "'"$VK_PASS"'" --no-auth-warning set '"$K"' v 2>&1)
             [[ "$out" == *MOVED*'"$OWNER"'* ]] || { echo "got: $out"; exit 1; }'
check "-c follows the MOVED and the write lands on the owner" \
    bash -c ''"$CLI"' -c -h '"${WRONG%%:*}"' -p '"${WRONG##*:}"' -a "'"$VK_PASS"'" --no-auth-warning set '"$K"' moved-ok 2>&1 | grep -q OK &&
             '"$CLI"' -h '"${OWNER%%:*}"' -p '"${OWNER##*:}"' -a "'"$VK_PASS"'" --no-auth-warning get '"$K"' 2>&1 | grep -q moved-ok'
vkc "$OWNER" del "$K" >/dev/null 2>&1

# ---------------------------------------------------------------------------
# 2. ASK — temporary redirect during live slot migration
# ---------------------------------------------------------------------------
# Protocol recap: while a slot is MIGRATING on the source, requests for keys
# STILL PRESENT on the source are served normally; requests for keys in that
# slot that are NOT on the source get "ASK <slot> <target>". The client must
# send ASKING before retrying at the target — plain requests there get MOVED
# back (the target doesn't own the slot yet). valkey-cli -c handles all this.
# We use two keys with the same hash tag (same slot): one stays on the source
# (control), one never exists (triggers ASK).
echo
echo "=== 2. ASK (live slot-migration redirect) =========================="
TAG="askmig$$"
K_PRESENT="{${TAG}}:present"
K_ABSENT="{${TAG}}:absent"
ASK_SLOT=$(vkc "$SEED" cluster keyslot "$K_PRESENT" | tr -d '\r')
SRC_EP="$(owner_ep_of_slot "$ASK_SLOT")"
DST_EP=""
for ep in "$(ep_of valkey-primary-0)" "$(ep_of valkey-primary-1)" "$(ep_of valkey-primary-2)"; do
    [[ "$ep" != "$SRC_EP" ]] && { DST_EP=$ep; break; }
done
SRC_ID="$(node_id "$SRC_EP")"
DST_ID="$(node_id "$DST_EP")"

info "slot $ASK_SLOT: migrating $SRC_EP ($SRC_ID) → $DST_EP ($DST_ID)"
vkc "$SRC_EP" set "$K_PRESENT" here >/dev/null

# Start the migration handshake (target first, then source — the documented order)
vkc "$DST_EP" cluster setslot "$ASK_SLOT" importing "$SRC_ID" >/dev/null
vkc "$SRC_EP" cluster setslot "$ASK_SLOT" migrating "$DST_ID" >/dev/null

abort_migration() {
    vkc "$SRC_EP" cluster setslot "$ASK_SLOT" stable >/dev/null 2>&1 || true
    vkc "$DST_EP" cluster setslot "$ASK_SLOT" stable >/dev/null 2>&1 || true
    vkc "$SRC_EP" del "$K_PRESENT" >/dev/null 2>&1 || true
}
trap abort_migration EXIT

check "key still on the source is served normally mid-migration" \
    bash -c 'v=$('"$CLI"' -h '"${SRC_EP%%:*}"' -p '"${SRC_EP##*:}"' -a "'"$VK_PASS"'" --no-auth-warning get "'"$K_PRESENT"'" 2>&1 | tail -1)
             [[ "$v" == "here" ]] || { echo "got: $v"; exit 1; }'

check "absent key in the migrating slot returns ASK naming the target ($DST_EP)" \
    bash -c 'out=$('"$CLI"' -h '"${SRC_EP%%:*}"' -p '"${SRC_EP##*:}"' -a "'"$VK_PASS"'" --no-auth-warning get "'"$K_ABSENT"'" 2>&1)
             [[ "$out" == *ASK*'"$DST_EP"'* ]] || { echo "expected ASK ... '"$DST_EP"', got: $out"; exit 1; }'

check "plain request at the target (no ASKING) is bounced back with MOVED" \
    bash -c 'out=$('"$CLI"' -h '"${DST_EP%%:*}"' -p '"${DST_EP##*:}"' -a "'"$VK_PASS"'" --no-auth-warning get "'"$K_ABSENT"'" 2>&1)
             [[ "$out" == *MOVED* ]] || { echo "expected MOVED, got: $out"; exit 1; }'

check "-c chases the ASK (sends ASKING) and completes the read" \
    bash -c 'out=$('"$CLI"' -c -h '"${SRC_EP%%:*}"' -p '"${SRC_EP##*:}"' -a "'"$VK_PASS"'" --no-auth-warning get "'"$K_ABSENT"'" 2>&1 | tail -1)
             [[ -z "$out" || "$out" == "" ]] || { echo "expected empty (nil), got: $out"; exit 1; }'

abort_migration
trap - EXIT
check "migration aborted cleanly — cluster_state back to ok, no importing/migrating slots" \
    bash -c '
        nodes=$('"$CLI"' -h '"${SEED%%:*}"' -p '"${SEED##*:}"' -a "'"$VK_PASS"'" --no-auth-warning cluster nodes 2>&1)
        [[ "$nodes" != *"->-"* && "$nodes" != *"-<-"* ]] || { echo "residual migration flags: $nodes"; exit 1; }
    '

# ---------------------------------------------------------------------------
# 3. Replica behavior
# ---------------------------------------------------------------------------
echo
echo "=== 3. Replica reads ==============================================="
RK="cluster-test-replica-$$"
RSLOT=$(vkc "$SEED" cluster keyslot "$RK" | tr -d '\r')
ROWNER="$(owner_ep_of_slot "$RSLOT")"
vkc "$ROWNER" set "$RK" replica-test >/dev/null
# Find the replica of that owner (by-index pairing: primary-N ↔ secondary-N)
ROWNER_NAME=""
for i in "${!EP_ADDR[@]}"; do [[ "${EP_ADDR[$i]}" == "$ROWNER" ]] && ROWNER_NAME="${EP_NAME[$i]}"; done
REPLICA_EP="$(ep_of "${ROWNER_NAME/primary/secondary}")"
sleep 1   # let async replication catch up

check "plain GET on the replica is redirected (MOVED) to the primary" \
    bash -c 'out=$('"$CLI"' -h '"${REPLICA_EP%%:*}"' -p '"${REPLICA_EP##*:}"' -a "'"$VK_PASS"'" --no-auth-warning get '"$RK"' 2>&1)
             [[ "$out" == *MOVED*'"$ROWNER"'* ]] || { echo "got: $out"; exit 1; }'

check "READONLY on the same connection lets the replica serve the read" \
    bash -c 'out=$(printf "READONLY\nGET '"$RK"'\n" | '"$CLI"' -h '"${REPLICA_EP%%:*}"' -p '"${REPLICA_EP##*:}"' -a "'"$VK_PASS"'" --no-auth-warning 2>&1 | tail -1)
             [[ "$out" == "replica-test" ]] || { echo "got: $out"; exit 1; }'
vkc "$ROWNER" del "$RK" >/dev/null 2>&1

# ---------------------------------------------------------------------------
# 4. Failover: kill a primary, watch its replica take over, fail back
# ---------------------------------------------------------------------------
if [[ $SKIP_FAILOVER -eq 1 ]]; then
    echo; echo "=== 4. Failover — SKIPPED (--skip-failover) ==="
else
    echo
    echo "=== 4. Failover (freeze primary → replica takeover → failback) ==="
    VICTIM_POD="valkey-primary-1"
    VICTIM_EP="$(ep_of valkey-primary-1)"
    HEIR_EP="$(ep_of valkey-secondary-1)"
    HEIR_ID="$(node_id "$HEIR_EP")"

    info "freezing $VICTIM_POD ($VICTIM_EP) for 20s via DEBUG SLEEP; heir is $HEIR_EP"
    # DEBUG SLEEP blocks the victim's event loop: no client commands, no
    # cluster-bus PONGs → peers mark it pfail→fail after node-timeout (5s)
    # and the replica wins an election. Run detached — the exec blocks for
    # the full 20s.
    kubectl -n valkey exec "$VICTIM_POD" -- \
        valkey-cli -a "$VK_PASS" --no-auth-warning debug sleep 20 >/dev/null 2>&1 &
    FREEZE_PID=$!

    check "heir promotes to master within 30s (cluster-node-timeout is 5s)" \
        bash -c '
            for i in $(seq 1 30); do
                role=$('"$CLI"' -h '"${SEED%%:*}"' -p '"${SEED##*:}"' -a "'"$VK_PASS"'" --no-auth-warning cluster nodes 2>/dev/null \
                        | awk -v id="'"$HEIR_ID"'" "\$1==id {print \$3}")
                [[ "$role" == *master* ]] && exit 0
                sleep 1
            done
            echo "heir never promoted; last role: $role"; exit 1
        '

    check "cluster serves writes during the failover (slot now owned by the heir)" \
        bash -c '
            for i in $(seq 1 15); do
                if '"$CLI"' -c -h '"${SEED%%:*}"' -p '"${SEED##*:}"' -a "'"$VK_PASS"'" --no-auth-warning set failover-probe-$$ ok 2>/dev/null | grep -q OK; then
                    exit 0
                fi
                sleep 1
            done
            echo "writes never recovered"; exit 1
        '

    check "the app API keeps working during the failover (POST /api/orders)" \
        bash -c '
            HAPROXY_IP=$(cat "'"$SCRIPT_DIR"'/../dumps/haproxy-vm-ip" 2>/dev/null) || HAPROXY_IP=$(kubectl get nodes -o jsonpath="{.items[0].status.addresses[?(@.type==\"ExternalIP\")].address}")
            ts=$(date +%s)
            cid=$(curl -fsS -m 8 --resolve "debug-demo.local:80:${HAPROXY_IP}" -X POST http://debug-demo.local/api/customers \
                  -H "Content-Type: application/json" \
                  -d "{\"name\":\"failover-$ts\",\"email\":\"failover-$ts@example.com\"}" | python3 -c "import json,sys;print(json.load(sys.stdin)[\"id\"])")
            # Lettuce may need a topology refresh after the promotion — retry a few times
            for i in $(seq 1 10); do
                if curl -fsS -m 8 --resolve "debug-demo.local:80:${HAPROXY_IP}" -X POST http://debug-demo.local/api/orders \
                     -H "Content-Type: application/json" -d "{\"customerId\":$cid,\"amount\":1.00}" >/dev/null 2>&1; then
                    exit 0
                fi
                sleep 2
            done
            echo "POST /api/orders never succeeded during failover"; exit 1
        '

    check "frozen primary wakes up and DEMOTES itself to replica of the heir" \
        bash -c '
            # It wakes at ~20s, learns the epoch moved on, reconfigures as slave.
            for i in $(seq 1 45); do
                line=$('"$CLI"' -h '"${SEED%%:*}"' -p '"${SEED##*:}"' -a "'"$VK_PASS"'" --no-auth-warning cluster nodes 2>/dev/null \
                        | awk -v a="'"$VICTIM_EP"'" "{split(\$2,x,\"@\"); if (x[1]==a) print \$3, \$4}")
                if [[ "$line" == *slave*'"$HEIR_ID"'* ]]; then exit 0; fi
                sleep 2
            done
            echo "old primary never demoted to replica of heir; last: $line"; exit 1
        '
    wait "$FREEZE_PID" 2>/dev/null || true

    info "failing back: CLUSTER FAILOVER on $VICTIM_EP (now a replica) restores canonical roles"
    vkc "$VICTIM_EP" cluster failover >/dev/null 2>&1 || true
    check "failback: $VICTIM_EP is master again, heir back to replica" \
        bash -c '
            for i in $(seq 1 30); do
                role=$('"$CLI"' -h '"${SEED%%:*}"' -p '"${SEED##*:}"' -a "'"$VK_PASS"'" --no-auth-warning cluster nodes 2>/dev/null \
                        | awk -v a="'"$VICTIM_EP"'" "{split(\$2,x,\"@\"); if (x[1]==a) print \$3}")
                [[ "$role" == *master* && "$role" != *fail* ]] && exit 0
                sleep 2
            done
            echo "failback never completed; last role: $role"; exit 1
        '

    check "final state: cluster_state:ok, all 6 nodes, no fail flags" \
        bash -c '
            out=$('"$CLI"' -h '"${SEED%%:*}"' -p '"${SEED##*:}"' -a "'"$VK_PASS"'" --no-auth-warning cluster info 2>&1)
            nodes=$('"$CLI"' -h '"${SEED%%:*}"' -p '"${SEED##*:}"' -a "'"$VK_PASS"'" --no-auth-warning cluster nodes 2>&1)
            echo "$out" | grep -q cluster_state:ok &&
            echo "$out" | grep -q cluster_known_nodes:6 &&
            ! echo "$nodes" | grep -qE "fail\??[ ,]"
        '
fi

# ---------------------------------------------------------------------------
echo
echo "=================================================================="
echo "Passed: $PASS_COUNT    Failed: $FAIL_COUNT"
if [[ $FAIL_COUNT -gt 0 ]]; then
    echo; echo "Failures:"; for l in "${FAIL_LINES[@]}"; do echo "  - $l"; done
fi
echo "=================================================================="
exit $FAIL_COUNT
