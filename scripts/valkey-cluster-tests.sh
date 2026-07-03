#!/usr/bin/env bash
#
# valkey-cluster-tests.sh — deep cluster-semantics test suite for the live
# Valkey cluster. Where smoke-test.sh proves the happy path, this suite
# exercises the cluster PROTOCOL — the behaviors a client library and an
# operator must both survive:
#
#   0  Topology invariants     slot coverage, pairing, announce consistency
#   1  Slot routing            keyslot math, hash tags, CROSSSLOT, key placement
#   2  MOVED                   permanent redirects, from every wrong angle
#   3  ASK + slot migration    a REAL migration: ASK redirects observed, then
#                              the slot is genuinely moved, verified, and
#                              moved back — full lifecycle, self-restoring
#   4  Replica semantics       READONLY/READWRITE, replication, WAIT acks
#   5  Pub/sub across nodes    cluster-bus broadcast vs slot-pinned SPUBLISH
#   6  Failover lifecycle      freeze a primary (DEBUG SLEEP) → detection →
#                              election → durability + API during the outage →
#                              demotion → failback → byte-identical slot map
#
# Every check narrates: WHY it runs, what a pass PROVES, and what usually
# breaks when it FAILS. A succinct per-section scoreboard prints at the end.
#
# DISRUPTIVE: section 3 migrates one slot (and restores it); section 6 takes
# one shard's primary offline for ~20s. Fine for this dev stack, never prod.
#
# By DEFAULT, the exact valkey-cli command behind each check is echoed (in
# cyan) as it runs, so you can see and copy-paste what was executed. Run this
# once first to make the printed commands directly runnable:
#   export PASS=$(kubectl -n valkey get secret valkey -o jsonpath='{.data.password}' | base64 -d)
#
# Usage:
#   ./valkey-cluster-tests.sh                 # everything, with commands echoed
#   ./valkey-cluster-tests.sh --skip-failover # no disruption to primaries
#   ./valkey-cluster-tests.sh --no-commands   # narration + verdicts, no commands
#   ./valkey-cluster-tests.sh --quiet         # verdicts only (no narration/commands)

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
set +e   # the harness decides pass/fail; a failing probe must not kill the run

SKIP_FAILOVER=0
QUIET=0
SHOW_CMDS=1     # echo the command behind each check by default
for a in "$@"; do
    case "$a" in
        --skip-failover) SKIP_FAILOVER=1 ;;
        --quiet)         QUIET=1; SHOW_CMDS=0 ;;
        --no-commands)   SHOW_CMDS=0 ;;
        --commands)      SHOW_CMDS=1 ;;   # kept for back-compat (now the default)
        -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) err "unknown arg: $a"; exit 64 ;;
    esac
done

# fd 3 = the real terminal, so command echoes bypass tcase's output capture
# (tcase runs each test in $(...), which would otherwise swallow them).
exec 3>&1
IN_TCASE=0
_cmd() { [[ $SHOW_CMDS -eq 1 && $IN_TCASE -eq 1 ]] && printf '      \033[36m$ %s\033[0m\n' "$*" >&3; return 0; }

require_cmd kubectl curl python3
CLI="$(command -v valkey-cli || command -v redis-cli || true)"
[[ -n "$CLI" ]] || { err "valkey-cli/redis-cli required (brew install valkey)"; exit 1; }

VK_PASS="$(kubectl -n valkey get secret valkey -o jsonpath='{.data.password}' | base64 -d)"
SUITE_START=$(date +%s)

# ---------------------------------------------------------------------------
# Harness. tcase <name> <why> <proves> <fails-if> <fn> [args...]
# The test body is a FUNCTION (returns 0/1, may echo diagnostics) — no
# string-injected bash -c, so quoting stays sane at this scale.
# ---------------------------------------------------------------------------
TOTAL_PASS=0; TOTAL_FAIL=0
declare -a FAILED_NAMES SECTION_NAMES SECTION_PASS SECTION_FAIL
CUR_SECTION=-1

section() {
    CUR_SECTION=$((CUR_SECTION+1))
    SECTION_NAMES[$CUR_SECTION]="$1"
    SECTION_PASS[$CUR_SECTION]=0
    SECTION_FAIL[$CUR_SECTION]=0
    echo
    printf '\033[1m=== %s ===\033[0m\n' "$1"
}

N=0
tcase() {
    local name="$1" why="$2" proves="$3" failsif="$4"; shift 4
    N=$((N+1))
    if [[ $QUIET -eq 0 ]]; then
        echo
        printf '\033[1m▶ [%02d] %s\033[0m\n' "$N" "$name"
        printf '    \033[2mwhy:      %s\033[0m\n' "$why"
        printf '    \033[2mproves:   %s\033[0m\n' "$proves"
        printf '    \033[2mfails-if: %s\033[0m\n' "$failsif"
    fi
    local t0 t1 rc out
    t0=$(date +%s)
    IN_TCASE=1
    out="$("$@" 2>&1)"; rc=$?
    IN_TCASE=0
    t1=$(date +%s)
    if [[ $rc -eq 0 ]]; then
        printf '    \033[32m→ PASS\033[0m \033[2m(%ss)\033[0m' "$((t1-t0))"
        [[ $QUIET -eq 1 ]] && printf '  %s' "$name"
        echo
        TOTAL_PASS=$((TOTAL_PASS+1)); SECTION_PASS[$CUR_SECTION]=$(( ${SECTION_PASS[$CUR_SECTION]} + 1 ))
    else
        printf '    \033[31m→ FAIL\033[0m \033[2m(%ss)\033[0m' "$((t1-t0))"
        [[ $QUIET -eq 1 ]] && printf '  %s' "$name"
        echo
        [[ -n "$out" ]] && echo "$out" | sed 's/^/      | /' | head -8
        TOTAL_FAIL=$((TOTAL_FAIL+1)); SECTION_FAIL[$CUR_SECTION]=$(( ${SECTION_FAIL[$CUR_SECTION]} + 1 ))
        FAILED_NAMES+=("[$(printf '%02d' $N)] $name")
    fi
}

# vk <ip:port> <args...> — pinned to one announced endpoint (no redirects)
vk()  { local ep="$1"; shift; _cmd "valkey-cli -h ${ep%%:*} -p ${ep##*:} -a \"\$PASS\" $*"; "$CLI" -h "${ep%%:*}" -p "${ep##*:}" -a "$VK_PASS" --no-auth-warning "$@" 2>&1; }
# vkc <ip:port> <args...> — cluster-aware (-c follows MOVED/ASK)
vkc() { local ep="$1"; shift; _cmd "valkey-cli -c -h ${ep%%:*} -p ${ep##*:} -a \"\$PASS\" $*"; "$CLI" -c -h "${ep%%:*}" -p "${ep##*:}" -a "$VK_PASS" --no-auth-warning "$@" 2>&1; }
# vkpipe <ip:port> — multiple commands over ONE connection via stdin. The
# caller's printf feeds the commands; in --commands mode we surface that hint.
vkpipe() { local ep="$1"; _cmd "printf '<cmd>\\\\n<cmd>\\\\n' | valkey-cli -h ${ep%%:*} -p ${ep##*:} -a \"\$PASS\"   # commands piped over one connection"; "$CLI" -h "${ep%%:*}" -p "${ep##*:}" -a "$VK_PASS" --no-auth-warning 2>&1; }

# ---------------------------------------------------------------------------
# Discovery
# ---------------------------------------------------------------------------
declare -a EP_NAME EP_ADDR
while IFS=$'\t' read -r name ep; do
    [[ -n "$ep" ]] || continue
    EP_NAME+=("$name"); EP_ADDR+=("$ep")
done < <(valkey_announced_endpoints valkey)
[[ ${#EP_ADDR[@]} -eq 6 ]] || { err "expected 6 announced endpoints, have ${#EP_ADDR[@]} — is the stack up?"; exit 1; }

ep_of() { local i; for i in "${!EP_NAME[@]}"; do [[ "${EP_NAME[$i]}" == "$1" ]] && { echo "${EP_ADDR[$i]}"; return; }; done; }
SEED="$(ep_of valkey-primary-0)"
PRIMARIES=("$(ep_of valkey-primary-0)" "$(ep_of valkey-primary-1)" "$(ep_of valkey-primary-2)")

node_id()          { vk "$SEED" cluster nodes | awk -v a="$1" '{split($2,x,"@"); if (x[1]==a) print $1}'; }
# Handle BOTH "lo-hi" ranges and bare single-slot entries (post-migration the
# slot map fragments into singletons; a naive split on "-" leaves hi empty → 0,
# which silently fails to match single-slot owners).
owner_ep_of_slot() { vk "$SEED" cluster nodes | awk -v s="$1" '
    /master/ { for (i=9;i<=NF;i++) {
        if ($i ~ /^\[/) continue;                 # skip [slot->-id] migration markers
        n=split($i,r,"-"); lo=r[1]+0; hi=(n>1?r[2]:r[1])+0;
        if (lo<=s+0 && hi>=s+0) { split($2,a,"@"); print a[1]; exit } } }'; }
# ownership map "slotranges@id" per primary, sorted — for before/after diffs
slot_map() { vk "$SEED" cluster nodes | awk '/master/ && NF>8 {out=$1":"; for(i=9;i<=NF;i++) out=out $i ","; print out}' | sort; }
other_primary() { local avoid="$1" ep; for ep in "${PRIMARIES[@]}"; do [[ "$ep" != "$avoid" ]] && { echo "$ep"; return; }; done; }
third_primary() { local a="$1" b="$2" ep; for ep in "${PRIMARIES[@]}"; do [[ "$ep" != "$a" && "$ep" != "$b" ]] && { echo "$ep"; return; }; done; }

RUN_ID="$$-$(date +%s)"

if [[ $SHOW_CMDS -eq 1 ]]; then
    cat <<PRE

  --commands mode: the exact valkey-cli command behind each check prints in
  cyan under it. To run them yourself, first set:

      export PASS=\$(kubectl -n valkey get secret valkey -o jsonpath='{.data.password}' | base64 -d)

  Endpoints on THIS cluster (announced ip:port, what clients dial):
$(for i in "${!EP_NAME[@]}"; do printf '      %-20s %s\n' "${EP_NAME[$i]}" "${EP_ADDR[$i]}"; done)

  valkey-cli flags used: -c = cluster mode (auto-follow MOVED/ASK); no -c =
  pinned to that one node (needed for CLUSTER/INFO/cluster-admin commands).
PRE
fi

# ===========================================================================
section "0. Topology invariants — is this even a healthy 3-shard cluster?"
# ===========================================================================

t_state() {
    local out; out="$(vk "$SEED" cluster info)"
    echo "$out" | grep -q cluster_state:ok        || { echo "$out" | grep cluster_state; return 1; }
    echo "$out" | grep -q cluster_known_nodes:6   || { echo "$out" | grep known_nodes;  return 1; }
    echo "$out" | grep -q cluster_size:3          || { echo "$out" | grep cluster_size; return 1; }
}
tcase "cluster_state ok, 6 known nodes, 3 shards" \
    "everything below assumes a formed, converged cluster" \
    "gossip has converged and a quorum of masters agree the cluster is serving" \
    "bootstrap Job failed, stale PVC split-brain, a node partitioned from the bus" \
    t_state

t_slots() {
    local out; out="$(vk "$SEED" cluster info)"
    echo "$out" | grep -q cluster_slots_assigned:16384 || { echo "$out" | grep slots_assigned; return 1; }
    echo "$out" | grep -q cluster_slots_ok:16384       || { echo "$out" | grep slots_ok; return 1; }
    echo "$out" | grep -q cluster_slots_fail:0         || { echo "$out" | grep slots_fail; return 1; }
}
tcase "all 16384 slots assigned and healthy" \
    "a cluster with orphaned slots silently rejects a fraction of the keyspace" \
    "every possible key has exactly one responsible primary right now" \
    "an aborted migration left slots unowned; a failover died halfway" \
    t_slots

t_noflags() {
    local nodes; nodes="$(vk "$SEED" cluster nodes)"
    ! echo "$nodes" | grep -qE 'fail\??[ ,]' || { echo "$nodes" | grep -E 'fail\??[ ,]'; return 1; }
    ! echo "$nodes" | grep -qE 'handshake|noaddr|disconnected' || { echo "$nodes" | grep -E 'handshake|noaddr|disconnected'; return 1; }
}
tcase "no node carries fail / pfail / handshake / noaddr flags" \
    "flags are the cluster's own early-warning system — they precede outages" \
    "every node currently sees every other node as live and addressable" \
    "bus ports unreachable through the VIP path; a node mid-crash; stale peers from an old install" \
    t_noflags

t_ep_shape() {
    local ips ports
    ips="$(printf '%s\n' "${EP_ADDR[@]}" | cut -d: -f1 | sort -u | wc -l | tr -d ' ')"
    ports="$(printf '%s\n' "${EP_ADDR[@]}" | cut -d: -f2 | sort -n | tr '\n' ' ')"
    [[ "$(printf '%s\n' "${EP_ADDR[@]}" | sort -u | wc -l | tr -d ' ')" == "6" ]] || { echo "endpoints not unique: ${EP_ADDR[*]}"; return 1; }
    local base first; first="$(echo "$ports" | awk '{print $1}')"
    local expect="" i
    for i in 0 1 2 3 4 5; do expect="$expect$((first+i)) "; done
    [[ "$ports" == "$expect" ]] || { echo "ports not contiguous: $ports (expected $expect)"; return 1; }
    echo "shape: $ips shared IP(s), ports $ports"
}
tcase "6 unique announced endpoints, contiguous port block" \
    "the sharedIP-perPort model derives ports from pod ordinal — an off-by-one strands a node" \
    "the ordinal→port math in the StatefulSet entrypoints produced the intended block" \
    "ORDINAL_OFFSET wrong on a StatefulSet; basePorts drifted between chart and reality" \
    t_ep_shape

t_announce_consistent() {
    local ep bad=0
    for ep in "${EP_ADDR[@]}"; do
        local view
        view="$(vk "$ep" cluster nodes | awk '{split($2,a,"@"); print a[1]}' | sort | tr '\n' ' ')"
        local expected
        expected="$(printf '%s\n' "${EP_ADDR[@]}" | sort | tr '\n' ' ')"
        [[ "$view" == "$expected" ]] || { echo "$ep sees: $view"; echo "expected:   $expected"; bad=1; }
    done
    return $bad
}
tcase "every node's view of all 6 announced addresses is identical" \
    "clients may bootstrap from ANY node; divergent views mean redirects depend on who you ask" \
    "announce values propagated through gossip identically — no split-brain over addressing" \
    "one pod restarted with stale env; gossip partially partitioned; two nodes claiming one endpoint" \
    t_announce_consistent

t_pairing() {
    local i pid rline
    for i in 0 1 2; do
        pid="$(node_id "$(ep_of valkey-primary-$i)")"
        rline="$(vk "$SEED" cluster nodes | awk -v a="$(ep_of valkey-secondary-$i)" '{split($2,x,"@"); if (x[1]==a) print $3, $4}')"
        [[ "$rline" == *slave*"$pid"* ]] || { echo "secondary-$i: '$rline' (expected slave of $pid)"; return 1; }
    done
}
tcase "by-index pairing: secondary-N replicates primary-N, for all three shards" \
    "the chart pairs replicas explicitly (not round-robin) so failover scenarios are predictable" \
    "the bootstrap Job's add-node --cluster-master-id wiring survived to now" \
    "a past failover was never failed back; a replica re-parented after a partition" \
    t_pairing

t_connected_slaves() {
    local ep out
    for ep in "${PRIMARIES[@]}"; do
        out="$(vk "$ep" info replication | tr -d '\r')"
        echo "$out" | grep -q '^connected_slaves:1' || { echo "$ep: $(echo "$out" | grep connected_slaves)"; return 1; }
        echo "$out" | grep -q 'slave0:.*state=online' || { echo "$ep: $(echo "$out" | grep slave0)"; return 1; }
    done
}
tcase "each primary reports exactly one ONLINE replica" \
    "a replica that is connected but not online gives you failover theatre — it can't win an election" \
    "replication links are established AND streaming on all three shards" \
    "replica can't reach its primary's announced address; replication buffer overrun" \
    t_connected_slaves

t_ping_all() {
    local ep
    for ep in "${EP_ADDR[@]}"; do
        vk "$ep" ping | grep -q PONG || { echo "$ep: no PONG"; return 1; }
    done
}
tcase "PING answers on all 6 announced endpoints from outside the cluster" \
    "the announced endpoint IS the product — if it doesn't answer, nothing else matters" \
    "the full external chain works per node: VIP listener → MetalLB IP → Service → pod" \
    "HAProxy listener missing for one port; Mac host-route gone; a pod not Ready" \
    t_ping_all

t_bus_ports() {
    local ep port
    for ep in "${EP_ADDR[@]}"; do
        port="$(( ${ep##*:} + 10000 ))"
        _cmd "nc -z -w 3 ${ep%%:*} $port   # cluster-bus port = client port + 10000"
        nc -z -w 3 "${ep%%:*}" "$port" || { echo "bus ${ep%%:*}:$port unreachable"; return 1; }
    done
}
tcase "all 6 cluster-bus ports (client+10000) reachable through the VIP" \
    "peers gossip via announced bus addresses; a blocked bus port is a slow-motion cluster_state:fail" \
    "the two-layer path forwards the bus block 1:1, not just the client ports" \
    "F5/HAProxy config lists client ports only — requirement 3 of the two-layer contract" \
    t_bus_ports

t_epochs() {
    local epochs
    epochs="$(vk "$SEED" cluster nodes | awk '/master/ {print $7}' | sort -u | wc -l | tr -d ' ')"
    [[ "$epochs" == "3" ]] || { echo "primaries share config epochs ($epochs unique of 3) — collision risk"; return 1; }
}
tcase "the three primaries hold three distinct config epochs" \
    "epoch collisions make slot-ownership conflicts unresolvable after partitions" \
    "epoch allocation behaved through whatever elections/migrations happened before now" \
    "cluster formed with forced epochs; a bug replayed an epoch after RESET" \
    t_epochs

# ===========================================================================
section "1. Slot routing — the keyspace math clients depend on"
# ===========================================================================

t_keyslot_tag() {
    local a b c
    a="$(vk "$SEED" cluster keyslot "customer:stats:{77}" | tr -d '\r')"
    b="$(vk "$SEED" cluster keyslot "customer:orders:{77}" | tr -d '\r')"
    c="$(vk "$SEED" cluster keyslot "77" | tr -d '\r')"
    [[ "$a" == "$b" && "$b" == "$c" ]] || { echo "slots: stats=$a orders=$b bare=$c"; return 1; }
}
tcase "hash-tag {77} pins different key names to one slot (== slot of '77')" \
    "the app relies on this to co-locate per-customer keys (ValkeyKeysTest proves the math; this proves the server agrees)" \
    "server-side CRC16-over-tag matches the documented contract our code assumes" \
    "someone 'simplified' key names and dropped the braces; a proxy rewrote key bytes" \
    t_keyslot_tag

t_mset_same_slot() {
    vk "$(owner_ep_of_slot "$(vk "$SEED" cluster keyslot "{ct$RUN_ID}:a" | tr -d '\r')")" \
        mset "{ct$RUN_ID}:a" 1 "{ct$RUN_ID}:b" 2 | grep -q OK
}
tcase "multi-key MSET succeeds when keys share a hash tag" \
    "multi-key commands are only legal within one slot — hash tags are how you opt in" \
    "same-tag keys really do land together, making atomic multi-key ops possible" \
    "tag stripped between client and server; keys accidentally in different slots" \
    t_mset_same_slot

t_mset_cross_slot() {
    local out; out="$(vk "$SEED" mset "ct$RUN_ID:x" 1 "ct$RUN_ID:y:different" 2)"
    [[ "$out" == *CROSSSLOT* ]] || { echo "expected CROSSSLOT, got: $out"; return 1; }
}
tcase "multi-key MSET across slots is refused with CROSSSLOT" \
    "code that worked on single-node Redis breaks EXACTLY here when moved to cluster" \
    "the cluster enforces the single-slot rule rather than silently splitting the op" \
    "you're accidentally talking to a non-cluster instance; a proxy is splitting commands" \
    t_mset_cross_slot

t_countkeys() {
    local slot owner
    slot="$(vk "$SEED" cluster keyslot "{ct$RUN_ID}:a" | tr -d '\r')"
    owner="$(owner_ep_of_slot "$slot")"
    local n; n="$(vk "$owner" cluster countkeysinslot "$slot" | tr -d '\r')"
    [[ "$n" -ge 2 ]] || { echo "countkeysinslot $slot = $n (expected >= 2)"; return 1; }
    vk "$owner" cluster getkeysinslot "$slot" 10 | grep -q "{ct$RUN_ID}:a" || { echo "getkeysinslot missing our key"; return 1; }
}
tcase "COUNTKEYSINSLOT / GETKEYSINSLOT see the keys we just wrote" \
    "these are the introspection commands resharding tools are built on" \
    "slot-level key accounting is accurate — a migration would move the right keys" \
    "keys landed on a different node than the slot map claims (ownership drift)" \
    t_countkeys

t_distribution() {
    local i owners=""
    for i in 1 2 3 4 5 6 7 8; do
        local s; s="$(vk "$SEED" cluster keyslot "ct$RUN_ID:spread:$i" | tr -d '\r')"
        owners="$owners$(owner_ep_of_slot "$s")\n"
    done
    local n; n="$(printf "%b" "$owners" | sort -u | wc -l | tr -d ' ')"
    [[ "$n" -ge 2 ]] || { echo "8 sequential keys all hashed to $n shard(s)"; return 1; }
    echo "8 keys spread across $n of 3 shards"
}
tcase "sequential key names spread across shards (no accidental hot shard)" \
    "if everything hashes to one node you have a cluster-shaped single point of failure" \
    "CRC16 dispersion works on realistic key names; capacity actually scales with shards" \
    "keys share an unintended hash tag (e.g. a '{' crept into a prefix)" \
    t_distribution

t_ttl_redirect() {
    local k="ct$RUN_ID:ttl" wrong
    wrong="$(other_primary "$(owner_ep_of_slot "$(vk "$SEED" cluster keyslot "$k" | tr -d '\r')")")"
    vkc "$wrong" set "$k" v ex 90 | grep -q OK || { echo "SET EX via redirect failed"; return 1; }
    local t; t="$(vkc "$wrong" ttl "$k" | tail -1 | tr -d '\r')"
    [[ "$t" -gt 0 && "$t" -le 90 ]] || { echo "TTL after redirect: $t"; return 1; }
}
tcase "SET EX + TTL round-trip through a MOVED redirect keeps the expiry" \
    "redirect handling must preserve command arguments exactly — TTLs are where sloppiness shows" \
    "the -c retry resends the FULL original command to the owner, options included" \
    "a client library rebuilds the command on redirect and drops trailing args" \
    t_ttl_redirect

t_read_moved() {
    local k="ct$RUN_ID:ttl" wrong out
    wrong="$(other_primary "$(owner_ep_of_slot "$(vk "$SEED" cluster keyslot "$k" | tr -d '\r')")")"
    out="$(vk "$wrong" exists "$k")"
    [[ "$out" == *MOVED* ]] || { echo "expected MOVED for EXISTS on wrong node, got: $out"; return 1; }
}
tcase "reads (EXISTS) are redirected too — MOVED is not write-only" \
    "a common misconception: 'reads work anywhere'. They don't (without READONLY on a replica)" \
    "the redirect contract covers the entire command surface uniformly" \
    "you were testing against a replica-routed proxy and never noticed" \
    t_read_moved

t_type_moved() {
    local tag="{ctt$RUN_ID}" slot wrong out cmd
    slot="$(vk "$SEED" cluster keyslot "$tag:k" | tr -d '\r')"
    wrong="$(other_primary "$(owner_ep_of_slot "$slot")")"
    for cmd in "hset $tag:h f v" "zadd $tag:z 1 m" "lpush $tag:l v" "xadd $tag:s * f v"; do
        # shellcheck disable=SC2086
        out="$(vk "$wrong" $cmd)"
        [[ "$out" == *MOVED* ]] || { echo "$cmd → expected MOVED, got: $out"; return 1; }
    done
}
tcase "hash/zset/list/stream writes all get the same MOVED treatment" \
    "the app's fan-out uses five datatypes; redirect behavior must be uniform across them" \
    "MOVED is a keyspace-layer contract, independent of command family" \
    "a datatype-specific code path (e.g. streams) bypasses redirect handling somewhere" \
    t_type_moved

t_del_cross() {
    vkc "$SEED" del "{ct$RUN_ID}:a" "{ct$RUN_ID}:b" >/dev/null
    vkc "$SEED" del "ct$RUN_ID:ttl" >/dev/null
    local left; left="$(vkc "$SEED" exists "{ct$RUN_ID}:a" | tail -1 | tr -d '\r')"
    [[ "$left" == "0" ]] || { echo "cleanup left keys behind"; return 1; }
}
tcase "cleanup: DEL through redirects removes everything this section wrote" \
    "tests must leave the keyspace as found — and DEL-via-redirect is itself a behavior worth pinning" \
    "deletes follow the same routing as writes; no orphans left on any shard" \
    "DEL executed on the wrong node's empty keyspace and 'succeeded' at deleting nothing" \
    t_del_cross

# ===========================================================================
section "2. MOVED — permanent redirects, from every angle"
# ===========================================================================
MK="ct$RUN_ID:moved"
MSLOT="$(vk "$SEED" cluster keyslot "$MK" | tr -d '\r')"
MOWNER="$(owner_ep_of_slot "$MSLOT")"
MWRONG="$(other_primary "$MOWNER")"
MTHIRD="$(third_primary "$MOWNER" "$MWRONG")"

t_moved_raw() {
    local out; out="$(vk "$MWRONG" set "$MK" v)"
    [[ "$out" == *MOVED*"$MOWNER"* ]] || { echo "got: $out"; return 1; }
}
tcase "wrong-node SET answers MOVED naming the owner's ANNOUNCED endpoint" \
    "this is the moment cluster topology becomes the client's problem — the redirect must be dialable" \
    "redirects carry the VIP:port shape external clients can actually reach" \
    "announce misconfig: redirect names a pod IP (works in-cluster, strands everyone outside)" \
    t_moved_raw

t_moved_slot_num() {
    local out; out="$(vk "$MWRONG" set "$MK" v)"
    [[ "$out" == *"MOVED $MSLOT "* ]] || { echo "expected slot $MSLOT in: $out"; return 1; }
}
tcase "the slot number in MOVED equals CLUSTER KEYSLOT's answer" \
    "smart clients cache slot→node from redirects; a wrong slot number poisons the cache" \
    "the redirect is internally consistent with the keyslot math" \
    "(would indicate a server bug — this is a canary, not an expected failure)" \
    t_moved_slot_num

t_moved_agree() {
    local o1 o2
    o1="$(vk "$MWRONG" set "$MK" v | grep -oE '[0-9.]+:[0-9]+' | tail -1)"
    o2="$(vk "$MTHIRD" set "$MK" v | grep -oE '[0-9.]+:[0-9]+' | tail -1)"
    [[ -n "$o1" && "$o1" == "$o2" ]] || { echo "wrong nodes disagree: '$o1' vs '$o2'"; return 1; }
}
tcase "both wrong primaries redirect to the SAME owner" \
    "if two nodes name different owners, the slot map has split — clients ping-pong forever" \
    "slot ownership is a cluster-wide agreement, not per-node opinion" \
    "mid-migration state leaked; an aborted SETSLOT left views diverged" \
    t_moved_agree

t_moved_follow() {
    vkc "$MWRONG" set "$MK" moved-ok | grep -q OK || return 1
    vk "$MOWNER" get "$MK" | grep -q moved-ok || { echo "value not on owner"; return 1; }
}
tcase "-c follows the MOVED and the value lands on the owner" \
    "this is what every real client (Lettuce, Jedis, valkey-cli) does on your behalf" \
    "redirect-following yields a write on exactly the right node — verified by reading the owner directly" \
    "the redirect target is unreachable (VIP listener missing for that port)" \
    t_moved_follow

t_moved_third() {
    local v; v="$(vkc "$MTHIRD" get "$MK" | tail -1 | tr -d '\r')"
    [[ "$v" == "moved-ok" ]] || { echo "got: $v"; return 1; }
}
tcase "reading via the OTHER wrong node also converges on the same value" \
    "clients bootstrap from arbitrary seeds; convergence must be seed-independent" \
    "any entry point leads to the same single source of truth for the key" \
    "asymmetric routing: one node's redirect target resolves, another's doesn't" \
    t_moved_third

t_moved_dial_target() {
    local target
    target="$(vk "$MWRONG" get "$MK" | grep -oE '[0-9.]+:[0-9]+' | tail -1)"
    [[ -n "$target" ]] || { echo "no MOVED target captured"; return 1; }
    local v; v="$(vk "$target" get "$MK" | tail -1 | tr -d '\r')"
    [[ "$v" == "moved-ok" ]] || { echo "dialing redirect target $target literally: got '$v'"; return 1; }
    vk "$target" del "$MK" >/dev/null
}
tcase "dialing the literal ip:port from the MOVED text works with no -c magic" \
    "the ultimate test of announce correctness: take the redirect at its word and dial it" \
    "the redirect string is a complete, honest address — no client-side fixups needed" \
    "the two-layer forwarding rewrites or drops ports, so announced != dialable" \
    t_moved_dial_target

# ===========================================================================
section "3. ASK + a real slot migration, there and back again"
# ===========================================================================
TAG="askmig$RUN_ID"
K_PRESENT="{${TAG}}:present"
K_ABSENT="{${TAG}}:absent"
ASK_SLOT="$(vk "$SEED" cluster keyslot "$K_PRESENT" | tr -d '\r')"
SRC_EP="$(owner_ep_of_slot "$ASK_SLOT")"
DST_EP="$(other_primary "$SRC_EP")"
SRC_ID="$(node_id "$SRC_EP")"
DST_ID="$(node_id "$DST_EP")"
BASE_MAP="$(slot_map)"

[[ $QUIET -eq 0 ]] && printf '\n\033[2m    slot %s: %s (%s…) → %s (%s…)\033[0m\n' \
    "$ASK_SLOT" "$SRC_EP" "${SRC_ID:0:8}" "$DST_EP" "${DST_ID:0:8}"

vk "$SRC_EP" set "$K_PRESENT" here >/dev/null
vk "$DST_EP" cluster setslot "$ASK_SLOT" importing "$SRC_ID" >/dev/null
vk "$SRC_EP" cluster setslot "$ASK_SLOT" migrating "$DST_ID" >/dev/null
cleanup_migration() {
    vk "$SRC_EP" cluster setslot "$ASK_SLOT" stable >/dev/null 2>&1
    vk "$DST_EP" cluster setslot "$ASK_SLOT" stable >/dev/null 2>&1
    vk "$SRC_EP" del "$K_PRESENT" >/dev/null 2>&1
    vk "$DST_EP" del "$K_PRESENT" >/dev/null 2>&1
}
trap cleanup_migration EXIT

t_ask_present() {
    local v; v="$(vk "$SRC_EP" get "$K_PRESENT" | tail -1 | tr -d '\r')"
    [[ "$v" == "here" ]] || { echo "got: $v"; return 1; }
}
tcase "mid-migration, a key still on the source is served normally" \
    "migrations move keys gradually; unmoved keys must stay available the whole time" \
    "MIGRATING state does not blanket-redirect the slot — only missing keys divert" \
    "a client treats MIGRATING as 'slot gone' and redirects everything early (thundering herd on the target)" \
    t_ask_present

t_ask_absent() {
    local out; out="$(vk "$SRC_EP" get "$K_ABSENT")"
    [[ "$out" == *"ASK $ASK_SLOT $DST_EP"* ]] || { echo "expected 'ASK $ASK_SLOT $DST_EP', got: $out"; return 1; }
}
tcase "a key NOT on the source gets ASK <slot> <target> — with the right slot AND target" \
    "ASK is the only redirect that is per-request and must NOT update the client's slot cache" \
    "the server distinguishes moved-already keys from unmoved ones, per request" \
    "client libraries that treat ASK like MOVED poison their cache mid-migration" \
    t_ask_absent

t_ask_no_asking() {
    local out; out="$(vk "$DST_EP" get "$K_ABSENT")"
    [[ "$out" == *MOVED* ]] || { echo "expected MOVED (bounce back), got: $out"; return 1; }
}
tcase "hitting the TARGET without ASKING bounces back with MOVED" \
    "the target doesn't own the slot yet; ASKING is the one-request permission slip" \
    "importing state is invisible to ordinary requests — no premature ownership" \
    "a client 'optimizes' away the ASKING and gets redirect-looped" \
    t_ask_no_asking

t_ask_asking_direct() {
    local out
    out="$(printf 'ASKING\nGET %s\n' "$K_ABSENT" | vkpipe "$DST_EP" | tail -1)"
    [[ "$out" != *MOVED* && "$out" != *ERR* ]] || { echo "ASKING+GET at target got: $out"; return 1; }
}
tcase "ASKING + GET on one connection is accepted at the target" \
    "this is the raw protocol a client must emit — worth proving without -c sugar" \
    "the one-shot ASKING flag opens exactly one command's worth of access" \
    "connection pooling splits ASKING and the command onto different connections" \
    t_ask_asking_direct

t_ask_follow() {
    local out; out="$(vkc "$SRC_EP" get "$K_ABSENT" | tail -1 | tr -d '\r')"
    [[ -z "$out" ]] || { echo "expected nil, got: $out"; return 1; }
}
tcase "-c chases the ASK end-to-end and completes the (nil) read" \
    "sum of the three previous behaviors, as a real client experiences them" \
    "the full ASK dance works over the announced two-layer endpoints" \
    "any single hop of VIP forwarding broken for the target's port" \
    t_ask_follow

t_migrate_key() {
    local out
    out="$(vk "$SRC_EP" migrate "${DST_EP%%:*}" "${DST_EP##*:}" "$K_PRESENT" 0 5000 auth "$VK_PASS" | tail -1 | tr -d '\r')"
    # Exact "OK" — NOT *OK* (which false-matches "NOKEY").
    [[ "$out" == "OK" ]] || { echo "MIGRATE: $out"; return 1; }
    # EXISTS on the source now returns ASK (slot is MIGRATING, key is gone), so
    # ask the slot's key inventory directly instead — no redirect, exact match.
    vk "$SRC_EP" cluster getkeysinslot "$ASK_SLOT" 1000 | grep -qx "$K_PRESENT" \
        && { echo "key still physically in source slot after MIGRATE"; return 1; }
    return 0
}
tcase "MIGRATE physically moves the key (source no longer has it)" \
    "this is the data-plane half of resharding — atomic move, not copy" \
    "the source can push a key to the target over the ANNOUNCED address and delete its copy" \
    "source pod can't reach the target's announced endpoint (in dev: the VIP shim is down)" \
    t_migrate_key

t_finalize() {
    vk "$DST_EP" cluster setslot "$ASK_SLOT" node "$DST_ID" >/dev/null || return 1
    vk "$SRC_EP" cluster setslot "$ASK_SLOT" node "$DST_ID" >/dev/null || return 1
    vk "$(third_primary "$SRC_EP" "$DST_EP")" cluster setslot "$ASK_SLOT" node "$DST_ID" >/dev/null || return 1
    local now; now="$(owner_ep_of_slot "$ASK_SLOT")"
    [[ "$now" == "$DST_EP" ]] || { echo "owner after finalize: $now (expected $DST_EP)"; return 1; }
}
tcase "SETSLOT NODE finalizes: the whole cluster now says the target owns the slot" \
    "the control-plane half: ownership flips only when every primary is told" \
    "slot reassignment propagates and the map converges on the new owner" \
    "finalize sent to only one node — the classic source of split slot views" \
    t_finalize

t_read_after_move() {
    local v; v="$(vkc "$SEED" get "$K_PRESENT" | tail -1 | tr -d '\r')"
    [[ "$v" == "here" ]] || { echo "got: $v"; return 1; }
    local out; out="$(vk "$SRC_EP" get "$K_PRESENT")"
    [[ "$out" == *MOVED*"$DST_EP"* ]] || { echo "old owner should MOVED to new owner, got: $out"; return 1; }
}
tcase "the key survives the move; the OLD owner now redirects to the NEW one" \
    "a migration that loses data or leaves the old owner answering is worse than no migration" \
    "data integrity through resharding + immediate redirect correctness from the ex-owner" \
    "MIGRATE copied instead of moved; finalize raced a concurrent write" \
    t_read_after_move

t_migrate_back() {
    # Full symmetric handshake in the reverse direction (the forward path's
    # mirror): SRC imports, DST migrates, move the key DST→SRC, finalize to SRC.
    vk "$SRC_EP" cluster setslot "$ASK_SLOT" importing "$DST_ID" >/dev/null
    vk "$DST_EP" cluster setslot "$ASK_SLOT" migrating "$SRC_ID" >/dev/null
    local out; out="$(vk "$DST_EP" migrate "${SRC_EP%%:*}" "${SRC_EP##*:}" "$K_PRESENT" 0 5000 auth "$VK_PASS" | tail -1 | tr -d '\r')"
    [[ "$out" == "OK" ]] || { echo "migrate back: $out"; return 1; }
    # Finalize to the original owner FIRST on that owner, then everyone else.
    vk "$SRC_EP" cluster setslot "$ASK_SLOT" node "$SRC_ID" >/dev/null
    vk "$DST_EP" cluster setslot "$ASK_SLOT" node "$SRC_ID" >/dev/null
    vk "$(third_primary "$SRC_EP" "$DST_EP")" cluster setslot "$ASK_SLOT" node "$SRC_ID" >/dev/null
    local now; now="$(owner_ep_of_slot "$ASK_SLOT")"
    [[ "$now" == "$SRC_EP" ]] || { echo "owner after restore: $now (expected $SRC_EP)"; return 1; }
}
tcase "migrate the slot BACK — ownership restored to the original primary" \
    "a test that reshapes the cluster must reshape it back; also proves migration is symmetric" \
    "the whole lifecycle is repeatable in either direction, no residue" \
    "restore path assumes state the forward path didn't actually leave" \
    t_migrate_back

t_map_restored() {
    vk "$SRC_EP" del "$K_PRESENT" >/dev/null 2>&1
    local now; now="$(slot_map)"
    [[ "$now" == "$BASE_MAP" ]] || { diff <(echo "$BASE_MAP") <(echo "$now") | head -6; return 1; }
}
tcase "the full slot map is byte-identical to the pre-migration baseline" \
    "the strongest possible 'no residue' claim — every range, every owner, compared" \
    "sections 1-3 left zero permanent topology changes" \
    "an earlier check aborted mid-migration and the trap cleanup missed a step" \
    t_map_restored
trap - EXIT

# ===========================================================================
section "4. Replica semantics — reads, redirects, and acknowledgements"
# ===========================================================================
RK="ct$RUN_ID:replica"
RSLOT="$(vk "$SEED" cluster keyslot "$RK" | tr -d '\r')"
ROWNER="$(owner_ep_of_slot "$RSLOT")"
ROWNER_NAME=""
for i in "${!EP_ADDR[@]}"; do [[ "${EP_ADDR[$i]}" == "$ROWNER" ]] && ROWNER_NAME="${EP_NAME[$i]}"; done
REPLICA_EP="$(ep_of "${ROWNER_NAME/primary/secondary}")"
vk "$ROWNER" set "$RK" replica-test >/dev/null
sleep 1

t_replica_moved() {
    local out; out="$(vk "$REPLICA_EP" get "$RK")"
    [[ "$out" == *MOVED*"$ROWNER"* ]] || { echo "got: $out"; return 1; }
}
tcase "a plain GET on the replica is redirected to its primary" \
    "replicas are not read endpoints by default — clients must opt in explicitly" \
    "default routing protects you from stale reads you didn't ask for" \
    "a proxy silently serves replica reads and callers assume they're fresh" \
    t_replica_moved

t_replica_readonly() {
    local out; out="$(printf 'READONLY\nGET %s\n' "$RK" | vkpipe "$REPLICA_EP" | tail -1)"
    [[ "$out" == "replica-test" ]] || { echo "got: $out"; return 1; }
}
tcase "READONLY on the same connection lets the replica serve the read" \
    "this is the scale-reads-from-replicas mechanism, and the value proves REPLICATION works too" \
    "the write made it primary → replica and is readable where it landed" \
    "replication link down (section 0's connected_slaves would also fail); READONLY sent on a different pooled connection" \
    t_replica_readonly

t_replica_readwrite() {
    # valkey-cli pipe mode emits a trailing blank line; grab the last NON-blank.
    local out; out="$(printf 'READONLY\nGET %s\nREADWRITE\nGET %s\n' "$RK" "$RK" | vkpipe "$REPLICA_EP" | grep -v '^[[:space:]]*$' | tail -1)"
    [[ "$out" == *MOVED* ]] || { echo "after READWRITE expected MOVED, got: $out"; return 1; }
}
tcase "READWRITE cancels READONLY — the next read is redirected again" \
    "connection state must be revocable; pooled connections get reused by non-replica-read callers" \
    "the READONLY flag is per-connection state with a working off switch" \
    "a pool 'sanitizes' connections by reconnecting and masks the state machine entirely" \
    t_replica_readwrite

t_replica_no_writes() {
    local out; out="$(printf 'READONLY\nSET %s nope\n' "$RK" | vkpipe "$REPLICA_EP" | grep -v '^[[:space:]]*$' | tail -1)"
    [[ "$out" == *MOVED* ]] || { echo "write on replica in READONLY got: $out"; return 1; }
}
tcase "even in READONLY mode, a WRITE on the replica is refused (MOVED)" \
    "READONLY grants read access, not write access — the name is the contract" \
    "there is no path to split-brain writes through the replica-read door" \
    "(a pass here is expected from any healthy server; failure means version drift or a proxy)" \
    t_replica_no_writes

t_wait_ack() {
    local out
    out="$(printf 'SET %s acked\nWAIT 1 500\n' "$RK" | vkpipe "$ROWNER" | tail -1 | tr -d '\r')"
    [[ "$out" =~ ^[0-9]+$ && "$out" -ge 1 ]] || { echo "WAIT returned: $out"; return 1; }
}
tcase "WAIT 1 500 after a write returns >=1 (the replica acknowledged)" \
    "WAIT is the strongest durability lever cluster mode offers before a failover" \
    "the replication link is not just online but keeping up in real time" \
    "replica lagging: WAIT returns 0 — your failover would lose the tail of writes" \
    t_wait_ack

t_offsets() {
    local out master_off slave_off
    out="$(vk "$ROWNER" info replication | tr -d '\r')"
    master_off="$(echo "$out" | awk -F: '/^master_repl_offset/ {print $2}')"
    slave_off="$(echo "$out" | grep '^slave0' | grep -oE 'offset=[0-9]+' | cut -d= -f2)"
    [[ -n "$master_off" && -n "$slave_off" ]] || { echo "offsets missing: m=$master_off s=$slave_off"; return 1; }
    local lag=$((master_off - slave_off))
    [[ "$lag" -lt 100000 ]] || { echo "replica lag: $lag bytes"; return 1; }
    echo "repl offset lag: $lag bytes"
}
tcase "replica offset trails the primary by a healthy margin (<100KB)" \
    "offset lag is THE metric for 'how much would a failover lose right now'" \
    "steady-state replication keeps the replica effectively current" \
    "sustained write load outpacing the replica; bus congestion through the VIP hairpin" \
    t_offsets
vk "$ROWNER" del "$RK" >/dev/null 2>&1

# ===========================================================================
section "5. Pub/sub — cluster-bus broadcast vs slot-pinned SPUBLISH"
# ===========================================================================
CH="ct$RUN_ID:chan"
SUB_LOG="/tmp/vk-cluster-sub-$RUN_ID.log"

t_cross_node_pubsub() {
    local sub_ep pub_ep
    sub_ep="${PRIMARIES[0]}"; pub_ep="${PRIMARIES[1]}"
    : > "$SUB_LOG"
    "$CLI" -h "${sub_ep%%:*}" -p "${sub_ep##*:}" -a "$VK_PASS" --no-auth-warning subscribe "$CH" > "$SUB_LOG" 2>&1 &
    local sub_pid=$!
    sleep 2
    vk "$pub_ep" publish "$CH" "hello-across-the-bus" >/dev/null
    local ok=1 i
    for i in 1 2 3 4 5; do
        grep -q "hello-across-the-bus" "$SUB_LOG" && { ok=0; break; }
        sleep 1
    done
    kill "$sub_pid" 2>/dev/null; wait "$sub_pid" 2>/dev/null
    [[ $ok -eq 0 ]] || { echo "subscriber on $sub_ep never saw the message published at $pub_ep"; cat "$SUB_LOG" | head -5; return 1; }
}
tcase "a message published on node B reaches a subscriber connected to node A" \
    "classic pub/sub rides the cluster bus to EVERY node — that's its superpower and its cost" \
    "bus connectivity carries application payloads across shards, not just gossip" \
    "bus ports blocked (messages silently vanish — no error anywhere, the worst failure mode)" \
    t_cross_node_pubsub

t_pubsub_channels() {
    local sub_ep="${PRIMARIES[2]}"
    "$CLI" -h "${sub_ep%%:*}" -p "${sub_ep##*:}" -a "$VK_PASS" --no-auth-warning subscribe "$CH-vis" >/dev/null 2>&1 &
    local sub_pid=$!
    sleep 2
    local out; out="$(vk "$sub_ep" pubsub channels "$CH-vis")"
    kill "$sub_pid" 2>/dev/null; wait "$sub_pid" 2>/dev/null
    [[ "$out" == *"$CH-vis"* ]] || { echo "PUBSUB CHANNELS on the subscribing node: $out"; return 1; }
}
tcase "PUBSUB CHANNELS shows the subscription on the node holding it" \
    "operators debug 'why is nobody receiving' with this — its scope (local!) trips everyone" \
    "subscription state is node-local even though delivery is cluster-wide" \
    "asking a DIFFERENT node and concluding there are no subscribers (see k8s_gotchas)" \
    t_pubsub_channels

SCH="{ct$RUN_ID}:sharded"
SSLOT="$(vk "$SEED" cluster keyslot "$SCH" | tr -d '\r')"
SOWNER="$(owner_ep_of_slot "$SSLOT")"
SWRONG="$(other_primary "$SOWNER")"

t_spublish_slot() {
    local a b
    a="$(vk "$SEED" cluster keyslot "$SCH" | tr -d '\r')"
    b="$(vk "$SEED" cluster keyslot "{ct$RUN_ID}:anything" | tr -d '\r')"
    [[ "$a" == "$b" ]] || { echo "sharded channel slot $a != tag slot $b"; return 1; }
}
tcase "a sharded channel hashes exactly like a key with the same tag" \
    "SSUBSCRIBE must connect to the owning shard — you find it with ordinary keyslot math" \
    "channels and keys share one addressing scheme; no separate mental model needed" \
    "(server invariant — failure would mean protocol drift between versions)" \
    t_spublish_slot

t_spublish_moved() {
    local out; out="$(vk "$SWRONG" spublish "$SCH" hi)"
    [[ "$out" == *MOVED*"$SOWNER"* ]] || { echo "got: $out"; return 1; }
}
tcase "SPUBLISH from a non-owner gets MOVED (unlike classic PUBLISH)" \
    "the entire difference between the two pub/sub flavors in one check" \
    "sharded pub/sub is slot-routed like data; classic is broadcast like gossip" \
    "confusing the two: SPUBLISH code written against a classic-channel mental model" \
    t_spublish_moved

t_spublish_owner() {
    local out; out="$(vk "$SOWNER" spublish "$SCH" hi | tail -1 | tr -d '\r')"
    [[ "$out" =~ ^[0-9]+$ ]] || { echo "got: $out"; return 1; }
}
tcase "SPUBLISH at the owner returns a subscriber count (an integer)" \
    "the app's raw-Lettuce SPUBLISH dispatch (see OrderEventPubSub) relies on exactly this reply shape" \
    "the integer reply arrives intact through the two-layer path — IntegerOutput decodes" \
    "the ByteArrayOutput trap from k8s_gotchas.md: wrong output type can't decode integer replies" \
    t_spublish_owner

# ===========================================================================
if [[ $SKIP_FAILOVER -eq 1 ]]; then
    section "6. Failover — SKIPPED (--skip-failover)"
else
    section "6. Failover lifecycle — freeze, elect, survive, demote, fail back"

    VICTIM_POD="valkey-primary-1"
    VICTIM_EP="$(ep_of valkey-primary-1)"
    HEIR_EP="$(ep_of valkey-secondary-1)"
    VICTIM_ID="$(node_id "$VICTIM_EP")"
    HEIR_ID="$(node_id "$HEIR_EP")"
    FAILOVER_BASE_MAP="$(slot_map)"
    EPOCH_BEFORE="$(vk "$SEED" cluster info | awk -F: '/cluster_current_epoch/ {print $2}' | tr -d '\r ')"

    t_baseline() {
        [[ -n "$FAILOVER_BASE_MAP" && -n "$VICTIM_ID" && -n "$HEIR_ID" ]] || return 1
        echo "victim=$VICTIM_EP (${VICTIM_ID:0:8}…)  heir=$HEIR_EP (${HEIR_ID:0:8}…)  epoch=$EPOCH_BEFORE"
    }
    tcase "baseline captured: slot map, victim/heir identities, current epoch" \
        "every later assertion diffs against this moment" \
        "we know exactly what 'fully recovered' must look like" \
        "cluster already unhealthy going in (sections 0-5 would have said so)" \
        t_baseline

    # canary written into a slot the VICTIM owns, before the lights go out
    CANARY=""
    for i in $(seq 1 200); do
        s="$(vk "$SEED" cluster keyslot "ct$RUN_ID:canary:$i" | tr -d '\r')"
        [[ "$(owner_ep_of_slot "$s")" == "$VICTIM_EP" ]] && { CANARY="ct$RUN_ID:canary:$i"; break; }
    done
    t_canary_write() {
        [[ -n "$CANARY" ]] || { echo "no key hashing to victim found in 200 tries"; return 1; }
        vk "$VICTIM_EP" set "$CANARY" survives >/dev/null
        local out; out="$(printf 'SET %s survives\nWAIT 1 500\n' "$CANARY" | vkpipe "$VICTIM_EP" | tail -1 | tr -d '\r')"
        [[ "$out" =~ ^[0-9]+$ && "$out" -ge 1 ]] || { echo "canary not replica-acked: WAIT=$out"; return 1; }
    }
    tcase "canary key written to the victim's keyspace and ACKED by its replica" \
        "the point of failover is that acknowledged data survives it — so ack something, then kill" \
        "we have a write that MUST exist after promotion, by WAIT's guarantee" \
        "WAIT=0 (lagging replica) — in which case data loss later is expected, not a failover bug" \
        t_canary_write

    if [[ $SHOW_CMDS -eq 1 ]]; then
        printf '      \033[36m# freeze the primary (run detached — blocks for 20s):\033[0m\n' >&3
        printf '      \033[36m$ kubectl -n valkey exec %s -- valkey-cli -a "$PASS" debug sleep 20\033[0m\n' "$VICTIM_POD" >&3
    fi
    kubectl -n valkey exec "$VICTIM_POD" -- \
        valkey-cli -a "$VK_PASS" --no-auth-warning debug sleep 20 >/dev/null 2>&1 &
    FREEZE_PID=$!
    [[ $QUIET -eq 0 ]] && printf '\n\033[2m    victim frozen for 20s (DEBUG SLEEP) — no client commands, no bus PONGs\033[0m\n'

    t_detect() {
        local i flags
        for i in $(seq 1 20); do
            flags="$(vk "$SEED" cluster nodes | awk -v id="$VICTIM_ID" '$1==id {print $3}')"
            [[ "$flags" == *fail* ]] && return 0
            sleep 1
        done
        echo "victim never flagged; last flags: $flags"; return 1
    }
    tcase "peers flag the frozen node 'fail' within 20s (node-timeout is 5s)" \
        "failure detection is the precondition for everything else — no flag, no election" \
        "missed bus PONGs escalate pfail → fail by quorum agreement, mechanically" \
        "node-timeout misconfigured huge; only one other node noticed (no quorum)" \
        t_detect

    t_promote() {
        local i role
        for i in $(seq 1 30); do
            role="$(vk "$SEED" cluster nodes | awk -v id="$HEIR_ID" '$1==id {print $3}')"
            [[ "$role" == *master* ]] && return 0
            sleep 1
        done
        echo "heir never promoted; last role: $role"; return 1
    }
    tcase "the by-index replica promotes itself to master" \
        "this is the payoff of running replicas at all" \
        "the election completed: the heir requested votes and a majority of masters granted them" \
        "replica too stale to stand (data-age check); only 2 masters alive = no majority edge cases" \
        t_promote

    t_epoch_bumped() {
        local now; now="$(vk "$SEED" cluster info | awk -F: '/cluster_current_epoch/ {print $2}' | tr -d '\r ')"
        [[ "$now" -gt "$EPOCH_BEFORE" ]] || { echo "epoch $EPOCH_BEFORE → $now (no bump)"; return 1; }
        echo "epoch $EPOCH_BEFORE → $now"
    }
    tcase "cluster epoch increased — proof a real election happened" \
        "epochs only move for real config changes; this rules out 'the roles were already flipped'" \
        "the promotion was a voted config change, not an artifact of our observation" \
        "(diagnostic: if this fails but promote passed, something replayed old state)" \
        t_epoch_bumped

    t_canary_survives() {
        local v; v="$(vkc "$SEED" get "$CANARY" | tail -1 | tr -d '\r')"
        [[ "$v" == "survives" ]] || { echo "canary after promotion: '$v'"; return 1; }
    }
    tcase "the replica-acked canary is readable from the promoted heir" \
        "durability through failover — the single most important promise of the whole setup" \
        "WAIT-acknowledged data crossed the failover intact" \
        "write was acked but replication link died between ack and freeze (WAIT prevents exactly this)" \
        t_canary_survives

    t_writes_during() {
        local i
        for i in $(seq 1 15); do
            vkc "$SEED" set "ct$RUN_ID:during-outage" yes 2>/dev/null | grep -q OK && return 0
            sleep 1
        done
        echo "writes never recovered during the outage"; return 1
    }
    tcase "cluster accepts writes to the failed-over slots during the outage" \
        "a failover that leaves the shard read-only until the old node returns is only half a failover" \
        "the heir serves its inherited slots immediately; total write outage was seconds" \
        "clients pinned to the dead endpoint with no topology refresh" \
        t_writes_during

    t_other_shards() {
        local ep
        for ep in "${PRIMARIES[@]}"; do
            [[ "$ep" == "$VICTIM_EP" ]] && continue
            vk "$ep" ping | grep -q PONG || { echo "$ep unhealthy during unrelated failover"; return 1; }
        done
    }
    tcase "the OTHER two shards never blinked" \
        "blast-radius check: one shard's election must not degrade its neighbors" \
        "shard isolation holds under failure — the cluster degrades by 1/3, not entirely" \
        "quorum churn starving the bus; shared resource (VIP) buckling under retry storms" \
        t_other_shards

    t_api_during() {
        local HAPROXY_IP ts cid i
        HAPROXY_IP="$(cat "$REPO_ROOT/dumps/haproxy-vm-ip" 2>/dev/null)" \
            || HAPROXY_IP="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="ExternalIP")].address}')"
        ts="$(date +%s)"
        _cmd "curl --resolve debug-demo.local:80:${HAPROXY_IP} -X POST http://debug-demo.local/api/customers -H 'Content-Type: application/json' -d '{\"name\":\"x\",\"email\":\"x@e.com\"}'"
        cid="$(curl -fsS -m 8 --resolve "debug-demo.local:80:${HAPROXY_IP}" -X POST http://debug-demo.local/api/customers \
              -H 'Content-Type: application/json' \
              -d "{\"name\":\"failover-$ts\",\"email\":\"failover-$ts@example.com\"}" 2>/dev/null \
              | python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])' 2>/dev/null)"
        [[ -n "$cid" ]] || { echo "customer create failed during outage"; return 1; }
        _cmd "curl --resolve debug-demo.local:80:${HAPROXY_IP} -X POST http://debug-demo.local/api/orders -H 'Content-Type: application/json' -d '{\"customerId\":$cid,\"amount\":1.00}'"
        for i in $(seq 1 10); do
            curl -fsS -m 8 --resolve "debug-demo.local:80:${HAPROXY_IP}" -X POST http://debug-demo.local/api/orders \
                 -H 'Content-Type: application/json' -d "{\"customerId\":$cid,\"amount\":1.00}" >/dev/null 2>&1 && return 0
            sleep 2
        done
        echo "POST /api/orders never succeeded during failover"; return 1
    }
    tcase "the app's full fan-out (POST /api/orders) works during the outage" \
        "the end-to-end claim: Lettuce inside the app refreshes topology and follows the promotion" \
        "a real client library, not just valkey-cli, rides through the failover" \
        "Lettuce topology refresh disabled/too slow; app pinned to a dead announced endpoint" \
        t_api_during

    t_demote() {
        local i line
        for i in $(seq 1 45); do
            line="$(vk "$SEED" cluster nodes | awk -v id="$VICTIM_ID" '$1==id {print $3, $4}')"
            [[ "$line" == *slave*"$HEIR_ID"* ]] && return 0
            sleep 2
        done
        echo "victim never demoted; last: $line"; return 1
    }
    tcase "the frozen node wakes, learns the epoch moved on, and demotes itself" \
        "the anti-split-brain half: the OLD master must yield, not fight" \
        "epoch arithmetic resolves the conflict automatically — no operator intervention" \
        "the wake-up node still believes it's master and serves stale writes (the nightmare scenario)" \
        t_demote
    wait "$FREEZE_PID" 2>/dev/null

    t_failback() {
        vk "$VICTIM_EP" cluster failover >/dev/null 2>&1
        local i role
        for i in $(seq 1 30); do
            role="$(vk "$SEED" cluster nodes | awk -v id="$VICTIM_ID" '$1==id {print $3}')"
            [[ "$role" == *master* && "$role" != *fail* ]] && return 0
            sleep 2
        done
        echo "failback never completed; last role: $role"; return 1
    }
    tcase "manual CLUSTER FAILOVER returns the original primary to master" \
        "operators fail back to restore rack/zone placement after incidents — the graceful path" \
        "a coordinated, lossless role swap works when both nodes are healthy" \
        "replication between the pair broken since the crash failover" \
        t_failback

    t_final_state() {
        vkc "$SEED" del "$CANARY" "ct$RUN_ID:during-outage" >/dev/null 2>&1
        local out nodes now
        out="$(vk "$SEED" cluster info)"
        nodes="$(vk "$SEED" cluster nodes)"
        echo "$out" | grep -q cluster_state:ok || { echo "$out" | grep cluster_state; return 1; }
        echo "$out" | grep -q cluster_known_nodes:6 || return 1
        echo "$nodes" | grep -qE 'fail\??[ ,]' && { echo "residual fail flags"; return 1; }
        now="$(slot_map)"
        [[ "$now" == "$FAILOVER_BASE_MAP" ]] || { diff <(echo "$FAILOVER_BASE_MAP") <(echo "$now") | head -6; return 1; }
    }
    tcase "final state: healthy, no flags, slot map byte-identical to the baseline" \
        "the suite promises to leave the cluster exactly as found — verify it, don't assume it" \
        "a full crash-failover + failback cycle is invisible after the fact" \
        "failback flipped roles but a slot moved somewhere along the way" \
        t_final_state
fi

# ===========================================================================
# Scoreboard
# ===========================================================================
ELAPSED=$(( $(date +%s) - SUITE_START ))
echo
echo "===================================================================="
printf '\033[1m Scoreboard %57s\033[0m\n' "(${ELAPSED}s total)"
echo "--------------------------------------------------------------------"
for i in "${!SECTION_NAMES[@]}"; do
    p="${SECTION_PASS[$i]}"; f="${SECTION_FAIL[$i]}"
    if [[ "$f" -eq 0 ]]; then verdict=$'\033[32mPASS\033[0m'; else verdict=$'\033[31mFAIL\033[0m'; fi
    printf ' %b  %-58s %2d/%2d\n' "$verdict" "${SECTION_NAMES[$i]:0:58}" "$p" "$((p+f))"
done
echo "--------------------------------------------------------------------"
if [[ $TOTAL_FAIL -eq 0 ]]; then
    printf ' \033[1;32m ALL %d CHECKS PASSED\033[0m — MOVED, ASK, migration, replicas,\n' "$TOTAL_PASS"
    echo "  pub/sub, and a full crash-failover cycle behave to spec, and the"
    echo "  cluster was left byte-identical to how this suite found it."
else
    printf ' \033[1;31m %d/%d FAILED\033[0m\n' "$TOTAL_FAIL" "$((TOTAL_PASS+TOTAL_FAIL))"
    for l in "${FAILED_NAMES[@]}"; do echo "   - $l"; done
fi
echo "===================================================================="
exit $TOTAL_FAIL
