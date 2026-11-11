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
    var quit: () -> Void = {}

    static let shared = AppActions()
}

extension AppActions {
    /// 菜单栏 / 悬浮坞共用的右键菜单
    func buildMenu(model: AppModel) -> NSMenu {
        let menu = NSMenu()

        let open = NSMenuItem(title: "打开面板", action: #selector(MenuActionRouter.openPanel), keyEquivalent: "")
        menu.addItem(open)

        let settings = NSMenuItem(title: "设置…", action: #selector(MenuActionRouter.openSettings), keyEquivalent: ",")
        menu.addItem(settings)

        menu.addItem(.separator())

        let refresh = NSMenuItem(title: "立即刷新统计", action: #selector(MenuActionRouter.refresh), keyEquivalent: "r")
        menu.addItem(refresh)

        let update = NSMenuItem(title: "检查更新…", action: #selector(MenuActionRouter.checkUpdate), keyEquivalent: "")
        menu.addItem(update)

        let readAll = NSMenuItem(title: "标记全部已读", action: #selector(MenuActionRouter.markAllRead), keyEquivalent: "")
        menu.addItem(readAll)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出 TokenMeter", action: #selector(MenuActionRouter.quit), keyEquivalent: "q")
        menu.addItem(quit)

        for item in menu.items where item.action != nil {
            item.target = MenuActionRouter.shared
        }
        return menu
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
    @objc func quit() { AppActions.shared.quit() }
}
#endif
