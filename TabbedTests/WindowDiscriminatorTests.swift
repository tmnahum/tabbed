import XCTest
@testable import Tabbed
import ApplicationServices

final class WindowDiscriminatorTests: XCTestCase {

    func testAutoJoinRejectsDialogWindows() {
        let accepted = WindowDiscriminator.isActualWindow(
            cgWindowID: 1,
            subrole: "AXDialog",
            role: "AXWindow",
            title: "Save",
            size: CGSize(width: 700, height: 480),
            level: 0,
            bundleIdentifier: "com.example.app",
            localizedName: "Example",
            executableURL: nil,
            qualification: .autoJoin
        )
        XCTAssertFalse(accepted)
    }

    func testAutoJoinAcceptsStandardWindows() {
        let accepted = WindowDiscriminator.isActualWindow(
            cgWindowID: 1,
            subrole: "AXStandardWindow",
            role: "AXWindow",
            title: "Document",
            size: CGSize(width: 900, height: 700),
            level: 0,
            bundleIdentifier: "com.example.app",
            localizedName: "Example",
            executableURL: nil,
            qualification: .autoJoin
        )
        XCTAssertTrue(accepted)
    }

    func testWindowDiscoveryStillAcceptsDialogsByDefault() {
        let accepted = WindowDiscriminator.isActualWindow(
            cgWindowID: 1,
            subrole: "AXDialog",
            role: "AXWindow",
            title: "Dialog",
            size: CGSize(width: 700, height: 480),
            level: 0,
            bundleIdentifier: "com.example.app",
            localizedName: "Example",
            executableURL: nil
        )
        XCTAssertTrue(accepted)
    }

    func testAutoJoinKeepsExplicitNonStandardExceptions() {
        let accepted = WindowDiscriminator.isActualWindow(
            cgWindowID: 2,
            subrole: "AXUnknown",
            role: "AXWindow",
            title: "World of Warcraft",
            size: CGSize(width: 1200, height: 800),
            level: 0,
            bundleIdentifier: "com.blizzard.worldofwarcraft",
            localizedName: "WoW",
            executableURL: nil,
            qualification: .autoJoin
        )
        XCTAssertTrue(accepted)
    }

    func testAutoJoinRejectsAdobeFloatingPalette() {
        let accepted = WindowDiscriminator.isActualWindow(
            cgWindowID: 3,
            subrole: "AXFloatingWindow",
            role: "AXWindow",
            title: "Tools",
            size: CGSize(width: 500, height: 600),
            level: 0,
            bundleIdentifier: "com.adobe.AfterEffects",
            localizedName: "After Effects",
            executableURL: nil,
            qualification: .autoJoin
        )
        XCTAssertFalse(accepted)
    }

    func testAutoJoinRejectsSmallFirefoxPopupWindow() {
        let accepted = WindowDiscriminator.isActualWindow(
            cgWindowID: 4,
            subrole: "AXStandardWindow",
            role: "AXWindow",
            title: "Extension Popup",
            size: CGSize(width: 420, height: 560),
            level: 0,
            bundleIdentifier: "org.mozilla.firefox",
            localizedName: "Firefox",
            executableURL: nil,
            qualification: .autoJoin
        )
        XCTAssertFalse(accepted)
    }

    func testAutoJoinAcceptsLargeFirefoxBrowserWindow() {
        let accepted = WindowDiscriminator.isActualWindow(
            cgWindowID: 5,
            subrole: "AXStandardWindow",
            role: "AXWindow",
            title: "Mozilla Firefox",
            size: CGSize(width: 1200, height: 800),
            level: 0,
            bundleIdentifier: "org.mozilla.firefox",
            localizedName: "Firefox",
            executableURL: nil,
            qualification: .autoJoin
        )
        XCTAssertTrue(accepted)
    }

    func testAutoJoinAcceptsITermUnknownSubroleMainWindow() {
        let accepted = WindowDiscriminator.isActualWindow(
            cgWindowID: 6,
            subrole: "AXUnknown",
            role: "AXWindow",
            title: "zsh",
            size: CGSize(width: 1100, height: 700),
            level: 0,
            bundleIdentifier: "com.googlecode.iterm2",
            localizedName: "iTerm2",
            executableURL: nil,
            qualification: .autoJoin
        )
        XCTAssertTrue(accepted)
    }

    func testAutoJoinRejectsITermDialogWindow() {
        let accepted = WindowDiscriminator.isActualWindow(
            cgWindowID: 7,
            subrole: "AXDialog",
            role: "AXWindow",
            title: "Preferences",
            size: CGSize(width: 900, height: 620),
            level: 0,
            bundleIdentifier: "com.googlecode.iterm2",
            localizedName: "iTerm2",
            executableURL: nil,
            qualification: .autoJoin
        )
        XCTAssertFalse(accepted)
    }

    func testWindowDiscoveryAcceptsITermUnknownSubroleMainWindow() {
        let accepted = WindowDiscriminator.isActualWindow(
            cgWindowID: 8,
            subrole: "AXUnknown",
            role: "AXWindow",
            title: "zsh",
            size: CGSize(width: 1000, height: 650),
            level: 0,
            bundleIdentifier: "com.googlecode.iterm2",
            localizedName: "iTerm2",
            executableURL: nil
        )
        XCTAssertTrue(accepted)
    }

    func testAutoJoinRejectsITermUnknownSubroleWithEmptyTitle() {
        let accepted = WindowDiscriminator.isActualWindow(
            cgWindowID: 9,
            subrole: "AXUnknown",
            role: "AXWindow",
            title: "",
            size: CGSize(width: 1100, height: 700),
            level: 0,
            bundleIdentifier: "com.googlecode.iterm2",
            localizedName: "iTerm2",
            executableURL: nil,
            qualification: .autoJoin
        )
        XCTAssertFalse(accepted)
    }

    func testAutoJoinRejectsITermUnknownSubroleWhenTooSmall() {
        let accepted = WindowDiscriminator.isActualWindow(
            cgWindowID: 10,
            subrole: "AXUnknown",
            role: "AXWindow",
            title: "tiny",
            size: CGSize(width: 420, height: 280),
            level: 0,
            bundleIdentifier: "com.googlecode.iterm2",
            localizedName: "iTerm2",
            executableURL: nil,
            qualification: .autoJoin
        )
        XCTAssertFalse(accepted)
    }
}
