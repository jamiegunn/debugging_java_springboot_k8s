#!/usr/bin/env bash
#
# k3s-net.sh — the DNS layer. Makes *.debug-demo.local resolve to the VIP for
# both the Mac and pods. (The VIP itself is served by the LB tier — see
# scripts/k3s-lb.sh; this script no longer runs keepalived.)
#
#   dnsmasq     on the server  → *.debug-demo.local resolves to the VIP
#   /etc/resolver (Mac)        → the Mac resolves *.debug-demo.local via dnsmasq
#   CoreDNS stub (in-cluster)  → PODS resolve *.debug-demo.local locally → VIP
#
# The last one matters: Valkey clients (app pods and external) dial announced
# HOSTNAMES, so every pod must resolve valkey.debug-demo.local → VIP exactly
# like an external client.
#
# Usage:
#   ./k3s-net.sh up          # configure dnsmasq + CoreDNS stub + Mac resolver
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

cmd_up() {
    # DNS only. The VIP itself lives on the LB tier (scripts/k3s-lb.sh); DNS just
    # answers *.debug-demo.local → that VIP, for both the Mac and pods.
    [[ -s "$K3S_KUBECONFIG" ]] || { err "no kubeconfig — run scripts/k3s-cluster.sh up first"; exit 1; }
    info "[1/3] dnsmasq on the server..."
    configure_dnsmasq
    info "[2/3] CoreDNS stub zone..."
    configure_coredns
    info "[3/3] Mac resolver..."
    configure_mac_resolver
    echo
    info "DNS up (*.$BASE_DOMAIN → $K3S_VIP). The VIP is served by the LB tier: scripts/k3s-lb.sh up"
}

cmd_down() {
    vsh "$K3S_SERVER_VM" "rc-service dnsmasq stop 2>/dev/null; rc-update del dnsmasq default 2>/dev/null" >/dev/null 2>&1 || true
    if [[ -f "/etc/resolver/$BASE_DOMAIN" ]]; then
        info "removing /etc/resolver/$BASE_DOMAIN (sudo)"
        sudo rm -f "/etc/resolver/$BASE_DOMAIN"; sudo dscacheutil -flushcache 2>/dev/null || true
    fi
    kc -n kube-system delete configmap coredns-custom >/dev/null 2>&1 || true
}

cmd_status() {
    info "VIP $K3S_VIP (served by the LB tier — scripts/k3s-lb.sh status):"
    ping -c1 -t2 "$K3S_VIP" >/dev/null 2>&1 && printf '  \033[32mreachable\033[0m\n' || printf '  \033[31mnot reachable — is the LB VM up?\033[0m\n'
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
