#!/usr/bin/env bash
# Builds the release binary and wraps it into "Tokei.app".
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP="build/Tokei.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/Tokei "$APP/Contents/MacOS/Tokei"
cp scripts/Info.plist "$APP/Contents/Info.plist"

# App icon (generated from Assets/tokei-icon-512.png).
bash scripts/make-icon.sh
if [ -f build/AppIcon.icns ]; then
    cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon" "$APP/Contents/Info.plist"
fi

# Signing: ad-hoc by default (local dev); set CODESIGN_IDENTITY to a
# "Developer ID Application: …" identity for distribution builds, which
# also enables the hardened runtime notarization requires.
IDENTITY="${CODESIGN_IDENTITY:--}"
if [ "$IDENTITY" = "-" ]; then
    codesign --force --sign - "$APP"
else
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
fi

echo "Built: $APP"
echo "Install with: cp -R \"$APP\" /Applications/"
