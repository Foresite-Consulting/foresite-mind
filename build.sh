#!/usr/bin/env bash
# Builds "Foresite Mind.app" (universal: Apple silicon + Intel) and zips it into dist/.
# Runs on any Mac with the Xcode command line tools (`xcode-select --install`); GitHub Actions runs it on every change.
set -euo pipefail
cd "$(dirname "$0")"

APP="dist/Foresite Mind.app"
rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

for arch in arm64 x86_64; do
  swiftc -O -target "$arch-apple-macos13" main.swift HotKeys.swift QuickAdd.swift Updater.swift -o "dist/ForesiteMind-$arch" \
    -framework AppKit -framework WebKit -framework ServiceManagement -framework AVFoundation \
    -framework UserNotifications -framework Carbon
done
lipo -create dist/ForesiteMind-arm64 dist/ForesiteMind-x86_64 -output "$APP/Contents/MacOS/ForesiteMind"
rm dist/ForesiteMind-arm64 dist/ForesiteMind-x86_64

cp Info.plist "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature: enough for macOS to run it on your own Mac after a one-time "Open" confirmation.
codesign --force --deep --sign - "$APP"
codesign --verify --verbose=2 "$APP"

(cd dist && ditto -c -k --keepParent "Foresite Mind.app" "Foresite-Mind.zip")
echo "Built dist/Foresite-Mind.zip"
