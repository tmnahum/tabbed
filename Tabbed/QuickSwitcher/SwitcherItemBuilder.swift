import Foundation
import CoreGraphics

enum SwitcherItemBuilder {
    /// Build an ordered list of switcher items from z-ordered windows and active groups.
    ///
    /// Each group appears once, at the z-position of its frontmost member.
    /// Ungrouped windows appear individually.
    static func build(zOrderedWindows: [WindowInfo], groups: [TabGroup]) -> [SwitcherItem] {
        // Map window IDs to their group (if any)
        var windowToGroup: [CGWindowID: TabGroup] = [:]
        for group in groups {
            for window in group.windows {
                windowToGroup[window.id] = group
            }
        }

        var result: [SwitcherItem] = []
        var seenGroupIDs: Set<UUID> = []

        for window in zOrderedWindows {
            if let group = windowToGroup[window.id] {
                // First time seeing this group in z-order -> insert it here
                if seenGroupIDs.insert(group.id).inserted {
                    result.append(.group(group))
                }
                // Otherwise skip — group already placed
            } else {
                result.append(.singleWindow(window))
            }
        }

        return result
    }
}
