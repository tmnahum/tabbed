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
    case groupAllInSpace
    case mergeGroup(groupID: UUID)
    case insertSeparatorTab
    case renameTargetGroup
    case renameCurrentTab
    case releaseCurrentTab
    case ungroupTargetGroup
    case closeAllWindowsInTargetGroup
    case appLaunch(bundleID: String, appURL: URL?, isRunning: Bool)
    case openURL(url: URL)
    case webSearch(query: String)

    var historyKey: String? {
        switch self {
        case .groupAllInSpace:
            return "action.groupAllInSpace"
        case .renameTargetGroup:
            return "action.renameTargetGroup"
        case .insertSeparatorTab:
            return "action.insertSeparatorTab"
        case .renameCurrentTab:
            return "action.renameCurrentTab"
        case .releaseCurrentTab:
            return "action.releaseCurrentTab"
        case .ungroupTargetGroup:
            return "action.ungroupTargetGroup"
        case .closeAllWindowsInTargetGroup:
            return "action.closeAllWindowsInTargetGroup"
        default:
            return nil
        }
    }
}

struct LauncherCandidate: Identifiable {
    static let mirrorTabsSectionTitle = "Mirror Tabs"

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
    let sectionTitleOverride: String?

    var sectionTitle: String {
        if let sectionTitleOverride {
            return sectionTitleOverride
        }
        switch tier {
        case 0: return "Windows"
        case 1: return "Merge-in Groups"
        case 2: return "Suggestions"
        case 3: return "Web Search"
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
        lhs.hasNativeNewWindow == rhs.hasNativeNewWindow &&
        lhs.sectionTitleOverride == rhs.sectionTitleOverride
    }
}

struct LauncherQueryContext {
    let mode: LauncherMode
    let looseWindows: [WindowInfo]
    let mergeGroups: [TabGroup]
    let targetGroupDisplayName: String?
    let targetGroupWindowCount: Int?
    let targetActiveTabID: CGWindowID?
    let targetActiveTabTitle: String?
    let appCatalog: [AppCatalogService.AppRecord]
    let launcherConfig: AddWindowLauncherConfig
    let resolvedURLBrowserProvider: ResolvedBrowserProvider?
    let resolvedSearchBrowserProvider: ResolvedBrowserProvider?
    let currentSpaceID: UInt64?
    let windowRecency: [CGWindowID: Int]
    let groupRecency: [UUID: Int]
    let appRecency: [String: Int]
    var mirroredWindowIDs: Set<CGWindowID> = []
    let urlHistory: [LauncherHistoryStore.URLEntry]
    let appLaunchHistory: [String: LauncherHistoryStore.AppEntry]
    let actionHistory: [String: LauncherHistoryStore.ActionEntry]
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

        let now = Date()
        let hasExplicitURLIntent = Self.hasExplicitURLIntent(query: query)

        var windows: [LauncherCandidate] = []
        for window in context.looseWindows {
            let score = scoreMatch(query: query, fields: [window.appName, window.title])
            guard score > 0 else { continue }
            windows.append(LauncherCandidate(
                id: "window-\(window.id)",
                action: .looseWindow(windowID: window.id),
                tier: 0,
                score: score,
                displayName: window.title.isEmpty ? window.appName : window.title,
                subtitle: window.title.isEmpty ? "" : window.appName,
                icon: window.icon,
                recency: context.windowRecency[window.id] ?? 0,
                isRunningApp: false,
                hasNativeNewWindow: true,
                sectionTitleOverride: context.mirroredWindowIDs.contains(window.id) ? LauncherCandidate.mirrorTabsSectionTitle : nil
            ))
        }

        var groups: [LauncherCandidate] = []
        if context.mode.isAddToGroup {
            for group in context.mergeGroups {
                let descriptor = groupDescriptor(group)
                let appNames = Set(group.managedWindows.map(\.appName)).sorted().joined(separator: " ")
                let score = scoreMatch(query: query, fields: [descriptor, appNames])
                guard score > 0 else { continue }
                groups.append(LauncherCandidate(
                    id: "group-\(group.id.uuidString)",
                    action: .mergeGroup(groupID: group.id),
                    tier: 1,
                    score: score,
                    displayName: descriptor,
                    subtitle: "\(group.managedWindowCount) tabs",
                    icon: group.activeWindow?.icon,
                    recency: context.groupRecency[group.id] ?? 0,
                    isRunningApp: false,
                    hasNativeNewWindow: true,
                    sectionTitleOverride: nil
                ))
            }
        }

        let actions = buildActionCandidates(query: query, context: context, now: now)
        let suggestions = buildSuggestions(
            query: query,
            context: context,
            now: now,
            hasExplicitURLIntent: hasExplicitURLIntent
        ) + actions
        let search = buildSearchCandidates(query: query, context: context)

        let regularWindows = windows.filter { $0.sectionTitleOverride != LauncherCandidate.mirrorTabsSectionTitle }
        let mirrorWindows = windows.filter { $0.sectionTitleOverride == LauncherCandidate.mirrorTabsSectionTitle }
        let ranked =
            sortWindows(regularWindows) +
            sortGroups(groups) +
            sortWindows(mirrorWindows) +
            sortSuggestions(suggestions) +
            sortSearches(search)

        Logger.log(
            "[LAUNCHER_RANK] ranked windows=\(windows.count) groups=\(groups.count) suggestions=\(suggestions.count) actions=\(actions.count) search=\(search.count)"
        )
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
                    displayName: window.title.isEmpty ? window.appName : window.title,
                    subtitle: window.title.isEmpty ? "" : window.appName,
                    icon: window.icon,
                    recency: context.windowRecency[window.id] ?? 0,
                    isRunningApp: false,
                    hasNativeNewWindow: true,
                    sectionTitleOverride: context.mirroredWindowIDs.contains(window.id) ? LauncherCandidate.mirrorTabsSectionTitle : nil
                )
            }
        let regularWindows = windows.filter { $0.sectionTitleOverride != LauncherCandidate.mirrorTabsSectionTitle }
        let mirrorWindows = windows.filter { $0.sectionTitleOverride == LauncherCandidate.mirrorTabsSectionTitle }
        let previewWindows = sortWindows(regularWindows).prefix(Self.previewWindowCap)
        let previewMirror = sortWindows(mirrorWindows).prefix(Self.previewWindowCap)

        let previewGroups: [LauncherCandidate]
        if context.mode.isAddToGroup {
            previewGroups = Array(sortGroups(context.mergeGroups.map { group in
                LauncherCandidate(
                    id: "group-\(group.id.uuidString)",
                    action: .mergeGroup(groupID: group.id),
                    tier: 1,
                    score: 1,
                    displayName: groupDescriptor(group),
                    subtitle: "\(group.managedWindowCount) tabs",
                    icon: group.activeWindow?.icon,
                    recency: context.groupRecency[group.id] ?? 0,
                    isRunningApp: false,
                    hasNativeNewWindow: true,
                    sectionTitleOverride: nil
                )
            }).prefix(Self.previewGroupCap))
        } else {
            previewGroups = []
        }

        let previewActions = previewActionCandidates(context: context)

        return previewActions + Array(previewWindows) + previewGroups + Array(previewMirror)
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

    private static func hasExplicitURLIntent(query: String) -> Bool {
        if query.contains(".") {
            return true
        }
        guard let components = URLComponents(string: query),
              let scheme = components.scheme?.lowercased() else {
            return false
        }
        return scheme == "http" || scheme == "https"
    }

    private func buildSuggestions(
        query: String,
        context: LauncherQueryContext,
        now: Date,
        hasExplicitURLIntent: Bool
    ) -> [LauncherCandidate] {
        var suggestions: [LauncherCandidate] = []

        for app in context.appCatalog {
            let base = scoreApp(query: query, app: app)
            guard base > 0 else { continue }

            let historyEntry = context.appLaunchHistory[app.bundleID]
            let usageBoost = appUsageBoost(entry: historyEntry, now: now)
            let runningBoost = app.isRunning ? 0.05 : 0
            let finalScore = base + usageBoost + runningBoost
            let historyRecency = historyEntry.map { Int($0.lastLaunchedAt.timeIntervalSince1970) } ?? 0

            suggestions.append(LauncherCandidate(
                id: "app-\(app.bundleID)",
                action: .appLaunch(bundleID: app.bundleID, appURL: app.appURL, isRunning: app.isRunning),
                tier: 2,
                score: finalScore,
                displayName: app.displayName,
                subtitle: app.bundleID,
                icon: app.icon,
                recency: max(context.appRecency[app.bundleID] ?? app.recency, historyRecency),
                isRunningApp: app.isRunning,
                hasNativeNewWindow: app.isRunning ? LaunchOrchestrator.hasNativeNewWindowSupport(bundleID: app.bundleID) : true,
                sectionTitleOverride: nil
            ))
        }

        if context.launcherConfig.urlLaunchEnabled {
            let intentBoost = hasExplicitURLIntent ? 0.4 : 0
            var historyByCanonical: [String: LauncherHistoryStore.URLEntry] = [:]
            for entry in context.urlHistory {
                guard let url = URL(string: entry.urlString) else { continue }
                historyByCanonical[LauncherHistoryStore.canonicalURLString(url)] = entry
            }

            var urlSuggestionsByCanonical: [String: LauncherCandidate] = [:]

            func upsertURLSuggestion(_ candidate: LauncherCandidate, canonical: String) {
                if let existing = urlSuggestionsByCanonical[canonical] {
                    if candidate.score > existing.score {
                        urlSuggestionsByCanonical[canonical] = candidate
                    } else if candidate.score == existing.score,
                              candidate.recency > existing.recency {
                        urlSuggestionsByCanonical[canonical] = candidate
                    }
                } else {
                    urlSuggestionsByCanonical[canonical] = candidate
                }
            }

            if let typedURL = Self.normalizeURL(from: query) {
                let canonical = LauncherHistoryStore.canonicalURLString(typedURL)
                let historyRecency = historyByCanonical[canonical].map { Int($0.lastLaunchedAt.timeIntervalSince1970) } ?? 0
                let typedCandidate = LauncherCandidate(
                    id: "url-typed-\(canonical)",
                    action: .openURL(url: typedURL),
                    tier: 2,
                    score: 1.0 + intentBoost,
                    displayName: "Open URL",
                    subtitle: typedURL.absoluteString,
                    icon: nil,
                    recency: historyRecency,
                    isRunningApp: false,
                    hasNativeNewWindow: true,
                    sectionTitleOverride: nil
                )
                upsertURLSuggestion(typedCandidate, canonical: canonical)
            }

            for entry in context.urlHistory {
                guard let url = URL(string: entry.urlString) else { continue }
                let host = url.host ?? ""
                let base = scoreMatch(query: query, fields: [host, url.absoluteString])
                guard base > 0 else { continue }

                let canonical = LauncherHistoryStore.canonicalURLString(url)
                let finalScore = base + urlUsageBoost(entry: entry, now: now) + intentBoost
                let hostDisplay = host.isEmpty ? "Open URL" : host

                let historyCandidate = LauncherCandidate(
                    id: "url-history-\(canonical)",
                    action: .openURL(url: url),
                    tier: 2,
                    score: finalScore,
                    displayName: hostDisplay,
                    subtitle: url.absoluteString,
                    icon: nil,
                    recency: Int(entry.lastLaunchedAt.timeIntervalSince1970),
                    isRunningApp: false,
                    hasNativeNewWindow: true,
                    sectionTitleOverride: nil
                )
                upsertURLSuggestion(historyCandidate, canonical: canonical)
            }

            suggestions.append(contentsOf: urlSuggestionsByCanonical.values)
        }

        return suggestions
    }

    private func buildSearchCandidates(query: String, context: LauncherQueryContext) -> [LauncherCandidate] {
        guard context.launcherConfig.searchLaunchEnabled else { return [] }

        return [
            LauncherCandidate(
                id: "search-\(query)",
                action: .webSearch(query: query),
                tier: 3,
                score: 0.1,
                displayName: "Web Search",
                subtitle: query,
                icon: nil,
                recency: 0,
                isRunningApp: false,
                hasNativeNewWindow: true,
                sectionTitleOverride: nil
            )
        ]
    }

    private func buildActionCandidates(query: String, context: LauncherQueryContext, now: Date) -> [LauncherCandidate] {
        if context.mode.isAddToGroup {
            var actions: [LauncherCandidate] = []

            let renameTitle = context.targetGroupDisplayName == nil ? "Name Group…" : "Rename Group…"
            let renameScore = scoreMatch(query: query, fields: ["name group", "rename group", "group name"])
            if renameScore > 0 {
                let action = LauncherAction.renameTargetGroup
                let history = action.historyKey.flatMap { context.actionHistory[$0] }
                actions.append(
                    LauncherCandidate(
                        id: "action-rename-target-group",
                        action: action,
                        tier: 2,
                        score: renameScore + actionUsageBoost(entry: history, now: now),
                        displayName: renameTitle,
                        subtitle: context.targetGroupDisplayName ?? "Current group",
                        icon: nil,
                        recency: history.map { Int($0.lastLaunchedAt.timeIntervalSince1970) } ?? 0,
                        isRunningApp: false,
                        hasNativeNewWindow: true,
                        sectionTitleOverride: nil
                    )
                )
            }

            let separatorScore = scoreMatch(query: query, fields: [
                "separator",
                "separator tab",
                "insert separator",
                "spacer",
                "gap between tabs"
            ])
            if separatorScore > 0 {
                let action = LauncherAction.insertSeparatorTab
                let history = action.historyKey.flatMap { context.actionHistory[$0] }
                actions.append(
                    LauncherCandidate(
                        id: "action-insert-separator-tab",
                        action: action,
                        tier: 2,
                        score: separatorScore + actionUsageBoost(entry: history, now: now),
                        displayName: "Insert Separator Tab",
                        subtitle: "Adds spacing between tabs",
                        icon: nil,
                        recency: history.map { Int($0.lastLaunchedAt.timeIntervalSince1970) } ?? 0,
                        isRunningApp: false,
                        hasNativeNewWindow: true,
                        sectionTitleOverride: nil
                    )
                )
            }

            let ungroupScore = scoreMatch(query: query, fields: ["ungroup", "release from group", "release all tabs"])
            if ungroupScore > 0 {
                let action = LauncherAction.ungroupTargetGroup
                let history = action.historyKey.flatMap { context.actionHistory[$0] }
                actions.append(
                    LauncherCandidate(
                        id: "action-ungroup-target-group",
                        action: action,
                        tier: 2,
                        score: ungroupScore + actionUsageBoost(entry: history, now: now),
                        displayName: "Ungroup",
                        subtitle: "\(context.targetGroupWindowCount ?? 0) windows",
                        icon: nil,
                        recency: history.map { Int($0.lastLaunchedAt.timeIntervalSince1970) } ?? 0,
                        isRunningApp: false,
                        hasNativeNewWindow: true,
                        sectionTitleOverride: nil
                    )
                )
            }

            let closeAllScore = scoreMatch(query: query, fields: ["close all windows", "close group", "close tabs"])
            if closeAllScore > 0 {
                let action = LauncherAction.closeAllWindowsInTargetGroup
                let history = action.historyKey.flatMap { context.actionHistory[$0] }
                actions.append(
                    LauncherCandidate(
                        id: "action-close-all-target-group",
                        action: action,
                        tier: 2,
                        score: closeAllScore + actionUsageBoost(entry: history, now: now),
                        displayName: "Close All Windows",
                        subtitle: "\(context.targetGroupWindowCount ?? 0) windows",
                        icon: nil,
                        recency: history.map { Int($0.lastLaunchedAt.timeIntervalSince1970) } ?? 0,
                        isRunningApp: false,
                        hasNativeNewWindow: true,
                        sectionTitleOverride: nil
                    )
                )
            }

            if context.targetActiveTabID != nil {
                let renameTabScore = scoreMatch(query: query, fields: ["rename tab", "name tab", "tab name"])
                if renameTabScore > 0 {
                    let action = LauncherAction.renameCurrentTab
                    let history = action.historyKey.flatMap { context.actionHistory[$0] }
                    actions.append(
                        LauncherCandidate(
                            id: "action-rename-current-tab",
                            action: action,
                            tier: 2,
                            score: renameTabScore + actionUsageBoost(entry: history, now: now),
                            displayName: "Rename Current Tab…",
                            subtitle: context.targetActiveTabTitle ?? "Active tab",
                            icon: nil,
                            recency: history.map { Int($0.lastLaunchedAt.timeIntervalSince1970) } ?? 0,
                            isRunningApp: false,
                            hasNativeNewWindow: true,
                            sectionTitleOverride: nil
                        )
                    )
                }

                let releaseTabScore = scoreMatch(query: query, fields: ["release tab", "release current tab", "remove tab from group"])
                if releaseTabScore > 0 {
                    let action = LauncherAction.releaseCurrentTab
                    let history = action.historyKey.flatMap { context.actionHistory[$0] }
                    actions.append(
                        LauncherCandidate(
                            id: "action-release-current-tab",
                            action: action,
                            tier: 2,
                            score: releaseTabScore + actionUsageBoost(entry: history, now: now),
                            displayName: "Release Current Tab",
                            subtitle: context.targetActiveTabTitle ?? "Active tab",
                            icon: nil,
                            recency: history.map { Int($0.lastLaunchedAt.timeIntervalSince1970) } ?? 0,
                            isRunningApp: false,
                            hasNativeNewWindow: true,
                            sectionTitleOverride: nil
                        )
                    )
                }
            }
            return actions
        }

        guard shouldOfferGroupAllInSpace(context: context) else { return [] }

        let score = scoreMatch(query: query, fields: ["add all in space", "group all in space", "all windows in space"])
        guard score > 0 else { return [] }

        let action = LauncherAction.groupAllInSpace
        let history = action.historyKey.flatMap { context.actionHistory[$0] }
        return [
            LauncherCandidate(
                id: "action-group-all-space",
                action: action,
                tier: 2,
                score: score + actionUsageBoost(entry: history, now: now),
                displayName: "Add All in Space",
                subtitle: "\(context.looseWindows.count) windows",
                icon: nil,
                recency: history.map { Int($0.lastLaunchedAt.timeIntervalSince1970) } ?? 0,
                isRunningApp: false,
                hasNativeNewWindow: true,
                sectionTitleOverride: nil
            )
        ]
    }

    private func previewActionCandidates(context: LauncherQueryContext) -> [LauncherCandidate] {
        guard shouldOfferGroupAllInSpace(context: context) else { return [] }
        return [
            LauncherCandidate(
                id: "action-group-all-space",
                action: .groupAllInSpace,
                tier: 2,
                score: 1,
                displayName: "Add All in Space",
                subtitle: "\(context.looseWindows.count) windows",
                icon: nil,
                recency: 0,
                isRunningApp: false,
                hasNativeNewWindow: true,
                sectionTitleOverride: nil
            )
        ]
    }

    private func scoreApp(query: String, app: AppCatalogService.AppRecord) -> Double {
        let base = scoreMatch(query: query, fields: [app.displayName, app.bundleID])
        if app.bundleID.lowercased().hasSuffix(query) {
            return max(base, 0.85)
        }
        return base
    }

    private func appUsageBoost(entry: LauncherHistoryStore.AppEntry?, now: Date) -> Double {
        guard let entry else { return 0 }
        let hoursSinceLast = max(0, now.timeIntervalSince(entry.lastLaunchedAt) / 3600)
        let frequencyBoost = 0.12 * log2(Double(entry.launchCount) + 1)
        let recencyBoost = 0.25 * exp(-hoursSinceLast / 168.0)
        return min(0.45, frequencyBoost + recencyBoost)
    }

    private func urlUsageBoost(entry: LauncherHistoryStore.URLEntry, now: Date) -> Double {
        let hoursSinceLast = max(0, now.timeIntervalSince(entry.lastLaunchedAt) / 3600)
        let frequencyBoost = 0.15 * log2(Double(entry.launchCount) + 1)
        let recencyBoost = 0.35 * exp(-hoursSinceLast / 168.0)
        return min(0.5, frequencyBoost + recencyBoost)
    }

    private func actionUsageBoost(entry: LauncherHistoryStore.ActionEntry?, now: Date) -> Double {
        guard let entry else { return 0 }
        let hoursSinceLast = max(0, now.timeIntervalSince(entry.lastLaunchedAt) / 3600)
        let frequencyBoost = 0.12 * log2(Double(entry.launchCount) + 1)
        let recencyBoost = 0.2 * exp(-hoursSinceLast / 168.0)
        return min(0.35, frequencyBoost + recencyBoost)
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
            let lhsIsMirror = lhs.sectionTitleOverride == LauncherCandidate.mirrorTabsSectionTitle
            let rhsIsMirror = rhs.sectionTitleOverride == LauncherCandidate.mirrorTabsSectionTitle
            if lhsIsMirror != rhsIsMirror { return !lhsIsMirror }
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

    private func sortSuggestions(_ candidates: [LauncherCandidate]) -> [LauncherCandidate] {
        candidates.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.isRunningApp != rhs.isRunningApp { return lhs.isRunningApp }
            if lhs.recency != rhs.recency { return lhs.recency > rhs.recency }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    private func sortSearches(_ candidates: [LauncherCandidate]) -> [LauncherCandidate] {
        candidates.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    private func shouldOfferGroupAllInSpace(context: LauncherQueryContext) -> Bool {
        guard !context.mode.isAddToGroup else { return false }
        return context.looseWindows.count > 1
    }

    private func groupDescriptor(_ group: TabGroup) -> String {
        let appNames = Array(Set(group.managedWindows.map(\.appName))).sorted()
        if appNames.count == 1, let appName = appNames.first {
            return "\(group.managedWindowCount) \(appName) windows"
        }
        if appNames.count <= 2 {
            return appNames.joined(separator: ", ")
        }
        return "\(appNames.prefix(2).joined(separator: ", ")) + \(appNames.count - 2) more"
    }
}
