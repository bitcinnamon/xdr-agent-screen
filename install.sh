#!/bin/zsh
# Builds XDR Agent Screen and installs a LaunchAgent so it starts at login.
set -e
cd "$(dirname "$0")"
./build.sh
LABEL=local.xdr-agent-screen
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
BIN="$PWD/build/XDR Agent Screen.app/Contents/MacOS/XDRAgentScreen"
launchctl unload "$PLIST" 2>/dev/null || true
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>$BIN</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key>
  <dict><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>/tmp/xdr-agent-screen.log</string>
  <key>StandardErrorPath</key><string>/tmp/xdr-agent-screen.log</string>
</dict>
</plist>
PLIST
launchctl load "$PLIST"
echo "installed: $PLIST"
