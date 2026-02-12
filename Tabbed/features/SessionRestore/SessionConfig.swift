import Foundation

enum RestoreMode: String, Codable, CaseIterable {
    case smart
    case off
    case always
}

enum AutoCaptureMode: String, Codable, CaseIterable {
    case never
    case always        // gobble to most recent group on current space
    case whenMaximized // only when a group fills the screen
    case whenOnly      // when a group is the only one in the space
}

struct SessionConfig: Codable, Equatable {
    var restoreMode: RestoreMode
    var autoCaptureMode: AutoCaptureMode
    var autoCaptureUnmatchedToNewGroup: Bool

    var autoCaptureEnabled: Bool { autoCaptureMode != .never }

    static let `default` = SessionConfig(
        restoreMode: .smart,
        autoCaptureMode: .whenMaximized,
        autoCaptureUnmatchedToNewGroup: false
    )

    init(
        restoreMode: RestoreMode = .smart,
        autoCaptureMode: AutoCaptureMode = .whenMaximized,
        autoCaptureUnmatchedToNewGroup: Bool = false
    ) {
        self.restoreMode = restoreMode
        self.autoCaptureMode = autoCaptureMode
        self.autoCaptureUnmatchedToNewGroup = autoCaptureUnmatchedToNewGroup
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        restoreMode = try container.decode(RestoreMode.self, forKey: .restoreMode)
        // Backward compat: migrate old Bool to new enum
        if let mode = try container.decodeIfPresent(AutoCaptureMode.self, forKey: .autoCaptureMode) {
            autoCaptureMode = mode
        } else {
            let enabled = try container.decodeIfPresent(Bool.self, forKey: .autoCaptureEnabled) ?? true
            autoCaptureMode = enabled ? .whenMaximized : .never
        }
        autoCaptureUnmatchedToNewGroup = try container.decodeIfPresent(
            Bool.self,
            forKey: .autoCaptureUnmatchedToNewGroup
        ) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case restoreMode
        case autoCaptureMode
        case autoCaptureEnabled // legacy key for migration
        case autoCaptureUnmatchedToNewGroup
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(restoreMode, forKey: .restoreMode)
        try container.encode(autoCaptureMode, forKey: .autoCaptureMode)
        try container.encode(autoCaptureUnmatchedToNewGroup, forKey: .autoCaptureUnmatchedToNewGroup)
    }

    // MARK: - Persistence

    private static let userDefaultsKey = "sessionConfig"

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.userDefaultsKey)
    }

    static func load() -> SessionConfig {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let config = try? JSONDecoder().decode(SessionConfig.self, from: data) else {
            return .default
        }
        return config
    }
}

/// Observable state for the menu bar to reactively show/hide the restore button.
class SessionState: ObservableObject {
    @Published var hasPendingSession = false
}
