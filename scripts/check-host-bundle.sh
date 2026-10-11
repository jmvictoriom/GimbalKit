#!/bin/zsh
set -euo pipefail
HOST_APP="${1:-.build/GimbalHostMac.app}"
HOST_PLIST="$HOST_APP/Contents/Info.plist"
plutil -lint "$HOST_PLIST"
test "$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$HOST_PLIST")" = true
test "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$HOST_PLIST")" = 14.0
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$HOST_PLIST")" = GimbalHostMac
test -n "$(/usr/libexec/PlistBuddy -c 'Print :NSBluetoothAlwaysUsageDescription' "$HOST_PLIST")"
test -x "$HOST_APP/Contents/MacOS/GimbalHostMac"
codesign --verify --strict "$HOST_APP"
