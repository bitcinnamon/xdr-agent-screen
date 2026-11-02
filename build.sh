#!/bin/zsh
# Builds "XDR Agent Screen.app" into ./build
set -e
cd "$(dirname "$0")"
APP="build/XDR Agent Screen.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -import-objc-header CGVirtualDisplay.h main.swift -o "$APP/Contents/MacOS/XDRAgentScreen"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.xdr-agent-screen</string>
  <key>CFBundleName</key><string>XDR Agent Screen</string>
  <key>CFBundleDisplayName</key><string>XDR Agent Screen</string>
  <key>CFBundleExecutable</key><string>XDRAgentScreen</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
codesign --force -s - "$APP"
echo "built $APP"
