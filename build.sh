#!/bin/zsh
# Compila o Snapmark.app (universal: Apple Silicon + Intel).
# Uso:
#   ./build.sh                  compila em build/Snapmark.app
#   ./build.sh --run [imagem]   compila e roda sem instalar (com imagem, abre direto no editor)
#   ./build.sh --install        compila e instala em /Applications
set -e
cd "$(dirname "$0")"

VERSION="${SNAPMARK_VERSION:-$(cat VERSION)}"
APP=build/Snapmark.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/obj
cp Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION%%-*}" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"

for ARCH in arm64 x86_64; do
  swiftc -O -swift-version 5 -target "$ARCH-apple-macos13.0" \
    -o "build/obj/Snapmark-$ARCH" Sources/main.swift \
    -framework Cocoa -framework Carbon -framework ServiceManagement
done
lipo -create build/obj/Snapmark-arm64 build/obj/Snapmark-x86_64 -output "$APP/Contents/MacOS/Snapmark"

codesign --force -s - "$APP"
echo "OK: $APP ($VERSION)"

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
  echo "Instalado em /Applications/Snapmark.app"
fi
