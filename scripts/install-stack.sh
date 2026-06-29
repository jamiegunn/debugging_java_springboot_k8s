#!/usr/bin/env bash
#
# install-stack.sh — bootstrap the full debugging_java_springboot_k8s stack
# onto a Rancher Desktop cluster. Idempotent: safe to re-run after partial
# failures (Helm upgrades replace, kubectl apply is a no-op when unchanged).
#
# Phases:
#   1. Prereq check               (rdctl, kubectl, helm, docker, curl, python3)
#   2. MetalLB                    (upstream manifest + bridge-pool 192.168.64.50-60)
#   3. Integration charts         (oracle, ibm-mq, valkey, [artifactory]) in parallel
#   4. App image build            (docker build into RD's moby)
#   5. App chart install          (per-pod LB + ClusterIP, valkey/oracle/mq wired)
#
# Usage:
#   ./install-stack.sh                  # everything (default)
#   ./install-stack.sh --skip-artifactory   # faster (skips ~3-5 min)
#   ./install-stack.sh --check          # report current state, install nothing
#   ./install-stack.sh --skip-build     # reuse existing debug-demo-app:dev image
#
# After this completes:
#   scripts/host-routes.sh add          # one-time sudo, makes the LB IPs reachable
#   scripts/smoke-test.sh               # verify everything end-to-end

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

# --- args -------------------------------------------------------------------
SKIP_ARTIFACTORY=0
SKIP_BUILD=0
CHECK_ONLY=0
for a in "$@"; do
    case "$a" in
        --skip-artifactory) SKIP_ARTIFACTORY=1 ;;
        --skip-build)       SKIP_BUILD=1 ;;
        --check)            CHECK_ONLY=1 ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)  err "unknown arg: $a"; exit 64 ;;
    esac
done

METALLB_VERSION="v0.14.8"
METALLB_POOL_RANGE="192.168.64.50-192.168.64.60"

# --- Phase 1: prereq check --------------------------------------------------
info "[1/5] checking prerequisites..."
require_cmd kubectl helm docker curl python3

if ! command -v rdctl >/dev/null 2>&1; then
    err "rdctl not on PATH — install Rancher Desktop and add ~/.rd/bin to PATH"
    exit 1
fi

if ! rdctl info >/dev/null 2>&1; then
    err "Rancher Desktop VM is not running. Start it with 'rdctl start' or open the app."
    exit 1
fi

CPU_COUNT="$(rdctl list-settings 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["virtualMachine"]["numberCPUs"])' 2>/dev/null || echo 0)"
MEM_GB="$(rdctl list-settings 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["virtualMachine"]["memoryInGB"])' 2>/dev/null || echo 0)"
info "  RD VM: ${CPU_COUNT} CPU, ${MEM_GB} GB"
if [[ "$MEM_GB" -lt 10 ]] || [[ "$CPU_COUNT" -lt 4 ]]; then
    err "  RD VM is too small for the full stack (need >= 4 CPU / 10 GB; 8 CPU / 16 GB recommended)."
    err "  Bump with: rdctl set --virtual-machine.memory-in-gb=16 --virtual-machine.number-cpus=8"
    err "  Then re-run this script."
    exit 1
fi

if ! kubectl get nodes >/dev/null 2>&1; then
    err "kubectl can't reach the cluster. Confirm 'kubectl config current-context' is rancher-desktop."
    exit 1
fi

info "  cluster: $(kubectl config current-context)"
info "  prereqs OK"

if [[ $CHECK_ONLY -eq 1 ]]; then
    echo
    info "=== current state ==="
    info "  MetalLB:     $(kubectl -n metallb-system get pods --no-headers 2>/dev/null | wc -l | tr -d ' ') pod(s)"
    info "  Pool:        $(kubectl -n metallb-system get ipaddresspool bridge-pool -o jsonpath='{.spec.addresses[0]}' 2>/dev/null || echo 'not present')"
    for ns in oracle mq valkey artifactory debug-demo; do
        cnt=$(kubectl -n "$ns" get pods --no-headers 2>/dev/null | wc -l | tr -d ' ')
        ready=$(kubectl -n "$ns" get pods --no-headers 2>/dev/null | awk '$2~/^[0-9]+\/[0-9]+$/ {split($2,a,"/"); if(a[1]==a[2]) c++} END{print c+0}')
        info "  $(printf '%-12s' "${ns}:") ${ready}/${cnt} Ready"
    done
    exit 0
fi

# --- Phase 2: MetalLB -------------------------------------------------------
info "[2/5] installing MetalLB..."
if kubectl -n metallb-system get deployment controller >/dev/null 2>&1; then
    info "  MetalLB controller already present, skipping manifest apply"
else
    kubectl apply -f "https://raw.githubusercontent.com/metallb/metallb/${METALLB_VERSION}/config/manifests/metallb-native.yaml" >/dev/null
    info "  waiting for MetalLB controller + speaker..."
    kubectl -n metallb-system wait --for=condition=Available deploy/controller --timeout=180s >/dev/null
    until kubectl -n metallb-system get pods -l app=metallb -o jsonpath='{.items[*].status.containerStatuses[*].ready}' 2>/dev/null | tr ' ' '\n' | grep -qx true; do
        sleep 3
    done
fi

info "  applying bridge-pool ${METALLB_POOL_RANGE}"
kubectl apply -f - <<EOF >/dev/null
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata: {name: bridge-pool, namespace: metallb-system}
spec: {addresses: ["${METALLB_POOL_RANGE}"]}
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata: {name: bridge-l2, namespace: metallb-system}
spec: {ipAddressPools: [bridge-pool]}
EOF

# --- Phase 3: integration charts (in parallel) ------------------------------
info "[3/5] installing integration charts (oracle, mq, valkey$( [[ $SKIP_ARTIFACTORY -eq 0 ]] && echo ', artifactory'))..."

install_oracle() {
    helm upgrade --install oracle "$REPO_ROOT/charts/oracle" -n oracle --create-namespace \
        --set image.repository=gvenzl/oracle-free \
        --set image.tag=23-slim-faststart >/dev/null
}
install_mq() {
    helm upgrade --install ibm-mq "$REPO_ROOT/charts/ibm-mq" -n mq --create-namespace \
        --set image.tag=9.4.5.1-r1-amd64 >/dev/null
}
install_valkey() {
    helm upgrade --install valkey "$REPO_ROOT/charts/valkey" -n valkey --create-namespace >/dev/null
}
install_artifactory() {
    helm upgrade --install artifactory "$REPO_ROOT/charts/artifactory" -n artifactory --create-namespace --no-hooks >/dev/null
}

install_oracle &       PID_ORA=$!
install_mq &           PID_MQ=$!
install_valkey &       PID_VK=$!
if [[ $SKIP_ARTIFACTORY -eq 0 ]]; then install_artifactory & PID_AF=$!; fi

wait $PID_ORA && info "  oracle install command done"      || { err "oracle install failed";       exit 1; }
wait $PID_MQ  && info "  mq install command done"          || { err "mq install failed";           exit 1; }
wait $PID_VK  && info "  valkey install command done"      || { err "valkey install failed";       exit 1; }
if [[ $SKIP_ARTIFACTORY -eq 0 ]]; then
    wait $PID_AF && info "  artifactory install command done" || { err "artifactory install failed"; exit 1; }
fi

wait_for_label() {
    local ns="$1" label="$2" expected="$3" timeout="${4:-600}"
    local deadline=$(( $(date +%s) + timeout ))
    until [[ "$(kubectl -n "$ns" get pods -l "$label" -o jsonpath='{.items[*].status.containerStatuses[*].ready}' 2>/dev/null | tr ' ' '\n' | grep -cx true)" -ge "$expected" ]]; do
        if [[ "$(date +%s)" -gt $deadline ]]; then
            err "  timed out waiting for $expected Ready pods in $ns ($label)"
            return 1
        fi
        sleep 8
    done
    info "  $ns ($label): $expected pod(s) Ready"
}

info "  waiting for pods to come Ready..."
wait_for_label oracle 'app.kubernetes.io/name=oracle' 1 600 &              W_ORA=$!
wait_for_label mq     'app.kubernetes.io/name=ibm-mq' 1 600 &              W_MQ=$!
wait_for_label valkey 'app.kubernetes.io/name=valkey' 6 600 &              W_VK=$!
if [[ $SKIP_ARTIFACTORY -eq 0 ]]; then
    wait_for_label artifactory 'app.kubernetes.io/name=artifactory' 1 900 & W_AF=$!
fi
wait $W_ORA $W_MQ $W_VK
if [[ $SKIP_ARTIFACTORY -eq 0 ]]; then wait $W_AF; fi

# --- Phase 4: build app image ----------------------------------------------
if [[ $SKIP_BUILD -eq 1 ]]; then
    info "[4/5] --skip-build set, reusing debug-demo-app:dev"
    if ! docker image inspect debug-demo-app:dev >/dev/null 2>&1; then
        err "  image debug-demo-app:dev not present; re-run without --skip-build"
        exit 1
    fi
else
    info "[4/5] building app image (debug-demo-app:dev)..."
    ( cd "$REPO_ROOT/app" && docker build -t debug-demo-app:dev . >/dev/null )
    info "  built"
fi

# --- Phase 5: install app ---------------------------------------------------
info "[5/5] installing app chart..."
helm upgrade --install app "$REPO_ROOT/charts/debug-demo-app" -n debug-demo --create-namespace \
    --set image.repository=debug-demo-app \
    --set image.tag=dev \
    --set image.pullPolicy=Never \
    --set replicaCount=1 \
    --set resources.requests.cpu=50m \
    --set resources.requests.memory=512Mi \
    --set oracle.host=oracle-oracle.oracle.svc.cluster.local \
    --set oracle.service=FREEPDB1 \
    --set mq.host=ibm-mq-ibm-mq.mq.svc.cluster.local \
    --set mq.user=app --set mq.password=passw0rd >/dev/null

wait_for_label debug-demo 'app.kubernetes.io/name=debug-demo-app' 1 300

echo
info "=== done ==="
info "  external IPs allocated by MetalLB:"
kubectl get svc -A -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace}/{.metadata.name}: {.status.loadBalancer.ingress[0].ip}{"\n"}{end}' \
    | sort | sed 's/^/    /'
echo
info "  next steps:"
info "    scripts/host-routes.sh add        # one-time sudo; makes the LB IPs reachable from this Mac"
info "    scripts/smoke-test.sh             # end-to-end verification"
