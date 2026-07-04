#!/usr/bin/env bash
#
# k3s-cluster.sh — provision the 3 Lima VMs and install a k3s cluster on them,
# FULLY OFFLINE from the air-gap bundle (scripts/bundle-images.sh must have run
# first). No VM or pod pulls anything from the internet.
#
# Steps (up):
#   1. create + start ddk3s-server, ddk3s-agent-1, ddk3s-agent-2 (Lima shared net)
#   2. copy the air-gap bundle (k3s binary, k3s core images tar, all image tars)
#      into every VM
#   3. install k3s SERVER offline (--disable traefik only; servicelb/klipper is
#      KEPT to fulfill the Valkey LoadBalancer Services) → grab node-token
#   4. install k3s AGENTS offline, joined to the server
#   5. import every app/backend image tar into each node's containerd
#   6. write a kubeconfig to dumps/k3s.kubeconfig (server reachable by VIP-less
#      shared-net IP until the VIP is up)
#
# Usage:
#   ./k3s-cluster.sh up          # provision + install (idempotent)
#   ./k3s-cluster.sh down        # stop + delete the VMs
#   ./k3s-cluster.sh status      # VM + node status
#   ./k3s-cluster.sh import      # re-import image tars only (after a rebuild)
#   ./k3s-cluster.sh kubeconfig  # (re)write dumps/k3s.kubeconfig

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/k3s-env.sh
source "$SCRIPT_DIR/lib/k3s-env.sh"
# common.sh sets `set -e`; this orchestrator does its own error handling across
# many VMs and MUST NOT die on the first transient (e.g. an rsync hiccup right
# after a VM boots). Keep -u -o pipefail, drop -e.
set +e

require_cmd limactl kubectl

# limactl copy with retries — scp/rsync into a freshly-booted VM is flaky for
# the first few seconds (exit 23 = rsync partial/stat error).
lcopy() {
    local src="$1" dst="$2" i
    for i in 1 2 3 4 5; do
        limactl copy "$src" "$dst" 2>/tmp/lcopy.err && return 0
        sleep 3
    done
    err "  copy failed after retries: $src → $dst : $(tail -1 /tmp/lcopy.err 2>/dev/null)"
    return 1
}

LIMA_TEMPLATE="$REPO_ROOT/k3s/lima-node.yaml"
BUNDLE_DEST="/tmp/airgap"       # where the bundle lands inside each VM
K3S_IMAGES_DIR_VM="/var/lib/rancher/k3s/agent/images"   # k3s auto-imports tars here

# --- helpers ----------------------------------------------------------------
vm_status() {
    limactl list --format '{{.Name}} {{.Status}}' 2>/dev/null | awk -v n="$1" '$1==n {print $2; found=1} END{if(!found) print "Missing"}'
}
vm_exists() { [[ "$(vm_status "$1")" != "Missing" ]]; }

create_vm() {
    local name="$1" cpus="$2" mem="$3"
    case "$(vm_status "$name")" in
        Running) info "  $name: already running" ;;
        Stopped) info "  $name: starting..."; limactl start "$name" >/dev/null 2>&1 ;;
        Missing)
            info "  $name: creating (${cpus} cpu / ${mem} GiB)..."
            limactl create --name="$name" --tty=false \
                --cpus="$cpus" --memory="$mem" --disk="$K3S_DISK" \
                "$LIMA_TEMPLATE" >/tmp/lima-create-$name.log 2>&1 || { err "  create $name failed: $(tail -1 /tmp/lima-create-$name.log)"; return 1; }
            limactl start "$name" >/dev/null 2>&1 || { err "  start $name failed"; return 1; }
            ;;
    esac
    # wait for shell — first boot of a cloud-init qcow2 (+ apk provision) can
    # take a few minutes, so give it up to ~6 min.
    local i; for i in $(seq 1 90); do limactl shell "$name" -- true 2>/dev/null && return 0; sleep 4; done
    err "  $name not reachable via limactl shell"; return 1
}

# run a script inside a VM as root
vsh() { limactl shell "$1" -- sudo sh -c "$2"; }

# the VM's interface on the shared subnet — flannel MUST use this (the unique,
# L2-adjacent shared net), NOT eth0 (the lima user-net, 192.168.5.15 on EVERY
# VM). Without pinning it, flannel picks the lower-metric default route (eth0)
# and writes useless host-gw routes via 192.168.5.15.
shared_iface() {
    limactl shell "$1" -- ip -4 -o addr show 2>/dev/null \
        | awk -v n="$LIMA_SHARED_SUBNET" '$4 ~ ("^" n "\\.") {print $2; exit}'
}

copy_bundle() {
    local name="$1"
    info "  $name: copying air-gap bundle (k3s + core-images tar + $(ls "$AIRGAP_DIR"/images/*.tar 2>/dev/null | wc -l | tr -d ' ') image tars)..."
    # BUNDLE_DEST must be USER-owned — limactl copy connects as the lima user,
    # not root, so a sudo-created (root) dir gives rsync "Permission denied".
    # The k3s images dir is root-owned and needs sudo.
    limactl shell "$name" -- mkdir -p "$BUNDLE_DEST/images" || return 1
    vsh "$name" "mkdir -p $K3S_IMAGES_DIR_VM" || return 1
    lcopy "$AIRGAP_DIR/k3s"                                    "$name:$BUNDLE_DEST/k3s" || return 1
    lcopy "$AIRGAP_DIR/k3s-airgap-images-${K3S_ARCH}.tar.zst"  "$name:$BUNDLE_DEST/" || return 1
    # k3s auto-loads its core images from this dir at startup (no pull):
    vsh "$name" "cp $BUNDLE_DEST/k3s-airgap-images-${K3S_ARCH}.tar.zst $K3S_IMAGES_DIR_VM/ && install -m755 $BUNDLE_DEST/k3s /usr/local/bin/k3s" || return 1
    # app/backend image tars — copied now, imported after k3s is up (step 5)
    local t
    for t in "$AIRGAP_DIR"/images/*.tar; do
        [[ -e "$t" ]] || continue
        lcopy "$t" "$name:$BUNDLE_DEST/images/" || return 1
    done
    info "    $name: bundle copied"
}

import_images() {
    local name="$1"
    info "  $name: importing image tars into containerd..."
    vsh "$name" '
        for t in '"$BUNDLE_DEST"'/images/*.tar; do
            [ -e "$t" ] || continue
            /usr/local/bin/k3s ctr images import "$t" >/dev/null 2>&1 \
              && echo "    imported $(basename "$t")" \
              || echo "    FAILED   $(basename "$t")" >&2
        done'
}

install_server() {
    local name="$K3S_SERVER_VM" ip iface; ip="$(k3s_vm_ip "$name")"; iface="$(shared_iface "$name")"
    info "  $name: installing k3s server (offline) at $ip..."
    # Fully offline: the binary is at /usr/local/bin/k3s and the core images
    # tar is in the agent/images dir (k3s auto-loads it — no pull). Alpine uses
    # openrc, so run k3s server as an openrc service directly.
    #   --disable traefik   → we use ingress-nginx
    #   servicelb (klipper) KEPT → it hostPort-binds each LoadBalancer Service's
    #     port on every node and forwards to the pod; keepalived floats a VIP
    #     across the nodes so there's one stable address. klipper + keepalived
    #     are complementary (port→pod forwarding + floating VIP), not either/or.
    #   --flannel-backend=host-gw → the nodes are L2-adjacent on the shared
    #     subnet, so flannel routes pod CIDRs directly (no VXLAN). This avoids
    #     the VXLAN tx-checksum-offload bug on nested VMs that silently drops
    #     UDP (breaks ALL DNS while TCP works) — and it's faster.
    #   --tls-san VIP+host  → apiserver cert valid when reached via VIP/hostname
    #   --node-taint control-plane:NoSchedule → keep ALL workloads (app, Oracle,
    #     MQ, Valkey, ingress, klipper) OFF the control-plane node. It's small
    #     (2 cpu/3 GiB) and must not be starved by workloads; they run on the
    #     agents. Only untainted/tolerating system components (kubelet/flannel/
    #     kube-proxy are in-process, not scheduled) stay; CoreDNS reschedules.
    vsh "$name" "
        cat > /etc/init.d/k3s <<EOS
#!/sbin/openrc-run
command=/usr/local/bin/k3s
command_args=\"server --disable traefik --flannel-backend=host-gw --flannel-iface=$iface --node-ip $ip --advertise-address $ip --node-taint node-role.kubernetes.io/control-plane=true:NoSchedule --tls-san $K3S_VIP --tls-san $BASE_DOMAIN --tls-san $ip --write-kubeconfig-mode 644\"
command_background=true
pidfile=/run/k3s.pid
output_log=/var/log/k3s.log
error_log=/var/log/k3s.log
depend() { need net; }
EOS
        chmod +x /etc/init.d/k3s && rc-update add k3s default && rc-service k3s start
    "
    # wait for node-token
    local i
    for i in $(seq 1 60); do
        NODE_TOKEN="$(vsh "$name" 'cat /var/lib/rancher/k3s/server/node-token 2>/dev/null' | tr -d '\r')"
        [[ -n "$NODE_TOKEN" ]] && break
        sleep 3
    done
    [[ -n "$NODE_TOKEN" ]] || { err "  server never produced a node-token — check: limactl shell $name -- sudo tail /var/log/k3s.log"; return 1; }
    SERVER_IP="$ip"
    info "  server up; node-token acquired"
}

install_agent() {
    local name="$1" ip iface; ip="$(k3s_vm_ip "$name")"; iface="$(shared_iface "$name")"
    info "  $name: installing k3s agent (offline), joining $SERVER_IP..."
    vsh "$name" "
        cat > /etc/init.d/k3s-agent <<EOS
#!/sbin/openrc-run
command=/usr/local/bin/k3s
command_args=\"agent --server https://$SERVER_IP:6443 --token $NODE_TOKEN --flannel-iface=$iface --node-ip $ip\"
command_background=true
pidfile=/run/k3s-agent.pid
output_log=/var/log/k3s-agent.log
error_log=/var/log/k3s-agent.log
depend() { need net; }
EOS
        chmod +x /etc/init.d/k3s-agent && rc-update add k3s-agent default && rc-service k3s-agent start
    "
}

write_kubeconfig() {
    info "  writing kubeconfig → $K3S_KUBECONFIG"
    mkdir -p "$(dirname "$K3S_KUBECONFIG")"
    local ip; ip="$(k3s_vm_ip "$K3S_SERVER_VM")"
    vsh "$K3S_SERVER_VM" 'cat /etc/rancher/k3s/k3s.yaml' \
        | sed "s#https://127.0.0.1:6443#https://${ip}:6443#" > "$K3S_KUBECONFIG"
    chmod 600 "$K3S_KUBECONFIG"
    info "  use it:  export KUBECONFIG=$K3S_KUBECONFIG   (or the kc() helper in k3s-env.sh)"
}

# --- commands ---------------------------------------------------------------
cmd_up() {
    [[ -s "$AIRGAP_DIR/k3s" ]] || { err "no air-gap bundle — run scripts/bundle-images.sh first"; exit 1; }

    info "   [1/6] provisioning VMs..."
    create_vm "$K3S_SERVER_VM" "$K3S_SERVER_CPUS" "$K3S_SERVER_MEM" || exit 1
    for vm in "${K3S_AGENT_VMS[@]}"; do create_vm "$vm" "$K3S_AGENT_CPUS" "$K3S_AGENT_MEM" || exit 1; done

    info "   [2/6] copying air-gap bundle into VMs..."
    for vm in "${K3S_ALL_VMS[@]}"; do copy_bundle "$vm" || { err "bundle copy to $vm failed"; exit 1; }; done

    info "   [3/6] installing k3s server..."
    install_server || exit 1

    info "   [4/6] installing k3s agents..."
    for vm in "${K3S_AGENT_VMS[@]}"; do install_agent "$vm"; done

    info "   [5/6] importing images into every node..."
    for vm in "${K3S_ALL_VMS[@]}"; do import_images "$vm"; done

    info "   [6/6] kubeconfig + readiness..."
    write_kubeconfig
    info "  waiting for 3 nodes Ready..."
    local i
    for i in $(seq 1 60); do
        local ready; ready="$(kc get nodes --no-headers 2>/dev/null | awk '$2=="Ready"{c++} END{print c+0}')"
        [[ "$ready" -ge 3 ]] && { info "  all 3 nodes Ready"; break; }
        sleep 5
    done
    kc get nodes -o wide 2>/dev/null || err "  nodes not Ready yet — kc get nodes"
    echo
    info "cluster up. Next: scripts/k3s-net.sh (keepalived VIP + dnsmasq) — P1."
}

cmd_down() {
    info "stopping + deleting VMs..."
    for vm in "${K3S_ALL_VMS[@]}"; do
        if vm_exists "$vm"; then
            limactl stop "$vm" 2>/dev/null; limactl delete "$vm" 2>/dev/null && info "  removed $vm"
        fi
    done
    rm -f "$K3S_KUBECONFIG"
}

cmd_status() {
    info "VMs:"
    for vm in "${K3S_ALL_VMS[@]}"; do printf '  %-18s %s  (%s)\n' "$vm" "$(vm_status "$vm")" "$(k3s_vm_ip "$vm" 2>/dev/null || echo '-')"; done
    echo
    if [[ -s "$K3S_KUBECONFIG" ]]; then info "Nodes:"; kc get nodes -o wide 2>/dev/null | sed 's/^/  /' || info "  (apiserver not reachable)"; fi
}

case "${1:-}" in
    up)         cmd_up ;;
    down)       cmd_down ;;
    status)     cmd_status ;;
    import)     for vm in "${K3S_ALL_VMS[@]}"; do copy_bundle "$vm"; import_images "$vm"; done ;;
    kubeconfig) write_kubeconfig ;;
    -h|--help|"") sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//' ;;
    *) err "unknown command: $1"; exit 64 ;;
esac
