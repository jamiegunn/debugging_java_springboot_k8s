#!/usr/bin/env bash
#
# tail-logs.sh — stream logs from all debug-demo-app replicas with pod-name prefix.
# Falls back to `stern` if available, otherwise uses `kubectl logs -f -l`.
#
# Usage:
#   ./tail-logs.sh [-n namespace] [-l selector] [--container name]

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_cmd kubectl

parse_common_args "$@"

if command -v stern >/dev/null 2>&1; then
    info "using stern"
    exec stern -n "$NAMESPACE" --selector "$SELECTOR" --container "$APP_CONTAINER" --tail 50
fi

info "using kubectl (install 'stern' for prettier output)"
exec kubectl -n "$NAMESPACE" logs -f \
    --selector "$SELECTOR" \
    --container "$APP_CONTAINER" \
    --max-log-requests 10 \
    --prefix \
    --tail 50
