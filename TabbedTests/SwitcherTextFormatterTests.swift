import XCTest
@testable import Tabbed

final class SwitcherTextFormatterTests: XCTestCase {

    func testAppAndWindowTextDropsDuplicateWindowTitle() {
        let text = SwitcherTextFormatter.appAndWindowText(appName: "Safari", windowTitle: "Safari")
        XCTAssertEqual(text, "Safari")
    }

    func testAppAndWindowTextShowsBothWhenDifferent() {
        let text = SwitcherTextFormatter.appAndWindowText(appName: "Safari", windowTitle: "Docs")
        XCTAssertEqual(text, "Safari  —  Docs")
    }

    func testNamedGroupLabelInIconsModeShowsGroupAndAppOnly() {
        let text = SwitcherTextFormatter.namedGroupLabel(
            groupName: "Work",
            appName: "Safari",
            windowTitle: "Docs",
            mode: .groupAppWindow,
            style: .appIcons
        )
        XCTAssertEqual(text, "Work  —  Safari")
    }

    func testNamedGroupLabelInTitlesModeDropsDuplicateWindowTitle() {
        let text = SwitcherTextFormatter.namedGroupLabel(
            groupName: "Work",
            appName: "Safari",
            windowTitle: "Safari",
            mode: .groupAppWindow,
            style: .titles
        )
        XCTAssertEqual(text, "Work  —  Safari")
    }

    func testNamedGroupLabelInTitlesModeIncludesWindowWhenDifferent() {
        let text = SwitcherTextFormatter.namedGroupLabel(
            groupName: "Work",
            appName: "Safari",
            windowTitle: "Docs",
            mode: .groupAppWindow,
            style: .titles
        )
        XCTAssertEqual(text, "Work  —  Safari  —  Docs")
    }

    func testNamedGroupTitleSuffixDropsDuplicateWindowTitle() {
        let suffix = SwitcherTextFormatter.namedGroupTitleSuffix(appName: "Safari", windowTitle: "Safari")
        XCTAssertEqual(suffix, "  —  Safari")
    }

    func testNamedGroupTitleSuffixUsesWindowWhenAppMissing() {
        let suffix = SwitcherTextFormatter.namedGroupTitleSuffix(appName: "", windowTitle: "Docs")
        XCTAssertEqual(suffix, "  —  Docs")
    }
}
