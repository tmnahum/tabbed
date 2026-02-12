import XCTest
@testable import Tabbed

final class CommitEchoSuppressionTests: XCTestCase {

    func testShouldSuppressCommitEchoReturnsFalseWhenInactive() {
        let app = AppDelegate()
        XCTAssertFalse(app.shouldSuppressCommitEcho(for: 1))
        XCTAssertFalse(app.isCommitEchoSuppressionActive)
    }

    func testBeginCommitEchoSuppressionSuppressesUntilTargetObserved() {
        let app = AppDelegate()
        app.beginCommitEchoSuppression(targetWindowID: 42)

        XCTAssertTrue(app.isCommitEchoSuppressionActive)
        XCTAssertTrue(app.shouldSuppressCommitEcho(for: 99))
        XCTAssertTrue(app.shouldSuppressCommitEcho(for: 42))

        let cleared = expectation(description: "suppression clears after target echo")
        DispatchQueue.main.async {
            XCTAssertFalse(app.isCommitEchoSuppressionActive)
            XCTAssertNil(app.pendingCommitEchoTargetWindowID)
            cleared.fulfill()
        }
        wait(for: [cleared], timeout: 1.0)
    }

    func testSuppressionExpiresAndClearsState() {
        let app = AppDelegate()
        app.beginCommitEchoSuppression(targetWindowID: 7)
        app.pendingCommitEchoDeadline = Date().addingTimeInterval(-0.01)

        XCTAssertFalse(app.shouldSuppressCommitEcho(for: 7))
        XCTAssertFalse(app.isCommitEchoSuppressionActive)
        XCTAssertNil(app.pendingCommitEchoTargetWindowID)
    }
}
