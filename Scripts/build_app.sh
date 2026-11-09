#!/bin/bash
# 构建 TokenMeter.app（菜单栏应用）与 tokenmeter CLI
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> swift build -c release"
swift build -c release

BUILD=.build/release
OUT=build
APP="$OUT/TokenMeter.app"

rm -rf "$OUT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BUILD/TokenMeterApp" "$APP/Contents/MacOS/TokenMeter"
cp "$BUILD/tokenmeter" "$OUT/tokenmeter"
cp Assets/TokenMeter.icns "$APP/Contents/Resources/"
cp Assets/menubar_icon.png Assets/menubar_icon@2x.png "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>TokenMeter</string>
    <key>CFBundleDisplayName</key>
    <string>TokenMeter</string>
    <key>CFBundleIdentifier</key>
    <string>local.tokenmeter.menubar</string>
    <key>CFBundleExecutable</key>
    <string>TokenMeter</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>CFBundleIconFile</key>
    <string>TokenMeter</string>
    <key>NSHumanReadableCopyright</key>
    <string>Local-only token meter</string>
</dict>
</plist>
PLIST

echo "==> ad-hoc codesign"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "==> done: $APP 和 $OUT/tokenmeter"
echo "    运行: open $APP   或   $OUT/tokenmeter report"
