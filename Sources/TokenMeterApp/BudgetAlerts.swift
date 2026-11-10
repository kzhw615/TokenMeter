#if os(macOS)
import Foundation
import UserNotifications
import TokenMeterCore

/// 预算告警：日/月预算上限，达到 80% / 100% 时发系统通知（每档每天/每月只提醒一次），
/// 菜单栏文字变红 + 面板显示进度条
extension AppModel {
    static let budgetLevels: [Double] = [0.8, 1.0]

    var dailyBudget: Double {
        get { UserDefaults.standard.double(forKey: "dailyBudget") }
        set {
            UserDefaults.standard.set(newValue, forKey: "dailyBudget")
            objectWillChange.send()
            if newValue > 0 { Self.requestNotificationAuth() }
            evaluateBudget()
        }
    }

    var monthlyBudget: Double {
        get { UserDefaults.standard.double(forKey: "monthlyBudget") }
        set {
            UserDefaults.standard.set(newValue, forKey: "monthlyBudget")
            objectWillChange.send()
            if newValue > 0 { Self.requestNotificationAuth() }
            evaluateBudget()
        }
    }

    /// 今日费用是否已超日预算（菜单栏变红用）
    var budgetOver: Bool {
        let b = dailyBudget
        guard b > 0 else { return false }
        return (summariesByRange[.today]?.cost ?? 0) >= b
    }

    static func requestNotificationAuth() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
    }

    func evaluateBudget() {
        guard let today = summariesByRange[.today]?.cost,
              let month = summariesByRange[.thisMonth]?.cost else { return }
        let dayKey = RangeKind.today.startDayKey() ?? ""
        let monthKey = RangeKind.thisMonth.startDayKey() ?? ""
        check(scope: "day", key: dayKey, budget: dailyBudget, cost: today, label: "今日")
        check(scope: "month", key: monthKey, budget: monthlyBudget, cost: month, label: "本月")
    }

    private func check(scope: String, key: String, budget: Double, cost: Double, label: String) {
        guard budget > 0 else { return }
        for level in Self.budgetLevels {
            guard cost >= budget * level else { continue }
            let flagKey = "budgetAlert-\(scope)-\(level)-\(key)"
            guard !UserDefaults.standard.bool(forKey: flagKey) else { continue }
            UserDefaults.standard.set(true, forKey: flagKey)
            let pct = Int((cost / budget * 100).rounded())
            let content = UNMutableNotificationContent()
            content.title = "TokenMeter 预算提醒"
            content.body = "\(label)预估费用 \(Fmt.cost(cost)) 已达预算 \(Fmt.cost(budget)) 的 \(pct)%\(level >= 1 ? "（已超支）" : "")"
            content.sound = .default
            let req = UNNotificationRequest(identifier: flagKey, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(req)
        }
    }
}
#endif
