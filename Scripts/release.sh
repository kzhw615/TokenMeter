#!/bin/bash
# 发版一条龙：构建 → 打 tag → 推 tag → 打包附件 → 创建 GitHub Release（watch 者收到通知）
# 用法: ./Scripts/release.sh 0.2.0 "本版变更说明（markdown）"
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?用法: release.sh <版本号如 0.2.0> [release notes]}"
NOTES="${2:-见提交历史}"

if [ -n "$(git status --porcelain)" ]; then
    echo "✗ 工作区不干净：先 commit 并 push 本次变更，再发版"
    exit 1
fi

echo "==> 构建 v$VERSION"
./Scripts/build_app.sh "$VERSION"

echo "==> 打 tag 并推送"
git tag -a "v$VERSION" -m "v$VERSION"
git push origin "v$VERSION"

echo "==> 打包附件"
rm -f build/TokenMeter.app.zip build/tokenmeter.zip
ditto -c -k --sequesterRsrc --keepParent build/TokenMeter.app build/TokenMeter.app.zip
zip -j -q build/tokenmeter.zip build/tokenmeter

echo "==> 创建 GitHub Release"
gh release create "v$VERSION" build/TokenMeter.app.zip build/tokenmeter.zip \
    --title "v$VERSION" --notes "$NOTES"

echo "✓ 已发布 v$VERSION：https://github.com/kzhw615/TokenMeter/releases/tag/v$VERSION"
echo "  Watch 了仓库的用户会收到 GitHub 通知；App 内更新检查也会提示新版本"
