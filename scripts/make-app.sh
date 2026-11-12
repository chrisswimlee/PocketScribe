#!/bin/zsh
# Builds a real PocketScribe.app (needed for the microphone permission prompt).
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product PocketScribeApp
BIN=$(swift build -c release --show-bin-path)
APP=build/PocketScribe.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/PocketScribeApp" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
# SwiftPM resource bundles (if any dependency ships them)
for b in "$BIN"/*.bundle(N); do cp -R "$b" "$APP/Contents/Resources/"; done
cp Resources/PrivacyInfo.xcprivacy "$APP/Contents/Resources/"
# SANDBOX=1 ./scripts/make-app.sh signs with the App Store sandbox entitlements.
# Note: a sandboxed build keeps its data in ~/Library/Containers/dev.chrisswimlee.PocketScribe.
if [[ "${SANDBOX:-0}" == "1" ]]; then
  codesign --force --deep --sign - --entitlements Resources/PocketScribe.entitlements "$APP"
else
  codesign --force --deep --sign - "$APP"
fi
echo "Built $PWD/$APP"
echo "Run: open $APP"
