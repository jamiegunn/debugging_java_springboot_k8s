#!/usr/bin/env bash
# Keep the Mac awake while the ddk3s Lima cluster VMs are running.
#
# Why: on Apple Silicon the Lima/QEMU guests use the arch_sys_counter
# clocksource, which FREEZES when the host sleeps/suspends. On resume the
# guest clock jumps backward, and Oracle aborts its instance on backward
# time movement (alert log: "Time stall, backward drift ...") -> Oracle
# pod CrashLoopBackOff. Holding a caffeinate assertion while the cluster is
# up prevents the host-sleep clock jump.
#
# Auto-exits (releasing the assertion) once the cluster VMs are gone, so it
# doesn't keep the Mac awake after `scripts/k3s.sh uninstall`.
#
# Usage:
#   scripts/caffeinate-guard.sh            # run in foreground
#   nohup scripts/caffeinate-guard.sh >/tmp/ddk3s-caffeinate.log 2>&1 &   # detached
set -euo pipefail

VMS='ddk3s-server|ddk3s-agent-1|ddk3s-agent-2|ddk3s-lb'

running() { pgrep -f "limactl hostagent.*(${VMS})" >/dev/null 2>&1; }

if ! running; then
  echo "No ddk3s cluster VMs running; nothing to guard. Exiting."
  exit 0
fi

# -i prevent idle sleep, -s prevent system sleep (on AC), -m prevent disk
# idle. Display sleep is left ALLOWED (the screen turning off is harmless).
# Caveat: caffeinate cannot prevent clamshell (lid-close) sleep on battery.
caffeinate -ims &
CAF=$!
trap 'kill "$CAF" 2>/dev/null || true' EXIT INT TERM

echo "$(date '+%Y-%m-%dT%H:%M:%S') caffeinate guard active (pid $CAF) — cluster VMs up."
while running; do sleep 30; done
echo "$(date '+%Y-%m-%dT%H:%M:%S') ddk3s cluster VMs gone — releasing caffeinate."
