import XCTest
import CoreGraphics
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

    func testPreferredOrderOverridesCreationOrderWithinSpace() {
        let first = UUID()
        let second = UUID()
        let third = UUID()

        let result = MaximizedGroupCounterPolicy.counterGroupIDsByGroupID(
            candidates: [
                .init(groupID: first, spaceID: 30, isMaximized: true),
                .init(groupID: second, spaceID: 30, isMaximized: true),
                .init(groupID: third, spaceID: 30, isMaximized: true)
            ],
            preferredOrderBySpaceID: [30: [third, first, second]]
        )

        XCTAssertEqual(result[first], [third, first, second])
        XCTAssertEqual(result[second], [third, first, second])
        XCTAssertEqual(result[third], [third, first, second])
    }

    func testPreferredOrderIsPrunedToCurrentMembers() {
        let first = UUID()
        let second = UUID()
        let third = UUID()

        let result = MaximizedGroupCounterPolicy.counterGroupIDsByGroupID(
            candidates: [
                .init(groupID: first, spaceID: 30, isMaximized: true),
                .init(groupID: second, spaceID: 30, isMaximized: true),
                .init(groupID: third, spaceID: 30, isMaximized: true)
            ],
            preferredOrderBySpaceID: [30: [UUID(), second]]
        )

        XCTAssertEqual(result[first], [second, first, third])
        XCTAssertEqual(result[second], [second, first, third])
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

    func testDisabledModeReturnsNoCounters() {
        let first = UUID()
        let second = UUID()

        let result = MaximizedGroupCounterPolicy.counterGroupIDsByGroupID(
            candidates: [
                .init(groupID: first, spaceID: 1, isMaximized: true),
                .init(groupID: second, spaceID: 1, isMaximized: true)
            ],
            mode: .disabled
        )

        XCTAssertEqual(result[first], [])
        XCTAssertEqual(result[second], [])
    }

    func testPositionAlignedModeIncludesAlignedNonMaximizedGroups() {
        let maximized = UUID()
        let aligned = UUID()
        let farAway = UUID()

        let result = MaximizedGroupCounterPolicy.counterGroupIDsByGroupID(
            candidates: [
                .init(
                    groupID: maximized,
                    spaceID: 1,
                    isMaximized: true,
                    frame: CGRect(x: 0, y: 0, width: 1600, height: 900)
                ),
                .init(
                    groupID: aligned,
                    spaceID: 1,
                    isMaximized: false,
                    frame: CGRect(x: 20, y: 20, width: 1560, height: 860)
                ),
                .init(
                    groupID: farAway,
                    spaceID: 1,
                    isMaximized: false,
                    frame: CGRect(x: 500, y: 400, width: 900, height: 600)
                )
            ],
            mode: .maximizedAndPositionAligned
        )

        XCTAssertEqual(result[maximized], [maximized, aligned])
        XCTAssertEqual(result[aligned], [maximized, aligned])
        XCTAssertEqual(result[farAway], [])
    }

    func testPositionAlignedModeWorksWithoutMaximizedGroup() {
        let first = UUID()
        let second = UUID()

        let result = MaximizedGroupCounterPolicy.counterGroupIDsByGroupID(
            candidates: [
                .init(
                    groupID: first,
                    spaceID: 2,
                    isMaximized: false,
                    frame: CGRect(x: 0, y: 0, width: 1200, height: 800)
                ),
                .init(
                    groupID: second,
                    spaceID: 2,
                    isMaximized: false,
                    frame: CGRect(x: 10, y: 10, width: 1190, height: 790)
                )
            ],
            mode: .maximizedAndPositionAligned
        )

        XCTAssertEqual(result[first], [first, second])
        XCTAssertEqual(result[second], [first, second])
    }

    func testPositionAlignedModeWithoutMaximizedRequiresAlignedPeer() {
        let first = UUID()
        let second = UUID()

        let result = MaximizedGroupCounterPolicy.counterGroupIDsByGroupID(
            candidates: [
                .init(
                    groupID: first,
                    spaceID: 2,
                    isMaximized: false,
                    frame: CGRect(x: 0, y: 0, width: 1200, height: 800)
                ),
                .init(
                    groupID: second,
                    spaceID: 2,
                    isMaximized: false,
                    frame: CGRect(x: 300, y: 300, width: 1190, height: 790)
                )
            ],
            mode: .maximizedAndPositionAligned
        )

        XCTAssertEqual(result[first], [])
        XCTAssertEqual(result[second], [])
    }

    func testPositionAlignedModeUsesTabBarTopLeftEvenWhenSizesDiffer() {
        let maximized = UUID()
        let smallButAligned = UUID()

        let result = MaximizedGroupCounterPolicy.counterGroupIDsByGroupID(
            candidates: [
                .init(
                    groupID: maximized,
                    spaceID: 3,
                    isMaximized: true,
                    frame: CGRect(x: 100, y: 100, width: 1600, height: 900)
                ),
                .init(
                    groupID: smallButAligned,
                    spaceID: 3,
                    isMaximized: false,
                    frame: CGRect(x: 120, y: 120, width: 520, height: 300)
                )
            ],
            mode: .maximizedAndPositionAligned
        )

        XCTAssertEqual(result[maximized], [maximized, smallButAligned])
        XCTAssertEqual(result[smallButAligned], [maximized, smallButAligned])
    }

    func testPositionAlignedModeDoesNotUseOverlapWhenTopLeftDiffers() {
        let maximized = UUID()
        let overlappingButDifferentTopLeft = UUID()

        let result = MaximizedGroupCounterPolicy.counterGroupIDsByGroupID(
            candidates: [
                .init(
                    groupID: maximized,
                    spaceID: 4,
                    isMaximized: true,
                    frame: CGRect(x: 0, y: 0, width: 1600, height: 900)
                ),
                .init(
                    groupID: overlappingButDifferentTopLeft,
                    spaceID: 4,
                    isMaximized: false,
                    frame: CGRect(x: 220, y: 180, width: 1300, height: 680)
                )
            ],
            mode: .maximizedAndPositionAligned
        )

        XCTAssertEqual(result[maximized], [])
        XCTAssertEqual(result[overlappingButDifferentTopLeft], [])
    }

    func testFullscreenGroupsOnSameScreenCountAsAligned() {
        let first = UUID()
        let second = UUID()
        let screenFrame = CGRect(x: 0, y: 25, width: 1440, height: 875)

        let result = MaximizedGroupCounterPolicy.counterGroupIDsByGroupID(
            candidates: [
                .init(
                    groupID: first,
                    spaceID: 1,
                    isMaximized: true,
                    displayMode: .fullscreen,
                    screenFrame: screenFrame
                ),
                .init(
                    groupID: second,
                    spaceID: 1,
                    isMaximized: true,
                    displayMode: .fullscreen,
                    screenFrame: screenFrame
                )
            ],
            mode: .maximizedAndPositionAligned
        )

        XCTAssertEqual(result[first], [first, second])
        XCTAssertEqual(result[second], [first, second])
    }
}
