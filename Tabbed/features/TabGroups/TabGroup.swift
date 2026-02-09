import Foundation
import CoreGraphics

class TabGroup: Identifiable, ObservableObject {
    let id = UUID()
    @Published var windows: [WindowInfo]
    @Published var activeIndex: Int
    @Published var frame: CGRect
    /// Insertion index shown as a drop indicator when another group is dragging tabs over this group's tab bar.
    @Published var dropIndicatorIndex: Int? = nil
    /// How many pixels the window was squeezed down when the group was created (0 if no squeeze was needed).
    var tabBarSqueezeDelta: CGFloat = 0
    /// Stored frame before zoom, used to restore on second double-click.
    var preZoomFrame: CGRect?
    /// The macOS Space this group belongs to. 0 means unknown (e.g. restored groups that couldn't resolve their space).
    var spaceID: UInt64

    /// MRU focus history — most recently focused window ID first.
    private(set) var focusHistory: [CGWindowID] = []
    /// Whether we're mid-cycle (Hyper+Tab held). Prevents focus handlers from updating MRU order.
    private(set) var isCycling = false
    /// Frozen snapshot of MRU order for the current cycle (prevents mid-cycle mutations from causing revisits).
    private var cycleOrder: [CGWindowID] = []
    private var cyclePosition = 0

    var activeWindow: WindowInfo? {
        guard activeIndex >= 0, activeIndex < windows.count else { return nil }
        return windows[activeIndex]
    }

    var fullscreenedWindowIDs: Set<CGWindowID> {
        Set(windows.filter(\.isFullscreened).map(\.id))
    }

    /// Windows that are not in fullscreen — used for frame sync operations.
    var visibleWindows: [WindowInfo] {
        windows.filter { !$0.isFullscreened }
    }

    init(windows: [WindowInfo], frame: CGRect, spaceID: UInt64 = 0) {
        self.windows = windows
        self.activeIndex = 0
        self.frame = frame
        self.spaceID = spaceID
        // Seed focus history with initial window order
        self.focusHistory = windows.map(\.id)
    }

    func contains(windowID: CGWindowID) -> Bool {
        windows.contains { $0.id == windowID }
    }

    func addWindow(_ window: WindowInfo, at index: Int? = nil) {
        guard !contains(windowID: window.id) else { return }
        if let index, index >= 0, index <= windows.count {
            windows.insert(window, at: index)
            if index <= activeIndex {
                activeIndex += 1
            }
        } else {
            windows.append(window)
        }
        focusHistory.append(window.id)
    }

    func removeWindow(at index: Int) -> WindowInfo? {
        guard index >= 0, index < windows.count else { return nil }
        let removed = windows.remove(at: index)
        focusHistory.removeAll { $0 == removed.id }
        cycleOrder.removeAll { $0 == removed.id }
        if activeIndex >= windows.count {
            activeIndex = max(0, windows.count - 1)
        } else if index < activeIndex {
            activeIndex -= 1
        }
        return removed
    }

    func removeWindow(withID windowID: CGWindowID) -> WindowInfo? {
        guard let index = windows.firstIndex(where: { $0.id == windowID }) else { return nil }
        return removeWindow(at: index)
    }

    /// Remove multiple windows by ID. Returns removed windows in their original order.
    func removeWindows(withIDs ids: Set<CGWindowID>) -> [WindowInfo] {
        guard !ids.isEmpty else { return [] }

        let activeID = activeWindow?.id
        var removed: [WindowInfo] = []

        // Remove from end to avoid index shifting issues
        for index in stride(from: windows.count - 1, through: 0, by: -1) {
            if ids.contains(windows[index].id) {
                let window = windows.remove(at: index)
                focusHistory.removeAll { $0 == window.id }
                cycleOrder.removeAll { $0 == window.id }
                removed.append(window)
            }
        }
        removed.reverse() // Restore original order

        // Fix activeIndex
        if windows.isEmpty {
            activeIndex = 0
        } else if let activeID, let newIndex = windows.firstIndex(where: { $0.id == activeID }) {
            activeIndex = newIndex
        } else {
            activeIndex = max(0, min(activeIndex, windows.count - 1))
        }

        return removed
    }

    func switchTo(index: Int) {
        guard index >= 0, index < windows.count else { return }
        activeIndex = index
    }

    func switchTo(windowID: CGWindowID) {
        guard let index = windows.firstIndex(where: { $0.id == windowID }) else { return }
        activeIndex = index
    }

    // MARK: - MRU Focus Tracking

    func recordFocus(windowID: CGWindowID) {
        focusHistory.removeAll { $0 == windowID }
        focusHistory.insert(windowID, at: 0)
    }

    /// Returns the index of the next window in MRU order.
    /// Snapshots the MRU order on first call so mid-cycle focus events can't cause revisits.
    func nextInMRUCycle() -> Int? {
        guard windows.filter({ !$0.isFullscreened }).count > 1 else { return nil }

        if !isCycling {
            isCycling = true
            // Snapshot: freeze MRU order, filtered to windows still in the group
            let windowIDs = Set(windows.filter { !$0.isFullscreened }.map(\.id))
            cycleOrder = focusHistory.filter { windowIDs.contains($0) }
            if cycleOrder.isEmpty { cycleOrder = windows.map(\.id) }
            cyclePosition = 0
        }

        guard cycleOrder.count > 1 else { return nil }

        // Advance, skipping any windows removed mid-cycle
        for _ in 0..<cycleOrder.count {
            cyclePosition = (cyclePosition + 1) % cycleOrder.count
            let nextID = cycleOrder[cyclePosition]
            if let index = windows.firstIndex(where: { $0.id == nextID }) {
                return index
            }
        }

        return (activeIndex + 1) % windows.count
    }

    /// End a cycling session: commit the landed-on window to MRU front and reset.
    func endCycle() {
        isCycling = false
        // Use the snapshot position — immune to focus-event races that change activeIndex
        let landedID: CGWindowID? = {
            guard !cycleOrder.isEmpty, cyclePosition < cycleOrder.count else { return nil }
            let id = cycleOrder[cyclePosition]
            return windows.contains(where: { $0.id == id }) ? id : nil
        }()
        if let id = landedID ?? activeWindow?.id {
            recordFocus(windowID: id)
        }
        cycleOrder = []
        cyclePosition = 0
    }

    // MARK: - Tab Reordering

    func moveTab(from source: Int, to destination: Int) {
        guard source >= 0, source < windows.count,
              destination >= 0, destination <= windows.count else { return }

        let wasActive = source == activeIndex
        let window = windows.remove(at: source)

        let adjustedDestination = destination > source ? destination - 1 : destination
        windows.insert(window, at: adjustedDestination)

        if wasActive {
            activeIndex = adjustedDestination
        } else if source < activeIndex, adjustedDestination >= activeIndex {
            activeIndex -= 1
        } else if source > activeIndex, adjustedDestination <= activeIndex {
            activeIndex += 1
        }
    }

    /// Move multiple tabs so they form a contiguous block starting at `toIndex` in the final array.
    /// Preserves relative order of moved tabs. `toIndex` is clamped to valid range.
    func moveTabs(withIDs ids: Set<CGWindowID>, toIndex: Int) {
        let moved = windows.filter { ids.contains($0.id) }
        guard !moved.isEmpty else { return }

        let activeID = activeWindow?.id
        windows.removeAll { ids.contains($0.id) }
        let insertAt = max(0, min(toIndex, windows.count))
        windows.insert(contentsOf: moved, at: insertAt)

        if let activeID, let newIndex = windows.firstIndex(where: { $0.id == activeID }) {
            activeIndex = newIndex
        }
    }
}
