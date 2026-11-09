#!/bin/bash
# Build (signed, Release) and install Skyfolder into /Applications, then launch it.
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate >/dev/null
xcodebuild -project Skyfolder.xcodeproj -scheme Skyfolder -configuration Release \
  -derivedDataPath build -allowProvisioningUpdates build | grep -E "error:|BUILD" || true
APP="build/Build/Products/Release/Skyfolder.app"
[ -d "$APP" ] || { echo "Build failed"; exit 1; }
osascript -e 'quit app "Skyfolder"' 2>/dev/null || true
sleep 1
rm -rf "/Applications/Skyfolder.app"
cp -R "$APP" /Applications/
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/Skyfolder.app"
open "/Applications/Skyfolder.app"
echo "Installed and launched /Applications/Skyfolder.app"
