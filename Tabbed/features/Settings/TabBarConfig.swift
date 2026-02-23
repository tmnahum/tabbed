import Foundation

enum TabBarStyle: String, Codable, CaseIterable {
    case equal
    case compact
}

enum TabCloseButtonMode: String, Codable, CaseIterable {
    case xmarkOnAllTabs
    case minusOnCurrentTab
    case minusOnAllTabs
}

enum GroupCounterMode: String, Codable, CaseIterable {
    case disabled
    case maximizedOnly
    case maximizedAndPositionAligned
}

class TabBarConfig: ObservableObject, Codable {
    @Published var style: TabBarStyle {
        didSet {
            if style != oldValue { save() }
        }
    }
    @Published var showDragHandle: Bool {
        didSet {
            if showDragHandle != oldValue { save() }
        }
    }
    @Published var superpinnedTabsBeforeHandle: Bool {
        didSet {
            if superpinnedTabsBeforeHandle != oldValue { save() }
        }
    }
    @Published var showTooltip: Bool {
        didSet {
            if showTooltip != oldValue { save() }
        }
    }
    @Published var closeButtonMode: TabCloseButtonMode {
        didSet {
            if closeButtonMode != oldValue { save() }
        }
    }
    @Published var showCloseConfirmation: Bool {
        didSet {
            if showCloseConfirmation != oldValue { save() }
        }
    }
    @Published var groupCounterMode: GroupCounterMode {
        didSet {
            if groupCounterMode != oldValue { save() }
        }
    }

    var showMaximizedGroupCounters: Bool {
        get {
            groupCounterMode != .disabled
        }
        set {
            groupCounterMode = newValue ? .maximizedOnly : .disabled
        }
    }

    static let `default` = TabBarConfig(style: .compact)

    init(
        style: TabBarStyle = .compact,
        showDragHandle: Bool = true,
        superpinnedTabsBeforeHandle: Bool = true,
        showTooltip: Bool = true,
        closeButtonMode: TabCloseButtonMode = .xmarkOnAllTabs,
        showCloseConfirmation: Bool = true,
        showMaximizedGroupCounters: Bool = true,
        groupCounterMode: GroupCounterMode? = nil
    ) {
        self.style = style
        self.showDragHandle = showDragHandle
        self.superpinnedTabsBeforeHandle = superpinnedTabsBeforeHandle
        self.showTooltip = showTooltip
        self.closeButtonMode = closeButtonMode
        self.showCloseConfirmation = showCloseConfirmation
        self.groupCounterMode = groupCounterMode ?? (showMaximizedGroupCounters ? .maximizedOnly : .disabled)
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case style
        case showDragHandle
        case superpinnedTabsBeforeHandle
        case showTooltip
        case closeButtonMode
        case showCloseConfirmation
        case groupCounterMode
        case showMaximizedGroupCounters
    }

    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        style = try container.decodeIfPresent(TabBarStyle.self, forKey: .style) ?? .compact
        showDragHandle = try container.decodeIfPresent(Bool.self, forKey: .showDragHandle) ?? true
        superpinnedTabsBeforeHandle = try container.decodeIfPresent(Bool.self, forKey: .superpinnedTabsBeforeHandle) ?? true
        showTooltip = try container.decodeIfPresent(Bool.self, forKey: .showTooltip) ?? true
        closeButtonMode = try container.decodeIfPresent(TabCloseButtonMode.self, forKey: .closeButtonMode) ?? .xmarkOnAllTabs
        showCloseConfirmation = try container.decodeIfPresent(Bool.self, forKey: .showCloseConfirmation) ?? true
        if let decodedMode = try container.decodeIfPresent(GroupCounterMode.self, forKey: .groupCounterMode) {
            groupCounterMode = decodedMode
        } else {
            let showCounters = try container.decodeIfPresent(Bool.self, forKey: .showMaximizedGroupCounters) ?? true
            groupCounterMode = showCounters ? .maximizedOnly : .disabled
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(style, forKey: .style)
        try container.encode(showDragHandle, forKey: .showDragHandle)
        try container.encode(superpinnedTabsBeforeHandle, forKey: .superpinnedTabsBeforeHandle)
        try container.encode(showTooltip, forKey: .showTooltip)
        try container.encode(closeButtonMode, forKey: .closeButtonMode)
        try container.encode(showCloseConfirmation, forKey: .showCloseConfirmation)
        try container.encode(groupCounterMode, forKey: .groupCounterMode)
        try container.encode(showMaximizedGroupCounters, forKey: .showMaximizedGroupCounters)
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
