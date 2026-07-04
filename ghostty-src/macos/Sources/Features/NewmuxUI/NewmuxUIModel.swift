import AppKit
import Combine

struct NewmuxUITab: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String?
    let isActive: Bool
    let window: NSWindow

    static func == (lhs: NewmuxUITab, rhs: NewmuxUITab) -> Bool {
        lhs.id == rhs.id &&
        lhs.title == rhs.title &&
        lhs.subtitle == rhs.subtitle &&
        lhs.isActive == rhs.isActive
    }
}

final class NewmuxUIModel: ObservableObject {
    @Published private(set) var tabs: [NewmuxUITab] = []
    @Published private(set) var status = NewmuxUIStatus()

    private var observers: [NSObjectProtocol] = []

    init() {
        refresh()

        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didBecomeMainNotification,
            NSWindow.willCloseNotification,
            TerminalWindow.terminalDidAwake,
            TerminalWindow.terminalWillCloseNotification,
            .ghosttyMoveTab,
        ]

        observers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refresh()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    self?.refresh()
                }
            }
        }
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func refresh() {
        let parentWindow = NSApp.keyWindow ?? TerminalController.preferredParent?.window
        let windows: [NSWindow]

        if let groupWindows = parentWindow?.tabGroup?.windows, !groupWindows.isEmpty {
            windows = groupWindows
        } else {
            windows = TerminalController.all.compactMap(\.window)
        }

        let nextTabs: [NewmuxUITab] = windows.compactMap { window in
            guard let controller = window.windowController as? TerminalController else {
                return nil
            }

            let title = controller.titleOverride?.isEmpty == false ?
                controller.titleOverride! :
                (window.title.isEmpty ? "Untitled" : window.title)

            let subtitle = controller.focusedSurface?.pwd?.abbreviatedPath
            let id = String(ObjectIdentifier(window).hashValue)

            return NewmuxUITab(
                id: id,
                title: title,
                subtitle: subtitle,
                isActive: window.isKeyWindow || window.tabGroup?.selectedWindow === window,
                window: window
            )
        }
        tabs = nextTabs
        updateStatus(tabs: nextTabs)
    }

    func select(_ tab: NewmuxUITab) {
        tab.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        refresh()
    }

    func moveTab(id draggedID: String, before target: NewmuxUITab) {
        guard let dragged = tabs.first(where: { $0.id == draggedID }) else { return }
        guard dragged.id != target.id else { return }
        guard dragged.window.tabGroup === target.window.tabGroup else { return }

        dragged.window.tabGroup?.removeWindow(dragged.window)
        target.window.addTabbedWindowSafely(dragged.window, ordered: .below)
        dragged.window.makeKey()
        refresh()
    }

    func setRailExpanded(_ expanded: Bool) {
        var nextStatus = status
        nextStatus.railExpanded = expanded
        nextStatus.updatedAt = Date().timeIntervalSince1970
        status = nextStatus
        nextStatus.write()
    }

    private func updateStatus(tabs: [NewmuxUITab]) {
        let activeIndex = tabs.firstIndex { $0.isActive } ?? -1
        var nextStatus = status
        nextStatus.uiEnabled = NewmuxUIFlag.enabled
        nextStatus.statusEnabled = NewmuxUIFlag.statusEnabled
        nextStatus.nativeTabCount = tabs.count
        nextStatus.railTabCount = tabs.count
        nextStatus.activeNativeTabIndex = activeIndex
        nextStatus.nativeTabs = tabs.enumerated().map { index, tab in
            NewmuxUITabStatus(
                index: index,
                id: tab.id,
                title: tab.title,
                subtitle: tab.subtitle,
                active: tab.isActive
            )
        }
        nextStatus.activeRailTabId = activeIndex >= 0 ? tabs[activeIndex].id : nil
        nextStatus.bridgeConnected = ProcessInfo.processInfo.environment["NEWMUX_UI_BRIDGE_SOCKET"]?.isEmpty == false
        nextStatus.updatedAt = Date().timeIntervalSince1970
        status = nextStatus
        nextStatus.write()
    }
}
