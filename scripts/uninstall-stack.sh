#!/usr/bin/env bash
#
# uninstall-stack.sh — reverse everything scripts/install-stack.sh did.
# Idempotent (each step survives a missing target).
#
# The install script does three things that persist between runs:
#   1. Cluster state          — helm releases, PVCs, MetalLB config in the RD k8s cluster
#   2. A second Lima VM       — debug-demo-haproxy (the F5 stand-in)
#   3. Mac-side networking    — static routes, /etc/hosts, sysctl ip forwarding
#
# We reverse all three. For (1), rather than helm-uninstall each release one
# at a time, we just `kubectl delete namespace ...` — that cascades to every
# helm release, Deployment, Service, PVC, Secret, etc. inside. Two orders of
# magnitude simpler than the previous approach and functionally identical.
#
# Flags:
#   --keep-pvcs              preserve StatefulSet PVCs so a re-install reuses
#                            cluster state (Oracle DB, Valkey nodes.conf,
#                            Artifactory data). Uses helm-uninstall instead
#                            of namespace-delete for the stateful releases.
#   --keep-host-setup        don't touch /etc/hosts or static routes (no sudo)
#   --disable-ip-forwarding  also flip 'sysctl net.inet.ip.forwarding' to 0
#                            (opt-in — other Lima VMs / VPNs / Docker may need it)
#   --full                   also remove the MetalLB controller (upstream
#                            manifest + metallb-system namespace) — returns
#                            the RD cluster to its pre-install state
#   --yes                    skip the confirmation prompt
#
# Usage:
#   ./uninstall-stack.sh                     # symmetric teardown (one sudo prompt)
#   ./uninstall-stack.sh --full --yes        # scorched earth, no prompts
#   ./uninstall-stack.sh --keep-pvcs         # preserve data volumes
#   ./uninstall-stack.sh --keep-host-setup   # cluster-only, no sudo needed

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

APP_INGRESS_HOST="debug-demo.local"
METALLB_VERSION="v0.14.8"
OUR_NAMESPACES=(debug-demo valkey artifactory mq oracle ingress-nginx)

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
host_routes_present() { route -n get 192.168.64.51 2>/dev/null | grep -q 'gateway: 192.168.64.2'; }
etc_hosts_present()   { grep -qE "[[:space:]]${APP_INGRESS_HOST}([[:space:]]|$)" /etc/hosts 2>/dev/null; }
ip_forwarding_on()    { [[ "$(sysctl -n net.inet.ip.forwarding 2>/dev/null)" == "1" ]]; }

WILL_TOUCH_HOSTS=0
WILL_TOUCH_ROUTES=0
WILL_TOUCH_FWD=0
if [[ $KEEP_HOST_SETUP -eq 0 ]]; then
    etc_hosts_present   && WILL_TOUCH_HOSTS=1
    host_routes_present && WILL_TOUCH_ROUTES=1
fi
[[ $DISABLE_IP_FWD -eq 1 ]] && ip_forwarding_on && WILL_TOUCH_FWD=1

# ---------------------------------------------------------------------------
# Confirmation preamble
# ---------------------------------------------------------------------------
if [[ $ASSUME_YES -eq 0 ]]; then
    echo "About to remove (cluster-side):"
    if [[ $KEEP_PVCS -eq 1 ]]; then
        echo "  - Helm releases in: ${OUR_NAMESPACES[*]}"
        echo "  - Namespaces kept, PVCs kept (--keep-pvcs)"
    else
        echo "  - Namespaces: ${OUR_NAMESPACES[*]}"
        echo "    (cascades all helm releases, PVCs, Services, Deployments, etc.)"
    fi
    echo "  - MetalLB IPAddressPool 'bridge-pool' and L2Advertisement 'bridge-l2'"
    if [[ $FULL -eq 1 ]]; then
        echo "  - MetalLB controller + metallb-system namespace (--full)"
    fi
    echo "  - Lima VM 'debug-demo-haproxy' (HAProxy F5 stand-in)"
    echo
    echo "About to remove (Mac-side, needs sudo):"
    if [[ $KEEP_HOST_SETUP -eq 1 ]]; then
        echo "  --keep-host-setup — Mac-side state left untouched"
    else
        if [[ $WILL_TOUCH_ROUTES -eq 1 ]]; then
            echo "  - Static routes added by scripts/host-routes.sh"
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
# Warm sudo once, if we'll need it
# ---------------------------------------------------------------------------
if [[ $WILL_TOUCH_HOSTS -eq 1 || $WILL_TOUCH_ROUTES -eq 1 || $WILL_TOUCH_FWD -eq 1 ]]; then
    info "sudo will be needed for host-side cleanup"
    sudo -v || { err "sudo required — re-run with --keep-host-setup to skip host-side cleanup"; exit 1; }
fi

# ---------------------------------------------------------------------------
# 1. Cluster teardown
# ---------------------------------------------------------------------------
if [[ $KEEP_PVCS -eq 1 ]]; then
    # Preserve StatefulSet PVCs — helm uninstall leaves them by default, and
    # we don't delete the namespaces (which would cascade-delete PVCs).
    info "uninstalling helm releases (keeping namespaces and PVCs)..."
    for rel_ns in "app:debug-demo" "valkey:valkey" "artifactory:artifactory" \
                  "ibm-mq:mq" "oracle:oracle" "ingress-nginx:ingress-nginx"; do
        rel="${rel_ns%%:*}"; ns="${rel_ns##*:}"
        if helm -n "$ns" status "$rel" >/dev/null 2>&1; then
            helm -n "$ns" uninstall "$rel" 2>&1 | tail -1 | sed 's/^/    /'
        else
            info "    $rel ($ns): not installed"
        fi
    done
else
    # Nuke the namespaces — cascades every helm release, PVC, Deployment,
    # Service, Secret, Ingress, etc. in one step. This is what makes uninstall
    # equivalent to install in shape rather than a long list of inverses.
    info "deleting namespaces (cascades helm releases, PVCs, all resources)..."
    kubectl delete ns "${OUR_NAMESPACES[@]}" --wait=false --ignore-not-found 2>&1 \
        | sed 's/^/    /'
fi

# MetalLB pool + advertisement live in metallb-system regardless of our
# namespace strategy; remove them explicitly so re-install won't collide.
info "removing MetalLB pool + advertisement..."
kubectl -n metallb-system delete l2advertisement bridge-l2 --ignore-not-found 2>&1 | sed 's/^/    /'
kubectl -n metallb-system delete ipaddresspool bridge-pool --ignore-not-found 2>&1 | sed 's/^/    /'

# ---------------------------------------------------------------------------
# 2. --full: also remove MetalLB itself (pre-install state = no MetalLB)
# ---------------------------------------------------------------------------
if [[ $FULL -eq 1 ]]; then
    info "--full: removing MetalLB controller..."
    kubectl delete -f "https://raw.githubusercontent.com/metallb/metallb/${METALLB_VERSION}/config/manifests/metallb-native.yaml" \
        --ignore-not-found 2>&1 | tail -3 | sed 's/^/    /' || true
    kubectl delete ns metallb-system --ignore-not-found --wait=false 2>&1 | sed 's/^/    /'
fi

# ---------------------------------------------------------------------------
# 3. HAProxy Lima VM
# ---------------------------------------------------------------------------
if command -v limactl >/dev/null 2>&1; then
    info "removing HAProxy Lima VM (debug-demo-haproxy)..."
    "$SCRIPT_DIR/install-haproxy-vm.sh" --remove 2>&1 | sed 's/^/    /' || true
fi
rm -f "$REPO_ROOT/dumps/haproxy-vm-ip" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 4. Mac-side networking (mirrors install-stack.sh Phase 8)
# ---------------------------------------------------------------------------
if [[ $KEEP_HOST_SETUP -eq 0 ]]; then
    if [[ $WILL_TOUCH_ROUTES -eq 1 ]]; then
        info "removing static routes via scripts/host-routes.sh remove..."
        "$SCRIPT_DIR/host-routes.sh" remove 2>&1 | sed 's/^/    /' || true
    fi
    if [[ $WILL_TOUCH_HOSTS -eq 1 ]]; then
        info "removing /etc/hosts entry for ${APP_INGRESS_HOST}..."
        # Only match lines starting with an IP so comments aren't touched
        sudo sed -E -i.bak "/^[0-9].*[[:space:]]${APP_INGRESS_HOST}([[:space:]]|\$)/d" /etc/hosts
        if etc_hosts_present; then
            err "  /etc/hosts entry still present after sed; check by hand"
        else
            info "    /etc/hosts cleaned"
        fi
    fi
fi

if [[ $DISABLE_IP_FWD -eq 1 ]] && [[ $WILL_TOUCH_FWD -eq 1 ]]; then
    info "disabling Mac IP forwarding (net.inet.ip.forwarding=0)..."
    sudo sysctl -w net.inet.ip.forwarding=0 >/dev/null
elif ip_forwarding_on; then
    info "Mac IP forwarding: LEFT ON (pass --disable-ip-forwarding to flip to 0)"
fi

echo
info "uninstall complete. Re-run 'scripts/install-stack.sh' to rebuild."
