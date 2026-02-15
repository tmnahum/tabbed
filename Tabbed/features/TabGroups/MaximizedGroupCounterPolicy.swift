import Foundation

enum MaximizedGroupCounterPolicy {
    struct Candidate {
        let groupID: UUID
        let spaceID: UInt64?
        let isMaximized: Bool
    }

    /// Build per-group counter lists using creation-order input.
    /// Only maximized groups participate, and only when a space has 2+ participants.
    static func counterGroupIDsByGroupID(candidates: [Candidate]) -> [UUID: [UUID]] {
        var result: [UUID: [UUID]] = [:]
        var maximizedBySpace: [UInt64: [UUID]] = [:]

        for candidate in candidates {
            result[candidate.groupID] = []
            guard candidate.isMaximized, let spaceID = candidate.spaceID else { continue }
            maximizedBySpace[spaceID, default: []].append(candidate.groupID)
        }

        for ids in maximizedBySpace.values where ids.count >= 2 {
            for id in ids {
                result[id] = ids
            }
        }

        return result
    }
}
