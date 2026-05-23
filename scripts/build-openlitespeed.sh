#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Build OpenLiteSpeed for macOS as a self-contained tarball, with PCRE2, zlib,
# and OpenSSL built standalone so the user doesn't need any Homebrew presence.
#
# Usage: scripts/build-openlitespeed.sh <version>
#
# Output:
#   dist/openlitespeed-<version>-darwin-<arch>.tar.gz
#   dist/openlitespeed-<version>-darwin-<arch>.sha256
#
# Archive layout:
#   openlitespeed-<version>/
#     sbin/lshttpd           # the daemon binary
#     bin/lswsctrl           # control script wrapper
#     conf/                  # httpd_config.conf, mime.properties, etc.
#     fcgi-bin/              # standard fcgi templates if shipped
#     README.md
#
# Notes on OLS build system:
#   OLS ships an install.sh script-based installer, but also supports the
#   standard ./configure && make && make install flow when --prefix is set.
#   We use the latter for reproducibility and DESTDIR support.
#
#   OLS installs into $PREFIX/lsws/ by default. The DESTDIR approach captures
#   the full tree and we cherry-pick the pieces we need.

set -euo pipefail

VERSION="${1:?usage: build-openlitespeed.sh <version>}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$REPO_ROOT/build/openlitespeed-$VERSION"
DIST="$REPO_ROOT/dist"
ARCH="$(uname -m)"
case "$ARCH" in
    arm64)  TRIPLE="darwin-arm64" ;;
    x86_64) TRIPLE="darwin-x64" ;;
    *) echo "unsupported arch: $ARCH" >&2; exit 1 ;;
esac

# Pin dependency versions. Bumping any of these requires a new openlitespeed
# tag (e.g. openlitespeed-1.8.4-r2) so installs remain reproducible.
PCRE2_VERSION="10.44"
ZLIB_VERSION="1.3.1"
OPENSSL_VERSION="3.3.2"

OLS_URL="https://openlitespeed.org/packages/openlitespeed-${VERSION}.src.tgz"
PCRE2_URL="https://github.com/PCRE2Project/pcre2/releases/download/pcre2-${PCRE2_VERSION}/pcre2-${PCRE2_VERSION}.tar.gz"
ZLIB_URL="https://zlib.net/fossils/zlib-${ZLIB_VERSION}.tar.gz"
OPENSSL_URL="https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz"

PKG_DIR="$BUILD/pkg/openlitespeed-${VERSION}"
ARCHIVE="$DIST/openlitespeed-${VERSION}-${TRIPLE}.tar.gz"
PCRE2_PREFIX="$BUILD/pcre2-built"
ZLIB_PREFIX="$BUILD/zlib-built"
OPENSSL_PREFIX="$BUILD/openssl-built"

# OLS installs into $PREFIX/lsws/ — we use a dummy prefix since Forge
# controls the runtime root via its own config generation.
PREFIX_DUMMY="/usr/local/forge/openlitespeed"
JOBS="$(sysctl -n hw.ncpu)"

# OpenSSL Configure target varies by architecture
case "$ARCH" in
    arm64)  OPENSSL_TARGET="darwin64-arm64-cc" ;;
    x86_64) OPENSSL_TARGET="darwin64-x86_64-cc" ;;
esac

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

OLS_TAR="$BUILD/openlitespeed-${VERSION}.src.tgz"
PCRE2_TAR="$BUILD/pcre2-${PCRE2_VERSION}.tar.gz"
ZLIB_TAR="$BUILD/zlib-${ZLIB_VERSION}.tar.gz"
OPENSSL_TAR="$BUILD/openssl-${OPENSSL_VERSION}.tar.gz"

fetch "$OLS_URL" "$OLS_TAR"
fetch "$PCRE2_URL" "$PCRE2_TAR"
fetch "$ZLIB_URL" "$ZLIB_TAR"
fetch "$OPENSSL_URL" "$OPENSSL_TAR"

extract_once "$OLS_TAR" "$BUILD" "openlitespeed-${VERSION}"
extract_once "$PCRE2_TAR" "$BUILD" "pcre2-${PCRE2_VERSION}"
extract_once "$ZLIB_TAR" "$BUILD" "zlib-${ZLIB_VERSION}"
extract_once "$OPENSSL_TAR" "$BUILD" "openssl-${OPENSSL_VERSION}"

OLS_SRC="$BUILD/openlitespeed-${VERSION}"
PCRE2_SRC="$BUILD/pcre2-${PCRE2_VERSION}"
ZLIB_SRC="$BUILD/zlib-${ZLIB_VERSION}"
OPENSSL_SRC="$BUILD/openssl-${OPENSSL_VERSION}"

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

# --- 2. Build zlib standalone ---

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

# --- 3. Build OpenSSL standalone ---

if [ ! -f "$OPENSSL_PREFIX/lib/libssl.a" ]; then
    echo "==> building OpenSSL ${OPENSSL_VERSION}"
    cd "$OPENSSL_SRC"
    ./Configure "$OPENSSL_TARGET" \
        no-shared \
        no-tests \
        --prefix="$OPENSSL_PREFIX" \
        -mmacosx-version-min=11.0
    make -j"$JOBS"
    make install_sw
fi

# --- 4. Configure + build OpenLiteSpeed ---

echo "==> configuring OpenLiteSpeed ${VERSION}"
cd "$OLS_SRC"

# OLS configure accepts --with-pcre, --with-openssl, and --with-zlib pointing
# to the prefix where each library was installed (headers in include/, libs in lib/).
./configure \
    --prefix="$PREFIX_DUMMY" \
    --with-pcre="$PCRE2_PREFIX" \
    --with-openssl="$OPENSSL_PREFIX" \
    --with-zlib="$ZLIB_PREFIX" \
    CFLAGS="-O2 -arch $ARCH -mmacosx-version-min=11.0" \
    CXXFLAGS="-O2 -arch $ARCH -mmacosx-version-min=11.0" \
    LDFLAGS="-arch $ARCH -L$ZLIB_PREFIX/lib -L$OPENSSL_PREFIX/lib -L$PCRE2_PREFIX/lib"

echo "==> building OpenLiteSpeed"
make -j"$JOBS"

echo "==> installing to staging area"
make install DESTDIR="$BUILD/install"

# --- 5. Package into final layout ---

# OLS installs into DESTDIR + PREFIX + /lsws/ (the lsws subdirectory is
# hardcoded in OLS's build system). Locate the staged root.
STAGED="$BUILD/install${PREFIX_DUMMY}"
# If OLS added a /lsws/ subdirectory, use that instead
if [ -d "$STAGED/lsws" ]; then
    STAGED="$STAGED/lsws"
fi

echo "==> packaging"
rm -rf "$PKG_DIR"
mkdir -p "$PKG_DIR/sbin" "$PKG_DIR/bin" "$PKG_DIR/conf" "$PKG_DIR/fcgi-bin"

# Core daemon binary — OLS puts it in bin/ or sbin/ depending on version
if [ -f "$STAGED/bin/lshttpd" ]; then
    cp "$STAGED/bin/lshttpd" "$PKG_DIR/sbin/lshttpd"
elif [ -f "$STAGED/sbin/lshttpd" ]; then
    cp "$STAGED/sbin/lshttpd" "$PKG_DIR/sbin/lshttpd"
elif [ -f "$STAGED/bin/openlitespeed" ]; then
    cp "$STAGED/bin/openlitespeed" "$PKG_DIR/sbin/lshttpd"
else
    echo "ERROR: cannot find lshttpd binary in staged install" >&2
    find "$BUILD/install" -name "lshttpd" -o -name "openlitespeed" 2>/dev/null || true
    exit 1
fi

# Control script
if [ -f "$STAGED/bin/lswsctrl" ]; then
    cp "$STAGED/bin/lswsctrl" "$PKG_DIR/bin/lswsctrl"
fi

# Default config files
for f in httpd_config.conf mime.properties; do
    if [ -f "$STAGED/conf/$f" ]; then
        cp "$STAGED/conf/$f" "$PKG_DIR/conf/$f"
    fi
done

# Copy any additional conf files that exist
for f in "$STAGED/conf/"*; do
    [ -f "$f" ] && cp "$f" "$PKG_DIR/conf/" 2>/dev/null || true
done

# fcgi-bin templates if shipped
if [ -d "$STAGED/fcgi-bin" ]; then
    cp "$STAGED/fcgi-bin/"* "$PKG_DIR/fcgi-bin/" 2>/dev/null || true
fi

# Ensure sane permissions (OLS install.sh sometimes sets +s or restrictive modes)
chmod -R u+rw "$PKG_DIR"

# --- 6. Strip binaries ---

echo "==> stripping binaries"
strip -x "$PKG_DIR/sbin/lshttpd" || true
for bin in "$PKG_DIR/bin"/*; do
    [ -f "$bin" ] && strip -x "$bin" || true
done

# --- 7. README ---

cat > "$PKG_DIR/README.md" <<EOF
# OpenLiteSpeed $VERSION (built for Delify Forge)

Built with:
- PCRE2 $PCRE2_VERSION
- zlib $ZLIB_VERSION
- OpenSSL $OPENSSL_VERSION

Architecture: $TRIPLE
Build host: $(uname -mrs)
Build date (UTC): $(date -u +"%Y-%m-%dT%H:%M:%SZ")

Upstream sources:
- OpenLiteSpeed: $OLS_URL
- PCRE2:         $PCRE2_URL
- zlib:          $ZLIB_URL
- OpenSSL:       $OPENSSL_URL

Upstream license: OpenLiteSpeed Web Server is GPL-3.0.
Bundled deps under their respective licenses (PCRE2: BSD-3-Clause,
zlib: zlib license, OpenSSL: Apache-2.0).
EOF

# --- 8. Create archive + checksum ---

cd "$REPO_ROOT"
echo "==> creating $ARCHIVE"
tar -czf "$ARCHIVE" -C "$BUILD/pkg" "openlitespeed-${VERSION}"
( cd "$DIST" && shasum -a 256 "$(basename "$ARCHIVE")" > "$(basename "${ARCHIVE%.tar.gz}").sha256" )

echo "==> done"
echo "    archive: $ARCHIVE"
echo "    sha256:  $(cat "${ARCHIVE%.tar.gz}.sha256")"
