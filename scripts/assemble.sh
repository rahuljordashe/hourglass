#!/bin/zsh
# Assembles build/Hourglass.app from release binaries without installing it.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product Hourglass
swift build -c release --product hourglass-bridge
BIN="$(swift build -c release --show-bin-path)"
APP="build/Hourglass.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp "$BIN/Hourglass" "$BIN/hourglass-bridge" "$APP/Contents/MacOS/"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - --timestamp=none "$APP/Contents/MacOS/hourglass-bridge"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict "$APP"
echo "✓ $APP"
