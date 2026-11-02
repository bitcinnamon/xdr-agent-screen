#!/bin/zsh
# Stops XDR Agent Screen (restoring brightness) and removes its LaunchAgent.
PLIST="$HOME/Library/LaunchAgents/local.xdr-agent-screen.plist"
launchctl unload "$PLIST" 2>/dev/null || true
rm -f "$PLIST"
echo "uninstalled (settings remain in: defaults read local.xdr-agent-screen)"
