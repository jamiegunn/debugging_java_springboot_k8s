#!/usr/bin/env bash
#
# run-unit-tests.sh — run the JVM tests with the right JDK, regardless of what
# your shell's default java is.
#
# The project targets Java 21. Mockito's inline mock maker can't instrument
# newer JDKs (26+), so on a machine whose default is newer, `mvn test` fails
# with "Could not modify all classes". This wrapper finds a JDK 21 and pins
# JAVA_HOME for the Maven run so you never have to think about it.
#
#   ./run-unit-tests.sh              # unit tests only (Surefire) — fast, no Docker
#   ./run-unit-tests.sh --integration   # + Testcontainers ITs (Failsafe) — needs Docker
#   ./run-unit-tests.sh --coverage      # unit tests + print a per-class test count
#   ./run-unit-tests.sh -- <mvn args>   # pass anything after -- straight to Maven
#
# Examples:
#   ./run-unit-tests.sh -- -Dtest=OrderServiceTest        # one class
#   ./run-unit-tests.sh -- '-Dtest=OrderServiceTest#create_fans_out_to_every_valkey_op_type'

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_ROOT="$SCRIPT_DIR"; while [[ "$SCRIPTS_ROOT" != / && ! -f "$SCRIPTS_ROOT/lib/common.sh" ]]; do SCRIPTS_ROOT="$(dirname "$SCRIPTS_ROOT")"; done
REPO_ROOT="$(cd "$SCRIPTS_ROOT/.." && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPTS_ROOT/lib/common.sh"

APP_DIR="$REPO_ROOT/app"
MODE=unit
COVERAGE=0
declare -a MVN_EXTRA=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --integration|-it) MODE=integration; shift ;;
        --coverage)        COVERAGE=1; shift ;;
        --)                shift; MVN_EXTRA=("$@"); break ;;
        -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) err "unknown arg: $1 (use -- to pass args to Maven)"; exit 64 ;;
    esac
done

require_cmd mvn

# --- find a JDK 21 -----------------------------------------------------------
JH=""
if [[ "$(uname)" == "Darwin" ]] && /usr/libexec/java_home -v 21 >/dev/null 2>&1; then
    JH="$(/usr/libexec/java_home -v 21)"
elif [[ -n "${JAVA_HOME:-}" ]] && "${JAVA_HOME}/bin/java" -version 2>&1 | grep -q 'version "21'; then
    JH="$JAVA_HOME"
elif command -v java >/dev/null 2>&1 && java -version 2>&1 | grep -q 'version "21'; then
    JH="$(dirname "$(dirname "$(command -v java)")")"
fi

if [[ -z "$JH" ]]; then
    err "no JDK 21 found."
    err "  macOS:  brew install openjdk@21"
    err "  then re-run — this script auto-detects it via /usr/libexec/java_home -v 21"
    err "  or set JAVA_HOME to a 21 install and re-run."
    exit 1
fi
info "using JDK 21 at: $JH"

# --- run ---------------------------------------------------------------------
cd "$APP_DIR"
if [[ "$MODE" == "integration" ]]; then
    info "running unit + Testcontainers integration tests (mvn verify)..."
    info "  (needs a running Docker/moby — the ITs spin up Oracle Free + IBM MQ)"
    GOAL=verify
else
    info "running unit tests (mvn test)..."
    GOAL=test
fi

set +e
JAVA_HOME="$JH" mvn "$GOAL" ${MVN_EXTRA[@]+"${MVN_EXTRA[@]}"}
RC=$?
set -e

echo
if [[ $RC -eq 0 ]]; then
    info "BUILD SUCCESS"
    if [[ $COVERAGE -eq 1 ]]; then
        echo
        info "Tests per class (from Surefire reports):"
        find target/surefire-reports -name 'TEST-*.xml' 2>/dev/null | while read -r f; do
            cls="$(basename "$f" .xml | sed 's/^TEST-//')"
            n="$(grep -oE 'tests="[0-9]+"' "$f" | head -1 | grep -oE '[0-9]+')"
            printf '    %-60s %s\n' "$cls" "${n:-?}"
        done
    fi
else
    err "tests failed (exit $RC) — see target/surefire-reports/ for detail"
fi
exit $RC
