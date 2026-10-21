#!/bin/bash
# Builds build/Sunscreen.dmg (Apple Silicon + Intel). Needs only Apple's
# Command Line Tools.
#   ./build.sh            build the dmg
#   ./build.sh --install  also replace /Applications/Sunscreen.app and relaunch it
# The .app is assembled in a temp folder and never left on disk, so macOS
# doesn't list stray copies in Spotlight/Launchpad.
# Signing: ad-hoc by default. With an Apple Developer ID, set
# SIGN_IDENTITY="Developer ID Application: ..." and notarize the dmg afterwards
# so friends get no Gatekeeper warning.
set -euo pipefail
cd "$(dirname "$0")"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
WORK="$(mktemp -d "${TMPDIR:-/tmp}/sunscreen-build.XXXXXX")"
APP="$WORK/Sunscreen.app"
cleanup() { "$LSREGISTER" -u "$APP" "$WORK/dmg/Sunscreen.app" 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT
mkdir -p build "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> Compiling"
for arch in arm64 x86_64; do
  swiftc -O -target "$arch-apple-macos13" Sources/*.swift -o "$WORK/Sunscreen-$arch"
done
lipo -create "$WORK/Sunscreen-arm64" "$WORK/Sunscreen-x86_64" -output "$APP/Contents/MacOS/Sunscreen"
cp Info.plist "$APP/Contents/Info.plist"
cp docs/changelog.json "$APP/Contents/Resources/changelog.json"  # for "What's new" after an update

echo "==> Icon"
swiftc -O Tools/make_icon.swift -o "$WORK/make_icon"
"$WORK/make_icon" "$WORK/icon_1024.png"
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$WORK/icon_1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) "$WORK/icon_1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

echo "==> Signing"
xattr -cr "$APP"  # Finder/iCloud metadata breaks codesign
codesign --force --options runtime --sign "${SIGN_IDENTITY:--}" "$APP" 2>&1 | grep -v "replacing existing" || true

echo "==> Disk image"
mkdir -p "$WORK/dmg"
cp -R "$APP" "$WORK/dmg/"
cp "Read me first.txt" "$WORK/dmg/"
ln -s /Applications "$WORK/dmg/Applications"
hdiutil create -volname Sunscreen -srcfolder "$WORK/dmg" -ov -format UDZO build/Sunscreen.dmg 2>&1 >/dev/null | grep -v deprecated || true
rm -f build/Sunscreen.zip
ditto -c -k --keepParent "$APP" build/Sunscreen.zip  # used by docs/install.sh
echo "Built build/Sunscreen.dmg and build/Sunscreen.zip"

if [[ "${1:-}" == "--install" ]]; then
  echo "==> Installing to /Applications"
  osascript -e 'quit app "Sunscreen"' 2>/dev/null || true
  # The app fades the colours back before it quits; wait until it's really gone.
  for _ in $(seq 1 50); do pgrep -f "Sunscreen.app/Contents/MacOS/Sunscreen" >/dev/null || break; sleep 0.2; done
  rm -rf /Applications/Sunscreen.app
  cp -R "$APP" /Applications/
  open /Applications/Sunscreen.app
  echo "Installed and relaunched"
fi
