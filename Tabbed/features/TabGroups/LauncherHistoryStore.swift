import Foundation

final class LauncherHistoryStore {
    struct URLEntry: Codable, Equatable {
        let urlString: String
        let launchCount: Int
        let lastLaunchedAt: Date
    }

    struct AppEntry: Codable, Equatable {
        let bundleID: String
        let launchCount: Int
        let lastLaunchedAt: Date
    }

    private struct Snapshot: Codable {
        var urls: [URLEntry]
        var apps: [AppEntry]
    }

    static let defaultStorageKey = "addWindowLauncherHistory.v1"

    private let userDefaults: UserDefaults
    private let storageKey: String
    private let nowProvider: () -> Date
    private let urlLimit: Int
    private let appLimit: Int

    init(
        userDefaults: UserDefaults = .standard,
        storageKey: String = LauncherHistoryStore.defaultStorageKey,
        nowProvider: @escaping () -> Date = Date.init,
        urlLimit: Int = 300,
        appLimit: Int = 200
    ) {
        self.userDefaults = userDefaults
        self.storageKey = storageKey
        self.nowProvider = nowProvider
        self.urlLimit = urlLimit
        self.appLimit = appLimit
    }

    func urlEntries() -> [URLEntry] {
        loadSnapshot().urls
    }

    func appEntriesByBundleID() -> [String: AppEntry] {
        Dictionary(uniqueKeysWithValues: loadSnapshot().apps.map { ($0.bundleID, $0) })
    }

    func recordURLLaunch(_ url: URL, outcome: LaunchAttemptResult) {
        guard Self.shouldRecord(outcome: outcome) else { return }
        guard !Self.isSearchURL(url) else { return }

        let canonical = Self.canonicalURLString(url)
        let now = nowProvider()

        var snapshot = loadSnapshot()
        if let index = snapshot.urls.firstIndex(where: { entry in
            guard let existingURL = URL(string: entry.urlString) else { return false }
            return Self.canonicalURLString(existingURL) == canonical
        }) {
            let existing = snapshot.urls[index]
            snapshot.urls[index] = URLEntry(
                urlString: canonical,
                launchCount: existing.launchCount + 1,
                lastLaunchedAt: now
            )
        } else {
            snapshot.urls.append(URLEntry(urlString: canonical, launchCount: 1, lastLaunchedAt: now))
        }

        snapshot.urls.sort { lhs, rhs in
            if lhs.lastLaunchedAt != rhs.lastLaunchedAt { return lhs.lastLaunchedAt > rhs.lastLaunchedAt }
            if lhs.launchCount != rhs.launchCount { return lhs.launchCount > rhs.launchCount }
            return lhs.urlString.localizedCaseInsensitiveCompare(rhs.urlString) == .orderedAscending
        }
        if snapshot.urls.count > urlLimit {
            snapshot.urls = Array(snapshot.urls.prefix(urlLimit))
        }

        saveSnapshot(snapshot)
    }

    func recordAppLaunch(bundleID: String, outcome: LaunchAttemptResult) {
        guard Self.shouldRecord(outcome: outcome) else { return }

        let trimmedBundleID = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBundleID.isEmpty else { return }

        let now = nowProvider()
        var snapshot = loadSnapshot()

        if let index = snapshot.apps.firstIndex(where: { $0.bundleID == trimmedBundleID }) {
            let existing = snapshot.apps[index]
            snapshot.apps[index] = AppEntry(
                bundleID: trimmedBundleID,
                launchCount: existing.launchCount + 1,
                lastLaunchedAt: now
            )
        } else {
            snapshot.apps.append(AppEntry(bundleID: trimmedBundleID, launchCount: 1, lastLaunchedAt: now))
        }

        snapshot.apps.sort { lhs, rhs in
            if lhs.lastLaunchedAt != rhs.lastLaunchedAt { return lhs.lastLaunchedAt > rhs.lastLaunchedAt }
            if lhs.launchCount != rhs.launchCount { return lhs.launchCount > rhs.launchCount }
            return lhs.bundleID.localizedCaseInsensitiveCompare(rhs.bundleID) == .orderedAscending
        }
        if snapshot.apps.count > appLimit {
            snapshot.apps = Array(snapshot.apps.prefix(appLimit))
        }

        saveSnapshot(snapshot)
    }

    static func canonicalURLString(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }

        if let scheme = components.scheme {
            components.scheme = scheme.lowercased()
        }
        if let host = components.host {
            components.host = host.lowercased()
        }
        components.fragment = nil
        return components.url?.absoluteString ?? url.absoluteString
    }

    static func isSearchURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let hostRaw = components.host?.lowercased() else {
            return false
        }

        let host = hostRaw.hasPrefix("www.") ? String(hostRaw.dropFirst(4)) : hostRaw
        let queryKeys = Set((components.queryItems ?? []).map { $0.name.lowercased() })
        guard !queryKeys.isDisjoint(with: searchQueryParameterKeys) else {
            return false
        }

        if knownSearchHosts.contains(host) {
            return true
        }

        return knownSearchHostSuffixes.contains { host.hasSuffix($0) }
    }

    private static let searchQueryParameterKeys: Set<String> = [
        "q", "p", "query", "text", "wd", "keyword", "search_query"
    ]

    private static let knownSearchHosts: Set<String> = [
        "google.com",
        "bing.com",
        "duckduckgo.com",
        "search.yahoo.com",
        "yahoo.com",
        "search.brave.com",
        "ecosia.org",
        "yandex.com",
        "yandex.ru",
        "baidu.com"
    ]

    private static let knownSearchHostSuffixes: Set<String> = [
        ".google.com",
        ".bing.com",
        ".duckduckgo.com",
        ".yahoo.com",
        ".ecosia.org",
        ".yandex.com",
        ".yandex.ru",
        ".baidu.com"
    ]

    private static func shouldRecord(outcome: LaunchAttemptResult) -> Bool {
        switch outcome {
        case .succeeded, .timedOut:
            return true
        case .failed:
            return false
        }
    }

    private func loadSnapshot() -> Snapshot {
        guard let data = userDefaults.data(forKey: storageKey),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else {
            return Snapshot(urls: [], apps: [])
        }
        return snapshot
    }

    private func saveSnapshot(_ snapshot: Snapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        userDefaults.set(data, forKey: storageKey)
    }
}
