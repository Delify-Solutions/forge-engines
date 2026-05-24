#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Build Apache httpd for macOS as a self-contained tarball, with APR, APR-util,
# and PCRE2 built inline so the user doesn't need any Homebrew presence.
#
# Usage: scripts/build-apache.sh <version>
#
# Output:
#   dist/apache-<version>-darwin-<arch>.tar.gz
#   dist/apache-<version>-darwin-<arch>.sha256
#
# Archive layout:
#   apache-<version>/
#     sbin/httpd
#     bin/apachectl
#     bin/htpasswd
#     bin/htdigest
#     bin/ab
#     modules/*.so
#     conf/                # httpd.conf, mime.types, magic (defaults from upstream)
#     README.md

set -euo pipefail

VERSION="${1:?usage: build-apache.sh <version>}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$REPO_ROOT/build/apache-$VERSION"
DIST="$REPO_ROOT/dist"
ARCH="$(uname -m)"
case "$ARCH" in
    arm64)  TRIPLE="darwin-arm64" ;;
    x86_64) TRIPLE="darwin-x64" ;;
    *) echo "unsupported arch: $ARCH" >&2; exit 1 ;;
esac

# Pin dependency versions. Bumping any of these requires a new apache tag
# (e.g. apache-2.4.62-r2) so installs remain reproducible.
APR_VERSION="1.7.5"
APR_UTIL_VERSION="1.6.3"
PCRE2_VERSION="10.44"
ZLIB_VERSION="1.3.1"

HTTPD_URL="https://archive.apache.org/dist/httpd/httpd-${VERSION}.tar.gz"
APR_URL="https://archive.apache.org/dist/apr/apr-${APR_VERSION}.tar.gz"
APR_UTIL_URL="https://archive.apache.org/dist/apr/apr-util-${APR_UTIL_VERSION}.tar.gz"
PCRE2_URL="https://github.com/PCRE2Project/pcre2/releases/download/pcre2-${PCRE2_VERSION}/pcre2-${PCRE2_VERSION}.tar.gz"
ZLIB_URL="https://zlib.net/fossils/zlib-${ZLIB_VERSION}.tar.gz"

PKG_DIR="$BUILD/pkg/apache-${VERSION}"
ARCHIVE="$DIST/apache-${VERSION}-${TRIPLE}.tar.gz"
PCRE2_PREFIX="$BUILD/pcre2-built"
ZLIB_PREFIX="$BUILD/zlib-built"

# httpd's --prefix is baked into the binary as a default ServerRoot, but at
# runtime Forge always invokes `httpd -d <actual-root>`, so the compiled-in
# prefix is irrelevant. We use a dummy path consistent with the nginx script.
PREFIX_DUMMY="/usr/local/forge/apache"
JOBS="$(sysctl -n hw.ncpu)"

mkdir -p "$BUILD" "$DIST"

fetch() {
    local url="$1" out="$2"
    if [ ! -f "$out" ]; then
        echo "==> fetching $url"
        curl -fsSL --retry 3 -o "$out" "$url"
    fi
}

extract_once() {
    local tarball="$1" dest_parent="$2" dest_name="$3"
    if [ ! -d "$dest_parent/$dest_name" ]; then
        echo "==> extracting $(basename "$tarball")"
        tar -xzf "$tarball" -C "$dest_parent"
    fi
}

# --- Fetch sources ---

HTTPD_TAR="$BUILD/httpd-${VERSION}.tar.gz"
APR_TAR="$BUILD/apr-${APR_VERSION}.tar.gz"
APR_UTIL_TAR="$BUILD/apr-util-${APR_UTIL_VERSION}.tar.gz"
PCRE2_TAR="$BUILD/pcre2-${PCRE2_VERSION}.tar.gz"
ZLIB_TAR="$BUILD/zlib-${ZLIB_VERSION}.tar.gz"

fetch "$HTTPD_URL" "$HTTPD_TAR"
fetch "$APR_URL" "$APR_TAR"
fetch "$APR_UTIL_URL" "$APR_UTIL_TAR"
fetch "$PCRE2_URL" "$PCRE2_TAR"
fetch "$ZLIB_URL" "$ZLIB_TAR"

extract_once "$HTTPD_TAR" "$BUILD" "httpd-${VERSION}"
extract_once "$APR_TAR" "$BUILD" "apr-${APR_VERSION}"
extract_once "$APR_UTIL_TAR" "$BUILD" "apr-util-${APR_UTIL_VERSION}"
extract_once "$PCRE2_TAR" "$BUILD" "pcre2-${PCRE2_VERSION}"
extract_once "$ZLIB_TAR" "$BUILD" "zlib-${ZLIB_VERSION}"

HTTPD_SRC="$BUILD/httpd-${VERSION}"
APR_SRC="$BUILD/apr-${APR_VERSION}"
APR_UTIL_SRC="$BUILD/apr-util-${APR_UTIL_VERSION}"
PCRE2_SRC="$BUILD/pcre2-${PCRE2_VERSION}"
ZLIB_SRC="$BUILD/zlib-${ZLIB_VERSION}"

# --- 1. Build PCRE2 standalone ---

if [ ! -f "$PCRE2_PREFIX/lib/libpcre2-8.a" ]; then
    echo "==> building PCRE2 ${PCRE2_VERSION}"
    cd "$PCRE2_SRC"
    ./configure \
        --prefix="$PCRE2_PREFIX" \
        --disable-shared \
        --enable-static \
        --enable-jit \
        CFLAGS="-O2 -arch $ARCH -mmacosx-version-min=11.0" \
        LDFLAGS="-arch $ARCH"
    make -j"$JOBS"
    make install
fi

# --- 1b. Build zlib standalone (mod_deflate dependency) ---

if [ ! -f "$ZLIB_PREFIX/lib/libz.a" ]; then
    echo "==> building zlib ${ZLIB_VERSION}"
    cd "$ZLIB_SRC"
    CFLAGS="-O2 -arch $ARCH -mmacosx-version-min=11.0" \
    LDFLAGS="-arch $ARCH" \
    ./configure \
        --prefix="$ZLIB_PREFIX" \
        --static
    make -j"$JOBS"
    make install
fi

# --- 2. Place APR + APR-util into httpd srclib ---

if [ ! -d "$HTTPD_SRC/srclib/apr" ]; then
    echo "==> placing APR into srclib/apr"
    cp -R "$APR_SRC" "$HTTPD_SRC/srclib/apr"
fi

if [ ! -d "$HTTPD_SRC/srclib/apr-util" ]; then
    echo "==> placing APR-util into srclib/apr-util"
    cp -R "$APR_UTIL_SRC" "$HTTPD_SRC/srclib/apr-util"
fi

# --- 3. Configure + build httpd ---

echo "==> configuring httpd ${VERSION}"
cd "$HTTPD_SRC"

./configure \
    --prefix="$PREFIX_DUMMY" \
    --with-included-apr \
    --with-pcre="$PCRE2_PREFIX/bin/pcre2-config" \
    --with-z="$ZLIB_PREFIX" \
    --enable-mods-shared=most \
    --enable-proxy \
    --enable-proxy-fcgi \
    --enable-rewrite \
    --enable-headers \
    --enable-deflate \
    --enable-expires \
    --disable-ssl \
    --enable-so \
    --with-mpm=event \
    CFLAGS="-O2 -arch $ARCH -mmacosx-version-min=11.0 -I$ZLIB_PREFIX/include" \
    LDFLAGS="-arch $ARCH -L$ZLIB_PREFIX/lib"

echo "==> building httpd"
make -j"$JOBS"

echo "==> installing to staging area"
make install DESTDIR="$BUILD/install"

# --- 4. Package into final layout ---

STAGED="$BUILD/install${PREFIX_DUMMY}"

echo "==> packaging"
rm -rf "$PKG_DIR"
mkdir -p "$PKG_DIR/sbin" "$PKG_DIR/bin" "$PKG_DIR/modules" "$PKG_DIR/conf"

# Core binary
cp "$STAGED/bin/httpd" "$PKG_DIR/sbin/httpd"

# Utility binaries
cp "$STAGED/bin/apachectl" "$PKG_DIR/bin/apachectl"
cp "$STAGED/bin/htpasswd" "$PKG_DIR/bin/htpasswd"
cp "$STAGED/bin/htdigest" "$PKG_DIR/bin/htdigest" 2>/dev/null || true
cp "$STAGED/bin/ab" "$PKG_DIR/bin/ab" 2>/dev/null || true

# Dynamic modules
if [ -d "$STAGED/modules" ]; then
    cp "$STAGED/modules"/*.so "$PKG_DIR/modules/" 2>/dev/null || true
fi

# Default config files (Forge generates its own httpd.conf but these are
# useful as reference and for include directives)
cp "$STAGED/conf/httpd.conf" "$PKG_DIR/conf/httpd.conf" 2>/dev/null || true
cp "$STAGED/conf/mime.types" "$PKG_DIR/conf/mime.types" 2>/dev/null || true
cp "$STAGED/conf/magic" "$PKG_DIR/conf/magic" 2>/dev/null || true
cp "$STAGED/conf/extra/httpd-default.conf" "$PKG_DIR/conf/httpd-default.conf" 2>/dev/null || true

# --- 5. Strip binaries ---

echo "==> stripping binaries"
strip -x "$PKG_DIR/sbin/httpd" || true
for bin in "$PKG_DIR/bin"/*; do
    [ -f "$bin" ] && strip -x "$bin" || true
done

# --- 6. README ---

cat > "$PKG_DIR/README.md" <<EOF
# Apache httpd $VERSION (built for Delify Forge)

Built with:
- APR $APR_VERSION
- APR-util $APR_UTIL_VERSION
- PCRE2 $PCRE2_VERSION
- zlib $ZLIB_VERSION

Architecture: $TRIPLE
Build host: $(uname -mrs)
Build date (UTC): $(date -u +"%Y-%m-%dT%H:%M:%SZ")

Upstream sources:
- httpd:     $HTTPD_URL
- APR:       $APR_URL
- APR-util:  $APR_UTIL_URL
- PCRE2:     $PCRE2_URL
- zlib:      $ZLIB_URL

Upstream license: Apache httpd is Apache-2.0; bundled deps under their
respective licenses (APR: Apache-2.0, PCRE2: BSD-3-Clause, zlib: zlib license).
EOF

# --- 7. Create archive + checksum ---

cd "$REPO_ROOT"
echo "==> creating $ARCHIVE"
tar -czf "$ARCHIVE" -C "$BUILD/pkg" "apache-${VERSION}"
( cd "$DIST" && shasum -a 256 "$(basename "$ARCHIVE")" > "$(basename "${ARCHIVE%.tar.gz}").sha256" )

echo "==> done"
echo "    archive: $ARCHIVE"
echo "    sha256:  $(cat "${ARCHIVE%.tar.gz}.sha256")"
