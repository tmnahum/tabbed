import Foundation
import CoreGraphics
import SwiftUI

/// Manages the lifecycle of tab groups. All methods must be called on the main thread.
class GroupManager: ObservableObject {
    @Published var groups: [TabGroup] = []

    func isWindowGrouped(_ windowID: CGWindowID) -> Bool {
        groups.contains { $0.contains(windowID: windowID) }
    }

    func group(for windowID: CGWindowID) -> TabGroup? {
        groups.first { $0.contains(windowID: windowID) }
    }

    @discardableResult
    func createGroup(with windows: [WindowInfo], frame: CGRect, spaceID: UInt64 = 0, name: String? = nil) -> TabGroup? {
        guard windows.count >= 1 else { return nil }

        // Reject duplicate window IDs in the input
        let uniqueIDs = Set(windows.map(\.id))
        guard uniqueIDs.count == windows.count else { return nil }

        // Prevent adding windows that are already grouped
        for window in windows {
            if isWindowGrouped(window.id) { return nil }
        }

        let group = TabGroup(windows: windows, frame: frame, spaceID: spaceID, name: name)
        groups.append(group)
        return group
    }

    func addWindow(_ window: WindowInfo, to group: TabGroup, at index: Int? = nil) {
        guard groups.contains(where: { $0.id == group.id }) else { return }
        guard !isWindowGrouped(window.id) else { return }
        withAnimation(.easeOut(duration: 0.1)) {
            group.addWindow(window, at: index)
        }
        objectWillChange.send()
    }

    func releaseWindow(withID windowID: CGWindowID, from group: TabGroup) {
        guard groups.contains(where: { $0.id == group.id }) else { return }
        withAnimation(.easeOut(duration: 0.1)) {
            guard group.removeWindow(withID: windowID) != nil else { return }
        }

        if group.managedWindowCount == 0 {
            dissolveGroup(group)
        } else {
            objectWillChange.send()
        }
    }

    /// Updates a grouped window's title and publishes a change for views that
    /// observe the manager (for example, the menu bar popover).
    @discardableResult
    func updateWindowTitle(withID windowID: CGWindowID, in group: TabGroup, to title: String) -> Bool {
        guard groups.contains(where: { $0.id == group.id }),
              let index = group.windows.firstIndex(where: { $0.id == windowID }) else {
            return false
        }
        guard !group.windows[index].isSeparator else { return false }
        guard group.windows[index].title != title else { return false }
        group.windows[index].title = title
        objectWillChange.send()
        return true
    }

    /// Updates a grouped window's user-defined tab name and publishes a change.
    /// Pass nil/empty whitespace to clear the custom name.
    @discardableResult
    func updateWindowCustomTabName(withID windowID: CGWindowID, in group: TabGroup, to rawCustomTabName: String?) -> Bool {
        guard groups.contains(where: { $0.id == group.id }),
              let index = group.windows.firstIndex(where: { $0.id == windowID }) else {
            return false
        }
        guard !group.windows[index].isSeparator else { return false }
        let normalized = normalizeCustomTabName(rawCustomTabName)
        let existing = normalizeCustomTabName(group.windows[index].customTabName)
        guard existing != normalized else { return false }
        group.windows[index].customTabName = normalized
        objectWillChange.send()
        return true
    }

    /// Remove multiple windows from a group. Returns the removed windows.
    /// Auto-dissolves the group if it becomes empty.
    @discardableResult
    func releaseWindows(withIDs ids: Set<CGWindowID>, from group: TabGroup) -> [WindowInfo] {
        guard groups.contains(where: { $0.id == group.id }) else { return [] }
        var removed: [WindowInfo] = []
        withAnimation(.easeOut(duration: 0.1)) {
            removed = group.removeWindows(withIDs: ids)
        }

        if group.managedWindowCount == 0 {
            dissolveGroup(group)
        } else {
            objectWillChange.send()
        }
        return removed
    }

    /// Remove the group from management. Note: the group's `windows` array is
    /// intentionally left intact so callers (e.g., `AppDelegate.handleGroupDissolution`)
    /// can still access the surviving windows for cleanup (expanding them into tab bar space).
    func dissolveGroup(_ group: TabGroup) {
        guard groups.contains(where: { $0.id == group.id }) else { return }
        groups.removeAll { $0.id == group.id }
    }

    func dissolveAllGroups() {
        groups.removeAll()
    }

    private func normalizeCustomTabName(_ rawName: String?) -> String? {
        guard let rawName else { return nil }
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
