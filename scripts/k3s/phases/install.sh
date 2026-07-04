#!/usr/bin/env bash
#
# k3s-install.sh — P4. The one front door for the multi-node k3s stack. Chains
# every phase, each of which is an idempotent standalone script:
#
#   1  pre-flight        scripts/k3s/phases/preflight.sh   (Mac prerequisites, auto-fix)
#   2  air-gap bundle    scripts/k3s/phases/bundle-images.sh   (skippable if already built)
#   3  cluster           scripts/k3s/phases/cluster.sh up  (3 VMs + k3s, offline)
#   4  DNS               scripts/k3s/phases/net.sh up      (dnsmasq + CoreDNS + resolver → VIP)
#   5  platform          scripts/k3s/phases/platform.sh up (ingress-nginx DaemonSet)
#   6  charts            scripts/k3s/phases/charts.sh up   (oracle, mq, valkey, app)
#   7  LB tier           scripts/k3s/phases/lb.sh up       (ddk3s-lb VM: keepalived VIP + HAProxy)
#   8  verify + smoke                               (VIP + DNS reachable by hostname)
#
# Top-level phases are [n/8]; each sub-script prints its OWN indented [n/m]
# sub-steps underneath.
#
# Everything is air-gapped and hostname-native.
#
# Usage:
#   ./k3s-install.sh                 # full install (prompts for sudo once, for the Mac resolver)
#   ./k3s-install.sh --skip-bundle   # reuse an existing dumps/airgap bundle
#   ./k3s-install.sh --skip-smoke    # don't run the final smoke test

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_ROOT="$SCRIPT_DIR"; while [[ "$SCRIPTS_ROOT" != / && ! -f "$SCRIPTS_ROOT/lib/common.sh" ]]; do SCRIPTS_ROOT="$(dirname "$SCRIPTS_ROOT")"; done
REPO_ROOT="$(cd "$SCRIPTS_ROOT/.." && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPTS_ROOT/lib/common.sh"
# shellcheck source=lib/k3s-env.sh
source "$SCRIPTS_ROOT/lib/k3s-env.sh"
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
  │  everything by hostname. 4 VMs: 1 server + 2 agents + 1 LB.   │
  └──────────────────────────────────────────────────────────────┘
EOF
}

banner

# --- pre-flight: Mac prerequisites (socket_vmnet, sudoers, tools, Docker) ----
# Idempotent + self-healing. Aborts with exact fix commands if something can't
# be auto-fixed (e.g. Docker not running), so the install never fails obscurely
# deep inside VM creation.
info "[1/8] pre-flight: checking Mac prerequisites..."
"$SCRIPTS_ROOT/k3s/phases/preflight.sh" || { err "pre-flight failed — fix the items above, then re-run: ./tui install"; exit 1; }

# --- 2. air-gap bundle ------------------------------------------------------
if [[ $SKIP_BUNDLE -eq 1 || -s "$AIRGAP_DIR/k3s" ]]; then
    info "[2/8] air-gap bundle: present (skipping build) — $AIRGAP_DIR"
else
    info "[2/8] building air-gap bundle (pulls images on the Mac, ~5 GB)..."
    "$SCRIPTS_ROOT/k3s/phases/bundle-images.sh" --skip-artifactory || { err "bundle build failed"; exit 1; }
fi

# --- 3. cluster -------------------------------------------------------------
info "[3/8] cluster (3 VMs + k3s, offline)..."
"$SCRIPTS_ROOT/k3s/phases/cluster.sh" up || { err "cluster provisioning failed"; exit 1; }

# --- 4. DNS -----------------------------------------------------------------
info "[4/8] DNS (dnsmasq + CoreDNS stub + Mac resolver → VIP)..."
"$SCRIPTS_ROOT/k3s/phases/net.sh" up || { err "DNS setup failed"; exit 1; }

# --- 5. platform ------------------------------------------------------------
info "[5/8] platform (ingress-nginx)..."
"$SCRIPTS_ROOT/k3s/phases/platform.sh" up || { err "platform install failed"; exit 1; }

# --- 6. charts --------------------------------------------------------------
info "[6/8] charts (oracle, mq, valkey, app)..."
"$SCRIPTS_ROOT/k3s/phases/charts.sh" up || { err "chart install failed"; exit 1; }

# --- 7. LB tier -------------------------------------------------------------
# Last: the LB VM pools to the k3s ingress + Valkey, so those must exist first.
info "[7/8] LB tier (ddk3s-lb: keepalived VIP + HAProxy → k3s nodes)..."
"$SCRIPTS_ROOT/k3s/phases/lb.sh" up || { err "LB tier setup failed"; exit 1; }

# --- 8. verify --------------------------------------------------------------
info "[8/8] verify VIP + DNS..."
"$SCRIPTS_ROOT/k3s/phases/net.sh" verify

if [[ $SKIP_SMOKE -eq 0 ]]; then
    echo
    info "running smoke test..."
    "$SCRIPTS_ROOT/k3s/verify/smoke.sh" 2>&1 | tail -8
fi

echo
info "=== done ==="
info "  App:     http://${APP_HOST}/           (Swagger: http://${APP_HOST}/swagger-ui.html)"
info "  Valkey:  ${VALKEY_HOST}:${VALKEY_CLIENT_BASE}-$((VALKEY_CLIENT_BASE + VALKEY_NODE_COUNT - 1))  (cluster-aware valkey-cli -c)"
info "  VIP:     ${K3S_VIP}   kubeconfig: ${K3S_KUBECONFIG}"
info "  Tear down: scripts/k3s/phases/uninstall.sh"
