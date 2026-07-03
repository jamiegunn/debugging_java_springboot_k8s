#!/usr/bin/env bash
#
# install-stack.sh — bootstrap the full debugging_java_springboot_k8s stack
# onto a Rancher Desktop cluster.
#
# Idempotent. Safe to re-run any time, from any state:
#   - `helm upgrade --install` reconciles each release to the desired values
#     (no-op if already matching, in-place upgrade otherwise).
#   - `kubectl apply` is a no-op when manifests are unchanged.
#   - Failed/stuck helm releases are detected and surfaced with clear
#     remediation, not silently swallowed.
#   - Wait phases short-circuit when pods are already Ready (typical second
#     run completes in ~20s).
#   - Will NOT delete PVCs, secrets, or any user-modified state. To rebuild
#     from clean state, run scripts/uninstall-stack.sh first.
#
# Phases:
#   1. Prereq check               (rdctl, kubectl, helm, docker, curl, python3, limactl)
#   2. Image preload              (scripts/preload-images.sh — pull every registry
#                                  image up-front so corporate-MITM TLS failures
#                                  surface here, not as ImagePullBackOff later)
#   3. MetalLB + nginx-ingress    (MetalLB pool 192.168.64.50-60 for Valkey;
#                                  nginx-ingress runs with hostNetwork=true bound
#                                  to the RD node's :80 — Pattern D)
#   4. HAProxy F5 stand-in        (second Lima VM with HAProxy on 192.168.105.x;
#                                  models the external F5: HTTP frontend for the
#                                  hostNetwork ingress + Valkey L4 passthrough
#                                  6379-6384/16379-16384. Provisioned before the
#                                  charts so Valkey can announce its IP.)
#   5. Integration charts         (oracle, ibm-mq, valkey, [artifactory]) in parallel
#                                  Valkey default: 6 per-pod Services SHARE one
#                                  LB IP (192.168.64.51), split by port 6379-6384,
#                                  and ANNOUNCE the HAProxy VM IP (two-layer)
#   6. App image build            (docker build into RD's moby)
#   7. App chart install          (ClusterIP Service + Ingress; no direct LB)
#   8. Post-install validation    (helm status, actuator/health, HAProxy health)
#   9. Host-side setup            (PROMPTS FOR sudo — adds static routes for the
#                                  MetalLB Valkey IPs and a /etc/hosts entry
#                                  pointing debug-demo.local at the HAProxy VM
#                                  IP; idempotent — skips work already in place)
#  10. End-to-end smoke test      (scripts/smoke-test.sh — in-cluster + external)
#
# Usage:
#   ./install-stack.sh                  # everything (default — will prompt for sudo in Phase 9)
#   ./install-stack.sh --check          # report current state, install nothing
#   ./install-stack.sh --image-manifest-only # print the image list Phase 2 would pull, then exit
#   ./install-stack.sh --skip-image-preload  # skip the up-front image pulls (clean networks)
#   ./install-stack.sh --skip-build     # reuse existing debug-demo-app:dev image
#   ./install-stack.sh --skip-artifactory   # faster cluster install (~3-5 min saved)
#   ./install-stack.sh --skip-validate  # skip the in-cluster actuator/Valkey checks
#   ./install-stack.sh --skip-haproxy-vm    # skip the F5 stand-in (HTTP via RD node IP directly)
#   ./install-stack.sh --skip-host-setup    # don't touch routes or /etc/hosts (no sudo)
#   ./install-stack.sh --skip-smoke     # don't run the final smoke-test

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

# --- args -------------------------------------------------------------------
SKIP_ARTIFACTORY=0
SKIP_BUILD=0
SKIP_VALIDATE=0
SKIP_HAPROXY_VM=0
SKIP_HOST_SETUP=0
SKIP_SMOKE=0
SKIP_IMAGE_PRELOAD=0
CHECK_ONLY=0
for a in "$@"; do
    case "$a" in
        --skip-artifactory) SKIP_ARTIFACTORY=1 ;;
        --skip-build)       SKIP_BUILD=1 ;;
        --skip-validate)    SKIP_VALIDATE=1 ;;
        --skip-haproxy-vm)  SKIP_HAPROXY_VM=1 ;;
        --skip-host-setup)  SKIP_HOST_SETUP=1 ;;
        --skip-smoke)       SKIP_SMOKE=1 ;;
        --skip-image-preload) SKIP_IMAGE_PRELOAD=1 ;;
        --image-manifest-only)
            # Print the image list Phase 2 would pull, for security review /
            # air-gap prep, and exit without touching anything.
            exec "$SCRIPT_DIR/preload-images.sh" --manifest-only
            ;;
        --check)            CHECK_ONLY=1 ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)  err "unknown arg: $a"; exit 64 ;;
    esac
done

METALLB_VERSION="v0.14.8"
METALLB_POOL_RANGE="192.168.64.50-192.168.64.60"    # Valkey default (sharedIP-perPort) uses only .51;
                                                    # legacy perPodIP mode claims .51-.56
NGINX_INGRESS_VERSION="4.11.3"          # controller v1.11.3 (now hostNetwork-mode)
APP_INGRESS_HOST="debug-demo.local"     # /etc/hosts entry → HAProxy VM IP
HAPROXY_VM_IP_FILE="$REPO_ROOT/dumps/haproxy-vm-ip"  # written by install-haproxy-vm.sh

# --- Phase 1: prereq check --------------------------------------------------
info "[1/10] checking prerequisites..."
require_cmd kubectl helm docker curl python3
if [[ $SKIP_HAPROXY_VM -eq 0 ]]; then
    require_cmd limactl
fi

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

# Detect a helm release stuck in a non-deployed state. Returns 0 if status is
# fine (deployed | not installed), 1 if stuck (failed | pending-* | uninstalling).
# Print the status and a remediation hint when stuck.
check_helm_release() {
    local rel="$1" ns="$2"
    local status
    status="$(helm -n "$ns" status "$rel" -o json 2>/dev/null | python3 -c '
import json, sys
try:
    print(json.load(sys.stdin)["info"]["status"])
except Exception:
    print("not-installed")
' 2>/dev/null)"
    case "$status" in
        deployed|not-installed) return 0 ;;
        failed|pending-install|pending-upgrade|pending-rollback|uninstalling)
            err "  release $rel ($ns) is in '${status}' state — helm upgrade will reject it"
            err "  remediation: helm -n $ns rollback $rel  OR  helm -n $ns uninstall $rel && rerun"
            return 1 ;;
        *)
            err "  release $rel ($ns) has unexpected status: $status"
            return 1 ;;
    esac
}

if [[ $CHECK_ONLY -eq 1 ]]; then
    echo
    info "=== current state ==="
    info "  MetalLB pool: $(kubectl -n metallb-system get ipaddresspool bridge-pool -o jsonpath='{.spec.addresses[0]}' 2>/dev/null || echo 'not present')"
    echo
    info "  Pods (Ready / Total):"
    for ns in metallb-system ingress-nginx oracle mq valkey artifactory debug-demo; do
        cnt=$(kubectl -n "$ns" get pods --no-headers 2>/dev/null | wc -l | tr -d ' ')
        ready=$(kubectl -n "$ns" get pods --no-headers 2>/dev/null | awk '$2~/^[0-9]+\/[0-9]+$/ {split($2,a,"/"); if(a[1]==a[2]) c++} END{print c+0}')
        info "    $(printf '%-16s' "${ns}:") ${ready}/${cnt}"
    done
    echo
    info "  Helm releases:"
    for rel_ns in "ingress-nginx:ingress-nginx" "oracle:oracle" "ibm-mq:mq" "valkey:valkey" "artifactory:artifactory" "app:debug-demo"; do
        rel="${rel_ns%%:*}"; ns="${rel_ns##*:}"
        st="$(helm -n "$ns" status "$rel" -o json 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin)["info"]["status"])' 2>/dev/null || echo 'not-installed')"
        info "    $(printf '%-16s' "${rel}:") ${st}"
    done
    echo
    info "  LoadBalancer endpoints (MetalLB — Valkey per-pod Services only in Pattern D):"
    kubectl get svc -A -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}    {.metadata.namespace}/{.metadata.name}: {.status.loadBalancer.ingress[0].ip}:{.spec.ports[0].port}{"\n"}{end}' 2>/dev/null | sort
    echo
    info "  HAProxy F5 stand-in:"
    # Capture limactl output into a variable first — piping directly into
    # `grep -q` with `set -o pipefail` causes limactl to be SIGPIPE'd
    # when grep exits early on a match, making the `if` evaluate as false.
    LIMA_LIST_JSON="$(limactl list --format=json 2>/dev/null || true)"
    if [[ "$LIMA_LIST_JSON" == *'"name":"debug-demo-haproxy"'* ]]; then
        vm_status="$(printf '%s\n' "$LIMA_LIST_JSON" | python3 -c 'import json,sys
for line in sys.stdin:
    try: v = json.loads(line.strip())
    except: continue
    if v.get("name") == "debug-demo-haproxy":
        print(v.get("status","?")); break')"
        info "    Lima VM debug-demo-haproxy: $vm_status"
        info "    Cached VM IP:               $(cat "$HAPROXY_VM_IP_FILE" 2>/dev/null || echo '(none)')"
    else
        info "    Lima VM debug-demo-haproxy: not present (run scripts/install-haproxy-vm.sh)"
    fi
    echo
    info "  Host-side state:"
    if route -n get 192.168.64.51 2>/dev/null | grep -q 'gateway: 192.168.64.2'; then
        info "    static routes:        installed ✓"
    else
        info "    static routes:        not installed (run scripts/host-routes.sh add)"
    fi
    if grep -qE "\s+debug-demo\.local(\s|$)" /etc/hosts 2>/dev/null; then
        hosts_entry="$(grep -E "\s+debug-demo\.local(\s|$)" /etc/hosts | head -1)"
        info "    /etc/hosts entry:     ${hosts_entry}"
    else
        info "    /etc/hosts entry:     missing"
    fi
    if [[ "$(sysctl -n net.inet.ip.forwarding 2>/dev/null)" == "1" ]]; then
        info "    Mac IP forwarding:    enabled ✓ (needed so HAProxy VM can reach RD node)"
    else
        info "    Mac IP forwarding:    DISABLED — run: sudo sysctl -w net.inet.ip.forwarding=1"
    fi
    exit 0
fi

info "  detecting any stuck helm releases..."
STUCK=0
for rel_ns in "ingress-nginx:ingress-nginx" "oracle:oracle" "ibm-mq:mq" "valkey:valkey" "artifactory:artifactory" "app:debug-demo"; do
    rel="${rel_ns%%:*}"; ns="${rel_ns##*:}"
    check_helm_release "$rel" "$ns" || STUCK=$((STUCK+1))
done
if [[ $STUCK -gt 0 ]]; then
    err "  $STUCK release(s) need manual remediation before this script can continue."
    exit 1
fi
info "  no stuck releases"

# --- Phase 2: image preload --------------------------------------------------
# Pull every registry image the rest of the install needs, before anything is
# applied to the cluster. On corporate networks with TLS interception this is
# where the MITM failure surfaces — as one clear docker error naming the image
# and registry, instead of a pod wedged in ImagePullBackOff mid-install.
if [[ $SKIP_IMAGE_PRELOAD -eq 1 ]]; then
    info "[2/10] --skip-image-preload: skipping up-front image pulls"
    info "       (images will be pulled lazily by kubelet/docker as each phase needs them)"
else
    info "[2/10] preloading container images (scripts/preload-images.sh)..."
    "$SCRIPT_DIR/preload-images.sh" || {
        err "  image preload failed — fix the registry access above and re-run,"
        err "  or bypass with --skip-image-preload if you accept lazy pulls."
        exit 1
    }
fi

# --- Phase 3: MetalLB -------------------------------------------------------
info "[3/10] installing MetalLB + nginx-ingress (hostNetwork mode)..."
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

info "  installing nginx-ingress controller (Pattern D: hostNetwork=true, binds RD node :80)"
if ! helm repo list 2>/dev/null | grep -q '^ingress-nginx'; then
    helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null
fi
helm repo update ingress-nginx >/dev/null 2>&1 || true
# Pattern D: controller pod runs with hostNetwork=true so it binds directly
# to the node's :80 — the external L4 LB (F5 / HAProxy VM) fronts node IPs
# on standard ports. Service stays ClusterIP for cluster-internal lookups
# but external traffic bypasses it entirely.
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
    --version "${NGINX_INGRESS_VERSION}" \
    -n ingress-nginx --create-namespace \
    --set controller.hostNetwork=true \
    --set controller.dnsPolicy=ClusterFirstWithHostNet \
    --set controller.service.type=ClusterIP \
    --set controller.replicaCount=1 \
    --set controller.ingressClassResource.default=true \
    --set controller.watchIngressWithoutClass=true >/dev/null

# --- Phase 4: HAProxy F5 stand-in (second Lima VM) --------------------------
# Provisioned BEFORE the integration charts because Valkey's two-layer
# announce shape needs the VM's IP at install time: the pods announce it
# (loadBalancer.announceIP) so MOVED redirects name the VIP, exactly like
# the production F5-without-CIS setup. The VM also carries the Valkey TCP
# passthrough listeners (client 6379-6384, bus 16379-16384) next to the
# HTTP frontend.
HAPROXY_VM_IP=""
if [[ $SKIP_HAPROXY_VM -eq 0 ]]; then
    echo
    info "[4/10] provisioning HAProxy F5 stand-in (second Lima VM)..."
    if "$SCRIPT_DIR/install-haproxy-vm.sh" 2>&1 | sed 's/^/    /'; then
        :
    else
        err "  HAProxy VM provisioning failed — re-run scripts/install-haproxy-vm.sh standalone"
        err "  (or pass --skip-haproxy-vm to install without the F5 stand-in)"
        exit 1
    fi
    if [[ -f "$HAPROXY_VM_IP_FILE" ]]; then
        HAPROXY_VM_IP="$(cat "$HAPROXY_VM_IP_FILE")"
        info "  HAProxy VM IP (F5 stand-in): $HAPROXY_VM_IP"
    else
        err "  HAProxy VM IP not cached at $HAPROXY_VM_IP_FILE"
    fi
else
    info "[4/10] --skip-haproxy-vm: not provisioning HAProxy F5 stand-in"
    info "       (HTTP via RD node IP directly; Valkey announces its MetalLB IP — one-layer)"
fi

# --- Phase 5: integration charts (in parallel) ------------------------------
info "[5/10] installing integration charts (oracle, mq, valkey$( [[ $SKIP_ARTIFACTORY -eq 0 ]] && echo ', artifactory'))..."

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
    # The Valkey chart has a `valkey-cluster-bootstrap` post-install Job that
    # runs CLUSTER MEET + CLUSTER ADDSLOTS to weld 6 standalone pods into a
    # cluster. Helm waits on this Job. Default timeout (5 min) isn't enough
    # on a cold install where images are pulling in parallel — the release
    # gets marked 'failed' even though the cluster forms fine seconds later.
    # 15 min covers realistic worst-case first-install times.
    local extra=()
    if [[ -n "$HAPROXY_VM_IP" ]]; then
        # Two-layer rehearsal (prod F5-without-CIS shape): pods announce the
        # F5 stand-in's IP so MOVED redirects name the VIP; the dev VIP shim
        # makes that VIP dialable from inside the cluster (gossip) — Apple's
        # vz NAT blocks pod→Lima-VM traffic that prod LANs allow.
        extra+=(--set "loadBalancer.announceIP=${HAPROXY_VM_IP}" --set devVipShim.enabled=true)
    fi
    # ${extra[@]+...} idiom: empty-array expansion is an unbound-variable
    # error under set -u on macOS's stock bash 3.2.
    helm upgrade --install valkey "$REPO_ROOT/charts/valkey" -n valkey --create-namespace \
        ${extra[@]+"${extra[@]}"} --timeout 15m >/dev/null
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
    local started=$(date +%s)
    local deadline=$(( started + timeout ))
    # Fast path — already Ready?
    local cur
    cur="$(kubectl -n "$ns" get pods -l "$label" -o jsonpath='{.items[*].status.containerStatuses[*].ready}' 2>/dev/null | tr ' ' '\n' | grep -cx true)"
    if [[ "$cur" -ge "$expected" ]]; then
        info "  $ns ($label): already Ready ($cur/$expected)"
        return 0
    fi
    info "  $ns ($label): waiting for $expected pod(s) (have $cur)..."
    until [[ "$(kubectl -n "$ns" get pods -l "$label" -o jsonpath='{.items[*].status.containerStatuses[*].ready}' 2>/dev/null | tr ' ' '\n' | grep -cx true)" -ge "$expected" ]]; do
        if [[ "$(date +%s)" -gt $deadline ]]; then
            err "  timed out after ${timeout}s waiting for $expected Ready pods in $ns ($label)"
            err "  diagnose: kubectl -n $ns get pods -l '$label' -o wide"
            err "            kubectl -n $ns describe pod -l '$label' | tail -30"
            return 1
        fi
        sleep 8
    done
    info "  $ns ($label): $expected pod(s) Ready (took $(( $(date +%s) - started ))s)"
}

info "  waiting for pods to come Ready..."
wait_for_label oracle        'app.kubernetes.io/name=oracle'        1 600 & W_ORA=$!
wait_for_label mq            'app.kubernetes.io/name=ibm-mq'        1 600 & W_MQ=$!
wait_for_label valkey        'app.kubernetes.io/name=valkey'        6 600 & W_VK=$!
wait_for_label ingress-nginx 'app.kubernetes.io/name=ingress-nginx' 1 300 & W_NG=$!
if [[ $SKIP_ARTIFACTORY -eq 0 ]]; then
    wait_for_label artifactory 'app.kubernetes.io/name=artifactory' 1 900 & W_AF=$!
fi
wait $W_ORA $W_MQ $W_VK $W_NG
if [[ $SKIP_ARTIFACTORY -eq 0 ]]; then wait $W_AF; fi

# --- Phase 6: build app image ----------------------------------------------
if [[ $SKIP_BUILD -eq 1 ]]; then
    info "[6/10] --skip-build set, reusing debug-demo-app:dev"
    if ! docker image inspect debug-demo-app:dev >/dev/null 2>&1; then
        err "  image debug-demo-app:dev not present; re-run without --skip-build"
        exit 1
    fi
else
    info "[6/10] building app image (debug-demo-app:dev)..."
    ( cd "$REPO_ROOT/app" && docker build -t debug-demo-app:dev . >/dev/null )
    info "  built"
fi

# --- Phase 7: install app ---------------------------------------------------
info "[7/10] installing app chart (ClusterIP + Ingress; no direct LoadBalancer)..."
helm upgrade --install app "$REPO_ROOT/charts/debug-demo-app" -n debug-demo --create-namespace \
    --set image.repository=debug-demo-app \
    --set image.tag=dev \
    --set image.pullPolicy=Never \
    --set replicaCount=1 \
    --set resources.requests.cpu=50m \
    --set resources.requests.memory=512Mi \
    --set externalService.enabled=false \
    --set ingress.enabled=true \
    --set ingress.className=nginx \
    --set "ingress.hosts[0].host=${APP_INGRESS_HOST}" \
    --set oracle.host=oracle-oracle.oracle.svc.cluster.local \
    --set oracle.service=FREEPDB1 \
    --set mq.host=ibm-mq-ibm-mq.mq.svc.cluster.local \
    --set mq.user=app --set mq.password=passw0rd >/dev/null

wait_for_label debug-demo 'app.kubernetes.io/name=debug-demo-app' 1 300

# --- Phase 8: post-install validation ---------------------------------------
if [[ $SKIP_VALIDATE -eq 0 ]]; then
    echo
    info "[8/10] post-install validation..."
    # In-cluster checks (don't depend on host routes / /etc/hosts)
    POD=$(kubectl -n debug-demo get pod -l app.kubernetes.io/name=debug-demo-app \
            -o jsonpath='{.items[?(@.status.containerStatuses[0].ready==true)].metadata.name}' 2>/dev/null | awk '{print $1}')
    if [[ -n "$POD" ]] && \
       kubectl -n debug-demo exec "$POD" -- curl -fsS -m 5 http://localhost:8080/actuator/health 2>/dev/null | grep -q UP; then
        info "  app /actuator/health (in-cluster): UP"
    else
        err "  app /actuator/health (in-cluster): FAIL — try 'kubectl -n debug-demo logs $POD --tail=50'"
    fi
    VK_PASS="$(kubectl -n valkey get secret valkey -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null)"
    if kubectl -n valkey exec valkey-primary-0 -- valkey-cli -a "$VK_PASS" cluster info 2>/dev/null | grep -q 'cluster_state:ok'; then
        info "  valkey cluster_state: ok"
    else
        err "  valkey cluster_state: not ok — try 'kubectl -n valkey logs valkey-primary-0 --tail=30'"
    fi
    # Pattern D check: ingress-nginx pod must be hostNetwork=true
    NG_POD_HOSTNET="$(kubectl -n ingress-nginx get pod -l app.kubernetes.io/name=ingress-nginx -o jsonpath='{.items[0].spec.hostNetwork}' 2>/dev/null)"
    if [[ "$NG_POD_HOSTNET" == "true" ]]; then
        info "  ingress-nginx pod hostNetwork: true ✓ (Pattern D)"
    else
        err "  ingress-nginx pod hostNetwork: '$NG_POD_HOSTNET' (expected 'true' for Pattern D)"
    fi
    # End-to-end through HAProxy VM, if it's up. Retry: HAProxy's backend
    # health check needs ~10s (inter 5s, rise 2) to mark the RD node UP after
    # the config reload, so an immediate curl right after Phase 6 will 503.
    if [[ -n "$HAPROXY_VM_IP" ]]; then
        VALIDATED=0
        for attempt in 1 2 3 4 5 6; do
            if curl -fsS -m 5 -o /dev/null -w '%{http_code}' "http://$HAPROXY_VM_IP/actuator/health" 2>/dev/null | grep -q 200; then
                info "  HAProxy VM → ingress-nginx → app: /actuator/health = 200 ✓ (attempt $attempt)"
                VALIDATED=1
                break
            fi
            sleep 3
        done
        if [[ $VALIDATED -eq 0 ]]; then
            err "  HAProxy VM → ingress-nginx → app: FAIL after 6 tries (~18s)"
            err "  Diagnose:"
            err "    sysctl net.inet.ip.forwarding   (should be 1)"
            err "    curl -sS http://${HAPROXY_VM_IP}:8404/;csv | awk -F, '/ingress_nginx,rd-node/{print \$18}'   (should be UP)"
            err "    limactl shell debug-demo-haproxy -- sh -c 'curl -sS http://192.168.64.2/'"
        fi
    fi
fi

# --- Phase 9: host-side setup (sudo) ---------------------------------------
# Idempotent: only invokes sudo when something actually needs to change.
# Now: static routes are needed for Valkey only (HAProxy VM has its own
#      shared-network IP that the Mac reaches directly via Lima). /etc/hosts
#      entry points debug-demo.local at the HAProxy VM IP, not a MetalLB IP.
host_routes_present() {
    route -n get 192.168.64.51 2>/dev/null | grep -q 'gateway: 192.168.64.2'
}
# Target IP for the /etc/hosts entry: HAProxy VM IP if we have it, else the
# RD node ExternalIP (degraded mode without the F5 stand-in).
etc_hosts_target_ip() {
    if [[ -n "$HAPROXY_VM_IP" ]]; then
        echo "$HAPROXY_VM_IP"
    else
        kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="ExternalIP")].address}' 2>/dev/null \
            || echo "192.168.64.2"
    fi
}
etc_hosts_present() {
    local target="$1"
    grep -qE "^\s*${target}\s+${APP_INGRESS_HOST}(\s|$)" /etc/hosts 2>/dev/null
}
# Mac IP forwarding is required so the HAProxy VM (on 192.168.105.x) can
# reach the RD node (on 192.168.64.2/bridge100) via the Mac as a router.
ip_forwarding_on() {
    [[ "$(sysctl -n net.inet.ip.forwarding 2>/dev/null)" == "1" ]]
}

if [[ $SKIP_HOST_SETUP -eq 0 ]]; then
    echo
    info "[9/10] host-side setup (may prompt for sudo)..."
    HOSTS_TARGET="$(etc_hosts_target_ip)"

    NEED_SUDO=0
    if ! host_routes_present;        then NEED_SUDO=1; fi
    if ! etc_hosts_present "$HOSTS_TARGET"; then NEED_SUDO=1; fi
    if [[ $SKIP_HAPROXY_VM -eq 0 ]] && ! ip_forwarding_on; then NEED_SUDO=1; fi

    if [[ $NEED_SUDO -eq 0 ]]; then
        info "  static routes:        already installed ✓"
        info "  /etc/hosts entry:     already pointing $HOSTS_TARGET → ${APP_INGRESS_HOST} ✓"
        if [[ $SKIP_HAPROXY_VM -eq 0 ]]; then
            info "  Mac IP forwarding:    enabled ✓"
        fi
    else
        info "  some host-side state is missing; will run sudo commands"
        # Warm the sudo timestamp once so we don't get multiple prompts.
        sudo -v || { err "  sudo required for Phase 9. Re-run with --skip-host-setup to defer."; exit 1; }

        if ! host_routes_present; then
            info "  adding static routes via scripts/host-routes.sh add (for Valkey LBs)"
            "$SCRIPT_DIR/host-routes.sh" add 2>&1 | sed 's/^/    /' || {
                err "  scripts/host-routes.sh add failed"; exit 1; }
        else
            info "  static routes already installed — skipping"
        fi

        if [[ $SKIP_HAPROXY_VM -eq 0 ]] && ! ip_forwarding_on; then
            info "  enabling Mac IP forwarding (sysctl net.inet.ip.forwarding=1)"
            info "  (so HAProxy VM can reach the RD node via the Mac)"
            sudo sysctl -w net.inet.ip.forwarding=1 >/dev/null
        fi

        if ! etc_hosts_present "$HOSTS_TARGET"; then
            # Escape any dots in the hostname for the regex.
            HOST_RE="${APP_INGRESS_HOST//./\\.}"
            # Match lines that (a) start with a digit (real IP mapping, not a
            # comment) and (b) contain <space><hostname><space-or-EOL>. Using
            # `sed -E` for extended regex — BSD sed on macOS doesn't support
            # `\|` alternation in BRE, so the old pattern silently matched
            # nothing (which is how the stale line survived earlier).
            STALE_RE="^[0-9].*[[:space:]]${HOST_RE}([[:space:]]|\$)"
            if grep -qE "$STALE_RE" /etc/hosts 2>/dev/null; then
                stale_lines="$(grep -nE "$STALE_RE" /etc/hosts | sed 's/^/    /')"
                info "  removing stale /etc/hosts entries for ${APP_INGRESS_HOST}:"
                echo "$stale_lines"
                sudo sed -E -i.bak "/${STALE_RE}/d" /etc/hosts
            fi
            info "  appending: ${HOSTS_TARGET} ${APP_INGRESS_HOST}"
            echo "${HOSTS_TARGET} ${APP_INGRESS_HOST}" | sudo tee -a /etc/hosts >/dev/null
            # Verify the rewrite actually took hold
            if ! etc_hosts_present "$HOSTS_TARGET"; then
                err "  /etc/hosts rewrite FAILED to take effect; check /etc/hosts by hand"
                exit 1
            fi
        else
            info "  /etc/hosts entry already present — skipping"
        fi
    fi
else
    info "[9/10] --skip-host-setup: skipping host routes + /etc/hosts edit"
fi

# --- Phase 10: end-to-end smoke test ----------------------------------------
if [[ $SKIP_SMOKE -eq 0 ]]; then
    echo
    info "[10/10] running scripts/smoke-test.sh (in-cluster + external + MOVED)..."
    SMOKE_ARGS=()
    [[ $SKIP_ARTIFACTORY -eq 1 ]] && SMOKE_ARGS+=(--skip-artifactory)
    if "$SCRIPT_DIR/smoke-test.sh" ${SMOKE_ARGS[@]+"${SMOKE_ARGS[@]}"} 2>&1 | tee /tmp/install-stack.smoke.out | tail -5; then
        :
    fi
    SMOKE_RC=$?
    if [[ $SMOKE_RC -ne 0 ]]; then
        err "  smoke-test had $SMOKE_RC failure(s) — full output: /tmp/install-stack.smoke.out"
    fi
else
    info "[10/10] --skip-smoke: not running smoke-test"
fi

echo
info "=== done ==="
info "  L7 (HTTP) entry — Pattern D (external LB → hostNetwork ingress):"
# If Phase 6 was skipped but the VM was already provisioned from an earlier
# install, pick up the cached IP so we don't mis-report the topology.
if [[ -z "$HAPROXY_VM_IP" && -f "$HAPROXY_VM_IP_FILE" ]]; then
    HAPROXY_VM_IP="$(cat "$HAPROXY_VM_IP_FILE")"
fi
if [[ -n "$HAPROXY_VM_IP" ]]; then
    info "    http://${APP_INGRESS_HOST}/  →  HAProxy VM @ ${HAPROXY_VM_IP}  →  RD node :80  →  ingress-nginx → app"
    info "    HAProxy stats UI:   http://${HAPROXY_VM_IP}:8404/"
else
    RD_NODE_IP="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="ExternalIP")].address}')"
    info "    http://${APP_INGRESS_HOST}/  →  RD node ${RD_NODE_IP}:80  →  ingress-nginx → app   (no F5 stand-in)"
fi
info ""
info "  L4 (TCP) entry — MetalLB per-pod Services (Valkey only; default = one shared IP, unique client port per node):"
kubectl get svc -n valkey -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}    {.metadata.name}: {.status.loadBalancer.ingress[0].ip}:{.spec.ports[0].port}{"\n"}{end}' \
    | sort
echo
info "  Host-side setup state:"
HOSTS_TARGET_FINAL="$(etc_hosts_target_ip)"
if host_routes_present; then
    info "    static routes:      installed ✓"
else
    info "    static routes:      MISSING — run: scripts/host-routes.sh add"
fi
if etc_hosts_present "$HOSTS_TARGET_FINAL"; then
    info "    /etc/hosts entry:   $HOSTS_TARGET_FINAL ${APP_INGRESS_HOST} ✓"
else
    info "    /etc/hosts entry:   MISSING — run: sudo sh -c \"echo '${HOSTS_TARGET_FINAL} ${APP_INGRESS_HOST}' >> /etc/hosts\""
fi
if [[ $SKIP_HAPROXY_VM -eq 0 ]]; then
    if ip_forwarding_on; then
        info "    Mac IP forwarding:  enabled ✓"
    else
        info "    Mac IP forwarding:  DISABLED — run: sudo sysctl -w net.inet.ip.forwarding=1"
    fi
fi
echo
info "  Try it:"
info "    curl http://${APP_INGRESS_HOST}/actuator/health"
