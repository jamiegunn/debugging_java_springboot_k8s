#!/usr/bin/env bash
#
# k3s-uninstall.sh — reverse k3s-install.sh. Symmetric teardown:
#   - remove the Mac /etc/resolver entry (sudo) + keepalived/dnsmasq on the VMs
#   - delete the 3 Lima VMs (this takes the whole cluster, charts, PVCs with it)
#   - remove the local kubeconfig
#
# The air-gap bundle in dumps/airgap is KEPT by default (rebuilding it is the
# slow part); pass --purge-bundle to delete it too.
#
# Usage:
#   ./k3s-uninstall.sh            # tear everything down (one sudo prompt)
#   ./k3s-uninstall.sh --purge-bundle
#   ./k3s-uninstall.sh --yes      # no confirmation

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/k3s-env.sh
source "$SCRIPT_DIR/lib/k3s-env.sh"
set +e

PURGE_BUNDLE=0
ASSUME_YES=0
for a in "$@"; do
    case "$a" in
        --purge-bundle) PURGE_BUNDLE=1 ;;
        --yes|-y)       ASSUME_YES=1 ;;
        -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) err "unknown arg: $a"; exit 64 ;;
    esac
done

if [[ $ASSUME_YES -eq 0 ]]; then
    echo "About to remove:"
    echo "  - Mac /etc/resolver/$BASE_DOMAIN (sudo)"
    echo "  - Lima VMs: ${K3S_ALL_VMS[*]} $K3S_LB_VM  (deletes the cluster + LB tier + data)"
    echo "  - kubeconfig: $K3S_KUBECONFIG"
    [[ $PURGE_BUNDLE -eq 1 ]] && echo "  - air-gap bundle: $AIRGAP_DIR"
    printf "Proceed? [y/N] "; read -r ans
    [[ "$ans" == y || "$ans" == Y ]] || { info "aborted"; exit 0; }
fi

# Mac resolver (+ VM-side net services, best-effort before the VMs go)
"$SCRIPT_DIR/k3s-net.sh" down 2>/dev/null

info "deleting Lima VMs..."
FAILED_VMS=()
for vm in "${K3S_ALL_VMS[@]}" "$K3S_LB_VM"; do
    limactl list --format '{{.Name}}' 2>/dev/null | grep -qx "$vm" || continue
    limactl stop -f "$vm" >/dev/null 2>&1
    # force-delete; retry once in case it raced the force-stop, then VERIFY —
    # the old code hid delete failures under 2>/dev/null, so a VM (and its
    # keepalived VIP) could survive an "uninstall complete".
    limactl delete -f "$vm" >/dev/null 2>&1 || { sleep 1; limactl delete -f "$vm" >/dev/null 2>&1; }
    if limactl list --format '{{.Name}}' 2>/dev/null | grep -qx "$vm"; then
        err "  FAILED to delete $vm"; FAILED_VMS+=("$vm")
    else
        info "  removed $vm"
    fi
done

rm -f "$K3S_KUBECONFIG" "$K3S_VIP_FILE"
if [[ $PURGE_BUNDLE -eq 1 ]]; then
    info "purging air-gap bundle $AIRGAP_DIR..."
    rm -rf "$AIRGAP_DIR"
fi

echo
if [[ ${#FAILED_VMS[@]} -gt 0 ]]; then
    err "uninstall INCOMPLETE — these VMs are still running (their keepalived VIP is still up):"
    for vm in "${FAILED_VMS[@]}"; do err "    limactl stop -f $vm && limactl delete -f $vm"; done
    exit 1
fi
info "uninstall complete. Rebuild with: scripts/k3s-install.sh"
