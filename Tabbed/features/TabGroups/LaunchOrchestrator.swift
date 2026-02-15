import AppKit

final class LaunchOrchestrator {

    struct CaptureRequest {
        let mode: LauncherMode
        let currentSpaceID: UInt64?

        var targetSpaceID: UInt64 {
            switch mode {
            case .newGroup:
                return 0
            case .addToGroup(_, let targetSpaceID):
                return targetSpaceID
            }
        }
    }

    struct Timing {
        var timeout: TimeInterval = 2.5
        var pollInterval: TimeInterval = 0.05
    }

    struct Outcome: Equatable {
        let result: LaunchAttemptResult
        let capturedWindow: WindowInfo?

        static func == (lhs: Outcome, rhs: Outcome) -> Bool {
            lhs.result == rhs.result && lhs.capturedWindow?.id == rhs.capturedWindow?.id
        }
    }

    struct Dependencies {
        var listWindows: () -> [WindowInfo] = { WindowDiscovery.currentSpace() }
        var isWindowGrouped: (CGWindowID) -> Bool = { _ in false }
        var spaceIDForWindow: (CGWindowID) -> UInt64? = { SpaceUtils.spaceID(for: $0) }
        var runningPIDForBundle: (String) -> pid_t? = { bundleID in
            NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID })?.processIdentifier
        }
        var reopenRunningApp: (String, URL?) -> Bool = { bundleID, _ in
            if LaunchOrchestrator.sendAppSpecificNewWindowAppleEvent(bundleID: bundleID) {
                return true
            }
            if let args = LaunchOrchestrator.knownNewWindowArgs[bundleID],
               LaunchOrchestrator.launchNewWindowWithArgs(bundleID: bundleID, args: args) {
                return true
            }
            if let args = LaunchOrchestrator.bestEffortNewWindowArgs[bundleID],
               LaunchOrchestrator.launchNewWindowWithArgs(bundleID: bundleID, args: args) {
                return true
            }
            if LaunchOrchestrator.sendKnownNewWindowKeystrokes(bundleID: bundleID) {
                return true
            }
            LaunchOrchestrator.attemptSpeculativeNewWindowArgs(bundleID: bundleID)
            if LaunchOrchestrator.sendBestEffortNewWindowKeystrokes(bundleID: bundleID) {
                return true
            }
            if LaunchOrchestrator.sendReopenAppleEvent(bundleID: bundleID) {
                return true
            }
            return LaunchOrchestrator.runOpenCommand(bundleID: bundleID, args: [])
        }
        var launchApplication: (String, URL?) -> Bool = { bundleID, _ in
            LaunchOrchestrator.runOpenCommand(bundleID: bundleID, args: [])
        }
        var activateApp: (String) -> Void = { bundleID in
            guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) else { return }
            if #available(macOS 14.0, *) {
                app.activate()
            } else {
                app.activate(options: [])
            }
        }
        var attemptProviderNewWindow: ((String) -> Bool)? = nil
        var launchURLAction: ((URL, ResolvedBrowserProvider) -> Bool)? = nil
        var launchSearchAction: ((String, ResolvedBrowserProvider, SearchEngine, String) -> Bool)? = nil
        var launchURLFallback: (URL) -> Bool = { url in
            NSWorkspace.shared.open(url)
        }
        var launchSearchFallback: (String, SearchEngine, String) -> Bool = { query, searchEngine, customSearchTemplate in
            let searchURL = searchEngine.searchURL(for: query, customTemplate: customSearchTemplate)
                ?? SearchEngine.google.searchURL(for: query, customTemplate: nil)
            guard let searchURL else { return false }
            return NSWorkspace.shared.open(searchURL)
        }
        var sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
        var async: (@escaping () -> Void) -> Void = { work in
            DispatchQueue.global(qos: .userInitiated).async(execute: work)
        }
        var completeOnMain: (@escaping () -> Void) -> Void = { work in
            DispatchQueue.main.async(execute: work)
        }
        var log: (String) -> Void = { Logger.log($0) }
    }

    private let timing: Timing
    private let resolver: BrowserProviderResolver
    private let chromiumLauncher: BrowserLauncher
    private let firefoxLauncher: BrowserLauncher
    private let safariLauncher: BrowserLauncher
    private var dependencies: Dependencies

    init(
        timing: Timing = Timing(),
        resolver: BrowserProviderResolver = BrowserProviderResolver(),
        chromiumLauncher: BrowserLauncher = ChromiumBrowserLauncher(),
        firefoxLauncher: BrowserLauncher = FirefoxBrowserLauncher(),
        safariLauncher: BrowserLauncher = SafariBrowserLauncher(),
        dependencies: Dependencies = Dependencies()
    ) {
        self.timing = timing
        self.resolver = resolver
        self.chromiumLauncher = chromiumLauncher
        self.firefoxLauncher = firefoxLauncher
        self.safariLauncher = safariLauncher
        self.dependencies = dependencies
    }

    func launchAppAndCapture(
        app: AppCatalogService.AppRecord,
        request: CaptureRequest,
        completion: @escaping (Outcome) -> Void
    ) {
        dependencies.async { [self] in
            let outcome = launchAppAndCaptureSync(app: app, request: request)
            dependencies.completeOnMain {
                completion(outcome)
            }
        }
    }

    func launchURLAndCapture(
        url: URL,
        provider: ResolvedBrowserProvider?,
        request: CaptureRequest,
        completion: @escaping (Outcome) -> Void
    ) {
        dependencies.async { [self] in
            let outcome = launchURLAndCaptureSync(url: url, provider: provider, request: request)
            dependencies.completeOnMain {
                completion(outcome)
            }
        }
    }

    func launchSearchAndCapture(
        query: String,
        provider: ResolvedBrowserProvider?,
        searchEngine: SearchEngine,
        customSearchTemplate: String,
        request: CaptureRequest,
        completion: @escaping (Outcome) -> Void
    ) {
        dependencies.async { [self] in
            let outcome = launchSearchAndCaptureSync(
                query: query,
                provider: provider,
                searchEngine: searchEngine,
                customSearchTemplate: customSearchTemplate,
                request: request
            )
            dependencies.completeOnMain {
                completion(outcome)
            }
        }
    }

    // MARK: - Sync API (used by tests)

    func launchAppAndCaptureSync(app: AppCatalogService.AppRecord, request: CaptureRequest) -> Outcome {
        dependencies.log("[LAUNCHER_ACTION] appLaunch bundle=\(app.bundleID) running=\(app.isRunning)")

        if app.isRunning {
            let providerBaseline = baselineWindowIDs(forPID: dependencies.runningPIDForBundle(app.bundleID))
            dependencies.log("[CAPTURE_WAIT] provider baseline bundle=\(app.bundleID) count=\(providerBaseline.count)")

            let providerDispatched = dependencies.attemptProviderNewWindow?(app.bundleID)
                ?? defaultAttemptProviderNewWindow(bundleID: app.bundleID, appURL: app.appURL)
            dependencies.log("[APP_LAUNCH] running new-window attempt bundle=\(app.bundleID) success=\(providerDispatched)")

            if providerDispatched {
                let providerCapture = waitForCapturedWindow(
                    baseline: providerBaseline,
                    pidResolver: { self.dependencies.runningPIDForBundle(app.bundleID) },
                    request: request
                )
                if let providerCapture {
                    dependencies.log("[CAPTURE_RESULT] success bundle=\(app.bundleID) window=\(providerCapture.id) via=provider")
                    return Outcome(result: .succeeded, capturedWindow: providerCapture)
                }
                dependencies.log("[CAPTURE_WAIT] provider attempt produced no capture bundle=\(app.bundleID), trying reopen")
            }

            let reopenBaseline = baselineWindowIDs(forPID: dependencies.runningPIDForBundle(app.bundleID))
            dependencies.log("[CAPTURE_WAIT] reopen baseline bundle=\(app.bundleID) count=\(reopenBaseline.count)")
            let reopenDispatched = dependencies.reopenRunningApp(app.bundleID, app.appURL)
            dependencies.log("[APP_LAUNCH] running reopen attempt bundle=\(app.bundleID) success=\(reopenDispatched)")

            if reopenDispatched {
                let reopenCapture = waitForCapturedWindow(
                    baseline: reopenBaseline,
                    pidResolver: { self.dependencies.runningPIDForBundle(app.bundleID) },
                    request: request
                )
                if let reopenCapture {
                    dependencies.log("[CAPTURE_RESULT] success bundle=\(app.bundleID) window=\(reopenCapture.id) via=reopen")
                    return Outcome(result: .succeeded, capturedWindow: reopenCapture)
                }
            } else if !providerDispatched {
                dependencies.activateApp(app.bundleID)
                dependencies.log("[CAPTURE_RESULT] dispatch-failed bundle=\(app.bundleID)")
                return Outcome(result: .failed(status: "Unable to launch app"), capturedWindow: nil)
            }

            dependencies.activateApp(app.bundleID)
            dependencies.log("[CAPTURE_RESULT] timeout bundle=\(app.bundleID)")
            return Outcome(result: .timedOut(status: "No new window detected"), capturedWindow: nil)
        }

        let initialPID = dependencies.runningPIDForBundle(app.bundleID)
        let baseline = baselineWindowIDs(forPID: initialPID)
        dependencies.log("[CAPTURE_WAIT] baseline bundle=\(app.bundleID) pid=\(String(describing: initialPID)) count=\(baseline.count)")

        let launched = dependencies.launchApplication(app.bundleID, app.appURL)
        dependencies.log("[APP_LAUNCH] cold launch bundle=\(app.bundleID) success=\(launched)")
        guard launched else {
            return Outcome(result: .failed(status: "Unable to launch app"), capturedWindow: nil)
        }

        let capture = waitForCapturedWindow(
            baseline: baseline,
            pidResolver: { self.dependencies.runningPIDForBundle(app.bundleID) },
            request: request
        )
        if let capture {
            dependencies.log("[CAPTURE_RESULT] success bundle=\(app.bundleID) window=\(capture.id)")
            return Outcome(result: .succeeded, capturedWindow: capture)
        }

        dependencies.activateApp(app.bundleID)
        dependencies.log("[CAPTURE_RESULT] timeout bundle=\(app.bundleID)")
        return Outcome(result: .timedOut(status: "No new window detected"), capturedWindow: nil)
    }

    func launchURLAndCaptureSync(url: URL, provider: ResolvedBrowserProvider?, request: CaptureRequest) -> Outcome {
        if let provider {
            dependencies.log("[LAUNCHER_ACTION] openURL provider=\(provider.selection.bundleID) url=\(url.absoluteString)")

            let initialPID = dependencies.runningPIDForBundle(provider.selection.bundleID)
            let baseline = baselineWindowIDs(forPID: initialPID)
            dependencies.log("[CAPTURE_WAIT] baseline url provider=\(provider.selection.bundleID) pid=\(String(describing: initialPID)) count=\(baseline.count)")

            let launched = dependencies.launchURLAction?(url, provider) ?? defaultLaunchURL(url: url, provider: provider)
            dependencies.log("[URL_LAUNCH] url dispatch provider=\(provider.selection.bundleID) success=\(launched)")
            if launched {
                let capture = waitForCapturedWindow(
                    baseline: baseline,
                    pidResolver: { self.dependencies.runningPIDForBundle(provider.selection.bundleID) },
                    request: request
                )
                if let capture {
                    dependencies.log("[CAPTURE_RESULT] success provider=\(provider.selection.bundleID) window=\(capture.id)")
                    return Outcome(result: .succeeded, capturedWindow: capture)
                }
                dependencies.activateApp(provider.selection.bundleID)
                dependencies.log("[CAPTURE_RESULT] timeout provider=\(provider.selection.bundleID)")
                return Outcome(result: .timedOut(status: "No new window detected"), capturedWindow: nil)
            }

            dependencies.activateApp(provider.selection.bundleID)
            dependencies.log("[CAPTURE_RESULT] failed provider=\(provider.selection.bundleID)")
            return Outcome(result: .failed(status: "Unable to open URL"), capturedWindow: nil)
        }

        dependencies.log("[LAUNCHER_ACTION] openURL provider=system-default url=\(url.absoluteString)")
        return launchURLFallbackAndCapture(url: url, request: request)
    }

    func launchSearchAndCaptureSync(
        query: String,
        provider: ResolvedBrowserProvider?,
        searchEngine: SearchEngine,
        customSearchTemplate: String,
        request: CaptureRequest
    ) -> Outcome {
        if let provider {
            dependencies.log("[LAUNCHER_ACTION] webSearch provider=\(provider.selection.bundleID) query=\(query)")

            let initialPID = dependencies.runningPIDForBundle(provider.selection.bundleID)
            let baseline = baselineWindowIDs(forPID: initialPID)
            dependencies.log("[CAPTURE_WAIT] baseline search provider=\(provider.selection.bundleID) pid=\(String(describing: initialPID)) count=\(baseline.count)")

            let launched = dependencies.launchSearchAction?(query, provider, searchEngine, customSearchTemplate)
                ?? defaultLaunchSearch(
                    query: query,
                    provider: provider,
                    searchEngine: searchEngine,
                    customSearchTemplate: customSearchTemplate
                )
            dependencies.log("[URL_LAUNCH] search dispatch provider=\(provider.selection.bundleID) success=\(launched)")
            if launched {
                let capture = waitForCapturedWindow(
                    baseline: baseline,
                    pidResolver: { self.dependencies.runningPIDForBundle(provider.selection.bundleID) },
                    request: request
                )
                if let capture {
                    dependencies.log("[CAPTURE_RESULT] success provider=\(provider.selection.bundleID) window=\(capture.id)")
                    return Outcome(result: .succeeded, capturedWindow: capture)
                }
                dependencies.activateApp(provider.selection.bundleID)
                dependencies.log("[CAPTURE_RESULT] timeout provider=\(provider.selection.bundleID)")
                return Outcome(result: .timedOut(status: "No new window detected"), capturedWindow: nil)
            }

            dependencies.activateApp(provider.selection.bundleID)
            dependencies.log("[CAPTURE_RESULT] failed provider=\(provider.selection.bundleID)")
            return Outcome(result: .failed(status: "Unable to open search"), capturedWindow: nil)
        }

        dependencies.log("[LAUNCHER_ACTION] webSearch provider=system-default query=\(query)")
        return launchSearchFallbackAndCapture(
            query: query,
            searchEngine: searchEngine,
            customSearchTemplate: customSearchTemplate,
            request: request
        )
    }

    // MARK: - Internals

    private func baselineWindowIDs(forPID pid: pid_t?) -> Set<CGWindowID> {
        let windows = dependencies.listWindows()
        if let pid {
            return Set(windows.filter { $0.ownerPID == pid }.map(\.id))
        }
        return Set(windows.map(\.id))
    }

    private func waitForCapturedWindow(
        baseline: Set<CGWindowID>,
        pidResolver: () -> pid_t?,
        request: CaptureRequest
    ) -> WindowInfo? {
        let deadline = Date().addingTimeInterval(timing.timeout)

        while Date() < deadline {
            let candidatePID = pidResolver()
            let windows = dependencies.listWindows()

            for window in windows {
                if baseline.contains(window.id) { continue }
                if let candidatePID, window.ownerPID != candidatePID { continue }
                if dependencies.isWindowGrouped(window.id) { continue }
                if !passesSpaceGate(windowID: window.id, request: request) { continue }
                return window
            }

            dependencies.sleep(timing.pollInterval)
        }

        return nil
    }

    private func passesSpaceGate(windowID: CGWindowID, request: CaptureRequest) -> Bool {
        let windowSpace = dependencies.spaceIDForWindow(windowID) ?? 0

        switch request.mode {
        case .newGroup:
            guard let currentSpace = request.currentSpaceID else { return true }
            let accepted = windowSpace == currentSpace
            if !accepted {
                dependencies.log("[CAPTURE_WAIT] reject space new-group window=\(windowID) windowSpace=\(windowSpace) current=\(currentSpace)")
            }
            return accepted

        case .addToGroup(_, let targetSpaceID):
            if targetSpaceID == 0 { return true }
            let accepted = windowSpace == targetSpaceID
            if !accepted {
                dependencies.log("[CAPTURE_WAIT] reject space add-to-group window=\(windowID) windowSpace=\(windowSpace) target=\(targetSpaceID)")
            }
            return accepted
        }
    }

    private enum NewWindowKeystroke {
        case commandN
        case commandShiftN

        var key: String { "n" }

        var automationLabel: String {
            switch self {
            case .commandN:
                return "cmd+n"
            case .commandShiftN:
                return "cmd+shift+n"
            }
        }

        var modifiersClause: String {
            switch self {
            case .commandN:
                return "command down"
            case .commandShiftN:
                return "{command down, shift down}"
            }
        }
    }

    /// Confirmed app-specific args that are expected to request a new window for an already-running app.
    static let knownNewWindowArgs: [String: [String]] = [
        // VSCode / Code OSS family
        "com.microsoft.VSCode": ["--new-window"],
        "com.microsoft.VSCodeInsiders": ["--new-window"],
        "com.vscodium": ["--new-window"],
        "com.visualstudio.code.oss": ["--new-window"],

        // Browsers - Chromium-based
        "org.chromium.Chromium": ["--new-window"],
        "com.google.Chrome": ["--new-window"],
        "com.google.Chrome.canary": ["--new-window"],
        "com.google.Chrome.dev": ["--new-window"],
        "com.google.Chrome.beta": ["--new-window"],
        "com.microsoft.edgemac": ["--new-window"],
        "com.brave.Browser": ["--new-window"],
        "com.operasoftware.Opera": ["--new-window"],
        "com.vivaldi.Vivaldi": ["--new-window"],

        // Browsers - Firefox-based
        "org.mozilla.firefox": ["--new-window"],
        "org.mozilla.firefoxdeveloperedition": ["--new-window"],
        "org.mozilla.nightly": ["--new-window"],
        "org.mozilla.floorp": ["--new-window"],
        "org.torproject.torbrowser": ["--new-window"],
        "net.mullvad.mullvadbrowser": ["--new-window"],

        // Terminals
        "com.mitchellh.ghostty": ["+new-window"],
        "net.kovidgoyal.kitty": ["--single-instance"],
    ]

    /// Additional args that we still route through the fallback chain.
    /// Per product policy, CLI/arg-based strategies are treated as confirmed support.
    static let bestEffortNewWindowArgs: [String: [String]] = [
        // VSCode-derived editors where `--new-window` is likely but not fully validated.
        "com.todesktop.230313mzl4w4u92": ["--new-window"], // Cursor
        "com.exafunction.windsurf": ["--new-window"], // Windsurf
        "co.posit.positron": ["--new-window"],
        "com.trae.app": ["--new-window"],
        "com.voideditor.code": ["--new-window"],
        "ai.codestory.AideInsiders": ["--new-window"],
        "sh.melty.code": ["--new-window"],
        "com.google.antigravity": ["--new-window"],

        // Common desktop editors with probable support.
        "com.sublimetext.4": ["--new-window"],
        "com.sublimetext.3": ["--new-window"],
        "com.sublimetext.2": ["--new-window"],
        "com.github.atom": ["--new-window"],
        "com.barebones.bbedit": ["--new-window"],
        "dev.zed.Zed": ["-n"],

        // Additional Chromium-family browsers.
        "com.operasoftware.OperaGX": ["--new-window"],
        "com.operasoftware.OperaAir": ["--new-window"],
        "company.thebrowser.Browser": ["--new-window"], // Arc
        "company.thebrowser.dia": ["--new-window"], // Dia
        "com.pushplaylabs.sidekick": ["--new-window"],
        "com.sigmaos.sigmaos.macos": ["--new-window"],

        // Additional Firefox-family browsers.
        "app.zen-browser.zen": ["--new-window"],
        "org.mozilla.librewolf": ["--new-window"],
        "net.waterfox.waterfox": ["--new-window"],
    ]

    /// Confirmed keyboard shortcuts for creating new windows in running apps.
    /// Multiple entries are attempted in order.
    /// Used for both behavior and UI confidence.
    private static let knownNewWindowKeystrokes: [String: [NewWindowKeystroke]] = [
        // Terminals
        "com.googlecode.iterm2": [.commandN],
        "com.apple.Terminal": [.commandN],
        "dev.warp.Warp-Stable": [.commandN],
        "dev.warp.Warp": [.commandN],
        "dev.warp.WarpPreview": [.commandN],

        // Browsers
        "org.chromium.Chromium": [.commandN],
        "com.google.Chrome": [.commandN],
        "com.google.Chrome.canary": [.commandN],
        "com.google.Chrome.dev": [.commandN],
        "com.google.Chrome.beta": [.commandN],
        "com.microsoft.edgemac": [.commandN],
        "com.brave.Browser": [.commandN],
        "com.operasoftware.Opera": [.commandN],
        "com.vivaldi.Vivaldi": [.commandN],
        "org.mozilla.firefox": [.commandN],
        "org.mozilla.firefoxdeveloperedition": [.commandN],
        "org.mozilla.nightly": [.commandN],
        "org.mozilla.floorp": [.commandN],
        "org.torproject.torbrowser": [.commandN],
        "net.mullvad.mullvadbrowser": [.commandN],
        "com.apple.Safari": [.commandN],
        "com.apple.SafariTechnologyPreview": [.commandN],

        // VSCode family
        "com.microsoft.VSCode": [.commandShiftN],
        "com.microsoft.VSCodeInsiders": [.commandShiftN],
        "com.vscodium": [.commandShiftN],
        "com.visualstudio.code.oss": [.commandShiftN],
    ]

    /// Best-effort shortcuts scoped to specific apps. Not counted as guaranteed support.
    private static let bestEffortNewWindowKeystrokes: [String: NewWindowKeystroke] = [
        // Terminals
        "com.github.wez.wezterm": .commandN,
        "com.github.wez.wezterm-nightly": .commandN,
        "org.wezfurlong.wezterm": .commandN,
        "org.tabby": .commandN,
        "org.alacritty": .commandN,
        "org.alacritty.Alacritty": .commandN,
        "com.raphaelamorim.rio": .commandN,
        "org.contourterminal.contour": .commandN,
        "dev.waveterm.waveterm": .commandN,
        "com.termius.mac": .commandN,
        "co.zeit.hyper": .commandN,

        // Browsers
        "com.operasoftware.OperaGX": .commandN,
        "com.operasoftware.OperaAir": .commandN,
        "company.thebrowser.Browser": .commandN, // Arc
        "app.zen-browser.zen": .commandN,
        "org.mozilla.librewolf": .commandN,
        "net.waterfox.waterfox": .commandN,

        // VSCode family
        "com.todesktop.230313mzl4w4u92": .commandShiftN, // Cursor
        "com.exafunction.windsurf": .commandShiftN, // Windsurf
        "co.posit.positron": .commandShiftN,
        "com.trae.app": .commandShiftN,
    ]

    static func hasNativeNewWindowSupport(bundleID: String) -> Bool {
        if knownNewWindowArgs[bundleID] != nil { return true }
        if bestEffortNewWindowArgs[bundleID] != nil { return true }
        if appSpecificNewWindowAppleScript(bundleID: bundleID) != nil { return true }
        if knownNewWindowKeystrokes[bundleID] != nil { return true }
        if BrowserProviderResolver.knownChromiumBundleIDs.contains(bundleID) { return true }
        if BrowserProviderResolver.knownFirefoxBundleIDs.contains(bundleID) { return true }
        return false
    }

    static func knownNewWindowShortcutAutomation() -> [String: [String]] {
        knownNewWindowKeystrokes.mapValues { shortcuts in
            shortcuts.map(\.automationLabel)
        }
    }

    private func defaultAttemptProviderNewWindow(bundleID: String, appURL: URL? = nil) -> Bool {
        if let engine = resolver.engine(for: bundleID),
           let appURL = appURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let provider = ResolvedBrowserProvider(
                selection: BrowserProviderSelection(bundleID: bundleID, engine: engine),
                appURL: appURL
            )
            switch engine {
            case .chromium:
                return chromiumLauncher.openNewWindow(provider: provider)
            case .firefox:
                return firefoxLauncher.openNewWindow(provider: provider)
            case .safari:
                return safariLauncher.openNewWindow(provider: provider)
            }
        }

        if let args = Self.knownNewWindowArgs[bundleID] {
            return Self.launchNewWindowWithArgs(bundleID: bundleID, args: args)
        }

        return false
    }

    private static func launchNewWindowWithArgs(bundleID: String, args: [String]) -> Bool {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
           let bundle = Bundle(url: appURL),
           let executableURL = bundle.executableURL {
            let process = Process()
            process.executableURL = executableURL
            process.arguments = args
            do {
                try process.run()
                let deadline = Date().addingTimeInterval(0.8)
                while process.isRunning, Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.02)
                }
                if process.isRunning || process.terminationStatus == 0 {
                    Logger.log("[APP_LAUNCH] new-window via executable bundle=\(bundleID) args=\(args)")
                    return true
                }
            } catch {
                Logger.log("[APP_LAUNCH] executable launch failed bundle=\(bundleID): \(error.localizedDescription)")
            }
        }

        return runOpenCommand(bundleID: bundleID, args: args)
    }

    static func appSpecificNewWindowAppleScript(bundleID: String) -> String? {
        let escapedID = bundleID.replacingOccurrences(of: "\"", with: "\\\"")
        switch bundleID {
        case "com.googlecode.iterm2", "com.googlecode.iterm2-beta":
            return """
            tell application id "\(escapedID)"
                create window with default profile
            end tell
            """
        default:
            return nil
        }
    }

    private static func sendAppSpecificNewWindowAppleEvent(bundleID: String) -> Bool {
        guard let source = appSpecificNewWindowAppleScript(bundleID: bundleID) else {
            return false
        }
        var error: NSDictionary?
        let script = NSAppleScript(source: source)
        _ = script?.executeAndReturnError(&error)
        if let error {
            Logger.log("[APP_LAUNCH] app-specific new-window script failed bundle=\(bundleID): \(error)")
            return false
        }
        Logger.log("[APP_LAUNCH] app-specific new-window script succeeded bundle=\(bundleID)")
        return true
    }

    private func defaultLaunchURL(url: URL, provider: ResolvedBrowserProvider) -> Bool {
        switch provider.selection.engine {
        case .chromium:
            return chromiumLauncher.openURL(url, provider: provider)
        case .firefox:
            return firefoxLauncher.openURL(url, provider: provider)
        case .safari:
            return safariLauncher.openURL(url, provider: provider)
        }
    }

    private func defaultLaunchSearch(
        query: String,
        provider: ResolvedBrowserProvider,
        searchEngine: SearchEngine,
        customSearchTemplate: String
    ) -> Bool {
        switch provider.selection.engine {
        case .chromium:
            return chromiumLauncher.openSearch(
                query: query,
                provider: provider,
                searchEngine: searchEngine,
                customSearchTemplate: customSearchTemplate
            )
        case .firefox:
            return firefoxLauncher.openSearch(
                query: query,
                provider: provider,
                searchEngine: searchEngine,
                customSearchTemplate: customSearchTemplate
            )
        case .safari:
            return safariLauncher.openSearch(
                query: query,
                provider: provider,
                searchEngine: searchEngine,
                customSearchTemplate: customSearchTemplate
            )
        }
    }

    private func launchURLFallbackAndCapture(url: URL, request: CaptureRequest) -> Outcome {
        let baseline = baselineWindowIDs(forPID: nil)
        dependencies.log("[CAPTURE_WAIT] fallback URL baseline count=\(baseline.count)")
        let launched = dependencies.launchURLFallback(url)
        dependencies.log("[URL_LAUNCH] fallback URL dispatch success=\(launched)")
        guard launched else {
            return Outcome(result: .failed(status: "Unable to open URL"), capturedWindow: nil)
        }

        let capture = waitForCapturedWindow(
            baseline: baseline,
            pidResolver: { nil },
            request: request
        )
        if let capture {
            dependencies.log("[CAPTURE_RESULT] fallback URL success window=\(capture.id)")
            return Outcome(result: .succeeded, capturedWindow: capture)
        }
        dependencies.log("[CAPTURE_RESULT] fallback URL timeout")
        return Outcome(result: .timedOut(status: "No new window detected"), capturedWindow: nil)
    }

    private func launchSearchFallbackAndCapture(
        query: String,
        searchEngine: SearchEngine,
        customSearchTemplate: String,
        request: CaptureRequest
    ) -> Outcome {
        let baseline = baselineWindowIDs(forPID: nil)
        dependencies.log("[CAPTURE_WAIT] fallback search baseline count=\(baseline.count)")
        let launched = dependencies.launchSearchFallback(query, searchEngine, customSearchTemplate)
        dependencies.log("[URL_LAUNCH] fallback search dispatch success=\(launched)")
        guard launched else {
            return Outcome(result: .failed(status: "Unable to open search"), capturedWindow: nil)
        }

        let capture = waitForCapturedWindow(
            baseline: baseline,
            pidResolver: { nil },
            request: request
        )
        if let capture {
            dependencies.log("[CAPTURE_RESULT] fallback search success window=\(capture.id)")
            return Outcome(result: .succeeded, capturedWindow: capture)
        }
        dependencies.log("[CAPTURE_RESULT] fallback search timeout")
        return Outcome(result: .timedOut(status: "No new window detected"), capturedWindow: nil)
    }

    @discardableResult
    private static func runOpenCommand(bundleID: String, args: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-b", bundleID] + (args.isEmpty ? [] : ["--args"] + args)

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            Logger.log("[APP_LAUNCH] open command failed bundle=\(bundleID): \(error.localizedDescription)")
            return false
        }
    }

    private static func sendKnownNewWindowKeystrokes(bundleID: String) -> Bool {
        guard let keystrokes = knownNewWindowKeystrokes[bundleID] else { return false }
        return sendNewWindowKeystrokes(bundleID: bundleID, strategies: keystrokes)
    }

    private static func sendBestEffortNewWindowKeystrokes(bundleID: String) -> Bool {
        guard let keystroke = bestEffortNewWindowKeystrokes[bundleID] else { return false }
        return sendNewWindowKeystrokes(bundleID: bundleID, strategies: [keystroke])
    }

    private static func attemptSpeculativeNewWindowArgs(bundleID: String) {
        // Non-destructive best-effort args for apps without confirmed support.
        runOpenCommand(bundleID: bundleID, args: ["--new-window"])
        runOpenCommand(bundleID: bundleID, args: ["--new"])
        runOpenCommand(bundleID: bundleID, args: ["-n"])
    }

    private static func sendNewWindowKeystrokes(bundleID: String, strategies: [NewWindowKeystroke]) -> Bool {
        guard !strategies.isEmpty else { return false }

        var dispatched = false

        for strategy in strategies {
            dispatched = sendNewWindowKeystroke(bundleID: bundleID, strategy: strategy) || dispatched
        }

        return dispatched
    }

    private static func sendNewWindowKeystroke(bundleID: String, strategy: NewWindowKeystroke) -> Bool {
        let escapedID = bundleID.replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        tell application id "\(escapedID)"
            activate
        end tell
        delay 0.3
        tell application "System Events"
            keystroke "\(strategy.key)" using \(strategy.modifiersClause)
        end tell
        """
        var error: NSDictionary?
        let script = NSAppleScript(source: source)
        _ = script?.executeAndReturnError(&error)
        if let error {
            Logger.log("[APP_LAUNCH] new-window keystroke failed bundle=\(bundleID) shortcut=\(strategy.automationLabel): \(error)")
            return false
        }
        Logger.log("[APP_LAUNCH] new-window keystroke sent bundle=\(bundleID) shortcut=\(strategy.automationLabel)")
        return true
    }

    private static func sendReopenAppleEvent(bundleID: String) -> Bool {
        let source = """
        tell application id "\(bundleID)"
            try
                reopen
                return true
            on error
                return false
            end try
        end tell
        """
        var error: NSDictionary?
        let script = NSAppleScript(source: source)
        let result = script?.executeAndReturnError(&error)
        if let error {
            Logger.log("[APP_LAUNCH] reopen AppleScript error bundle=\(bundleID): \(error)")
            return false
        }
        return result?.booleanValue == true
    }
}
