import Foundation

struct NewmuxUITabStatus: Equatable {
    let index: Int
    let id: String
    let title: String
    let subtitle: String?
    let active: Bool

    var payload: [String: Any] {
        [
            "index": index,
            "id": id,
            "title": title,
            "subtitle": subtitle ?? NSNull(),
            "active": active,
        ]
    }
}

struct NewmuxUIStatus: Equatable {
    var uiEnabled: Bool = NewmuxUIFlag.enabled
    var statusEnabled: Bool = NewmuxUIFlag.statusEnabled
    var railExpanded: Bool = false
    var nativeTabCount: Int = 0
    var railTabCount: Int = 0
    var activeNativeTabIndex: Int = -1
    var nativeTabs: [NewmuxUITabStatus] = []
    var activeRailTabId: String?
    var bridgeConnected: Bool = false
    var lastSnapshotRevision: String?
    var updatedAt: TimeInterval = Date().timeIntervalSince1970

    var summary: String {
        let bridge = bridgeConnected ? "ok" : "n/a"
        let expanded = railExpanded ? "expanded" : "collapsed"
        return "NM UI \(uiEnabled ? "on" : "off") | rail=\(expanded) | native tabs=\(nativeTabCount) | rail tabs=\(railTabCount) | bridge=\(bridge)"
    }

    var markerText: String {
        "NEWMUX_UI_ENABLED=\(uiEnabled ? 1 : 0) NEWMUX_RAIL_EXPANDED=\(railExpanded ? 1 : 0) NEWMUX_NATIVE_TAB_COUNT=\(nativeTabCount) NEWMUX_RAIL_TAB_COUNT=\(railTabCount)"
    }

    func write() {
        guard statusEnabled, let url = Self.statusURL else { return }

        let payload: [String: Any] = [
            "ui_enabled": uiEnabled,
            "status_enabled": statusEnabled,
            "rail_expanded": railExpanded,
            "native_tab_count": nativeTabCount,
            "native_tabs": nativeTabs.map(\.payload),
            "rail_tab_count": railTabCount,
            "active_native_tab_index": activeNativeTabIndex,
            "active_rail_tab_id": activeRailTabId ?? NSNull(),
            "bridge_connected": bridgeConnected,
            "last_snapshot_revision": lastSnapshotRevision ?? NSNull(),
            "updated_at": updatedAt,
            "marker": markerText,
        ]

        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic])
        } catch {
            // Status is test-only telemetry; never disturb the terminal.
        }
    }

    static var statusURL: URL? {
        let environment = ProcessInfo.processInfo.environment
        if let explicit = environment["NEWMUX_UI_STATUS_FILE"], !explicit.isEmpty {
            return URL(fileURLWithPath: explicit)
        }
        if let bridgeSocket = environment["NEWMUX_UI_BRIDGE_SOCKET"], !bridgeSocket.isEmpty {
            return URL(fileURLWithPath: bridgeSocket)
                .deletingLastPathComponent()
                .appendingPathComponent("ui-status.json")
        }
        return nil
    }
}
