#!/bin/zsh
# Builds a universal, hardened-runtime Bollard.app in build/.
# Ad-hoc signed by default. Set SIGN_IDENTITY="Developer ID Application: …" to sign for
# distribution, and NOTARY_PROFILE=<notarytool keychain profile> to notarize and staple.
set -euo pipefail
cd "${0:A:h:h}"
version=$(grep -m1 'let version = ' Sources/Bollard/CLI.swift | sed 's/.*"\(.*\)".*/\1/')
build=$(git rev-list --count HEAD 2>/dev/null || echo 1)
for arch in arm64 x86_64; do
  swift build --build-system native -c release --product Bollard --triple "$arch-apple-macosx14.0"
done
app="$PWD/build/Bollard.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
lipo -create .build/arm64-apple-macosx/release/Bollard .build/x86_64-apple-macosx/release/Bollard -output "$app/Contents/MacOS/Bollard"
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
codesign --force --options runtime --timestamp=none --sign "${SIGN_IDENTITY:--}" "$app"
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  zip="build/Bollard-$version.zip"
  ditto -c -k --keepParent "$app" "$zip"
  xcrun notarytool submit "$zip" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$app"
fi
codesign --verify --deep --strict "$app"
lipo -archs "$app/Contents/MacOS/Bollard"
printf '%s\n' "$app"
