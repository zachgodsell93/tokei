#!/usr/bin/env bash
# Converts Assets/logo.png (square, ideally 1024x1024) into AppIcon.icns.
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="Assets/logo.png"
OUT="build/AppIcon.icns"
if [ ! -f "$SRC" ]; then
    echo "No $SRC found — skipping icon generation."
    exit 0
fi

ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"

for size in 16 32 128 256 512; do
    sips -z $size $size "$SRC" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    retina=$((size * 2))
    sips -z $retina $retina "$SRC" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$ICONSET" -o "$OUT"
rm -rf "$ICONSET"
echo "Generated $OUT"
