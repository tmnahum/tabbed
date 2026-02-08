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
            return w.title.isEmpty ? w.appName : w.title
        case .group(let g):
            guard let active = g.activeWindow else { return "" }
            return active.title.isEmpty ? active.appName : active.title
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
        case .group(let g): return g.windows.map(\.icon)
        }
    }

    /// Number of windows this entry represents.
    var windowCount: Int {
        switch self {
        case .singleWindow: return 1
        case .group(let g): return g.windows.count
        }
    }

    /// All window IDs covered by this entry.
    var windowIDs: [CGWindowID] {
        switch self {
        case .singleWindow(let w): return [w.id]
        case .group(let g): return g.windows.map(\.id)
        }
    }
}
