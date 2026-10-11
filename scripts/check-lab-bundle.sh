#!/bin/zsh
set -euo pipefail
APP="${1:-.build/GimbalLab.app}"
PLIST="$APP/Contents/Info.plist"
plutil -lint "$PLIST"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$PLIST")" = GimbalLab
test "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$PLIST")" = 14.0
test -n "$(/usr/libexec/PlistBuddy -c 'Print :NSBluetoothAlwaysUsageDescription' "$PLIST")"
if /usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$PLIST" >/dev/null 2>&1; then
    print -u2 "GimbalLab debe abrir una ventana normal, no una app de barra de menús"
    exit 1
fi
test -x "$APP/Contents/MacOS/GimbalLab"
codesign --verify --strict "$APP"
