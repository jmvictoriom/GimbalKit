#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/modcache"
timeout 300 swift build --disable-sandbox --scratch-path .build -c release --product GimbalHostMac
timeout 300 swift build --disable-sandbox --scratch-path .build -c release --product gimbal
HOST_APP="$PWD/.build/GimbalHostMac.app"
mkdir -p "$HOST_APP/Contents/MacOS" "$PWD/.build/bin"
cp .build/release/GimbalHostMac "$HOST_APP/Contents/MacOS/GimbalHostMac"
cp .build/release/gimbal .build/bin/gimbal
chmod +x "$HOST_APP/Contents/MacOS/GimbalHostMac" .build/bin/gimbal
cat > "$HOST_APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.gimbalkit.host.mac</string>
<key>CFBundleName</key><string>GimbalHostMac</string>
<key>CFBundleExecutable</key><string>GimbalHostMac</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSBluetoothAlwaysUsageDescription</key><string>Conectar y controlar el estabilizador desde GimbalKit.</string>
</dict></plist>
EOF
codesign --force --sign - "$HOST_APP"
scripts/check-host-bundle.sh "$HOST_APP"
printf 'App preparada: %s\nCLI preparada: %s\n' "$HOST_APP" "$PWD/.build/bin/gimbal"
