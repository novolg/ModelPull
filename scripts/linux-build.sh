#!/bin/sh
# Build + test the Linux version inside Docker (Ubuntu 24.04, Swift 6.0), then package dist/modelpull-linux-<arch>.tar.gz.
# Usage: scripts/linux-build.sh [amd64|arm64]
set -eu
cd "$(dirname "$0")/.."
ARCH=${1:-amd64}
IMAGE=swift:6.0-noble  # 5.10 Linux URLSession: first request of every new session hangs until timeout
OUT=dist/modelpull-linux-$ARCH

mkdir -p dist
docker run --rm --platform "linux/$ARCH" -v "$PWD":/src -w /src "$IMAGE" sh -euc "
  S=/tmp/build
  command -v curl >/dev/null || { apt-get update -qq && apt-get install -y -qq curl procps >/dev/null; }  # smoke test only
  swift build -c release --product ModelPullWeb --static-swift-stdlib --scratch-path \$S
  swift build --product DLChecks --scratch-path \$S
  echo '=== core checks'; \$S/debug/DLChecks
  echo '=== web smoke'; scripts/web-smoke.sh \$S/release/ModelPullWeb
  echo '=== real-file integrity'; scripts/verify-real.sh \$S/debug/DLChecks
  echo '=== shared libraries'; ldd \$S/release/ModelPullWeb
  mkdir -p $OUT && cp \$S/release/ModelPullWeb $OUT/modelpull && strip $OUT/modelpull
"
[ -f build/icons/linux-256.png ] || swift scripts/make-icons.swift resources/modelpull-logo.png   # AppKit: runs on the Mac host
cp packaging/linux/install.sh packaging/linux/README.txt "$OUT/"
cp build/icons/linux-256.png "$OUT/modelpull.png"
chmod +x "$OUT/install.sh" "$OUT/modelpull"
# Explicit file list: leftovers from older builds in $OUT never get shipped.
P="modelpull-linux-$ARCH"
COPYFILE_DISABLE=1 tar --no-xattrs --no-mac-metadata -C dist -czf "$OUT.tar.gz" "$P/install.sh" "$P/modelpull" "$P/modelpull.png" "$P/README.txt"
echo "Packaged $OUT.tar.gz"
