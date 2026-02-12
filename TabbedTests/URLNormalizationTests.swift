import XCTest
@testable import Tabbed

final class URLNormalizationTests: XCTestCase {

    func testSchemeLessHostGetsHTTPSPrepended() {
        let url = LauncherEngine.normalizeURL(from: "example.com/path")
        XCTAssertEqual(url?.absoluteString, "https://example.com/path")
    }

    func testLocalhostIPv4AndIPv6AreAccepted() {
        XCTAssertEqual(LauncherEngine.normalizeURL(from: "localhost:3000")?.absoluteString, "https://localhost:3000")
        XCTAssertEqual(LauncherEngine.normalizeURL(from: "127.0.0.1:8080")?.absoluteString, "https://127.0.0.1:8080")
        XCTAssertEqual(LauncherEngine.normalizeURL(from: "[::1]:8080")?.absoluteString, "https://[::1]:8080")
    }

    func testInvalidInputRejected() {
        XCTAssertNil(LauncherEngine.normalizeURL(from: "not-a-url"))
        XCTAssertNil(LauncherEngine.normalizeURL(from: "http://bad host"))
        XCTAssertNil(LauncherEngine.normalizeURL(from: ""))
    }

    func testSearchFallbackURLGeneration() {
        XCTAssertEqual(
            SearchEngine.google.searchURL(for: "alpha beta")?.absoluteString,
            "https://www.google.com/search?q=alpha%20beta"
        )
        XCTAssertEqual(
            SearchEngine.duckDuckGo.searchURL(for: "alpha")?.absoluteString,
            "https://duckduckgo.com/?q=alpha"
        )
        XCTAssertEqual(
            SearchEngine.bing.searchURL(for: "alpha")?.absoluteString,
            "https://www.bing.com/search?q=alpha"
        )
        XCTAssertEqual(
            SearchEngine.brave.searchURL(for: "alpha")?.absoluteString,
            "https://search.brave.com/search?q=alpha"
        )
        XCTAssertEqual(
            SearchEngine.kagi.searchURL(for: "alpha")?.absoluteString,
            "https://kagi.com/search?q=alpha"
        )
        XCTAssertEqual(
            SearchEngine.unduck.searchURL(for: "alpha")?.absoluteString,
            "https://unduck.link/?q=alpha"
        )
        XCTAssertEqual(
            SearchEngine.googleAI.searchURL(for: "alpha")?.absoluteString,
            "https://www.google.com/search?q=alpha&udm=50"
        )
        XCTAssertEqual(
            SearchEngine.googleWeb.searchURL(for: "alpha")?.absoluteString,
            "https://www.google.com/search?q=alpha&udm=14"
        )
        XCTAssertEqual(
            SearchEngine.perplexity.searchURL(for: "alpha")?.absoluteString,
            "https://www.perplexity.ai/search/new?q=alpha"
        )
        XCTAssertEqual(
            SearchEngine.chatGPT.searchURL(for: "alpha")?.absoluteString,
            "https://chatgpt.com/?q=alpha"
        )
        XCTAssertEqual(
            SearchEngine.claude.searchURL(for: "alpha")?.absoluteString,
            "https://claude.ai/new?q=alpha"
        )
    }

    func testCustomTemplateSearchURLGeneration() {
        XCTAssertEqual(
            SearchEngine.custom.searchURL(for: "alpha beta", customTemplate: "https://example.com/find?term=%s")?.absoluteString,
            "https://example.com/find?term=alpha%20beta"
        )
        XCTAssertNil(SearchEngine.custom.searchURL(for: "alpha", customTemplate: "https://example.com/find"))
    }
}
