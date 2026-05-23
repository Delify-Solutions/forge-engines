#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Build nginx for macOS as a self-contained tarball, with PCRE2, zlib, and
# OpenSSL linked statically into the binary so the user doesn't need any
# Homebrew presence.
#
# Usage: scripts/build-nginx.sh <version>
#
# Output:
#   dist/nginx-<version>-darwin-<arch>.tar.gz
#   dist/nginx-<version>-darwin-<arch>.sha256
#
# Archive layout:
#   nginx-<version>/
#     sbin/nginx
#     conf/                # mime.types + fastcgi_params (defaults from upstream)
#     README.md

set -euo pipefail

VERSION="${1:?usage: build-nginx.sh <version>}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$REPO_ROOT/build/nginx-$VERSION"
DIST="$REPO_ROOT/dist"
ARCH="$(uname -m)"
case "$ARCH" in
    arm64)  TRIPLE="darwin-arm64" ;;
    x86_64) TRIPLE="darwin-x64" ;;
    *) echo "unsupported arch: $ARCH" >&2; exit 1 ;;
esac

# Pin dependency versions per nginx release. Bumping any of these requires a
# new nginx tag (e.g. nginx-1.27.3-r2) so installs remain reproducible.
PCRE2_VERSION="10.44"
ZLIB_VERSION="1.3.1"
OPENSSL_VERSION="3.3.2"

NGINX_URL="https://nginx.org/download/nginx-${VERSION}.tar.gz"
PCRE2_URL="https://github.com/PCRE2Project/pcre2/releases/download/pcre2-${PCRE2_VERSION}/pcre2-${PCRE2_VERSION}.tar.gz"
ZLIB_URL="https://zlib.net/fossils/zlib-${ZLIB_VERSION}.tar.gz"
OPENSSL_URL="https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz"

PKG_DIR="$BUILD/pkg/nginx-${VERSION}"
ARCHIVE="$DIST/nginx-${VERSION}-${TRIPLE}.tar.gz"

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

NGINX_TAR="$BUILD/nginx-${VERSION}.tar.gz"
PCRE2_TAR="$BUILD/pcre2-${PCRE2_VERSION}.tar.gz"
ZLIB_TAR="$BUILD/zlib-${ZLIB_VERSION}.tar.gz"
OPENSSL_TAR="$BUILD/openssl-${OPENSSL_VERSION}.tar.gz"

fetch "$NGINX_URL" "$NGINX_TAR"
fetch "$PCRE2_URL" "$PCRE2_TAR"
fetch "$ZLIB_URL" "$ZLIB_TAR"
fetch "$OPENSSL_URL" "$OPENSSL_TAR"

extract_once "$NGINX_TAR" "$BUILD" "nginx-${VERSION}"
extract_once "$PCRE2_TAR" "$BUILD" "pcre2-${PCRE2_VERSION}"
extract_once "$ZLIB_TAR" "$BUILD" "zlib-${ZLIB_VERSION}"
extract_once "$OPENSSL_TAR" "$BUILD" "openssl-${OPENSSL_VERSION}"

NGINX_SRC="$BUILD/nginx-${VERSION}"
PCRE2_SRC="$BUILD/pcre2-${PCRE2_VERSION}"
ZLIB_SRC="$BUILD/zlib-${ZLIB_VERSION}"
OPENSSL_SRC="$BUILD/openssl-${OPENSSL_VERSION}"

PREFIX_DUMMY="/usr/local/forge/nginx"  # rewritten at runtime via -p flag
JOBS="$(sysctl -n hw.ncpu)"

echo "==> configuring nginx (deps inline)"
cd "$NGINX_SRC"

# `--with-pcre=<dir>` etc. tell nginx's configure to build the dependency
# in-tree against the supplied source tree. The resulting nginx binary has
# everything statically linked.
./configure \
    --prefix="$PREFIX_DUMMY" \
    --sbin-path=sbin/nginx \
    --conf-path=conf/nginx.conf \
    --error-log-path=logs/error.log \
    --http-log-path=logs/access.log \
    --pid-path=logs/nginx.pid \
    --lock-path=logs/nginx.lock \
    --http-client-body-temp-path=tmp/client_body \
    --http-proxy-temp-path=tmp/proxy \
    --http-fastcgi-temp-path=tmp/fastcgi \
    --http-uwsgi-temp-path=tmp/uwsgi \
    --http-scgi-temp-path=tmp/scgi \
    --with-pcre="$PCRE2_SRC" \
    --with-pcre-jit \
    --with-zlib="$ZLIB_SRC" \
    --with-openssl="$OPENSSL_SRC" \
    --with-openssl-opt="no-shared no-tests" \
    --with-http_ssl_module \
    --with-http_v2_module \
    --with-http_realip_module \
    --with-http_gzip_static_module \
    --with-http_stub_status_module \
    --with-cc-opt="-O2 -arch $ARCH -mmacosx-version-min=11.0" \
    --with-ld-opt="-arch $ARCH"

echo "==> building"
make -j"$JOBS"

echo "==> packaging"
rm -rf "$PKG_DIR"
mkdir -p "$PKG_DIR/sbin" "$PKG_DIR/conf"
cp "$NGINX_SRC/objs/nginx" "$PKG_DIR/sbin/nginx"
strip -x "$PKG_DIR/sbin/nginx"

# Ship upstream defaults so a fresh install has working mime types and
# fastcgi_params. The Forge app generates its own nginx.conf, but reads
# these support files via include directives.
cp "$NGINX_SRC/conf/mime.types" "$PKG_DIR/conf/mime.types"
cp "$NGINX_SRC/conf/fastcgi_params" "$PKG_DIR/conf/fastcgi_params"
cp "$NGINX_SRC/conf/scgi_params" "$PKG_DIR/conf/scgi_params" 2>/dev/null || true
cp "$NGINX_SRC/conf/uwsgi_params" "$PKG_DIR/conf/uwsgi_params" 2>/dev/null || true

cat > "$PKG_DIR/README.md" <<EOF
# nginx $VERSION (built for Delify Forge)

Built statically with:
- PCRE2 $PCRE2_VERSION
- zlib  $ZLIB_VERSION
- OpenSSL $OPENSSL_VERSION

Architecture: $TRIPLE
Build host: $(uname -mrs)
Build date (UTC): $(date -u +"%Y-%m-%dT%H:%M:%SZ")

Upstream sources:
- nginx:   $NGINX_URL
- PCRE2:   $PCRE2_URL
- zlib:    $ZLIB_URL
- OpenSSL: $OPENSSL_URL

Upstream license: nginx is BSD-2-Clause; bundled deps under their
respective licenses.
EOF

cd "$REPO_ROOT"
echo "==> creating $ARCHIVE"
tar -czf "$ARCHIVE" -C "$BUILD/pkg" "nginx-${VERSION}"
shasum -a 256 "$ARCHIVE" > "${ARCHIVE%.tar.gz}.sha256"

echo "==> done"
echo "    archive: $ARCHIVE"
echo "    sha256:  $(cat "${ARCHIVE%.tar.gz}.sha256")"
