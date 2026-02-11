import AppKit

enum LauncherMode {
    case newGroup
    case addToGroup(targetGroupID: UUID, targetSpaceID: UInt64)

    var isAddToGroup: Bool {
        if case .addToGroup = self { return true }
        return false
    }
}

enum LauncherAction: Equatable {
    case looseWindow(windowID: CGWindowID)
    case mergeGroup(groupID: UUID)
    case appLaunch(bundleID: String, appURL: URL?, isRunning: Bool)
    case openURL(url: URL)
    case webSearch(query: String)
}

struct LauncherCandidate: Identifiable {
    let id: String
    let action: LauncherAction
    let tier: Int
    let score: Double
    let displayName: String
    let subtitle: String
    let icon: NSImage?
    let recency: Int
    let isRunningApp: Bool
    let hasNativeNewWindow: Bool

    var sectionTitle: String {
        switch tier {
        case 0: return "Windows"
        case 1: return "Groups"
        case 2: return "Apps"
        default: return "Actions"
        }
    }
}

extension LauncherCandidate: Equatable {
    static func == (lhs: LauncherCandidate, rhs: LauncherCandidate) -> Bool {
        lhs.id == rhs.id &&
        lhs.action == rhs.action &&
        lhs.tier == rhs.tier &&
        lhs.score == rhs.score &&
        lhs.displayName == rhs.displayName &&
        lhs.subtitle == rhs.subtitle &&
        lhs.recency == rhs.recency &&
        lhs.isRunningApp == rhs.isRunningApp &&
        lhs.hasNativeNewWindow == rhs.hasNativeNewWindow
    }
}

struct LauncherQueryContext {
    let mode: LauncherMode
    let looseWindows: [WindowInfo]
    let mergeGroups: [TabGroup]
    let appCatalog: [AppCatalogService.AppRecord]
    let launcherConfig: AddWindowLauncherConfig
    let resolvedBrowserProvider: ResolvedBrowserProvider?
    let currentSpaceID: UInt64?
    let windowRecency: [CGWindowID: Int]
    let groupRecency: [UUID: Int]
    let appRecency: [String: Int]
}

enum LaunchAttemptResult: Equatable {
    case succeeded
    case timedOut(status: String)
    case failed(status: String)
}

final class LauncherEngine {
    private static let previewWindowCap = 6
    private static let previewGroupCap = 3

    func rank(query rawQuery: String, context: LauncherQueryContext) -> [LauncherCandidate] {
        let query = Self.normalizeQuery(rawQuery)
        Logger.log("[LAUNCHER_QUERY] query='\(query)' mode=\(context.mode.isAddToGroup ? "add" : "new")")

        if query.isEmpty {
            let preview = previewCandidates(context: context)
            Logger.log("[LAUNCHER_RANK] empty-query candidates=\(preview.count)")
            return preview
        }

        var windows: [LauncherCandidate] = []
        for window in context.looseWindows {
            let score = scoreMatch(query: query, fields: [window.appName, window.title])
            guard score > 0 else { continue }
            windows.append(LauncherCandidate(
                id: "window-\(window.id)",
                action: .looseWindow(windowID: window.id),
                tier: 0,
                score: score,
                displayName: window.appName,
                subtitle: window.title,
                icon: window.icon,
                recency: context.windowRecency[window.id] ?? 0,
                isRunningApp: false,
                hasNativeNewWindow: true
            ))
        }

        var groups: [LauncherCandidate] = []
        if context.mode.isAddToGroup {
            for group in context.mergeGroups {
                let descriptor = groupDescriptor(group)
                let appNames = Set(group.windows.map(\.appName)).sorted().joined(separator: " ")
                let score = scoreMatch(query: query, fields: [descriptor, appNames])
                guard score > 0 else { continue }
                groups.append(LauncherCandidate(
                    id: "group-\(group.id.uuidString)",
                    action: .mergeGroup(groupID: group.id),
                    tier: 1,
                    score: score,
                    displayName: descriptor,
                    subtitle: "\(group.windows.count) tabs",
                    icon: group.activeWindow?.icon,
                    recency: context.groupRecency[group.id] ?? 0,
                    isRunningApp: false,
                    hasNativeNewWindow: true
                ))
            }
        }

        var apps: [LauncherCandidate] = []
        for app in context.appCatalog {
            let score = scoreApp(query: query, app: app)
            guard score > 0 else { continue }
            apps.append(LauncherCandidate(
                id: "app-\(app.bundleID)",
                action: .appLaunch(bundleID: app.bundleID, appURL: app.appURL, isRunning: app.isRunning),
                tier: 2,
                score: score,
                displayName: app.displayName,
                subtitle: app.bundleID,
                icon: app.icon,
                recency: context.appRecency[app.bundleID] ?? app.recency,
                isRunningApp: app.isRunning,
                hasNativeNewWindow: app.isRunning ? LaunchOrchestrator.hasNativeNewWindowSupport(bundleID: app.bundleID) : true
            ))
        }

        var actions: [LauncherCandidate] = []
        if context.launcherConfig.urlLaunchEnabled,
           let url = Self.normalizeURL(from: query) {
            actions.append(LauncherCandidate(
                id: "url-\(url.absoluteString)",
                action: .openURL(url: url),
                tier: 3,
                score: 1.0,
                displayName: "Open URL",
                subtitle: url.absoluteString,
                icon: nil,
                recency: 0,
                isRunningApp: false,
                hasNativeNewWindow: true
            ))
        }

        if context.launcherConfig.searchLaunchEnabled {
            actions.append(LauncherCandidate(
                id: "search-\(query)",
                action: .webSearch(query: query),
                tier: 3,
                score: 0.7,
                displayName: "Web Search",
                subtitle: query,
                icon: nil,
                recency: 0,
                isRunningApp: false,
                hasNativeNewWindow: true
            ))
        }

        let ranked =
            sortWindows(windows) +
            sortGroups(groups) +
            sortApps(apps) +
            sortActions(actions)

        Logger.log("[LAUNCHER_RANK] ranked windows=\(windows.count) groups=\(groups.count) apps=\(apps.count) actions=\(actions.count)")
        return ranked
    }

    func previewCandidates(context: LauncherQueryContext) -> [LauncherCandidate] {
        let windows = context.looseWindows
            .map { window in
                LauncherCandidate(
                    id: "window-\(window.id)",
                    action: .looseWindow(windowID: window.id),
                    tier: 0,
                    score: 1,
                    displayName: window.appName,
                    subtitle: window.title,
                    icon: window.icon,
                    recency: context.windowRecency[window.id] ?? 0,
                    isRunningApp: false,
                    hasNativeNewWindow: true
                )
            }
        let previewWindows = sortWindows(windows).prefix(Self.previewWindowCap)

        let previewGroups: [LauncherCandidate]
        if context.mode.isAddToGroup {
            previewGroups = Array(sortGroups(context.mergeGroups.map { group in
                LauncherCandidate(
                    id: "group-\(group.id.uuidString)",
                    action: .mergeGroup(groupID: group.id),
                    tier: 1,
                    score: 1,
                    displayName: groupDescriptor(group),
                    subtitle: "\(group.windows.count) tabs",
                    icon: group.activeWindow?.icon,
                    recency: context.groupRecency[group.id] ?? 0,
                    isRunningApp: false,
                    hasNativeNewWindow: true
                )
            }).prefix(Self.previewGroupCap))
        } else {
            previewGroups = []
        }

        return Array(previewWindows) + previewGroups
    }

    static func normalizeQuery(_ query: String) -> String {
        query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .lowercased()
    }

    static func normalizeURL(from query: String) -> URL? {
        let trimmed = normalizeQuery(query)
        guard !trimmed.isEmpty else { return nil }
        guard !trimmed.contains(" ") else { return nil }

        if let components = URLComponents(string: trimmed),
           let scheme = components.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            return validatedURL(from: components)
        }

        // Bracketed IPv6 literals are valid hosts for scheme-less input.
        if isBracketedIPv6HostPath(trimmed) {
            return URL(string: "https://\(trimmed)")
        }

        guard looksLikeHostPath(trimmed) else { return nil }
        guard let components = URLComponents(string: "https://\(trimmed)") else { return nil }
        return validatedURL(from: components)
    }

    private static func validatedURL(from components: URLComponents) -> URL? {
        if let host = components.host?.lowercased(), !host.isEmpty {
            guard isValidHost(host) else { return nil }
            return components.url
        }

        // URLComponents occasionally leaves host nil for bracketed IPv6 literals
        // without a path; accept when the raw form is otherwise a valid URL.
        if let raw = components.string,
           raw.contains("["),
           raw.contains("]") {
            return URL(string: raw)
        }
        return nil
    }

    private static func looksLikeHostPath(_ query: String) -> Bool {
        let hostPart = query.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? query
        let hostWithoutPort = hostPart.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? hostPart

        if hostWithoutPort == "localhost" { return true }
        if isIPv4(hostWithoutPort) { return true }
        if isBracketedIPv6HostPath(hostPart) { return true }
        return hostWithoutPort.contains(".")
    }

    private static func isBracketedIPv6HostPath(_ value: String) -> Bool {
        guard value.hasPrefix("["),
              let closeIndex = value.firstIndex(of: "]") else { return false }

        let suffix = value[value.index(after: closeIndex)...]
        return suffix.isEmpty || suffix.hasPrefix(":") || suffix.hasPrefix("/")
    }

    private static func isValidHost(_ host: String) -> Bool {
        if host == "localhost" { return true }
        if isIPv4(host) { return true }
        if host.contains(":") { return true } // IPv6

        let labels = host.split(separator: ".")
        guard labels.count >= 2 else { return false }
        for label in labels {
            guard !label.isEmpty,
                  label.first != "-",
                  label.last != "-",
                  label.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else {
                return false
            }
        }
        return true
    }

    private static func isIPv4(_ string: String) -> Bool {
        let parts = string.split(separator: ".")
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard let n = Int(part), n >= 0, n <= 255 else { return false }
            return String(n) == part || part == "0"
        }
    }

    private func scoreApp(query: String, app: AppCatalogService.AppRecord) -> Double {
        let base = scoreMatch(query: query, fields: [app.displayName, app.bundleID])
        if app.bundleID.lowercased().hasSuffix(query) {
            return max(base, 0.85)
        }
        return base
    }

    private func scoreMatch(query: String, fields: [String]) -> Double {
        guard !query.isEmpty else { return 0 }

        var best: Double = 0
        for field in fields {
            let normalizedField = Self.normalizeQuery(field)
            guard !normalizedField.isEmpty else { continue }

            if normalizedField.hasPrefix(query) {
                best = max(best, 1.0)
                continue
            }

            if tokenPrefixMatch(query: query, value: normalizedField) {
                best = max(best, 0.85)
                continue
            }

            if normalizedField.contains(query) {
                best = max(best, 0.65)
                continue
            }

            if fuzzyOrderedMatch(query: query, value: normalizedField) {
                best = max(best, 0.45)
            }
        }

        return best
    }

    private func tokenPrefixMatch(query: String, value: String) -> Bool {
        let queryTokens = query.split(separator: " ").map(String.init)
        guard !queryTokens.isEmpty else { return false }

        let valueTokens = value.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard !valueTokens.isEmpty else { return false }

        for queryToken in queryTokens {
            if !valueTokens.contains(where: { $0.hasPrefix(queryToken) }) {
                return false
            }
        }
        return true
    }

    private func fuzzyOrderedMatch(query: String, value: String) -> Bool {
        guard !query.isEmpty else { return false }

        var queryIndex = query.startIndex
        for char in value where queryIndex < query.endIndex {
            if char == query[queryIndex] {
                query.formIndex(after: &queryIndex)
            }
        }
        return queryIndex == query.endIndex
    }

    private func sortWindows(_ candidates: [LauncherCandidate]) -> [LauncherCandidate] {
        candidates.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.recency != rhs.recency { return lhs.recency > rhs.recency }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    private func sortGroups(_ candidates: [LauncherCandidate]) -> [LauncherCandidate] {
        candidates.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.recency != rhs.recency { return lhs.recency > rhs.recency }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    private func sortApps(_ candidates: [LauncherCandidate]) -> [LauncherCandidate] {
        candidates.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.isRunningApp != rhs.isRunningApp { return lhs.isRunningApp }
            if lhs.recency != rhs.recency { return lhs.recency > rhs.recency }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    private func sortActions(_ candidates: [LauncherCandidate]) -> [LauncherCandidate] {
        candidates.sorted { lhs, rhs in
            let lhsIsURL: Bool
            if case .openURL = lhs.action { lhsIsURL = true } else { lhsIsURL = false }
            let rhsIsURL: Bool
            if case .openURL = rhs.action { rhsIsURL = true } else { rhsIsURL = false }
            if lhsIsURL != rhsIsURL { return lhsIsURL }
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    private func groupDescriptor(_ group: TabGroup) -> String {
        let appNames = Array(Set(group.windows.map(\.appName))).sorted()
        if appNames.count == 1, let appName = appNames.first {
            return "\(group.windows.count) \(appName) windows"
        }
        if appNames.count <= 2 {
            return appNames.joined(separator: ", ")
        }
        return "\(appNames.prefix(2).joined(separator: ", ")) + \(appNames.count - 2) more"
    }
}
