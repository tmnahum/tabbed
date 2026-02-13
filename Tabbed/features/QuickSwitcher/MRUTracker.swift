import Foundation
import CoreGraphics

/// Identifies a switchable entity in the global MRU list.
enum MRUEntry: Equatable {
    case group(UUID)                                 // legacy whole-group entry
    case groupWindow(groupID: UUID, windowID: CGWindowID) // grouped window activation
    case window(CGWindowID)                          // a standalone (ungrouped) window
}

/// Tracks global most-recently-used entities and builds ordered switcher items.
final class MRUTracker {
    private static let maxEntries = 1024
    private(set) var entries: [MRUEntry] = []

    var count: Int { entries.count }

    func recordActivation(_ entry: MRUEntry) {
        remove(entry)
        entries.insert(entry, at: 0)
        pruneIfNeeded()
    }

    func appendIfMissing(_ entry: MRUEntry) {
        guard !entries.contains(entry) else { return }
        entries.append(entry)
        pruneIfNeeded()
    }

    func remove(_ entry: MRUEntry) {
        entries.removeAll { $0 == entry }
    }

    private func pruneIfNeeded() {
        guard entries.count > Self.maxEntries else { return }
        entries.removeSubrange(Self.maxEntries...)
    }

    func removeWindow(_ windowID: CGWindowID) {
        entries.removeAll { entry in
            switch entry {
            case .window(let id):
                return id == windowID
            case .groupWindow(_, let groupedWindowID):
                return groupedWindowID == windowID
            case .group:
                return false
            }
        }
    }

    func removeGroup(_ groupID: UUID) {
        entries.removeAll { entry in
            switch entry {
            case .group(let id):
                return id == groupID
            case .groupWindow(let entryGroupID, _):
                return entryGroupID == groupID
            case .window:
                return false
            }
        }
    }

    func mruGroupOrder() -> [UUID] {
        var seen: Set<UUID> = []
        var ordered: [UUID] = []

        for entry in entries {
            let groupID: UUID?
            switch entry {
            case .group(let id):
                groupID = id
            case .groupWindow(let id, _):
                groupID = id
            case .window:
                groupID = nil
            }
            guard let groupID, seen.insert(groupID).inserted else { continue }
            ordered.append(groupID)
        }
        return ordered
    }

    func buildSwitcherItems(
        groups: [TabGroup],
        zOrderedWindows: [WindowInfo],
        splitPinnedTabsIntoSeparateGroup: Bool = false,
        splitSeparatedTabsIntoSeparateGroups: Bool = false
    ) -> [SwitcherItem] {
        let groupFrames = groups.map(\.frame)
        let splitGroups = splitPinnedTabsIntoSeparateGroup || splitSeparatedTabsIntoSeparateGroups

        struct GroupSegmentKey: Hashable {
            let groupID: UUID
            let index: Int
        }

        var groupsByID: [UUID: TabGroup] = [:]
        var segmentsByKey: [GroupSegmentKey: [CGWindowID]] = [:]
        var segmentKeyByWindowID: [CGWindowID: GroupSegmentKey] = [:]
        var segmentKeysByGroupID: [UUID: [GroupSegmentKey]] = [:]

        for group in groups {
            groupsByID[group.id] = group
            let segments = TabWindowGrouping.segments(
                in: group,
                splitPinnedTabs: splitPinnedTabsIntoSeparateGroup,
                splitOnSeparators: splitSeparatedTabsIntoSeparateGroups
            )

            var groupSegmentKeys: [GroupSegmentKey] = []
            for (index, windowIDs) in segments.enumerated() {
                let key = GroupSegmentKey(groupID: group.id, index: index)
                segmentsByKey[key] = windowIDs
                groupSegmentKeys.append(key)
                for windowID in windowIDs {
                    segmentKeyByWindowID[windowID] = key
                }
            }
            segmentKeysByGroupID[group.id] = groupSegmentKeys
        }

        var windowsByID: [CGWindowID: WindowInfo] = [:]
        for window in zOrderedWindows where windowsByID[window.id] == nil {
            windowsByID[window.id] = window
        }

        var items: [SwitcherItem] = []
        var seenSegmentKeys: Set<GroupSegmentKey> = []
        var seenWindowIDs: Set<CGWindowID> = []

        func appendSegmentIfNeeded(_ key: GroupSegmentKey) {
            guard seenSegmentKeys.insert(key).inserted,
                  let group = groupsByID[key.groupID],
                  let windowIDs = segmentsByKey[key],
                  !windowIDs.isEmpty else { return }

            if splitGroups {
                items.append(.groupSegment(group, windowIDs: windowIDs))
            } else {
                items.append(.group(group))
            }
            seenWindowIDs.formUnion(windowIDs)
        }

        func appendAllSegmentsIfNeeded(for groupID: UUID) {
            guard let segmentKeys = segmentKeysByGroupID[groupID] else { return }
            for key in segmentKeys {
                appendSegmentIfNeeded(key)
            }
        }

        func preferredSegmentKey(for groupID: UUID, preferredWindowID: CGWindowID?) -> GroupSegmentKey? {
            guard let segmentKeys = segmentKeysByGroupID[groupID], !segmentKeys.isEmpty else { return nil }

            if let preferredWindowID,
               let segmentKey = segmentKeyByWindowID[preferredWindowID],
               segmentKey.groupID == groupID {
                return segmentKey
            }
            if let group = groupsByID[groupID] {
                if let activeWindowID = group.activeWindow?.id,
                   let segmentKey = segmentKeyByWindowID[activeWindowID],
                   segmentKey.groupID == groupID {
                    return segmentKey
                }
                if let focusedWindowID = group.focusHistory.first(where: { segmentKeyByWindowID[$0]?.groupID == groupID }),
                   let segmentKey = segmentKeyByWindowID[focusedWindowID],
                   segmentKey.groupID == groupID {
                    return segmentKey
                }
            }
            return segmentKeys[0]
        }

        // Phase 1: place items in MRU order.
        for entry in entries {
            switch entry {
            case .group(let groupID):
                if splitGroups {
                    if let segmentKey = preferredSegmentKey(for: groupID, preferredWindowID: nil) {
                        appendSegmentIfNeeded(segmentKey)
                    }
                } else {
                    appendAllSegmentsIfNeeded(for: groupID)
                }
            case .groupWindow(let groupID, let windowID):
                if splitGroups {
                    if let segmentKey = preferredSegmentKey(for: groupID, preferredWindowID: windowID) {
                        appendSegmentIfNeeded(segmentKey)
                    }
                } else {
                    appendAllSegmentsIfNeeded(for: groupID)
                }
            case .window(let windowID):
                guard let window = windowsByID[windowID],
                      !seenWindowIDs.contains(windowID),
                      segmentKeyByWindowID[windowID] == nil else { continue }
                items.append(.singleWindow(window))
                seenWindowIDs.insert(windowID)
            }
        }

        // Phase 2: remaining windows/groups in z-order.
        for window in zOrderedWindows where !seenWindowIDs.contains(window.id) {
            if let segmentKey = segmentKeyByWindowID[window.id] {
                appendSegmentIfNeeded(segmentKey)
                continue
            }

            if let frame = window.cgBounds {
                let matchesGroupFrame = groupFrames.contains { gf in
                    abs(frame.origin.x - gf.origin.x) < 2 &&
                    abs(frame.origin.y - gf.origin.y) < 2 &&
                    abs(frame.width - gf.width) < 2 &&
                    abs(frame.height - gf.height) < 2
                }
                if matchesGroupFrame { continue }
            }

            items.append(.singleWindow(window))
            seenWindowIDs.insert(window.id)
        }

        // Phase 3: groups with no visible members (e.g., on another space).
        for group in groups where !(segmentKeysByGroupID[group.id] ?? []).allSatisfy({ seenSegmentKeys.contains($0) }) {
            appendAllSegmentsIfNeeded(for: group.id)
        }

        return items
    }
}
