#!/usr/bin/env bash
#
# k3s-install.sh — P4. The one front door for the multi-node k3s stack. Chains
# every phase, each of which is an idempotent standalone script:
#
#   0  air-gap bundle    scripts/bundle-images.sh   (skippable if already built)
#   1  cluster           scripts/k3s-cluster.sh up  (3 VMs + k3s, offline)
#   2  VIP + DNS         scripts/k3s-net.sh up      (keepalived + dnsmasq + resolvers)
#   3  platform          scripts/k3s-platform.sh up (ingress-nginx DaemonSet)
#   4  charts            scripts/k3s-charts.sh up   (oracle, mq, valkey, app)
#   5  keepalived retrack + smoke                    (VIP tracks ingress :80; verify)
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

# --- 0. air-gap bundle ------------------------------------------------------
if [[ $SKIP_BUNDLE -eq 1 || -s "$AIRGAP_DIR/k3s" ]]; then
    info "[0/5] air-gap bundle: present (skipping build) — $AIRGAP_DIR"
else
    info "[0/5] building air-gap bundle (pulls images on the Mac, ~5 GB)..."
    "$SCRIPT_DIR/bundle-images.sh" --skip-artifactory || { err "bundle build failed"; exit 1; }
fi

# --- 1. cluster -------------------------------------------------------------
info "[1/5] cluster (3 VMs + k3s, offline)..."
"$SCRIPT_DIR/k3s-cluster.sh" up || { err "cluster provisioning failed"; exit 1; }

# --- 2. VIP + DNS -----------------------------------------------------------
info "[2/5] VIP + DNS (keepalived + dnsmasq + resolvers)..."
"$SCRIPT_DIR/k3s-net.sh" up || { err "VIP/DNS setup failed"; exit 1; }

# --- 3. platform ------------------------------------------------------------
info "[3/5] platform (ingress-nginx)..."
"$SCRIPT_DIR/k3s-platform.sh" up || { err "platform install failed"; exit 1; }

# --- 4. charts --------------------------------------------------------------
info "[4/5] charts (oracle, mq, valkey, app)..."
"$SCRIPT_DIR/k3s-charts.sh" up || { err "chart install failed"; exit 1; }

# --- 5. retrack + smoke -----------------------------------------------------
info "[5/5] retarget keepalived at ingress :80, then verify..."
"$SCRIPT_DIR/k3s-net.sh" --track ingress up >/dev/null 2>&1
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
