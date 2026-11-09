#!/bin/zsh
# Packages build/Bollard.app into a drag-to-Applications disk image.
#
# Release, after scripts/build.sh has produced a notarized, stapled app:
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" NOTARY_PROFILE=<profile> scripts/dmg.sh
# SIGN_IDENTITY signs the image with a secure timestamp. NOTARY_PROFILE submits the image itself
# to notarytool and staples the ticket to it, so the download also opens offline. Without them
# the image is unsigned and fine for local use.
set -euo pipefail
cd "${0:A:h:h}"
app="build/Bollard.app"
[[ -d "$app" ]] || { echo "run scripts/build.sh first"; exit 1; }
version=$(defaults read "$PWD/$app/Contents/Info.plist" CFBundleShortVersionString)
dmg="build/Bollard-$version.dmg"
stage=$(mktemp -d)
cp -R "$app" "$stage/"
ln -s /Applications "$stage/Applications"
rm -f "$dmg"
diskutil image create from --volumeName Bollard --format UDZO "$stage" "$dmg" >/dev/null
rm -rf "$stage"
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$dmg"
fi
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  [[ -n "${SIGN_IDENTITY:-}" ]] || { echo "NOTARY_PROFILE needs SIGN_IDENTITY"; exit 1; }
  xcrun notarytool submit "$dmg" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$dmg"
  xcrun stapler validate "$dmg"
fi
printf '%s\n' "$dmg"
