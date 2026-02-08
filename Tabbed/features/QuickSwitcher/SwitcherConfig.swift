import Foundation

enum SwitcherStyle: String, Codable, CaseIterable {
    case appIcons
    case titles
}

struct SwitcherConfig: Codable, Equatable {
    var style: SwitcherStyle = .appIcons

    private static let userDefaultsKey = "switcherConfig"

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.userDefaultsKey)
    }

    static func load() -> SwitcherConfig {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let config = try? JSONDecoder().decode(SwitcherConfig.self, from: data) else {
            return SwitcherConfig()
        }
        return config
    }
}
