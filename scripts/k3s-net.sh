#!/usr/bin/env bash
#
# k3s-net.sh — the VIP + DNS layer (P1). Turns the bare k3s cluster into a
# hostname-native one:
#
#   keepalived  on all 3 nodes → one VRRP VIP floats to a healthy node
#   dnsmasq     on the server  → *.debug-demo.local resolves to the VIP
#   /etc/resolver (Mac)        → the Mac resolves *.debug-demo.local via dnsmasq
#   CoreDNS stub (in-cluster)  → PODS resolve *.debug-demo.local via dnsmasq too
#
# The last one matters: Valkey pods gossip via ANNOUNCED HOSTNAMES, so every
# pod must resolve valkey.debug-demo.local → VIP exactly like an external
# client. On Lima's shared network the VIP is directly reachable from pods and
# the Mac (one L2 segment) — no NAT, no routes, no shim.
#
# Usage:
#   ./k3s-net.sh up          # configure + start keepalived, dnsmasq, resolvers
#   ./k3s-net.sh down        # stop them, remove the Mac resolver
#   ./k3s-net.sh status      # who owns the VIP, is DNS answering
#   ./k3s-net.sh verify      # resolve + reach the VIP by hostname, end to end
#   ./k3s-net.sh --track ingress   # (P2) retarget keepalived's health check at :80

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/k3s-env.sh
source "$SCRIPT_DIR/lib/k3s-env.sh"

require_cmd limactl kubectl

TRACK="k3s"     # k3s | ingress  (what keepalived's health check probes)
ARGS=()
for a in "$@"; do
    case "$a" in
        --track) TRACK="__next__" ;;
        *) if [[ "$TRACK" == "__next__" ]]; then TRACK="$a"; else ARGS+=("$a"); fi ;;
    esac
done
set -- "${ARGS[@]}"

vsh() { limactl shell "$1" -- sudo sh -c "$2"; }

# the VM's interface on the shared subnet (keepalived binds VRRP to it)
shared_iface() {
    limactl shell "$1" -- ip -4 -o addr show 2>/dev/null \
        | awk -v n="$LIMA_SHARED_SUBNET" '$4 ~ ("^" n "\\.") {print $2; exit}'
}

# The health check keepalived runs. k3s: kubelet healthz (up on every node once
# k3s runs). ingress: the node's :80 (P2, once the ingress DaemonSet is up) so
# the VIP only lives where HTTP is actually served.
track_script_body() {
    if [[ "$TRACK" == "ingress" ]]; then
        echo 'curl -sf -o /dev/null --max-time 2 http://127.0.0.1/healthz || curl -sf -o /dev/null --max-time 2 http://127.0.0.1:80/'
    else
        echo 'curl -sf -o /dev/null --max-time 2 http://127.0.0.1:10248/healthz'
    fi
}

configure_keepalived() {
    local vm="$1" state="$2" prio="$3" iface; iface="$(shared_iface "$vm")"
    [[ -n "$iface" ]] || { err "  $vm: no interface on $LIMA_SHARED_SUBNET"; return 1; }
    info "  $vm: keepalived $state (prio $prio) on $iface, VIP $K3S_VIP, track=$TRACK"
    local check; check="$(track_script_body)"
    vsh "$vm" "cat > /etc/keepalived/keepalived.conf <<'EOF'
vrrp_script chk_node {
    script \"$check\"
    interval 2
    fall 2
    rise 2
    timeout 3
}
vrrp_instance VI_1 {
    state $state
    interface $iface
    virtual_router_id $K3S_VRRP_ROUTER_ID
    priority $prio
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass $K3S_VRRP_AUTH_PASS
    }
    virtual_ipaddress {
        $K3S_VIP/24 dev $iface
    }
    track_script {
        chk_node
    }
}
EOF
    rc-update add keepalived default 2>/dev/null || true
    rc-service keepalived restart"
}

configure_dnsmasq() {
    local vm="$K3S_SERVER_VM" ip; ip="$(k3s_vm_ip "$vm")"
    info "  $vm: dnsmasq — *.$BASE_DOMAIN → $K3S_VIP (listen $ip)"
    vsh "$vm" "cat > /etc/dnsmasq.d/debug-demo.conf <<EOF
# Wildcard: debug-demo.local AND every *.debug-demo.local → the keepalived VIP.
address=/$BASE_DOMAIN/$K3S_VIP
domain-needed
bogus-priv
listen-address=127.0.0.1,$ip
bind-interfaces
EOF
    rc-update add dnsmasq default 2>/dev/null || true
    rc-service dnsmasq restart"
}

configure_coredns() {
    local ip; ip="$(k3s_vm_ip "$K3S_SERVER_VM")"
    info "  CoreDNS: stub zone $BASE_DOMAIN → dnsmasq@$ip (so PODS resolve it too)"
    kc -n kube-system apply -f - >/dev/null <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns-custom
  namespace: kube-system
data:
  debug-demo.server: |
    ${BASE_DOMAIN}:53 {
        errors
        cache 30
        forward . ${ip}
    }
EOF
    # nudge CoreDNS to reload the custom config
    kc -n kube-system rollout restart deployment/coredns >/dev/null 2>&1 || true
}

configure_mac_resolver() {
    local ip; ip="$(k3s_vm_ip "$K3S_SERVER_VM")"
    info "  Mac: /etc/resolver/$BASE_DOMAIN → $ip (needs sudo)"
    sudo mkdir -p /etc/resolver
    printf 'nameserver %s\n' "$ip" | sudo tee "/etc/resolver/$BASE_DOMAIN" >/dev/null
    # macOS picks up /etc/resolver changes automatically; flush to be safe.
    sudo dscacheutil -flushcache 2>/dev/null || true
    sudo killall -HUP mDNSResponder 2>/dev/null || true
}

cmd_up() {
    [[ -s "$K3S_KUBECONFIG" ]] || { err "no kubeconfig — run scripts/k3s-cluster.sh up first"; exit 1; }
    info "[1/4] keepalived on all nodes..."
    configure_keepalived "$K3S_SERVER_VM" MASTER 150 || exit 1
    local p=100
    for vm in "${K3S_AGENT_VMS[@]}"; do configure_keepalived "$vm" BACKUP "$p" || exit 1; p=$((p-10)); done
    info "[2/4] dnsmasq on the server..."
    configure_dnsmasq
    info "[3/4] CoreDNS stub zone..."
    configure_coredns
    info "[4/4] Mac resolver..."
    configure_mac_resolver
    echo
    info "VIP + DNS up. Verify: scripts/k3s-net.sh verify"
}

cmd_down() {
    for vm in "${K3S_ALL_VMS[@]}"; do
        limactl list --format '{{.Name}}' 2>/dev/null | grep -qx "$vm" || continue
        vsh "$vm" "rc-service keepalived stop 2>/dev/null; rc-update del keepalived default 2>/dev/null" >/dev/null 2>&1 || true
    done
    vsh "$K3S_SERVER_VM" "rc-service dnsmasq stop 2>/dev/null; rc-update del dnsmasq default 2>/dev/null" >/dev/null 2>&1 || true
    if [[ -f "/etc/resolver/$BASE_DOMAIN" ]]; then
        info "removing /etc/resolver/$BASE_DOMAIN (sudo)"
        sudo rm -f "/etc/resolver/$BASE_DOMAIN"; sudo dscacheutil -flushcache 2>/dev/null || true
    fi
    kc -n kube-system delete configmap coredns-custom >/dev/null 2>&1 || true
}

cmd_status() {
    info "VIP $K3S_VIP owner:"
    for vm in "${K3S_ALL_VMS[@]}"; do
        if limactl shell "$vm" -- ip -4 -o addr show 2>/dev/null | grep -q "$K3S_VIP"; then
            printf '  \033[32m%s holds the VIP\033[0m\n' "$vm"
        else
            printf '  %s\n' "$vm"
        fi
    done
    echo
    local sip; sip="$(k3s_vm_ip "$K3S_SERVER_VM")"
    info "dnsmasq @ $sip answering $APP_HOST:"
    limactl shell "$K3S_SERVER_VM" -- nslookup "$APP_HOST" "127.0.0.1" 2>/dev/null | grep -A1 "$APP_HOST" | tail -1 | sed 's/^/  /'
}

cmd_verify() {
    local fail=0
    info "1. Mac resolves $APP_HOST → (should be $K3S_VIP)"
    local got; got="$(dscacheutil -q host -a name "$APP_HOST" 2>/dev/null | awk '/ip_address/{print $2; exit}')"
    [[ "$got" == "$K3S_VIP" ]] && ok_ "  $APP_HOST → $got" || { bad_ "  $APP_HOST → ${got:-<nothing>} (expected $K3S_VIP)"; fail=1; }

    info "2. Mac resolves $VALKEY_HOST → (should be $K3S_VIP)"
    got="$(dscacheutil -q host -a name "$VALKEY_HOST" 2>/dev/null | awk '/ip_address/{print $2; exit}')"
    [[ "$got" == "$K3S_VIP" ]] && ok_ "  $VALKEY_HOST → $got" || { bad_ "  $VALKEY_HOST → ${got:-<nothing>}"; fail=1; }

    info "3. VIP $K3S_VIP is pingable from the Mac"
    ping -c1 -t2 "$K3S_VIP" >/dev/null 2>&1 && ok_ "  VIP reachable" || { bad_ "  VIP not reachable — is a node holding it? (status)"; fail=1; }

    info "4. A pod resolves $VALKEY_HOST → VIP (in-cluster CoreDNS stub)"
    got="$(kc run dns-probe-$$ --rm -i --restart=Never --image="$APP_IMAGE" --image-pull-policy=Never \
             --command -- sh -c "getent hosts $VALKEY_HOST 2>/dev/null | awk '{print \$1}'" 2>/dev/null | tr -d '\r' | head -1)"
    [[ "$got" == "$K3S_VIP" ]] && ok_ "  pod: $VALKEY_HOST → $got" || bad_ "  pod: $VALKEY_HOST → ${got:-<nothing>} (CoreDNS stub / probe image?)"

    echo
    [[ $fail -eq 0 ]] && info "VIP + DNS verified." || err "some checks failed (see above)."
    return $fail
}

ok_()  { printf '  \033[32m✔%s\033[0m\n' "$*"; }
bad_() { printf '  \033[31m✘%s\033[0m\n' "$*"; }

case "${1:-}" in
    up)     cmd_up ;;
    down)   cmd_down ;;
    status) cmd_status ;;
    verify) cmd_verify ;;
    retrack) cmd_up ;;   # re-run up with a different --track
    -h|--help|"") sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//' ;;
    *) err "unknown command: $1"; exit 64 ;;
esac
