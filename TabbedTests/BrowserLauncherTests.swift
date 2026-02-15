import XCTest
@testable import Tabbed

final class BrowserLauncherTests: XCTestCase {

    func testChromiumNewWindowArgsUsesRealNewTabForHelium() {
        XCTAssertEqual(
            ChromiumBrowserLauncher.newWindowArgs(bundleID: BrowserProviderResolver.heliumBundleID),
            ["--new-window"]
        )
    }

    func testChromiumNewWindowArgsUsesBlankURLForOtherChromiumBrowsers() {
        XCTAssertEqual(
            ChromiumBrowserLauncher.newWindowArgs(bundleID: "com.google.Chrome"),
            ["--new-window", "about:blank"]
        )
    }

    func testFirefoxNewWindowArgsUsesDoubleHyphenFlagForBlankWindow() {
        XCTAssertEqual(
            FirefoxBrowserLauncher.newWindowArgs(url: nil),
            ["--new-window", "about:blank"]
        )
    }

    func testFirefoxNewWindowArgsUsesDoubleHyphenFlagForURL() {
        let url = URL(string: "https://example.com")!
        XCTAssertEqual(
            FirefoxBrowserLauncher.newWindowArgs(url: url),
            ["--new-window", "https://example.com"]
        )
    }

    func testCommonSearchProvidersContainsSevenAndIncludesKagiAndUnduck() {
        XCTAssertEqual(SearchEngine.commonProviders.count, 7)
        XCTAssertEqual(SearchEngine.commonProviders.first, .unduck)
        XCTAssertEqual(SearchEngine.commonProviders[1], .google)
        XCTAssertEqual(SearchEngine.commonProviders[2], .googleWeb)
        XCTAssertTrue(SearchEngine.commonProviders.contains(.kagi))
        XCTAssertTrue(SearchEngine.commonProviders.contains(.unduck))
        XCTAssertFalse(SearchEngine.commonProviders.contains(.custom))
    }

    func testAIProvidersContainGoogleAIAndChatProviders() {
        XCTAssertEqual(SearchEngine.aiProviders, [.googleAI, .perplexity, .chatGPT, .claude])
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
