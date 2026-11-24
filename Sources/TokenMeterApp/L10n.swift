import Foundation

/// 轻量本地化：中文串作为 key，英文查表；查不到就回退中文。
/// 不引入 .strings 体系是因为界面文案本来就写死在代码里，用字典最直观也最好维护。
enum L10n {
    /// 跟随系统 / 强制中文 / 强制英文
    static var mode: String {
        UserDefaults.standard.string(forKey: "appLanguage") ?? "auto"
    }

    static var isEnglish: Bool {
        switch mode {
        case "en": return true
        case "zh": return false
        default:
            let pref = Locale.preferredLanguages.first ?? "zh"
            return pref.lowercased().hasPrefix("en")
        }
    }

    static func t(_ zh: String) -> String {
        guard isEnglish else { return zh }
        return en[zh] ?? zh
    }

    /// 带参数：`L10n.t("上次统计") + " " + time`
    static func t(_ zh: String, _ arg: String) -> String {
        guard isEnglish else { return zh + arg }
        return (en[zh] ?? zh) + arg
    }

    static let en: [String: String] = ["趋势": "Trend",
"日历": "Calendar",
"工具": "Tools",
"模型": "Models",
"少": "Less",
"多": "More",
"按工具": "By tool",
"按模型": "By model",
"按项目": "By project",
"每日用量 · 按工具": "Daily usage · by tool",
"每日用量 · 按模型": "Daily usage · by model",
"逐小时用量": "Hourly usage",
"使用习惯 · 周几 × 小时": "Habits · weekday × hour",
"颜色越深表示那个时段用量越大；横向是小时，纵向是周几":
            "Darker means more usage in that slot; hours horizontal, weekdays vertical",
"该范围内暂无数据": "No data in this range",
"当天没有用量记录": "No usage recorded that day",
"全部模型": "All models",
"全部工具": "All tools",
"刷新": "Refresh",
"导出": "Export",
"设置": "Settings",
"检查更新": "Check for updates",
"退出": "Quit",
"检查中…": "Checking…",
"下载页": "Download",
"新版本 v": "New version v",
"可用": " available",
"正在下载更新…": "Downloading update…",
"正在校验 sha256…": "Verifying sha256…",
"正在替换应用…": "Replacing app…",
"即将重启…": "Restarting…",
"上次统计": "Last scan",
"未定价模型（费用记 0）：": "Unpriced models (cost counted as 0): ",
"按当前速度预计本月": "Forecast for this month at current pace",
"对比": "vs ",
"用量": "Usage",
"费用": "Cost",
"总用量": "Total",
"预估费用": "Est. cost",
"缓存命中率": "Cache hit rate",
"输入": "Input",
"输出": "Output",
"缓存读": "Cache read",
"缓存写": "Cache write",
"调用": "calls",
"次": "calls",
"含缓存": "With cache",
"不含缓存": "Without cache",
"今天": "Today",
"昨天": "Yesterday",
"近 7 天": "7 days",
"近 30 天": "30 days",
"本月": "This month",
"上月": "Last month",
"全部": "All",
"燃烧中": "Burning",
"缓存命中": "Cache hit",
"外观": "Appearance",
"主题色": "Theme",
"菜单栏显示": "Menu bar",
"用量 + 费用": "Usage + cost",
"仅用量": "Usage only",
"仅费用": "Cost only",
"仅图标": "Icon only",
"消耗速度": "Burn rate",
"自动": "Auto",
"总是显示": "Always",
"不显示": "Never",
"自动：菜单栏拥挤时只显示用量，腾出宽度":
            "Auto: hide the rate when the menu bar is crowded",
"面板外观": "Panel theme",
"跟随系统": "System",
"深色": "Dark",
"浅色": "Light",
"玻璃不透明度": "Glass opacity",
"登录时自动启动": "Launch at login",
"侧边悬浮坞": "Side dock",
"位置": "Position",
"关闭": "Off",
"左侧": "Left",
"右侧": "Right",
"开启后可从屏幕边缘拖出，松手自动吸附；双击回到默认位置，单击展开面板。":
            "Drag from the screen edge to detach; it snaps back on release. Double-click to reset, click to open the panel.",
"预算提醒": "Budget alerts",
"达到 80% 和 100% 时发送系统通知；填 0 表示不提醒。":
            "Sends a system notification at 80% and 100%. Set 0 to disable.",
"今日": "Today",
"本月预算": "Monthly budget",
"悬浮坞显示的工具": "Dock tools",
"材质": "Material",
"黑色": "Black",
"液态玻璃": "Liquid glass",
"显示工具状态": "Show tool status",
"点名称可隐藏，灰色为当前不显示。": "Click a name to hide it; gray means hidden.",
"模型价格": "Model pricing",
"数据来源": "Data sources",
"还没有扫描结果": "No scan results yet",
"数据体检": "Health check",
"各工具状态是怎么判断的": "How tool states are detected",
"其余工具：依据日志写入时间推断（这些工具没有提供真实状态）":
            "Other tools: inferred from log write times (they expose no real state)",
"关于": "About",
"打开数据目录": "Open data folder",
"所有数据均来自本机日志，不会上传到任何服务器。":
            "All data comes from local logs; nothing is uploaded.",
"模型名称": "Model name",
"编辑单价": "Edit prices",
"保存": "Save",
"加一行": "Add row",
"恢复内置": "Reset to built-in",
"删除这一行": "Delete row",
"单位：美元 / 百万 tokens；名称按子串匹配，从上到下先命中先生效。":
            "USD per 1M tokens. Names match by substring; first hit wins.",
"权限": "Permissions",
"打开面板": "Open panel",
"关闭面板": "Close panel",
"立即刷新统计": "Refresh now",
"检查更新…": "Check for updates…",
"退出 TokenMeter": "Quit TokenMeter",
"全部标为已读": "Mark all as read",
"预算提醒通知": "Budget alert",
"TokenMeter 预算提醒": "TokenMeter budget alert",
"今日费用": "Today's cost",
"已达预算": "reached budget",
"的": " at ",
"（已超支）": " (over budget)",
"运行中": "Running",
"待阅读": "Unread",
"空闲": "Idle",
"正在统计历史用量": "Scanning history",
"首次运行或日志有大量变动时需要几分钟；已完成的文件会被缓存，之后是秒级增量。":
            "First run or after big log changes takes a few minutes; afterward it's incremental.",
"剩约": "~",
"已": "",
"秒": "s",
"下载": "Download",
"稍后": "Later",
"总计": "Total",
"时": "h",
" 天有记录": " days with data",
"语言": "Language",
"跟随系统语言": "System",
"中文": "Chinese",
"English": "English",
"个模型": " models",
"行": "rows",
"用量占比": "Share",
"费用占比": "Cost share",
"立即检查是否有新版本": "Check for updates now",
"把当前范围的明细导出成 CSV": "Export the current range as CSV",
"设置…": "Settings…",
"标记全部已读": "Mark all as read",
"用量（含缓存）": "Usage (with cache)",
"用量（不含缓存）": "Usage (no cache)",
"输入 tokens": "Input",
"点按格子查看当天明细": "Click a cell to see that day",
"上一周期": "previous period",
"未归属": "Unassigned",
"展开": "Expand",
"收起": "Collapse",
"次调用": "calls",
"秒前": "s ago",
"可用，点击一键更新": " is available — click to update",
"退出 TokenMeter？": "Quit TokenMeter?",
"退出后菜单栏的用量显示与燃烧状态会停止更新；重新打开 App 即可恢复。":
            "Usage and burn status stop updating in the menu bar. Reopen the app to resume.",
"取消": "Cancel",
"正在统计历史用量…": "Scanning history…",
"分钟": " min",
    ]
}
