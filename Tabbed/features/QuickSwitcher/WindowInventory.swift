import Foundation

/// Caches expensive all-spaces window discovery for switcher reads.
/// All methods are expected to run on the main thread.
final class WindowInventory {
    typealias DiscoverAllSpaces = () -> [WindowInfo]
    typealias Now = () -> Date

    private let staleAfter: TimeInterval
    private let discoverAllSpaces: DiscoverAllSpaces
    private let now: Now

    private(set) var cachedAllSpacesWindows: [WindowInfo] = []
    private(set) var lastRefreshAt: Date?
    private var refreshInFlight = false

    init(
        staleAfter: TimeInterval = 0.75,
        discoverAllSpaces: @escaping DiscoverAllSpaces = { WindowDiscovery.allSpaces() },
        now: @escaping Now = Date.init
    ) {
        self.staleAfter = staleAfter
        self.discoverAllSpaces = discoverAllSpaces
        self.now = now
    }

    /// Returns the current cache and schedules a refresh if needed.
    /// Never blocks the caller on a fresh discovery.
    func allSpacesForSwitcher() -> [WindowInfo] {
        if cachedAllSpacesWindows.isEmpty || isStale {
            refreshAsync()
        }
        return cachedAllSpacesWindows
    }

    /// Force a synchronous cache fill/update.
    func refreshSync() {
        guard !refreshInFlight else { return }
        refreshInFlight = true
        applyRefreshResult(discoverAllSpaces())
    }

    /// Refresh cache in the background when no refresh is currently running.
    func refreshAsync() {
        guard !refreshInFlight else { return }
        refreshInFlight = true
        DispatchQueue.global(qos: .userInitiated).async { [discoverAllSpaces] in
            let windows = discoverAllSpaces()
            DispatchQueue.main.async { [weak self] in
                self?.applyRefreshResult(windows)
            }
        }
    }

    private var isStale: Bool {
        guard let lastRefreshAt else { return true }
        return now().timeIntervalSince(lastRefreshAt) >= staleAfter
    }

    private func applyRefreshResult(_ windows: [WindowInfo]) {
        cachedAllSpacesWindows = windows
        lastRefreshAt = now()
        refreshInFlight = false
    }
}
