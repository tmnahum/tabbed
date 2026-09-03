import Foundation

final class MenuBarConfig: ObservableObject, Codable {
    @Published var showUngroupedWindows: Bool {
        didSet {
            if showUngroupedWindows != oldValue { save() }
        }
    }

    init(showUngroupedWindows: Bool = true) {
        self.showUngroupedWindows = showUngroupedWindows
    }

    private enum CodingKeys: String, CodingKey {
        case showUngroupedWindows
    }

    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        showUngroupedWindows = try container.decodeIfPresent(Bool.self, forKey: .showUngroupedWindows) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(showUngroupedWindows, forKey: .showUngroupedWindows)
    }

    private static let userDefaultsKey = "menuBarConfig"

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.userDefaultsKey)
    }

    static func load() -> MenuBarConfig {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let config = try? JSONDecoder().decode(MenuBarConfig.self, from: data) else {
            return MenuBarConfig()
        }
        return config
    }
}
