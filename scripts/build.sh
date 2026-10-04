#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
swift build --build-system native -c release --product DevPorts
app="$PWD/build/DevPorts.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp -X .build/release/DevPorts "$app/Contents/MacOS/DevPorts"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>DevPorts</string>
<key>CFBundleIdentifier</key><string>local.fortune.DevPorts</string>
<key>CFBundleName</key><string>DevPorts</string>
<key>CFBundleDisplayName</key><string>DevPorts</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.1.1</string>
<key>CFBundleVersion</key><string>3</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
xattr -cr "$app"
codesign --force --sign - "$app"
printf '%s\n' "$app"
