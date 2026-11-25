#if os(macOS)
import SwiftUI
import AppKit

/// 全局动作集合：菜单栏、悬浮坞、面板共享同一套操作入口
@MainActor
final class AppActions: ObservableObject {
    var openPanel: () -> Void = {}
    var closePanel: () -> Void = {}
    var togglePanel: () -> Void = {}
    var openSettings: () -> Void = {}
    var refresh: () -> Void = {}
    var checkUpdate: () -> Void = {}
    var markAllRead: () -> Void = {}
    var hideDock: () -> Void = {}
    var exportCSV: () -> Void = {}
    var setMenuBarStyle: (String) -> Void = { _ in }
    var setRateMode: (String) -> Void = { _ in }
    var setDockSide: (String) -> Void = { _ in }
    var quit: () -> Void = {}

    static let shared = AppActions()
}

extension AppActions {
    /// 菜单栏 / 悬浮坞共用的右键菜单
    func buildMenu(model: AppModel) -> NSMenu {
        let menu = NSMenu()

        menu.addItem(item(L10n.t("打开面板"), #selector(MenuActionRouter.openPanel)))

        // 常用开关放子菜单，避免主菜单过长；勾选态直接显示当前值
        let styleMenu = NSMenu()
        let styles: [(String, String)] = [
            ("both", L10n.t("用量 + 费用")),
            ("tokens", L10n.t("仅用量")),
            ("cost", L10n.t("仅费用")),
            ("icon", L10n.t("仅图标")),
        ]
        for (value, title) in styles {
            let it = item(title, #selector(MenuActionRouter.setMenuBarStyle(_:)), represent: value)
            it.state = model.menuBarStyle == value ? .on : .off
            styleMenu.addItem(it)
        }
        let styleItem = NSMenuItem(title: L10n.t("菜单栏显示"), action: nil, keyEquivalent: "")
        styleItem.submenu = styleMenu
        menu.addItem(styleItem)

        let rateMenu = NSMenu()
        let rates: [(String, String)] = [
            ("auto", L10n.t("自动")),
            ("always", L10n.t("总是显示")),
            ("never", L10n.t("不显示")),
        ]
        for (value, title) in rates {
            let it = item(title, #selector(MenuActionRouter.setRateMode(_:)), represent: value)
            it.state = model.rateDisplayMode == value ? .on : .off
            rateMenu.addItem(it)
        }
        let rateItem = NSMenuItem(title: L10n.t("显示速度"), action: nil, keyEquivalent: "")
        rateItem.submenu = rateMenu
        menu.addItem(rateItem)

        let dockMenu = NSMenu()
        let sides: [(String, String)] = [
            ("off", L10n.t("关闭")),
            ("left", L10n.t("左侧")),
            ("right", L10n.t("右侧")),
        ]
        for (value, title) in sides {
            let it = item(title, #selector(MenuActionRouter.setDockSide(_:)), represent: value)
            it.state = model.sideDock == value ? .on : .off
            dockMenu.addItem(it)
        }
        let dockItem = NSMenuItem(title: L10n.t("悬浮坞"), action: nil, keyEquivalent: "")
        dockItem.submenu = dockMenu
        menu.addItem(dockItem)

        menu.addItem(.separator())

        menu.addItem(item(L10n.t("立即刷新统计"), #selector(MenuActionRouter.refresh)))
        menu.addItem(item(L10n.t("导出 CSV…"), #selector(MenuActionRouter.exportCSV)))
        menu.addItem(item(L10n.t("检查更新…"), #selector(MenuActionRouter.checkUpdate)))
        menu.addItem(item(L10n.t("标记全部已读"), #selector(MenuActionRouter.markAllRead)))

        menu.addItem(.separator())

        menu.addItem(item(L10n.t("设置…"), #selector(MenuActionRouter.openSettings)))
        menu.addItem(item(L10n.t("退出 TokenMeter"), #selector(MenuActionRouter.quit)))

        applyTarget(menu)
        if ProcessInfo.processInfo.environment["TOKENMETER_DEBUG"] != nil {
            func dump(_ m: NSMenu, _ indent: String = "") {
                for it in m.items {
                    guard !it.isSeparatorItem else { continue }
                    let mark = it.state == .on ? "✓ " : "  "
                    FileHandle.standardError.write(Data("\(indent)\(mark)\(it.title)\n".utf8))
                    if let sub = it.submenu { dump(sub, indent + "    ") }
                }
            }
            FileHandle.standardError.write(Data("DBG menu:\n".utf8))
            dump(menu)
        }
        return menu
    }

    private func item(_ title: String, _ action: Selector, represent: Any? = nil) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: "")
        it.representedObject = represent
        return it
    }

    /// 子菜单里的项也要设 target，否则点了没反应
    private func applyTarget(_ menu: NSMenu) {
        for it in menu.items {
            it.target = MenuActionRouter.shared
            if let sub = it.submenu { applyTarget(sub) }
        }
    }
}

/// 菜单项转发的 Objective-C 目标（NSMenu 需要 target/action）
@MainActor
final class MenuActionRouter: NSObject {
    static let shared = MenuActionRouter()

    @objc func openPanel() { AppActions.shared.openPanel() }
    @objc func openSettings() { AppActions.shared.openSettings() }
    @objc func refresh() { AppActions.shared.refresh() }
    @objc func checkUpdate() { AppActions.shared.checkUpdate() }
    @objc func markAllRead() { AppActions.shared.markAllRead() }
    @objc func hideDock() { AppActions.shared.hideDock() }
    @objc func exportCSV() { AppActions.shared.exportCSV() }
    @objc func setMenuBarStyle(_ sender: NSMenuItem) {
        AppActions.shared.setMenuBarStyle(sender.representedObject as? String ?? "both")
    }
    @objc func setRateMode(_ sender: NSMenuItem) {
        AppActions.shared.setRateMode(sender.representedObject as? String ?? "auto")
    }
    @objc func setDockSide(_ sender: NSMenuItem) {
        AppActions.shared.setDockSide(sender.representedObject as? String ?? "off")
    }
    @objc func quit() { AppActions.shared.quit() }
}
#endif
