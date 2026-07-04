#!/usr/bin/env bash
#
# k3s-platform.sh — P2. Install the cluster platform: MetalLB (the in-cluster
# LoadBalancer fulfiller) + ingress-nginx. Fully offline — MetalLB is a vendored
# manifest (k3s/manifests/), ingress a vendored chart (k3s/charts/*.tgz), and all
# images are pre-imported into every node's containerd by k3s-cluster.sh.
#
# - MetalLB (L2 mode) fulfills the Valkey type:LoadBalancer Services — k3s
#   servicelb/klipper is disabled at install. It hands each shard a real IP from
#   METALLB_POOL, announced by ARP from the AGENTS only (an L2Advertisement
#   nodeSelector keeps announcement off the tainted control-plane). The ddk3s-lb
#   keepalived VIP + HAProxy front those IPs (see k3s-lb.sh).
# - ingress-nginx runs as a DaemonSet with hostPort 80/443, so EVERY node answers
#   HTTP on :80; the VIP's HAProxy pools to it. (Ingress is NOT a LoadBalancer
#   Service, so MetalLB doesn't touch it.)
#
# Usage:
#   ./k3s-platform.sh up       # install MetalLB + ingress-nginx + namespaces
#   ./k3s-platform.sh down     # uninstall them
#   ./k3s-platform.sh status

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/k3s-env.sh
source "$SCRIPT_DIR/lib/k3s-env.sh"
set +e   # common.sh enables set -e; these scripts do their own error handling

require_cmd kubectl helm
[[ -s "$K3S_KUBECONFIG" ]] || { err "no kubeconfig — run scripts/k3s-cluster.sh up first"; exit 1; }

INGRESS_TGZ="$REPO_ROOT/k3s/charts/ingress-nginx-${NGINX_INGRESS_VERSION}.tgz"
METALLB_MANIFEST="$REPO_ROOT/k3s/manifests/metallb-native-${METALLB_VERSION}.yaml"
OUR_NAMESPACES=(debug-demo oracle mq valkey artifactory)

helm_kc() { helm --kubeconfig "$K3S_KUBECONFIG" "$@"; }

# MetalLB: apply the vendored native manifest (creates metallb-system, CRDs,
# controller, speaker DaemonSet, validating webhook), wait for it, then apply the
# IP pool + an agents-only L2Advertisement. The pool CRs are retried because the
# validating webhook (served by the controller) needs a moment after rollout.
install_metallb() {
    [[ -s "$METALLB_MANIFEST" ]] || { err "vendored MetalLB manifest missing: $METALLB_MANIFEST"; return 1; }
    kc apply -f "$METALLB_MANIFEST" >/dev/null 2>&1 || { err "  metallb manifest apply failed"; return 1; }
    kc -n metallb-system rollout status deploy/controller --timeout=120s >/dev/null 2>&1 \
        || { err "  metallb controller not Ready — kc -n metallb-system get pods"; return 1; }
    kc -n metallb-system rollout status ds/speaker --timeout=120s >/dev/null 2>&1 || true
    local i
    for i in $(seq 1 12); do
        cat <<EOF | kc apply -f - >/dev/null 2>&1 && { info "      pool $METALLB_POOL (announced from agents only)"; return 0; }
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: valkey-pool
  namespace: metallb-system
spec:
  addresses: ["$METALLB_POOL"]
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: agents-only
  namespace: metallb-system
spec:
  ipAddressPools: [valkey-pool]
  nodeSelectors:
    - matchExpressions:
        - {key: node-role.kubernetes.io/control-plane, operator: DoesNotExist}
EOF
        sleep 5
    done
    err "  metallb pool/L2Advertisement did not apply (webhook not ready?) — kc -n metallb-system get pods"
    return 1
}

cmd_up() {
    [[ -s "$INGRESS_TGZ" ]] || { err "vendored chart missing: $INGRESS_TGZ"; exit 1; }

    info "   [1/4] namespaces..."
    for ns in "${OUR_NAMESPACES[@]}"; do kc create namespace "$ns" >/dev/null 2>&1 || true; done
    kc create namespace ingress-nginx >/dev/null 2>&1 || true

    info "   [2/4] MetalLB (L2 LoadBalancer fulfiller, offline manifest)..."
    install_metallb || return 1

    info "   [3/4] ingress-nginx (hostPort DaemonSet, offline from vendored tgz)..."
    # --kind DaemonSet + hostPort 80/443 → every node answers on :80, so the VIP
    # always lands on a serving node. ClusterIP service (no external LB needed;
    # hostPort + keepalived VIP is the entry). Images are pre-imported, so
    # IfNotPresent never reaches out.
    helm_kc upgrade --install ingress-nginx "$INGRESS_TGZ" \
        -n ingress-nginx \
        --set controller.kind=DaemonSet \
        --set controller.hostPort.enabled=true \
        --set controller.service.type=ClusterIP \
        --set controller.image.pullPolicy=IfNotPresent \
        --set controller.admissionWebhooks.patch.image.pullPolicy=IfNotPresent \
        --set controller.ingressClassResource.default=true \
        --set controller.watchIngressWithoutClass=true \
        --set controller.publishService.enabled=false \
        --wait --timeout 5m >/dev/null 2>&1 || {
            err "  ingress-nginx install failed — kc -n ingress-nginx get pods"; return 1; }

    info "   [4/4] waiting for the ingress DaemonSet to be Ready on all nodes..."
    kc -n ingress-nginx rollout status daemonset/ingress-nginx-controller --timeout=180s 2>/dev/null | sed 's/^/  /' \
        || err "  ingress DaemonSet not Ready — kc -n ingress-nginx get pods -o wide"

    echo
    info "platform up. MetalLB fulfills LoadBalancer Services from $METALLB_POOL;"
    info "ingress answers :80 on every node. Next: charts (Valkey Services get pool"
    info "IPs), then the LB tier (ddk3s-lb HAProxy pools the VIP to those IPs)."
}

cmd_down() {
    info "uninstalling ingress-nginx..."
    helm_kc -n ingress-nginx uninstall ingress-nginx >/dev/null 2>&1 || true
    info "removing MetalLB..."
    kc delete -f "$METALLB_MANIFEST" >/dev/null 2>&1 || true
}

cmd_status() {
    info "MetalLB:"
    kc -n metallb-system get pods -o wide 2>/dev/null | sed 's/^/  /' || info "  not installed"
    kc get ipaddresspool,l2advertisement -n metallb-system 2>/dev/null | sed 's/^/  /'
    echo
    info "ingress-nginx:"
    kc -n ingress-nginx get ds,pods -o wide 2>/dev/null | sed 's/^/  /' || info "  not installed"
    echo
    info "ingressclasses:"
    kc get ingressclass 2>/dev/null | sed 's/^/  /'
}

case "${1:-}" in
    up)     cmd_up ;;
    down)   cmd_down ;;
    status) cmd_status ;;
    -h|--help|"") sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//' ;;
    *) err "unknown command: $1"; exit 64 ;;
esac
