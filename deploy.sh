#!/bin/zsh
# Builds İlmek, installs it on the connected iPhone and launches it.
# Usage: DEVICE_ID=<udid> ./deploy.sh
#        DEVICE_ID=<udid> ./deploy.sh --demo     (sample data for screenshots, in memory only; see DemoData.swift)
set -euo pipefail

cd "$(dirname "$0")"

DEVICE_ID="${DEVICE_ID:?Set DEVICE_ID to your iPhone UDID (xcrun devicectl list devices)}"
BUNDLE_ID="com.mehol01.Ilmek"
APP_PATH="build/Build/Products/Debug-iphoneos/Ilmek.app"

echo "▸ Building…"
xcodebuild -project Ilmek.xcodeproj -scheme Ilmek -configuration Debug \
  -destination "id=$DEVICE_ID" -derivedDataPath build \
  -allowProvisioningUpdates -quiet build

echo "▸ Installing…"
xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH" > /dev/null

echo "▸ Launching…"
ARGS=()
# Demo runs in the language of the screenshots: DEMO_LANG=en ./deploy.sh --demo
DEMO_LANG="${DEMO_LANG:-tr}"
[[ "$DEMO_LANG" == "en" ]] && DEMO_LOCALE=en_US || DEMO_LOCALE=tr_TR
[[ "${1:-}" == "--demo" ]] && ARGS=(-demo -AppleLanguages "($DEMO_LANG)" -AppleLocale "$DEMO_LOCALE")
xcrun devicectl device process launch --terminate-existing --device "$DEVICE_ID" "$BUNDLE_ID" -- "${ARGS[@]}" > /dev/null

echo "✓ İlmek running on device"
