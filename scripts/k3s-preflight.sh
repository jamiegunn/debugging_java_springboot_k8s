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

# 1. Homebrew — everything else is installed through it. Offer to install it
#    (the official installer; NONINTERACTIVE so --yes works), then bring it onto
#    PATH for the rest of this run.
if command -v brew >/dev/null 2>&1; then
    ok "Homebrew"
else
    try_fix "install Homebrew (needed to install everything else)" \
        'NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
    # the installer doesn't touch THIS shell's PATH — source it so brew is usable now
    for p in /opt/homebrew/bin/brew /usr/local/bin/brew; do [[ -x "$p" ]] && eval "$("$p" shellenv)" 2>/dev/null && break; done
    command -v brew >/dev/null 2>&1 || { err "Homebrew still not on PATH — install it, then re-run."; exit 1; }
fi
BREW_PREFIX="$(brew --prefix 2>/dev/null)"

# 2. CLI tools.
missing=()
for pair in limactl:lima kubectl:kubernetes-cli helm:helm curl:curl; do
    command -v "${pair%%:*}" >/dev/null 2>&1 || missing+=("${pair##*:}")
done
if [[ ${#missing[@]} -eq 0 ]]; then ok "CLI tools (limactl, kubectl, helm, curl)"
else try_fix "install CLI tools: ${missing[*]}" "brew install ${missing[*]}"; fi

# 3. sudo access — the Lima sudoers file and the Mac /etc/resolver each need it
#    once. Non-admin corporate Macs can do neither. (Soft: an already-configured
#    machine can still install; the sudoers/resolver steps below hard-fail if
#    they actually can't sudo.)
if sudo -n true 2>/dev/null || id -Gn 2>/dev/null | tr ' ' '\n' | grep -qx admin; then
    ok "sudo access (admin / passwordless — you may be prompted once)"
else
    warn "your account can't sudo (not in the 'admin' group). The Lima sudoers and Mac resolver need it — ask IT to run 'limactl sudoers | sudo tee /etc/sudoers.d/lima', or use an admin account."
fi

# 4. socket_vmnet — the backend for Lima's 'shared' network (the whole stack
#    depends on the Mac + VMs sharing one L2 segment).
SVN=""
for p in "${BREW_PREFIX:-}/opt/socket_vmnet/bin/socket_vmnet" /opt/socket_vmnet/bin/socket_vmnet; do
    [[ -x "$p" ]] && { SVN="$p"; break; }
done
[[ -z "$SVN" ]] && brew list socket_vmnet >/dev/null 2>&1 && SVN="(brew)"
if [[ -n "$SVN" ]]; then ok "socket_vmnet (shared-network backend)"
else try_fix "install socket_vmnet (the shared network needs it)" "brew install socket_vmnet"; fi

# 5. Lima sudoers — socket_vmnet must run without a password prompt per VM.
#    `sudoers --check` also validates that the 'shared' network is defined and
#    points at the socket_vmnet binary, so it doubles as the "is the shared
#    network actually usable?" check.
if limactl sudoers --check >/dev/null 2>&1; then
    ok "Lima sudoers + shared network configured (/etc/sudoers.d/lima up to date)"
else
    try_fix "configure Lima sudoers (needs sudo once; the shared network won't start without it)" \
        "limactl sudoers | sudo tee /etc/sudoers.d/lima >/dev/null"
fi

# 6. k3s + images: present offline, or reachable to build. The air-gap bundle
#    (dumps/airgap: the k3s binary, its airgap image tar, and the app/backend
#    images) IS "k3s installed" — offline, nothing to download. If it's missing
#    it must be BUILT, which needs Docker + reachable sources (GitHub for the k3s
#    release, registries for images) — where a corporate proxy/MITM bites first.
if [[ -s "$AIRGAP_DIR/k3s" ]]; then
    ok "k3s + images: air-gap bundle present — no Docker/internet needed"
else
    # Bundle must be built → ensure Docker (install if missing, launch + wait if
    # stopped), then confirm the sources are reachable.
    if docker info >/dev/null 2>&1; then
        ok "Docker running (to build the bundle)"
    else
        command -v docker >/dev/null 2>&1 || try_fix "install Docker Desktop (to build the bundle)" "brew install --cask docker"
        if [[ $CHECK_ONLY -eq 0 ]] && command -v open >/dev/null 2>&1; then
            printf '     %sstarting Docker Desktop (waiting up to 60s for the daemon)…%s\n' "$DIM" "$OFF"
            open -a Docker 2>/dev/null
            for _ in $(seq 1 30); do docker info >/dev/null 2>&1 && break; sleep 2; done
        fi
        if docker info >/dev/null 2>&1; then ok "Docker running (to build the bundle)"
        else need "Docker isn't running (needed once to build the bundle)" \
            "open -a Docker   # wait for it to finish starting, then re-run  ./tui preflight"; fi
    fi
    if curl -sfI --max-time 8 https://github.com >/dev/null 2>&1; then
        ok "k3s sources reachable (github.com — the bundle can download k3s + images)"
    else
        need "can't reach github.com — the bundle can't fetch the k3s binary/images" \
            "corporate network? use a proxy/mirror, or run 'scripts/k3s.sh bundle' on an open network and copy dumps/airgap/ across"
    fi
fi

# 7. RAM — the VMs are 3 + 7 + 7 + 1 = 18 GiB.
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
