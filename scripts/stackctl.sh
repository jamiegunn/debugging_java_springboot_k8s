#!/usr/bin/env bash
#
# stackctl.sh — the front door to the debug-demo stack. One place to install,
# verify, explore, break, and tear down, with enough narration that you never
# need to remember which script does what.
#
#   scripts/stackctl.sh              interactive menu (start here)
#   scripts/stackctl.sh install      guided install (wraps install-stack.sh)
#   scripts/stackctl.sh status       what's running right now
#   scripts/stackctl.sh smoke        44-check verification (--commands to show CLI)
#   scripts/stackctl.sh unit-tests   JVM unit tests (mvn test, JDK 21 auto-pinned)
#   scripts/stackctl.sh tour         narrated API walk-through
#   scripts/stackctl.sh cluster-tests   MOVED / ASK / failover (--commands to show CLI)
#   scripts/stackctl.sh chaos        break things on purpose
#   scripts/stackctl.sh uninstall    guided teardown
#
# Everything here delegates to the focused scripts in scripts/ — this is a
# map, not a re-implementation.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
dim()  { printf '\033[2m%s\033[0m\n' "$*"; }
hr()   { printf '\033[2m%s\033[0m\n' "──────────────────────────────────────────────────────────────"; }

banner() {
    cat <<'EOF'

  ┌─────────────────────────────────────────────────────────────┐
  │  debug-demo  —  a JVM patient on k8s, wired for diagnosis    │
  │  Spring Boot · Oracle · IBM MQ · Valkey cluster · Pattern D  │
  └─────────────────────────────────────────────────────────────┘
EOF
}

do_install() {
    banner
    bold "Guided install"
    hr
    cat <<'EOF'
  What's about to happen (10 phases, ~10 min warm / ~25 min cold):

    1  prereq check          rdctl/kubectl/helm/docker/limactl, VM sizing
    2  image preload         every registry image pulled up-front — corporate
                             MITM failures surface HERE, not mid-install
    3  MetalLB + ingress     LB controller + hostNetwork nginx (Pattern D)
    4  HAProxy F5 stand-in   second Lima VM: HTTP :80 + Valkey :6379-6384
    5  integration charts    Oracle, IBM MQ, Valkey (announces the VM's IP),
                             Artifactory — in parallel
    6  app image             docker build into Rancher Desktop's moby
    7  app chart             ClusterIP + Ingress
    8  validation            health, cluster state, end-to-end reachability
    9  host setup            static route, /etc/hosts, IP forwarding  ← sudo
   10  smoke test            44 checks, in-cluster + external + MOVED

  Flags you might want (pass them after 'install'):
    --skip-artifactory       ~3-5 min faster; local CI registry off
    --skip-image-preload     on clean networks
    --check                  report state, change nothing
EOF
    hr
    printf '  Proceed with install%s? [Y/n] ' "${*:+ (extra flags: $*)}"
    read -r ans
    [[ "$ans" == "n" || "$ans" == "N" ]] && return 0
    "$SCRIPT_DIR/install-stack.sh" "$@"
    echo
    bold "Installed. Where to go next:"
    echo "  scripts/stackctl.sh tour     ← see the API do its thing"
    echo "  open http://debug-demo.local/swagger-ui.html"
}

do_uninstall() {
    banner
    bold "Guided teardown"
    hr
    cat <<'EOF'
  uninstall-stack.sh reverses everything install did:
    - deletes the app + backend namespaces (cascades releases, PVCs, LBs)
    - removes the MetalLB pool (+ controller with --full)
    - deletes the HAProxy Lima VM
    - removes the static route and /etc/hosts entry (sudo)

  Data note: PVCs die with the namespaces. --keep-pvcs preserves Oracle
  data / Valkey state for a faster re-install.
EOF
    hr
    printf '  Continue to uninstall-stack.sh (it has its own confirm)? [Y/n] '
    read -r ans
    [[ "$ans" == "n" || "$ans" == "N" ]] && return 0
    "$SCRIPT_DIR/uninstall-stack.sh" "$@"
}

do_status() {
    "$SCRIPT_DIR/install-stack.sh" --check
}

menu() {
    banner
    while true; do
        echo
        bold "What do you want to do?"
        cat <<'EOF'

  Get running
    1) install         guided install (explains each phase first)
    2) status          what's installed / running / reachable right now

  Verify
    3) smoke           44-check verification: in-cluster + external + MOVED
    4) cluster-tests   Valkey semantics: MOVED, ASK (live slot migration),
                       replica reads, failover + failback (58 checks)
    5) unit-tests      JVM unit tests (mvn test, JDK 21 auto-pinned)
       (3/4 accept --commands to print the CLI command behind each check)

  Explore
    6) tour            narrated API walk-through (prints every command)
    7) valkey-tour     the Valkey cluster from outside: topology, ops, latency
    8) swagger         where the interactive API explorer lives

  Break
    9) chaos           inject failures, watch what survives

  Tear down
    0) uninstall       guided teardown

    q) quit
EOF
        printf '> '
        read -r choice
        case "$choice" in
            1) do_install ;;
            2) do_status ;;
            3) "$SCRIPT_DIR/smoke-test.sh" ;;
            4) "$SCRIPT_DIR/valkey-cluster-tests.sh" ;;
            5) "$SCRIPT_DIR/run-unit-tests.sh" --coverage ;;
            6) PAUSE=1 "$SCRIPT_DIR/api-tour.sh" ;;
            7) "$SCRIPT_DIR/valkey-tour.sh" ;;
            8) ip="$(cat "$REPO_ROOT/dumps/haproxy-vm-ip" 2>/dev/null || echo '<install first>')"
               echo; bold "Swagger UI:"
               echo "  http://debug-demo.local/swagger-ui.html"
               dim "  (debug-demo.local → $ip in /etc/hosts; spec at /v3/api-docs)" ;;
            9) "$SCRIPT_DIR/chaos.sh" ;;
            0) do_uninstall ;;
            q) exit 0 ;;
            *) echo "?" ;;
        esac
    done
}

case "${1:-menu}" in
    menu)          menu ;;
    install)       shift; do_install "$@" ;;
    uninstall)     shift; do_uninstall "$@" ;;
    status)        do_status ;;
    smoke)         shift 2>/dev/null; "$SCRIPT_DIR/smoke-test.sh" "$@" ;;
    unit-tests|test) shift 2>/dev/null; "$SCRIPT_DIR/run-unit-tests.sh" "$@" ;;
    tour)          shift 2>/dev/null; "$SCRIPT_DIR/api-tour.sh" "$@" ;;
    cluster-tests) shift 2>/dev/null; "$SCRIPT_DIR/valkey-cluster-tests.sh" "$@" ;;
    chaos)         shift 2>/dev/null; "$SCRIPT_DIR/chaos.sh" "$@" ;;
    -h|--help)     sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//' ;;
    *)             echo "unknown command: $1 (try --help)"; exit 64 ;;
esac
