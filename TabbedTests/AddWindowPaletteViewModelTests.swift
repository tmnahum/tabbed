import XCTest
@testable import Tabbed

final class AddWindowPaletteViewModelTests: XCTestCase {
    private func makeContext(urlHistory: [LauncherHistoryStore.URLEntry]) -> LauncherQueryContext {
        LauncherQueryContext(
            mode: .newGroup,
            looseWindows: [],
            mergeGroups: [],
            appCatalog: [],
            launcherConfig: .default,
            resolvedBrowserProvider: nil,
            currentSpaceID: nil,
            windowRecency: [:],
            groupRecency: [:],
            appRecency: [:],
            urlHistory: urlHistory,
            appLaunchHistory: [:]
        )
    }

    private func containsOpenURL(_ candidates: [LauncherCandidate], canonicalURL: String) -> Bool {
        candidates.contains { candidate in
            guard case .openURL(let url) = candidate.action else { return false }
            return LauncherHistoryStore.canonicalURLString(url) == canonicalURL
        }
    }

    @MainActor
    private func waitForCondition(timeout: TimeInterval, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    @MainActor
    func testHistoryUpdateNotificationRefreshesContextAndReranks() {
        let notificationCenter = NotificationCenter()
        var context = makeContext(urlHistory: [])

        let viewModel = AddWindowPaletteViewModel(
            launcherEngine: LauncherEngine(),
            contextProvider: { context },
            actionExecutor: { _, _, _ in },
            dismiss: { },
            notificationCenter: notificationCenter
        )

        viewModel.query = "exa"
        viewModel.refreshSources()
        XCTAssertFalse(containsOpenURL(viewModel.candidates, canonicalURL: "https://example.com"))

        context = makeContext(urlHistory: [
            LauncherHistoryStore.URLEntry(
                urlString: "https://example.com",
                launchCount: 2,
                lastLaunchedAt: Date()
            )
        ])

        notificationCenter.post(name: LauncherHistoryStore.didUpdateNotification, object: nil)

        XCTAssertTrue(waitForCondition(timeout: 1.0) {
            self.containsOpenURL(viewModel.candidates, canonicalURL: "https://example.com")
        })
    }
}
