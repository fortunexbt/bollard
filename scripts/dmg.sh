#!/bin/zsh
# Packages build/Bollard.app into a drag-to-Applications disk image.
#
# The window layout (icon view, background, icon positions) is set by driving Finder with
# osascript on a read-write copy, then the image is converted to a compressed read-only one.
# The first run may ask to allow this terminal to control Finder.
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

# Window geometry in points. The background and the icon positions come from the same numbers
# in scripts/render-dmg-background.swift.
width=660 height=400 icon_size=128 app_x=180 applications_x=480 icon_y=195
volume=Bollard
mount_point="/Volumes/$volume"
[[ ! -e "$mount_point" ]] || { echo "$mount_point is already mounted; eject it first"; exit 1; }

work=$(mktemp -d)
cleanup() {
  hdiutil detach "$mount_point" -force >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

stage="$work/stage"
mkdir -p "$stage/.background"
cp -R "$app" "$stage/"
ln -s /Applications "$stage/Applications"
swift scripts/render-dmg-background.swift "$stage/.background/background.tiff" >/dev/null

rw="$work/rw.dmg"
# Headroom for the volume icon, which is copied in after the layout is set.
size_mb=$(( $(du -sm "$stage" | cut -f1) + 16 ))
hdiutil create -quiet -srcfolder "$stage" -size "${size_mb}m" -volname "$volume" -fs HFS+ -format UDRW -ov "$rw"
hdiutil attach -quiet -readwrite -noverify -noautoopen "$rw"

# Finder writes the layout to the volume's .DS_Store: a fixed-size icon-view window with no
# toolbar, sidebar or status bar, the background, and the two icons placed by their centres.
osascript >/dev/null <<OSA
tell application "Finder"
  tell disk "$volume"
    open
    set win to container window
    set current view of win to icon view
    set toolbar visible of win to false
    set statusbar visible of win to false
    set sidebar width of win to 0
    set opts to the icon view options of win
    set arrangement of opts to not arranged
    set icon size of opts to $icon_size
    set text size of opts to 13
    set label position of opts to bottom
    set shows item info of opts to false
    set background picture of opts to file ".background:background.tiff"
    set position of item "Bollard.app" of win to {$app_x, $icon_y}
    set position of item "Applications" of win to {$applications_x, $icon_y}
    set the bounds of win to {200, 120, $((200 + width)), $((120 + height))}
    update without registering applications
    delay 2
    close
  end tell
end tell
OSA
# Finder deletes a .VolumeIcon.icns that was there before it laid out the window, so the volume
# icon goes on last. hdiutil create also ignores the custom-icon flag on the staged folder.
cp Resources/Bollard.icns "$mount_point/.VolumeIcon.icns"
SetFile -a C "$mount_point"
sync
for _ in {1..20}; do [[ -s "$mount_point/.DS_Store" ]] && break; sleep 0.5; done
[[ -s "$mount_point/.DS_Store" ]] || { echo "Finder did not write the window layout"; exit 1; }
hdiutil detach -quiet "$mount_point"

rm -f "$dmg"
hdiutil convert -quiet "$rw" -format UDZO -imagekey zlib-level=9 -o "$dmg"
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
