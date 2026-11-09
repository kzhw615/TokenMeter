#!/bin/bash
# 把 Swift CLI 构建为 Tauri sidecar（按 rustc host triple 命名）
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --target tokenmeter
TRIPLE="$(rustc -vV 2>/dev/null | sed -n 's/^host: //p')" || true
if [ -z "$TRIPLE" ]; then
  case "$(uname -s)-$(uname -m)" in
    Darwin-arm64) TRIPLE=aarch64-apple-darwin;;
    Darwin-x86_64) TRIPLE=x86_64-apple-darwin;;
    Linux-x86_64) TRIPLE=x86_64-unknown-linux-gnu;;
    Linux-aarch64) TRIPLE=aarch64-unknown-linux-gnu;;
    MINGW*|MSYS*|CYGWIN*) TRIPLE=x86_64-pc-windows-msvc;;
    *) echo "无法推断 target triple，请手动复制二进制"; exit 1;;
  esac
fi
mkdir -p desktop/src-tauri/binaries
SRC=.build/release/tokenmeter
if [ -f .build/release/tokenmeter.exe ]; then SRC=.build/release/tokenmeter.exe; fi
EXT=""
case "$TRIPLE" in *windows*) EXT=".exe";; esac
cp "$SRC" "desktop/src-tauri/binaries/tokenmeter-${TRIPLE}${EXT}"
echo "==> sidecar: desktop/src-tauri/binaries/tokenmeter-${TRIPLE}${EXT}"
