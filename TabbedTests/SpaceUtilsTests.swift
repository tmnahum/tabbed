import XCTest
@testable import Tabbed

final class SpaceUtilsTests: XCTestCase {
    func testSpaceIDReturnsNilForInvalidWindow() {
        // Window ID 0 / nonexistent windows should return nil
        let result = SpaceUtils.spaceID(for: 0)
        XCTAssertNil(result)
    }

    func testSpaceIDsReturnsEmptyForNoWindows() {
        let result = SpaceUtils.spaceIDs(for: [])
        XCTAssertTrue(result.isEmpty)
    }

    func testSpaceIDsOmitsInvalidWindows() {
        let result = SpaceUtils.spaceIDs(for: [0, 99999])
        // Both invalid, so they should be omitted from the result
        XCTAssertTrue(result.isEmpty)
    }

    func testWindowLevelReturnsNilForInvalidWindow() {
        let result = SpaceUtils.windowLevel(for: 0)
        XCTAssertNil(result)
    }
}
