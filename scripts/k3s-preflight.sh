#!/usr/bin/env bash
#
# k3s-preflight.sh — Mac-side prerequisite check + auto-setup, run BEFORE the
# install touches any VM. Fully idempotent: run it any time; it only acts on
# what's missing. Every unmet requirement prints the EXACT command to fix it —
# and the safe ones (Homebrew installs, the Lima sudoers file) it offers to run
# for you, so `./tui install` works even if you never opened the README.
#
# Runs automatically as step 0 of `./tui install`; also standalone:
#   ./tui preflight            # check + interactively fix what's missing
#   scripts/k3s-preflight.sh --yes     # fix everything without prompting (CI)
#   scripts/k3s-preflight.sh --check   # report only, never change anything

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/k3s-env.sh
source "$SCRIPT_DIR/lib/k3s-env.sh"
set +e

AUTO=0; CHECK_ONLY=0
for a in "$@"; do case "$a" in
    --yes|-y) AUTO=1 ;;
    --check)  CHECK_ONLY=1 ;;
    -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac; done

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    B=$'\033[1m'; GN=$'\033[32m'; RD=$'\033[31m'; YL=$'\033[33m'; DIM=$'\033[2m'; OFF=$'\033[0m'
else B=""; GN=""; RD=""; YL=""; DIM=""; OFF=""; fi

PROB=0
ok()   { printf '  %s✔%s %s\n' "$GN" "$OFF" "$1"; }
warn() { printf '  %s⚠ %s%s\n' "$YL" "$1" "$OFF"; }
need() { PROB=$((PROB+1)); printf '  %s✘ %s%s\n' "$RD" "$1" "$OFF"; printf '     %sfix:%s %s\n' "$DIM" "$OFF" "$2"; }

# try_fix <label> <fix-cmd> — run a safe fix (auto with --yes; prompt otherwise;
# report-only with --check). Any leftover problem is counted so the run fails.
try_fix() {
    local label="$1" cmd="$2"
    if [[ $CHECK_ONLY -eq 1 ]]; then need "$label" "$cmd"; return 1; fi
    if [[ $AUTO -eq 0 ]]; then
        printf '  %s⚠ %s%s\n     %swould run:%s %s\n' "$YL" "$label" "$OFF" "$DIM" "$OFF" "$cmd"
        printf '     do this now? [Y/n] '; local a; read -r a
        [[ "$a" == n || "$a" == N ]] && { need "$label (you skipped it)" "$cmd"; return 1; }
    fi
    printf '     %srunning:%s %s\n' "$DIM" "$OFF" "$cmd"
    if eval "$cmd"; then ok "$label — done"; return 0
    else need "$label — the fix FAILED, run it by hand" "$cmd"; return 1; fi
}

echo
printf '%s── Pre-flight: Mac prerequisites ──────────────────────────────%s\n' "$B" "$OFF"

# 1. Homebrew — everything else is installed through it.
if command -v brew >/dev/null 2>&1; then
    ok "Homebrew"
    BREW_PREFIX="$(brew --prefix 2>/dev/null)"
else
    need "Homebrew not installed (needed to install the rest)" \
        '/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
    err "Install Homebrew first (command above), then re-run."; exit 1
fi

# 2. CLI tools.
missing=()
for pair in limactl:lima kubectl:kubernetes-cli helm:helm curl:curl; do
    command -v "${pair%%:*}" >/dev/null 2>&1 || missing+=("${pair##*:}")
done
if [[ ${#missing[@]} -eq 0 ]]; then ok "CLI tools (limactl, kubectl, helm, curl)"
else try_fix "install CLI tools: ${missing[*]}" "brew install ${missing[*]}"; fi

# 3. socket_vmnet — the backend for Lima's 'shared' network (the whole stack
#    depends on the Mac + VMs sharing one L2 segment).
if brew list socket_vmnet >/dev/null 2>&1 \
   || [[ -x "${BREW_PREFIX:-}/opt/socket_vmnet/bin/socket_vmnet" || -x /opt/socket_vmnet/bin/socket_vmnet ]]; then
    ok "socket_vmnet (shared-network backend)"
else
    try_fix "install socket_vmnet (the shared network needs it)" "brew install socket_vmnet"
fi

# 4. Lima sudoers — socket_vmnet must run without a password prompt per VM.
if limactl sudoers --check >/dev/null 2>&1; then
    ok "Lima sudoers (/etc/sudoers.d/lima up to date)"
else
    try_fix "configure Lima sudoers (needs sudo once; shared network won't start without it)" \
        "limactl sudoers | sudo tee /etc/sudoers.d/lima >/dev/null"
fi

# 5. Docker — only to BUILD the air-gap bundle. Once dumps/airgap exists it's
#    never needed again (the cluster is fully offline).
if [[ -s "$AIRGAP_DIR/k3s" ]]; then
    ok "air-gap bundle present — Docker not needed"
elif docker info >/dev/null 2>&1; then
    ok "Docker running (to build the air-gap bundle)"
elif command -v docker >/dev/null 2>&1; then
    need "Docker is installed but not running (needed once to build the bundle)" \
        "open -a Docker   # wait for it to finish starting, then re-run"
else
    need "Docker not installed (needed once to build the air-gap bundle)" \
        "brew install --cask docker   # then launch Docker Desktop"
fi

# 6. RAM — the VMs are 3 + 7 + 7 + 1 = 18 GiB.
mem=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1073741824 ))
if [[ $mem -ge 20 ]]; then ok "RAM: ${mem} GiB (VMs use ~18)"
else warn "RAM: ${mem} GiB — the VMs want ~18 GiB. Close apps, or shrink K3S_SERVER_MEM/K3S_AGENT_MEM in scripts/lib/k3s-env.sh"; fi

echo
if [[ $PROB -eq 0 ]]; then
    printf ' %s✔ Pre-flight passed%s — the Mac is ready. `./tui install` can proceed.\n' "$GN" "$OFF"
    exit 0
else
    printf ' %s✘ %d unmet requirement(s)%s. Run the fix command(s) shown above, then: %s./tui install%s\n' \
        "$RD" "$PROB" "$OFF" "$B" "$OFF"
    exit 1
fi
