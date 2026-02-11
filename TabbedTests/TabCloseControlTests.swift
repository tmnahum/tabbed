import XCTest
@testable import Tabbed

final class TabCloseControlTests: XCTestCase {
    func testXmarkOnAllTabsShowsCloseWithoutShift() {
        XCTAssertEqual(
            TabBarView.tabHoverControl(
                at: 0,
                activeIndex: 0,
                mode: .xmarkOnAllTabs,
                isShiftPressed: false
            ),
            .close
        )
    }

    func testMinusOnCurrentTabUsesReleaseOnlyForActiveTab() {
        XCTAssertEqual(
            TabBarView.tabHoverControl(
                at: 1,
                activeIndex: 1,
                mode: .minusOnCurrentTab,
                isShiftPressed: false
            ),
            .release
        )
        XCTAssertEqual(
            TabBarView.tabHoverControl(
                at: 0,
                activeIndex: 1,
                mode: .minusOnCurrentTab,
                isShiftPressed: false
            ),
            .close
        )
    }

    func testMinusOnAllTabsUsesRelease() {
        XCTAssertEqual(
            TabBarView.tabHoverControl(
                at: 2,
                activeIndex: 0,
                mode: .minusOnAllTabs,
                isShiftPressed: false
            ),
            .release
        )
    }

    func testShiftInvertsCloseAndRelease() {
        XCTAssertEqual(
            TabBarView.tabHoverControl(
                at: 0,
                activeIndex: 0,
                mode: .xmarkOnAllTabs,
                isShiftPressed: true
            ),
            .release
        )
        XCTAssertEqual(
            TabBarView.tabHoverControl(
                at: 0,
                activeIndex: 0,
                mode: .minusOnAllTabs,
                isShiftPressed: true
            ),
            .close
        )
    }

    func testTabHoverControlSymbol() {
        XCTAssertEqual(
            TabBarView.tabHoverControlSymbol(control: .close, isConfirmingClose: false),
            "xmark"
        )
        XCTAssertEqual(
            TabBarView.tabHoverControlSymbol(control: .close, isConfirmingClose: true),
            "questionmark"
        )
        XCTAssertEqual(
            TabBarView.tabHoverControlSymbol(control: .release, isConfirmingClose: true),
            "minus"
        )
    }
}
