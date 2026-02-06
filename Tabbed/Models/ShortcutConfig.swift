import Foundation

struct ShortcutConfig: Codable, Equatable {
    var newTab: KeyBinding
    var releaseTab: KeyBinding
    var cycleTab: KeyBinding
    var switchToTab: [KeyBinding]   // 9 entries; index 0 = tab 1

    static let `default` = ShortcutConfig(
        newTab: .defaultNewTab,
        releaseTab: .defaultReleaseTab,
        cycleTab: .defaultCycleTab,
        switchToTab: (1...9).map { KeyBinding.defaultSwitchToTab($0) }
    )

    // MARK: - Persistence

    private static let userDefaultsKey = "shortcutConfig"

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.userDefaultsKey)
    }

    static func load() -> ShortcutConfig {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let config = try? JSONDecoder().decode(ShortcutConfig.self, from: data) else {
            return .default
        }
        return config
    }
}
