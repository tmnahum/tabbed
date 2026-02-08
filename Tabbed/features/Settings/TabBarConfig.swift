import Foundation

enum TabBarStyle: String, Codable, CaseIterable {
    case equal
    case compact
}

class TabBarConfig: ObservableObject, Codable {
    @Published var style: TabBarStyle {
        didSet {
            if style != oldValue { save() }
        }
    }

    static let `default` = TabBarConfig(style: .equal)

    init(style: TabBarStyle = .equal) {
        self.style = style
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case style
    }

    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        style = try container.decodeIfPresent(TabBarStyle.self, forKey: .style) ?? .equal
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(style, forKey: .style)
    }

    // MARK: - Persistence

    private static let userDefaultsKey = "tabBarConfig"

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.userDefaultsKey)
    }

    static func load() -> TabBarConfig {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let config = try? JSONDecoder().decode(TabBarConfig.self, from: data) else {
            return TabBarConfig()
        }
        return config
    }
}
