import Foundation
import TokenMeterCore

/// Claude Code hooks 的接收端。
///
/// CLI 本身没有「查询会话状态」的命令，但 hooks 会在关键节点执行我们的脚本：
///   SessionStart / UserPromptSubmit / PreToolUse / PostToolUse / Stop / SessionEnd
/// 把事件写进本地状态文件后，TokenMeter 就能**精确**知道任务在跑还是结束，
/// 不再需要靠日志时间或 Obsidian vault 去推断。
enum HookEvent {
    static var stateURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("TokenMeter", isDirectory: true)
            .appendingPathComponent("claude-state.json")
    }

    /// `tokenmeter hook-event <EventName>`：从 stdin 读 hook 的 JSON，落盘当前状态
    static func record(event: String) {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        var sessionID = ""
        var cwd = ""
        if !input.isEmpty,
           let obj = try? JSONSerialization.jsonObject(with: input) as? [String: Any] {
            sessionID = (obj["session_id"] as? String) ?? ""
            cwd = (obj["cwd"] as? String) ?? ""
        }
        let running: Bool
        switch event {
        case "Stop", "SessionEnd", "SubagentStop": running = false
        case "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse": running = true
        default: running = false
        }
        // 按会话分别记录：Claudian 等客户端会同时开多个 claude 进程，
        // 若只存「最后一个事件」，一个会话结束会误把另一个正在跑的灭掉。
        try? FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: stateURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = obj
        }
        var sessions = (root["sessions"] as? [String: Any]) ?? [:]
        let now = Date().timeIntervalSince1970
        // 清理 2 小时前的记录，避免文件无限增长
        sessions = sessions.filter { _, v in
            guard let e = v as? [String: Any], let at = (e["at"] as? Double) else { return false }
            return now - at < 7200
        }
        let key = sessionID.isEmpty ? "unknown" : sessionID
        sessions[key] = [
            "event": event,
            "running": running,
            "cwd": cwd,
            "at": now,
        ]
        root["sessions"] = sessions
        root["at"] = now
        if let data = try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]) {
            try? data.write(to: stateURL, options: .atomic)
        }
    }

    /// `tokenmeter hook-install [--apply]`：把 hook 写进 ~/.claude/settings.json
    static func install(apply: Bool) {
        let settings = NSString(string: "~/.claude/settings.json").expandingTildeInPath
        guard let exe = Bundle.main.executableURL?.resolvingSymlinksInPath().path
                ?? ProcessInfo.processInfo.arguments.first else {
            print("无法定位可执行文件路径"); return
        }
        // hook 命令必须是长期稳定的路径：优先 /usr/local/bin，其次 App 包内，最后当前可执行文件
        let supportBin = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("TokenMeter/bin/tokenmeter").path
        let candidates = [
            supportBin,
            "/usr/local/bin/tokenmeter",
            "/opt/homebrew/bin/tokenmeter",
        ]
        let cmdBase = candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? exe
        // PostToolUse 作为「心跳」：长任务期间每次工具返回都会刷新状态，避免 10 分钟无事件被误判失效。
        // 它只在工具调用结束时触发，开销可忽略。
        let events = ["SessionStart", "UserPromptSubmit", "PostToolUse", "Stop", "SessionEnd"]
        var hooks: [String: [[String: Any]]] = [:]
        for e in events {
            hooks[e] = [["hooks": [["type": "command", "command": "\(cmdBase) hook-event \(e)"]]]]
        }
        if !apply {
            print("将要写入 \(settings) 的 hooks：")
            for e in events { print("  \(e): \(cmdBase) hook-event \(e)") }
            print("\n确认无误后加 --apply 执行（会先备份为 settings.json.bak）")
            return
        }
        // 备份后合并
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: URL(fileURLWithPath: settings)),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = obj
            try? data.write(to: URL(fileURLWithPath: settings + ".bak"), options: .atomic)
        }
        var merged = (root["hooks"] as? [String: Any]) ?? [:]
        // 先清理旧版本可能写入的多余事件（只保留上面 4 个），不影响用户自己的 hook
        for (event, value) in merged {
            guard var list = value as? [[String: Any]], !events.contains(event) else { continue }
            list.removeAll { item in
                let cmds = (item["hooks"] as? [[String: Any]]) ?? []
                return cmds.contains { (($0["command"] as? String) ?? "").contains("tokenmeter hook-event ") }
            }
            merged[event] = list.isEmpty ? nil : list
        }
        for (event, entry) in hooks {
            var list = (merged[event] as? [[String: Any]]) ?? []
            // 已经有同类条目则跳过（避免重复安装）；否则追加，保留用户原有 hook
            let already = list.contains { item in
                let cmds = (item["hooks"] as? [[String: Any]]) ?? []
                return cmds.contains { (($0["command"] as? String) ?? "").contains("tokenmeter hook-event \(event)") }
            }
            if !already { list.append(contentsOf: entry) }
            merged[event] = list
        }
        root["hooks"] = merged
        if let data = try? JSONSerialization.data(withJSONObject: root,
                                                 options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: settings), options: .atomic)
            print("已写入 hooks（备份：\(settings).bak）")
        } else {
            print("写入失败")
        }
    }
}
