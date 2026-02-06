import Foundation
import CoreGraphics

class TabGroup: Identifiable, ObservableObject {
    let id = UUID()
    @Published var windows: [WindowInfo]
    @Published var activeIndex: Int
    @Published var frame: CGRect

    /// MRU focus history — most recently focused window ID first.
    private(set) var focusHistory: [CGWindowID] = []
    /// Whether we're mid-cycle (Hyper+Tab held). Prevents focus handlers from updating MRU order.
    private(set) var isCycling = false
    private var cyclePosition = 0

    var activeWindow: WindowInfo? {
        guard activeIndex >= 0, activeIndex < windows.count else { return nil }
        return windows[activeIndex]
    }

    init(windows: [WindowInfo], frame: CGRect) {
        self.windows = windows
        self.activeIndex = 0
        self.frame = frame
        // Seed focus history with initial window order
        self.focusHistory = windows.map(\.id)
    }

    func contains(windowID: CGWindowID) -> Bool {
        windows.contains { $0.id == windowID }
    }

    func addWindow(_ window: WindowInfo) {
        guard !contains(windowID: window.id) else { return }
        windows.append(window)
        focusHistory.append(window.id)
    }

    func removeWindow(at index: Int) -> WindowInfo? {
        guard index >= 0, index < windows.count else { return nil }
        let removed = windows.remove(at: index)
        focusHistory.removeAll { $0 == removed.id }
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
    /// Tracks cycle position so repeated calls walk through the full history.
    func nextInMRUCycle() -> Int? {
        guard windows.count > 1, !focusHistory.isEmpty else { return nil }

        if !isCycling {
            // Starting a new cycle — begin from position 0 (the current window)
            isCycling = true
            cyclePosition = 0
        }

        // Advance through MRU history, skipping stale entries
        for _ in 0..<focusHistory.count {
            cyclePosition = (cyclePosition + 1) % focusHistory.count
            let nextID = focusHistory[cyclePosition]
            if let index = windows.firstIndex(where: { $0.id == nextID }) {
                return index
            }
        }

        // Fallback: just go to the next tab by position
        return (activeIndex + 1) % windows.count
    }

    /// End a cycling session: commit the current window to MRU and reset state.
    func endCycle() {
        isCycling = false
        cyclePosition = 0
        if let active = activeWindow {
            recordFocus(windowID: active.id)
        }
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
}
