#!/bin/zsh
# Builds Snapmark.app (universal: Apple silicon + Intel).
# Usage:
#   ./build.sh                  builds build/Snapmark.app
#   ./build.sh --run [image]    builds and runs without installing (with an image, opens it in the editor)
#   ./build.sh --install        builds and installs to /Applications
set -e
cd "$(dirname "$0")"

VERSION="${SNAPMARK_VERSION:-$(cat VERSION)}"
APP=build/Snapmark.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/obj
cp Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION%%-*}" "$APP/Contents/Info.plist"
# Build: commit count + short hash ("-dirty" when there are uncommitted changes)
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 0)"
COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo local)"
[[ -n "$(git status --porcelain 2>/dev/null)" ]] && COMMIT="$COMMIT-dirty"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :SnapmarkVersion string $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :SnapmarkCommit string $COMMIT" "$APP/Contents/Info.plist"

# Icons: app .icns (from the 1024 PNG) and the menu bar icon
ICONSET=build/obj/AppIcon.iconset
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
for SZ in 16 32 128 256 512; do
  sips -z $SZ $SZ assets/AppIcon-1024.png --out "$ICONSET/icon_${SZ}x${SZ}.png" >/dev/null
  sips -z $((SZ*2)) $((SZ*2)) assets/AppIcon-1024.png --out "$ICONSET/icon_${SZ}x${SZ}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
cp assets/MenuBarIcon.png assets/MenuBarIcon@2x.png "$APP/Contents/Resources/"

for ARCH in arm64 x86_64; do
  swiftc -O -swift-version 5 -target "$ARCH-apple-macos13.0" \
    -o "build/obj/Snapmark-$ARCH" Sources/*.swift \
    -framework Cocoa -framework Carbon -framework ServiceManagement
done
lipo -create build/obj/Snapmark-arm64 build/obj/Snapmark-x86_64 -output "$APP/Contents/MacOS/Snapmark"

# Signing: uses the local "Snapmark Dev" certificate if present (create it with ./scripts/create-dev-cert.sh).
# With it, the Screen Recording permission survives rebuilds.
# Without it, the build is signed ad-hoc and macOS may ask for the permission again on each build.
IDENTITY="${SNAPMARK_SIGN_IDENTITY:-Snapmark Dev}"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
  codesign --force -s "$IDENTITY" "$APP"
  echo "Signed with: $IDENTITY"
else
  codesign --force -s - "$APP"
  echo "Note: certificate \"$IDENTITY\" not found; signing ad-hoc."
fi
echo "OK: $APP ($VERSION, build $BUILD_NUMBER, $COMMIT)"

if [[ "$1" == "--run" ]]; then
  pkill -x Snapmark 2>/dev/null || true
  sleep 0.3
  if [[ -n "$2" ]]; then
    "$APP/Contents/MacOS/Snapmark" --edit "$(cd "$(dirname "$2")" && pwd)/$(basename "$2")" &
  else
    open "$APP"
  fi
fi
if [[ "$1" == "--install" ]]; then
  pkill -x Snapmark 2>/dev/null || true
  rm -rf /Applications/Snapmark.app
  cp -R "$APP" /Applications/
  open /Applications/Snapmark.app
  echo "Installed to /Applications/Snapmark.app"
fi
