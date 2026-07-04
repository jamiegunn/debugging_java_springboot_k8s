#!/usr/bin/env bash
#
# debug-tui.sh — interactive menu over the JVM debug kit (scripts/jdebug.sh).
# Cluster-agnostic: it drives whatever KUBECONFIG points at, defaulting to
# this repo's k3s stack. Grouped by the troubleshooting runbook:
# triage → capture → memory → logs → snapshot. Launch via `./jdebug` or
# `scripts/jdebug.sh` (no args).

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_ROOT="$SCRIPT_DIR"; while [[ "$SCRIPTS_ROOT" != / && ! -f "$SCRIPTS_ROOT/lib/common.sh" ]]; do SCRIPTS_ROOT="$(dirname "$SCRIPTS_ROOT")"; done
# shellcheck source=lib/common.sh
source "$SCRIPTS_ROOT/lib/common.sh"
set +e   # interactive loop — never die on a failed action

DBG="$SCRIPTS_ROOT/jdebug.sh"
export NAMESPACE SELECTOR APP_CONTAINER   # 't' retargets; children inherit

# --- colors (respect NO_COLOR / non-tty) -----------------------------------
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    B=$'\033[1m'; DIM=$'\033[2m'; CY=$'\033[36m'; GN=$'\033[32m'; YL=$'\033[33m'; RD=$'\033[31m'; OFF=$'\033[0m'
else B=""; DIM=""; CY=""; GN=""; YL=""; RD=""; OFF=""; fi

hr() { printf '%s────────────────────────────────────────────────────────────────%s\n' "$DIM" "$OFF"; }
pause() { printf '\n%sPress Enter to return to the menu…%s ' "$DIM" "$OFF"; read -r _ || exit 0; }

confirm() {
    printf '%s%s%s [y/N] ' "$YL" "$1" "$OFF"; local a; read -r a || return 1
    [[ "$a" == y || "$a" == Y || "$a" == yes ]]
}

run() {  # run <cmd...> — echo it, run it, keep output on screen
    printf '\n%s$ %s%s\n\n' "$CY" "$*" "$OFF"
    "$@"
    printf '\n%s[exit %s]%s\n' "$DIM" "$?" "$OFF"
}

header() {
    clear 2>/dev/null || printf '\n\n'
    printf '%s╔══════════════════════════════════════════════════════════════╗%s\n' "$B" "$OFF"
    printf '%s║  JVM debug kit · works on any Spring Boot pod                ║%s\n' "$B" "$OFF"
    printf '%s╚══════════════════════════════════════════════════════════════╝%s\n' "$B" "$OFF"
    # stable rows (long selector/kubeconfig values don't shove other fields off-screen)
    printf '  %starget%s   namespace  %s%s%s\n' "$B" "$OFF" "$GN" "$NAMESPACE" "$OFF"
    printf '           selector   %s%s%s\n' "$GN" "$SELECTOR" "$OFF"
    printf '           container  %s%s%s\n' "$GN" "$APP_CONTAINER" "$OFF"
    printf '  %skubeconfig%s %s\n' "$B" "$OFF" "${KUBECONFIG:-"(default context)"}"
    printf '  %sCapture tiers: 1 actuator (default) → 2 jattach → 3 ephemeral JDK.%s\n' "$DIM" "$OFF"
    hr
}

ask_via() {  # sets VIA
    printf '  capture via [a]ctuator / [j]attach / [d] ephemeral JDK (default a): '
    local v; read -r v
    case "$v" in j|J) VIA=jattach ;; d|D) VIA=jdk ;; *) VIA=actuator ;; esac
}

retarget() {
    printf '  namespace       [%s]: ' "$NAMESPACE";     local v; read -r v; [[ -n "$v" ]] && NAMESPACE="$v"
    printf '  label selector  [%s]: ' "$SELECTOR";      read -r v; [[ -n "$v" ]] && SELECTOR="$v"
    printf '  container       [%s]: ' "$APP_CONTAINER"; read -r v; [[ -n "$v" ]] && APP_CONTAINER="$v"
    export NAMESPACE SELECTOR APP_CONTAINER
}

menu() {
    header
    cat <<EOF
  ${B}TRIAGE${OFF}                      ${B}CAPTURE${OFF} ${DIM}(pick tier at prompt)${OFF}
   ${GN}1${OFF} pod status + events      ${GN}5${OFF} thread dump ${DIM}(actuator)${OFF}
   ${GN}2${OFF} actuator health          ${GN}6${OFF} heap dump ${RD}(actuator · pauses JVM)${OFF}
   ${GN}3${OFF} top pods + HPA           ${GN}7${OFF} jcmd … ${DIM}(GC.heap_info, NMT, JFR)${OFF}

  ${B}MEMORY / METRICS${OFF}            ${B}LOGS${OFF}
   ${GN}4${OFF} memory anatomy           ${GN}8${OFF} tail logs (all replicas)
     ${DIM}(RSS vs heap/nonheap)${OFF}    ${GN}9${OFF} set log level

  ${B}SNAPSHOT${OFF}                    ${B}UTILITIES${OFF}
   ${GN}10${OFF} incident snapshot        ${GN}i${OFF}  pre-stage jattach in pod
      ${DIM}(offline bundle)${OFF}          ${GN}t${OFF}  change target (ns/selector)
                                ${GN}q${OFF}  quit
EOF
    printf '\n  %s> %s' "$B" "$OFF"
}

while true; do
    menu
    read -r choice || exit 0
    case "$choice" in
        1)  run "$DBG" status ;;
        2)  run "$DBG" health ;;
        3)  run "$DBG" top ;;
        4)  run "$DBG" memory ;;
        5)  ask_via; run "$DBG" threads --via "$VIA" ;;
        6)  ask_via
            confirm "heap dump PAUSES the JVM (destructive in production) — proceed?" \
                && run "$DBG" heap --via "$VIA" --confirm ;;
        7)  printf '  jcmd command (e.g. GC.heap_info, VM.flags, VM.native_memory summary): '
            read -r jc; [[ -n "$jc" ]] && run "$DBG" jcmd "$jc" ;;
        8)  printf '  %sstreaming — Ctrl-C to stop%s\n' "$DIM" "$OFF"; run "$DBG" logs ;;
        9)  printf '  logger (e.g. com.example.debugdemo, org.hibernate.SQL, ROOT): '
            read -r lg
            printf '  level (TRACE|DEBUG|INFO|WARN|ERROR|OFF): '
            read -r lv
            [[ -n "$lg" && -n "$lv" ]] && run "$DBG" log-level "$lg" "$lv" ;;
        10) if confirm "include a heap dump in the bundle? (PAUSES the JVM)"; then
                run "$DBG" snapshot --heap --confirm
            else
                run "$DBG" snapshot
            fi ;;
        i|I) run "$DBG" install-jattach ;;
        t|T) retarget; continue ;;
        q|Q|"") clear 2>/dev/null; exit 0 ;;
        *) continue ;;
    esac
    pause
done
