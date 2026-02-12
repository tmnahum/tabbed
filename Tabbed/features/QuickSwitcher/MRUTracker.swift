import Foundation
import CoreGraphics

/// Identifies a switchable entity in the global MRU list.
enum MRUEntry: Equatable {
    case group(UUID)        // a tab group, tracked by its stable UUID
    case window(CGWindowID) // a standalone (ungrouped) window
}

/// Tracks global most-recently-used entities and builds ordered switcher items.
final class MRUTracker {
    private(set) var entries: [MRUEntry] = []

    var count: Int { entries.count }

    func recordActivation(_ entry: MRUEntry) {
        remove(entry)
        entries.insert(entry, at: 0)
    }

    func appendIfMissing(_ entry: MRUEntry) {
        guard !entries.contains(entry) else { return }
        entries.append(entry)
    }

    func remove(_ entry: MRUEntry) {
        entries.removeAll { $0 == entry }
    }

    func removeWindow(_ windowID: CGWindowID) {
        remove(.window(windowID))
    }

    func removeGroup(_ groupID: UUID) {
        remove(.group(groupID))
    }

    func mruGroupOrder() -> [UUID] {
        entries.compactMap { entry -> UUID? in
            if case .group(let id) = entry { return id }
            return nil
        }
    }

    func buildSwitcherItems(groups: [TabGroup], zOrderedWindows: [WindowInfo]) -> [SwitcherItem] {
        let groupFrames = groups.map(\.frame)

        var groupsByID: [UUID: TabGroup] = [:]
        var groupByWindowID: [CGWindowID: TabGroup] = [:]
        for group in groups {
            groupsByID[group.id] = group
            for window in group.windows {
                groupByWindowID[window.id] = group
            }
        }

        var windowsByID: [CGWindowID: WindowInfo] = [:]
        for window in zOrderedWindows where windowsByID[window.id] == nil {
            windowsByID[window.id] = window
        }

        var items: [SwitcherItem] = []
        var seenGroupIDs: Set<UUID> = []
        var seenWindowIDs: Set<CGWindowID> = []

        // Phase 1: place items in MRU order.
        for entry in entries {
            switch entry {
            case .group(let groupID):
                guard let group = groupsByID[groupID],
                      seenGroupIDs.insert(groupID).inserted else { continue }
                items.append(.group(group))
                seenWindowIDs.formUnion(group.windows.map(\.id))
            case .window(let windowID):
                guard let window = windowsByID[windowID],
                      !seenWindowIDs.contains(windowID),
                      groupByWindowID[windowID] == nil else { continue }
                items.append(.singleWindow(window))
                seenWindowIDs.insert(windowID)
            }
        }

        // Phase 2: remaining windows/groups in z-order.
        for window in zOrderedWindows where !seenWindowIDs.contains(window.id) {
            if let group = groupByWindowID[window.id] {
                if seenGroupIDs.insert(group.id).inserted {
                    items.append(.group(group))
                    seenWindowIDs.formUnion(group.windows.map(\.id))
                }
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
        for group in groups where !seenGroupIDs.contains(group.id) {
            items.append(.group(group))
        }

        return items
    }
}
