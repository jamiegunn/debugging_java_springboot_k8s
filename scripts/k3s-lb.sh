#!/usr/bin/env bash
#
# k3s-lb.sh — the LOAD-BALANCER TIER. A dedicated `ddk3s-lb` VM (the F5/NetScaler
# stand-in) that runs:
#   - keepalived — owns the VIP (192.168.105.100). The VIP lives HERE, on the LB
#     tier, NOT on the cluster nodes, so it's independent of cluster-node health
#     and load (a thrashing k3s node can't take the VIP down).
#   - HAProxy — pools HTTP :80 to the k3s ingress on every node, and passes the
#     Valkey client ports (6379-6384) through to the klipper LBs. This is the
#     "external VIP → backend pool of cluster nodes" model (Pattern A/C).
#
# Usage:
#   ./k3s-lb.sh up       # create the LB VM, wire keepalived + haproxy → k3s nodes
#   ./k3s-lb.sh down     # stop + delete the LB VM (frees the VIP)
#   ./k3s-lb.sh status   # VIP holder, haproxy backends, health

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/k3s-env.sh
source "$SCRIPT_DIR/lib/k3s-env.sh"
set +e

require_cmd limactl
LIMA_TEMPLATE="$REPO_ROOT/k3s/lima-node.yaml"
VC_BASE="${VALKEY_CLIENT_BASE:-6379}"
VC_COUNT="${VALKEY_NODE_COUNT:-6}"

vsh() { limactl shell "$1" -- sudo sh -c "$2"; }
vm_status() { limactl list --format '{{.Status}}' "$1" 2>/dev/null | head -1 | grep -q . && limactl list --format '{{.Status}}' "$1" 2>/dev/null | head -1 || echo Missing; }
lb_iface() { limactl shell "$K3S_LB_VM" -- ip -4 -o addr show 2>/dev/null | awk -v n="$LIMA_SHARED_SUBNET" '$4 ~ ("^" n "\\.") {print $2; exit}'; }

create_lb_vm() {
    case "$(vm_status "$K3S_LB_VM")" in
        Running) info "  $K3S_LB_VM: already running" ;;
        Stopped) info "  $K3S_LB_VM: starting..."; limactl start "$K3S_LB_VM" >/dev/null 2>&1 ;;
        *)  info "  $K3S_LB_VM: creating (${K3S_LB_CPUS} cpu / ${K3S_LB_MEM} GiB)..."
            limactl create --name="$K3S_LB_VM" --tty=false \
                --cpus="$K3S_LB_CPUS" --memory="$K3S_LB_MEM" --disk="$K3S_DISK" \
                "$LIMA_TEMPLATE" >/tmp/lima-create-$K3S_LB_VM.log 2>&1 \
                || { err "  create failed: $(tail -1 /tmp/lima-create-$K3S_LB_VM.log)"; return 1; }
            limactl start "$K3S_LB_VM" >/dev/null 2>&1 || { err "  start failed"; return 1; } ;;
    esac
    local i; for i in $(seq 1 90); do limactl shell "$K3S_LB_VM" -- true 2>/dev/null && break; sleep 4; done
    # haproxy on top of the template's keepalived/curl
    vsh "$K3S_LB_VM" "command -v haproxy >/dev/null || apk add --no-cache haproxy 2>/dev/null || \
        echo 'WARN: apk add haproxy failed (air-gapped without a local mirror?)' >&2"
}

# refuse to claim the VIP if a FOREIGN device holds it (shared-net DHCP isn't
# reserved). The LB VM holding it already = a re-run. Ping is the reliable
# free/held signal here — a Lima VM holding the VIP answers ICMP, and unlike the
# ARP cache (which can hold a STALE entry after a holder goes) ping reflects the
# live state.
preflight_vip() {
    limactl shell "$K3S_LB_VM" -- ip -4 -o addr show 2>/dev/null | grep -qw "$K3S_VIP" && return 0
    if ping -c1 -t1 "$K3S_VIP" >/dev/null 2>&1; then
        local mac; mac="$(arp -n "$K3S_VIP" 2>/dev/null | grep -oiE '([0-9a-f]{1,2}:){5}[0-9a-f]{1,2}')"
        err "VIP $K3S_VIP is already in use on ${LIMA_SHARED_SUBNET}.0/24 (MAC ${mac:-unknown})."
        err "Free it, or install with a different VIP:  K3S_VIP=${LIMA_SHARED_SUBNET}.240 ./tui install"
        return 1
    fi
    return 0
}

configure_keepalived() {
    local iface; iface="$(lb_iface)"
    [[ -n "$iface" ]] || { err "  $K3S_LB_VM: no interface on $LIMA_SHARED_SUBNET"; return 1; }
    info "  keepalived on $K3S_LB_VM: VIP $K3S_VIP (MASTER) on $iface"
    vsh "$K3S_LB_VM" "mkdir -p /etc/keepalived
cat > /etc/keepalived/keepalived.conf <<'EOF'
vrrp_instance VI_1 {
    state MASTER
    interface $iface
    virtual_router_id $K3S_VRRP_ROUTER_ID
    priority 150
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass $K3S_VRRP_AUTH_PASS
    }
    virtual_ipaddress {
        $K3S_VIP/24 dev $iface
    }
}
EOF
    rc-update add keepalived default 2>/dev/null || true
    rc-service keepalived stop 2>/dev/null || true
    pkill -9 -x keepalived 2>/dev/null || true
    rm -f /run/keepalived*.pid /run/keepalived/*.pid 2>/dev/null || true
    sleep 1
    keepalived --use-file=/etc/keepalived/keepalived.conf"
}

configure_haproxy() {
    info "  haproxy on $K3S_LB_VM: :80 → k3s ingress; :${VC_BASE}-$((VC_BASE+VC_COUNT-1)) → Valkey klipper"
    # Backends = the WORKER agents only. The control-plane node is tainted, so
    # ingress-nginx and klipper svclb don't run there — pooling to it would just
    # be a permanently-down backend.
    local ips=() vm ip
    for vm in "${K3S_AGENT_VMS[@]}"; do ip="$(k3s_vm_ip "$vm")"; [[ -n "$ip" ]] && ips+=("$ip"); done
    [[ ${#ips[@]} -gt 0 ]] || { err "  no agent node IPs — is the cluster up?"; return 1; }

    # build the config on the host, then push it in
    local cfg; cfg="$(cat <<'HDR'
global
    maxconn 8192
defaults
    timeout connect 5s
    timeout client  1h
    timeout server  1h
    retries 2

# HTTP → the k3s ingress-nginx hostPort :80 on every node (health-checked, so
# HAProxy routes around a node whose ingress is down/starved).
frontend http_in
    mode http
    bind *:80
    default_backend k3s_ingress
backend k3s_ingress
    mode http
    balance roundrobin
    option httpchk
    http-check send meth GET uri /healthz
HDR
)"
    local i=1
    for ip in "${ips[@]}"; do cfg+=$'\n'"    server node$i $ip:80 check"; i=$((i+1)); done

    # Valkey: one TCP frontend/backend per client port. klipper binds each port
    # on every node and routes it to the owning shard's pod, so round-robin
    # across nodes for a given port always lands on the same shard.
    local p
    for ((p=VC_BASE; p<VC_BASE+VC_COUNT; p++)); do
        cfg+=$'\n\n'"frontend valkey_${p}"$'\n'"    mode tcp"$'\n'"    bind *:${p}"$'\n'"    default_backend valkey_${p}_be"
        cfg+=$'\n'"backend valkey_${p}_be"$'\n'"    mode tcp"$'\n'"    balance roundrobin"
        i=1; for ip in "${ips[@]}"; do cfg+=$'\n'"    server node$i $ip:${p} check"; i=$((i+1)); done
    done

    printf '%s\n' "$cfg" | vsh "$K3S_LB_VM" "cat > /etc/haproxy/haproxy.cfg
    rc-update add haproxy default 2>/dev/null || true
    rc-service haproxy stop 2>/dev/null || true; pkill -9 -x haproxy 2>/dev/null || true; sleep 1
    haproxy -f /etc/haproxy/haproxy.cfg -c >/dev/null 2>&1 && haproxy -D -f /etc/haproxy/haproxy.cfg -p /run/haproxy.pid || echo 'WARN: haproxy config invalid' >&2"
}

cmd_up() {
    info "[1/4] LB VM ($K3S_LB_VM)..."
    create_lb_vm || return 1
    info "[2/4] VIP pre-flight..."
    preflight_vip || return 1
    info "[3/4] keepalived (VIP)..."
    configure_keepalived || return 1
    info "[4/4] haproxy (pools → k3s nodes)..."
    configure_haproxy || return 1
    mkdir -p "$(dirname "$K3S_VIP_FILE")" 2>/dev/null && printf '%s\n' "$K3S_VIP" > "$K3S_VIP_FILE"
    echo
    info "LB tier up. VIP $K3S_VIP on $K3S_LB_VM → k3s ingress + Valkey."
}

cmd_down() {
    if [[ "$(vm_status "$K3S_LB_VM")" != Missing ]]; then
        vsh "$K3S_LB_VM" "rc-service haproxy stop 2>/dev/null; rc-service keepalived stop 2>/dev/null; pkill -9 -x haproxy keepalived 2>/dev/null" 2>/dev/null
        limactl stop -f "$K3S_LB_VM" >/dev/null 2>&1
        limactl delete -f "$K3S_LB_VM" >/dev/null 2>&1 && info "  removed $K3S_LB_VM" || err "  FAILED to delete $K3S_LB_VM"
    else info "  $K3S_LB_VM already gone"; fi
}

cmd_status() {
    printf '  %-14s %s\n' "$K3S_LB_VM:" "$(vm_status "$K3S_LB_VM")"
    limactl shell "$K3S_LB_VM" -- sh -c '
        echo -n "  VIP '"$K3S_VIP"': "; ip -4 -o addr show 2>/dev/null | grep -qw '"$K3S_VIP"' && echo held || echo NO
        echo -n "  keepalived: "; pgrep -x keepalived >/dev/null && echo up || echo down
        echo -n "  haproxy:    "; pgrep -x haproxy >/dev/null && echo up || echo down' 2>/dev/null
    ping -c1 -t2 "$K3S_VIP" >/dev/null 2>&1 && echo "  VIP reachable from Mac: yes" || echo "  VIP reachable from Mac: NO"
}

case "${1:-}" in
    up)     cmd_up ;;
    down)   cmd_down ;;
    status) cmd_status ;;
    -h|--help|"") sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//' ;;
    *) err "unknown command: $1"; exit 64 ;;
esac
