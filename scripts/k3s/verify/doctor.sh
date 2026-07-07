#!/usr/bin/env bash
#
# doctor.sh — one command that checks EVERY layer of the k3s stack, top to
# bottom, and for anything broken tells you the exact command to fix it. Run
# this first whenever something's wrong; it walks the same path a request takes
# (Mac → VIP → HAProxy → ingress / MetalLB IP → pod → backend) so the first ✘
# is usually the root cause.
#
# Layers checked:
#   1 tooling + kubeconfig      limactl/kubectl/curl, k3s kubeconfig present
#   2 VMs                       all 4 Lima VMs Running (3 k3s + ddk3s-lb)
#   3 k3s nodes                 all 3 Ready
#   4 LB tier                   ddk3s-lb holds the VIP + HAProxy; VIP reachable
#   5 DNS                       Mac resolver + CoreDNS stub → names resolve
#   6 platform                  MetalLB IPs assigned; ingress serving; HTTP on VIP
#   7 workloads                 oracle/mq/valkey/app pods Ready; no ImagePull*
#   8 valkey cluster            state ok, 6 nodes, hostname endpoints
#   9 end to end                app UP + fan-out by hostname
#
# Usage:
#   ./k3s-doctor.sh            # full checkup
#   ./k3s-doctor.sh --quiet    # only show problems

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_ROOT="$SCRIPT_DIR"; while [[ "$SCRIPTS_ROOT" != / && ! -f "$SCRIPTS_ROOT/lib/common.sh" ]]; do SCRIPTS_ROOT="$(dirname "$SCRIPTS_ROOT")"; done
REPO_ROOT="$(cd "$SCRIPTS_ROOT/.." && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPTS_ROOT/lib/common.sh"
# shellcheck source=lib/k3s-env.sh
source "$SCRIPTS_ROOT/lib/k3s-env.sh"
set +e +o pipefail   # +o pipefail: `limactl ... | grep -q` SIGPIPEs limactl (early grep exit); pipefail would misread the guard

QUIET=0
for a in "$@"; do case "$a" in --quiet) QUIET=1;; -h|--help) sed -n '2,/^$/p' "$0"|sed 's/^# \{0,1\}//'; exit 0;; esac; done

C_OK=$'\033[32m'; C_BAD=$'\033[31m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'; C_H=$'\033[1m'
OK=0; PROB=0
sect() { echo; printf '%s── %s%s\n' "$C_H" "$1" "$C_OFF"; }
ok()   { OK=$((OK+1)); [[ $QUIET -eq 0 ]] && printf '  %s✔%s %s\n' "$C_OK" "$C_OFF" "$1"; return 0; }
bad()  { PROB=$((PROB+1)); printf '  %s✘ %s%s\n' "$C_BAD" "$1" "$C_OFF"; [[ -n "${2:-}" ]] && printf '     %sfix:%s %s\n' "$C_DIM" "$C_OFF" "$2"; }

VK_PASS="$(kubectl -n valkey get secret valkey -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null)"

# ---------------------------------------------------------------------------
sect "1. Tooling + kubeconfig"
for t in limactl kubectl curl; do command -v "$t" >/dev/null && ok "$t on PATH" || bad "$t missing" "install it (brew install $t)"; done
if [[ -s "$K3S_KUBECONFIG" ]]; then ok "kubeconfig: $K3S_KUBECONFIG"
else bad "no kubeconfig at $K3S_KUBECONFIG" "scripts/k3s/phases/cluster.sh up   (or  scripts/k3s/phases/cluster.sh kubeconfig)"; fi

sect "2. Lima VMs"
for vm in "${K3S_ALL_VMS[@]}" "$K3S_LB_VM"; do
    st="$(limactl list --format '{{.Name}} {{.Status}}' 2>/dev/null | awk -v n="$vm" '$1==n{print $2}')"
    [[ "$st" == Running ]] && ok "$vm Running" || bad "$vm: ${st:-missing}" "limactl start $vm"
done

sect "3. k3s nodes"
nready="$(kubectl get nodes --no-headers --request-timeout=10s 2>/dev/null | awk '$2=="Ready"{c++} END{print c+0}')"
[[ "$nready" == 3 ]] && ok "3 nodes Ready" || bad "$nready/3 nodes Ready" "kubectl get nodes; kubectl describe node <name>"
# A NotReady node is most often a lost shared-net DHCP lease: after the Mac
# sleeps, socket_vmnet's lease lapses, the VM's shared NIC (lima0) falls back to
# link-local 169.254.x, and flannel host-gw breaks → NotReady. Detect it and
# print the one-command fix.
if [[ "$nready" != 3 ]]; then
    for vm in "${K3S_ALL_VMS[@]}"; do
        limactl shell "$vm" -- ip -4 -o addr show 2>/dev/null | grep -q "$LIMA_SHARED_SUBNET\\." \
            || bad "$vm has no shared-net ($LIMA_SHARED_SUBNET.x) IP — lost DHCP lease (lima0 on link-local) → NotReady" "scripts/k3s.sh fix-net"
    done
fi

sect "4. LB tier — VIP $K3S_VIP + HAProxy (on $K3S_LB_VM)"
if limactl shell "$K3S_LB_VM" -- ip -4 -o addr show 2>/dev/null | grep -q "$K3S_VIP"; then ok "VIP held by $K3S_LB_VM (keepalived)"
else bad "$K3S_LB_VM does not hold the VIP" "scripts/k3s/phases/lb.sh up   (keepalived on the LB VM)"; fi
if limactl shell "$K3S_LB_VM" -- pgrep -x haproxy >/dev/null 2>&1; then ok "HAProxy running on $K3S_LB_VM"
else bad "HAProxy not running on $K3S_LB_VM" "scripts/k3s/phases/lb.sh up"; fi
if ping -c1 -t2 "$K3S_VIP" >/dev/null 2>&1; then ok "VIP pingable from the Mac"; else bad "VIP not reachable from the Mac" "scripts/k3s/phases/lb.sh status"; fi

sect "5. DNS (hostnames → VIP)"
# Mac side (curl --resolve doesn't need this, but valkey-cli from the Mac does)
if [[ -f /etc/resolver/$BASE_DOMAIN ]] || getent hosts "$APP_HOST" >/dev/null 2>&1 || dscacheutil -q host -a name "$APP_HOST" 2>/dev/null | grep -q "$K3S_VIP"; then
    ok "Mac resolves $APP_HOST (resolver or /etc/hosts)"
else bad "Mac can't resolve $APP_HOST" "scripts/k3s/phases/net.sh up   (writes /etc/resolver, needs sudo). Tests use curl --resolve so this is optional."; fi
# Pod side (required for the app → Valkey by hostname)
if kubectl -n kube-system get cm coredns-custom >/dev/null 2>&1; then
    got="$(kubectl run ddoctor-$$ --rm -i --restart=Never --image="$APP_IMAGE" --image-pull-policy=Never --timeout=45s \
           --command -- sh -c "getent hosts $VALKEY_HOST | awk '{print \$1}'" 2>/dev/null | tr -d '\r' | head -1)"
    [[ "$got" == "$K3S_VIP" ]] && ok "pods resolve $VALKEY_HOST → VIP (CoreDNS stub)" || bad "pods can't resolve $VALKEY_HOST (got '${got:-nothing}')" "scripts/k3s/phases/net.sh up   (CoreDNS stub); kubectl -n kube-system rollout restart deploy/coredns"
else bad "CoreDNS custom stub missing" "scripts/k3s/phases/net.sh up"; fi

sect "6. Platform (MetalLB + ingress-nginx)"
mc="$(kubectl -n metallb-system get deploy controller -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
[[ "${mc:-0}" -ge 1 ]] && ok "MetalLB controller Ready" || bad "MetalLB controller not Ready" "scripts/k3s/phases/platform.sh up; kubectl -n metallb-system get pods"
lbn="$(kubectl -n valkey get svc -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.status.loadBalancer.ingress[0].ip}{"\n"}{end}' 2>/dev/null | grep -c '\.')"
[[ "${lbn:-0}" -ge "$VALKEY_NODE_COUNT" ]] && ok "MetalLB assigned IPs to $lbn Valkey Services" || bad "only ${lbn:-0}/$VALKEY_NODE_COUNT Valkey Services have a MetalLB IP" "kubectl -n valkey get svc; kubectl -n metallb-system get ipaddresspool"
ir="$(kubectl -n ingress-nginx get ds ingress-nginx-controller -o jsonpath='{.status.numberReady}' 2>/dev/null)"
[[ "${ir:-0}" -ge 1 ]] && ok "ingress DaemonSet Ready (${ir} pods)" || bad "ingress not Ready" "scripts/k3s/phases/platform.sh up; kubectl -n ingress-nginx get pods"
code="$(curl -s -o /dev/null -w '%{http_code}' -m5 "http://${K3S_VIP}/healthz" 2>/dev/null)"
[[ "$code" == 200 ]] && ok "ingress answers http://VIP/healthz (200)" || bad "ingress not serving on the VIP (got ${code:-none})" "check keepalived VIP + ingress; scripts/k3s/verify/chaos.sh status"

sect "7. Workloads (air-gapped)"
for e in oracle:1 mq:1 valkey:6 debug-demo:1; do
    ns="${e%:*}"; want="${e#*:}"
    r="$(kubectl -n "$ns" get pods --no-headers 2>/dev/null | awk '{split($2,a,"/"); if(a[1]==a[2]&&a[1]>0)c++} END{print c+0}')"
    [[ "$r" -ge "$want" ]] && ok "$ns: $r Ready" || bad "$ns: $r/$want Ready" "kubectl -n $ns get pods; kubectl -n $ns describe pod <pod> | tail -20"
done
if kubectl get pods -A --no-headers 2>/dev/null | grep -qiE 'ErrImagePull|ImagePullBackOff'; then
    bad "a pod is trying to PULL an image (air-gap breach)" "scripts/k3s/phases/cluster.sh import   (re-import the bundle into containerd)"
else ok "no image pulls (air-gap intact)"; fi

sect "8. Valkey cluster"
ci="$(kubectl -n valkey exec valkey-primary-0 -- valkey-cli -a "$VK_PASS" cluster info 2>/dev/null)"
echo "$ci" | grep -q cluster_state:ok && ok "cluster_state: ok" || bad "cluster_state not ok" "kubectl -n valkey logs valkey-primary-0; helm upgrade valkey ... (re-run bootstrap)"
kn="$(echo "$ci" | grep -oE 'cluster_known_nodes:[0-9]+' | cut -d: -f2)"
[[ "$kn" == 6 ]] && ok "6 nodes known" || bad "only ${kn:-?} nodes known" "kubectl -n valkey get pods; check replica joins"
if kubectl -n valkey exec valkey-primary-0 -- valkey-cli -a "$VK_PASS" cluster shards 2>/dev/null | grep -A1 hostname | grep -q "$VALKEY_HOST"; then
    ok "CLUSTER SHARDS returns the hostname ($VALKEY_HOST)"
else bad "Valkey not announcing the hostname" "check cluster-announce-hostname in the valkey configmap"; fi

sect "9. End to end (by hostname)"
if curl -fsS -m8 --resolve "${APP_HOST}:80:${K3S_VIP}" "http://${APP_HOST}/actuator/health" 2>/dev/null | grep -q UP; then
    ok "app UP via http://${APP_HOST}/"
else bad "app health not UP via ${APP_HOST}" "kubectl -n debug-demo logs -l app.kubernetes.io/name=debug-demo-app --tail=40"; fi
ts=$(date +%s)
cid="$(curl -fsS -m8 --resolve "${APP_HOST}:80:${K3S_VIP}" -X POST "http://${APP_HOST}/api/customers" -H 'Content-Type: application/json' -d "{\"name\":\"dr-$ts\",\"email\":\"dr-$ts@e.com\"}" 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])' 2>/dev/null)"
if [[ -n "$cid" ]] && curl -fsS -m8 --resolve "${APP_HOST}:80:${K3S_VIP}" -X POST "http://${APP_HOST}/api/orders" -H 'Content-Type: application/json' -d "{\"customerId\":$cid,\"amount\":1.0}" >/dev/null 2>&1; then
    ok "full fan-out (POST /api/orders: Oracle + MQ + Valkey)"
else bad "fan-out failed" "one backend is down — see section 7/8; scripts/k3s/verify/chaos.sh probe"; fi

# ---------------------------------------------------------------------------
echo
printf '%s══════════════════════════════════════════════════════════════%s\n' "$C_H" "$C_OFF"
if [[ $PROB -eq 0 ]]; then
    printf ' %s✔ HEALTHY%s — %d checks passed. Stack is up, air-gapped, by hostname.\n' "$C_OK" "$C_OFF" "$OK"
    printf '   App: http://%s/   Valkey: %s:%d-%d\n' "$APP_HOST" "$VALKEY_HOST" "$VALKEY_CLIENT_BASE" "$((VALKEY_CLIENT_BASE+5))"
else
    printf ' %s✘ %d PROBLEM(S)%s (%d ok). Fix the FIRST ✘ above — it is usually the root cause.\n' "$C_BAD" "$PROB" "$C_OFF" "$OK"
fi
printf '%s══════════════════════════════════════════════════════════════%s\n' "$C_H" "$C_OFF"
exit $PROB
