#!/usr/bin/env bash
# Builds the release binary and wraps it into "AI Usage Monitor.app".
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP="build/AI Usage Monitor.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/AIUsageMonitor "$APP/Contents/MacOS/AIUsageMonitor"
cp scripts/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc signature so macOS remembers the keychain "Always Allow" choice
# across rebuilds.
codesign --force --sign - "$APP"

echo "Built: $APP"
echo "Install with: cp -R \"$APP\" /Applications/"
