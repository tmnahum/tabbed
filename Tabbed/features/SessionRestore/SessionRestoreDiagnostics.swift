import Foundation

enum SessionRestoreDiagnostics {
    static let userDefaultsKey = "sessionRestoreDiagnosticsEnabled"
    static let environmentKey = "TABBED_SESSION_RESTORE_DIAGNOSTICS"

    static func isEnabled(
        userDefaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        if let value = environment[environmentKey],
           let parsed = parseBool(value) {
            return parsed
        }
        guard userDefaults.object(forKey: userDefaultsKey) != nil else {
            return true
        }
        return userDefaults.bool(forKey: userDefaultsKey)
    }

    static func parseBool(_ raw: String) -> Bool? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return nil
        }
    }
}
