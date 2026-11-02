# XDR Agent Screen

English | [中文](README.zh-CN.md)

A macOS menu bar app that keeps your display dark while computer-use agents keep working.

## Why

On Apple silicon Macs, letting the display sleep always raises the lock screen shield, even with
no password set. Once that happens, screen capture returns nothing and computer-use agents go
blind. XDR Agent Screen blacks the display out *without* sleeping it: the picture is dimmed through
the gamma table and the backlight is turned down, so the screen looks off but screenshots still
see the full desktop.

Built for a Mac mini driving a Pro Display XDR, but works with any display.

## Features

- **Black Out Now** and a global shortcut (configurable, default ⌃⌥⌘L) to toggle black-out.
- **Combined brightness slider**: the right half drives the native backlight (same as the system
  brightness control), the left half keeps the backlight at minimum and dims further in software,
  down to black.
- **Idle black-out**: black out after 1–60 minutes without input, or never.
- **Agent Display**: an optional virtual display (1280×720 up to 3840×2160), mirrored to the main
  display by default. If the physical display is powered off (e.g. with a smart plug), the
  virtual display takes over so agents still have a screen.
- Safe recovery: quitting or crashing restores the picture; locking the screen restores
  brightness so the login window is visible.

## Requirements

- macOS 14 or later, Apple silicon
- Xcode command line tools (`swiftc`)
- Recommended: System Settings → Lock Screen → turn display off and start screen saver: **Never**

## Download

Grab `XDR-Agent-Screen-*-arm64.zip` from [Releases](https://github.com/bitcinnamon/xdr-agent-screen/releases),
unzip, and move `XDR Agent Screen.app` to `/Applications`. The app is ad-hoc signed but not
notarized, so the first launch is blocked by Gatekeeper: right-click the app → **Open**, or run

```sh
xattr -dr com.apple.quarantine "/Applications/XDR Agent Screen.app"
```

To start it at login, add it in System Settings → General → Login Items.

## Build from source

```sh
./install.sh     # builds build/XDR Agent Screen.app and installs a LaunchAgent (starts at login)
./uninstall.sh   # stops it (restoring brightness) and removes the LaunchAgent
```

Log: `/tmp/xdr-agent-screen.log`. Settings: `defaults read local.xdr-agent-screen`.

## Remote control

```sh
kill -USR2 $(pgrep -x XDRAgentScreen)   # toggle black-out, same as the shortcut
kill -USR1 $(pgrep -x XDRAgentScreen)   # pop the menu open for 5 s (for screenshots)
```

If the screen is ever stuck dark, `./uninstall.sh` (or `launchctl unload` of the LaunchAgent)
always brings it back.

## Notes

- Synthetic input from automation counts as activity for the system idle timer, so it can trigger
  idle black-out but never undoes it; only the shortcut, menu or signal restores brightness.
- Hardware brightness and the virtual display use private macOS APIs (`DisplayServices`,
  `CGVirtualDisplay`) and may break in future macOS releases.
