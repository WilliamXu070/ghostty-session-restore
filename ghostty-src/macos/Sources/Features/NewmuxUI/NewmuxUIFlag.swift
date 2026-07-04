import Foundation

enum NewmuxUIFlag {
    static var enabled: Bool {
        boolEnvironment("NEWMUX_GHOSTTY_UI")
    }

    static var statusEnabled: Bool {
        boolEnvironment("NEWMUX_GHOSTTY_UI_STATUS")
    }

    static func boolEnvironment(_ name: String) -> Bool {
        let value = ProcessInfo.processInfo.environment[name] ?? ""
        return value == "1" || value.caseInsensitiveCompare("true") == .orderedSame
    }
}
