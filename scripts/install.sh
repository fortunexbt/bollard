#!/bin/zsh
# Installs build/Bollard.app into /Applications, relaunches it, and links the CLI.
set -euo pipefail
cd "${0:A:h:h}"
binary="build/Bollard.app/Contents/MacOS/Bollard"
[[ -f "$binary" ]] || { echo "run scripts/build.sh first"; exit 1; }
if [[ -n "$(find Sources Resources -newer "$binary" -type f 2>/dev/null)" ]]; then
  echo "build/Bollard.app is older than the sources; run scripts/build.sh again"; exit 1
fi
pkill -x Bollard 2>/dev/null || true
sleep 0.5
rm -rf /Applications/Bollard.app
cp -R build/Bollard.app /Applications/Bollard.app
xattr -cr /Applications/Bollard.app
codesign --force --options runtime --sign "${SIGN_IDENTITY:--}" /Applications/Bollard.app 2>/dev/null
codesign --verify --deep --strict /Applications/Bollard.app
mkdir -p ~/.local/bin
ln -sfn /Applications/Bollard.app/Contents/MacOS/Bollard ~/.local/bin/bollard
open -a /Applications/Bollard.app
echo "installed $(defaults read /Applications/Bollard.app/Contents/Info.plist CFBundleShortVersionString); CLI at ~/.local/bin/bollard"
