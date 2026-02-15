import XCTest
@testable import Tabbed

final class AccessibilityHelperFocusTests: XCTestCase {
    func testShouldPromoteAfterRaiseWhenAppIsInactive() {
        let shouldPromote = AccessibilityHelper.shouldPromoteAfterRaise(
            appIsActive: false,
            focusedWindowID: 42,
            targetWindowID: 42
        )
        XCTAssertTrue(shouldPromote)
    }

    func testShouldPromoteAfterRaiseWhenFocusedWindowMatchesTarget() {
        let shouldPromote = AccessibilityHelper.shouldPromoteAfterRaise(
            appIsActive: true,
            focusedWindowID: 42,
            targetWindowID: 42
        )
        XCTAssertFalse(shouldPromote)
    }

    func testShouldPromoteAfterRaiseWhenFocusedWindowDiffersFromTarget() {
        let shouldPromote = AccessibilityHelper.shouldPromoteAfterRaise(
            appIsActive: true,
            focusedWindowID: 99,
            targetWindowID: 42
        )
        XCTAssertTrue(shouldPromote)
    }

    func testShouldPromoteAfterRaiseWhenFocusedWindowIsUnknown() {
        let shouldPromote = AccessibilityHelper.shouldPromoteAfterRaise(
            appIsActive: true,
            focusedWindowID: nil,
            targetWindowID: 42
        )
        XCTAssertTrue(shouldPromote)
    }

    func testShouldActivateViaNSAppForCurrentProcess() {
        XCTAssertTrue(
            AccessibilityHelper.shouldActivateViaNSApp(
                windowOwnerPID: 123,
                currentProcessID: 123
            )
        )
    }

    func testShouldActivateViaNSAppForDifferentProcess() {
        XCTAssertFalse(
            AccessibilityHelper.shouldActivateViaNSApp(
                windowOwnerPID: 456,
                currentProcessID: 123
            )
        )
    }
}
