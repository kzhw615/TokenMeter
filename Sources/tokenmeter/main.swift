import Foundation
import TokenMeterCore

func parseArgs(_ args: [String]) -> (command: String, range: RangeKind, json: Bool, noCache: Bool, excludeCache: Bool) {
    var command = "report"
    var range: RangeKind = .today
    var json = false
    var noCache = false
    var excludeCache = false
    var i = 0
    var positional: [String] = []
    while i < args.count {
        let a = args[i]
        switch a {
        case "debug-activity":
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
        default:
            if !a.hasPrefix("-") { positional.append(a) }
        }
        i += 1
    }
    if let first = positional.first { command = first }
    return (command, range, json, noCache, excludeCache)
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
