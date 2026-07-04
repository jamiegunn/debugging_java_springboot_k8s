#!/usr/bin/env bash
#
# local-ci.sh — run the CI flow (build → push image → package + push charts)
# against the local Artifactory installed by charts/artifactory. Mirrors what
# .github/workflows/ci.yml does, but pointed at the in-cluster registry via
# kubectl port-forward.
#
# Prereqs:
#   - artifactory chart installed (helm install artifactory ./charts/artifactory -n artifactory)
#   - Artifactory pod ready: kubectl -n artifactory get pod artifactory-artifactory-0 -> 1/1 Running
#   - docker reachable as the active context (Docker Desktop / any daemon)
#
# Usage:
#   scripts/local-ci.sh                    # uses git short-sha as image tag
#   scripts/local-ci.sh --tag v0.1.0       # explicit tag
#   scripts/local-ci.sh --skip-build       # reuse existing debug-demo-app:dev

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_cmd kubectl docker helm curl

# Defaults — override via env or args.
: "${AF_NAMESPACE:=artifactory}"
: "${AF_SERVICE:=artifactory-artifactory}"
: "${AF_PORT:=8081}"            # Artifactory direct port (works during slow bootstrap of the JFrog router on 8082)
: "${AF_LOCAL_PORT:=8081}"
: "${AF_USER:=admin}"
: "${AF_PASSWORD:=password}"    # Default admin password until you rotate via UI
: "${DOCKER_REPO:=debug-demo-docker}"
: "${HELM_REPO:=debug-demo-helm}"
: "${IMAGE_NAME:=debug-demo-app}"

TAG=""
SKIP_BUILD=0
SKIP_IMAGE=0
SKIP_CHARTS=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tag)         TAG="$2"; shift 2 ;;
        --skip-build)  SKIP_BUILD=1; shift ;;
        --skip-image)  SKIP_IMAGE=1; shift ;;
        --skip-charts) SKIP_CHARTS=1; shift ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) err "unknown arg: $1"; exit 64 ;;
    esac
done

if [[ -z "$TAG" ]]; then
    if git -C "$REPO_ROOT" rev-parse --short HEAD >/dev/null 2>&1; then
        TAG="$(git -C "$REPO_ROOT" rev-parse --short HEAD)"
    else
        TAG="local-$(date -u +%Y%m%dT%H%M%SZ)"
    fi
fi

# When the docker daemon runs inside a VM (Docker Desktop / Lima), `127.0.0.1`
# is the VM, not the host, so kubectl port-forward (bound to host:127.0.0.1) is
# unreachable from docker. We use `host.docker.internal`, which the daemon maps
# to the host. Because that hostname isn't insecure by default, the daemon's
# daemon.json must include:
#   "insecure-registries": ["host.docker.internal:8081"]
# REST/curl calls still go to 127.0.0.1 — those run on the host, not the VM.
REGISTRY_DOCKER="host.docker.internal:${AF_LOCAL_PORT}"
REST_BASE="http://127.0.0.1:${AF_LOCAL_PORT}"
IMAGE_REF="${REGISTRY_DOCKER}/${DOCKER_REPO}/${IMAGE_NAME}:${TAG}"

info "local-ci: tag=$TAG docker_registry=$REGISTRY_DOCKER rest=$REST_BASE"

# --- start port-forward in background, kill on exit -------------------------
PF_PID=""
cleanup() {
    if [[ -n "$PF_PID" ]] && kill -0 "$PF_PID" 2>/dev/null; then
        kill "$PF_PID" 2>/dev/null || true
        wait "$PF_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

info "starting port-forward svc/$AF_SERVICE $AF_LOCAL_PORT:$AF_PORT"
kubectl -n "$AF_NAMESPACE" port-forward "svc/$AF_SERVICE" "$AF_LOCAL_PORT:$AF_PORT" \
    >/tmp/local-ci-pf.log 2>&1 &
PF_PID=$!

# wait for port-forward to be ready
for i in $(seq 1 20); do
    if curl -fsS -o /dev/null "${REST_BASE}/artifactory/api/system/ping"; then
        info "port-forward ready"
        break
    fi
    sleep 1
    if [[ $i -eq 20 ]]; then err "port-forward never became ready"; exit 1; fi
done

# --- build image -----------------------------------------------------------
if [[ $SKIP_BUILD -eq 0 ]]; then
    info "building image $IMAGE_NAME:dev"
    docker build -t "${IMAGE_NAME}:dev" "$REPO_ROOT/app"
else
    info "skipping build (--skip-build)"
fi

# --- push image to artifactory ---------------------------------------------
if [[ $SKIP_IMAGE -eq 0 ]]; then
    info "logging in to $REGISTRY_DOCKER as $AF_USER"
    echo "$AF_PASSWORD" | docker login "$REGISTRY_DOCKER" -u "$AF_USER" --password-stdin

    info "tagging and pushing $IMAGE_REF"
    docker tag "${IMAGE_NAME}:dev" "$IMAGE_REF"
    docker push "$IMAGE_REF"

    # also tag :latest for convenience
    docker tag "${IMAGE_NAME}:dev" "${REGISTRY_DOCKER}/${DOCKER_REPO}/${IMAGE_NAME}:latest"
    docker push "${REGISTRY_DOCKER}/${DOCKER_REPO}/${IMAGE_NAME}:latest"
else
    info "skipping image push (--skip-image)"
fi

# --- package and push helm charts ------------------------------------------
if [[ $SKIP_CHARTS -eq 0 ]]; then
    PACKAGE_DIR="$(mktemp -d)"
    info "packaging charts to $PACKAGE_DIR"

    CHART_VERSION="0.1.0-${TAG}"
    APP_VERSION="$TAG"

    for chart in debug-demo-app oracle ibm-mq artifactory; do
        helm package "$REPO_ROOT/charts/$chart" \
            --version "$CHART_VERSION" \
            --app-version "$APP_VERSION" \
            -d "$PACKAGE_DIR" >/dev/null
        info "  packaged $chart"
    done

    HELM_BASE="${REST_BASE}/artifactory/${HELM_REPO}"
    for tgz in "$PACKAGE_DIR"/*.tgz; do
        TGZ_NAME="$(basename "$tgz")"
        info "  uploading $TGZ_NAME -> $HELM_BASE/$TGZ_NAME"
        curl -fsS -u "$AF_USER:$AF_PASSWORD" \
            -T "$tgz" \
            "$HELM_BASE/$TGZ_NAME" >/dev/null
    done

    rm -rf "$PACKAGE_DIR"
else
    info "skipping chart push (--skip-charts)"
fi

info "done."
info ""
info "Image: $IMAGE_REF"
info "Helm repo index (refresh): curl -u $AF_USER:****  ${REST_BASE}/artifactory/api/helm/${HELM_REPO}/index.yaml"
info ""
info "To deploy from the local registry:"
info "  helm upgrade --install app charts/debug-demo-app -n debug-demo \\"
info "    --set image.repository=${AF_SERVICE}.${AF_NAMESPACE}.svc.cluster.local:${AF_PORT}/${DOCKER_REPO}/${IMAGE_NAME} \\"
info "    --set image.tag=${TAG}"
