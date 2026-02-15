import XCTest
@testable import Tabbed

final class MaximizedGroupCounterPolicyTests: XCTestCase {
    func testNoCountersWhenSpaceHasFewerThanTwoMaximizedGroups() {
        let g1 = UUID()
        let g2 = UUID()

        let result = MaximizedGroupCounterPolicy.counterGroupIDsByGroupID(candidates: [
            .init(groupID: g1, spaceID: 1, isMaximized: true),
            .init(groupID: g2, spaceID: 1, isMaximized: false)
        ])

        XCTAssertEqual(result[g1], [])
        XCTAssertEqual(result[g2], [])
    }

    func testOnlyMaximizedGroupsParticipateWhenMixedWithNonMaximized() {
        let g1 = UUID()
        let g2 = UUID()
        let g3 = UUID()

        let result = MaximizedGroupCounterPolicy.counterGroupIDsByGroupID(candidates: [
            .init(groupID: g1, spaceID: 1, isMaximized: true),
            .init(groupID: g2, spaceID: 1, isMaximized: false),
            .init(groupID: g3, spaceID: 1, isMaximized: true)
        ])

        XCTAssertEqual(result[g1], [g1, g3])
        XCTAssertEqual(result[g2], [])
        XCTAssertEqual(result[g3], [g1, g3])
    }

    func testCountersAreIsolatedPerSpace() {
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let d = UUID()

        let result = MaximizedGroupCounterPolicy.counterGroupIDsByGroupID(candidates: [
            .init(groupID: a, spaceID: 10, isMaximized: true),
            .init(groupID: b, spaceID: 10, isMaximized: true),
            .init(groupID: c, spaceID: 20, isMaximized: true),
            .init(groupID: d, spaceID: 20, isMaximized: true)
        ])

        XCTAssertEqual(result[a], [a, b])
        XCTAssertEqual(result[b], [a, b])
        XCTAssertEqual(result[c], [c, d])
        XCTAssertEqual(result[d], [c, d])
    }

    func testOrderingFollowsCreationOrderInput() {
        let first = UUID()
        let second = UUID()
        let third = UUID()

        let result = MaximizedGroupCounterPolicy.counterGroupIDsByGroupID(candidates: [
            .init(groupID: second, spaceID: 30, isMaximized: true),
            .init(groupID: first, spaceID: 30, isMaximized: true),
            .init(groupID: third, spaceID: 30, isMaximized: true)
        ])

        XCTAssertEqual(result[second], [second, first, third])
        XCTAssertEqual(result[first], [second, first, third])
        XCTAssertEqual(result[third], [second, first, third])
    }

    func testNonParticipatingGroupsResolveToEmptyList() {
        let maximized = UUID()
        let unknownSpace = UUID()
        let notMaximized = UUID()

        let result = MaximizedGroupCounterPolicy.counterGroupIDsByGroupID(candidates: [
            .init(groupID: maximized, spaceID: 7, isMaximized: true),
            .init(groupID: unknownSpace, spaceID: nil, isMaximized: true),
            .init(groupID: notMaximized, spaceID: 7, isMaximized: false)
        ])

        XCTAssertEqual(result[maximized], [])
        XCTAssertEqual(result[unknownSpace], [])
        XCTAssertEqual(result[notMaximized], [])
    }
}
