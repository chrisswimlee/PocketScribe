#!/bin/zsh
# Builds a real PocketPad.app (needed for the microphone permission prompt).
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product PocketPadApp
BIN=$(swift build -c release --show-bin-path)
APP=build/PocketPad.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/PocketPadApp" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
# SwiftPM resource bundles (if any dependency ships them)
for b in "$BIN"/*.bundle(N); do cp -R "$b" "$APP/Contents/Resources/"; done
cp Resources/PrivacyInfo.xcprivacy "$APP/Contents/Resources/"
# SANDBOX=1 ./scripts/make-app.sh signs with the App Store sandbox entitlements.
# Note: a sandboxed build keeps its data in ~/Library/Containers/dev.chrisswimlee.PocketPad.
if [[ "${SANDBOX:-0}" == "1" ]]; then
  codesign --force --deep --sign - --entitlements Resources/PocketPad.entitlements "$APP"
else
  codesign --force --deep --sign - "$APP"
fi
echo "Built $PWD/$APP"
echo "Run: open $APP"
