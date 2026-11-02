#!/bin/zsh
# Builds XDR Agent Screen, installs it to /Applications, starts it and turns on Launch at Login.
set -e
cd "$(dirname "$0")"
./build.sh
APP="/Applications/XDR Agent Screen.app"

# Quit a running copy first (it restores brightness on the way out).
pkill -TERM -x XDRAgentScreen 2>/dev/null && sleep 1 || true

# Clean up the LaunchAgent that earlier versions of this script installed.
OLD="$HOME/Library/LaunchAgents/local.xdr-agent-screen.plist"
if [[ -f "$OLD" ]]; then launchctl unload "$OLD" 2>/dev/null || true; rm -f "$OLD"; fi

rm -rf "$APP"
ditto "build/XDR Agent Screen.app" "$APP"
"$APP/Contents/MacOS/XDRAgentScreen" --login-item on
open "$APP"
echo "installed: $APP"
