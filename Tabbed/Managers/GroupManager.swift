import Foundation
import CoreGraphics

/// Manages the lifecycle of tab groups. All methods must be called on the main thread.
class GroupManager: ObservableObject {
    @Published var groups: [TabGroup] = []

    /// Callback fired when a group is dissolved. Passes the remaining windows.
    /// Note: When dissolution is triggered by `releaseWindow`, `onWindowReleased`
    /// fires first for the explicitly released window, then `onWindowReleased` fires
    /// for each remaining window, then `onGroupDissolved` fires with an empty array.
    var onGroupDissolved: (([WindowInfo]) -> Void)?

    /// Callback fired when a window is released from a group (including each
    /// remaining window during dissolution triggered by `releaseWindow`).
    var onWindowReleased: ((WindowInfo) -> Void)?

    func isWindowGrouped(_ windowID: CGWindowID) -> Bool {
        groups.contains { $0.contains(windowID: windowID) }
    }

    func group(for windowID: CGWindowID) -> TabGroup? {
        groups.first { $0.contains(windowID: windowID) }
    }

    @discardableResult
    func createGroup(with windows: [WindowInfo], frame: CGRect) -> TabGroup? {
        guard windows.count >= 2 else { return nil }

        // Reject duplicate window IDs in the input
        let uniqueIDs = Set(windows.map(\.id))
        guard uniqueIDs.count == windows.count else { return nil }

        // Prevent adding windows that are already grouped
        for window in windows {
            if isWindowGrouped(window.id) { return nil }
        }

        let group = TabGroup(windows: windows, frame: frame)
        groups.append(group)
        return group
    }

    func addWindow(_ window: WindowInfo, to group: TabGroup) {
        guard groups.contains(where: { $0.id == group.id }) else { return }
        guard !isWindowGrouped(window.id) else { return }
        group.addWindow(window)
        objectWillChange.send()
    }

    func releaseWindow(withID windowID: CGWindowID, from group: TabGroup) {
        guard groups.contains(where: { $0.id == group.id }) else { return }
        guard let removed = group.removeWindow(withID: windowID) else { return }
        onWindowReleased?(removed)

        if group.windows.count <= 1 {
            // Fire onWindowReleased for the last survivor before dissolving
            for window in group.windows {
                onWindowReleased?(window)
            }
            dissolveGroup(group)
        } else {
            objectWillChange.send()
        }
    }

    func dissolveGroup(_ group: TabGroup) {
        guard groups.contains(where: { $0.id == group.id }) else { return }
        onGroupDissolved?(group.windows)
        groups.removeAll { $0.id == group.id }
    }

    func dissolveAllGroups() {
        for group in groups {
            onGroupDissolved?(group.windows)
        }
        groups.removeAll()
    }
}
