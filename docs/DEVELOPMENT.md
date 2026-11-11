# 开发与构建

面向想改代码、从源码构建或自己发版的维护者。**普通用户请只看 [README](../README.md)。**

## 目录结构

```
Package.swift                    SwiftPM：TokenMeterCore 库 + tokenmeter CLI + TokenMeterApp
Sources/TokenMeterCore/          模型 / 聚合 / 价格 / 扫描缓存 / 行读取器
Sources/TokenMeterCore/Sources/  13 个 harness 解析器（实现 UsageSource 协议）
Sources/tokenmeter/              CLI
Sources/TokenMeterApp/           AppKit 菜单栏（NSStatusItem）+ SwiftUI 面板 / 悬浮坞 / 设置窗口
  ├── main.swift                 纯 AppKit 入口（避免 SwiftUI Scene 自建空窗口）
  ├── StatusBarController.swift  菜单栏图标、左键面板、右键菜单
  ├── SideDock.swift             侧边悬浮坞（拖拽 / 吸附 / 融合形态）
  ├── SettingsView.swift         独立设置窗口
  └── Resources/harness/         13 个工具的图标 PNG
Scripts/build_app.sh             构建 + 组装 .app + ad-hoc 签名
Scripts/install.sh               一步到位：构建 + 安装到 /Applications + 重启
Scripts/release.sh               发版：打 tag + 打包 + 创建 GitHub Release
Scripts/make_icons.py            生成 App 图标与菜单栏火苗帧
docs/                            本文件 + 发版说明规范
desktop/                         Tauri v2 实验性托盘应用（见下）
.research/                       官方定价页抓取存档（定价依据）
```

## 从源码构建

```bash
./Scripts/install.sh            # 构建 + 安装到 /Applications + 重启（推荐）
# 或只构建不安装：
./Scripts/build_app.sh 0.7.4    # 产出 build/TokenMeter.app 与 build/tokenmeter
open build/TokenMeter.app
```

要求 macOS 14+ 与 Xcode Command Line Tools。

## CLI

```bash
swift build -c release --target tokenmeter
.build/release/tokenmeter report --range 30d --timing   # --timing 输出各阶段耗时
.build/release/tokenmeter sources                       # 数据源状态（文件数 / 禁用）
.build/release/tokenmeter activity --json               # 当前是否有会话在跑
.build/release/tokenmeter debug-activity                # 各源活动探测耗时 + 状态判定依据
```

## 测试

```bash
swift test
```

CI（`.github/workflows/ci.yml`）在每次 push 时于 macOS + Ubuntu 双平台编译并跑单测。

## 发版流程

```bash
# 1. 本地验证：构建 + 安装 + 重启，确认 App 正常
./Scripts/install.sh <新版本号>

# 2. 发版：打 tag + 推送 + 打包附件 + 创建 GitHub Release
./Scripts/release.sh <新版本号> "$(cat notes.md)"
```

附 Release Notes 写作规范见 [RELEASE_NOTES_GUIDE.md](RELEASE_NOTES_GUIDE.md)：**面向用户描述「影响 + 需要做什么」**，不写开发机数据、第三方对比与内部术语。

修改已发布版本的说明：

```bash
gh release edit vX.Y.Z --notes-file /tmp/notes.md
```

## 数据与缓存

- 扫描缓存：`~/Library/Caches/TokenMeter/scan-v1.json`
  - 按「文件大小 + mtime」指纹复用；压缩日志（zstd）额外记录帧偏移做增量解析
  - 缓存格式向后兼容（`version >= 5` 均可复用），升级不会强制重建
  - 怀疑缓存有问题时可直接删除该文件，下次启动会重建
- 自定义定价：`~/Library/Application Support/TokenMeter/pricing.json`

## 关闭自动更新检查

```bash
defaults write local.tokenmeter.menubar disableUpdateCheck -bool YES
```

## 跨平台 CLI（Windows / Linux）

Linux / Windows 只提供 CLI（菜单栏 App 为 macOS 专属）：

```bash
swift build -c release --target tokenmeter
```

- Windows：需安装 [Swift 工具链](https://www.swift.org/install/windows/)；DSH 压缩日志需 `zstd.exe` 在 PATH；中文输出先 `chcp 65001`
- SQLite 系数据源（OpenCode / Hermes / ZCode / Kiro / Copilot CLI / MiniMax / Qoder）为 macOS 专属

## 实验性：Tauri 托盘应用

`desktop/` 是 Tauri v2 托盘应用（设计目标 Windows / Linux / macOS），复用 CLI 的全部统计能力（sidecar 调 `report --json` / `activity --json`）。

> ⚠️ 仅在 macOS 上 smoke 验证过，**不作为官方支持目标**：Windows 打包链（WiX/NSIS/sidecar 权限）维护成本过高。Windows 用户请用 CLI。

构建步骤：

1. 放置 sidecar：`./Scripts/prepare-sidecar.sh`
   （Windows 手动：`swift build --target tokenmeter -c release` 后把 `tokenmeter.exe` 复制为 `desktop/src-tauri/binaries/tokenmeter-x86_64-pc-windows-msvc.exe`）
2. 安装 [Rust](https://rustup.rs) 与 tauri-cli：`cargo install tauri-cli --version ^2`
3. `cd desktop/src-tauri && cargo tauri build` → 安装包在 `target/release/bundle/`

Tauri 版不支持右键菜单、无悬浮坞。
