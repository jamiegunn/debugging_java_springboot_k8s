#!/usr/bin/env bash
#
# k3s-tui.sh — an interactive, dependency-free text UI over the whole k3s
# toolkit. Every action is a thin call to scripts/k3s.sh (or a focused
# scripts/k3s-*.sh); the TUI just makes them discoverable and shows you the
# exact command it runs before it runs it. Launch it with `scripts/k3s.sh` (no
# args) or `scripts/k3s.sh tui`.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/k3s-env.sh
source "$SCRIPT_DIR/lib/k3s-env.sh" 2>/dev/null || true
set +e   # interactive loop — never die on a failed action

K3S="$SCRIPT_DIR/k3s.sh"
: "${K3S_VIP:=192.168.105.100}"
: "${APP_HOST:=debug-demo.local}"
: "${VALKEY_HOST:=valkey.debug-demo.local}"
KCFG="$REPO_ROOT/dumps/k3s.kubeconfig"

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
# would make the menu sluggish). Full VIP-owner/node state is menu option 6.
status_line() {
    local up=0 total=0 vm list kc
    list="$(limactl list --format '{{.Name}} {{.Status}}' 2>/dev/null)"
    for vm in "${K3S_ALL_VMS[@]:-}"; do
        [[ -z "$vm" ]] && continue
        total=$((total+1))
        printf '%s\n' "$list" | awk -v n="$vm" '$1==n && $2=="Running"{f=1} END{exit !f}' && up=$((up+1))
    done
    kc="${RD}✗ no kubeconfig${OFF}"; [[ -s "$KCFG" ]] && kc="${GN}✓ kubeconfig${OFF}"
    printf '  %sVMs%s %s/%s running    %s    %sVIP%s %s   %s(full state → 6)%s\n' \
        "$B" "$OFF" "$up" "$total" "$kc" "$B" "$OFF" "$K3S_VIP" "$DIM" "$OFF"
}

header() {
    clear 2>/dev/null || printf '\n\n'
    printf '%s╔══════════════════════════════════════════════════════════════╗%s\n' "$B" "$OFF"
    printf '%s║  debug-demo · k3s control                                    ║%s\n' "$B" "$OFF"
    printf '%s╚══════════════════════════════════════════════════════════════╝%s\n' "$B" "$OFF"
    printf '%s  • You don'\''t need to set KUBECONFIG — the scripts auto-target%s\n' "$DIM" "$OFF"
    printf '%s    dumps/k3s.kubeconfig. For your own kubectl, run:%s\n' "$DIM" "$OFF"
    printf '%s        export KUBECONFIG=$PWD/dumps/k3s.kubeconfig%s\n' "$CY" "$OFF"
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
  ${B}GET RUNNING${OFF}              ${B}CHECK${OFF}                    ${B}EXPLORE / BREAK${OFF}
   ${GN}1${OFF} install               ${GN}4${OFF} doctor  ${DIM}(start here)${OFF}     ${GN}8${OFF}  api tour
   ${GN}2${OFF} bundle                ${GN}5${OFF} smoke   ${DIM}(14 checks)${OFF}      ${GN}9${OFF}  valkey tour
   ${GN}3${OFF} resolver ${DIM}(sudo)${OFF}       ${GN}6${OFF} status                  ${GN}10${OFF} chaos …
                            ${GN}7${OFF} valkey 58-test suite

  ${B}TEAR DOWN${OFF}                ${B}UTILITIES${OFF}
   ${GN}11${OFF} uninstall            ${GN}h${OFF}  --help for a subcommand
                            ${GN}k${OFF}  print the KUBECONFIG export
                            ${GN}s${OFF}  shell with KUBECONFIG set
                            ${GN}q${OFF}  quit
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
   ${GN}3${OFF} vip-failover        ${DIM}stop the VIP holder → keepalived moves it${OFF}
   ${GN}4${OFF} valkey-freeze       ${DIM}freeze a primary → replica election${OFF}
   ${GN}5${OFF} oracle-down         ${GN}6${OFF} mq-down         ${GN}7${OFF} valkey-down
   ${GN}8${OFF} probe   ${DIM}observe by hostname${OFF}      ${GN}9${OFF} status
   ${GN}10${OFF} heal (all)         ${GN}11${OFF} heal <scenario>
   ${GN}b${OFF} back
EOF
        printf '\n  %s> %s' "$B" "$OFF"; local c; read -r c || return
        case "$c" in
            1) run "$K3S" chaos node-down agent-1 ;;
            2) run "$K3S" chaos node-down agent-2 ;;
            3) confirm "vip-failover stops the current VIP node — proceed?" && run "$K3S" chaos vip-failover ;;
            4) run "$K3S" chaos valkey-freeze ;;
            5) run "$K3S" chaos oracle-down ;;
            6) run "$K3S" chaos mq-down ;;
            7) run "$K3S" chaos valkey-down ;;
            8) run "$K3S" chaos probe ;;
            9) run "$K3S" chaos status ;;
            10) run "$K3S" chaos heal ;;
            11) printf '  scenario (node-down/vip-failover/valkey-freeze/oracle-down/mq-down/valkey-down): '
                local s; read -r s; [[ -n "$s" ]] && run "$K3S" chaos heal "$s" ;;
            b|B|"") return ;;
            *) continue ;;
        esac
        pause
    done
}

# --- utilities --------------------------------------------------------------
help_for() {
    printf '  subcommand (install/bundle/resolver/doctor/smoke/status/chaos/tour/valkey/uninstall): '
    local s; read -r s; [[ -n "$s" ]] && run "$K3S" "$s" --help
}
kube_export() {
    printf '\n  Copy-paste to point your own kubectl at the cluster:\n\n'
    printf '    %sexport KUBECONFIG=%s%s\n' "$CY" "$KCFG" "$OFF"
    printf '    %sexport KUBECONFIG=$PWD/dumps/k3s.kubeconfig%s   %s(from the repo root)%s\n' "$CY" "$OFF" "$DIM" "$OFF"
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
        1)  confirm "Full install (builds VMs, ~15 min the first time) — proceed?" && run "$K3S" install ;;
        2)  run "$K3S" bundle ;;
        3)  confirm "Write /etc/resolver/${BASE_DOMAIN:-debug-demo.local} (needs sudo) — proceed?" && run "$K3S" resolver ;;
        4)  run "$K3S" doctor ;;
        5)  run "$K3S" smoke ;;
        6)  run "$K3S" status ;;
        7)  printf '  full suite, or skip the slow failover section? [F=full / s=skip]: '
            read -r m; case "$m" in s|S) run "$SCRIPT_DIR/valkey-cluster-tests.sh" --skip-failover ;; *) run "$SCRIPT_DIR/valkey-cluster-tests.sh" ;; esac ;;
        8)  run "$K3S" tour ;;
        9)  run "$K3S" valkey ;;
        10) chaos_menu; continue ;;
        11) confirm "Uninstall: delete the VMs, /etc/resolver entry, and kubeconfig — proceed?" && run "$K3S" uninstall ;;
        h|H) help_for ;;
        k|K) kube_export ;;
        s|S) kube_shell ;;
        q|Q|"") clear 2>/dev/null; exit 0 ;;
        *) continue ;;
    esac
    pause
done
