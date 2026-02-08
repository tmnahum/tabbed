import Foundation

enum RestoreMode: String, Codable, CaseIterable {
    case smart
    case off
    case always
}

struct SessionConfig: Codable, Equatable {
    var restoreMode: RestoreMode
    var autoCaptureEnabled: Bool

    static let `default` = SessionConfig(restoreMode: .smart, autoCaptureEnabled: true)

    init(restoreMode: RestoreMode = .smart, autoCaptureEnabled: Bool = true) {
        self.restoreMode = restoreMode
        self.autoCaptureEnabled = autoCaptureEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        restoreMode = try container.decode(RestoreMode.self, forKey: .restoreMode)
        autoCaptureEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoCaptureEnabled) ?? true
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
