#!/bin/zsh
# Empaqueta GimbalSmoke en una .app con permiso de Bluetooth (un binario suelto lanzado desde el terminal muere con SIGABRT).
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --disable-sandbox -c release --product GimbalSmoke
APP=".build/GimbalSmoke.app"
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS"
cp ".build/release/GimbalSmoke" "$APP/Contents/MacOS/GimbalSmokeBin"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.gimbalkit.smoke</string>
<key>CFBundleName</key><string>GimbalSmoke</string>
<key>CFBundleExecutable</key><string>run</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSBackgroundOnly</key><true/>
<key>NSBluetoothAlwaysUsageDescription</key><string>Probar la conexión con el estabilizador.</string>
</dict></plist>
EOF
OUT="${SMOKE_OUT:-/tmp/gimbalkit-smoke.txt}"
printf '#!/bin/zsh\nexec "%s/Contents/MacOS/GimbalSmokeBin" %s > "%s" 2>&1\n' "$PWD/$APP" "${*:-}" "$OUT" > "$APP/Contents/MacOS/run"
chmod +x "$APP/Contents/MacOS/run"
codesign -s - --force --deep "$APP" >/dev/null
rm -f "$OUT"; open -W "$APP"; cat "$OUT"
