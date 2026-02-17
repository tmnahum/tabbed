import XCTest
@testable import Tabbed
import ApplicationServices

final class AutoCapturePolicyTests: XCTestCase {

    func testFocusCaptureBlockedOutsideLaunchGrace() {
        let pid: pid_t = 123
        let windowID: CGWindowID = 55
        let now = Date()
        let launchGraceUntilByPID: [pid_t: Date] = [pid: now.addingTimeInterval(-0.01)]

        XCTAssertFalse(
            AutoCapturePolicy.shouldAttemptFocusCapture(
                pid: pid,
                windowID: windowID,
                now: now,
                launchGraceUntilByPID: launchGraceUntilByPID,
                knownWindowIDsByPID: [:]
            )
        )
    }

    func testFocusCaptureAllowedDuringLaunchGraceForUnseenWindow() {
        let pid: pid_t = 123
        let windowID: CGWindowID = 55
        let now = Date()
        let launchGraceUntilByPID: [pid_t: Date] = [pid: now.addingTimeInterval(2)]

        XCTAssertTrue(
            AutoCapturePolicy.shouldAttemptFocusCapture(
                pid: pid,
                windowID: windowID,
                now: now,
                launchGraceUntilByPID: launchGraceUntilByPID,
                knownWindowIDsByPID: [:]
            )
        )
    }

    func testKnownWindowsNeverCaptureViaFocusFallback() {
        let pid: pid_t = 123
        let windowID: CGWindowID = 55
        let now = Date()
        let launchGraceUntilByPID: [pid_t: Date] = [pid: now.addingTimeInterval(2)]
        let knownWindowIDsByPID: [pid_t: Set<CGWindowID>] = [pid: [windowID]]

        XCTAssertFalse(
            AutoCapturePolicy.shouldAttemptFocusCapture(
                pid: pid,
                windowID: windowID,
                now: now,
                launchGraceUntilByPID: launchGraceUntilByPID,
                knownWindowIDsByPID: knownWindowIDsByPID
            )
        )
    }

    func testSuppressedWindowIDsRemainUntilWindowCloses() {
        let suppressed: Set<CGWindowID> = [10, 20]
        let existingWindowIDs: Set<CGWindowID> = [10]

        let pruned = AutoCapturePolicy.prunedSuppressedWindowIDs(
            suppressed,
            windowExists: { existingWindowIDs.contains($0) }
        )

        XCTAssertEqual(pruned, [10])
    }

    func testGroupMatchesModeForMaximizedOrOnlyAllowsEitherCondition() {
        XCTAssertTrue(
            AutoCapturePolicy.groupMatchesMode(
                mode: .whenMaximizedOrOnly,
                isMaximized: true,
                isOnlyGroupOnSpace: false
            )
        )
        XCTAssertTrue(
            AutoCapturePolicy.groupMatchesMode(
                mode: .whenMaximizedOrOnly,
                isMaximized: false,
                isOnlyGroupOnSpace: true
            )
        )
    }

    func testGroupMatchesModeForMaximizedOrOnlyRejectsWhenNeitherConditionApplies() {
        XCTAssertFalse(
            AutoCapturePolicy.groupMatchesMode(
                mode: .whenMaximizedOrOnly,
                isMaximized: false,
                isOnlyGroupOnSpace: false
            )
        )
    }

    func testSelectMostRecentGroupPrefersLastActiveGroup() {
        let groupA = UUID()
        let groupB = UUID()
        let candidates = [groupA, groupB]
        let mruEntries: [MRUEntry] = [.group(groupA), .group(groupB)]

        let selected = AutoCapturePolicy.selectMostRecentGroupID(
            candidates: candidates,
            lastActiveGroupID: groupB,
            mruEntries: mruEntries
        )

        XCTAssertEqual(selected, groupB)
    }

    func testSelectMostRecentGroupFallsBackToMRUWhenLastActiveMissing() {
        let groupA = UUID()
        let groupB = UUID()
        let candidates = [groupA, groupB]
        let mruEntries: [MRUEntry] = [.window(99), .group(groupB), .group(groupA)]

        let selected = AutoCapturePolicy.selectMostRecentGroupID(
            candidates: candidates,
            lastActiveGroupID: UUID(),
            mruEntries: mruEntries
        )

        XCTAssertEqual(selected, groupB)
    }

    func testSelectMostRecentGroupFallsBackToCandidateOrderWhenNoRecency() {
        let groupA = UUID()
        let groupB = UUID()
        let candidates = [groupA, groupB]

        let selected = AutoCapturePolicy.selectMostRecentGroupID(
            candidates: candidates,
            lastActiveGroupID: nil,
            mruEntries: [.window(42)]
        )

        XCTAssertEqual(selected, groupA)
    }

    func testSelectMostRecentGroupConsidersGroupWindowEntries() {
        let groupA = UUID()
        let groupB = UUID()
        let candidates = [groupA, groupB]

        let selected = AutoCapturePolicy.selectMostRecentGroupID(
            candidates: candidates,
            lastActiveGroupID: nil,
            mruEntries: [
                .groupWindow(groupID: groupB, windowID: 90),
                .groupWindow(groupID: groupA, windowID: 80)
            ]
        )

        XCTAssertEqual(selected, groupB)
    }

    func testSelectCaptureGroupPrefersMatchingScreenOverLastActive() {
        let groupA = UUID()
        let groupB = UUID()
        let candidates = [
            AutoCaptureWindowRoutingCandidate(
                groupID: groupA,
                groupSpaceID: 1,
                screenVisibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800)
            ),
            AutoCaptureWindowRoutingCandidate(
                groupID: groupB,
                groupSpaceID: 1,
                screenVisibleFrame: CGRect(x: 1000, y: 0, width: 1000, height: 800)
            )
        ]

        let selected = AutoCapturePolicy.selectCaptureGroupID(
            candidates: candidates,
            windowFrame: CGRect(x: 1200, y: 120, width: 700, height: 500),
            windowSpaceID: 1,
            lastActiveGroupID: groupA,
            mruEntries: [.group(groupA), .group(groupB)]
        )

        XCTAssertEqual(selected, groupB)
    }

    func testSelectCaptureGroupRejectsSpaceMismatch() {
        let groupA = UUID()
        let groupB = UUID()
        let candidates = [
            AutoCaptureWindowRoutingCandidate(
                groupID: groupA,
                groupSpaceID: 11,
                screenVisibleFrame: CGRect(x: 0, y: 0, width: 1200, height: 800)
            ),
            AutoCaptureWindowRoutingCandidate(
                groupID: groupB,
                groupSpaceID: 12,
                screenVisibleFrame: CGRect(x: 0, y: 0, width: 1200, height: 800)
            )
        ]

        let selected = AutoCapturePolicy.selectCaptureGroupID(
            candidates: candidates,
            windowFrame: CGRect(x: 400, y: 160, width: 600, height: 500),
            windowSpaceID: 12,
            lastActiveGroupID: groupA,
            mruEntries: [.group(groupA), .group(groupB)]
        )

        XCTAssertEqual(selected, groupB)
    }

    func testSelectCaptureGroupUsesMRUAmongMatchingCandidates() {
        let groupA = UUID()
        let groupB = UUID()
        let candidates = [
            AutoCaptureWindowRoutingCandidate(
                groupID: groupA,
                groupSpaceID: 0,
                screenVisibleFrame: CGRect(x: 0, y: 0, width: 1200, height: 800)
            ),
            AutoCaptureWindowRoutingCandidate(
                groupID: groupB,
                groupSpaceID: 0,
                screenVisibleFrame: CGRect(x: 0, y: 0, width: 1200, height: 800)
            )
        ]

        let selected = AutoCapturePolicy.selectCaptureGroupID(
            candidates: candidates,
            windowFrame: CGRect(x: 200, y: 200, width: 400, height: 300),
            windowSpaceID: nil,
            lastActiveGroupID: nil,
            mruEntries: [.group(groupB), .group(groupA)]
        )

        XCTAssertEqual(selected, groupB)
    }

    func testSelectCaptureGroupReturnsNilWhenNoScreenMatch() {
        let groupA = UUID()
        let candidates = [
            AutoCaptureWindowRoutingCandidate(
                groupID: groupA,
                groupSpaceID: 0,
                screenVisibleFrame: CGRect(x: 0, y: 0, width: 800, height: 600)
            )
        ]

        let selected = AutoCapturePolicy.selectCaptureGroupID(
            candidates: candidates,
            windowFrame: CGRect(x: 1200, y: 100, width: 500, height: 400),
            windowSpaceID: nil,
            lastActiveGroupID: groupA,
            mruEntries: [.group(groupA)]
        )

        XCTAssertNil(selected)
    }

    func testShouldSeedKnownWindowsWhenRequestedForFreshObserver() {
        XCTAssertTrue(
            AutoCapturePolicy.shouldSeedKnownWindows(
                requestedSeed: true,
                observerAlreadyExists: false
            )
        )
    }

    func testShouldNotSeedKnownWindowsForExistingObserver() {
        XCTAssertFalse(
            AutoCapturePolicy.shouldSeedKnownWindows(
                requestedSeed: true,
                observerAlreadyExists: true
            )
        )
    }

    func testShouldNotSeedKnownWindowsWhenSeedNotRequested() {
        XCTAssertFalse(
            AutoCapturePolicy.shouldSeedKnownWindows(
                requestedSeed: false,
                observerAlreadyExists: false
            )
        )
    }
}
