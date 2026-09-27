#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
VERSION="${VERSION#v}"
ARCH_LABEL="${ARCH_LABEL:-$(uname -m)}"
PACKAGE="luma-v${VERSION}-linux-${ARCH_LABEL}"

zig build -Doptimize=ReleaseSafe
rm -rf "dist/$PACKAGE"
mkdir -p "dist/$PACKAGE"
cp zig-out/bin/luma "dist/$PACKAGE/luma"
cp README.md "dist/$PACKAGE/README.md"
cp vendor/webview/LICENSE "dist/$PACKAGE/WEBVIEW-LICENSE"
tar -C dist -czf "dist/$PACKAGE.tar.gz" "$PACKAGE"
printf 'Created dist/%s.tar.gz\n' "$PACKAGE"
