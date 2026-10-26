#!/usr/bin/env bash
# Renders design/icon/eclipse.svg into the macOS app icon sizes.
# Run after changing the icon, and commit the PNGs it writes.
set -euo pipefail
cd "$(dirname "$0")/.."

src=design/icon/eclipse.svg
out=macos/Runner/Assets.xcassets/AppIcon.appiconset
for size in 16 32 64 128 256 512 1024; do
  rsvg-convert -w "$size" -h "$size" "$src" -o "$out/app_icon_$size.png"
done
rsvg-convert -w 256 -h 256 "$src" -o assets/icon/eclipse.png
