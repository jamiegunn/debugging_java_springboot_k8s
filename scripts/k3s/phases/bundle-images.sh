#!/usr/bin/env bash
#
# bundle-images.sh — build the AIR-GAP bundle on the Mac. Runs where you DO
# have registry access (home network, or a corporate mirror), and produces a
# self-contained directory that k3s-cluster.sh copies into each VM. After this,
# nothing inside a VM or pod ever pulls from the internet.
#
# Produces, in dumps/airgap/ :
#   k3s                                  the k3s binary (pinned K3S_VERSION)
#   k3s-airgap-images-<arch>.tar.zst     k3s core images (pause/coredns/etc.)
#   images/<name>.tar                    every third-party image (docker save)
#   images/debug-demo-app.tar            the app image (built here)
#   manifest.txt                         what's in the bundle + digests
#
# Idempotent: skips artifacts already present (unless --force). Fail-fast: a
# pull/build/download that fails stops the bundle with a clear message — the
# whole point is to surface a corporate-proxy/MITM problem HERE, on the Mac,
# not later as an ImagePullBackOff in an air-gapped VM.
#
# Usage:
#   ./bundle-images.sh                 # build/refresh the bundle
#   ./bundle-images.sh --force         # rebuild every artifact
#   ./bundle-images.sh --skip-artifactory   # omit the JCR image (~1 GB)
#   ./bundle-images.sh --list          # print what the bundle will contain, exit

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_ROOT="$SCRIPT_DIR"; while [[ "$SCRIPTS_ROOT" != / && ! -f "$SCRIPTS_ROOT/lib/common.sh" ]]; do SCRIPTS_ROOT="$(dirname "$SCRIPTS_ROOT")"; done
REPO_ROOT="$(cd "$SCRIPTS_ROOT/.." && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPTS_ROOT/lib/common.sh"
# shellcheck source=lib/k3s-env.sh
source "$SCRIPTS_ROOT/lib/k3s-env.sh"

FORCE=0
SKIP_ARTIFACTORY=0
LIST_ONLY=0
for a in "$@"; do
    case "$a" in
        --force)            FORCE=1 ;;
        --skip-artifactory) SKIP_ARTIFACTORY=1 ;;
        --list)             LIST_ONLY=1 ;;
        -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) err "unknown arg: $a"; exit 64 ;;
    esac
done

# Filter the image list per flags.
IMAGES=()
for img in "${K3S_IMAGES[@]}"; do
    [[ $SKIP_ARTIFACTORY -eq 1 && "$img" == *artifactory-jcr* ]] && continue
    IMAGES+=("$img")
done

K3S_BIN="$AIRGAP_DIR/k3s"
K3S_AIRGAP_TAR="$AIRGAP_DIR/k3s-airgap-images-${K3S_ARCH}.tar.zst"
IMAGES_DIR="$AIRGAP_DIR/images"

if [[ $LIST_ONLY -eq 1 ]]; then
    echo "Air-gap bundle contents (dumps/airgap/):"
    echo "  k3s ${K3S_VERSION} (${K3S_ARCH}) binary + airgap images tar"
    echo "  app image: $APP_IMAGE"
    printf '  %s\n' "${IMAGES[@]}"
    exit 0
fi

require_cmd docker curl
if ! docker info >/dev/null 2>&1; then
    err "docker daemon unreachable — start Docker Desktop / colima / your engine"
    exit 1
fi

mkdir -p "$IMAGES_DIR"

# tar name for an image ref (strip registry path + tag/digest → safe filename)
tar_name() {
    local ref="$1"
    ref="${ref%@*}"                 # drop @sha256:...
    echo "${ref}" | tr '/:' '__'    # registry/path:tag → registry_path_tag
}

# IBM MQ ships amd64 only; pull that platform explicitly (Rosetta runs it).
platform_for() { case "$1" in icr.io/ibm-messaging/mq:*) echo "--platform=linux/amd64" ;; *) echo "" ;; esac; }

# --- 1. k3s binary ----------------------------------------------------------
info "[1/4] k3s ${K3S_VERSION} binary (${K3S_ARCH})..."
if [[ $FORCE -eq 0 && -s "$K3S_BIN" ]]; then
    info "  [cached] $K3S_BIN"
else
    bin_suffix=""; [[ "$K3S_ARCH" == "arm64" ]] && bin_suffix="-arm64"
    url="https://github.com/k3s-io/k3s/releases/download/${K3S_VERSION//+/%2B}/k3s${bin_suffix}"
    info "  downloading $url"
    curl -fL --retry 3 -o "$K3S_BIN" "$url" || { err "  k3s binary download failed"; exit 1; }
    chmod +x "$K3S_BIN"
fi

# --- 2. k3s airgap images tar ----------------------------------------------
info "[2/4] k3s airgap core images tar..."
if [[ $FORCE -eq 0 && -s "$K3S_AIRGAP_TAR" ]]; then
    info "  [cached] $K3S_AIRGAP_TAR"
else
    url="https://github.com/k3s-io/k3s/releases/download/${K3S_VERSION//+/%2B}/k3s-airgap-images-${K3S_ARCH}.tar.zst"
    info "  downloading $url"
    curl -fL --retry 3 -o "$K3S_AIRGAP_TAR" "$url" || { err "  k3s airgap tar download failed"; exit 1; }
fi

# --- 3. third-party images --------------------------------------------------
info "[3/4] third-party images (pull on Mac → docker save)..."
n=0; total=${#IMAGES[@]}
for img in "${IMAGES[@]}"; do
    n=$((n+1))
    tar="$IMAGES_DIR/$(tar_name "$img").tar"
    if [[ $FORCE -eq 0 && -s "$tar" ]]; then
        info "  [$n/$total] [cached]  $img"
        continue
    fi
    info "  [$n/$total] [pull]    $img"
    # shellcheck disable=SC2046
    if ! docker pull $(platform_for "$img") "$img" >/dev/null 2>/tmp/bundle-pull.err; then
        err "  pull FAILED: $img"; sed 's/^/    /' /tmp/bundle-pull.err | head -5
        registry="${img%%/*}"; [[ "$registry" != *.* ]] && registry="docker.io"
        err "  registry: $registry — on a corporate network this is where a"
        err "  blocked registry or TLS-intercepting proxy shows up. Fix access"
        err "  (or point at your mirror) and re-run."
        exit 1
    fi
    info "  [$n/$total] [save]    → $(basename "$tar")"
    docker save "$img" -o "$tar" || { err "  docker save failed for $img"; exit 1; }
done

# --- 4. the app image (built here) ------------------------------------------
info "[4/4] app image ${APP_IMAGE} (build → save)..."
app_tar="$IMAGES_DIR/debug-demo-app.tar"
if [[ $FORCE -eq 0 && -s "$app_tar" ]] && docker image inspect "$APP_IMAGE" >/dev/null 2>&1; then
    info "  [cached] $app_tar"
else
    info "  docker build app/ (maven + JRE bases must already be pulled above)"
    ( cd "$REPO_ROOT/app" && docker build -t "$APP_IMAGE" . ) || { err "  app build failed"; exit 1; }
    docker save "$APP_IMAGE" -o "$app_tar" || { err "  docker save app failed"; exit 1; }
fi

# --- manifest ---------------------------------------------------------------
{
    echo "# air-gap bundle — generated for k3s ${K3S_VERSION} (${K3S_ARCH})"
    echo "# app image: $APP_IMAGE"
    for img in "${IMAGES[@]}"; do echo "$img"; done
} > "$AIRGAP_DIR/manifest.txt"

du_total="$(du -sh "$AIRGAP_DIR" 2>/dev/null | awk '{print $1}')"
echo
info "bundle ready: $AIRGAP_DIR  (${du_total:-?})"
info "  $(ls "$IMAGES_DIR"/*.tar 2>/dev/null | wc -l | tr -d ' ') image tars + k3s binary + k3s airgap tar"
info "next: scripts/k3s/phases/cluster.sh up   (provisions VMs + installs k3s, all offline)"
