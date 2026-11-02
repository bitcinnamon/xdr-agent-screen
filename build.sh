#!/bin/zsh
# Builds "XDR Agent Screen.app" into ./build
set -e
cd "$(dirname "$0")"
APP="build/XDR Agent Screen.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# App icon: every size macOS wants, from the 1024px master (regenerate it with icon/make-icon.swift).
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
for px in 16 32 128 256 512; do
  sips -z $px $px icon/icon-1024.png --out "$ICONSET/icon_${px}x${px}.png" >/dev/null
  sips -z $((px * 2)) $((px * 2)) icon/icon-1024.png --out "$ICONSET/icon_${px}x${px}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
swiftc -O -target arm64-apple-macos14.0 -import-objc-header CGVirtualDisplay.h main.swift -o "$APP/Contents/MacOS/XDRAgentScreen"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.xdr-agent-screen</string>
  <key>CFBundleName</key><string>XDR Agent Screen</string>
  <key>CFBundleDisplayName</key><string>XDR Agent Screen</string>
  <key>CFBundleExecutable</key><string>XDRAgentScreen</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.1.0</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
codesign --force -s - "$APP"
echo "built $APP"
