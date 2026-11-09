# TokenMeter

macOS 菜单栏（状态栏）token 用量统计器，灵感来自 [CodeBurn](https://codeburn.app/zh-CN/docs/menubar)：
常驻菜单栏显示**当日含缓存 token 总量 + 预估费用**，点开展示按工具 / 按模型 / 每日趋势的明细。
**纯本地运行**：只读取本机各 agent harness 的会话日志，不上传任何数据。

## 功能

- 菜单栏常驻：`⬢ 4239.4万 · $2.04`（当日含缓存总量 + 预估费用），每 5 分钟自动刷新；
  **燃烧状态**：检测到任一 harness 日志近 2 分钟有写入（会话进行中）时，图标变为橙色小火苗 🔥，面板头部显示正在燃烧的工具；空闲 2 分钟后恢复默认图标
- 面板（点击菜单栏图标）：
  - 范围切换：今天 / 昨天 / 近 7 天 / 近 30 天 / 本月 / 上月 / 全部（两行分段选择器，按系统本地时区）
  - 口径切换：含缓存 / 不含缓存（影响用量与占比；费用按分量计价不受影响），选择会记住
  - 总览卡片：用量、预估费用、缓存命中率（= 缓存读 / (输入 + 缓存读)）
  - 按工具（agent harness）条形榜：token 量、占比、费用
  - 按模型榜：token 量、占比、费用、来源工具
  - 每日用量柱状图：固定近 30 天（缺失日补零），与所选范围无关
  - 数据源诊断不在面板展示；用 CLI `tokenmeter sources` 查看（文件数 / 禁用 / 说明）
- CLI：`tokenmeter report [--range today|7d|30d|all] [--json] [--exclude-cache]`、`tokenmeter sources`
- 文件级扫描缓存：6.9GB 的 Codex 日志首次扫描约 2 分钟（并行），之后增量秒级

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
| CC Switch（默认关闭） | `~/.cc-switch/cc-switch.db` 的 `proxy_request_logs` | 代理层镜像日志；默认关闭是因为这些请求通常也记录在 Claude/Codex 自身日志里，开启会重复计数 |

所有来源均为「存在即扫描」：本机没有对应日志时自动跳过，不影响其他来源。
Cursor、Gemini CLI、Trae、Grok Bot 的本地日志不含可解析的 token 级用量（云端计费 / 加密库），未接入。
新增来源只需实现 `TokenMeterCore.UsageSource` 协议；日志格式变化请提 `new-source` issue。

### 统计口径说明

- **含缓存** = 输入 + 输出 + 缓存读 + 缓存写（= 请求的 prompt + completion 总量）
- **不含缓存** = 纯新鲜输入 + 输出（缓存读、缓存写都不计）
- 缓存读 / 缓存写分别按各家官方缓存单价计费；不同统计工具对「缓存写是否算新鲜输入」处理不同，TokenMeter 两种口径同时提供、可一键切换

## 安装与运行

```bash
./Scripts/install.sh        # 构建 + 安装到 /Applications 并启动
# 或手动：
./Scripts/build_app.sh      # 产出 build/TokenMeter.app 与 build/tokenmeter
open build/TokenMeter.app
```

要求 macOS 14+（MenuBarExtra / Swift Charts），Xcode Command Line Tools。
开机自启：系统设置 → 通用 → 登录项 → 添加 TokenMeter。

CLI（可不装 App 直接用）：

```bash
build/tokenmeter report                 # 今天
build/tokenmeter report --range 30d     # 近 30 天
build/tokenmeter report --range all --json
build/tokenmeter sources
```

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

## 实现与目录

```
Package.swift                  SwiftPM：TokenMeterCore 库 + tokenmeter CLI + TokenMeterApp
Sources/TokenMeterCore/        模型/聚合/价格/扫描缓存/行读取器
Sources/TokenMeterCore/Sources/  各 harness 解析器（UsageSource 协议）
Sources/tokenmeter/            CLI
Sources/TokenMeterApp/         SwiftUI MenuBarExtra 面板
Scripts/build_app.sh           release 构建 + 组装 .app + ad-hoc 签名
Scripts/install.sh             安装到 /Applications
.research/                     官方定价页抓取存档（定价依据）
```

扫描缓存：`~/Library/Caches/TokenMeter/scan-v1.json`（按 文件大小+mtime 指纹增量复用）。
配置：`~/Library/Application Support/TokenMeter/pricing.json`。

## 已知限制

- Cursor、Gemini CLI、CodeBuddy、Pi、Grok、OpenClaw、Kimi、Antigravity 无可解析的 token 级本地日志，未接入；CC Switch 源默认关闭防重复计数
- **Trae / Trae SOLO CN 无法支持**：`ModularData/ai-agent/database.db` 为加密库（文件头非 SQLite），其余仅 Electron 会话日志
- 费用为**估算**：按官方公开单价 × 本地日志口径折算，不等于实际账单（折扣、Batch、区域加价、高峰时段等未计入）
- Codex `token_count` 为会话内增量事件，极早期版本日志若无该事件则统计不到
- 首次扫描大日志（数 GB + 数千个 zstd 压缩会话）约 2–5 分钟，期间菜单栏显示 `…`；之后走文件级缓存，增量秒级
- `codex-auto-review`（Codex 内部自动审查模型）官方无公开单价，默认记 0，可在 pricing.json 补

## 更新与发布

- **发版流程**：`./Scripts/release.sh 0.2.0 "变更说明"` 一条命令完成——按新版本号构建、打并推送 `v0.2.0` tag、打包 `TokenMeter.app.zip` 与 `tokenmeter.zip` 附件、创建 GitHub Release；**Watch 了仓库的用户会收到 GitHub 通知**。
- **应用内更新检查**：启动时及每 20 小时匿名 GET 一次 GitHub Releases API（仅比对版本号，不上传任何数据）；发现新版本时面板顶部显示提示条、右上角出现橙色更新图标，点击跳转 Release 下载页，**不自动替换二进制**；无新版本时不显示任何更新入口。关闭检查：`defaults write local.tokenmeter.menubar disableUpdateCheck -bool YES`。
- **手动更新**：从 Releases 下载 `TokenMeter.app.zip` 替换旧 App；或拉源码后 `./Scripts/install.sh`。

## 许可

MIT License（见 [LICENSE](LICENSE)）。价格表数据来源于各厂商公开定价页，仅用于本地估算。
