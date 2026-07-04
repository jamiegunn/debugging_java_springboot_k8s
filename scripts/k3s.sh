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
#     bundle        build the air-gap image bundle on the Mac (scripts/k3s/phases/bundle-images.sh)
#     install       full install: preflight → VMs → k3s → VIP/DNS → ingress → charts → LB → smoke
#     resolver      write the Mac /etc/resolver so hostnames resolve (sudo)
#
#   Check
#     doctor        one-shot health check across EVERY layer (start here if broken)
#     smoke         14-check end-to-end verification, all by hostname
#     docs-verify   assert the /docs design claims against the live cluster
#     status        VMs + VIP owner + nodes
#
#   Explore / break
#     chaos         inject failures (node-down, lb-down, valkey-freeze, ...)
#     tour          narrated API walk-through          (scripts/k3s/tours/api-tour.sh)
#     valkey        the Valkey cluster from outside     (scripts/k3s/tours/valkey-tour.sh)
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
    tui|menu|"")  exec "$D/k3s/ui/tui.sh" ;;
    preflight)  exec "$D/k3s/phases/preflight.sh" "$@" ;;   # check/fix Mac prerequisites
    bundle)     exec "$D/k3s/phases/bundle-images.sh" "$@" ;;
    install)    exec "$D/k3s/phases/install.sh" "$@" ;;
    uninstall)  exec "$D/k3s/phases/uninstall.sh" "$@" ;;
    resolver)   exec "$D/k3s/phases/net.sh" up ;;        # writes /etc/resolver (sudo)
    lb)         exec "$D/k3s/phases/lb.sh" "$@" ;;        # the LB tier: keepalived VIP + HAProxy
    doctor)     exec "$D/k3s/verify/doctor.sh" "$@" ;;
    smoke)      exec "$D/k3s/verify/smoke.sh" "$@" ;;
    docs-verify) exec "$D/k3s/verify/docs-verify.sh" "$@" ;;
    status)     exec "$D/k3s/verify/chaos.sh" status ;;
    chaos)      exec "$D/k3s/verify/chaos.sh" "$@" ;;
    tour)       exec "$D/k3s/tours/api-tour.sh" "$@" ;;
    valkey)     exec "$D/k3s/tours/valkey-tour.sh" "$@" ;;
    -h|--help)  usage ;;
    *) echo "unknown command: $cmd"; echo; usage; exit 64 ;;
esac
