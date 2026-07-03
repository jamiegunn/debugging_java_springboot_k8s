#!/usr/bin/env bash
#
# valkey-tour.sh — read-only investigation of the running Valkey cluster
# from outside the k8s cluster, via the per-pod LoadBalancer endpoints.
# Endpoints are discovered from the valkey-*-ext Services, so the tour works
# in both endpoint modes: sharedIP-perPort (one IP, client ports 6379-6384)
# and legacy perPodIP (six IPs, one port).
#
# Use this when you want a comprehensive snapshot: topology, every op type
# the chart wires up, MOVED redirect behavior, latency, slow queries, big
# keys, memory. Output is informational — no pass/fail. For pass/fail
# checks, see scripts/smoke-test.sh.
#
# Prereqs:
#   - scripts/host-routes.sh add   (Mac can route to the LB IP(s))
#   - valkey-cli or redis-cli on PATH (brew install valkey)
#
# Usage:
#   ./valkey-tour.sh                   # full tour
#   ./valkey-tour.sh --seed 192.168.64.51:6380   # use a different seed (ip[:port])
#   ./valkey-tour.sh --section topology          # just one section
#       sections: topology, strings, hash, list, zset, stream, pubsub, info, latency

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

SEED=""
PORT=""
SECTIONS=""
for ((i=1; i<=$#; i++)); do
    case "${!i}" in
        --seed)     j=$((i+1)); SEED="${!j}"; i=$j ;;
        --section)  j=$((i+1)); SECTIONS="${!j}"; i=$j ;;
        -h|--help)  sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    esac
done
# --seed accepts "ip" or "ip:port"
if [[ "$SEED" == *:* ]]; then
    PORT="${SEED##*:}"
    SEED="${SEED%%:*}"
fi

# Discover the 6 external endpoints from the Services (works in both
# sharedIP-perPort and perPodIP modes). ALL_EPS drives per-node sweeps.
ALL_EPS=()
for role in primary secondary; do
    for n in 0 1 2; do
        ep_ip=$(kubectl -n valkey get svc "valkey-${role}-${n}-ext" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
        ep_port=$(kubectl -n valkey get svc "valkey-${role}-${n}-ext" -o jsonpath='{.spec.ports[?(@.name=="client")].port}' 2>/dev/null || true)
        [[ -n "$ep_ip" && -n "$ep_port" ]] && ALL_EPS+=("${ep_ip}:${ep_port}")
    done
done
if [[ -z "$SEED" ]]; then
    if [[ ${#ALL_EPS[@]} -gt 0 ]]; then
        SEED="${ALL_EPS[0]%%:*}"
        : "${PORT:=${ALL_EPS[0]##*:}}"
    else
        SEED="192.168.64.51"
    fi
fi
: "${PORT:=6379}"

CLI="$(command -v valkey-cli || command -v redis-cli || true)"
if [[ -z "$CLI" ]]; then
    err "neither valkey-cli nor redis-cli on PATH — install with: brew install valkey"
    exit 1
fi

PASS="$(kubectl -n valkey get secret valkey -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null)"
if [[ -z "$PASS" ]]; then
    err "couldn't read Valkey password from k8s secret — is the cluster up?"
    exit 1
fi

# Connectivity check first — fail fast with a useful message
if ! "$CLI" -h "$SEED" -p "$PORT" -a "$PASS" --no-auth-warning ping 2>/dev/null | grep -q PONG; then
    err "can't reach $SEED:$PORT"
    err "did you run 'scripts/host-routes.sh add'? (or the cluster isn't healthy)"
    exit 1
fi

# vk = cluster-aware (follows MOVED redirects) — for single-key ops
# vk_pin = pinned to one node (no -c) — for ops that need shard affinity (cluster commands, INFO, latency)
vk()      { "$CLI" -c -h "$SEED" -p "$PORT" -a "$PASS" --no-auth-warning "$@"; }
vk_pin()  { "$CLI"    -h "$SEED" -p "$PORT" -a "$PASS" --no-auth-warning "$@"; }
section() {
    [[ -n "$SECTIONS" && "$SECTIONS" != "$1" ]] && return 1
    echo
    printf '═══ %s ═══════════════════════════════════════════════════════\n' "$1"
    return 0
}

# ---------------------------------------------------------------------------
section topology && {
    echo "Seed: $SEED:$PORT"
    echo
    echo "─ CLUSTER INFO ─"
    vk_pin cluster info | sed 's/^/  /'
    echo
    echo "─ CLUSTER NODES (id role addr master_id) ─"
    vk_pin cluster nodes | awk '{printf "  %s  %-25s %-15s %s\n", substr($1,1,8)".."substr($1,length($1)-3), $3, $2, $4}'
    echo
    echo "─ CLUSTER SHARDS (slot ranges → owning primary) ─"
    vk_pin cluster shards 2>/dev/null | sed 's/^/  /' || vk_pin cluster slots | sed 's/^/  /'
    echo
    echo "─ Per-node uptime + role ─"
    for ep in ${ALL_EPS[@]+"${ALL_EPS[@]}"}; do    # empty-array-safe under set -u / bash 3.2
        ep_ip="${ep%%:*}"; ep_port="${ep##*:}"
        role=$("$CLI" -h "$ep_ip" -p "$ep_port" -a "$PASS" --no-auth-warning info replication 2>/dev/null | grep -E '^role:' | tr -d '\r' | cut -d: -f2)
        up=$("$CLI" -h "$ep_ip" -p "$ep_port" -a "$PASS" --no-auth-warning info server 2>/dev/null | grep -E '^uptime_in_seconds:' | tr -d '\r' | cut -d: -f2)
        printf "  %-21s role=%-7s uptime=%ss\n" "$ep" "$role" "$up"
    done
}

# ---------------------------------------------------------------------------
section strings && {
    echo "Plain string ops — keys distribute across shards by CRC16(key) mod 16384."
    echo "We use -c (cluster-aware) so the client follows MOVED redirects transparently."
    echo
    for k in foo bar baz qux quux corge grault; do
        slot=$(vk_pin cluster keyslot "$k" | tr -d '\r')
        owner=$(vk_pin cluster countkeysinslot "$slot" >/dev/null; vk_pin cluster nodes | awk -v s="$slot" '
            !/slave/ { for(i=9;i<=NF;i++) { if(match($i, /^([0-9]+)-([0-9]+)$/, m)) { if(s>=m[1] && s<=m[2]) print $2 } } }')
        printf "  key=%-8s slot=%-5d owner=%s\n" "$k" "$slot" "$owner"
    done
    echo
    echo "─ SET/GET with TTL (round-trips one MOVED redirect if seed isn't the owner) ─"
    vk set tour:demo "hello at $(date -u +%H:%M:%S)" EX 60 | sed 's/^/  /'
    vk get tour:demo  | sed 's/^/  /'
    vk ttl tour:demo  | sed 's/^/  /'
}

# ---------------------------------------------------------------------------
section hash && {
    echo "Hash ops on customer:stats:{N} — the {N} hash tag pins all per-customer keys to one shard."
    echo
    K="customer:stats:{42}"
    vk hset "$K" order_count 1 total_spend 19.99 last_order_at "$(date -u +%FT%TZ)" > /dev/null
    vk hincrby "$K" order_count 1 > /dev/null
    vk hincrbyfloat "$K" total_spend 29.50 > /dev/null
    echo "─ HGETALL $K ─"
    vk hgetall "$K" | paste - - | sed 's/^/  /'
    echo
    echo "All hash-tagged keys for the same customer ID land on the same shard:"
    for k in "customer:stats:{42}" "customer:orders:{42}" "customer:cart:{42}"; do
        slot=$(vk_pin cluster keyslot "$k" | tr -d '\r')
        printf "  %-30s slot=%s\n" "$k" "$slot"
    done
}

# ---------------------------------------------------------------------------
section list && {
    echo "Capped list — orders:recent uses LPUSH + LTRIM 0 99 to keep the last 100."
    echo
    echo "─ LLEN orders:recent ─"
    vk llen orders:recent | sed 's/^/  /'
    echo "─ LRANGE orders:recent 0 4 ─"
    vk lrange orders:recent 0 4 | sed 's/^/  /'
}

# ---------------------------------------------------------------------------
section zset && {
    echo "Sorted set — customers:top ranks customers by total spend."
    echo
    echo "─ ZCARD customers:top ─"
    vk zcard customers:top | sed 's/^/  /'
    echo "─ ZREVRANGE customers:top 0 9 WITHSCORES ─"
    vk zrevrange customers:top 0 9 WITHSCORES | paste - - | sed 's/^/  /'
}

# ---------------------------------------------------------------------------
section stream && {
    echo "Stream — orders:events. Each XADD by the app appends one entry."
    echo
    echo "─ XLEN orders:events ─"
    vk xlen orders:events | sed 's/^/  /'
    echo "─ XINFO STREAM orders:events ─"
    vk xinfo stream orders:events | sed 's/^/  /' | head -20
    echo "─ XINFO GROUPS orders:events ─"
    vk xinfo groups orders:events | sed 's/^/  /'
    echo "─ XRANGE orders:events - + COUNT 3 (the 3 oldest entries) ─"
    vk xrange orders:events - + COUNT 3 | sed 's/^/  /'
    echo "─ XREVRANGE orders:events + - COUNT 3 (the 3 newest entries) ─"
    vk xrevrange orders:events + - COUNT 3 | sed 's/^/  /'
}

# ---------------------------------------------------------------------------
section pubsub && {
    echo "Pub/sub channels currently in use:"
    echo
    echo "─ PUBSUB CHANNELS * ─"
    vk_pin pubsub channels '*' | sed 's/^/  /'
    echo "─ PUBSUB NUMSUB orders:notifications ─"
    vk_pin pubsub numsub orders:notifications | paste - - | sed 's/^/  /'
    echo "─ PUBSUB SHARDCHANNELS * (sharded channels) ─"
    vk_pin pubsub shardchannels '*' | sed 's/^/  /'
    echo
    echo "To watch the classic channel live (cluster bus broadcasts, so any seed works):"
    echo "  $CLI -h $SEED -p $PORT -a '\$PASS' subscribe orders:notifications"
    echo "Then in another terminal, drive an order to trigger a PUBLISH:"
    echo "  curl -X POST http://debug-demo.local/api/orders -H 'Content-Type: application/json' -d '{\"customerId\":1,\"amount\":1.00}'"
}

# ---------------------------------------------------------------------------
section info && {
    echo "─ INFO Server (selected) ─"
    vk_pin info server | grep -E '^(redis_version|valkey_version|os|arch_bits|uptime_in_seconds|run_id|tcp_port)' | sed 's/^/  /'
    echo
    echo "─ INFO Clients ─"
    vk_pin info clients | grep -E '^(connected_clients|maxclients|blocked_clients|tracking_clients)' | sed 's/^/  /'
    echo
    echo "─ INFO Memory ─"
    vk_pin info memory | grep -E '^(used_memory_human|used_memory_peak_human|used_memory_rss_human|maxmemory_human|mem_fragmentation_ratio|maxmemory_policy)' | sed 's/^/  /'
    echo
    echo "─ INFO Stats (cluster-bus + commands) ─"
    vk_pin info stats | grep -E '^(total_commands_processed|instantaneous_ops_per_sec|total_net_input_bytes|total_net_output_bytes|expired_keys|evicted_keys|keyspace_hits|keyspace_misses)' | sed 's/^/  /'
    echo
    echo "─ INFO Replication (this seed's role) ─"
    vk_pin info replication | sed 's/^/  /' | head -10
    echo
    echo "─ INFO Cluster ─"
    vk_pin info cluster | sed 's/^/  /'
}

# ---------------------------------------------------------------------------
section latency && {
    echo "Latency probes — these run a few thousand pings and report distribution."
    echo "Quick check (3 seconds, this seed only):"
    "$CLI" -h "$SEED" -p "$PORT" -a "$PASS" --no-auth-warning --latency -i 1 &
    LPID=$!
    sleep 3
    kill $LPID 2>/dev/null
    wait $LPID 2>/dev/null
    echo
    echo "Per-node history (events that exceeded the latency monitor threshold):"
    echo "  LATENCY threshold default = 0 ms (disabled). To enable: 'config set latency-monitor-threshold 100'"
    echo
    echo "─ LATENCY LATEST ─"
    vk_pin latency latest | sed 's/^/  /'
    echo "─ SLOWLOG GET 5 (slowest recent commands per node) ─"
    vk_pin slowlog get 5 | sed 's/^/  /'
}

echo
echo "═══════════════════════════════════════════════════════════════════"
echo "Done. Sections you can run individually:"
echo "  --section topology  strings  hash  list  zset  stream  pubsub  info  latency"
