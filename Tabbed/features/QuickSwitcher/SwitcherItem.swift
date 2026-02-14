import AppKit

/// One entry in the quick switcher: either a standalone window or a tab group.
enum SwitcherItem: Identifiable {
    case singleWindow(WindowInfo)
    case group(TabGroup)
    case groupSegment(TabGroup, windowIDs: [CGWindowID])

    var id: String {
        switch self {
        case .singleWindow(let w): return "window-\(w.id)"
        case .group(let g): return "group-\(g.id.uuidString)"
        case .groupSegment(let g, let windowIDs):
            let key = windowIDs.map(String.init).joined(separator: "-")
            return "group-\(g.id.uuidString)-segment-\(key)"
        }
    }

    var isGroup: Bool {
        switch self {
        case .group, .groupSegment:
            return true
        case .singleWindow:
            return false
        }
    }

    var isSegmentedGroup: Bool {
        if case .groupSegment = self { return true }
        return false
    }

    var tabGroup: TabGroup? {
        switch self {
        case .singleWindow:
            return nil
        case .group(let g), .groupSegment(let g, _):
            return g
        }
    }

    /// Group used for named-group labels in switcher UI.
    var namedGroup: TabGroup? {
        switch self {
        case .group(let g), .groupSegment(let g, _):
            return g
        case .singleWindow:
            return nil
        }
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
        case .groupSegment(let g, let windowIDs):
            return primaryWindow(in: g, windowIDs: windowIDs)?.displayTitle ?? ""
        }
    }

    /// App name for the primary/active window.
    var appName: String {
        switch self {
        case .singleWindow(let w): return w.appName
        case .group(let g): return g.activeWindow?.appName ?? ""
        case .groupSegment(let g, let windowIDs):
            return primaryWindow(in: g, windowIDs: windowIDs)?.appName ?? ""
        }
    }

    /// All icons for this entry (one for single window, all for group).
    var icons: [NSImage?] {
        switch self {
        case .singleWindow(let w): return [w.icon]
        case .group(let g): return g.managedWindows.map(\.icon)
        case .groupSegment(let g, let windowIDs):
            return representedWindows(in: g, windowIDs: windowIDs).map(\.icon)
        }
    }

    /// Number of windows this entry represents.
    var windowCount: Int {
        switch self {
        case .singleWindow: return 1
        case .group(let g): return g.managedWindowCount
        case .groupSegment(_, let windowIDs): return windowIDs.count
        }
    }

    /// All window IDs covered by this entry.
    var windowIDs: [CGWindowID] {
        switch self {
        case .singleWindow(let w): return [w.id]
        case .group(let g): return g.managedWindows.map(\.id)
        case .groupSegment(_, let windowIDs): return windowIDs
        }
    }

    /// Returns a specific window from a group by index, or nil for single windows.
    func window(at index: Int) -> WindowInfo? {
        switch self {
        case .singleWindow:
            return nil
        case .group(let g):
            return g.managedWindows[safe: index]
        case .groupSegment(let g, let windowIDs):
            guard let windowID = windowIDs[safe: index] else { return nil }
            return g.managedWindows.first(where: { $0.id == windowID })
        }
    }

    /// Icon + fullscreen state for ZStack display, capped to `maxVisible`.
    /// Shows a sliding window into the MRU list anchored on the target.
    ///
    /// ZStack renders last element on top, so returned array is:
    ///   [0] = furthest from target (back)  ...  [last] = target (top)
    func iconsInMRUOrder(frontIndex: Int?, maxVisible: Int) -> [(icon: NSImage?, isFullscreened: Bool)] {
        guard let group = tabGroup else {
            if case .singleWindow(let w) = self { return [(icon: w.icon, isFullscreened: w.isFullscreened)] }
            return []
        }

        let represented = representedWindows(in: group, windowIDs: windowIDsForGroupContext())
        let representedIDs = Set(represented.map(\.id))
        let mruIDs = group.focusHistory.filter { representedIDs.contains($0) }
        let mruIDSet = Set(mruIDs)
        let remainingIDs = represented.map(\.id).filter { !mruIDSet.contains($0) }
        let mruList: [WindowInfo] = (mruIDs + remainingIDs).compactMap { id in
            represented.first { $0.id == id }
        }
        guard !mruList.isEmpty else { return [] }

        // Find the target's position in MRU order (default: 0 = most-recent)
        var targetPos = 0
        if let fi = frontIndex, let target = window(at: fi),
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
        case .groupSegment(let g, let windowIDs):
            if let index { return window(at: index)?.isFullscreened ?? false }
            return primaryWindow(in: g, windowIDs: windowIDs)?.isFullscreened ?? false
        }
    }

    private func windowIDsForGroupContext() -> [CGWindowID]? {
        switch self {
        case .group:
            return nil
        case .groupSegment(_, let windowIDs):
            return windowIDs
        case .singleWindow:
            return nil
        }
    }

    private func representedWindows(in group: TabGroup, windowIDs: [CGWindowID]?) -> [WindowInfo] {
        guard let windowIDs else { return group.managedWindows }
        let windowsByID = Dictionary(uniqueKeysWithValues: group.managedWindows.map { ($0.id, $0) })
        return windowIDs.compactMap { windowsByID[$0] }
    }

    private func primaryWindow(in group: TabGroup, windowIDs: [CGWindowID]) -> WindowInfo? {
        let windows = representedWindows(in: group, windowIDs: windowIDs)
        guard !windows.isEmpty else { return nil }

        if let active = group.activeWindow, windowIDs.contains(active.id) {
            return active
        }
        if let mruID = group.focusHistory.first(where: { windowIDs.contains($0) }),
           let mruWindow = windows.first(where: { $0.id == mruID }) {
            return mruWindow
        }
        return windows.first
    }
}
