#!/usr/bin/env bash
#
# preload-images.sh — pull every container image the stack needs, before the
# install kicks off. Exists so corporate-MITM TLS failures (proxied registries,
# re-signed certs) surface as one clear error at the earliest possible point,
# instead of as a pod stuck in ImagePullBackOff twenty minutes into
# install-stack.sh.
#
# Pulls go through the Rancher Desktop moby engine (the `docker` CLI on this
# Mac), which is the same image store the cluster's kubelet uses — an image
# pulled here is "already present on machine" when the pod starts.
#
# Idempotent: images already present are skipped ([cached]).
# Fail-fast:  exits non-zero on the FIRST pull failure, naming the image and
#             registry, with the underlying docker error shown. Nothing is
#             swallowed — surfacing the failure is the point.
#
# Usage:
#   ./preload-images.sh                   # pull everything not already present
#   ./preload-images.sh --manifest-only   # print the image list and exit
#                                         # (for security review / air-gap prep)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

# One entry per image the install path needs, grouped by the install-stack.sh
# phase that consumes it. Versions are pinned to match what each phase installs;
# when you bump a version in install-stack.sh or a chart's values.yaml, update
# the matching line here (the comment on each group says where the version
# authority lives). ingress-nginx refs include the digest because the chart
# pins images by tag@digest — pulling the same ref guarantees kubelet's
# "already present" check matches.
IMAGES=(
    # MetalLB manifest (install-stack.sh Phase 2, METALLB_VERSION)
    "quay.io/metallb/controller:v0.14.8"
    "quay.io/metallb/speaker:v0.14.8"

    # ingress-nginx chart 4.11.3 (install-stack.sh Phase 2, NGINX_INGRESS_VERSION)
    # Refs extracted from: helm template ingress-nginx/ingress-nginx --version 4.11.3 | grep image:
    "registry.k8s.io/ingress-nginx/controller:v1.11.3@sha256:d56f135b6462cfc476447cfe564b83a45e8bb7da2774963b00d12161112270b7"
    "registry.k8s.io/ingress-nginx/kube-webhook-certgen:v1.4.4@sha256:a9f03b34a3cbfbb26d103a14046ab2c5130a80c3d69d526ff8063d2b37b9fd3f"

    # Stateful backends (install-stack.sh --set overrides + charts/*/values.yaml)
    "gvenzl/oracle-free:23-slim-faststart"
    "icr.io/ibm-messaging/mq:9.4.5.1-r1-amd64"
    "valkey/valkey:8.0.1-alpine"
    "releases-docker.jfrog.io/jfrog/artifactory-jcr:7.90.10"
    "postgres:16-alpine"

    # Valkey dev VIP shim (charts/valkey values: devVipShim.image/initImage)
    "haproxy:3.0-alpine"
    "busybox:1.36"

    # App image build (install-stack.sh Phase 4, app/Dockerfile FROM lines)
    "maven:3.9-eclipse-temurin-21"
    "eclipse-temurin:21-jre-alpine"
)

if [[ "${1:-}" == "--manifest-only" ]]; then
    printf '%s\n' "${IMAGES[@]}"
    exit 0
fi
if [[ $# -gt 0 ]]; then
    err "unknown arg: $1 (only --manifest-only is accepted)"
    exit 64
fi

require_cmd docker
if ! docker info >/dev/null 2>&1; then
    err "docker daemon unreachable — is Rancher Desktop running with the moby engine?"
    exit 1
fi

# IBM MQ ships amd64 only; on Apple Silicon the pod runs it under Rosetta.
# docker pull follows the same rule: request the amd64 platform explicitly for
# that image so the pull doesn't fail resolving a nonexistent arm64 manifest.
platform_args_for() {
    case "$1" in
        icr.io/ibm-messaging/mq:*) echo "--platform=linux/amd64" ;;
        *) echo "" ;;
    esac
}

TOTAL=${#IMAGES[@]}
N=0
PULLED=0
CACHED=0
for image in "${IMAGES[@]}"; do
    N=$((N+1))
    if docker image inspect "$image" >/dev/null 2>&1; then
        info "  [$N/$TOTAL] [cached]  $image"
        CACHED=$((CACHED+1))
        continue
    fi
    info "  [$N/$TOTAL] [pulling] $image"
    # shellcheck disable=SC2046  # platform arg is intentionally word-split (empty or one flag)
    if ! docker pull $(platform_args_for "$image") "$image" 2>&1 | sed 's/^/      /'; then
        registry="${image%%/*}"
        [[ "$registry" == "$image" || "$registry" != *.* ]] && registry="docker.io"
        err "image pull FAILED: $image"
        err "  registry: $registry"
        err "  Common cause on corporate networks: TLS interception (MITM proxy)."
        err "  Verify with:  curl -v https://${registry}/v2/ 2>&1 | grep -E 'issuer|SSL'"
        err "  If the issuer is your corporate CA, add it to the RD VM's trust store"
        err "  or pull this image from an allowed internal mirror and retag it."
        exit 1
    fi
    PULLED=$((PULLED+1))
done

info "  image preload complete: $PULLED pulled, $CACHED already cached ($TOTAL total)"
