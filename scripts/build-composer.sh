#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Package Composer for Delify Forge.
#
# Composer is a PHAR — architecture-independent, no compilation needed.
# We download the upstream PHAR, verify its sha256 against the published
# checksum, and pack it into the same tarball layout the rest of the
# catalog uses (bin/composer + README.md). The "_arm64" / "_x64" suffix
# in the archive name is cosmetic — both arches receive the same bytes,
# but the matrix in release.yml expects a per-arch artefact.
#
# Usage: scripts/build-composer.sh <version>

set -euo pipefail

VERSION="${1:?usage: build-composer.sh <version>}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$REPO_ROOT/build/composer-$VERSION"
DIST="$REPO_ROOT/dist"
ARCH="$(uname -m)"
case "$ARCH" in
    arm64)  TRIPLE="darwin-arm64" ;;
    x86_64) TRIPLE="darwin-x64" ;;
    *) echo "unsupported arch: $ARCH" >&2; exit 1 ;;
esac

PHAR_URL="https://getcomposer.org/download/${VERSION}/composer.phar"
SUM_URL="https://getcomposer.org/download/${VERSION}/composer.phar.sha256sum"

PKG_DIR="$BUILD/pkg/composer-${VERSION}"
ARCHIVE="$DIST/composer-${VERSION}-${TRIPLE}.tar.gz"

mkdir -p "$BUILD" "$DIST" "$PKG_DIR/bin"

echo "==> fetching composer ${VERSION}"
PHAR="$BUILD/composer.phar"
SUMFILE="$BUILD/composer.phar.sha256sum"
curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors --connect-timeout 30 --max-time 600 -o "$PHAR" "$PHAR_URL"
curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors --connect-timeout 30 --max-time 600 -o "$SUMFILE" "$SUM_URL"

echo "==> verifying sha256"
expected="$(awk '{print $1}' "$SUMFILE")"
got="$(shasum -a 256 "$PHAR" | awk '{print $1}')"
if [ "$expected" != "$got" ]; then
    echo "  sha256 mismatch: expected $expected, got $got" >&2
    exit 1
fi

echo "==> packaging"
# Composer is invoked as `composer ...`. We ship the phar at bin/composer
# with a +x bit and a phar shebang so it runs via the user's PHP. Forge
# always invokes it as `<bundled-php> bin/composer ...` so an absent
# system php doesn't matter, but keeping the shebang lets users run the
# binary directly if they wish.
cp "$PHAR" "$PKG_DIR/bin/composer"
chmod 755 "$PKG_DIR/bin/composer"

cat > "$PKG_DIR/README.md" <<EOF
# Composer ${VERSION} (packaged for Delify Forge)

The bin/composer file is the upstream composer.phar verified against
https://getcomposer.org/download/${VERSION}/composer.phar.sha256sum.

Architecture: ${TRIPLE} (PHAR is arch-independent; both darwin-arm64 and
darwin-x64 archives ship identical bytes — the suffix is cosmetic so the
release matrix can publish one artefact per arch.)

Build date (UTC): $(date -u +"%Y-%m-%dT%H:%M:%SZ")

Upstream license: MIT (see https://github.com/composer/composer/blob/main/LICENSE).
EOF

cd "$REPO_ROOT"
echo "==> creating $ARCHIVE"
tar -czf "$ARCHIVE" -C "$BUILD/pkg" "composer-${VERSION}"
( cd "$DIST" && shasum -a 256 "$(basename "$ARCHIVE")" > "$(basename "${ARCHIVE%.tar.gz}").sha256" )

echo "==> done"
echo "    archive: $ARCHIVE"
echo "    sha256:  $(cat "${ARCHIVE%.tar.gz}.sha256")"
