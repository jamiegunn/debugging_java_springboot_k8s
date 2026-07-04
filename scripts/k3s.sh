#!/usr/bin/env bash
#
# k3s.sh — the ONE front door for the multi-node k3s stack. Everything you need,
# in the order you need it. Each command is a thin wrapper over a focused script
# (see scripts/k3s-*.sh); run `k3s.sh <cmd> --help` for that script's options.
#
# Run with NO arguments (or `tui`) for an interactive menu over everything.
#
#   Get running
#     preflight     check + auto-fix Mac prerequisites (socket_vmnet, sudoers, tools)
#     bundle        build the air-gap image bundle on the Mac (scripts/bundle-images.sh)
#     install       full install: preflight → VMs → k3s → VIP/DNS → ingress → charts → LB → smoke
#     resolver      write the Mac /etc/resolver so hostnames resolve (sudo)
#
#   Check
#     doctor        one-shot health check across EVERY layer (start here if broken)
#     smoke         14-check end-to-end verification, all by hostname
#     status        VMs + VIP owner + nodes
#
#   Explore / break
#     chaos         inject failures (node-down, lb-down, valkey-freeze, ...)
#     tour          narrated API walk-through          (scripts/api-tour.sh)
#     valkey        the Valkey cluster from outside     (scripts/valkey-tour.sh)
#
#   Tear down
#     uninstall     delete the VMs, resolver, kubeconfig
#
# Examples:
#   scripts/k3s.sh install
#   scripts/k3s.sh doctor
#   scripts/k3s.sh chaos node-down agent-1
#   scripts/k3s.sh chaos heal

set -uo pipefail
D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() { sed -n '2,/^set /p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

cmd="${1:-}"; shift 2>/dev/null || true
case "$cmd" in
    tui|menu|"")  exec "$D/k3s-tui.sh" ;;
    preflight)  exec "$D/k3s-preflight.sh" "$@" ;;   # check/fix Mac prerequisites
    bundle)     exec "$D/bundle-images.sh" "$@" ;;
    install)    exec "$D/k3s-install.sh" "$@" ;;
    uninstall)  exec "$D/k3s-uninstall.sh" "$@" ;;
    resolver)   exec "$D/k3s-net.sh" up ;;        # writes /etc/resolver (sudo)
    lb)         exec "$D/k3s-lb.sh" "$@" ;;        # the LB tier: keepalived VIP + HAProxy
    doctor)     exec "$D/k3s-doctor.sh" "$@" ;;
    smoke)      exec "$D/k3s-smoke.sh" "$@" ;;
    docs-verify) exec "$D/docs-verify.sh" "$@" ;;
    status)     exec "$D/k3s-chaos.sh" status ;;
    chaos)      exec "$D/k3s-chaos.sh" "$@" ;;
    tour)       exec "$D/api-tour.sh" "$@" ;;
    valkey)     exec "$D/valkey-tour.sh" "$@" ;;
    -h|--help)  usage ;;
    *) echo "unknown command: $cmd"; echo; usage; exit 64 ;;
esac
