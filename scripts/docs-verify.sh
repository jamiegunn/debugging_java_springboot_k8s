#!/usr/bin/env bash
#
# docs-verify.sh — make the /docs claims EXECUTABLE. Each check asserts something
# a doc states about the running cluster, and names the doc it validates, so the
# docs can't silently rot (this suite exists because a "Services share one MetalLB
# IP" claim was once false against the live cluster and nothing caught it).
#
# It complements — does not replace — doctor (layer health) and smoke (end-to-end
# by hostname). This one checks the SPECIFIC design assertions the docs make.
#
# Usage:
#   ./docs-verify.sh            # verify every doc claim
#   ./docs-verify.sh --quiet    # only show failures
# Exit code = number of failed claims.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/k3s-env.sh
source "$SCRIPT_DIR/lib/k3s-env.sh"
set +e +o pipefail

QUIET=0
for a in "$@"; do case "$a" in --quiet) QUIET=1;; -h|--help) sed -n '2,/^$/p' "$0"|sed 's/^# \{0,1\}//'; exit 0;; esac; done

C_OK=$'\033[32m'; C_BAD=$'\033[31m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'; C_H=$'\033[1m'
OK=0; BAD=0
doc()  { echo; printf '%s── %s%s %s(%s)%s\n' "$C_H" "$1" "$C_OFF" "$C_DIM" "$2" "$C_OFF"; }
ok()   { OK=$((OK+1)); [[ $QUIET -eq 0 ]] && printf '  %s✔%s %s\n' "$C_OK" "$C_OFF" "$1"; return 0; }
bad()  { BAD=$((BAD+1)); printf '  %s✘ %s%s\n' "$C_BAD" "$1" "$C_OFF"; [[ -n "${2:-}" ]] && printf '     %s%s%s\n' "$C_DIM" "$2" "$C_OFF"; }
note() { [[ $QUIET -eq 0 ]] && printf '  %s· %s%s\n' "$C_DIM" "$1" "$C_OFF"; }

[[ -s "$K3S_KUBECONFIG" ]] || { err "no kubeconfig at $K3S_KUBECONFIG — is the stack installed?"; exit 1; }
VK_PASS="$(kubectl -n valkey get secret valkey -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null)"

# --- architecture + L2 primer ----------------------------------------------
doc "Shared L2 + VIP" "k3s-architecture.md / networking-l2-primer.md"
if ping -c1 -t2 "$K3S_VIP" >/dev/null 2>&1; then ok "VIP $K3S_VIP is directly ARP-reachable from the Mac (shared L2)"
else bad "VIP $K3S_VIP not reachable from the Mac" "scripts/k3s-lb.sh status"; fi
if curl -fsS -m8 --resolve "${APP_HOST}:80:${K3S_VIP}" "http://${APP_HOST}/actuator/health/liveness" >/dev/null 2>&1; then
    ok "hostname $APP_HOST → VIP serves HTTP (by name, not IP)"
else bad "HTTP by hostname to $APP_HOST failed" "scripts/k3s-doctor.sh"; fi

# --- LB tier ----------------------------------------------------------------
doc "LB tier: VIP on a separate box + HAProxy" "lb-tier-keepalived-haproxy.md"
if limactl shell "$K3S_LB_VM" -- ip -4 -o addr show 2>/dev/null | grep -q "$K3S_VIP"; then ok "$K3S_LB_VM holds the VIP (keepalived), NOT a cluster node"
else bad "$K3S_LB_VM does not hold the VIP" "scripts/k3s-lb.sh up"; fi
if limactl shell "$K3S_LB_VM" -- pgrep -x haproxy >/dev/null 2>&1; then ok "HAProxy is the backend-pool on $K3S_LB_VM"
else bad "HAProxy not running on $K3S_LB_VM" "scripts/k3s-lb.sh up"; fi

# --- MetalLB (incl. the shared-IP claim the docs hinge on) ------------------
doc "MetalLB fulfills LoadBalancer; Valkey Services SHARE ONE IP" "metallb-configuration.md / valkey-tcp-ingress-routing.md"
if [[ "$(kubectl -n metallb-system get deploy controller -o jsonpath='{.status.readyReplicas}' 2>/dev/null)" -ge 1 ]] 2>/dev/null; then
    ok "MetalLB controller Ready (k3s servicelb/klipper disabled)"
else bad "MetalLB controller not Ready" "scripts/k3s-platform.sh up"; fi
VKIPS=(); while IFS= read -r _ip; do [[ -n "$_ip" ]] && VKIPS+=("$_ip"); done \
    < <(kubectl -n valkey get svc -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.status.loadBalancer.ingress[0].ip}{"\n"}{end}' 2>/dev/null | grep '\.' | sort -u)
n_svc=$(kubectl -n valkey get svc -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -c .)
if [[ ${#VKIPS[@]} -eq 1 && $n_svc -ge "$VALKEY_NODE_COUNT" ]]; then
    ok "all $n_svc Valkey Services share ONE MetalLB IP (${VKIPS[0]}) — the claim is TRUE"
elif [[ ${#VKIPS[@]} -eq 0 ]]; then
    bad "no Valkey Service has a MetalLB IP" "kubectl -n valkey get svc; kubectl -n valkey describe svc valkey-primary-0-ext | grep -A3 Events"
else
    bad "Valkey Services do NOT share one IP — ${#VKIPS[@]} distinct IPs: ${VKIPS[*]}" "the docs claim ONE shared IP. Set loadBalancer.sharedIP (VALKEY_SHARED_LB_IP) and re-apply; check the Service isn't setting both spec.loadBalancerIP and the metallb.io/loadBalancerIPs annotation"
fi
if kubectl -n metallb-system get l2advertisement -o jsonpath='{.items[0].spec.nodeSelectors}' 2>/dev/null | grep -q control-plane; then
    ok "L2Advertisement announces from agents only (excludes the tainted control-plane)"
else note "L2Advertisement has no control-plane exclusion (announcement may include the server)"; fi

# --- Valkey TCP / RESP routing ----------------------------------------------
doc "Valkey RESP over TCP by hostname; MOVED names the hostname" "valkey-tcp-ingress-routing.md"
vk() { kubectl -n valkey exec -i valkey-primary-0 -- valkey-cli -c -h "$VALKEY_HOST" -p "$VALKEY_CLIENT_BASE" -a "$VK_PASS" --no-auth-warning "$@" 2>/dev/null; }
if [[ "$(vk set docs-verify:probe ok)" == OK && "$(vk get docs-verify:probe)" == ok ]]; then
    ok "SET/GET via $VALKEY_HOST → VIP → HAProxy → shared IP:port → owning pod"
else bad "Valkey SET/GET via hostname failed" "scripts/k3s.sh doctor; scripts/valkey-tour.sh --section topology"; fi
moved=$(kubectl -n valkey exec -i valkey-primary-0 -- valkey-cli -h "$VALKEY_HOST" -p "$VALKEY_CLIENT_BASE" -a "$VK_PASS" --no-auth-warning set "{docs}:m:$RANDOM" v 2>/dev/null)
if echo "$moved" | grep -q MOVED && echo "$moved" | grep -q "$VALKEY_HOST"; then ok "MOVED redirect names the hostname, not an IP"
elif echo "$moved" | grep -q OK; then ok "MOVED not triggered (seed node owned the slot) — routing intact"
else note "could not confirm MOVED-by-hostname (got: ${moved:-nothing})"; fi

# --- stateful storage (POC-only) --------------------------------------------
doc "StatefulSet PVCs are RWO local-path (POC-only, node-local)" "stateful-storage-poc.md"
for ns in oracle mq valkey; do
    sc=$(kubectl -n "$ns" get pvc -o jsonpath='{.items[0].spec.storageClassName}' 2>/dev/null)
    mode=$(kubectl -n "$ns" get pvc -o jsonpath='{.items[0].spec.accessModes[0]}' 2>/dev/null)
    [[ "$mode" == ReadWriteOnce ]] && ok "$ns PVC is $mode / ${sc:-<default>} (node-local, not HA)" \
        || bad "$ns PVC access mode is '${mode:-none}', expected ReadWriteOnce" "kubectl -n $ns get pvc"
done
node=$(kubectl -n oracle get pod -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null)
note "Oracle+MQ are single-replica, pinned to ${K3S_STATEFUL_NODE:-<unpinned>} (Oracle currently on ${node:-?}) — killing that node takes both down"

# ---------------------------------------------------------------------------
echo
printf '%s══════════════════════════════════════════════════════════════%s\n' "$C_H" "$C_OFF"
if [[ $BAD -eq 0 ]]; then printf ' %s✔ docs match reality%s — %d claims verified.\n' "$C_OK" "$C_OFF" "$OK"
else printf ' %s✘ %d doc claim(s) FALSE%s (%d ok). The docs assert something the cluster does not do — fix one or the other.\n' "$C_BAD" "$BAD" "$C_OFF" "$OK"; fi
printf '%s══════════════════════════════════════════════════════════════%s\n' "$C_H" "$C_OFF"
exit $BAD
