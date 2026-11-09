#!/bin/bash
# 构建 TokenMeter.app（菜单栏应用）与 tokenmeter CLI
# 用法: ./Scripts/build_app.sh [版本号]   （默认 0.1.0）
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:-0.1.0}"

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
cp Assets/menubar_flame@2x.png "$APP/Contents/Resources/"
cp Assets/menubar_flame_0@2x.png Assets/menubar_flame_1@2x.png Assets/menubar_flame_2@2x.png Assets/menubar_flame_3@2x.png Assets/menubar_flame_4@2x.png Assets/menubar_flame_5@2x.png "$APP/Contents/Resources/"
cp Assets/menubar_flame_hot_0@2x.png Assets/menubar_flame_hot_1@2x.png Assets/menubar_flame_hot_2@2x.png Assets/menubar_flame_hot_3@2x.png Assets/menubar_flame_hot_4@2x.png Assets/menubar_flame_hot_5@2x.png "$APP/Contents/Resources/"

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
    <string>{{VERSION}}</string>
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
sed -i '' "s/{{VERSION}}/$VERSION/" "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "==> done: $APP 和 $OUT/tokenmeter"
echo "    运行: open $APP   或   $OUT/tokenmeter report"
