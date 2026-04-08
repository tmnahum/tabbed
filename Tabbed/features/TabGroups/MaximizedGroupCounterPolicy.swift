import Foundation
import CoreGraphics

enum MaximizedGroupCounterPolicy {
    struct Candidate {
        let groupID: UUID
        let spaceID: UInt64?
        let isMaximized: Bool
        let frame: CGRect
        let displayMode: TabGroupDisplayMode
        let screenFrame: CGRect?

        init(
            groupID: UUID,
            spaceID: UInt64?,
            isMaximized: Bool,
            frame: CGRect = .zero,
            displayMode: TabGroupDisplayMode = .bound,
            screenFrame: CGRect? = nil
        ) {
            self.groupID = groupID
            self.spaceID = spaceID
            self.isMaximized = isMaximized
            self.frame = frame
            self.displayMode = displayMode
            self.screenFrame = screenFrame
        }
    }

    private static let tabBarTopLeftTolerance: CGFloat = 30

    /// Build per-group counter lists using creation-order input.
    /// Participation is based on the selected mode, and only spaces with 2+ participants get counters.
    static func counterGroupIDsByGroupID(
        candidates: [Candidate],
        preferredOrderBySpaceID: [UInt64: [UUID]] = [:],
        mode: GroupCounterMode = .maximizedOnly
    ) -> [UUID: [UUID]] {
        var result: [UUID: [UUID]] = [:]

        for candidate in candidates {
            result[candidate.groupID] = []
        }

        let participantsBySpace = participatingGroupIDsBySpaceID(candidates: candidates, mode: mode)
        for (spaceID, ids) in participantsBySpace where ids.count >= 2 {
            let orderedIDs = applyPreferredOrder(preferredOrderBySpaceID[spaceID], to: ids)
            for id in orderedIDs {
                result[id] = orderedIDs
            }
        }

        return result
    }

    static func participatingGroupIDsBySpaceID(
        candidates: [Candidate],
        mode: GroupCounterMode
    ) -> [UInt64: [UUID]] {
        guard mode != .disabled else { return [:] }

        var candidatesBySpace: [UInt64: [Candidate]] = [:]
        for candidate in candidates {
            guard let spaceID = candidate.spaceID else { continue }
            candidatesBySpace[spaceID, default: []].append(candidate)
        }

        var participantsBySpace: [UInt64: [UUID]] = [:]
        for (spaceID, spaceCandidates) in candidatesBySpace {
            let participants = participants(in: spaceCandidates, mode: mode)
            if participants.count >= 2 {
                participantsBySpace[spaceID] = participants
            }
        }
        return participantsBySpace
    }

    private static func participants(in candidates: [Candidate], mode: GroupCounterMode) -> [UUID] {
        switch mode {
        case .disabled:
            return []
        case .maximizedOnly:
            return candidates
                .filter(\.isMaximized)
                .map(\.groupID)
        case .maximizedAndPositionAligned:
            let maximizedCandidates = candidates.filter(\.isMaximized)
            let hasMaximized = !maximizedCandidates.isEmpty
            return candidates.compactMap { candidate in
                if candidate.isMaximized {
                    return candidate.groupID
                }
                let aligned: Bool
                if hasMaximized {
                    aligned = maximizedCandidates.contains { maximized in
                        isRoughlyAligned(candidate, maximized)
                    }
                } else {
                    aligned = candidates.contains { other in
                        other.groupID != candidate.groupID &&
                        isRoughlyAligned(candidate, other)
                    }
                }
                return aligned ? candidate.groupID : nil
            }
        }
    }

    private static func isRoughlyAligned(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        let lhsTopLeft = tabBarTopLeft(for: lhs)
        let rhsTopLeft = tabBarTopLeft(for: rhs)
        return abs(lhsTopLeft.x - rhsTopLeft.x) <= tabBarTopLeftTolerance &&
               abs(lhsTopLeft.y - rhsTopLeft.y) <= tabBarTopLeftTolerance
    }

    private static func tabBarTopLeft(for candidate: Candidate) -> CGPoint {
        if candidate.displayMode == .fullscreen, let screenFrame = candidate.screenFrame {
            return CGPoint(x: screenFrame.origin.x, y: screenFrame.origin.y)
        }
        return CGPoint(
            x: candidate.frame.origin.x,
            y: candidate.frame.origin.y - ScreenCompensation.tabBarHeight
        )
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
