import XCTest
import AppKit
@testable import Tabbed

final class TabBarPanelHitTestingTests: XCTestCase {
    func testGroupNameDragRegionIncludesLeadingAndTrailingEdges() {
        XCTAssertTrue(
            TabBarPanel.isGroupNameDragRegion(
                pointX: 20,
                leadingPad: 4,
                groupCounterWidth: 0,
                handleWidth: 16,
                groupNameWidth: 80
            )
        )
        XCTAssertTrue(
            TabBarPanel.isGroupNameDragRegion(
                pointX: 100,
                leadingPad: 4,
                groupCounterWidth: 0,
                handleWidth: 16,
                groupNameWidth: 80
            )
        )
    }

    func testGroupNameDragRegionRejectsPointsOutsideBounds() {
        XCTAssertFalse(
            TabBarPanel.isGroupNameDragRegion(
                pointX: 19.99,
                leadingPad: 4,
                groupCounterWidth: 0,
                handleWidth: 16,
                groupNameWidth: 80
            )
        )
        XCTAssertFalse(
            TabBarPanel.isGroupNameDragRegion(
                pointX: 100.01,
                leadingPad: 4,
                groupCounterWidth: 0,
                handleWidth: 16,
                groupNameWidth: 80
            )
        )
    }

    func testGroupNameDragRegionAccountsForHiddenHandleLayout() {
        XCTAssertTrue(
            TabBarPanel.isGroupNameDragRegion(
                pointX: 2,
                leadingPad: 2,
                groupCounterWidth: 0,
                handleWidth: 0,
                groupNameWidth: 40
            )
        )
        XCTAssertFalse(
            TabBarPanel.isGroupNameDragRegion(
                pointX: 1.99,
                leadingPad: 2,
                groupCounterWidth: 0,
                handleWidth: 0,
                groupNameWidth: 40
            )
        )
    }

    func testGroupNameDragRegionIsDisabledWhenWidthIsNonPositive() {
        XCTAssertFalse(
            TabBarPanel.isGroupNameDragRegion(
                pointX: 20,
                leadingPad: 4,
                groupCounterWidth: 0,
                handleWidth: 16,
                groupNameWidth: 0
            )
        )
        XCTAssertFalse(
            TabBarPanel.isGroupNameDragRegion(
                pointX: 20,
                leadingPad: 4,
                groupCounterWidth: 0,
                handleWidth: 16,
                groupNameWidth: -1
            )
        )
    }

    func testGroupNameDragRegionShiftsRightWhenCounterIsPresent() {
        XCTAssertFalse(
            TabBarPanel.isGroupNameDragRegion(
                pointX: 39.99,
                leadingPad: 4,
                groupCounterWidth: 20,
                handleWidth: 16,
                groupNameWidth: 80
            )
        )
        XCTAssertTrue(
            TabBarPanel.isGroupNameDragRegion(
                pointX: 40,
                leadingPad: 4,
                groupCounterWidth: 20,
                handleWidth: 16,
                groupNameWidth: 80
            )
        )
    }

    func testGroupNameDragRegionShiftsRightWhenSuperpinSectionIsPresent() {
        XCTAssertFalse(
            TabBarPanel.isGroupNameDragRegion(
                pointX: 49.99,
                leadingPad: 4,
                groupCounterWidth: 20,
                handleWidth: 16,
                groupNameWidth: 80,
                superPinnedSectionWidth: 10
            )
        )
        XCTAssertTrue(
            TabBarPanel.isGroupNameDragRegion(
                pointX: 50,
                leadingPad: 4,
                groupCounterWidth: 20,
                handleWidth: 16,
                groupNameWidth: 80,
                superPinnedSectionWidth: 10
            )
        )
    }

    func testGroupCounterRegionStartsAfterHandleAndSuperpinSection() {
        XCTAssertEqual(
            TabBarPanel.dragHandleRegionMinX(
                leadingPad: 4,
                superPinnedSectionWidth: 10
            ),
            14,
            accuracy: 0.01
        )
        XCTAssertEqual(
            TabBarPanel.dragHandleRegionMinX(
                leadingPad: 4,
                superPinnedSectionWidth: 10,
                superPinnedBeforeHandle: false
            ),
            4,
            accuracy: 0.01
        )
        XCTAssertEqual(
            TabBarPanel.groupCounterRegionMinX(
                leadingPad: 4,
                handleWidth: 16,
                superPinnedSectionWidth: 10
            ),
            30,
            accuracy: 0.01
        )
        XCTAssertEqual(
            TabBarPanel.groupCounterRegionMinX(
                leadingPad: 4,
                handleWidth: 16,
                superPinnedSectionWidth: 10,
                superPinnedBeforeHandle: false
            ),
            30,
            accuracy: 0.01
        )
        XCTAssertFalse(
            TabBarPanel.isGroupCounterRegion(
                pointX: 29.99,
                leadingPad: 4,
                handleWidth: 16,
                superPinnedSectionWidth: 10,
                groupCounterWidth: 20
            )
        )
        XCTAssertTrue(
            TabBarPanel.isGroupCounterRegion(
                pointX: 30,
                leadingPad: 4,
                handleWidth: 16,
                superPinnedSectionWidth: 10,
                groupCounterWidth: 20
            )
        )
        XCTAssertTrue(
            TabBarPanel.isGroupCounterRegion(
                pointX: 50,
                leadingPad: 4,
                handleWidth: 16,
                superPinnedSectionWidth: 10,
                groupCounterWidth: 20
            )
        )
        XCTAssertFalse(
            TabBarPanel.isGroupCounterRegion(
                pointX: 50.01,
                leadingPad: 4,
                handleWidth: 16,
                superPinnedSectionWidth: 10,
                groupCounterWidth: 20
            )
        )
    }

    func testGroupCounterRegionIsDisabledWhenWidthIsNonPositive() {
        XCTAssertFalse(
            TabBarPanel.isGroupCounterRegion(
                pointX: 12,
                leadingPad: 2,
                handleWidth: 0,
                groupCounterWidth: 0
            )
        )
        XCTAssertFalse(
            TabBarPanel.isGroupCounterRegion(
                pointX: 12,
                leadingPad: 2,
                handleWidth: 0,
                groupCounterWidth: -1
            )
        )
    }

    func testIsShiftPressedReadsShiftFromDeviceIndependentFlags() {
        XCTAssertTrue(TabBarPanel.isShiftPressed(in: [.shift]))
        XCTAssertTrue(TabBarPanel.isShiftPressed(in: [.shift, .option]))
    }

    func testIsShiftPressedIgnoresNonShiftFlags() {
        XCTAssertFalse(TabBarPanel.isShiftPressed(in: []))
        XCTAssertFalse(TabBarPanel.isShiftPressed(in: [.option, .command]))
    }
}
