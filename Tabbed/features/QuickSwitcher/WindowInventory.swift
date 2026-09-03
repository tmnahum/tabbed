import Combine
import CoreGraphics
import Foundation

/// Caches expensive all-spaces window discovery for switcher reads.
/// All methods are expected to run on the main thread.
final class WindowInventory: ObservableObject {
    typealias DiscoverAllSpaces = () -> [WindowInfo]
    typealias Now = () -> Date

    private let staleAfter: TimeInterval
    private let discoverAllSpaces: DiscoverAllSpaces
    private let now: Now

    @Published private(set) var cachedAllSpacesWindows: [WindowInfo] = []
    private(set) var lastRefreshAt: Date?
    private var asyncRefreshInFlight = false
    private var refreshVersion: UInt64 = 0
    var hasCompletedRefresh: Bool { lastRefreshAt != nil }

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
    func refreshSync(force: Bool = false) {
        guard !asyncRefreshInFlight || force else { return }
        let version = nextRefreshVersion()
        applyRefreshResult(discoverAllSpaces(), version: version, fromAsync: false)
    }

    /// Refresh cache in the background when no refresh is currently running.
    func refreshAsync() {
        guard !asyncRefreshInFlight else { return }
        asyncRefreshInFlight = true
        let version = nextRefreshVersion()
        DispatchQueue.global(qos: .userInitiated).async { [discoverAllSpaces] in
            let windows = discoverAllSpaces()
            DispatchQueue.main.async { [weak self] in
                self?.applyRefreshResult(windows, version: version, fromAsync: true)
            }
        }
    }

    func removeCachedWindow(withID windowID: CGWindowID) {
        cachedAllSpacesWindows.removeAll { $0.id == windowID }
    }

    private var isStale: Bool {
        guard let lastRefreshAt else { return true }
        return now().timeIntervalSince(lastRefreshAt) >= staleAfter
    }

    private func nextRefreshVersion() -> UInt64 {
        refreshVersion &+= 1
        return refreshVersion
    }

    private func applyRefreshResult(_ windows: [WindowInfo], version: UInt64, fromAsync: Bool) {
        if fromAsync {
            asyncRefreshInFlight = false
        }
        guard version == refreshVersion else { return }
        cachedAllSpacesWindows = windows
        lastRefreshAt = now()
    }
}
