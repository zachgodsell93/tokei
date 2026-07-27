#!/usr/bin/env bash
# Builds a distributable DMG: build/AI-Usage-Monitor-<version>.dmg
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" scripts/Info.plist)

bash scripts/build-app.sh

STAGING="build/dmg-staging"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "build/AI Usage Monitor.app" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

DMG="build/AI-Usage-Monitor-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "AI Usage Monitor" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"

echo "Built: $DMG"
