import Foundation
import CoreGraphics

enum TabWindowGrouping {
    private enum SegmentPartition: Equatable {
        case all
        case superPinned
        case pinned
        case unpinned
    }

    static func segments(
        in group: TabGroup,
        splitPinnedTabs: Bool,
        splitSuperPinnedTabs: Bool = false,
        splitOnSeparators: Bool
    ) -> [[CGWindowID]] {
        let allManagedIDs = group.managedWindows.map(\.id)
        guard splitPinnedTabs || splitSuperPinnedTabs || splitOnSeparators else {
            return allManagedIDs.isEmpty ? [] : [allManagedIDs]
        }

        var segments: [[CGWindowID]] = []
        var currentSegment: [CGWindowID] = []
        var currentPartition: SegmentPartition?

        func flushCurrentSegment() {
            guard !currentSegment.isEmpty else { return }
            segments.append(currentSegment)
            currentSegment = []
            currentPartition = nil
        }

        func partition(for window: WindowInfo) -> SegmentPartition {
            if splitSuperPinnedTabs, window.isSuperPinned {
                return .superPinned
            }
            if splitPinnedTabs {
                if window.isSuperPinned {
                    return .superPinned
                }
                return window.isPinned ? .pinned : .unpinned
            }
            return .all
        }

        for window in group.windows {
            if window.isSeparator {
                if splitOnSeparators {
                    flushCurrentSegment()
                }
                continue
            }

            let windowPartition = partition(for: window)
            if currentSegment.isEmpty {
                currentSegment = [window.id]
                currentPartition = windowPartition
                continue
            }

            if let currentPartitionValue = currentPartition, currentPartitionValue != windowPartition {
                flushCurrentSegment()
                currentSegment = [window.id]
                currentPartition = windowPartition
                continue
            }

            currentSegment.append(window.id)
        }

        flushCurrentSegment()
        return segments
    }

    static func focusedSegmentWindowIDs(
        in group: TabGroup,
        focusedWindowID: CGWindowID?,
        splitPinnedTabs: Bool,
        splitSuperPinnedTabs: Bool = false,
        splitOnSeparators: Bool
    ) -> [CGWindowID] {
        let allSegments = segments(
            in: group,
            splitPinnedTabs: splitPinnedTabs,
            splitSuperPinnedTabs: splitSuperPinnedTabs,
            splitOnSeparators: splitOnSeparators
        )
        guard !allSegments.isEmpty else { return [] }

        let resolvedFocusedWindowID = focusedWindowID ?? group.activeWindow?.id
        if let resolvedFocusedWindowID,
           let matchingSegment = allSegments.first(where: { $0.contains(resolvedFocusedWindowID) }) {
            return matchingSegment
        }

        return allSegments[0]
    }
}
