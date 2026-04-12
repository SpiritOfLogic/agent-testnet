#!/usr/bin/env bash
#
# Build release artifacts for all platforms.
#
# Produces:
#   dist/testnet-server-linux-amd64
#   dist/testnet-client-linux-amd64
#   dist/testnet-node-linux-amd64
#   dist/testnet-server-linux-arm64
#   dist/testnet-client-linux-arm64
#   dist/testnet-node-linux-arm64
#   dist/install.sh
#
# If --rootfs is passed and running on Linux, also builds:
#   dist/rootfs-agent-amd64.ext4.gz
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
DIST_DIR="${PROJECT_DIR}/dist"

BUILD_ROOTFS=false
if [[ "${1:-}" == "--rootfs" ]]; then
    BUILD_ROOTFS=true
fi

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

# ---- Cross-compile binaries ----

build_binaries() {
    local arch="$1"
    echo "==> Building linux/${arch} binaries..."

    for bin in testnet-server testnet-client testnet-node; do
        local cmd_dir="./cmd/${bin}"
        local out="${DIST_DIR}/${bin}-linux-${arch}"
        CGO_ENABLED=0 GOOS=linux GOARCH="${arch}" \
            go build -ldflags="-s -w" -o "$out" "$cmd_dir"
        echo "    ${out}"
    done
}

cd "$PROJECT_DIR"

if command -v go >/dev/null 2>&1; then
    build_binaries amd64
    build_binaries arm64
else
    echo "==> Go not found locally, building via Docker..."
    docker build -f Dockerfile.build -t agent-testnet-builder .
    CONTAINER_ID=$(docker create --entrypoint="" agent-testnet-builder /bin/true)
    for bin in testnet-server testnet-client testnet-node; do
        docker cp "${CONTAINER_ID}:/${bin}" "${DIST_DIR}/${bin}-linux-amd64"
    done
    docker rm "$CONTAINER_ID" >/dev/null
    echo "    Built amd64 binaries via Docker (arm64 skipped)"
fi

# ---- Copy install script ----

cp "${PROJECT_DIR}/deploy/install.sh" "${DIST_DIR}/install.sh"
chmod +x "${DIST_DIR}/install.sh"
echo "==> Copied install.sh"

# ---- Build rootfs (optional, Linux only) ----

if $BUILD_ROOTFS; then
    if [[ "$(uname)" != "Linux" ]]; then
        echo "==> Skipping rootfs build (requires Linux)"
    else
        echo "==> Building rootfs..."
        sudo bash "${PROJECT_DIR}/scripts/gen-rootfs.sh"

        ROOTFS_SRC="/tmp/testnet-rootfs/rootfs.ext4"
        ROOTFS_DST="${DIST_DIR}/rootfs-agent-amd64.ext4.gz"
        echo "    Compressing rootfs..."
        gzip -c "$ROOTFS_SRC" > "$ROOTFS_DST"
        echo "    ${ROOTFS_DST} ($(du -sh "$ROOTFS_DST" | cut -f1))"
    fi
fi

# ---- Summary ----

echo ""
echo "==> Release artifacts in ${DIST_DIR}/:"
ls -lh "$DIST_DIR/"
echo ""
echo "To create a GitHub release:"
echo "  gh release create vX.Y.Z dist/* --title 'vX.Y.Z' --notes 'Release notes'"
