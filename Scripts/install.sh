#!/bin/bash
# 构建并安装 TokenMeter 到 /Applications（无权限时退到 ~/Applications）
set -euo pipefail
cd "$(dirname "$0")/.."

./Scripts/build_app.sh

# 若旧实例在运行先退出
osascript -e 'tell application "TokenMeter" to quit' >/dev/null 2>&1 || true
sleep 1

if [ -w /Applications ]; then
    DEST=/Applications
else
    DEST="$HOME/Applications"
    mkdir -p "$DEST"
fi

rm -rf "$DEST/TokenMeter.app"
cp -R build/TokenMeter.app "$DEST/"
echo "==> 已安装到 $DEST/TokenMeter.app"
open "$DEST/TokenMeter.app"
echo "==> 已启动。菜单栏出现 ⬢ 图标即成功；开机自启请在 系统设置 → 通用 → 登录项 中添加 TokenMeter。"
