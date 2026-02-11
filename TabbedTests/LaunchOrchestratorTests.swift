import XCTest
@testable import Tabbed
import ApplicationServices

final class LaunchOrchestratorTests: XCTestCase {

    private func makeWindow(id: CGWindowID, pid: pid_t) -> WindowInfo {
        WindowInfo(
            id: id,
            element: AXUIElementCreateSystemWide(),
            ownerPID: pid,
            bundleID: "com.test.app",
            title: "W\(id)",
            appName: "Test",
            icon: nil
        )
    }

    private func makeApp(isRunning: Bool) -> AppCatalogService.AppRecord {
        AppCatalogService.AppRecord(
            bundleID: "com.test.app",
            displayName: "Test App",
            appURL: URL(fileURLWithPath: "/Applications/Test.app"),
            icon: nil,
            isRunning: isRunning,
            runningPID: isRunning ? 42 : nil,
            recency: 10
        )
    }

    func testRunningAppAttemptsNewWindowBeforeReopenAndActivation() {
        var callOrder: [String] = []

        var deps = LaunchOrchestrator.Dependencies()
        deps.listWindows = { [self.makeWindow(id: 1, pid: 42)] }
        deps.runningPIDForBundle = { _ in 42 }
        deps.attemptProviderNewWindow = { _ in
            callOrder.append("provider")
            return false
        }
        deps.reopenRunningApp = { _, _ in
            callOrder.append("reopen")
            return true
        }
        deps.activateApp = { _ in
            callOrder.append("activate")
        }
        deps.sleep = { _ in }

        let orchestrator = LaunchOrchestrator(
            timing: .init(timeout: 0, pollInterval: 0),
            dependencies: deps
        )

        let outcome = orchestrator.launchAppAndCaptureSync(
            app: makeApp(isRunning: true),
            request: .init(mode: .newGroup, currentSpaceID: 1)
        )

        XCTAssertEqual(callOrder, ["provider", "reopen", "activate"])
        XCTAssertEqual(outcome.result, .timedOut(status: "No new window detected"))
    }

    func testTimeoutFallsBackToActivation() {
        var didActivate = false
        var reopenCalls = 0

        var deps = LaunchOrchestrator.Dependencies()
        deps.listWindows = { [self.makeWindow(id: 1, pid: 42)] }
        deps.runningPIDForBundle = { _ in 42 }
        deps.attemptProviderNewWindow = { _ in true }
        deps.reopenRunningApp = { _, _ in
            reopenCalls += 1
            return true
        }
        deps.activateApp = { _ in
            didActivate = true
        }
        deps.sleep = { _ in }

        let orchestrator = LaunchOrchestrator(
            timing: .init(timeout: 0, pollInterval: 0),
            dependencies: deps
        )

        let outcome = orchestrator.launchAppAndCaptureSync(
            app: makeApp(isRunning: true),
            request: .init(mode: .newGroup, currentSpaceID: 1)
        )

        XCTAssertEqual(reopenCalls, 1)
        XCTAssertTrue(didActivate)
        XCTAssertEqual(outcome.result, .timedOut(status: "No new window detected"))
    }

    func testCaptureReturnsFirstEligibleNewWindow() {
        var pollCount = 0

        var deps = LaunchOrchestrator.Dependencies()
        deps.launchApplication = { _, _ in true }
        deps.runningPIDForBundle = { _ in 52 }
        deps.isWindowGrouped = { _ in false }
        deps.spaceIDForWindow = { _ in 7 }
        deps.listWindows = {
            defer { pollCount += 1 }
            if pollCount == 0 {
                return [self.makeWindow(id: 1, pid: 52)]
            }
            return [self.makeWindow(id: 1, pid: 52), self.makeWindow(id: 2, pid: 52)]
        }
        deps.sleep = { _ in }

        let orchestrator = LaunchOrchestrator(
            timing: .init(timeout: 0.01, pollInterval: 0),
            dependencies: deps
        )

        let outcome = orchestrator.launchAppAndCaptureSync(
            app: makeApp(isRunning: false),
            request: .init(mode: .newGroup, currentSpaceID: 7)
        )

        XCTAssertEqual(outcome.result, .succeeded)
        XCTAssertEqual(outcome.capturedWindow?.id, 2)
    }

    // MARK: - URL launch provider isolation

    private func makeProvider() -> ResolvedBrowserProvider {
        ResolvedBrowserProvider(
            selection: BrowserProviderSelection(bundleID: "com.test.browser", engine: .chromium),
            appURL: URL(fileURLWithPath: "/Applications/TestBrowser.app")
        )
    }

    func testURLLaunchWithProviderDoesNotFallBackToSystemDefault() {
        var usedSystemFallback = false

        var deps = LaunchOrchestrator.Dependencies()
        deps.listWindows = { [self.makeWindow(id: 1, pid: 42)] }
        deps.runningPIDForBundle = { _ in 42 }
        deps.launchURLFallback = { _ in
            usedSystemFallback = true
            return true
        }
        deps.activateApp = { _ in }
        deps.sleep = { _ in }

        let orchestrator = LaunchOrchestrator(
            timing: .init(timeout: 0, pollInterval: 0),
            dependencies: deps
        )

        let outcome = orchestrator.launchURLAndCaptureSync(
            url: URL(string: "https://example.com")!,
            provider: makeProvider(),
            request: .init(mode: .newGroup, currentSpaceID: 1)
        )

        XCTAssertFalse(usedSystemFallback, "Should not fall back to system default browser when provider is configured")
        XCTAssertNotEqual(outcome.result, .succeeded)
    }

    func testURLLaunchWithoutProviderUsesSystemDefault() {
        var usedSystemFallback = false

        var deps = LaunchOrchestrator.Dependencies()
        deps.listWindows = { [] }
        deps.runningPIDForBundle = { _ in nil }
        deps.launchURLFallback = { _ in
            usedSystemFallback = true
            return true
        }
        deps.sleep = { _ in }

        let orchestrator = LaunchOrchestrator(
            timing: .init(timeout: 0, pollInterval: 0),
            dependencies: deps
        )

        _ = orchestrator.launchURLAndCaptureSync(
            url: URL(string: "https://example.com")!,
            provider: nil,
            request: .init(mode: .newGroup, currentSpaceID: 1)
        )

        XCTAssertTrue(usedSystemFallback, "Should use system default when no provider is configured")
    }

    func testSearchLaunchWithProviderDoesNotFallBackToSystemDefault() {
        var usedSystemFallback = false

        var deps = LaunchOrchestrator.Dependencies()
        deps.listWindows = { [self.makeWindow(id: 1, pid: 42)] }
        deps.runningPIDForBundle = { _ in 42 }
        deps.launchSearchFallback = { _, _ in
            usedSystemFallback = true
            return true
        }
        deps.activateApp = { _ in }
        deps.sleep = { _ in }

        let orchestrator = LaunchOrchestrator(
            timing: .init(timeout: 0, pollInterval: 0),
            dependencies: deps
        )

        let outcome = orchestrator.launchSearchAndCaptureSync(
            query: "test query",
            provider: makeProvider(),
            searchEngine: .google,
            request: .init(mode: .newGroup, currentSpaceID: 1)
        )

        XCTAssertFalse(usedSystemFallback, "Should not fall back to system default browser when provider is configured")
        XCTAssertNotEqual(outcome.result, .succeeded)
    }

    func testSearchLaunchWithoutProviderUsesSystemDefault() {
        var usedSystemFallback = false

        var deps = LaunchOrchestrator.Dependencies()
        deps.listWindows = { [] }
        deps.runningPIDForBundle = { _ in nil }
        deps.launchSearchFallback = { _, _ in
            usedSystemFallback = true
            return true
        }
        deps.sleep = { _ in }

        let orchestrator = LaunchOrchestrator(
            timing: .init(timeout: 0, pollInterval: 0),
            dependencies: deps
        )

        _ = orchestrator.launchSearchAndCaptureSync(
            query: "test query",
            provider: nil,
            searchEngine: .google,
            request: .init(mode: .newGroup, currentSpaceID: 1)
        )

        XCTAssertTrue(usedSystemFallback, "Should use system default when no provider is configured")
    }

    // MARK: - App-specific new window args

    func testKnownNewWindowArgsContainsVSCodeFamily() {
        let args = LaunchOrchestrator.knownNewWindowArgs
        XCTAssertEqual(args["com.microsoft.VSCode"], ["--new-window"])
        XCTAssertEqual(args["com.microsoft.VSCodeInsiders"], ["--new-window"])
        XCTAssertEqual(args["com.todesktop.230313mzl4w4u92"], ["--new-window"]) // Cursor
        XCTAssertEqual(args["com.exafunction.windsurf"], ["--new-window"]) // Windsurf
        XCTAssertEqual(args["com.vscodium"], ["--new-window"])
        XCTAssertEqual(args["co.posit.positron"], ["--new-window"]) // Positron
        XCTAssertEqual(args["com.trae.app"], ["--new-window"]) // Trae
        XCTAssertEqual(args["com.visualstudio.code.oss"], ["--new-window"]) // Code OSS
    }

    func testKnownNewWindowArgsContainsEditors() {
        let args = LaunchOrchestrator.knownNewWindowArgs
        XCTAssertEqual(args["dev.zed.Zed"], ["--new"])
        XCTAssertEqual(args["com.sublimetext.4"], ["--new-window"])
        XCTAssertEqual(args["com.sublimetext.3"], ["--new-window"])
    }

    func testKnownNewWindowArgsContainsTerminals() {
        let args = LaunchOrchestrator.knownNewWindowArgs
        XCTAssertEqual(args["net.kovidgoyal.kitty"], ["--single-instance"])
    }

    func testKnownNewWindowArgsDoesNotMatchUnknownApps() {
        XCTAssertNil(LaunchOrchestrator.knownNewWindowArgs["com.apple.finder"])
        XCTAssertNil(LaunchOrchestrator.knownNewWindowArgs["com.unknown.app"])
    }

    func testHasNativeNewWindowSupportForKnownApps() {
        // VSCode fork
        XCTAssertTrue(LaunchOrchestrator.hasNativeNewWindowSupport(bundleID: "com.microsoft.VSCode"))
        // Kitty
        XCTAssertTrue(LaunchOrchestrator.hasNativeNewWindowSupport(bundleID: "net.kovidgoyal.kitty"))
        // Chromium browser
        XCTAssertTrue(LaunchOrchestrator.hasNativeNewWindowSupport(bundleID: "com.google.Chrome"))
        // Firefox browser
        XCTAssertTrue(LaunchOrchestrator.hasNativeNewWindowSupport(bundleID: "org.mozilla.firefox"))
        // Unknown app
        XCTAssertFalse(LaunchOrchestrator.hasNativeNewWindowSupport(bundleID: "com.unknown.app"))
    }

    func testKnownAppProviderSucceedsCapturesWindowSkipsReopen() {
        var reopenCalled = false
        var pollCount = 0

        var deps = LaunchOrchestrator.Dependencies()
        deps.runningPIDForBundle = { _ in 42 }
        deps.isWindowGrouped = { _ in false }
        deps.spaceIDForWindow = { _ in 1 }
        deps.attemptProviderNewWindow = { bundleID in
            LaunchOrchestrator.knownNewWindowArgs[bundleID] != nil
        }
        deps.reopenRunningApp = { _, _ in
            reopenCalled = true
            return true
        }
        deps.activateApp = { _ in }
        deps.listWindows = { [self] in
            defer { pollCount += 1 }
            if pollCount <= 1 { return [self.makeWindow(id: 1, pid: 42)] }
            return [self.makeWindow(id: 1, pid: 42), self.makeWindow(id: 2, pid: 42)]
        }
        deps.sleep = { _ in }
        deps.log = { _ in }

        let orchestrator = LaunchOrchestrator(
            timing: .init(timeout: 0.1, pollInterval: 0),
            dependencies: deps
        )

        let app = AppCatalogService.AppRecord(
            bundleID: "com.microsoft.VSCode",
            displayName: "VS Code",
            appURL: URL(fileURLWithPath: "/Applications/Visual Studio Code.app"),
            icon: nil,
            isRunning: true,
            runningPID: 42,
            recency: 10
        )

        let outcome = orchestrator.launchAppAndCaptureSync(
            app: app,
            request: .init(mode: .newGroup, currentSpaceID: 1)
        )

        XCTAssertFalse(reopenCalled, "Reopen should not be called when provider succeeds and window is captured")
        XCTAssertEqual(outcome.result, .succeeded)
        XCTAssertEqual(outcome.capturedWindow?.id, 2)
    }

    func testKnownAppProviderFailsFallsBackToReopen() {
        var callOrder: [String] = []

        var deps = LaunchOrchestrator.Dependencies()
        deps.runningPIDForBundle = { _ in 42 }
        deps.isWindowGrouped = { _ in false }
        deps.spaceIDForWindow = { _ in 1 }
        deps.attemptProviderNewWindow = { _ in
            callOrder.append("provider")
            return false
        }
        deps.reopenRunningApp = { _, _ in
            callOrder.append("reopen")
            return true
        }
        deps.activateApp = { _ in
            callOrder.append("activate")
        }
        deps.listWindows = { [self.makeWindow(id: 1, pid: 42)] }
        deps.sleep = { _ in }
        deps.log = { _ in }

        let orchestrator = LaunchOrchestrator(
            timing: .init(timeout: 0, pollInterval: 0),
            dependencies: deps
        )

        let app = AppCatalogService.AppRecord(
            bundleID: "com.microsoft.VSCode",
            displayName: "VS Code",
            appURL: URL(fileURLWithPath: "/Applications/Visual Studio Code.app"),
            icon: nil,
            isRunning: true,
            runningPID: 42,
            recency: 10
        )

        let outcome = orchestrator.launchAppAndCaptureSync(
            app: app,
            request: .init(mode: .newGroup, currentSpaceID: 1)
        )

        XCTAssertEqual(callOrder, ["provider", "reopen", "activate"])
        XCTAssertEqual(outcome.result, .timedOut(status: "No new window detected"))
    }

    // MARK: - URL launch

    func testURLLaunchProviderSuccessButCaptureTimeoutReturnsTimeout() {
        var deps = LaunchOrchestrator.Dependencies()
        deps.listWindows = { [self.makeWindow(id: 1, pid: 42)] }
        deps.runningPIDForBundle = { _ in 42 }
        deps.activateApp = { _ in }
        deps.sleep = { _ in }

        let orchestrator = LaunchOrchestrator(
            timing: .init(timeout: 0, pollInterval: 0),
            dependencies: deps
        )

        // defaultLaunchURL will use the chromiumLauncher which won't actually launch anything
        // in test, but the mock launchURLAction returns true
        var depsMut = deps
        depsMut.launchURLAction = { _, _ in true }
        let orchestratorWithAction = LaunchOrchestrator(
            timing: .init(timeout: 0, pollInterval: 0),
            dependencies: depsMut
        )

        let outcome = orchestratorWithAction.launchURLAndCaptureSync(
            url: URL(string: "https://example.com")!,
            provider: makeProvider(),
            request: .init(mode: .newGroup, currentSpaceID: 1)
        )

        XCTAssertEqual(outcome.result, .timedOut(status: "No new window detected"))
    }
}
