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

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/k3s-env.sh
source "$SCRIPT_DIR/lib/k3s-env.sh"
set +e   # common.sh enables set -e; these scripts do their own error handling

require_cmd limactl kubectl

vsh() { limactl shell "$1" -- sudo sh -c "$2"; }

# the VM's interface on the shared subnet (keepalived binds VRRP to it)
shared_iface() {
    limactl shell "$1" -- ip -4 -o addr show 2>/dev/null \
        | awk -v n="$LIMA_SHARED_SUBNET" '$4 ~ ("^" n "\\.") {print $2; exit}'
}

configure_keepalived() {
    local vm="$1" state="$2" prio="$3" iface; iface="$(shared_iface "$vm")"
    [[ -n "$iface" ]] || { err "  $vm: no interface on $LIMA_SHARED_SUBNET"; return 1; }
    info "  $vm: keepalived $state (prio $prio) on $iface, VIP $K3S_VIP"
    # No vrrp_script/track: the VIP is held by VRRP priority and fails over on
    # NODE death (adverts stop). A health-track (ingress/kubelet :80) proved
    # fragile — script-security stuck-FAULT + ingress hostPort flapping left the
    # VIP down even on a healthy cluster; the doctor checks ingress/app health
    # separately, so a bare priority VIP is the robust choice here.
    vsh "$vm" "mkdir -p /etc/keepalived
cat > /etc/keepalived/keepalived.conf <<'EOF'
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
}
EOF
    rc-update add keepalived default 2>/dev/null || true
    # Start keepalived SELF-DAEMONIZING. The packaged openrc service launches it
    # with --dont-fork + command_background, which dies inside the transient
    # install shell (writes its pidfiles, then exits within ~2s); letting
    # keepalived daemonize itself detaches cleanly and survives. Clear any stale
    # instance/pidfile first so the start doesn't hit 'daemon is already running'.
    rc-service keepalived stop 2>/dev/null || true
    pkill -9 -x keepalived 2>/dev/null || true
    rm -f /run/keepalived*.pid /run/keepalived/*.pid 2>/dev/null || true
    sleep 1
    keepalived --use-file=/etc/keepalived/keepalived.conf"
}

configure_dnsmasq() {
    local vm="$K3S_SERVER_VM" ip; ip="$(k3s_vm_ip "$vm")"
    info "  $vm: dnsmasq — *.$BASE_DOMAIN → $K3S_VIP (listen $ip)"
    vsh "$vm" "mkdir -p /etc/dnsmasq.d
# Ensure dnsmasq loads drop-ins (Alpine's default conf may not set conf-dir).
grep -q '^conf-dir=/etc/dnsmasq.d' /etc/dnsmasq.conf 2>/dev/null || echo 'conf-dir=/etc/dnsmasq.d/,*.conf' >> /etc/dnsmasq.conf
cat > /etc/dnsmasq.d/debug-demo.conf <<EOF
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
    # Pods must resolve *.debug-demo.local → the VIP. We do NOT forward to the
    # host dnsmasq: pod → node-shared-IP works over TCP but times out over UDP
    # (a flannel quirk for the non-cluster node IP), and DNS is UDP. Instead we
    # answer the whole zone directly IN CoreDNS with the template plugin — every
    # name in debug-demo.local returns the VIP. No host round-trip, no UDP hole.
    # (The Mac still uses the host dnsmasq via /etc/resolver, which works fine.)
    info "  CoreDNS: template zone $BASE_DOMAIN → $K3S_VIP (pods resolve names locally)"
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
        template IN A {
            answer "{{ .Name }} 60 IN A ${K3S_VIP}"
        }
        template IN AAAA {
            rcode NXDOMAIN
        }
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

# _vip_pick_help — the "use a different VIP" recipe, shared by both error paths.
_vip_pick_help() {
    err "  Use a different, free VIP (it persists for every later command). Find one:"
    err "     for i in 200 210 220 230 240 250; do \\"
    err "       ping -c1 -t1 ${LIMA_SHARED_SUBNET}.\$i >/dev/null 2>&1 \\"
    err "         || echo \"${LIMA_SHARED_SUBNET}.\$i is free\"; done"
    err "  then install with it:"
    err "     K3S_VIP=${LIMA_SHARED_SUBNET}.240 ./tui install"
}

# preflight_vip — refuse to claim a VIP that isn't safely free. socket_vmnet's
# shared network hands out DHCP across the whole /24, so the VIP (default .100)
# is NOT reserved. Two ways it can collide, both a silent ARP conflict that
# breaks external access — caught here before keepalived ever adds the address.
preflight_vip() {
    local vm ip mac
    # (1) DHCP handed the VIP to one of OUR VMs as its real address.
    for vm in "${K3S_ALL_VMS[@]}"; do
        ip="$(k3s_vm_ip "$vm" 2>/dev/null)"
        [[ "$ip" == "$K3S_VIP" ]] || continue
        err "════════════════════════════════════════════════════════════════"
        err "The VIP $K3S_VIP is $vm's OWN DHCP address — socket_vmnet handed it out."
        err "keepalived can't use it as a floating VIP without conflicting with $vm."
        err ""
        err "FIX:"; _vip_pick_help
        err "════════════════════════════════════════════════════════════════"
        return 1
    done
    # (2) Our keepalived already holds it (as a secondary) → this is a re-run, fine.
    for vm in "${K3S_ALL_VMS[@]}"; do
        limactl shell "$vm" -- ip -4 -o addr show 2>/dev/null | grep -qw "$K3S_VIP" && return 0
    done
    # (3) A FOREIGN device on the segment holds it. Probe from the Mac: ping to
    #     force ARP resolution, then see if a real MAC answered (catches ICMP-
    #     blocked-but-ARP-responsive holders too).
    ping -c1 -t1 "$K3S_VIP" >/dev/null 2>&1
    mac="$(arp -n "$K3S_VIP" 2>/dev/null | grep -oiE '([0-9a-f]{1,2}:){5}[0-9a-f]{1,2}')"
    [[ -z "$mac" ]] && return 0   # free — good to go

    err "════════════════════════════════════════════════════════════════"
    err "VIP $K3S_VIP is ALREADY IN USE on ${LIMA_SHARED_SUBNET}.0/24 (MAC $mac)."
    err "keepalived must NOT claim it — a duplicate address is an ARP conflict"
    err "that silently breaks all external access to the cluster."
    err ""
    err "FIX — pick ONE option, then reinstall:"
    err ""
    err "  A)"; _vip_pick_help
    err ""
    err "  B) Free $K3S_VIP by stopping whatever holds it:"
    err "       limactl list          # is the holder one of your other VMs?"
    err "       arp -n $K3S_VIP   # its MAC is $mac"
    err "     stop that VM (limactl stop <name>), then rerun the install."
    err "════════════════════════════════════════════════════════════════"
    return 1
}

cmd_up() {
    [[ -s "$K3S_KUBECONFIG" ]] || { err "no kubeconfig — run scripts/k3s-cluster.sh up first"; exit 1; }
    info "[1/5] pre-flight: is VIP $K3S_VIP free on ${LIMA_SHARED_SUBNET}.0/24?"
    preflight_vip || exit 1
    info "[2/5] keepalived on all nodes..."
    configure_keepalived "$K3S_SERVER_VM" MASTER 150 || exit 1
    local p=100
    for vm in "${K3S_AGENT_VMS[@]}"; do configure_keepalived "$vm" BACKUP "$p" || exit 1; p=$((p-10)); done
    info "[3/5] dnsmasq on the server..."
    configure_dnsmasq
    info "[4/5] CoreDNS stub zone..."
    configure_coredns
    info "[5/5] Mac resolver..."
    configure_mac_resolver
    # Persist the VIP so doctor/charts/tui/etc. all agree on the value actually used.
    mkdir -p "$(dirname "$K3S_VIP_FILE")" 2>/dev/null && printf '%s\n' "$K3S_VIP" > "$K3S_VIP_FILE"
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
    -h|--help|"") sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//' ;;
    *) err "unknown command: $1"; exit 64 ;;
esac
