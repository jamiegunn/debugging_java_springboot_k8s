#!/usr/bin/env bash
#
# fix-net.sh — recover the shared socket_vmnet network when a Lima VM has lost
# its DHCP lease. This is the #1 "morning after" failure on a laptop: the Mac
# sleeps, socket_vmnet's lease lapses, the VM's shared NIC (lima0) falls back to
# link-local 169.254.x, and the k3s node goes NotReady (flannel host-gw can't
# route pod CIDRs without the 192.168.105.x address). See the memory note
# "agent-notready-lost-socket-vmnet-lease".
#
# What it does:
#   1. reports whether socket_vmnet is running,
#   2. inventories every VM's shared-net (192.168.105.x) lease,
#   3. restarts the affected VMs to reacquire the lease — TARGETED (just the
#      leaseless agents) when the server/LB are healthy, or a FULL ordered reset
#      (stop all → start server → agents → lb) when the control-plane is affected
#      or --full is given, since a wedged socket_vmnet daemon only relaunches
#      cleanly once no VM is using the shared network,
#   4. verifies each VM got a .x lease back and prints the next step.
#
# Usage:
#   scripts/k3s.sh fix-net            # detect + fix (prompts before restarting)
#   scripts/k3s.sh fix-net --full     # force the full stop-all/start-in-order reset
#   scripts/k3s.sh fix-net --check    # report only, change nothing (exit 1 if any missing)
#   scripts/k3s.sh fix-net -y         # don't prompt

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_ROOT="$SCRIPT_DIR"; while [[ "$SCRIPTS_ROOT" != / && ! -f "$SCRIPTS_ROOT/lib/common.sh" ]]; do SCRIPTS_ROOT="$(dirname "$SCRIPTS_ROOT")"; done
# shellcheck source=../../lib/common.sh
source "$SCRIPTS_ROOT/lib/common.sh"
# shellcheck source=../../lib/k3s-env.sh
source "$SCRIPTS_ROOT/lib/k3s-env.sh"
set +e

require_cmd limactl
: "${LIMA_SHARED_SUBNET:=192.168.105}"

if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then GN=$'\033[32m'; RD=$'\033[31m'; YL=$'\033[33m'; OFF=$'\033[0m'; else GN=""; RD=""; YL=""; OFF=""; fi
ok()   { printf '  %s✓%s %s\n' "$GN" "$OFF" "$*" >&2; }
warn() { printf '  %s!%s %s\n' "$YL" "$OFF" "$*" >&2; }
fail() { printf '  %s✘%s %s\n' "$RD" "$OFF" "$*" >&2; }

vm_status()    { limactl list --format '{{.Status}}' "$1" 2>/dev/null | head -1; }
vm_shared_ip() { limactl shell "$1" -- ip -4 -o addr show 2>/dev/null \
    | awk -v n="$LIMA_SHARED_SUBNET" '$4 ~ ("^" n "\\."){sub("/.*","",$4); print $4; exit}'; }

wait_for_lease() {  # poll up to ~50s for a shared-net IP; echo it or fail
    local vm="$1" i ip
    for i in $(seq 1 25); do ip="$(vm_shared_ip "$vm")"; [[ -n "$ip" ]] && { printf '%s\n' "$ip"; return 0; }; sleep 2; done
    return 1
}
stop_vm()  { info "  stopping $1 ..."; limactl stop "$1" >/dev/null 2>&1; }
start_wait() {  # start a VM, wait for its shell, then for its lease
    local vm="$1" ip i
    info "  starting $vm ..."
    limactl start "$vm" >/dev/null 2>&1 || { fail "$vm failed to start"; return 1; }
    for i in $(seq 1 60); do limactl shell "$vm" -- true 2>/dev/null && break; sleep 2; done
    if ip="$(wait_for_lease "$vm")"; then ok "$vm ← $ip"; return 0; else fail "$vm still has NO ${LIMA_SHARED_SUBNET}.x lease"; return 1; fi
}

confirm() { printf '%s%s%s [y/N] ' "$YL" "$1" "$OFF" >&2; local a; read -r a || return 1; [[ "$a" == y || "$a" == Y || "$a" == yes ]]; }

FULL=0 CHECK=0 YES=0
for a in "$@"; do case "$a" in
    --full) FULL=1 ;; --check|--dry-run) CHECK=1 ;; -y|--yes) YES=1 ;;
    -h|--help) sed -n '2,/^set /p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) err "unknown arg: $a"; exit 64 ;;
esac; done

# 1. socket_vmnet daemon
if pgrep -f '/socket_vmnet' >/dev/null 2>&1; then ok "socket_vmnet daemon running"
else warn "socket_vmnet daemon NOT running (Lima relaunches it when the first shared-net VM starts)"; fi

# 2. inventory leases across every VM
ALL=("$K3S_SERVER_VM" "${K3S_AGENT_VMS[@]}" "$K3S_LB_VM")
MISSING=()
info "checking shared-net (${LIMA_SHARED_SUBNET}.x) leases..."
for vm in "${ALL[@]}"; do
    st="$(vm_status "$vm")"
    if [[ "$st" != Running ]]; then warn "$vm: ${st:-missing} (not Running)"; MISSING+=("$vm"); continue; fi
    ip="$(vm_shared_ip "$vm")"
    if [[ -n "$ip" ]]; then ok "$vm has lease $ip"; else fail "$vm has NO ${LIMA_SHARED_SUBNET}.x lease — on link-local (169.254.x)"; MISSING+=("$vm"); fi
done

if [[ ${#MISSING[@]} -eq 0 && $FULL -eq 0 ]]; then
    info "all VMs have a shared-net lease — nothing to fix."
    info "if a node is still NotReady, run: scripts/k3s.sh doctor"
    exit 0
fi

if [[ $CHECK -eq 1 ]]; then
    fail "${#MISSING[@]} VM(s) missing a lease: ${MISSING[*]}"
    info "run: scripts/k3s.sh fix-net   (to recover)"
    exit 1
fi

# 3. decide scope: server/LB affected (or --full) → full reset; else targeted agents
SERVER_HIT=0; [[ " ${MISSING[*]} " == *" $K3S_SERVER_VM "* ]] && SERVER_HIT=1
if [[ $FULL -eq 1 || $SERVER_HIT -eq 1 ]]; then
    info "control-plane/LB affected → FULL reset: stop all VMs, then start server → agents → lb."
    if [[ $YES -eq 0 ]] && [[ -t 0 ]]; then confirm "stop and restart ALL cluster VMs now?" || { info "aborted."; exit 1; }; fi
    for vm in "${K3S_AGENT_VMS[@]}" "$K3S_LB_VM" "$K3S_SERVER_VM"; do stop_vm "$vm"; done
    rc=0
    start_wait "$K3S_SERVER_VM" || rc=1
    for vm in "${K3S_AGENT_VMS[@]}"; do start_wait "$vm" || rc=1; done
    start_wait "$K3S_LB_VM" || rc=1
else
    info "targeted recovery: restart only the leaseless VM(s): ${MISSING[*]}"
    if [[ $YES -eq 0 ]] && [[ -t 0 ]]; then confirm "restart ${MISSING[*]} now (their pods reschedule)?" || { info "aborted."; exit 1; }; fi
    for vm in "${MISSING[@]}"; do stop_vm "$vm"; done
    rc=0
    for vm in "${MISSING[@]}"; do start_wait "$vm" || rc=1; done
fi

# 4. verdict + next step
echo >&2
if [[ $rc -eq 0 ]]; then
    ok "shared-net leases restored on all VMs."
    info "next: scripts/k3s.sh install   (idempotent — re-bakes k3s node IPs + kubeconfig, finishes any unrun phases)"
    info "then: scripts/k3s.sh doctor"
else
    fail "some VMs still have NO ${LIMA_SHARED_SUBNET}.x lease — the shared network isn't coming up."
    err "  1) scripts/k3s.sh preflight     # repair socket_vmnet + Lima sudoers"
    err "  2) reboot the Mac               # clears a stale socket_vmnet socket, then: scripts/k3s.sh fix-net --full"
    err "  3) check for a VPN / network filter claiming ${LIMA_SHARED_SUBNET}.0/24"
fi
exit $rc
