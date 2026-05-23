# forge-engines

Prebuilt engine binaries for [Delify Forge](https://github.com/Delify-Solutions/forge).

This repository builds standalone macOS binaries for the engines Forge orchestrates (nginx, dnsmasq, php, php-fpm) and publishes them as tar.gz releases. The Forge desktop app downloads the right archive for the user's machine on demand and unpacks it into `~/Library/Application Support/Forge/engines/<engine>/<version>/`.

## How it's organized

- `scripts/build-<engine>.sh` — reproducible build script for one engine. Takes the version as an argument, fetches upstream source, builds, packages.
- `.github/workflows/release.yml` — runs on tag pushes that match `<engine>-<version>` (e.g. `nginx-1.27.3`). Builds on a matrix of `macos-14` (arm64) + `macos-13` (x86_64) runners and creates a GitHub Release with both tarballs attached.

## Release artefact layout

Each tag produces archives named:

```
<engine>-<version>-darwin-arm64.tar.gz
<engine>-<version>-darwin-x64.tar.gz
```

Inside, the layout matches what Forge expects:

```
<engine>-<version>/
├── sbin/<binary>          # primary binary (e.g. sbin/nginx)
├── bin/<binary>            # for engines that ship in bin
├── conf/                   # optional default configs
└── README.md               # build provenance + version info
```

The Forge app's `bundle::catalog()` expects `bin_subpath` such as `sbin/nginx`; archives must match.

## Cutting a release

```bash
# Build locally for verification
./scripts/build-dnsmasq.sh 2.90

# Push a tag to trigger CI build for both architectures
git tag dnsmasq-2.90
git push origin dnsmasq-2.90
```

The workflow watches tag patterns `dnsmasq-*`, `nginx-*`, `php-*`, `php-fpm-*` and dispatches the matching script.

## Phase status

| Engine | Status | Notes |
|--------|--------|-------|
| dnsmasq | Phase A.1 | Tiny upstream, fast smoke test for the pipeline. |
| nginx | Phase A.1 | Built statically with bundled pcre2, zlib, openssl. |
| php | Phase A.2 | Will use [static-php-cli](https://github.com/crazywhalecc/static-php-cli). Multi-version pinning (8.2, 8.3, 8.4). |
| php-fpm | Phase A.2 | Same build as PHP — fpm SAPI is enabled in the static-php-cli profile. |

## License

Build scripts and workflow code: AGPL-3.0-or-later.

The upstream source code being built (nginx, dnsmasq, PHP, etc.) ships under its respective upstream license. See each release's `README.md` for the upstream license and source URL of that build.
