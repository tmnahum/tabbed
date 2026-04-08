import Foundation
import CoreGraphics
import SwiftUI

/// Manages the lifecycle of tab groups. All methods must be called on the main thread.
class GroupManager: ObservableObject {
    @Published var groups: [TabGroup] = []
    private var windowIDsToGroupIDs: [CGWindowID: [UUID]] = [:]
    private var primaryGroupIDByWindowID: [CGWindowID: UUID] = [:]

    func isWindowGrouped(_ windowID: CGWindowID) -> Bool {
        membershipCount(for: windowID) > 0
    }

    /// Compatibility API: returns the current primary owner group for this window.
    /// For non-virtual tabs this is the only containing group.
    func group(for windowID: CGWindowID) -> TabGroup? {
        if let primaryID = primaryGroupIDByWindowID[windowID],
           let primary = groups.first(where: { $0.id == primaryID }) {
            return primary
        }
        return groups(for: windowID).first
    }

    func groups(for windowID: CGWindowID) -> [TabGroup] {
        guard let groupIDs = windowIDsToGroupIDs[windowID], !groupIDs.isEmpty else { return [] }
        let groupsByID = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
        return groupIDs.compactMap { groupsByID[$0] }
    }

    func membershipCount(for windowID: CGWindowID) -> Int {
        windowIDsToGroupIDs[windowID]?.count ?? 0
    }

    @discardableResult
    func promotePrimaryGroup(windowID: CGWindowID, groupID: UUID) -> Bool {
        guard let groupIDs = windowIDsToGroupIDs[windowID],
              groupIDs.contains(groupID) else { return false }
        primaryGroupIDByWindowID[windowID] = groupID
        return true
    }

    @discardableResult
    func createGroup(
        with windows: [WindowInfo],
        frame: CGRect,
        spaceID: UInt64 = 0,
        name: String? = nil,
        displayMode: TabGroupDisplayMode = .bound,
        fullscreenState: FullscreenGroupState? = nil,
        allowSharedMembership: Bool = false
    ) -> TabGroup? {
        guard windows.count >= 1 else { return nil }

        // Reject duplicate window IDs in the input
        let uniqueIDs = Set(windows.map(\.id))
        guard uniqueIDs.count == windows.count else { return nil }

        // Prevent adding windows that are already grouped, unless shared memberships are allowed.
        for window in windows {
            if isWindowGrouped(window.id) && (!allowSharedMembership || window.isSeparator) {
                return nil
            }
        }

        let group = TabGroup(
            windows: windows,
            frame: frame,
            spaceID: spaceID,
            name: name,
            displayMode: displayMode,
            fullscreenState: fullscreenState
        )
        groups.append(group)
        rebuildMembershipIndex()
        return group
    }

    @discardableResult
    func addWindow(
        _ window: WindowInfo,
        to group: TabGroup,
        at index: Int? = nil,
        allowSharedMembership: Bool = false
    ) -> Bool {
        guard groups.contains(where: { $0.id == group.id }) else { return false }
        if window.isSeparator && isWindowGrouped(window.id) {
            return false
        }
        guard allowSharedMembership || !isWindowGrouped(window.id) else { return false }
        guard !group.contains(windowID: window.id) else { return false }

        let previousCount = group.windows.count
        withAnimation(.easeOut(duration: 0.1)) {
            group.addWindow(window, at: index)
        }
        guard group.windows.count != previousCount else { return false }

        rebuildMembershipIndex()
        objectWillChange.send()
        return true
    }

    @discardableResult
    func releaseWindow(withID windowID: CGWindowID, from group: TabGroup) -> WindowInfo? {
        guard groups.contains(where: { $0.id == group.id }) else { return nil }
        var removed: WindowInfo?
        withAnimation(.easeOut(duration: 0.1)) {
            removed = group.removeWindow(withID: windowID)
        }
        guard removed != nil else { return nil }

        if group.managedWindowCount == 0 {
            dissolveGroup(group)
        } else {
            rebuildMembershipIndex()
            objectWillChange.send()
        }
        return removed
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
            rebuildMembershipIndex()
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
        rebuildMembershipIndex()
    }

    func dissolveAllGroups() {
        groups.removeAll()
        windowIDsToGroupIDs.removeAll()
        primaryGroupIDByWindowID.removeAll()
    }

    private func normalizeCustomTabName(_ rawName: String?) -> String? {
        guard let rawName else { return nil }
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func rebuildMembershipIndex() {
        var memberships: [CGWindowID: [UUID]] = [:]

        for group in groups {
            for window in group.windows {
                memberships[window.id, default: []].append(group.id)
            }
        }

        windowIDsToGroupIDs = memberships

        var nextPrimary: [CGWindowID: UUID] = [:]
        for (windowID, groupIDs) in memberships {
            guard !groupIDs.isEmpty else { continue }
            if let existing = primaryGroupIDByWindowID[windowID],
               groupIDs.contains(existing) {
                nextPrimary[windowID] = existing
            } else {
                nextPrimary[windowID] = groupIDs[0]
            }
        }
        primaryGroupIDByWindowID = nextPrimary
    }
}
