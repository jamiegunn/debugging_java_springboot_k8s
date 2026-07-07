#!/usr/bin/env bash
#
# tui.sh — an interactive, dependency-free text UI over the whole k3s
# toolkit. Every action is a thin call to scripts/k3s.sh (or a focused
# scripts/k3s-*.sh); the TUI just makes them discoverable and shows you the
# exact command it runs before it runs it. Launch it with `scripts/k3s.sh` (no
# args) or `scripts/k3s.sh tui`.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_ROOT="$SCRIPT_DIR"; while [[ "$SCRIPTS_ROOT" != / && ! -f "$SCRIPTS_ROOT/lib/common.sh" ]]; do SCRIPTS_ROOT="$(dirname "$SCRIPTS_ROOT")"; done
REPO_ROOT="$(cd "$SCRIPTS_ROOT/.." && pwd)"
# shellcheck source=lib/k3s-env.sh
source "$SCRIPTS_ROOT/lib/k3s-env.sh" 2>/dev/null || true
set +e   # interactive loop — never die on a failed action

K3S="$SCRIPTS_ROOT/k3s.sh"
: "${K3S_VIP:=192.168.105.100}"
: "${APP_HOST:=debug-demo.local}"
: "${VALKEY_HOST:=valkey.debug-demo.local}"
KCFG="$REPO_ROOT/dumps/k3s.kubeconfig"
KCTX="ddk3s"   # context name when imported into ~/.kube/config (k3s ships "default", which collides)
PASS_CMD="PASS=\$(kubectl --kubeconfig $KCFG -n valkey get secret valkey -o jsonpath='{.data.password}' | base64 -d)"

# --- colors (respect NO_COLOR / non-tty) -----------------------------------
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    B=$'\033[1m'; DIM=$'\033[2m'; CY=$'\033[36m'; GN=$'\033[32m'; YL=$'\033[33m'; RD=$'\033[31m'; OFF=$'\033[0m'
else B=""; DIM=""; CY=""; GN=""; YL=""; RD=""; OFF=""; fi

hr() { printf '%s────────────────────────────────────────────────────────────────%s\n' "$DIM" "$OFF"; }
pause() { printf '\n%sPress Enter to return to the menu…%s ' "$DIM" "$OFF"; read -r _ || exit 0; }

confirm() {  # confirm "message" — returns 0 on y
    printf '%s%s%s [y/N] ' "$YL" "$1" "$OFF"; local a; read -r a || return 1
    [[ "$a" == y || "$a" == Y || "$a" == yes ]]
}

run() {  # run <cmd...> — echo it, run it, keep output on screen
    printf '\n%s$ %s%s\n\n' "$CY" "$*" "$OFF"
    "$@"
    printf '\n%s[exit %s]%s\n' "$DIM" "$?" "$OFF"
}

# fast, local-only status — ONE `limactl list` call (no per-VM shell exec, which
# would make the menu sluggish) + a single 1s ping for real VIP liveness (the
# Mac shares the VIP's L2 segment). Full VIP-owner/node state is menu option 6.
status_line() {
    local up=0 total=0 vm list kc vip
    list="$(limactl list --format '{{.Name}} {{.Status}}' 2>/dev/null)"
    for vm in "${K3S_ALL_VMS[@]:-}" "${K3S_LB_VM:-}"; do
        [[ -z "$vm" ]] && continue
        total=$((total+1))
        printf '%s\n' "$list" | awk -v n="$vm" '$1==n && $2=="Running"{f=1} END{exit !f}' && up=$((up+1))
    done
    kc="${RD}✗ no kubeconfig${OFF}"; [[ -s "$KCFG" ]] && kc="${GN}✓ kubeconfig${OFF}"
    # real check: is the VIP actually answering? (not just the configured address)
    if ping -c1 -t1 "$K3S_VIP" >/dev/null 2>&1; then vip="${GN}VIP ${K3S_VIP} up${OFF}"
    else vip="${RD}VIP ${K3S_VIP} down${OFF}"; fi
    printf '  %sVMs%s %s/%s running    %s    %s   %s(full state → 6)%s\n' \
        "$B" "$OFF" "$up" "$total" "$kc" "$vip" "$DIM" "$OFF"
}

header() {
    clear 2>/dev/null || printf '\n\n'
    printf '%s╔══════════════════════════════════════════════════════════════╗%s\n' "$B" "$OFF"
    printf '%s║  debug-demo · k3s control                                    ║%s\n' "$B" "$OFF"
    printf '%s╚══════════════════════════════════════════════════════════════╝%s\n' "$B" "$OFF"
    printf '%s  • You don'\''t need to set KUBECONFIG — the scripts auto-target%s\n' "$DIM" "$OFF"
    printf '%s    dumps/k3s.kubeconfig. For your OWN kubectl, either:%s\n' "$DIM" "$OFF"
    printf '%s        export KUBECONFIG=%s%s\n' "$CY" "$KCFG" "$OFF"
    printf '%s    or import it into ~/.kube/config as context '\''%s'\'' → menu item %si%s\n' "$DIM" "$KCTX" "$B" "$OFF"
    printf '%s  • Valkey password for your local valkey-cli / redis-cli:%s\n' "$DIM" "$OFF"
    printf '%s        %s%s\n' "$CY" "$PASS_CMD" "$OFF"
    printf '%s  • Any subcommand takes --help for the underlying script'\''s options,%s\n' "$DIM" "$OFF"
    printf '%s    e.g.  k3s.sh smoke --help   or   k3s.sh chaos --help%s\n' "$DIM" "$OFF"
    printf '%s  • When in doubt, run %sdoctor%s%s — it walks the request path top to%s\n' "$DIM" "$B" "$OFF$DIM" "" "$OFF"
    printf '%s    bottom; the first ✘ is almost always the root cause.%s\n' "$DIM" "$OFF"
    hr
    status_line
    hr
}

menu() {
    header
    cat <<EOF
  ${B}${CY}▶ d${OFF}  ${B}JVM DEBUG KIT${OFF} ${DIM}— dumps · memory · logs · snapshot (the core diagnostics workflow)${OFF}

  ${B}GET RUNNING${OFF}              ${B}CHECK / DIAGNOSE${OFF}         ${B}EXPLORE / BREAK${OFF}
   ${GN}1${OFF} preflight ${DIM}(deps)${OFF}      ${GN}5${OFF} doctor  ${DIM}(start here)${OFF}    ${GN}10${OFF} api tour
   ${GN}2${OFF} bundle                ${GN}6${OFF} status                 ${GN}11${OFF} valkey tour
   ${GN}3${OFF} install               ${GN}7${OFF} smoke   ${DIM}(15 checks)${OFF}    ${GN}12${OFF} chaos …
   ${GN}4${OFF} resolver ${DIM}(sudo)${OFF}       ${GN}8${OFF} valkey validation
                            ${GN}9${OFF} lb ${DIM}(LB tier status)${OFF}

  ${B}TEAR DOWN${OFF}                ${B}UTILITIES${OFF}
   ${GN}13${OFF} uninstall            ${GN}v${OFF} VMs ${DIM}(start/stop/restart)${OFF}  ${GN}h${OFF} --help  ${GN}k${OFF} KUBECONFIG export
                            ${GN}i${OFF} import kubeconfig  ${GN}s${OFF} shell  ${GN}q${OFF} quit
EOF
    printf '\n  %s> %s' "$B" "$OFF"
}

# --- chaos submenu ----------------------------------------------------------
chaos_menu() {
    while true; do
        header
        cat <<EOF
  ${B}CHAOS${OFF} — break one thing, leave it broken, print debug + heal cmds

   ${GN}1${OFF} node-down agent-1   ${DIM}stop a whole node → pods reschedule${OFF}
   ${GN}2${OFF} node-down agent-2
   ${GN}3${OFF} lb-down             ${DIM}stop the LB VM → VIP + access down (SPOF)${OFF}
   ${GN}4${OFF} valkey-freeze       ${DIM}freeze a primary → replica election${OFF}
   ${GN}5${OFF} oracle-down         ${GN}6${OFF} mq-down         ${GN}7${OFF} valkey-down
   ${GN}8${OFF} probe   ${DIM}observe by hostname${OFF}      ${GN}9${OFF} status
   ${GN}10${OFF} heal (all)         ${GN}11${OFF} heal <scenario>
   ${GN}b${OFF} back
EOF
        printf '\n  %s> %s' "$B" "$OFF"; local c; read -r c || return
        case "$c" in
            1) confirm "node-down stops agent-1 (its pods reschedule) — proceed?" && run "$K3S" chaos node-down agent-1 ;;
            2) confirm "node-down stops agent-2 (its pods reschedule) — proceed?" && run "$K3S" chaos node-down agent-2 ;;
            3) confirm "lb-down stops the LB VM (VIP + external access go down) — proceed?" && run "$K3S" chaos lb-down ;;
            4) confirm "valkey-freeze freezes a primary (triggers failover) — proceed?" && run "$K3S" chaos valkey-freeze ;;
            5) confirm "oracle-down scales Oracle to 0 — proceed?" && run "$K3S" chaos oracle-down ;;
            6) confirm "mq-down scales IBM MQ to 0 — proceed?" && run "$K3S" chaos mq-down ;;
            7) confirm "valkey-down scales Valkey to 0 — proceed?" && run "$K3S" chaos valkey-down ;;
            8) run "$K3S" chaos probe ;;
            9) run "$K3S" chaos status ;;
            10) run "$K3S" chaos heal ;;
            11) printf '  scenario (node-down/lb-down/valkey-freeze/oracle-down/mq-down/valkey-down): '
                local s; read -r s; [[ -n "$s" ]] && run "$K3S" chaos heal "$s" ;;
            b|B|"") return ;;
            *) continue ;;
        esac
        pause
    done
}

# --- VM lifecycle submenu ---------------------------------------------------
# Thin start/stop/restart over `limactl` for each Lima VM. Restarting an agent
# is the fix when it goes NotReady after the Mac sleeps (its shared-net DHCP
# lease lapsed → lima0 on link-local 169.254.x); after a start/restart we print
# the VM's shared-net IP so you can confirm the .x lease came back.
vm_action() {  # vm_action <start|stop|restart> <vm>
    local act="$1" vm="$2"
    case "$act" in
        start)   run limactl start "$vm" ;;
        stop)    run limactl stop  "$vm" ;;
        restart) run limactl stop  "$vm"; run limactl start "$vm" ;;
    esac
    [[ "$act" == stop ]] && return
    printf '\n  %sshared-net (%s.x) IP on %s:%s ' "$DIM" "${LIMA_SHARED_SUBNET:-192.168.105}" "$vm" "$OFF"
    limactl shell "$vm" -- ip -4 -o addr show 2>/dev/null \
        | awk -v n="${LIMA_SHARED_SUBNET:-192.168.105}" '$4 ~ ("^" n "\\."){sub("/.*","",$4); print $4; f=1} END{if(!f) print "(none yet — link-local; lease not acquired)"}'
}
vms_menu() {
    local S="${K3S_SERVER_VM:-ddk3s-server}" A1="${K3S_AGENT_VMS[0]:-ddk3s-agent-1}" A2="${K3S_AGENT_VMS[1]:-ddk3s-agent-2}" L="${K3S_LB_VM:-ddk3s-lb}"
    while true; do
        header
        cat <<EOF
  ${B}VM LIFECYCLE${OFF} — start / stop / restart the Lima VMs (limactl)
  ${DIM}Restart an agent to reacquire a lost shared-net lease (NotReady-after-sleep fix).${OFF}
  ${DIM}Bring-up order: server → agents → lb.${OFF}

               ${DIM}start   stop   restart${OFF}
   ${B}server ${OFF}       ${GN}1${OFF}      ${GN}2${OFF}      ${GN}3${OFF}
   ${B}agent-1${OFF}       ${GN}4${OFF}      ${GN}5${OFF}      ${GN}6${OFF}
   ${B}agent-2${OFF}       ${GN}7${OFF}      ${GN}8${OFF}      ${GN}9${OFF}
   ${B}lb     ${OFF}      ${GN}10${OFF}     ${GN}11${OFF}     ${GN}12${OFF}

   ${GN}f${OFF} fix-net ${DIM}(auto-detect + recover lost shared-net lease → NotReady)${OFF}
   ${GN}a${OFF} restart BOTH agents    ${GN}L${OFF} list VMs    ${GN}b${OFF} back
EOF
        printf '\n  %s> %s' "$B" "$OFF"; local c; read -r c || return
        case "$c" in
            f|F) run "$K3S" fix-net ;;
            1)  vm_action start   "$S" ;;
            2)  confirm "stop $S (control-plane) — proceed?"    && vm_action stop    "$S" ;;
            3)  confirm "restart $S (control-plane) — proceed?" && vm_action restart "$S" ;;
            4)  vm_action start   "$A1" ;;
            5)  confirm "stop $A1 (its pods reschedule) — proceed?"    && vm_action stop    "$A1" ;;
            6)  vm_action restart "$A1" ;;
            7)  vm_action start   "$A2" ;;
            8)  confirm "stop $A2 (its pods reschedule) — proceed?"    && vm_action stop    "$A2" ;;
            9)  vm_action restart "$A2" ;;
            10) vm_action start   "$L" ;;
            11) confirm "stop $L (VIP + external access go down) — proceed?"  && vm_action stop    "$L" ;;
            12) confirm "restart $L (VIP drops briefly) — proceed?"           && vm_action restart "$L" ;;
            a|A) confirm "restart BOTH agents ($A1, $A2)?" && { vm_action restart "$A1"; vm_action restart "$A2"; } ;;
            L)   run limactl list ;;
            b|B|"") return ;;
            *)   continue ;;
        esac
        pause
    done
}

# --- utilities --------------------------------------------------------------
help_for() {
    printf '  subcommand (preflight/install/bundle/resolver/lb/doctor/smoke/status/chaos/tour/valkey/uninstall, or "jdebug"): '
    local s; read -r s
    case "$s" in
        jdebug|d) run "$REPO_ROOT/jdebug" --help ;;
        "")      ;;
        *)       run "$K3S" "$s" --help ;;
    esac
}
kube_export() {
    printf '\n  Copy-paste to point your own kubectl at the cluster (this shell only):\n\n'
    printf '    %sexport KUBECONFIG=%s%s\n' "$CY" "$KCFG" "$OFF"
    printf '\n  To make it permanent across shells, import it instead → menu item %si%s\n' "$B" "$OFF"
    printf '\n  Valkey password for your local valkey-cli / redis-cli:\n\n'
    printf '    %s%s%s\n' "$CY" "$PASS_CMD" "$OFF"
}
kube_import() {  # merge dumps/k3s.kubeconfig into ~/.kube/config as context $KCTX
    [[ -s "$KCFG" ]] || { printf '  %sno kubeconfig yet — install first (option 2).%s\n' "$RD" "$OFF"; return; }
    local dest="$HOME/.kube/config" tmp merged bak
    printf '\n  Merges %s\n  into %s as context %s%s%s (k3s names everything\n' "$KCFG" "$dest" "$B" "$KCTX" "$OFF"
    printf '  "default", which would collide — the entry is renamed on the way in).\n'
    printf '  Re-running refreshes the entry; your current file is backed up first.\n\n'
    confirm "merge into $dest?" || return
    local prev=""   # keep the user's current-context — the merge takes ours otherwise
    [[ -s "$dest" ]] && prev="$(kubectl --kubeconfig "$dest" config current-context 2>/dev/null)"
    tmp="$(mktemp)"; merged="$(mktemp)"
    # rename ONLY the identifier fields — never cert/server data
    sed -E 's/(name|cluster|user|current-context): default$/\1: '"$KCTX"'/' "$KCFG" > "$tmp"
    mkdir -p "$HOME/.kube"
    if [[ -s "$dest" ]]; then
        bak="$dest.bak-$(date +%Y%m%d%H%M%S)"
        cp "$dest" "$bak" && printf '  %sbacked up: %s%s\n' "$DIM" "$bak" "$OFF"
    fi
    # our file FIRST so a re-import overrides a stale $KCTX entry in $dest
    if KUBECONFIG="$tmp:$dest" kubectl config view --flatten > "$merged" 2>/dev/null && [[ -s "$merged" ]]; then
        mv "$merged" "$dest" && chmod 600 "$dest"; rm -f "$tmp"
        [[ -n "$prev" && "$prev" != "$KCTX" ]] && kubectl --kubeconfig "$dest" config use-context "$prev" >/dev/null 2>&1
        printf '\n  %s✓ imported.%s Your current-context is unchanged (%s). Use the cluster with:\n\n' "$GN" "$OFF" "${prev:-$KCTX}"
        printf '    %skubectl config use-context %s%s          %s(sticky, every new shell)%s\n' "$CY" "$KCTX" "$OFF" "$DIM" "$OFF"
        printf '    %skubectl --context %s -n valkey get pods%s   %s(one-off)%s\n' "$CY" "$KCTX" "$OFF" "$DIM" "$OFF"
    else
        rm -f "$tmp" "$merged"
        printf '  %s✘ merge failed — %s left untouched.%s\n' "$RD" "$dest" "$OFF"
    fi
}
kube_shell() {
    [[ -s "$KCFG" ]] || { printf '  %sno kubeconfig yet — install first.%s\n' "$RD" "$OFF"; return; }
    printf '  %sOpening a subshell with KUBECONFIG set. Type `exit` to come back.%s\n' "$DIM" "$OFF"
    KUBECONFIG="$KCFG" "${SHELL:-/bin/bash}"
}

# --- main loop --------------------------------------------------------------
while true; do
    menu
    read -r choice || exit 0
    case "$choice" in
        1)  run "$K3S" preflight ;;
        2)  run "$K3S" bundle ;;
        3)  confirm "Full install (builds VMs, ~15 min the first time) — proceed?" && run "$K3S" install ;;
        4)  confirm "Write /etc/resolver/${BASE_DOMAIN:-debug-demo.local} (needs sudo) — proceed?" && run "$K3S" resolver ;;
        5)  run "$K3S" doctor ;;
        6)  run "$K3S" status ;;
        7)  run "$K3S" smoke ;;
        8)  printf '  full suite, or skip the slow failover section? [F=full / s=skip]: '
            read -r m; case "$m" in s|S) run "$SCRIPTS_ROOT/k3s/verify/valkey-cluster-tests.sh" --skip-failover ;; *) run "$SCRIPTS_ROOT/k3s/verify/valkey-cluster-tests.sh" ;; esac ;;
        9)  run "$K3S" lb status ;;
        10) run "$K3S" tour ;;
        11) run "$K3S" valkey ;;
        12) chaos_menu; continue ;;
        13) confirm "Uninstall: delete the VMs, /etc/resolver entry, and kubeconfig — proceed?" && run "$K3S" uninstall ;;
        v|V) vms_menu; continue ;;
        d|D) "$REPO_ROOT/jdebug"; continue ;;
        h|H) help_for ;;
        k|K) kube_export ;;
        i|I) kube_import ;;
        s|S) kube_shell ;;
        q|Q|"") clear 2>/dev/null; exit 0 ;;
        *) continue ;;
    esac
    pause
done
