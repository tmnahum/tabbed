import Foundation

struct ShortcutConfig: Codable, Equatable {
    var newTab: KeyBinding
    var releaseTab: KeyBinding
    var cycleTab: KeyBinding
    var switchToTab: [KeyBinding]   // 9 entries; index 0 = tab 1
    var globalSwitcher: KeyBinding

    static let `default` = ShortcutConfig(
        newTab: .defaultNewTab,
        releaseTab: .defaultReleaseTab,
        cycleTab: .defaultCycleTab,
        switchToTab: (1...9).map { KeyBinding.defaultSwitchToTab($0) },
        globalSwitcher: .defaultGlobalSwitcher
    )

    // MARK: - Backward-Compatible Decoding

    init(newTab: KeyBinding, releaseTab: KeyBinding, cycleTab: KeyBinding, switchToTab: [KeyBinding], globalSwitcher: KeyBinding) {
        self.newTab = newTab
        self.releaseTab = releaseTab
        self.cycleTab = cycleTab
        self.switchToTab = switchToTab
        self.globalSwitcher = globalSwitcher
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        newTab = try container.decode(KeyBinding.self, forKey: .newTab)
        releaseTab = try container.decode(KeyBinding.self, forKey: .releaseTab)
        cycleTab = try container.decode(KeyBinding.self, forKey: .cycleTab)
        switchToTab = try container.decode([KeyBinding].self, forKey: .switchToTab)
        globalSwitcher = try container.decodeIfPresent(KeyBinding.self, forKey: .globalSwitcher)
            ?? .defaultGlobalSwitcher
    }

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
