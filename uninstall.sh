#!/bin/zsh
# Turns off Launch at Login, quits XDR Agent Screen (restoring brightness) and removes the app.
APP="/Applications/XDR Agent Screen.app"
[[ -x "$APP/Contents/MacOS/XDRAgentScreen" ]] && "$APP/Contents/MacOS/XDRAgentScreen" --login-item off
pkill -TERM -x XDRAgentScreen 2>/dev/null && sleep 1
rm -rf "$APP"
echo "uninstalled (settings remain in: defaults read local.xdr-agent-screen)"
