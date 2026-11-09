#!/bin/zsh
# Builds an Apple silicon, hardened-runtime Bollard.app in build/.
# Ad-hoc signed by default, which is enough to run locally and in CI.
#
# Release, from a clean checkout (one-time: xcrun notarytool store-credentials <profile> ...):
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" NOTARY_PROFILE=<profile> scripts/build.sh
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" NOTARY_PROFILE=<profile> scripts/dmg.sh
# A Developer ID identity gets a secure timestamp, which notarization requires. Ad-hoc signing
# cannot be timestamped. NOTARY_PROFILE zips the app, submits it with notarytool and staples the
# ticket to the app. The app uses no JIT, no dlopen of unsigned code, no Apple events and no
# network, so the hardened runtime needs no entitlements.
set -euo pipefail
cd "${0:A:h:h}"
version=$(grep -m1 'let version = ' Sources/Bollard/CLI.swift | sed 's/.*"\(.*\)".*/\1/')
build=$(git rev-list --count HEAD 2>/dev/null || echo 1)
swift build -c release --product Bollard --triple arm64-apple-macosx14.0
bin=$(swift build -c release --product Bollard --triple arm64-apple-macosx14.0 --show-bin-path)
app="$PWD/build/Bollard.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/Bollard" "$app/Contents/MacOS/Bollard"
cp Resources/Bollard.icns Resources/MenuBarIcon.png Resources/MenuBarIcon@2x.png "$app/Contents/Resources/"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Bollard</string>
<key>CFBundleIdentifier</key><string>com.fortunexbt.bollard</string>
<key>CFBundleName</key><string>Bollard</string>
<key>CFBundleDisplayName</key><string>Bollard</string>
<key>CFBundleIconFile</key><string>Bollard</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleVersion</key><string>$build</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSHumanReadableCopyright</key><string>Local only. No telemetry, no network requests.</string>
</dict></plist>
PLIST
xattr -cr "$app"
identity="${SIGN_IDENTITY:--}"
timestamp=--timestamp
[[ "$identity" == "-" ]] && timestamp=--timestamp=none
codesign --force --options runtime "$timestamp" --sign "$identity" "$app"
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  [[ "$identity" != "-" ]] || { echo "NOTARY_PROFILE needs SIGN_IDENTITY"; exit 1; }
  zip="build/Bollard-$version.zip"
  rm -f "$zip"
  ditto -c -k --keepParent "$app" "$zip"
  xcrun notarytool submit "$zip" --keychain-profile "$NOTARY_PROFILE" --wait
  rm -f "$zip"
  xcrun stapler staple "$app"
  xcrun stapler validate "$app"
fi
codesign --verify --deep --strict "$app"
file "$app/Contents/MacOS/Bollard"
printf '%s\n' "$app"
