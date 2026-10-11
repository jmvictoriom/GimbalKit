#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/modcache"
timeout 300 swift build --disable-sandbox --scratch-path .build -c release --product GimbalLabMac
APP="$PWD/.build/GimbalLab.app"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/GimbalLabMac "$APP/Contents/MacOS/GimbalLabBin"
# LaunchServices forwards --args to this launcher. Capture automatic stdout even with open -W.
cat > "$APP/Contents/MacOS/GimbalLab" <<'EOF'
#!/bin/zsh
set -euo pipefail
BIN="${0:A:h}/GimbalLabBin"
if (( ${argv[(Ie)--auto-run]} )); then
    for (( i=1; i < $#; i++ )); do
        if [[ "${argv[i]}" == --out ]]; then
            REPORT="${argv[i+1]}"
            mkdir -p -- "${REPORT:h}"
            exec "$BIN" "$@" > "${REPORT}.log" 2>&1
        fi
    done
fi
exec "$BIN" "$@"
EOF
chmod +x "$APP/Contents/MacOS/GimbalLab" "$APP/Contents/MacOS/GimbalLabBin"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.gimbalkit.lab.mac</string>
<key>CFBundleName</key><string>GimbalLab</string>
<key>CFBundleExecutable</key><string>GimbalLab</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSBluetoothAlwaysUsageDescription</key><string>Conectar y probar el estabilizador desde GimbalLab.</string>
</dict></plist>
EOF
plutil -lint "$APP/Contents/Info.plist"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")" = GimbalLab
test -n "$(/usr/libexec/PlistBuddy -c 'Print :NSBluetoothAlwaysUsageDescription' "$APP/Contents/Info.plist")"
codesign --force --sign - "$APP"
scripts/check-lab-bundle.sh "$APP"
printf 'App preparada: %s\n' "$APP"
