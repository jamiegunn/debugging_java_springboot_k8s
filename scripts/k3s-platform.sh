#!/usr/bin/env bash
#
# k3s-platform.sh — P2. Install the cluster platform: ingress-nginx as a
# hostPort DaemonSet fronted by the keepalived VIP. Fully offline — the chart
# is vendored (k3s/charts/*.tgz) and its images are already imported into every
# node's containerd by k3s-cluster.sh.
#
# ingress-nginx runs as a DaemonSet with hostPort 80/443, so EVERY node answers
# HTTP on :80. keepalived floats the VIP onto one node; whichever node holds it
# is serving ingress. (Valkey's per-pod LoadBalancer Services are handled
# separately by klipper — see charts/valkey.)
#
# Usage:
#   ./k3s-platform.sh up       # install ingress-nginx + namespaces
#   ./k3s-platform.sh down     # uninstall it
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
OUR_NAMESPACES=(debug-demo oracle mq valkey artifactory)

helm_kc() { helm --kubeconfig "$K3S_KUBECONFIG" "$@"; }

cmd_up() {
    [[ -s "$INGRESS_TGZ" ]] || { err "vendored chart missing: $INGRESS_TGZ"; exit 1; }

    info "   [1/3] namespaces..."
    for ns in "${OUR_NAMESPACES[@]}"; do kc create namespace "$ns" >/dev/null 2>&1 || true; done
    kc create namespace ingress-nginx >/dev/null 2>&1 || true

    info "   [2/3] ingress-nginx (hostPort DaemonSet, offline from vendored tgz)..."
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

    info "   [3/3] waiting for the ingress DaemonSet to be Ready on all nodes..."
    kc -n ingress-nginx rollout status daemonset/ingress-nginx-controller --timeout=180s 2>/dev/null | sed 's/^/  /' \
        || err "  ingress DaemonSet not Ready — kc -n ingress-nginx get pods -o wide"

    echo
    info "platform up. ingress answers :80 on every node; keepalived VIP fronts it."
    info "next: install the backend charts (P3) + retarget keepalived at :80:"
    info "  scripts/k3s-net.sh --track ingress up"
}

cmd_down() {
    info "uninstalling ingress-nginx..."
    helm_kc -n ingress-nginx uninstall ingress-nginx >/dev/null 2>&1 || true
}

cmd_status() {
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
