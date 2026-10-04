#!/bin/zsh
# Builds "Hourglass.app" into ./build. Usage: scripts/build-app.sh [--install]
#   --install  also copies it to /Applications and (re)launches it.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Hourglass"
APP="build/${APP_NAME}.app"

echo "→ Building release binaries"
swift build -c release --product Hourglass
swift build -c release --product hourglass-bridge
BIN="$(swift build -c release --show-bin-path)"

echo "→ Assembling ${APP}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp "$BIN/Hourglass" "$APP/Contents/MacOS/Hourglass"
cp "$BIN/hourglass-bridge" "$APP/Contents/MacOS/hourglass-bridge"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "→ Signing (ad hoc, for this Mac)"
codesign --force --sign - --timestamp=none "$APP/Contents/MacOS/hourglass-bridge"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict "$APP"

if [[ "${1:-}" == "--install" ]]; then
  DEST="/Applications/${APP_NAME}.app"
  echo "→ Installing to ${DEST}"
  pkill -x Hourglass 2>/dev/null && sleep 0.5 || true
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  open "$DEST"
fi
echo "✓ Done: $APP"
