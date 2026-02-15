import Foundation

enum MaximizedGroupCounterPolicy {
    struct Candidate {
        let groupID: UUID
        let spaceID: UInt64?
        let isMaximized: Bool
    }

    /// Build per-group counter lists using creation-order input.
    /// Only maximized groups participate, and only when a space has 2+ participants.
    static func counterGroupIDsByGroupID(
        candidates: [Candidate],
        preferredOrderBySpaceID: [UInt64: [UUID]] = [:]
    ) -> [UUID: [UUID]] {
        var result: [UUID: [UUID]] = [:]
        var maximizedBySpace: [UInt64: [UUID]] = [:]

        for candidate in candidates {
            result[candidate.groupID] = []
            guard candidate.isMaximized, let spaceID = candidate.spaceID else { continue }
            maximizedBySpace[spaceID, default: []].append(candidate.groupID)
        }

        for (spaceID, ids) in maximizedBySpace where ids.count >= 2 {
            let orderedIDs = applyPreferredOrder(preferredOrderBySpaceID[spaceID], to: ids)
            for id in orderedIDs {
                result[id] = orderedIDs
            }
        }

        return result
    }

    static func applyPreferredOrder(_ preferredOrder: [UUID]?, to creationOrderedIDs: [UUID]) -> [UUID] {
        guard let preferredOrder, !preferredOrder.isEmpty else { return creationOrderedIDs }
        let creationSet = Set(creationOrderedIDs)
        var ordered: [UUID] = []
        ordered.reserveCapacity(creationOrderedIDs.count)

        for id in preferredOrder where creationSet.contains(id) && !ordered.contains(id) {
            ordered.append(id)
        }
        for id in creationOrderedIDs where !ordered.contains(id) {
            ordered.append(id)
        }
        return ordered
    }
}
