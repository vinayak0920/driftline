#!/bin/bash
# Builds Driftline.app with just the Xcode Command Line Tools (no Xcode project needed).
#   bash build.sh            build into ./build/Driftline.app
#   bash build.sh --install  build, copy to /Applications and launch
#   RELAY_URL=https://driftline-relay.you.workers.dev bash build.sh --install
#                            also bakes your Friends relay into the app, so a copy
#                            you send to a friend is already set up.
set -euo pipefail
cd "$(dirname "$0")"

APP="Driftline"
OUT="build"
BUNDLE="$OUT/${APP}.app"

command -v xcrun >/dev/null || { echo "Install the command line tools first: xcode-select --install"; exit 1; }
SDK="$(xcrun --sdk macosx --show-sdk-path)"

rm -rf "$OUT"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"

FLAGS=(-O -swift-version 5 -parse-as-library -sdk "$SDK"
       -framework AppKit -framework SwiftUI -framework SystemConfiguration
       -framework CoreWLAN -framework ServiceManagement -framework IOKit)

BINARIES=()
for ARCH in arm64 x86_64; do
  echo "> Compiling for ${ARCH}..."
  if xcrun swiftc "${FLAGS[@]}" -target "${ARCH}-apple-macos13.0" Sources/*.swift -o "$OUT/${APP}-${ARCH}"; then
    BINARIES+=("$OUT/${APP}-${ARCH}")
  else
    echo "  (skipped ${ARCH})"
  fi
done
[ ${#BINARIES[@]} -gt 0 ] || { echo "Build failed."; exit 1; }
lipo -create "${BINARIES[@]}" -output "$BUNDLE/Contents/MacOS/${APP}"
rm -f "${BINARIES[@]}"

cp Info.plist "$BUNDLE/Contents/Info.plist"
if [ -n "${VERSION:-}" ]; then
  plutil -replace CFBundleShortVersionString -string "$VERSION" "$BUNDLE/Contents/Info.plist"
  echo "> Version: $VERSION"
fi
if [ -n "${RELAY_URL:-}" ]; then
  plutil -replace DriftlineRelayURL -string "$RELAY_URL" "$BUNDLE/Contents/Info.plist"
  echo "> Relay baked in: $RELAY_URL"
fi

if [ -f Resources/AppIcon.png ]; then
  echo "> Building icon..."
  ICONSET="$OUT/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for SIZE in 16 32 128 256 512; do
    sips -z $SIZE $SIZE Resources/AppIcon.png --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
    sips -z $((SIZE*2)) $((SIZE*2)) Resources/AppIcon.png --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$BUNDLE/Contents/Resources/AppIcon.icns"
  rm -rf "$ICONSET"
fi

echo "> Signing (ad-hoc)..."
codesign --force --deep --sign - "$BUNDLE"

echo "OK: Built $BUNDLE"
( cd "$OUT" && ditto -c -k --keepParent "${APP}.app" "${APP}.zip" )
echo "OK: Shareable copy: $OUT/${APP}.zip (send this to a friend)"

if [ "${1:-}" = "--install" ]; then
  pkill -x "${APP}" 2>/dev/null || true
  rm -rf "/Applications/${APP}.app"
  cp -R "$BUNDLE" /Applications/
  open "/Applications/${APP}.app"
  echo "OK: Installed to /Applications and launched. Look at your menu bar."
fi
