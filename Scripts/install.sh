#!/bin/bash
# 构建 → 安装到 /Applications（无权限时退到 ~/Applications）→ 重启，一步到位
# 用法: ./Scripts/install.sh [版本号]   （默认 0.1.0）
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:-0.1.0}"

./Scripts/build_app.sh "$VERSION"

# 退出旧实例（含 /Applications 里可能残留的老版本）
pkill -x TokenMeter >/dev/null 2>&1 || true
osascript -e 'tell application "TokenMeter" to quit' >/dev/null 2>&1 || true
sleep 1
pkill -9 -x TokenMeter >/dev/null 2>&1 || true
sleep 1

if [ -w /Applications ]; then
    DEST=/Applications
else
    DEST="$HOME/Applications"
    mkdir -p "$DEST"
fi

# 用 ditto 保留签名/资源包/权限位
rm -rf "$DEST/TokenMeter.app"
ditto build/TokenMeter.app "$DEST/TokenMeter.app"
INSTALLED_VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$DEST/TokenMeter.app/Contents/Info.plist" 2>/dev/null || echo "?")
echo "==> 已安装 $DEST/TokenMeter.app v${INSTALLED_VERSION}"

# 清除隔离标记，避免更新替换后被 Gatekeeper 拦
xattr -dr com.apple.quarantine "$DEST/TokenMeter.app" >/dev/null 2>&1 || true

# 把 CLI 放到稳定路径：Claude Code hooks 等外部调用依赖固定路径
SUPPORT="$HOME/Library/Application Support/TokenMeter/bin"
if [ -f "./build/tokenmeter" ]; then
    mkdir -p "$SUPPORT"
    cp "./build/tokenmeter" "$SUPPORT/tokenmeter" && echo "==> CLI 已安装到 $SUPPORT/tokenmeter"
    if [ -w /usr/local/bin ]; then
        cp "./build/tokenmeter" /usr/local/bin/tokenmeter 2>/dev/null && echo "==> CLI 已安装到 /usr/local/bin/tokenmeter"
    fi
    # 用户级 PATH 目录（无需 sudo）
    if [ -d "$HOME/.local/bin" ]; then
        cp "./build/tokenmeter" "$HOME/.local/bin/tokenmeter" && echo "==> CLI 已安装到 ~/.local/bin/tokenmeter"
    fi
fi

open "$DEST/TokenMeter.app"
sleep 3
if pgrep -x TokenMeter >/dev/null; then
    echo "==> 已启动 PID $(pgrep -x TokenMeter | head -1)，菜单栏应出现图标"
else
    echo "!! 启动失败，请手动运行: open \"$DEST/TokenMeter.app\"" >&2
    exit 1
fi
