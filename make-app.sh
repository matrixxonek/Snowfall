#!/bin/bash
# Buduje Snowfall.app (bez ikony w Docku), którą można dodać do elementów logowania.
set -e
cd "$(dirname "$0")"
swift build -c release
APP=Snowfall.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Snowfall "$APP/Contents/MacOS/Snowfall"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Snowfall</string>
  <key>CFBundleIdentifier</key><string>local.snowfall</string>
  <key>CFBundleExecutable</key><string>Snowfall</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
EOF
codesign --force --sign - "$APP"
echo "Gotowe: $(pwd)/$APP"
