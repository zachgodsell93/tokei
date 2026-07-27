#!/usr/bin/env bash
# Builds a distributable DMG: build/Tokei-<version>.dmg
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" scripts/Info.plist)

bash scripts/build-app.sh

STAGING="build/dmg-staging"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "build/Tokei.app" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

DMG="build/Tokei-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "Tokei" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"

echo "Built: $DMG"
