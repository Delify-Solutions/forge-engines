#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Build dnsmasq for macOS as a self-contained tarball.
#
# Usage: scripts/build-dnsmasq.sh <version>
#
# Output (relative to repo root):
#   dist/dnsmasq-<version>-darwin-<arch>.tar.gz
#   dist/dnsmasq-<version>-darwin-<arch>.sha256
#
# The archive expands to:
#   dnsmasq-<version>/
#     sbin/dnsmasq
#     README.md            # source + build provenance

set -euo pipefail

VERSION="${1:?usage: build-dnsmasq.sh <version>}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$REPO_ROOT/build/dnsmasq-$VERSION"
DIST="$REPO_ROOT/dist"
ARCH="$(uname -m)"
case "$ARCH" in
    arm64)  TRIPLE="darwin-arm64" ;;
    x86_64) TRIPLE="darwin-x64" ;;
    *) echo "unsupported arch: $ARCH" >&2; exit 1 ;;
esac

URL="https://thekelleys.org.uk/dnsmasq/dnsmasq-${VERSION}.tar.gz"
SRC_TARBALL="$BUILD/dnsmasq-${VERSION}.tar.gz"
SRC_DIR="$BUILD/dnsmasq-${VERSION}"
PKG_DIR="$BUILD/pkg/dnsmasq-${VERSION}"
ARCHIVE="$DIST/dnsmasq-${VERSION}-${TRIPLE}.tar.gz"

mkdir -p "$BUILD" "$DIST"

echo "==> fetching $URL"
curl -fsSL --retry 3 -o "$SRC_TARBALL" "$URL"

echo "==> extracting"
rm -rf "$SRC_DIR"
tar -xzf "$SRC_TARBALL" -C "$BUILD"

echo "==> building (arch=$ARCH)"
# dnsmasq has no autoconf — its Makefile honors CFLAGS / LDFLAGS.
# COPTS controls optional features. We disable IPv6+nettle dependencies that
# aren't needed for resolving *.test → 127.0.0.1.
make -C "$SRC_DIR" \
    CC="cc" \
    CFLAGS="-O2 -arch $ARCH -mmacosx-version-min=11.0" \
    LDFLAGS="-arch $ARCH" \
    COPTS="-DNO_IPSET -DNO_AUTH -DNO_DHCP -DNO_TFTP -DNO_DUMPFILE -DNO_INOTIFY -DNO_GMP -DNO_DNSSEC" \
    -j"$(sysctl -n hw.ncpu)"

echo "==> packaging"
rm -rf "$PKG_DIR"
mkdir -p "$PKG_DIR/sbin"
cp "$SRC_DIR/src/dnsmasq" "$PKG_DIR/sbin/dnsmasq"
strip -x "$PKG_DIR/sbin/dnsmasq"

cat > "$PKG_DIR/README.md" <<EOF
# dnsmasq $VERSION (built for Delify Forge)

- Upstream source: $URL
- Upstream license: GPL-2.0
- Architecture: $TRIPLE
- Build host: $(uname -mrs)
- Build date (UTC): $(date -u +"%Y-%m-%dT%H:%M:%SZ")

This binary is distributed as a build artifact. Source code is available at
https://thekelleys.org.uk/dnsmasq/.
EOF

# Tar from the parent of the version dir so the archive expands to dnsmasq-<version>/.
echo "==> creating $ARCHIVE"
tar -czf "$ARCHIVE" -C "$BUILD/pkg" "dnsmasq-${VERSION}"
shasum -a 256 "$ARCHIVE" > "${ARCHIVE%.tar.gz}.sha256"

echo "==> done"
echo "    archive: $ARCHIVE"
echo "    sha256:  $(cat "${ARCHIVE%.tar.gz}.sha256")"
