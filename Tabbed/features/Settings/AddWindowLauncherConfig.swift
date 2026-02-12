import Foundation

enum BrowserEngine: String, Codable, CaseIterable {
    case chromium
    case firefox
    case safari
}

enum BrowserProviderMode: String, Codable, CaseIterable {
    case auto
    case manual
}

enum SearchEngine: String, Codable, CaseIterable {
    case unduck
    case google
    case googleWeb
    case duckDuckGo
    case bing
    case brave
    case kagi
    case googleAI
    case perplexity
    case chatGPT
    case claude
    case custom

    static let commonProviders: [SearchEngine] = [
        .unduck,
        .google,
        .googleWeb,
        .duckDuckGo,
        .bing,
        .brave,
        .kagi
    ]

    static let aiProviders: [SearchEngine] = [
        .googleAI,
        .perplexity,
        .chatGPT,
        .claude
    ]

    static let defaultTemplate = "https://www.google.com/search?q=%s"

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        switch rawValue {
        case Self.unduck.rawValue:
            self = .unduck
        case Self.google.rawValue:
            self = .google
        case Self.googleWeb.rawValue:
            self = .googleWeb
        case Self.duckDuckGo.rawValue:
            self = .duckDuckGo
        case Self.bing.rawValue:
            self = .bing
        case Self.brave.rawValue:
            self = .brave
        case Self.kagi.rawValue:
            self = .kagi
        case Self.googleAI.rawValue:
            self = .googleAI
        case Self.perplexity.rawValue:
            self = .perplexity
        case Self.chatGPT.rawValue:
            self = .chatGPT
        case Self.claude.rawValue:
            self = .claude
        case Self.custom.rawValue:
            self = .custom
        default:
            self = .unduck
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var presetTemplate: String? {
        switch self {
        case .unduck:
            return "https://unduck.link/?q=%s"
        case .google:
            return "https://www.google.com/search?q=%s"
        case .googleWeb:
            return "https://www.google.com/search?q=%s&udm=14"
        case .duckDuckGo:
            return "https://duckduckgo.com/?q=%s"
        case .bing:
            return "https://www.bing.com/search?q=%s"
        case .brave:
            return "https://search.brave.com/search?q=%s"
        case .kagi:
            return "https://kagi.com/search?q=%s"
        case .googleAI:
            return "https://www.google.com/search?q=%s&udm=50"
        case .perplexity:
            return "https://www.perplexity.ai/search/new?q=%s"
        case .chatGPT:
            return "https://chatgpt.com/?q=%s"
        case .claude:
            return "https://claude.ai/new?q=%s"
        case .custom:
            return nil
        }
    }

    func searchURL(for query: String, customTemplate: String? = nil) -> URL? {
        let template = (self == .custom ? customTemplate : presetTemplate) ?? ""
        return Self.searchURL(query: query, template: template)
    }

    static func isTemplateValid(_ template: String) -> Bool {
        template.trimmingCharacters(in: .whitespacesAndNewlines).contains("%s")
    }

    static func searchURL(query: String, template: String) -> URL? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalizedTemplate = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isTemplateValid(normalizedTemplate) else { return nil }
        guard let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return nil
        }
        let urlString = normalizedTemplate.replacingOccurrences(of: "%s", with: encoded)
        return URL(string: urlString)
    }

    var displayName: String {
        switch self {
        case .unduck: return "Unduck"
        case .google: return "Google"
        case .googleWeb: return "Google (Web)"
        case .duckDuckGo: return "DuckDuckGo"
        case .bing: return "Bing"
        case .brave: return "Brave Search"
        case .kagi: return "Kagi"
        case .googleAI: return "Google (AI)"
        case .perplexity: return "Perplexity"
        case .chatGPT: return "ChatGPT"
        case .claude: return "Claude"
        case .custom: return "Custom"
        }
    }
}

struct BrowserProviderSelection: Codable, Equatable {
    var bundleID: String
    var engine: BrowserEngine

    init(bundleID: String = "", engine: BrowserEngine = .chromium) {
        self.bundleID = bundleID
        self.engine = engine
    }
}

struct AddWindowLauncherConfig: Codable, Equatable {
    var urlLaunchEnabled: Bool
    var searchLaunchEnabled: Bool
    var providerMode: BrowserProviderMode
    var searchEngine: SearchEngine
    var customSearchTemplate: String
    var manualSelection: BrowserProviderSelection

    static let `default` = AddWindowLauncherConfig(
        urlLaunchEnabled: true,
        searchLaunchEnabled: true,
        providerMode: .auto,
        searchEngine: .unduck,
        customSearchTemplate: SearchEngine.defaultTemplate,
        manualSelection: BrowserProviderSelection(bundleID: "", engine: .chromium)
    )

    init(
        urlLaunchEnabled: Bool = true,
        searchLaunchEnabled: Bool = true,
        providerMode: BrowserProviderMode = .auto,
        searchEngine: SearchEngine = .unduck,
        customSearchTemplate: String = SearchEngine.defaultTemplate,
        manualSelection: BrowserProviderSelection = BrowserProviderSelection()
    ) {
        self.urlLaunchEnabled = urlLaunchEnabled
        self.searchLaunchEnabled = searchLaunchEnabled
        self.providerMode = providerMode
        self.searchEngine = searchEngine
        self.customSearchTemplate = customSearchTemplate
        self.manualSelection = manualSelection
    }

    var hasManualSelection: Bool {
        !manualSelection.bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasAnyLaunchActionEnabled: Bool {
        urlLaunchEnabled || searchLaunchEnabled
    }

    var effectiveSearchTemplate: String {
        if searchEngine == .custom {
            return customSearchTemplate
        }
        return searchEngine.presetTemplate ?? SearchEngine.defaultTemplate
    }

    var isCustomSearchTemplateValid: Bool {
        searchEngine != .custom || SearchEngine.isTemplateValid(customSearchTemplate)
    }

    func searchURL(for query: String) -> URL? {
        searchEngine.searchURL(for: query, customTemplate: customSearchTemplate)
    }

    private enum CodingKeys: String, CodingKey {
        case urlLaunchEnabled
        case searchLaunchEnabled
        case providerMode
        case searchEngine
        case customSearchTemplate
        case manualSelection
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        urlLaunchEnabled = try container.decodeIfPresent(Bool.self, forKey: .urlLaunchEnabled) ?? true
        // For configs saved before `searchLaunchEnabled` existed, mirror the legacy combined toggle value.
        searchLaunchEnabled = try container.decodeIfPresent(Bool.self, forKey: .searchLaunchEnabled) ?? urlLaunchEnabled
        providerMode = try container.decodeIfPresent(BrowserProviderMode.self, forKey: .providerMode) ?? .auto
        searchEngine = try container.decodeIfPresent(SearchEngine.self, forKey: .searchEngine) ?? .unduck
        customSearchTemplate = try container.decodeIfPresent(String.self, forKey: .customSearchTemplate) ?? SearchEngine.defaultTemplate
        if customSearchTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            customSearchTemplate = SearchEngine.defaultTemplate
        }
        manualSelection = try container.decodeIfPresent(BrowserProviderSelection.self, forKey: .manualSelection) ?? BrowserProviderSelection()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(urlLaunchEnabled, forKey: .urlLaunchEnabled)
        try container.encode(searchLaunchEnabled, forKey: .searchLaunchEnabled)
        try container.encode(providerMode, forKey: .providerMode)
        try container.encode(searchEngine, forKey: .searchEngine)
        try container.encode(customSearchTemplate, forKey: .customSearchTemplate)
        try container.encode(manualSelection, forKey: .manualSelection)
    }

    private static let userDefaultsKey = "addWindowLauncherConfig"

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.userDefaultsKey)
    }

    static func load() -> AddWindowLauncherConfig {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let config = try? JSONDecoder().decode(AddWindowLauncherConfig.self, from: data) else {
            return .default
        }
        return config
    }
}
