#!/bin/bash
# Builds build/TinyPrinter.app and the tinyprint CLI.
# Usage: scripts/build-app.sh [--install]   (--install copies the app to /Applications and the CLI to ~/.local/bin)
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product TinyPrinter
swift build -c release --product tinyprint
BIN="$(swift build -c release --show-bin-path)"

APP="build/TinyPrinter.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/TinyPrinter" "$APP/Contents/MacOS/TinyPrinter"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp "$BIN/tinyprint" build/tinyprint

# A stable signing identity keeps the Bluetooth permission across rebuilds.
# Set SIGN_IDENTITY to override; falls back to ad-hoc signing.
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')}"
if [ -n "$IDENTITY" ]; then
  codesign --force --options runtime --timestamp=none -s "$IDENTITY" "$APP"
else
  echo "warning: no signing identity, using ad-hoc (macOS may ask for Bluetooth access after every rebuild)"
  codesign --force -s - "$APP"
fi
codesign --force -s "${IDENTITY:--}" build/tinyprint 2>/dev/null || true
echo "Built $APP"

if [ "${1:-}" = "--install" ]; then
  osascript -e 'quit app "Tiny Printer"' 2>/dev/null || true
  sleep 1
  rm -rf "/Applications/TinyPrinter.app"
  cp -R "$APP" /Applications/
  mkdir -p "$HOME/.local/bin"
  cp build/tinyprint "$HOME/.local/bin/tinyprint"
  echo "Installed /Applications/TinyPrinter.app and ~/.local/bin/tinyprint"
  open /Applications/TinyPrinter.app
fi
