import AppKit

/// One entry in the quick switcher: either a standalone window or a tab group.
enum SwitcherItem: Identifiable {
    case singleWindow(WindowInfo)
    case group(TabGroup)

    var id: String {
        switch self {
        case .singleWindow(let w): return "window-\(w.id)"
        case .group(let g): return "group-\(g.id.uuidString)"
        }
    }

    var isGroup: Bool {
        if case .group = self { return true }
        return false
    }

    /// Title to display — active window's title (or app name if empty).
    var displayTitle: String {
        switch self {
        case .singleWindow(let w):
            return w.displayTitle
        case .group(let g):
            if let name = g.displayName {
                return name
            }
            guard let active = g.activeWindow else { return "" }
            return active.displayTitle
        }
    }

    /// App name for the primary/active window.
    var appName: String {
        switch self {
        case .singleWindow(let w): return w.appName
        case .group(let g): return g.activeWindow?.appName ?? ""
        }
    }

    /// All icons for this entry (one for single window, all for group).
    var icons: [NSImage?] {
        switch self {
        case .singleWindow(let w): return [w.icon]
        case .group(let g): return g.managedWindows.map(\.icon)
        }
    }

    /// Number of windows this entry represents.
    var windowCount: Int {
        switch self {
        case .singleWindow: return 1
        case .group(let g): return g.managedWindowCount
        }
    }

    /// All window IDs covered by this entry.
    var windowIDs: [CGWindowID] {
        switch self {
        case .singleWindow(let w): return [w.id]
        case .group(let g): return g.managedWindows.map(\.id)
        }
    }

    /// Returns a specific window from a group by index, or nil for single windows.
    func window(at index: Int) -> WindowInfo? {
        guard case .group(let g) = self else { return nil }
        return g.managedWindows[safe: index]
    }

    /// Icon + fullscreen state for ZStack display, capped to `maxVisible`.
    /// Shows a sliding window into the MRU list anchored on the target.
    ///
    /// ZStack renders last element on top, so returned array is:
    ///   [0] = furthest from target (back)  ...  [last] = target (top)
    func iconsInMRUOrder(frontIndex: Int?, maxVisible: Int) -> [(icon: NSImage?, isFullscreened: Bool)] {
        guard case .group(let g) = self else {
            if case .singleWindow(let w) = self {
                return [(icon: w.icon, isFullscreened: w.isFullscreened)]
            }
            return []
        }

        // Build MRU list: most-recent first, windows without history at the end
        let windowIDs = Set(g.managedWindows.map(\.id))
        let mruIDs = g.focusHistory.filter { windowIDs.contains($0) }
        let remainingIDs = g.managedWindows.map(\.id).filter { !mruIDs.contains($0) }
        let mruList: [WindowInfo] = (mruIDs + remainingIDs).compactMap { id in
            g.managedWindows.first { $0.id == id }
        }

        // Find the target's position in MRU order (default: 0 = most-recent)
        var targetPos = 0
        if let fi = frontIndex, let target = g.managedWindows[safe: fi],
           let pos = mruList.firstIndex(where: { $0.id == target.id }) {
            targetPos = pos
        }

        // Slide a window of maxVisible starting at the target, wrapping around
        let count = min(maxVisible, mruList.count)
        var visible: [WindowInfo] = []
        for i in 0..<count {
            visible.append(mruList[(targetPos + i) % mruList.count])
        }

        // Reverse for ZStack: target (first in visible) becomes last (on top)
        return visible.reversed().map { (icon: $0.icon, isFullscreened: $0.isFullscreened) }
    }

    /// Whether the sub-selected (or active) window is fullscreened.
    func isWindowFullscreened(at index: Int?) -> Bool {
        switch self {
        case .singleWindow(let w): return w.isFullscreened
        case .group(let g):
            if let index { return g.managedWindows[safe: index]?.isFullscreened ?? false }
            return g.activeWindow?.isFullscreened ?? false
        }
    }
}
