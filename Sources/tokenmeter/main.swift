import Foundation
import TokenMeterCore

func parseArgs(_ args: [String]) -> (command: String, range: RangeKind, json: Bool, noCache: Bool,
                                     excludeCache: Bool, out: String?, limit: Int, interval: Double) {
    var command = "report"
    var range: RangeKind = .today
    var json = false
    var noCache = false
    var excludeCache = false
    var out: String?
    var limit = 10
    var interval = 5.0
    var i = 0
    var positional: [String] = []
    while i < args.count {
        let a = args[i]
        switch a {
        case "check-update":
            let appPlist = "/Applications/TokenMeter.app/Contents/Info.plist"
            let current = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
                ?? (NSDictionary(contentsOfFile: appPlist)?["CFBundleShortVersionString"] as? String)
                ?? "未知"
            print("当前版本: \(current)")
            let sem = DispatchSemaphore(value: 0)
            Task.detached {
                do {
                    let latest = try await UpdateInfo.fetchLatest()
                    print("最新版本: \(latest.version)（通道: \(latest.channel)）")
                    if let u = latest.pageURL { print("发布页:   \(u.absoluteString)") }
                    if let a = latest.assetURL { print("安装包:   \(a.absoluteString)") } else { print("安装包:   无（该通道取不到，可手动下载）") }
                    print(UpdateInfo.isNewer(latest.version, than: current) ? "结果:     有新版本" : "结果:     已是最新")
                } catch {
                    print("检查失败: \(error)")
                }
                sem.signal()
            }
            sem.wait()
            exit(0)

        case "hook-event":
            let event = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "Unknown"
            HookEvent.record(event: event)
            exit(0)
        case "hook-install":
            HookEvent.install(apply: CommandLine.arguments.contains("--apply"))
            exit(0)
        case "debug-activity":
            if let hook = ActivityDetector.claudeHookState() {
                print("  claude-hook   \(hook.running ? "运行中" : "已结束")（hooks 事件：\(Int(Date().timeIntervalSince(hook.at)))s 前）")
            } else {
                print("  claude-hook   未启用（回退日志解析）")
            }
            if let vault = ActivityDetector.newestClaudeProjectPath() {
                let has = ActivityDetector.vaultHasClaudianPlugin(vault)
                print("  claude-vault  \(vault)  装 Claudian=\(has ? "是" : "否")")
            }
            if let running = ActivityDetector.claudeTaskRunning() {
                print("  claude-task   \(running ? "运行中" : "已结束")（日志尾部 stop_reason 判定）")
            }
            if let wb = ActivityDetector.workBuddyState() {
                let label = ["运行中", "待阅读", "空闲"][max(0, min(2, wb))]
                let traces = ActivityDetector.workBuddyTracesActive() ? "trace 正在写" : "trace 无近期写入"
                print("  wb-state      \(label)（DB 状态 + \(traces)）")
            }
            if let cs = ActivityDetector.codexTurnState() {
                let age = cs.lastActive.map { Int(Date().timeIntervalSince($0)) }.map { "\($0)s 前" } ?? "-"
                print("  codex-turn    \(cs.running ? "运行中" : "已结束")（sqlite turn 状态，最近活动 \(age)）")
            }
            if let running = DshSource.isTaskRunning() {
                print("  dsh-task      \(running ? "运行中" : "已结束")（会话锁 + 日志尾部事件）")
            } else {
                print("  dsh-task      无法判断（回退 mtime）")
            }
            for (name, ms) in ActivityDetector.timingBreakdown() {
                print(String(format: "  %-12s %6.1f ms", (name as NSString).utf8String!, ms))
            }
            exit(0)
        case "--range", "-r":
            i += 1
            if i < args.count {
                switch args[i] {
                case "today": range = .today
                case "yesterday": range = .yesterday
                case "7d": range = .d7
                case "30d": range = .d30
                case "month", "thismonth", "mtd": range = .thisMonth
                case "lastmonth": range = .lastMonth
                case "all": range = .all
                default: break
                }
            }
        case "--json": json = true
        case "--no-cache": noCache = true
        case "--exclude-cache": excludeCache = true
        case "--help", "-h", "help":
            command = "help"
        case "--out", "-o":
            i += 1
            if i < args.count { out = args[i] }
        case "--limit", "-n":
            i += 1
            if i < args.count, let v = Int(args[i]), v > 0 { limit = v }
        case "--interval":
            i += 1
            if i < args.count, let v = Double(args[i]), v > 0 { interval = v }
        default:
            if !a.hasPrefix("-") { positional.append(a) }
        }
        i += 1
    }
    if command != "help", let first = positional.first { command = first }
    return (command, range, json, noCache, excludeCache, out, limit, interval)
}

func pad(_ s: String, _ w: Int) -> String {
    // 中文宽度近似：非 ASCII 记 2 列
    var width = 0
    for sc in s.unicodeScalars { width += sc.value < 128 ? 1 : 2 }
    let padCount = max(0, w - width)
    return s + String(repeating: " ", count: padCount)
}

let opts = parseArgs(Array(CommandLine.arguments.dropFirst()))

@discardableResult
func phase<T>(_ label: String, _ block: () -> T) -> T {
    let t0 = Date()
    let value = block()
    FileHandle.standardError.write(Data(String(format: "  %-14s %7.1f ms\n", (label as NSString).utf8String!, Date().timeIntervalSince(t0) * 1000).utf8))
    return value
}
let verbose = CommandLine.arguments.contains("--timing")
if opts.command == "help" {
    print("""
    TokenMeter CLI — 本机 AI 编程工具的 token 用量与费用统计

    用法:
      tokenmeter [report] [选项]              今日用量报告（默认命令）
      tokenmeter top [--limit N] [--range R]  排行：模型 / 项目 / 工具
      tokenmeter export [--out 文件.csv]      导出明细 CSV（默认输出到 stdout）
      tokenmeter watch [--interval 秒]        实时刷新（Ctrl-C 退出）
      tokenmeter verify                       数据体检（可疑数字、缺价格等）
      tokenmeter sources                      各数据源状态与最后写入
      tokenmeter activity [--json]            当前在跑哪些工具
      tokenmeter check-update                 检查新版本
      tokenmeter hook-install [--apply]       安装 Claude Code 钩子

    选项:
      -r, --range today|yesterday|7d|30d|month|lastmonth|all   时间范围（默认 today）
          --json          输出 JSON
          --exclude-cache 用不含缓存口径
          --no-cache      忽略扫描缓存（强制全量重扫）
          --timing        打印各阶段耗时
          --out PATH      导出文件路径
      -n, --limit N       排行条数（默认 10）
          --interval S    实时刷新间隔秒数（默认 5）

    示例:
      tokenmeter top -n 5
      tokenmeter export -r 7d --out ~/Desktop/7天.csv
      tokenmeter watch --interval 3
    """)
    exit(0)
}
Aggregator.timingEnabled = verbose
func timed<T>(_ label: String, _ block: () -> T) -> T { verbose ? phase(label, block) : block() }

var cache = timed("cache-load") { opts.noCache ? ScanCache() : ScanCache.load() }
let scanned = timed("scan") { Aggregator.scan(cache: &cache) }
if !opts.noCache { timed("cache-save") { cache.save() } }
let pricing = PricingTable.load()
let summary = timed("summarize") { Aggregator.summarize(buckets: scanned.buckets, range: opts.range, pricing: pricing, statuses: scanned.statuses) }

switch opts.command {
case "activity":
    let active = ActivityDetector.activeSources()
    if opts.json {
        let payload: [String: Any] = ["burning": !active.isEmpty, "sources": active]
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
        print(String(decoding: data, as: UTF8.self))
    } else if active.isEmpty {
        print("当前无活跃会话（近 2 分钟无日志写入）")
    } else {
        print("正在燃烧 token 的会话：\(active.joined(separator: ", "))")
    }
case "verify":
    var issues = DataCheck.run(buckets: scanned.buckets, statuses: scanned.statuses)
    issues += DataCheck.pricingIssues(buckets: scanned.buckets, pricing: pricing)
    if opts.json {
        let payload: [String: Any] = ["issues": issues.map {
            ["level": $0.level.rawValue, "title": $0.title, "detail": $0.detail]
        }]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
            print(String(decoding: data, as: UTF8.self))
        }
    } else if issues.isEmpty {
        print("数据体检通过：未发现异常（共检查 \(scanned.buckets.count) 条分桶）")
    } else {
        print("数据体检发现 \(issues.count) 项问题：")
        for i in issues {
            print("  [\(i.level.rawValue)] \(i.title)")
            print("        \(i.detail)")
        }
    }
case "export":
    let csv = UsageCSV.make(buckets: scanned.buckets, range: opts.range, pricing: pricing,
                            includeCache: true)
    if let out = opts.out {
        let path = NSString(string: out).expandingTildeInPath
        do {
            try csv.write(toFile: path, atomically: true, encoding: .utf8)
            let rows = max(0, csv.split(separator: "\n").count - 1)
            print("已导出 \(rows) 行到 \(path)")
        } catch {
            FileHandle.standardError.write(Data("导出失败：\(error.localizedDescription)\n".utf8))
            exit(1)
        }
    } else {
        print(csv, terminator: "")
    }
case "top":
    let topDisp: (TokenCounts) -> Int64 = { c in opts.excludeCache ? c.input + c.output : c.total }
    print("TokenMeter · \(opts.range.label) · 前 \(opts.limit)")
    print(String(repeating: "-", count: 64))
    let groups: [(String, [(String, TokenCounts, Double)])] = [
        ("模型", summary.models.map { ($0.model, $0.counts, $0.cost) }),
        ("项目", summary.projects.map { ($0.project, $0.counts, $0.cost) }),
        ("工具", summary.tools.map { ($0.tool, $0.counts, $0.cost) }),
    ]
    for (title, items) in groups where !items.isEmpty {
        let total = max(1, items.reduce(Int64(0)) { $0 + topDisp($1.1) })
        print("")
        print("按\(title)：")
        for item in items.sorted(by: { topDisp($0.1) > topDisp($1.1) }).prefix(opts.limit) {
            let share = String(format: "%5.1f%%", Double(topDisp(item.1)) / Double(total) * 100)
            print("  \(pad(item.0, 28)) \(pad(Fmt.tokens(topDisp(item.1)), 12)) \(share)  \(pad(Fmt.cost(item.2), 10))")
        }
    }
case "watch":
    setvbuf(stdout, nil, _IOLBF, 0)   // 行缓冲：重定向到文件时也能立刻看到每帧
    FileHandle.standardError.write(Data("每 \(Int(opts.interval)) 秒刷新，Ctrl-C 退出\n".utf8))
    let clock = DateFormatter()
    clock.dateFormat = "HH:mm:ss"
    while true {
        var c = opts.noCache ? ScanCache() : ScanCache.load()
        let sc = Aggregator.scan(cache: &c)
        if !opts.noCache { c.save() }
        let p = PricingTable.load()
        let sm = Aggregator.summarize(buckets: sc.buckets, range: opts.range, pricing: p, statuses: sc.statuses)
        print("\u{1B}[2J\u{1B}[H", terminator: "")
        let active = ActivityDetector.activeSources()
        let burning = active.isEmpty ? "" : "  ·  燃烧中: \(active.joined(separator: ", "))"
        print("TokenMeter · \(opts.range.label) · \(clock.string(from: Date()))\(burning)")
        print(String(repeating: "-", count: 64))
        let shown = opts.excludeCache ? sm.counts.input + sm.counts.output : sm.counts.total
        print("总用量 \(Fmt.tokens(shown)) tokens · 预估 \(Fmt.cost(sm.cost)) · 缓存命中 \(Fmt.percent(sm.cacheHitRate))")
        print("")
        for t in sm.tools.prefix(8) {
            let v = opts.excludeCache ? t.counts.input + t.counts.output : t.counts.total
            print("  \(pad(t.tool, 16)) \(pad(Fmt.tokens(v), 12)) \(pad(Fmt.cost(t.cost), 10))")
        }
        Thread.sleep(forTimeInterval: opts.interval)
    }
case "debug-dsh":
    let path = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : ""
    DshSource().debugParse(path: path)
case "sources":
    print("数据来源：")
    for s in summary.sourceStatuses {
        let flag = s.enabled ? "启用" : "禁用"
        let note = s.note.map { "（\($0)）" } ?? ""
        print("  \(pad(s.id, 14)) \(pad(s.name, 14)) \(flag)  文件 \(s.files)\(note)")
    }
case "report":
    if opts.json {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(summary) {
            print(String(decoding: data, as: UTF8.self))
        }
        break
    }
    let rangeLabel: String
    let sk = opts.range.startDayKey()
    let ek = opts.range.endDayKey()
    if let sk, let ek {
        rangeLabel = sk == ek ? "\(opts.range.label)（\(sk)）" : "\(opts.range.label)（\(sk) ~ \(ek)）"
    } else if let sk {
        rangeLabel = "\(opts.range.label)（自 \(sk)）"
    } else {
        rangeLabel = opts.range.label
    }
    let disp: (TokenCounts) -> Int64 = { c in opts.excludeCache ? c.input + c.output : c.total }
    let totalDisp = max(1, disp(summary.counts))
    let shareOf: (TokenCounts) -> Double = { Double(disp($0)) / Double(totalDisp) }
    print("TokenMeter · \(rangeLabel) · \(opts.excludeCache ? "不含缓存" : "含缓存")口径")
    print(String(repeating: "-", count: 64))
    print("总用量(\(opts.excludeCache ? "不含缓存" : "含缓存"))  \(pad(Fmt.tokens(disp(summary.counts)) + " tokens", 18)) 预估费用 \(pad(Fmt.cost(summary.cost), 10)) 缓存命中率 \(Fmt.percent(summary.cacheHitRate))")
    print("  输入 \(Fmt.tokens(summary.counts.input)) · 输出 \(Fmt.tokens(summary.counts.output)) · 缓存读 \(Fmt.tokens(summary.counts.cacheRead)) · 缓存写 \(Fmt.tokens(summary.counts.cacheWrite)) · 调用 \(summary.requests) 次")
    print("")
    print("按工具：")
    if summary.tools.isEmpty { print("  （无数据）") }
    for t in summary.tools {
        print("  \(pad(t.tool, 16)) \(pad(Fmt.tokens(disp(t.counts)), 12)) \(pad(Fmt.percent(shareOf(t.counts)), 8)) \(pad(Fmt.cost(t.cost), 10)) \(t.requests) 次")
    }
    print("")
    print("按模型：")
    if summary.models.isEmpty { print("  （无数据）") }
    for m in summary.models {
        print("  \(pad(m.model, 34)) \(pad(Fmt.tokens(disp(m.counts)), 12)) \(pad(Fmt.percent(shareOf(m.counts)), 8)) \(pad(Fmt.cost(m.cost), 10)) [\(m.tools.joined(separator: ","))]")
    }
    print("")
    print("按项目：")
    if summary.projects.isEmpty { print("  （无数据）") }
    for p in summary.projects.prefix(10) {
        print("  \(pad(p.project, 28)) \(pad(Fmt.tokens(disp(p.counts)), 12)) \(pad(Fmt.percent(p.share), 8)) \(Fmt.cost(p.cost))  [\(p.tools.joined(separator: ","))]")
    }
    print("")
    print("每日：")
    for d in summary.days.suffix(14) {
        print("  \(d.day)  \(pad(Fmt.tokens(disp(d.counts)), 12)) \(Fmt.cost(d.cost))")
    }
    if !summary.unpricedModels.isEmpty {
        print("")
        print("未定价模型（费用记 0，可在 pricing.json 补充）：\(summary.unpricedModels.joined(separator: ", "))")
    }
    print("")
    print("来源：")
    for s in summary.sourceStatuses {
        let flag = s.enabled ? "ok" : "off"
        let note = s.note.map { " \($0)" } ?? ""
        print("  [\(flag)] \(pad(s.id, 14)) 文件 \(s.files)\(note)")
    }
default:
    print("用法: tokenmeter [report|sources|activity|debug-activity] [--range today|yesterday|7d|30d|month|lastmonth|all] [--json] [--no-cache] [--exclude-cache]")
}
