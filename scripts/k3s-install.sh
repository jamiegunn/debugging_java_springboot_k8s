#!/usr/bin/env bash
#
# k3s-install.sh — P4. The one front door for the multi-node k3s stack. Chains
# every phase, each of which is an idempotent standalone script:
#
#   0  air-gap bundle    scripts/bundle-images.sh   (skippable if already built)
#   1  cluster           scripts/k3s-cluster.sh up  (3 VMs + k3s, offline)
#   2  DNS               scripts/k3s-net.sh up      (dnsmasq + CoreDNS + resolver → VIP)
#   3  platform          scripts/k3s-platform.sh up (ingress-nginx DaemonSet)
#   4  charts            scripts/k3s-charts.sh up   (oracle, mq, valkey, app)
#   5  LB tier           scripts/k3s-lb.sh up       (ddk3s-lb VM: keepalived VIP + HAProxy)
#   6  verify + smoke                                 (VIP + DNS reachable by hostname)
#
# Everything is air-gapped and hostname-native. Replaces the Rancher Desktop
# install-stack.sh end to end.
#
# Usage:
#   ./k3s-install.sh                 # full install (prompts for sudo once, for the Mac resolver)
#   ./k3s-install.sh --skip-bundle   # reuse an existing dumps/airgap bundle
#   ./k3s-install.sh --skip-smoke    # don't run the final smoke test

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/k3s-env.sh
source "$SCRIPT_DIR/lib/k3s-env.sh"
set +e

SKIP_BUNDLE=0
SKIP_SMOKE=0
for a in "$@"; do
    case "$a" in
        --skip-bundle) SKIP_BUNDLE=1 ;;
        --skip-smoke)  SKIP_SMOKE=1 ;;
        -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) err "unknown arg: $a"; exit 64 ;;
    esac
done

banner() {
    cat <<'EOF'

  ┌──────────────────────────────────────────────────────────────┐
  │  debug-demo on multi-node k3s — air-gapped, keepalived VIP,   │
  │  everything by hostname. 3 Lima VMs (1 server + 2 agents).    │
  └──────────────────────────────────────────────────────────────┘
EOF
}

banner

# --- pre-flight: Mac prerequisites (socket_vmnet, sudoers, tools, Docker) ----
# Idempotent + self-healing. Aborts with exact fix commands if something can't
# be auto-fixed (e.g. Docker not running), so the install never fails obscurely
# deep inside VM creation.
info "pre-flight: checking Mac prerequisites..."
"$SCRIPT_DIR/k3s-preflight.sh" || { err "pre-flight failed — fix the items above, then re-run: ./tui install"; exit 1; }

# --- 0. air-gap bundle ------------------------------------------------------
if [[ $SKIP_BUNDLE -eq 1 || -s "$AIRGAP_DIR/k3s" ]]; then
    info "[0/5] air-gap bundle: present (skipping build) — $AIRGAP_DIR"
else
    info "[0/5] building air-gap bundle (pulls images on the Mac, ~5 GB)..."
    "$SCRIPT_DIR/bundle-images.sh" --skip-artifactory || { err "bundle build failed"; exit 1; }
fi

# --- 1. cluster -------------------------------------------------------------
info "[1/6] cluster (3 VMs + k3s, offline)..."
"$SCRIPT_DIR/k3s-cluster.sh" up || { err "cluster provisioning failed"; exit 1; }

# --- 2. DNS -----------------------------------------------------------------
info "[2/6] DNS (dnsmasq + CoreDNS stub + Mac resolver → VIP)..."
"$SCRIPT_DIR/k3s-net.sh" up || { err "DNS setup failed"; exit 1; }

# --- 3. platform ------------------------------------------------------------
info "[3/6] platform (ingress-nginx)..."
"$SCRIPT_DIR/k3s-platform.sh" up || { err "platform install failed"; exit 1; }

# --- 4. charts --------------------------------------------------------------
info "[4/6] charts (oracle, mq, valkey, app)..."
"$SCRIPT_DIR/k3s-charts.sh" up || { err "chart install failed"; exit 1; }

# --- 5. LB tier -------------------------------------------------------------
# Last: the LB VM pools to the k3s ingress + Valkey, so those must exist first.
info "[5/6] LB tier (ddk3s-lb: keepalived VIP + HAProxy → k3s nodes)..."
"$SCRIPT_DIR/k3s-lb.sh" up || { err "LB tier setup failed"; exit 1; }

# --- 6. verify --------------------------------------------------------------
info "[6/6] verify VIP + DNS..."
"$SCRIPT_DIR/k3s-net.sh" verify

if [[ $SKIP_SMOKE -eq 0 ]]; then
    echo
    info "running smoke test..."
    "$SCRIPT_DIR/k3s-smoke.sh" 2>&1 | tail -8
fi

echo
info "=== done ==="
info "  App:     http://${APP_HOST}/           (Swagger: http://${APP_HOST}/swagger-ui.html)"
info "  Valkey:  ${VALKEY_HOST}:${VALKEY_CLIENT_BASE}-$((VALKEY_CLIENT_BASE + VALKEY_NODE_COUNT - 1))  (cluster-aware valkey-cli -c)"
info "  VIP:     ${K3S_VIP}   kubeconfig: ${K3S_KUBECONFIG}"
info "  Tear down: scripts/k3s-uninstall.sh"
