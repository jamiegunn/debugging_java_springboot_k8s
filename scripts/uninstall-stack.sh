#!/usr/bin/env bash
#
# uninstall-stack.sh — symmetric tear-down of what install-stack.sh creates.
# Idempotent (each step survives a missing target).
#
# Default: helm uninstall everything, delete PVCs, delete IPAddressPool +
# L2Advertisement, delete the per-component namespaces. Leaves the MetalLB
# controller deployment alone (the manifest is fast to re-apply).
#
# Flags:
#   --keep-pvcs        leave PVCs in place so re-install reuses cluster state
#                      (Oracle pre-baked DB, Valkey nodes.conf, Artifactory data)
#   --full             also tear down the MetalLB controller (kubectl delete -f
#                      the upstream manifest)
#   --yes              skip the confirmation prompt
#
# Usage:
#   ./uninstall-stack.sh
#   ./uninstall-stack.sh --keep-pvcs --yes

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

KEEP_PVCS=0
FULL=0
ASSUME_YES=0
for a in "$@"; do
    case "$a" in
        --keep-pvcs) KEEP_PVCS=1 ;;
        --full)      FULL=1 ;;
        --yes|-y)    ASSUME_YES=1 ;;
        -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) err "unknown arg: $a"; exit 64 ;;
    esac
done

require_cmd kubectl helm

if [[ $ASSUME_YES -eq 0 ]]; then
    echo "About to remove:"
    echo "  - Helm releases: app, valkey, artifactory, ibm-mq, oracle"
    if [[ $KEEP_PVCS -eq 0 ]]; then
        echo "  - All PVCs in each namespace (data is destroyed)"
    fi
    echo "  - MetalLB IPAddressPool 'bridge-pool' and L2Advertisement 'bridge-l2'"
    echo "  - Namespaces: debug-demo, valkey, artifactory, mq, oracle"
    if [[ $FULL -eq 1 ]]; then
        echo "  - MetalLB controller (--full)"
    fi
    printf "Proceed? [y/N] "
    read -r ans
    [[ "$ans" == "y" || "$ans" == "Y" ]] || { info "aborted"; exit 0; }
fi

# --- helm releases (reverse install order) ----------------------------------
info "uninstalling helm releases..."
for rel_ns in "app:debug-demo" "valkey:valkey" "artifactory:artifactory" "ibm-mq:mq" "oracle:oracle"; do
    rel="${rel_ns%%:*}"
    ns="${rel_ns##*:}"
    if helm -n "$ns" status "$rel" >/dev/null 2>&1; then
        helm -n "$ns" uninstall "$rel" 2>&1 | tail -1 | sed 's/^/    /'
    else
        info "    $rel ($ns): not installed"
    fi
done

# --- PVCs -------------------------------------------------------------------
if [[ $KEEP_PVCS -eq 0 ]]; then
    info "deleting PVCs..."
    for ns in debug-demo valkey artifactory mq oracle; do
        if kubectl get ns "$ns" >/dev/null 2>&1; then
            cnt=$(kubectl -n "$ns" get pvc --no-headers 2>/dev/null | wc -l | tr -d ' ')
            if [[ "$cnt" -gt 0 ]]; then
                kubectl -n "$ns" delete pvc --all --wait=false 2>&1 | tail -3 | sed 's/^/    /'
            fi
        fi
    done
else
    info "--keep-pvcs: PVCs retained"
fi

# --- MetalLB pool + advertisement ------------------------------------------
info "removing MetalLB pool / advertisement..."
kubectl -n metallb-system delete l2advertisement bridge-l2 --ignore-not-found 2>&1 | sed 's/^/    /'
kubectl -n metallb-system delete ipaddresspool bridge-pool --ignore-not-found 2>&1 | sed 's/^/    /'

# --- namespaces ------------------------------------------------------------
info "deleting namespaces..."
for ns in debug-demo valkey artifactory mq oracle; do
    if kubectl get ns "$ns" >/dev/null 2>&1; then
        kubectl delete ns "$ns" --wait=false 2>&1 | tail -1 | sed 's/^/    /'
    fi
done

# --- optional: MetalLB controller ------------------------------------------
if [[ $FULL -eq 1 ]]; then
    info "--full: removing MetalLB controller..."
    kubectl delete -f "https://raw.githubusercontent.com/metallb/metallb/v0.14.8/config/manifests/metallb-native.yaml" --ignore-not-found 2>&1 | tail -3 | sed 's/^/    /' || true
fi

echo
info "uninstall complete. Re-run 'scripts/install-stack.sh' to rebuild."
info "Static routes added by 'scripts/host-routes.sh add' (if any) are NOT removed —"
info "tear them down separately with 'scripts/host-routes.sh remove'."
