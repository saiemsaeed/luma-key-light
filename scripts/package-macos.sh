#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
VERSION="${VERSION#v}"
TARGET="${TARGET:-}"
ARCH_LABEL="${ARCH_LABEL:-$(uname -m)}"
if [ -z "${SDKROOT:-}" ]; then
  SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
  export SDKROOT
fi

if [ -n "$TARGET" ]; then
  zig build -Doptimize=ReleaseSafe -Dtarget="$TARGET"
else
  zig build -Doptimize=ReleaseSafe
fi

APP="dist/Luma.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp zig-out/bin/luma "$APP/Contents/MacOS/Luma"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleDisplayName</key><string>Luma</string>
  <key>CFBundleExecutable</key><string>Luma</string>
  <key>CFBundleIdentifier</key><string>dev.luma.keylight</string>
  <key>CFBundleName</key><string>Luma</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>${GITHUB_RUN_NUMBER:-1}</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSLocalNetworkUsageDescription</key><string>Luma connects directly to your Elgato Key Light.</string>
</dict></plist>
PLIST
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

ARCHIVE="dist/luma-v${VERSION}-macos-${ARCH_LABEL}.zip"
rm -f "$ARCHIVE"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"
printf 'Created %s\n' "$ARCHIVE"
