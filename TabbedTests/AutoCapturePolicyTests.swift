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
}
