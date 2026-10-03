#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product QuendaCompanionMac
app="build/Companion.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Assets/Companion.icns "$app/Contents/Resources/"
cp .build/release/QuendaCompanionMac "$app/Contents/MacOS/"
cp Apps/macOS/Info.plist "$app/Contents/Info.plist"
codesign --force --sign - "$app"
scripts/build-ios-sdk.sh
# To build/sign/install through Xcode, install its iOS platform component and use
# Apps/iOS/QuendaCompanion.xcodeproj. SDK-only output is deliberately unsigned.
