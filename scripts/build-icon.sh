#!/bin/zsh
# Regenerates the icon assets from scripts/render-icon.py.
#   Resources/Bollard.icon      layered Icon Composer document (macOS 26 and later)
#   Resources/Bollard.icns      flattened fallback for macOS 14 and 15
#   Resources/MenuBarIcon.pdf   vector template glyph for the status item
# build.sh compiles the .icon into Assets.car with actool. Needs Xcode (Icon Composer) and librsvg.
set -euo pipefail
cd "${0:A:h:h}"
ictool="/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
python3 scripts/render-icon.py
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
set=$work/Bollard.iconset
mkdir "$set"
for size in 16 32 128 256 512; do
  "$ictool" Resources/Bollard.icon --export-image --output-file "$set/icon_${size}x${size}.png" \
    --platform macOS --rendition Default --width $size --height $size --scale 1 >/dev/null
  "$ictool" Resources/Bollard.icon --export-image --output-file "$set/icon_${size}x${size}@2x.png" \
    --platform macOS --rendition Default --width $size --height $size --scale 2 >/dev/null
done
iconutil -c icns "$set" -o Resources/Bollard.icns
echo "Resources/Bollard.icns"
