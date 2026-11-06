#!/bin/zsh
# Builds a real LocalSummary.app (needed for the microphone permission prompt).
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product LocalSummaryApp
BIN=$(swift build -c release --show-bin-path)
APP=build/LocalSummary.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/LocalSummaryApp" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
# SwiftPM resource bundles (if any dependency ships them)
for b in "$BIN"/*.bundle(N); do cp -R "$b" "$APP/Contents/Resources/"; done
codesign --force --deep --sign - "$APP"
echo "Built $PWD/$APP"
echo "Run: open $APP"
