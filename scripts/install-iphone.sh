#!/bin/bash
# Build, sign, install and launch the development app on a paired iPhone.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo 'Usage: scripts/install-iphone.sh TEAM_ID [DEVICE_UDID_OR_NAME]' >&2
    echo 'Sign in to Xcode > Settings > Apple Accounts first, and unlock your iPhone.' >&2
    exit 2
fi
companion_team="$1"
if [[ ! "$companion_team" =~ ^[A-Z0-9]{10}$ ]]; then
    echo 'TEAM_ID must be the 10-character Apple development team identifier.' >&2
    exit 2
fi
companion_device_file="$(mktemp -t quenda-companion-devices)"
trap 'rm -f "$companion_device_file"' EXIT
xcrun devicectl list devices --json-output "$companion_device_file" >/dev/null
companion_device="$(python3 - "$companion_device_file" "${2:-}" <<'PY'
import json, sys
selector = sys.argv[2]
devices = json.load(open(sys.argv[1])).get('result', {}).get('devices', [])
phones = [d for d in devices if d.get('hardwareProperties', {}).get('platform') == 'iOS'
          and d.get('connectionProperties', {}).get('pairingState') == 'paired']
if selector:
    phones = [d for d in phones if selector in (d.get('identifier'), d.get('hardwareProperties', {}).get('udid'), d.get('deviceProperties', {}).get('name'))]
else:
    phones = [d for d in phones if d.get('connectionProperties', {}).get('transportType') == 'wired']
if len(phones) != 1:
    raise SystemExit('Connect one paired iPhone by USB, or specify its UDID/name.')
print(phones[0]['hardwareProperties']['udid'])
PY
)"
xcodebuild -project Apps/iOS/QuendaCompanion.xcodeproj \
    -scheme QuendaCompanion -configuration Debug \
    -destination "id=$companion_device" -destination-timeout 30 \
    -derivedDataPath build/iOS-Device \
    -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
    DEVELOPMENT_TEAM="$companion_team" CODE_SIGNING_ALLOWED=YES build
companion_app='build/iOS-Device/Build/Products/Debug-iphoneos/QuendaCompanion.app'
[[ -f "$companion_app/embedded.mobileprovision" ]] || { echo 'Missing development provisioning profile.' >&2; exit 1; }
codesign --verify "$companion_app"
companion_bundle="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$companion_app/Info.plist")"
xcrun devicectl device install app --device "$companion_device" "$companion_app" --timeout 60
xcrun devicectl device process launch --device "$companion_device" "$companion_bundle" --timeout 30
