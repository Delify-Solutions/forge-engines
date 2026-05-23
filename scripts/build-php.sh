#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Build PHP (CLI + FPM) for macOS as a self-contained tarball using
# static-php-cli. The single archive ships both binaries:
#
#   php-<version>/
#     bin/php           (CLI)
#     sbin/php-fpm      (FPM)
#     README.md
#
# Usage: scripts/build-php.sh <version>

set -euo pipefail

VERSION="${1:?usage: build-php.sh <version>}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$REPO_ROOT/build/php-$VERSION"
DIST="$REPO_ROOT/dist"
ARCH="$(uname -m)"
case "$ARCH" in
    arm64)  TRIPLE="darwin-arm64";  SPC_ARCH="aarch64" ;;
    x86_64) TRIPLE="darwin-x64";    SPC_ARCH="x86_64" ;;
    *) echo "unsupported arch: $ARCH" >&2; exit 1 ;;
esac

# Pin static-php-cli to a stable release. Bumping requires a new
# php-<ver>-r<n> tag so installs remain reproducible.
SPC_VERSION="2.8.5"
SPC_URL="https://github.com/crazywhalecc/static-php-cli/releases/download/${SPC_VERSION}/spc-macos-${SPC_ARCH}.tar.gz"

# Php-version targeted by craft.yml. We mirror a Laravel/Symfony-friendly
# baseline; users can opt into more later via project-level php.ini.
EXTENSIONS="bcmath,bz2,calendar,ctype,curl,dba,dom,exif,fileinfo,filter,gd,gmp,iconv,intl,mbstring,mbregex,mysqli,mysqlnd,opcache,openssl,pcntl,pdo,pdo_mysql,pdo_pgsql,pdo_sqlite,pgsql,phar,posix,readline,session,shmop,simplexml,soap,sockets,sodium,sqlite3,sysvmsg,sysvsem,sysvshm,tokenizer,xml,xmlreader,xmlwriter,zip,zlib"

PKG_DIR="$BUILD/pkg/php-${VERSION}"
ARCHIVE="$DIST/php-${VERSION}-${TRIPLE}.tar.gz"

mkdir -p "$BUILD" "$DIST"

if [ ! -x "$BUILD/spc" ]; then
    echo "==> downloading static-php-cli ${SPC_VERSION} (${SPC_ARCH})"
    curl -fsSL --retry 5 -o "$BUILD/spc.tar.gz" "$SPC_URL"
    tar -xzf "$BUILD/spc.tar.gz" -C "$BUILD"
    rm -f "$BUILD/spc.tar.gz"
    chmod +x "$BUILD/spc"
fi

cd "$BUILD"

# CI runners (macos-14) ship Homebrew already; install the toolchain spc
# expects once, up-front, instead of relying on `spc doctor --auto-fix`
# which fetches binaries that occasionally 404 on a flaky network.
echo "==> brew prerequisites"
brew install pkg-config automake autoconf libtool re2c bison flex || true

# Declarative craft.yml — see https://static-php.dev for the schema.
cat > "$BUILD/craft.yml" <<EOF
php-version: $VERSION
extensions: "$EXTENSIONS"
sapi:
  - cli
  - fpm
download-options:
  retry: 5
  prefer-pre-built: false
EOF

echo "==> craft.yml:"
cat "$BUILD/craft.yml"

echo "==> spc craft"
./spc craft --debug

echo "==> packaging"
rm -rf "$PKG_DIR"
mkdir -p "$PKG_DIR/bin" "$PKG_DIR/sbin"

if [ ! -f "$BUILD/buildroot/bin/php" ]; then
    echo "FATAL: expected $BUILD/buildroot/bin/php after build" >&2
    ls -la "$BUILD/buildroot/bin" 2>&1 || true
    exit 1
fi

cp "$BUILD/buildroot/bin/php" "$PKG_DIR/bin/php"
if [ -f "$BUILD/buildroot/bin/php-fpm" ]; then
    cp "$BUILD/buildroot/bin/php-fpm" "$PKG_DIR/sbin/php-fpm"
elif [ -f "$BUILD/buildroot/sbin/php-fpm" ]; then
    cp "$BUILD/buildroot/sbin/php-fpm" "$PKG_DIR/sbin/php-fpm"
else
    echo "FATAL: php-fpm binary not found in buildroot" >&2
    find "$BUILD/buildroot" -name 'php-fpm' >&2 || true
    exit 1
fi
strip -x "$PKG_DIR/bin/php" "$PKG_DIR/sbin/php-fpm" 2>/dev/null || true

cat > "$PKG_DIR/README.md" <<EOF
# PHP $VERSION (built for Delify Forge)

Built with [static-php-cli](https://github.com/crazywhalecc/static-php-cli)
$SPC_VERSION, producing fully static binaries that have no external
dependencies beyond libSystem.

Architecture: $TRIPLE
Build host: $(uname -mrs)
Build date (UTC): $(date -u +"%Y-%m-%dT%H:%M:%SZ")

## Bundled extensions

$EXTENSIONS

## Layout

- \`bin/php\` — CLI SAPI
- \`sbin/php-fpm\` — FPM SAPI

## License

PHP itself: PHP License v3.01.
Build tooling (static-php-cli): MIT.
Bundled libraries: respective upstream licenses (see static-php-cli source).
EOF

cd "$REPO_ROOT"
echo "==> creating $ARCHIVE"
tar -czf "$ARCHIVE" -C "$BUILD/pkg" "php-${VERSION}"
( cd "$DIST" && shasum -a 256 "$(basename "$ARCHIVE")" > "$(basename "${ARCHIVE%.tar.gz}").sha256" )

echo "==> done"
echo "    archive: $ARCHIVE"
echo "    sha256:  $(cat "${ARCHIVE%.tar.gz}.sha256")"
