#!/bin/zsh
# Builds "Volume Mixer.app" into ./build. Requires macOS 14.2+ and the Xcode command line tools.
set -euo pipefail
cd "${0:A:h}"

APP="build/Volume Mixer.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build

echo "Compiling…"
swiftc -O -swift-version 5 \
    -target "$(uname -m)-apple-macos14.2" \
    -framework AppKit -framework SwiftUI -framework CoreAudio -framework ServiceManagement \
    Sources/*.swift -o "$APP/Contents/MacOS/VolumeMixer"

cp Info.plist "$APP/Contents/Info.plist"

echo "Rendering icon…"
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET"
swift make_icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

echo "Signing (ad-hoc)…"
codesign --force --sign - "$APP"

echo "Built: $PWD/$APP"
