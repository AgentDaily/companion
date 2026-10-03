#!/bin/bash
# SDK-only compilation also works on Macs without installed simulator runtimes.
set -euo pipefail
cd "$(dirname "$0")/.."
sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
out=build/iOS-SDK
mkdir -p "$out/QuendaCompanion.app"
xcrun --sdk iphoneos swiftc -swift-version 5 -parse-as-library -target arm64-apple-ios17.0 -sdk "$sdk" -module-name CompanionCore -emit-module -emit-module-path "$out/CompanionCore.swiftmodule" -emit-library -static Sources/CompanionCore/*.swift -o "$out/libCompanionCore.a"
xcrun --sdk iphoneos swiftc -swift-version 5 -parse-as-library -target arm64-apple-ios17.0 -sdk "$sdk" -I "$out" -module-name CompanionUI -emit-module -emit-module-path "$out/CompanionUI.swiftmodule" -emit-library -static Sources/CompanionUI/*.swift -o "$out/libCompanionUI.a"
xcrun --sdk iphoneos swiftc -swift-version 5 -parse-as-library -target arm64-apple-ios17.0 -sdk "$sdk" -I "$out" -L "$out" -lCompanionUI -lCompanionCore Apps/iOS/App.swift -o "$out/QuendaCompanion.app/QuendaCompanion"
xcrun actool Apps/iOS/Assets.xcassets --compile "$out/QuendaCompanion.app" --platform iphoneos --minimum-deployment-target 17.0 --target-device iphone --target-device ipad --app-icon AppIcon --output-partial-info-plist "$out/icon-info.plist"
python3 - <<'PY'
import plistlib
from pathlib import Path
source = plistlib.loads(Path('Apps/iOS/Info.plist').read_bytes())
source.update(CFBundleIdentifier='com.quenda.companion.ios', CFBundleExecutable='QuendaCompanion', CFBundleName='Companion', MinimumOSVersion='17.0')
source.update(plistlib.loads(Path('build/iOS-SDK/icon-info.plist').read_bytes()))
Path('build/iOS-SDK/QuendaCompanion.app/Info.plist').write_bytes(plistlib.dumps(source))
PY
