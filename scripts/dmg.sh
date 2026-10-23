#!/bin/zsh
# Packages build/Bollard.app into a drag-to-Applications disk image.
set -euo pipefail
cd "${0:A:h:h}"
app="build/Bollard.app"
[[ -d "$app" ]] || { echo "run scripts/build.sh first"; exit 1; }
version=$(defaults read "$PWD/$app/Contents/Info.plist" CFBundleShortVersionString)
stage=$(mktemp -d)
cp -R "$app" "$stage/"
ln -s /Applications "$stage/Applications"
rm -f "build/Bollard-$version.dmg"
hdiutil create -volname "Bollard" -srcfolder "$stage" -ov -format UDZO "build/Bollard-$version.dmg" >/dev/null
rm -rf "$stage"
printf '%s\n' "build/Bollard-$version.dmg"
