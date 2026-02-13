import Foundation
import CoreGraphics

class TabGroup: Identifiable, ObservableObject {
    let id = UUID()
    @Published var windows: [WindowInfo]
    @Published var activeIndex: Int
    @Published var frame: CGRect
    @Published var name: String?
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

    private static var separatorIDSeed: CGWindowID = 4_000_000_000

    var activeWindow: WindowInfo? {
        guard let index = nearestNonSeparatorIndex(from: activeIndex) else { return nil }
        return windows[index]
    }

    var displayName: String? {
        guard let name else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var managedWindows: [WindowInfo] {
        windows.filter { !$0.isSeparator }
    }

    var managedWindowCount: Int {
        managedWindows.count
    }

    var fullscreenedWindowIDs: Set<CGWindowID> {
        Set(managedWindows.filter(\.isFullscreened).map(\.id))
    }

    /// Windows that are not in fullscreen — used for frame sync operations.
    var visibleWindows: [WindowInfo] {
        managedWindows.filter { !$0.isFullscreened }
    }

    var pinnedCount: Int {
        windows.filter { $0.isPinned && !$0.isSeparator }.count
    }

    init(windows: [WindowInfo], frame: CGRect, spaceID: UInt64 = 0, name: String? = nil) {
        self.windows = windows
        self.activeIndex = 0
        self.frame = frame
        self.spaceID = spaceID
        self.name = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        // Seed focus history with initial real-window order
        self.focusHistory = windows.filter { !$0.isSeparator }.map(\.id)
        ensureActiveOnRealWindow(preferredIndex: 0)
    }

    func contains(windowID: CGWindowID) -> Bool {
        windows.contains { $0.id == windowID }
    }

    func addSeparator(at index: Int? = nil) -> CGWindowID {
        let separatorID = Self.nextSeparatorID()
        let separator = WindowInfo.separator(withID: separatorID)
        addWindow(separator, at: index)
        return separatorID
    }

    func addWindow(_ window: WindowInfo, at index: Int? = nil) {
        guard !contains(windowID: window.id) else { return }
        let insertionIndex: Int
        if window.isPinned && !window.isSeparator {
            let boundary = pinnedCount
            insertionIndex = max(0, min(index ?? boundary, boundary))
        } else {
            let boundary = pinnedCount
            insertionIndex = max(boundary, min(index ?? windows.count, windows.count))
        }

        if insertionIndex >= 0, insertionIndex <= windows.count {
            windows.insert(window, at: insertionIndex)
            if insertionIndex <= activeIndex {
                activeIndex += 1
            }
        }
        if !window.isSeparator {
            focusHistory.append(window.id)
        }
    }

    func removeWindow(at index: Int) -> WindowInfo? {
        guard index >= 0, index < windows.count else { return nil }
        let removed = windows.remove(at: index)
        let wasActive = index == activeIndex
        let activeWasMRU = !removed.isSeparator && wasActive && focusHistory.first == removed.id
        focusHistory.removeAll { $0 == removed.id }
        cycleOrder.removeAll { $0 == removed.id }

        if windows.isEmpty {
            activeIndex = 0
        } else if wasActive {
            // If active focus history is trustworthy, switch to MRU; otherwise prefer the previous tab.
            if activeWasMRU,
               let mruID = focusHistory.first,
               let mruIndex = windows.firstIndex(where: { $0.id == mruID }) {
                activeIndex = mruIndex
            } else {
                // If MRU history is unavailable, prefer the tab immediately before the removed one.
                activeIndex = max(0, min(index - 1, windows.count - 1))
            }
        } else if index < activeIndex {
            activeIndex -= 1
        }

        dropSeparatorsIfNoRealWindows()
        ensureActiveOnRealWindow()
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
        let previousActiveIndex = activeIndex
        let activeWasMRU = activeID != nil && focusHistory.first == activeID
        var removed: [WindowInfo] = []
        var removedOriginalIndices: [Int] = []

        // Remove from end to avoid index shifting issues
        for index in stride(from: windows.count - 1, through: 0, by: -1) {
            if ids.contains(windows[index].id) {
                let window = windows.remove(at: index)
                focusHistory.removeAll { $0 == window.id }
                cycleOrder.removeAll { $0 == window.id }
                removed.append(window)
                removedOriginalIndices.append(index)
            }
        }
        removed.reverse() // Restore original order

        // Fix activeIndex
        if windows.isEmpty {
            activeIndex = 0
        } else if let activeID, let newIndex = windows.firstIndex(where: { $0.id == activeID }) {
            activeIndex = newIndex
        } else if activeWasMRU,
                  let mruID = focusHistory.first,
                  let mruIndex = windows.firstIndex(where: { $0.id == mruID }) {
            activeIndex = mruIndex
        } else {
            let removedBeforeActive = removedOriginalIndices.filter { $0 < previousActiveIndex }.count
            let preferredIndex = previousActiveIndex - removedBeforeActive - 1
            activeIndex = max(0, min(preferredIndex, windows.count - 1))
        }

        dropSeparatorsIfNoRealWindows()
        ensureActiveOnRealWindow()
        return removed
    }

    func switchTo(index: Int) {
        guard index >= 0, index < windows.count else { return }
        guard let resolvedIndex = nearestNonSeparatorIndex(from: index) else { return }
        activeIndex = resolvedIndex
    }

    func switchTo(windowID: CGWindowID) {
        guard let index = windows.firstIndex(where: { $0.id == windowID }) else { return }
        switchTo(index: index)
    }

    // MARK: - MRU Focus Tracking

    func recordFocus(windowID: CGWindowID) {
        guard let window = windows.first(where: { $0.id == windowID }),
              !window.isSeparator else { return }
        focusHistory.removeAll { $0 == windowID }
        focusHistory.insert(windowID, at: 0)
    }

    func beginCycle() {
        guard !isCycling else { return }
        guard managedWindows.filter({ !$0.isFullscreened }).count > 1 else { return }
        isCycling = true
        let windowIDs = Set(managedWindows.filter { !$0.isFullscreened }.map(\.id))
        cycleOrder = focusHistory.filter { windowIDs.contains($0) }
        if cycleOrder.isEmpty { cycleOrder = managedWindows.map(\.id) }
        cyclePosition = 0
    }

    /// Returns the index of the next window in MRU order.
    /// Snapshots the MRU order on first call so mid-cycle focus events can't cause revisits.
    func nextInMRUCycle() -> Int? {
        guard managedWindows.filter({ !$0.isFullscreened }).count > 1 else { return nil }

        if !isCycling {
            beginCycle()
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

        return nearestNonSeparatorIndex(from: activeIndex + 1) ?? nearestNonSeparatorIndex(from: activeIndex)
    }

    /// End a cycling session: commit the landed-on window to MRU front and reset.
    /// - Parameter landedWindowID: Optional explicit final selection from UI.
    ///   If provided and still present in the group, it wins over snapshot state.
    func endCycle(landedWindowID: CGWindowID? = nil) {
        isCycling = false
        let explicitLandedID: CGWindowID? = {
            guard let landedWindowID else { return nil }
            return managedWindows.contains(where: { $0.id == landedWindowID }) ? landedWindowID : nil
        }()
        // Use the snapshot position — immune to focus-event races that change activeIndex
        let snapshotLandedID: CGWindowID? = {
            guard !cycleOrder.isEmpty, cyclePosition < cycleOrder.count else { return nil }
            let id = cycleOrder[cyclePosition]
            return managedWindows.contains(where: { $0.id == id }) ? id : nil
        }()
        if let id = explicitLandedID ?? snapshotLandedID ?? activeWindow?.id {
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
        normalizePinnedOrder()
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
        normalizePinnedOrder()
    }

    // MARK: - Pinned Tabs

    func pinWindow(withID windowID: CGWindowID, at pinnedIndex: Int? = nil) {
        guard let sourceIndex = windows.firstIndex(where: { $0.id == windowID }),
              !windows[sourceIndex].isSeparator else { return }

        if windows[sourceIndex].isPinned {
            if let pinnedIndex {
                movePinnedTab(withID: windowID, toPinnedIndex: pinnedIndex)
            }
            return
        }

        let pinnedBefore = pinnedCount
        windows[sourceIndex].isPinned = true
        let targetPinnedIndex = max(0, min(pinnedIndex ?? pinnedBefore, pinnedBefore))
        moveWindowToFinalIndex(from: sourceIndex, to: targetPinnedIndex)
    }

    func unpinWindow(withID windowID: CGWindowID) {
        guard let sourceIndex = windows.firstIndex(where: { $0.id == windowID }),
              windows[sourceIndex].isPinned,
              !windows[sourceIndex].isSeparator else { return }

        windows[sourceIndex].isPinned = false
        let firstUnpinnedIndex = pinnedCount
        moveWindowToFinalIndex(from: sourceIndex, to: firstUnpinnedIndex)
    }

    func setPinned(_ pinned: Bool, forWindowIDs ids: Set<CGWindowID>) {
        guard !ids.isEmpty else { return }
        var changed = false
        for index in windows.indices where ids.contains(windows[index].id) {
            guard !windows[index].isSeparator else { continue }
            if windows[index].isPinned != pinned {
                windows[index].isPinned = pinned
                changed = true
            }
        }
        guard changed else { return }
        normalizePinnedOrder()
    }

    func movePinnedTab(withID windowID: CGWindowID, toPinnedIndex: Int) {
        guard let sourceIndex = windows.firstIndex(where: { $0.id == windowID }),
              windows[sourceIndex].isPinned,
              !windows[sourceIndex].isSeparator else { return }
        let maxIndex = max(0, pinnedCount - 1)
        let destination = max(0, min(toPinnedIndex, maxIndex))
        moveWindowToFinalIndex(from: sourceIndex, to: destination)
    }

    func moveUnpinnedTab(withID windowID: CGWindowID, toUnpinnedIndex: Int) {
        guard let sourceIndex = windows.firstIndex(where: { $0.id == windowID }),
              !windows[sourceIndex].isPinned else { return }
        let boundary = pinnedCount
        let unpinnedCount = windows.count - boundary
        guard unpinnedCount > 0 else { return }
        let clamped = max(0, min(toUnpinnedIndex, unpinnedCount - 1))
        moveWindowToFinalIndex(from: sourceIndex, to: boundary + clamped)
    }

    private func moveWindowToFinalIndex(from source: Int, to destination: Int) {
        guard source >= 0, source < windows.count,
              destination >= 0, destination < windows.count,
              source != destination else {
            return
        }

        let wasActive = source == activeIndex
        let window = windows.remove(at: source)
        windows.insert(window, at: destination)

        if wasActive {
            activeIndex = destination
        } else if source < activeIndex, destination >= activeIndex {
            activeIndex -= 1
        } else if source > activeIndex, destination <= activeIndex {
            activeIndex += 1
        }
    }

    private func normalizePinnedOrder() {
        let activeID = activeWindow?.id
        let pinned = windows.filter { $0.isPinned && !$0.isSeparator }
        let unpinned = windows.filter { !$0.isPinned || $0.isSeparator }
        windows = pinned + unpinned

        if let activeID, let index = windows.firstIndex(where: { $0.id == activeID }) {
            activeIndex = index
        } else if windows.isEmpty {
            activeIndex = 0
        } else {
            activeIndex = max(0, min(activeIndex, windows.count - 1))
            ensureActiveOnRealWindow()
        }
    }

    private func dropSeparatorsIfNoRealWindows() {
        guard windows.contains(where: { !$0.isSeparator }) else {
            windows = []
            activeIndex = 0
            focusHistory = []
            cycleOrder = []
            cyclePosition = 0
            return
        }
    }

    private func ensureActiveOnRealWindow(preferredIndex: Int? = nil) {
        guard !windows.isEmpty else {
            activeIndex = 0
            return
        }
        let seed = preferredIndex ?? activeIndex
        if let index = nearestNonSeparatorIndex(from: seed) {
            activeIndex = index
        }
    }

    private func nearestNonSeparatorIndex(from index: Int) -> Int? {
        guard !windows.isEmpty else { return nil }
        let clamped = max(0, min(index, windows.count - 1))
        if !windows[clamped].isSeparator { return clamped }

        var left = clamped - 1
        var right = clamped + 1
        while left >= 0 || right < windows.count {
            if left >= 0, !windows[left].isSeparator { return left }
            if right < windows.count, !windows[right].isSeparator { return right }
            left -= 1
            right += 1
        }
        return nil
    }

    private static func nextSeparatorID() -> CGWindowID {
        defer {
            if separatorIDSeed == CGWindowID.max {
                separatorIDSeed = 4_000_000_000
            } else {
                separatorIDSeed += 1
            }
        }
        return separatorIDSeed
    }
}
