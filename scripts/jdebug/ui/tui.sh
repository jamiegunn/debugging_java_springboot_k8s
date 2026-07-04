#!/usr/bin/env bash
#
# tui.sh — the jdebug interactive menu. It opens by asking WHERE the JVM is:
#   1 remote      operator machine → kubectl exec into a pod (drives scripts/jdebug/jdebug)
#   2 in-pod      a shell inside the pod, no kubectl        (drives jdebug-local on localhost)
#   3 bare metal  a JVM on this host, no Kubernetes         (drives jdebug-local on localhost)
# Set JDEBUG_MODE=1|2|3 to skip the prompt. Launch via `./jdebug` or the kit CLI.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_ROOT="$SCRIPT_DIR"; while [[ "$SCRIPTS_ROOT" != / && ! -f "$SCRIPTS_ROOT/lib/common.sh" ]]; do SCRIPTS_ROOT="$(dirname "$SCRIPTS_ROOT")"; done
# shellcheck source=lib/common.sh
source "$SCRIPTS_ROOT/lib/common.sh"
set +e   # interactive loop — never die on a failed action

DBG="$SCRIPTS_ROOT/jdebug"              # mode 1 backend (kubectl)
LOCAL="$SCRIPTS_ROOT/jdebug-local"      # mode 2/3 backend (localhost, no kubectl)
export NAMESPACE SELECTOR APP_CONTAINER # mode 1: 't' retargets; children inherit
: "${ACTUATOR_BASE:=http://localhost:8080/actuator}"; export ACTUATOR_BASE
: "${JATTACH_BIN:=/tmp/jattach}";                     export JATTACH_BIN
MODE="${JDEBUG_MODE:-}"

# --- colors (respect NO_COLOR / non-tty) -----------------------------------
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    B=$'\033[1m'; DIM=$'\033[2m'; CY=$'\033[36m'; GN=$'\033[32m'; YL=$'\033[33m'; RD=$'\033[31m'; OFF=$'\033[0m'
else B=""; DIM=""; CY=""; GN=""; YL=""; RD=""; OFF=""; fi

box() { printf '%s╔══════════════════════════════════════════════════════════════╗%s\n' "$B" "$OFF"
        printf '%s║  %-60s║%s\n' "$B" "$1" "$OFF"
        printf '%s╚══════════════════════════════════════════════════════════════╝%s\n' "$B" "$OFF"; }
hr() { printf '%s────────────────────────────────────────────────────────────────%s\n' "$DIM" "$OFF"; }
pause() { printf '\n%sPress Enter to return to the menu…%s ' "$DIM" "$OFF"; read -r _ || exit 0; }
confirm() { printf '%s%s%s [y/N] ' "$YL" "$1" "$OFF"; local a; read -r a || return 1; [[ "$a" == y || "$a" == Y || "$a" == yes ]]; }
run() { printf '\n%s$ %s%s\n\n' "$CY" "$*" "$OFF"; "$@"; printf '\n%s[exit %s]%s\n' "$DIM" "$?" "$OFF"; }

choose_mode() {
    clear 2>/dev/null || printf '\n\n'
    box "jdebug - where is the JVM you want to debug?"
    printf '\n'
    printf '   %s1%s  %sRemote%s      operator machine → %skubectl exec%s into a pod  %s(needs kubectl + a context)%s\n' "$GN" "$OFF" "$B" "$OFF" "$CY" "$OFF" "$DIM" "$OFF"
    printf '   %s2%s  %sIn-pod%s      a shell INSIDE the pod, no kubectl        %s(JRE-only image is fine)%s\n' "$GN" "$OFF" "$B" "$OFF" "$DIM" "$OFF"
    printf '   %s3%s  %sBare metal%s  a JVM on THIS host, no Kubernetes at all\n' "$GN" "$OFF" "$B" "$OFF"
    printf '\n  %sModes 2 & 3 talk to localhost actuator + a local jattach + /proc (via jdebug-local).%s\n' "$DIM" "$OFF"
    printf '\n  %s> %s' "$B" "$OFF"; local m; read -r m
    case "$m" in 1|2|3) MODE="$m" ;; q|Q) clear 2>/dev/null; exit 0 ;; *) MODE=1 ;; esac
}
mode_label() { case "$MODE" in 1) echo "remote · kubectl → pod";; 2) echo "in-pod · localhost";; 3) echo "bare metal · localhost";; esac; }

# --- headers ----------------------------------------------------------------
header_remote() {
    clear 2>/dev/null || printf '\n\n'
    box "JVM debug kit - remote (kubectl)"
    local ctx; ctx="$(kubectl config current-context 2>/dev/null)"
    printf '  %smode%s      %s  %s(m to switch)%s\n' "$B" "$OFF" "$(mode_label)" "$DIM" "$OFF"
    printf '  %scontext%s   %s%s%s\n' "$B" "$OFF" "$GN" "${ctx:-<none — is KUBECONFIG set?>}" "$OFF"
    printf '  %starget%s    namespace  %s%s%s\n' "$B" "$OFF" "$GN" "$NAMESPACE" "$OFF"
    printf '            selector   %s%s%s\n' "$GN" "$SELECTOR" "$OFF"
    printf '            container  %s%s%s\n' "$GN" "$APP_CONTAINER" "$OFF"
    printf '            %s↳ press %st%s%s to change target · %sm%s%s to switch mode%s\n' "$DIM" "$OFF$GN" "$OFF" "$DIM" "$GN" "$OFF" "$DIM" "$OFF"
    printf '  %skubeconfig%s %s\n' "$B" "$OFF" "${KUBECONFIG:-"(default context)"}"
    printf '  %sExamples:  jdebug health · jdebug -n prod -l app=web memory · jdebug jcmd "GC.heap_info"%s\n' "$DIM" "$OFF"
    hr
}
header_local() {
    clear 2>/dev/null || printf '\n\n'
    box "JVM debug kit - local (no kubectl)"
    local jat="not staged"; [[ -x "$JATTACH_BIN" ]] && jat="ok"
    printf '  %smode%s      %s  %s(m to switch)%s\n' "$B" "$OFF" "$(mode_label)" "$DIM" "$OFF"
    printf '  %sactuator%s  %s%s%s\n' "$B" "$OFF" "$GN" "$ACTUATOR_BASE" "$OFF"
    printf '  %sjattach%s   %s%s%s %s(%s)%s\n' "$B" "$OFF" "$GN" "$JATTACH_BIN" "$OFF" "$DIM" "$jat" "$OFF"
    printf '            %s↳ press %ss%s%s for settings (actuator / jattach / pid) · %sm%s%s to switch mode%s\n' "$DIM" "$OFF$GN" "$OFF" "$DIM" "$GN" "$OFF" "$DIM" "$OFF"
    printf '  %sReaches this machine'\''s JVM directly (localhost + /proc). No pod/kubectl needed.%s\n' "$DIM" "$OFF"
    hr
}

# --- utilities --------------------------------------------------------------
ask_via() { printf '  capture via [a]ctuator / [j]attach / [d] ephemeral JDK (default a): '
    local v; read -r v; case "$v" in j|J) VIA=jattach ;; d|D) VIA=jdk ;; *) VIA=actuator ;; esac; }
retarget() {
    printf '  namespace       [%s]: ' "$NAMESPACE";     local v; read -r v; [[ -n "$v" ]] && NAMESPACE="$v"
    printf '  label selector  [%s]: ' "$SELECTOR";      read -r v; [[ -n "$v" ]] && SELECTOR="$v"
    printf '  container       [%s]: ' "$APP_CONTAINER"; read -r v; [[ -n "$v" ]] && APP_CONTAINER="$v"
    export NAMESPACE SELECTOR APP_CONTAINER
}
local_settings() {
    printf '  actuator base URL [%s]: ' "$ACTUATOR_BASE"; local v; read -r v; [[ -n "$v" ]] && ACTUATOR_BASE="$v"
    printf '  jattach binary    [%s]: ' "$JATTACH_BIN";   read -r v; [[ -n "$v" ]] && JATTACH_BIN="$v"
    printf '  JVM pid           [%s]: ' "${JVM_PID:-auto}"; read -r v; [[ -n "$v" ]] && export JVM_PID="$v"
    export ACTUATOR_BASE JATTACH_BIN
}

# --- menus ------------------------------------------------------------------
menu_remote() {
    header_remote
    cat <<EOF
  ${B}TRIAGE${OFF}                      ${B}CAPTURE${OFF} ${DIM}(pick tier at prompt)${OFF}
   ${GN}1${OFF} pod status + events      ${GN}5${OFF} thread dump ${DIM}(actuator)${OFF}
   ${GN}2${OFF} actuator health          ${GN}6${OFF} heap dump ${RD}(actuator · pauses JVM)${OFF}
   ${GN}3${OFF} top pods + HPA           ${GN}7${OFF} jcmd … ${DIM}(GC.heap_info, NMT, JFR)${OFF}

  ${B}MEMORY / METRICS${OFF}            ${B}LOGS${OFF}
   ${GN}4${OFF} memory anatomy           ${GN}8${OFF} tail logs (all replicas)
     ${DIM}(RSS vs heap/nonheap)${OFF}    ${GN}9${OFF} set log level

  ${B}SNAPSHOT${OFF}                    ${B}UTILITIES${OFF}
   ${GN}10${OFF} incident snapshot        ${GN}i${OFF} stage jattach   ${GN}p${OFF} push in-pod tool
                                ${GN}t${OFF} target  ${GN}m${OFF} mode  ${GN}q${OFF} quit
EOF
    printf '\n  %s> %s' "$B" "$OFF"
}
menu_local() {
    header_local
    cat <<EOF
  ${B}TRIAGE${OFF}                      ${B}CAPTURE${OFF}
   ${GN}1${OFF} actuator health          ${GN}4${OFF} thread dump ${DIM}(→ stdout)${OFF}
   ${GN}2${OFF} metrics                  ${GN}5${OFF} heap dump ${RD}(pauses JVM)${OFF}
   ${GN}3${OFF} memory anatomy           ${GN}6${OFF} jcmd … ${DIM}(needs jattach)${OFF}

  ${B}SNAPSHOT${OFF}                    ${B}UTILITIES${OFF}
   ${GN}7${OFF} offline bundle           ${GN}s${OFF} settings   ${GN}m${OFF} mode   ${GN}q${OFF} quit
EOF
    printf '\n  %s> %s' "$B" "$OFF"
}

dispatch_remote() {
    case "$1" in
        1)  run "$DBG" status ;;
        2)  run "$DBG" health ;;
        3)  run "$DBG" top ;;
        4)  run "$DBG" memory ;;
        5)  ask_via; run "$DBG" threads --via "$VIA" ;;
        6)  ask_via; confirm "heap dump PAUSES the JVM (destructive in production) — proceed?" && run "$DBG" heap --via "$VIA" --confirm ;;
        7)  printf '  jcmd command (e.g. GC.heap_info, VM.native_memory summary): '; read -r jc; [[ -n "$jc" ]] && run "$DBG" jcmd "$jc" ;;
        8)  printf '  %sstreaming — Ctrl-C to stop%s\n' "$DIM" "$OFF"; run "$DBG" logs ;;
        9)  printf '  logger (e.g. com.example.debugdemo, ROOT): '; read -r lg
            printf '  level (TRACE|DEBUG|INFO|WARN|ERROR|OFF): '; read -r lv
            [[ -n "$lg" && -n "$lv" ]] && run "$DBG" log-level "$lg" "$lv" ;;
        10) if confirm "include a heap dump in the bundle? (PAUSES the JVM)"; then run "$DBG" snapshot --heap --confirm; else run "$DBG" snapshot; fi ;;
        i|I) run "$DBG" install-jattach ;;
        p|P) run "$DBG" push-local ;;
        t|T) retarget ;;
        m|M) choose_mode ;;
        q|Q|"") clear 2>/dev/null; exit 0 ;;
        *) return 1 ;;
    esac
}
dispatch_local() {
    case "$1" in
        1)  run sh "$LOCAL" health ;;
        2)  run sh "$LOCAL" metrics ;;
        3)  run sh "$LOCAL" memory ;;
        4)  run sh "$LOCAL" threads ;;
        5)  confirm "heap dump PAUSES the JVM (destructive in production) — proceed?" && run sh "$LOCAL" heap --confirm ;;
        6)  printf '  jcmd command (e.g. GC.heap_info, VM.native_memory summary): '; read -r jc; [[ -n "$jc" ]] && run sh "$LOCAL" jcmd "$jc" ;;
        7)  if confirm "include a heap dump in the bundle? (PAUSES the JVM)"; then run sh "$LOCAL" snapshot --heap; else run sh "$LOCAL" snapshot; fi ;;
        s|S) local_settings ;;
        m|M) choose_mode ;;
        q|Q|"") clear 2>/dev/null; exit 0 ;;
        *) return 1 ;;
    esac
}

# --- main loop --------------------------------------------------------------
[[ -n "$MODE" ]] || choose_mode
while true; do
    if [[ "$MODE" == 1 ]]; then menu_remote; read -r choice || exit 0; dispatch_remote "$choice" || continue
    else menu_local; read -r choice || exit 0; dispatch_local "$choice" || continue; fi
    [[ "$choice" =~ ^[tTmMsS]$ ]] || pause
done
