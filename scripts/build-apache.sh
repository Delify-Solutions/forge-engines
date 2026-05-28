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

HTTPD_URL="https://downloads.apache.org/httpd/httpd-${VERSION}.tar.gz"
HTTPD_URL_FALLBACK="https://archive.apache.org/dist/httpd/httpd-${VERSION}.tar.gz"
APR_URL="https://downloads.apache.org/apr/apr-${APR_VERSION}.tar.gz"
APR_URL_FALLBACK="https://archive.apache.org/dist/apr/apr-${APR_VERSION}.tar.gz"
APR_UTIL_URL="https://downloads.apache.org/apr/apr-util-${APR_UTIL_VERSION}.tar.gz"
APR_UTIL_URL_FALLBACK="https://archive.apache.org/dist/apr/apr-util-${APR_UTIL_VERSION}.tar.gz"
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
    local url="$1" out="$2" fallback="${3:-}"
    if [ ! -f "$out" ]; then
        echo "==> fetching $url"
        if ! curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors --connect-timeout 30 --max-time 600 -o "$out" "$url"; then
            if [ -n "$fallback" ]; then
                echo "==> primary failed, fetching fallback $fallback"
                curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors --connect-timeout 30 --max-time 600 -o "$out" "$fallback"
            else
                return 1
            fi
        fi
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

fetch "$HTTPD_URL" "$HTTPD_TAR" "$HTTPD_URL_FALLBACK"
fetch "$APR_URL" "$APR_TAR" "$APR_URL_FALLBACK"
fetch "$APR_UTIL_URL" "$APR_UTIL_TAR" "$APR_UTIL_URL_FALLBACK"
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

# Bundled shared libraries (APR + APR-util built via --with-included-apr).
# httpd's compiled-in install names point at $PREFIX_DUMMY/lib/, which doesn't
# exist on user machines — we copy them in and rewrite the names below.
mkdir -p "$PKG_DIR/lib"
if [ -d "$STAGED/lib" ]; then
    cp -RP "$STAGED/lib"/libapr-*.dylib    "$PKG_DIR/lib/" 2>/dev/null || true
    cp -RP "$STAGED/lib"/libaprutil-*.dylib "$PKG_DIR/lib/" 2>/dev/null || true
fi

# Default config files (Forge generates its own httpd.conf but these are
# useful as reference and for include directives)
cp "$STAGED/conf/httpd.conf" "$PKG_DIR/conf/httpd.conf" 2>/dev/null || true
cp "$STAGED/conf/mime.types" "$PKG_DIR/conf/mime.types" 2>/dev/null || true
cp "$STAGED/conf/magic" "$PKG_DIR/conf/magic" 2>/dev/null || true
cp "$STAGED/conf/extra/httpd-default.conf" "$PKG_DIR/conf/httpd-default.conf" 2>/dev/null || true

# --- 5. Rewrite install names so the bundle is relocatable ---
#
# httpd was configured with --prefix=$PREFIX_DUMMY, so every Mach-O object
# encodes absolute paths like $PREFIX_DUMMY/lib/libapr-1.0.dylib. Rewrite to
# @rpath and add @loader_path/../lib so dyld resolves from inside the bundle.

echo "==> rewriting install names"

# Each dylib in lib/: set its own ID, then rewrite cross-lib references.
for dylib in "$PKG_DIR/lib"/*.dylib; do
    [ -L "$dylib" ] && continue
    [ ! -f "$dylib" ] && continue
    base="$(basename "$dylib")"
    install_name_tool -id "@rpath/$base" "$dylib"
    while IFS= read -r dep; do
        case "$dep" in
            "$PREFIX_DUMMY/lib/"*)
                dep_base="$(basename "$dep")"
                install_name_tool -change "$dep" "@rpath/$dep_base" "$dylib"
                ;;
        esac
    done < <(otool -L "$dylib" | awk 'NR > 1 {print $1}')
done

rewrite_macho() {
    local target="$1"
    [ ! -f "$target" ] && return 0
    while IFS= read -r dep; do
        case "$dep" in
            "$PREFIX_DUMMY/lib/"*)
                dep_base="$(basename "$dep")"
                install_name_tool -change "$dep" "@rpath/$dep_base" "$target"
                ;;
        esac
    done < <(otool -L "$target" | awk 'NR > 1 {print $1}')
    install_name_tool -add_rpath "@loader_path/../lib" "$target" 2>/dev/null || true
}

rewrite_macho "$PKG_DIR/sbin/httpd"
for bin in "$PKG_DIR/bin"/*; do
    [ -f "$bin" ] && rewrite_macho "$bin"
done
for mod in "$PKG_DIR/modules"/*.so; do
    [ -f "$mod" ] && rewrite_macho "$mod"
done

# --- 6. Strip binaries (after rewrite — install_name_tool invalidates the
#     previous strip's signature/checksums) ---

echo "==> stripping binaries"
strip -x "$PKG_DIR/sbin/httpd" || true
for bin in "$PKG_DIR/bin"/*; do
    [ -f "$bin" ] && strip -x "$bin" || true
done
for mod in "$PKG_DIR/modules"/*.so; do
    [ -f "$mod" ] && strip -x "$mod" || true
done
for dylib in "$PKG_DIR/lib"/*.dylib; do
    [ -L "$dylib" ] && continue
    [ -f "$dylib" ] && strip -x "$dylib" || true
done

# --- 6b. Smoke test: every dependency must resolve from inside the bundle
#     or from system paths. A leftover $PREFIX_DUMMY reference means the
#     install-name rewrite missed something — fail the build now rather than
#     ship a broken tarball. ---

echo "==> smoke-testing bundle relocatability"
SMOKE_FAIL=0
for target in "$PKG_DIR/sbin/httpd" "$PKG_DIR/bin"/* "$PKG_DIR/modules"/*.so "$PKG_DIR/lib"/*.dylib; do
    [ -L "$target" ] && continue
    [ ! -f "$target" ] && continue
    if otool -L "$target" 2>/dev/null | awk 'NR > 1 {print $1}' | grep -q "^$PREFIX_DUMMY"; then
        echo "  FAIL: $target still references $PREFIX_DUMMY" >&2
        otool -L "$target" >&2
        SMOKE_FAIL=1
    fi
done
if [ "$SMOKE_FAIL" -ne 0 ]; then
    echo "==> bundle has unresolved compile-time paths; aborting" >&2
    exit 1
fi

if ! "$PKG_DIR/sbin/httpd" -v >/dev/null 2>&1; then
    echo "==> httpd -v failed to run from packaged tree" >&2
    "$PKG_DIR/sbin/httpd" -v
    exit 1
fi

# --- 7. README ---

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

# --- 8. Create archive + checksum ---

cd "$REPO_ROOT"
echo "==> creating $ARCHIVE"
tar -czf "$ARCHIVE" -C "$BUILD/pkg" "apache-${VERSION}"
( cd "$DIST" && shasum -a 256 "$(basename "$ARCHIVE")" > "$(basename "${ARCHIVE%.tar.gz}").sha256" )

echo "==> done"
echo "    archive: $ARCHIVE"
echo "    sha256:  $(cat "${ARCHIVE%.tar.gz}.sha256")"
