#!/bin/zsh
# Builds XDR Agent Screen, installs it to /Applications, starts it and turns on Launch at Login.
set -e
cd "$(dirname "$0")"
./build.sh
APP="/Applications/XDR Agent Screen.app"

# Quit a running copy first (it restores brightness on the way out), and wait for it to be gone:
# the new copy exits right away if it finds another instance still running.
pkill -TERM -x XDRAgentScreen 2>/dev/null || true
for _ in {1..50}; do pgrep -x XDRAgentScreen >/dev/null || break; sleep 0.1; done

# Clean up the LaunchAgent that earlier versions of this script installed.
OLD="$HOME/Library/LaunchAgents/local.xdr-agent-screen.plist"
if [[ -f "$OLD" ]]; then launchctl unload "$OLD" 2>/dev/null || true; rm -f "$OLD"; fi

rm -rf "$APP"
ditto "build/XDR Agent Screen.app" "$APP"
"$APP/Contents/MacOS/XDRAgentScreen" --login-item on
open "$APP"
echo "installed: $APP"
