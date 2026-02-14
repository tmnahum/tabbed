import XCTest
@testable import Tabbed

final class CGWindowFilterTests: XCTestCase {

    // MARK: - isPlausibleCGWindow

    private func meta(
        bounds: CGRect = CGRect(x: 0, y: 0, width: 800, height: 600),
        name: String? = nil,
        alpha: CGFloat = 1.0,
        isOnscreen: Bool = true
    ) -> WindowDiscriminator.CGWindowMeta {
        WindowDiscriminator.CGWindowMeta(
            bounds: bounds, zOrder: 0, name: name, alpha: alpha, isOnscreen: isOnscreen
        )
    }

    func testWindowWithTitleIsPlausible() {
        XCTAssertTrue(WindowDiscriminator.isPlausibleCGWindow(
            meta(name: "My Document")
        ))
    }

    func testWindowWithTitleOffScreenIsPlausible() {
        // Cross-space windows have a title but are off-screen on the current space
        XCTAssertTrue(WindowDiscriminator.isPlausibleCGWindow(
            meta(bounds: CGRect(x: 0, y: 0, width: 1440, height: 900),
                 name: "Firefox", isOnscreen: false)
        ))
    }

    func testWindowWithTitleSmallBoundsIsPlausible() {
        // A titled window with small bounds is still a real window (tooltip-style)
        XCTAssertTrue(WindowDiscriminator.isPlausibleCGWindow(
            meta(bounds: CGRect(x: 100, y: 100, width: 10, height: 10), name: "Status")
        ))
    }

    func testInvisibleWindowIsNotPlausible() {
        // Alpha = 0 — invisible overlay surface
        XCTAssertFalse(WindowDiscriminator.isPlausibleCGWindow(
            meta(name: "Overlay", alpha: 0.0)
        ))
    }

    func testZeroBoundsIsNotPlausible() {
        XCTAssertFalse(WindowDiscriminator.isPlausibleCGWindow(
            meta(bounds: .zero, isOnscreen: false)
        ))
    }

    func testDegenerateBoundsIsNotPlausible() {
        // 0-width rendering surface
        XCTAssertFalse(WindowDiscriminator.isPlausibleCGWindow(
            meta(bounds: CGRect(x: 0, y: 0, width: 0.5, height: 900))
        ))
    }

    func testNoTitleLargeBoundsOnScreenIsPlausible() {
        // No title but big and on-screen — could be a loading window
        XCTAssertTrue(WindowDiscriminator.isPlausibleCGWindow(
            meta()
        ))
    }

    func testNoTitleWindowSizedBoundsOffScreenIsPlausible() {
        // Off-space windows are often untitled and report off-screen on the active Space.
        XCTAssertTrue(WindowDiscriminator.isPlausibleCGWindow(
            meta(bounds: CGRect(x: 120, y: 80, width: 900, height: 700), isOnscreen: false)
        ))
    }

    func testNoTitleSmallBoundsOffScreenIsNotPlausible() {
        XCTAssertFalse(WindowDiscriminator.isPlausibleCGWindow(
            meta(bounds: CGRect(x: 0, y: 0, width: 80, height: 80), isOnscreen: false)
        ))
    }

    func testNoTitleSmallBoundsOnScreenIsNotPlausible() {
        // No title, small, on-screen — surface/overlay
        XCTAssertFalse(WindowDiscriminator.isPlausibleCGWindow(
            meta(bounds: CGRect(x: 0, y: 0, width: 30, height: 30))
        ))
    }

    func testEmptyTitleIsNotPlausible() {
        // Empty string title is treated the same as nil
        XCTAssertFalse(WindowDiscriminator.isPlausibleCGWindow(
            meta(bounds: CGRect(x: 0, y: 0, width: 30, height: 30),
                 name: "", isOnscreen: false)
        ))
    }

    func testOffScreenMenuBarStripIsNotPlausible() {
        // Typical non-window surface: untitled, thin menu-bar-sized strip.
        XCTAssertFalse(WindowDiscriminator.isPlausibleCGWindow(
            meta(bounds: CGRect(x: 0, y: 0, width: 1440, height: 24), isOnscreen: false)
        ))
    }

    func testGameRealWindow() {
        // The actual game window has a title
        XCTAssertTrue(WindowDiscriminator.isPlausibleCGWindow(
            meta(name: "Balatro")
        ))
    }

    func testPartiallyTransparentWithTitleIsPlausible() {
        XCTAssertTrue(WindowDiscriminator.isPlausibleCGWindow(
            meta(bounds: CGRect(x: 0, y: 0, width: 400, height: 300),
                 name: "HUD", alpha: 0.5)
        ))
    }

    func testZeroBoundsWithTitleAndAlphaIsNotPlausible() {
        // Even with a title, zero-size is degenerate
        XCTAssertFalse(WindowDiscriminator.isPlausibleCGWindow(
            meta(bounds: CGRect(x: 50, y: 50, width: 0, height: 0), name: "Ghost")
        ))
    }
}
