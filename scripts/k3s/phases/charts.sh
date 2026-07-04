#!/usr/bin/env bash
#
# k3s-charts.sh — P3. Install the application charts on the k3s cluster, fully
# offline (every image is pre-imported into containerd; IfNotPresent/Never
# never reach out). Backends first (Oracle, IBM MQ, Valkey), then the app wired
# to them + an Ingress on debug-demo.local (→ VIP → ingress-nginx → app).
#
# Usage:
#   ./k3s-charts.sh up               # install everything
#   ./k3s-charts.sh up --skip-artifactory   # (default: artifactory is skipped anyway)
#   ./k3s-charts.sh down             # uninstall the app + backend releases
#   ./k3s-charts.sh status

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_ROOT="$SCRIPT_DIR"; while [[ "$SCRIPTS_ROOT" != / && ! -f "$SCRIPTS_ROOT/lib/common.sh" ]]; do SCRIPTS_ROOT="$(dirname "$SCRIPTS_ROOT")"; done
REPO_ROOT="$(cd "$SCRIPTS_ROOT/.." && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPTS_ROOT/lib/common.sh"
# shellcheck source=lib/k3s-env.sh
source "$SCRIPTS_ROOT/lib/k3s-env.sh"
set +e   # our own error handling

require_cmd kubectl helm
[[ -s "$K3S_KUBECONFIG" ]] || { err "no kubeconfig — run scripts/k3s/phases/cluster.sh up first"; exit 1; }

helm_kc() { helm --kubeconfig "$K3S_KUBECONFIG" "$@"; }

install_oracle() {
    info "  oracle (gvenzl/oracle-free, pre-imported)${K3S_STATEFUL_NODE:+ → pinned to $K3S_STATEFUL_NODE}..."
    helm_kc upgrade --install oracle "$REPO_ROOT/charts/oracle" -n oracle --create-namespace \
        --set image.repository=gvenzl/oracle-free \
        --set image.tag=23-slim-faststart \
        ${K3S_STATEFUL_NODE:+--set pinToNode=$K3S_STATEFUL_NODE} \
        --set image.pullPolicy=IfNotPresent >/dev/null 2>&1
}
install_mq() {
    info "  ibm-mq (amd64 via rosetta, pre-imported)${K3S_STATEFUL_NODE:+ → pinned to $K3S_STATEFUL_NODE}..."
    helm_kc upgrade --install ibm-mq "$REPO_ROOT/charts/ibm-mq" -n mq --create-namespace \
        --set image.tag=9.4.5.1-r1-amd64 \
        ${K3S_STATEFUL_NODE:+--set pinToNode=$K3S_STATEFUL_NODE} \
        --set image.pullPolicy=IfNotPresent >/dev/null 2>&1
}
install_valkey() {
    info "  valkey (6-node cluster, hostname announce → $VALKEY_HOST, shared LB IP ${VALKEY_SHARED_LB_IP:-auto})..."
    # The chart already defaults loadBalancer.announceHostname to valkey.debug-demo.local.
    # Bootstrap Job welds the cluster; give it headroom on a cold cluster.
    helm_kc upgrade --install valkey "$REPO_ROOT/charts/valkey" -n valkey --create-namespace \
        --set image.pullPolicy=IfNotPresent \
        --set loadBalancer.announceHostname="$VALKEY_HOST" \
        ${VALKEY_SHARED_LB_IP:+--set loadBalancer.sharedIP=$VALKEY_SHARED_LB_IP} \
        --timeout 15m >/dev/null 2>&1
}

install_app() {
    info "  app (debug-demo-app:dev, Ingress host=$APP_HOST)..."
    helm_kc upgrade --install app "$REPO_ROOT/charts/debug-demo-app" -n debug-demo --create-namespace \
        --set image.repository=debug-demo-app \
        --set image.tag=dev \
        --set image.pullPolicy=Never \
        --set replicaCount=1 \
        --set resources.requests.cpu=50m \
        --set resources.requests.memory=512Mi \
        --set autoscaling.maxReplicas=4 \
        --set ingress.enabled=true \
        --set ingress.className=nginx \
        --set "ingress.hosts[0].host=${APP_HOST}" \
        --set "ingress.hosts[0].paths[0].path=/" \
        --set "ingress.hosts[0].paths[0].pathType=Prefix" \
        --set oracle.host=oracle-oracle.oracle.svc.cluster.local \
        --set oracle.service=FREEPDB1 \
        --set mq.host=ibm-mq-ibm-mq.mq.svc.cluster.local \
        --set mq.user=app --set mq.password=passw0rd \
        --set "hostAliases[0].ip=${K3S_VIP}" \
        --set "hostAliases[0].hostnames[0]=${VALKEY_HOST}" \
        --set "hostAliases[0].hostnames[1]=${APP_HOST}" >/dev/null 2>&1
}

wait_ready() {
    local ns="$1" label="$2" want="$3" timeout="${4:-600}" i
    for ((i=0; i<timeout; i+=8)); do
        local r; r="$(kc -n "$ns" get pods -l "$label" -o jsonpath='{.items[*].status.containerStatuses[*].ready}' 2>/dev/null | tr ' ' '\n' | grep -cx true)"
        [[ "$r" -ge "$want" ]] && { info "    $ns ($label): $r/$want Ready"; return 0; }
        sleep 8
    done
    err "    $ns ($label): timed out (<$want Ready) — kc -n $ns get pods"
    return 1
}

cmd_up() {
    info "   [1/3] backends (oracle, mq, valkey) in parallel..."
    install_oracle & install_mq & install_valkey & wait

    info "   [2/3] waiting for backends Ready..."
    wait_ready oracle 'app.kubernetes.io/name=oracle' 1 600 &
    wait_ready mq     'app.kubernetes.io/name=ibm-mq' 1 600 &
    wait_ready valkey 'app.kubernetes.io/name=valkey' 6 600 &
    wait

    info "   [3/3] app..."
    install_app
    wait_ready debug-demo 'app.kubernetes.io/name=debug-demo-app' 1 300

    echo
    info "charts installed. Validate: scripts/k3s/phases/charts.sh status  then  scripts/k3s/verify/smoke.sh"
}

cmd_down() {
    for rel_ns in "app:debug-demo" "valkey:valkey" "ibm-mq:mq" "oracle:oracle"; do
        helm_kc -n "${rel_ns##*:}" uninstall "${rel_ns%%:*}" >/dev/null 2>&1 && info "  uninstalled ${rel_ns%%:*}"
    done
}

cmd_status() {
    for ns in oracle mq valkey debug-demo; do
        printf '  %-12s ' "$ns:"
        kc -n "$ns" get pods --no-headers 2>/dev/null | awk '{split($2,a,"/"); if(a[1]==a[2]&&a[1]>0)r++} END{print (r+0)" Ready / "NR" pods"}'
    done
    echo
    info "Valkey cluster:"
    local pass; pass="$(kc -n valkey get secret valkey -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null)"
    kc -n valkey exec valkey-primary-0 -- valkey-cli -a "$pass" cluster info 2>/dev/null | grep -E 'cluster_state|cluster_known_nodes' | sed 's/^/  /'
}

case "${1:-up}" in
    up)     shift 2>/dev/null; cmd_up ;;
    down)   cmd_down ;;
    status) cmd_status ;;
    -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//' ;;
    *) err "unknown command: $1"; exit 64 ;;
esac
