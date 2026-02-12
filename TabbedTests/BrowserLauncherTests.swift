import XCTest
@testable import Tabbed

final class BrowserLauncherTests: XCTestCase {

    func testFirefoxNewWindowArgsUsesSingleHyphenFlagForBlankWindow() {
        XCTAssertEqual(
            FirefoxBrowserLauncher.newWindowArgs(url: nil),
            ["-new-window", "about:blank"]
        )
    }

    func testFirefoxNewWindowArgsUsesSingleHyphenFlagForURL() {
        let url = URL(string: "https://example.com")!
        XCTAssertEqual(
            FirefoxBrowserLauncher.newWindowArgs(url: url),
            ["-new-window", "https://example.com"]
        )
    }

    func testCommonSearchProvidersContainsSixAndIncludesKagiAndUnduck() {
        XCTAssertEqual(SearchEngine.commonProviders.count, 6)
        XCTAssertTrue(SearchEngine.commonProviders.contains(.kagi))
        XCTAssertTrue(SearchEngine.commonProviders.contains(.unduck))
        XCTAssertFalse(SearchEngine.commonProviders.contains(.custom))
    }

    func testCustomSearchTemplateValidationRequiresPercentS() {
        XCTAssertTrue(SearchEngine.isTemplateValid("https://example.com/search?q=%s"))
        XCTAssertFalse(SearchEngine.isTemplateValid("https://example.com/search?q="))
    }

    func testCustomSearchTemplateCanReplaceMultiplePlaceholders() {
        let url = SearchEngine.custom.searchURL(
            for: "tabbed app",
            customTemplate: "https://example.com/?q=%s&src=%s"
        )
        XCTAssertEqual(url?.absoluteString, "https://example.com/?q=tabbed%20app&src=tabbed%20app")
    }
}
