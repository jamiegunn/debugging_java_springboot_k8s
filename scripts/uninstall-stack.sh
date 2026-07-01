#!/usr/bin/env bash
#
# uninstall-stack.sh — symmetric tear-down of what install-stack.sh creates.
# Idempotent (each step survives a missing target).
#
# By default, reverses everything install-stack.sh added:
#   - helm releases (app, valkey, artifactory, ibm-mq, oracle, ingress-nginx)
#   - PVCs
#   - MetalLB IPAddressPool 'bridge-pool' and L2Advertisement 'bridge-l2'
#   - namespaces
#   - Lima VM 'debug-demo-haproxy' (the HAProxy F5 stand-in)
#   - static routes added by scripts/host-routes.sh
#   - /etc/hosts entry for debug-demo.local
#
# NOT touched by default because they may affect other software on this Mac:
#   - Mac IP forwarding (net.inet.ip.forwarding) — other Lima VMs, VPNs,
#     Docker Desktop, etc. may rely on it. Pass --disable-ip-forwarding
#     to flip it back off.
#   - MetalLB controller manifest itself — fast to re-apply, and multiple
#     projects on this cluster may use it. Pass --full to remove it.
#
# Flags:
#   --keep-pvcs              leave PVCs in place so re-install reuses cluster state
#                            (Oracle pre-baked DB, Valkey nodes.conf, Artifactory data)
#   --keep-host-setup        don't touch /etc/hosts or static routes (no sudo prompt)
#   --disable-ip-forwarding  also flip 'sysctl net.inet.ip.forwarding' back to 0
#                            (only if you're sure nothing else on this Mac needs it)
#   --full                   also tear down the MetalLB controller (upstream manifest)
#   --yes                    skip the confirmation prompt
#
# Usage:
#   ./uninstall-stack.sh                          # full symmetric teardown (prompts once for sudo)
#   ./uninstall-stack.sh --keep-pvcs --yes        # cluster-level clean, keep data
#   ./uninstall-stack.sh --keep-host-setup --yes  # cluster-level clean, don't touch macOS

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

APP_INGRESS_HOST="debug-demo.local"

KEEP_PVCS=0
KEEP_HOST_SETUP=0
DISABLE_IP_FWD=0
FULL=0
ASSUME_YES=0
for a in "$@"; do
    case "$a" in
        --keep-pvcs)             KEEP_PVCS=1 ;;
        --keep-host-setup)       KEEP_HOST_SETUP=1 ;;
        --disable-ip-forwarding) DISABLE_IP_FWD=1 ;;
        --full)                  FULL=1 ;;
        --yes|-y)                ASSUME_YES=1 ;;
        -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) err "unknown arg: $a"; exit 64 ;;
    esac
done

require_cmd kubectl helm

# ---------------------------------------------------------------------------
# Detect host-side state so we can tell the user exactly what will change
# ---------------------------------------------------------------------------
host_routes_present() {
    route -n get 192.168.64.51 2>/dev/null | grep -q 'gateway: 192.168.64.2'
}
etc_hosts_present() {
    grep -qE "[[:space:]]${APP_INGRESS_HOST}([[:space:]]|$)" /etc/hosts 2>/dev/null
}
ip_forwarding_on() {
    [[ "$(sysctl -n net.inet.ip.forwarding 2>/dev/null)" == "1" ]]
}

WILL_TOUCH_HOSTS=0
WILL_TOUCH_ROUTES=0
WILL_TOUCH_FWD=0
if [[ $KEEP_HOST_SETUP -eq 0 ]]; then
    etc_hosts_present && WILL_TOUCH_HOSTS=1
    host_routes_present && WILL_TOUCH_ROUTES=1
fi
if [[ $DISABLE_IP_FWD -eq 1 ]] && ip_forwarding_on; then
    WILL_TOUCH_FWD=1
fi

# ---------------------------------------------------------------------------
# Confirmation
# ---------------------------------------------------------------------------
if [[ $ASSUME_YES -eq 0 ]]; then
    echo "About to remove (cluster-side):"
    echo "  - Helm releases: app, valkey, artifactory, ibm-mq, oracle, ingress-nginx"
    if [[ $KEEP_PVCS -eq 0 ]]; then
        echo "  - All PVCs in each namespace (data is destroyed)"
    fi
    echo "  - MetalLB IPAddressPool 'bridge-pool' and L2Advertisement 'bridge-l2'"
    echo "  - Namespaces: debug-demo, valkey, artifactory, mq, oracle, ingress-nginx"
    echo "  - Lima VM 'debug-demo-haproxy' (HAProxy F5 stand-in)"
    if [[ $FULL -eq 1 ]]; then
        echo "  - MetalLB controller (--full)"
    fi
    echo
    echo "About to remove (Mac-side, needs sudo):"
    if [[ $KEEP_HOST_SETUP -eq 1 ]]; then
        echo "  --keep-host-setup — Mac-side state left untouched"
    else
        if [[ $WILL_TOUCH_ROUTES -eq 1 ]]; then
            echo "  - Static routes added by scripts/host-routes.sh (via host-routes.sh remove)"
        else
            echo "  - Static routes: none present, nothing to remove"
        fi
        if [[ $WILL_TOUCH_HOSTS -eq 1 ]]; then
            stale="$(grep -E "[[:space:]]${APP_INGRESS_HOST}([[:space:]]|$)" /etc/hosts | head -1)"
            echo "  - /etc/hosts entry: '${stale}'"
        else
            echo "  - /etc/hosts entry for ${APP_INGRESS_HOST}: none present"
        fi
    fi
    if [[ $WILL_TOUCH_FWD -eq 1 ]]; then
        echo "  - Mac IP forwarding: will flip to 0 (--disable-ip-forwarding)"
    elif [[ $DISABLE_IP_FWD -eq 0 ]] && ip_forwarding_on; then
        echo
        echo "NOT touched (by default; pass flags to override):"
        echo "  - Mac IP forwarding is on. Other Lima VMs / VPNs / Docker may need it."
        echo "    Pass --disable-ip-forwarding to flip it back to 0."
    fi
    echo
    printf "Proceed? [y/N] "
    read -r ans
    [[ "$ans" == "y" || "$ans" == "Y" ]] || { info "aborted"; exit 0; }
fi

# ---------------------------------------------------------------------------
# Warm sudo once if we're going to need it for host-side work
# ---------------------------------------------------------------------------
if [[ $WILL_TOUCH_HOSTS -eq 1 || $WILL_TOUCH_ROUTES -eq 1 || $WILL_TOUCH_FWD -eq 1 ]]; then
    info "sudo will be needed for host-side cleanup"
    sudo -v || { err "sudo required — re-run with --keep-host-setup to skip host-side cleanup"; exit 1; }
fi

# --- HAProxy VM (Lima) ------------------------------------------------------
if command -v limactl >/dev/null 2>&1; then
    info "removing HAProxy Lima VM (debug-demo-haproxy)..."
    "$SCRIPT_DIR/install-haproxy-vm.sh" --remove 2>&1 | sed 's/^/    /' || true
fi

# --- helm releases (reverse install order) ----------------------------------
info "uninstalling helm releases..."
for rel_ns in "app:debug-demo" "valkey:valkey" "artifactory:artifactory" "ibm-mq:mq" "oracle:oracle" "ingress-nginx:ingress-nginx"; do
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
    for ns in debug-demo valkey artifactory mq oracle ingress-nginx; do
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
for ns in debug-demo valkey artifactory mq oracle ingress-nginx; do
    if kubectl get ns "$ns" >/dev/null 2>&1; then
        kubectl delete ns "$ns" --wait=false 2>&1 | tail -1 | sed 's/^/    /'
    fi
done

# --- optional: MetalLB controller ------------------------------------------
if [[ $FULL -eq 1 ]]; then
    info "--full: removing MetalLB controller..."
    kubectl delete -f "https://raw.githubusercontent.com/metallb/metallb/v0.14.8/config/manifests/metallb-native.yaml" --ignore-not-found 2>&1 | tail -3 | sed 's/^/    /' || true
fi

# --- Mac-side cleanup (mirrors install-stack.sh Phase 8) --------------------
if [[ $KEEP_HOST_SETUP -eq 0 ]]; then
    if [[ $WILL_TOUCH_ROUTES -eq 1 ]]; then
        info "removing static routes via scripts/host-routes.sh remove..."
        "$SCRIPT_DIR/host-routes.sh" remove 2>&1 | sed 's/^/    /' || true
    else
        info "static routes: none present, nothing to remove"
    fi

    if [[ $WILL_TOUCH_HOSTS -eq 1 ]]; then
        info "removing /etc/hosts entry for ${APP_INGRESS_HOST}..."
        # Only match lines that start with an IP so we don't touch comments
        sudo sed -E -i.bak "/^[0-9].*[[:space:]]${APP_INGRESS_HOST}([[:space:]]|\$)/d" /etc/hosts
        # Verify
        if etc_hosts_present; then
            err "  /etc/hosts entry still present after sed; check by hand"
        else
            info "    /etc/hosts cleaned"
        fi
    else
        info "/etc/hosts entry for ${APP_INGRESS_HOST}: not present, nothing to remove"
    fi
fi

# --- Mac IP forwarding (only if user opted in with --disable-ip-forwarding) --
if [[ $DISABLE_IP_FWD -eq 1 ]]; then
    if [[ $WILL_TOUCH_FWD -eq 1 ]]; then
        info "disabling Mac IP forwarding (net.inet.ip.forwarding=0)..."
        sudo sysctl -w net.inet.ip.forwarding=0 >/dev/null
    else
        info "Mac IP forwarding: already disabled"
    fi
elif ip_forwarding_on; then
    info "Mac IP forwarding: LEFT ON (pass --disable-ip-forwarding to flip to 0)"
fi

# --- Clear cached HAProxy VM IP file ---------------------------------------
rm -f "$REPO_ROOT/dumps/haproxy-vm-ip" 2>/dev/null || true

echo
info "uninstall complete. Re-run 'scripts/install-stack.sh' to rebuild."
