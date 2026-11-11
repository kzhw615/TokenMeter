# TokenMeter

macOS 菜单栏 token 用量统计器，灵感来自 [CodeBurn](https://codeburn.app/zh-CN/docs/menubar)：
常驻菜单栏显示**当日含缓存 token 总量 + 预估费用**，左键点开完整面板，右键出功能菜单。
支持 **13 个 AI 编程工具**的用量统计与实时任务状态，**纯本地运行**：只读本机会话日志，不上传任何数据。

## 功能

- **菜单栏**：`⬢ 1234.5万 · $1.23`（当日含缓存总量 + 预估费用）
  - **左键**打开面板 / **右键**（或 Ctrl+点击）弹出菜单：打开面板、设置…、立即刷新统计（⌘R）、检查更新…、退出（⌘Q）
  - **燃烧动画**：有会话在跑时图标变为彩色火苗 🔥，16 帧动画；火苗**尺寸随实时速率连续变大**（13pt→20pt），≥15K tokens/s 切换旺盛版（侧舌+白热芯+火星）
  - 空闲时完全停止动画定时器，不占 CPU
- **面板**（左键点击菜单栏图标）：
  - 范围切换：今天 / 昨天 / 近 7 天 / 近 30 天 / 本月 / 上月 / 全部（一行分段选择器，带弹性滑块，按系统本地时区）
  - 口径切换：含缓存 / 不含缓存（影响用量与占比；费用按分量计价不受影响），选择会记住
  - 总览卡片：用量、预估费用、缓存命中率（= 缓存读 / (输入 + 缓存读)）
  - 按工具（agent harness）条形榜：token 量、占比、费用
  - 按模型榜：token 量、占比、费用、来源工具
  - 按项目榜：从日志 cwd / 项目目录解析仓库名（含 dsh 的 unicode 转义目录名解码），回答"哪个 repo 最烧钱"
  - 每日用量柱状图：固定近 30 天（缺失日补零），与所选范围无关
  - 逐小时用量图：今天/昨天范围为当日 24 小时明细；其他范围为按钟点分布汇总
  - 统计进行时显示**真实进度条**（已处理 / 总文件数）+ 灰色骨架屏占位，不再空白干等
  - 键盘：`⌘R` 刷新、`Esc` 关闭、`⌘,` 打开设置；切换别的应用时自动收起
  - 悬浮坞底部工具状态列：13 个 harness 全部配官方品牌图标，三态指示灯（运行/待阅读/空闲）
  - 侧边悬浮坞：贴边吸附在屏幕左/右边缘的**纯黑舱体**（凹弧喇叭口融进屏边、始终置顶、全空间可见、四角全透明），显示今日用量/费用/燃烧速率或命中率；按住拖拽脱离为圆角浮块，松手滑向较近一侧并形变融合；设置可切换左/右、位置记忆、双击回位；**点击弹出完整大面板窗口**，解决菜单栏空间被其他 App 挤压的问题
  - 数据源诊断不在面板展示（避免干扰），需要时用 CLI `tokenmeter sources` 查看
- **CLI**：`tokenmeter report [--range today|yesterday|7d|30d|month|lastmonth|all] [--json] [--exclude-cache]`、`sources`、`activity [--json]`（排查参数见 [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)）
- **文件级扫描缓存 + 增量解析**：首次扫描需要几分钟（几 GB 历史日志，并行解压解析）；之后日常刷新**零点几秒**完成
  - 压缩日志（DSH 的 zstd）按**帧边界增量解析**：只解压新追加的帧，几 MB 的活跃会话几乎零成本
  - 活跃文件的缓存判定允许「比上次更大」（append-only），不会因为文件一直在写就每次全量重解析
  - 缓存格式向后兼容，升级新版本**不会**触发全量重建
- **日志变化自动刷新**：监听各工具日志目录，按需节流——面板展开 20s / 燃烧中 45s / 完全空闲 120s（不会为了刷新而持续轮询耗电）
- 预算告警：设置日/月预算（USD），达到 80% / 100% 发系统通知（每档每周期一次）；超支时菜单栏文字变红；面板显示预算进度条
- **独立设置窗口**（页脚「设置」/右键菜单/`⌘,` 打开）：外观（6 种主题色、菜单栏显示样式、开机自启）、侧边悬浮坞、预算提醒、悬浮坞显示的工具、模型价格表编辑器（直接写 pricing.json，可一键恢复内置表）、关于

## 支持的数据源

| 来源 | 日志位置 | 取数字段 |
| --- | --- | --- |
| Claude Code | `~/.claude/projects/**/*.jsonl`（含 subagents） | `type=assistant` 的 `message.usage{input_tokens,cache_creation_input_tokens,cache_read_input_tokens,output_tokens}`，按 message.id 去重 |
| Codex CLI / Desktop | `~/.codex/sessions/**/rollout-*.jsonl` 与 `.jsonl.zst`（新版会话为 zstd 压缩）、`archived_sessions/` | `event_msg.payload.type=token_count` 的 `info.last_token_usage`（单次增量），模型取 `session_meta.payload.model` / `thread_settings.model` / `base_instructions.provenance.model` |
| DSH（DeepSeek Harness） | `~/.dsh/sessions/*/*/session.v*.jsonl.zstd`（zstd） | `assistant/message` 事件的 `data.usage{inputTokens,outputTokens,cacheReadTokens,cacheWriteTokens}`；模型取 `data.stream` 里 finish chunk 的 `replayState.response.model` |
| WorkBuddy | `~/.workbuddy/traces/*/trace_*.jsonl` | generation span 的 `span_end.toolOutput`（原始 chat.completion 响应数组）里的 `usage{prompt_tokens, completion_tokens, prompt_tokens_details.cached_tokens/cache_write_tokens}`；被 `tracePayloadTruncated` 截断的 toolOutput 用碎片提取兜底 |
| OpenCode | `~/.local/share/opencode/opencode.db` | `message` 表 `data.tokens{input,output,reasoning,cache{read,write}}`、`data.modelID` |
| Hermes | `~/.hermes/state.db` + `~/.hermes/profiles/*/state.db` | `session_model_usage` 表（input/output/cache_read/cache_write_tokens、last_seen） |
| ZCode | `~/.zcode/cli/db/db.sqlite` | `model_usage` 表（model_id、started_at、input/output/reasoning/cache_creation/cache_read_input_tokens） |
| Kiro | `~/Library/Application Support/KiroUser/globalStorage/kiro.kiroagent/dev_data/devdata.sqlite` | `tokens_generated` 表 |
| Copilot CLI | `~/.copilot/cli/state.db` | `local_runtime_token_usage` 表 |
| MiniMax Code | `~/.minimax/runtime-state.sqlite` | `token_usage` 表 |
| Qoder | `~/.qoder*/db.sqlite`（或 `QODER_BASE_PATH`） | `chat_message.token_info/model_info` JSON 字段 |
| Reasonix | `~/.reasonix/usage.jsonl` | 每行 usage 字段 |
| Droid | `~/.factory/sessions/**` | 会话 JSON 的 `tokenUsage` 字段 |

所有来源均为「存在即扫描」：本机没有对应日志时自动跳过，不影响其他来源。
Cursor、Gemini CLI、Trae、Grok Bot 的本地日志不含可解析的 token 级用量（云端计费 / 加密库），未接入。
新增来源只需实现 `TokenMeterCore.UsageSource` 协议；日志格式变化请提 `new-source` issue。

### 统计口径说明

- **含缓存** = 输入 + 输出 + 缓存读 + 缓存写（= 请求的 prompt + completion 总量）
- **不含缓存** = 纯新鲜输入 + 输出（缓存读、缓存写都不计）
- 缓存读 / 缓存写分别按各家官方缓存单价计费；不同统计工具对「缓存写是否算新鲜输入」处理不同，TokenMeter 两种口径同时提供、可一键切换

## 安装与运行

**要求**：macOS 14 或更高版本。

1. 到 [Releases](https://github.com/kzhw615/TokenMeter/releases/latest) 下载 `TokenMeter.app.zip`
2. 解压后把 `TokenMeter.app` 拖进「应用程序」文件夹
3. 首次打开：右键点 App →「打开」（未签名应用需要这一次确认）
4. 菜单栏出现图标即成功；点图标看面板，右键出菜单

开机自启：设置窗口 → 外观 → 勾选「登录时自动启动」。

> 首次运行会扫描历史日志（几 GB，约 6–7 分钟），面板会显示进度条；之后是秒级增量刷新。
> 想从源码构建或使用 CLI，见 [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)。

CLI 用户可以只用命令行，不需要安装 App：

```bash
tokenmeter report                 # 今天
tokenmeter report --range 30d     # 近 30 天
tokenmeter report --range all --json
tokenmeter sources                # 查看数据源状态
```

## 自动更新

- 启动时检查一次（距上次检查不足 20 小时会跳过），运行期间**每天 10:00** 再检查一次
- 有新版本时，面板顶部出现提示条、右上角出现橙色更新图标
- 点「一键更新」：自动下载 → 校验完整性 → 替换应用 → 重启；失败会回滚到旧版本
- 不想更新就点 × 忽略；也可以点「下载页」自己去下载
- 只比对版本号，不上传任何数据

关闭自动检查（高级）：`defaults write local.tokenmeter.menubar disableUpdateCheck -bool YES`

## 预估价格

内置价格表取自各家**官方 API 定价页**（2026-11 抓取，USD / 1M tokens）：

- OpenAI `developers.openai.com/api/docs/pricing`：gpt-6-astra 10/50、gpt-6.1-sol 2/10、gpt-6.1-terra 1/5、gpt-6-luna 0.1/0.5（输入/输出，缓存读 0.1×、30m 缓存写 1.25×）等
- Anthropic `anthropic.com/pricing`：Opus 4.5/4.6 5/25、Sonnet 4.5 3/15、Haiku 4.5 1/5（缓存读 0.1×、写 1.25×）
- Google `ai.google.dev/gemini-api/docs/pricing`：gemini-4-argon 2/10、gemini-3.8-flash 0.75/3.75 等
- DeepSeek `api-docs.deepseek.com/quick_start/pricing`：人民币价按 7.0 汇率折算，取**空闲时段**价（高峰 ×2）；deepseek-flash 输入 1 元 / 缓存命中 0.02 元 / 输出 4 元
- 千问 `help.aliyun.com/zh/model-studio/model-pricing`：qwen3.8-max 12 元 / 36 元；缓存命中按输入价 10%、显式创建按 125%

覆盖 / 自定义：编辑 `~/Library/Application Support/TokenMeter/pricing.json`（首次启动 App 会自动生成模板），
格式为 `{"prices":[{"pattern":"子串(小写无关)","input":2,"output":10,"cacheRead":0.1,"cacheWrite":2.5}]}`，
按顺序第一个命中的 pattern 生效；未命中的模型费用记 0 并在面板/CLI 中列出。

## 已知限制

- Cursor、Gemini CLI、CodeBuddy、Pi、Grok、OpenClaw、Kimi、Antigravity 无可解析的 token 级本地日志，未接入
- **Trae / Trae SOLO CN 无法支持**：`ModularData/ai-agent/database.db` 为加密库（文件头非 SQLite），其余仅 Electron 会话日志
- 费用为**估算**：按官方公开单价 × 本地日志口径折算，不等于实际账单（折扣、Batch、区域加价、高峰时段等未计入）
- Codex `token_count` 为会话内增量事件，极早期版本日志若无该事件则统计不到
- 首次扫描大日志（数 GB + 数千个压缩会话）需要几分钟，面板显示真实进度与骨架屏；之后为秒级增量
- **任务状态是估算**：13 个工具里只有 WorkBuddy 提供真实已读回执（`sessions.unread`）；DSH 用日志尾部事件（`turn/end` 表示结束）判定；其余数据源只能靠「日志新鲜度 + 最近 10 分钟」启发式，长工具执行期间可能提前判定为结束
- `codex-auto-review`（Codex 内部自动审查模型）官方无公开单价，默认记 0，可在 pricing.json 补

## 跨平台状态

| 平台 | 状态 |
| --- | --- |
| macOS | ✅ 完整体验：菜单栏 App + CLI |
| Windows | ✅ CLI（`tokenmeter.exe`）已真机验证（Win10 19045 / Swift 6.4.2，2026-11-09）：jsonl 系数据源（Claude Code / Codex / DSH / WorkBuddy 等）可用；**不提供托盘应用**（Windows 打包链维护成本过高）；SQLite 系来源暂为 macOS 专属；DSH 压缩日志需 `zstd.exe` 在 PATH；中文输出先 `chcp 65001` |
| Linux | 🟡 CLI 同 Windows 口径；CI 每 push 在 macOS + Ubuntu 双平台编译+单测（Ubuntu 验证非 Apple 编译路径），Windows 由真机验证 |

Windows 构建：安装 [Swift 工具链](https://www.swift.org/install/windows/) 后 `swift build --target tokenmeter -c release`，产物 `.build\release\tokenmeter.exe`；中文输出请先 `chcp 65001` 切换控制台 UTF-8。WSL 内的 harness 日志扫描在规划中（Phase 3）。

## 开发与构建

想改代码、从源码构建、或自己发版？见 [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)。

本机数据位置（排查问题时有用）：

- 扫描缓存：`~/Library/Caches/TokenMeter/scan-v1.json`（按文件大小 + mtime 指纹增量复用，删掉即重建）
- 自定义定价：`~/Library/Application Support/TokenMeter/pricing.json`（删除即恢复内置价格表）

## 许可

MIT License（见 [LICENSE](LICENSE)）。价格表数据来源于各厂商公开定价页，仅用于本地估算。
