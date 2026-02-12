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
            // Speculatively try --new-window for all apps (most ignore unknown flags harmlessly).
            // Fire-and-forget: don't short-circuit so Cmd+N still fires as a backup.
            LaunchOrchestrator.runOpenCommand(bundleID: bundleID, args: ["--new-window"])
            if LaunchOrchestrator.sendNewWindowKeystrokes(bundleID: bundleID) {
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

    static let knownNewWindowArgs: [String: [String]] = [
        // VSCode family and derivatives (Electron / Code OSS)
        "com.microsoft.VSCode": ["--new-window"],
        "com.microsoft.VSCodeInsiders": ["--new-window"],
        "com.todesktop.230313mzl4w4u92": ["--new-window"], // Cursor (VSCode fork)
        "com.exafunction.windsurf": ["--new-window"], // Windsurf (VSCode fork)
        "com.vscodium": ["--new-window"],
        "co.posit.positron": ["--new-window"], // Positron
        "com.trae.app": ["--new-window"], // Trae (ByteDance, VSCode-based)
        "com.visualstudio.code.oss": ["--new-window"], // Code OSS / forks
        "com.voideditor.code": ["--new-window"], // Void
        "ai.codestory.AideInsiders": ["--new-window"], // Aide
        "sh.melty.code": ["--new-window"], // Melty
        "com.google.antigravity": ["--new-window"], // Antigravity / Project IDX

        // Other Electron-based editors with documented new-window flags
        "dev.zed.Zed": ["--new"], // Zed: `zed --new`
        "com.sublimetext.4": ["--new-window"],
        "com.sublimetext.3": ["--new-window"],
        "com.sublimetext.2": ["--new-window"], // Assuming Sublime Text 2 also uses this
        "com.github.atom": ["--new-window"],
        "com.barebones.bbedit": ["--new-window"], // BBEdit: `bbedit --new-window`

        // Browsers - Chromium-based (use --new-window)
        "com.google.Chrome": ["--new-window"],
        "com.google.Chrome.canary": ["--new-window"],
        "com.google.Chrome.dev": ["--new-window"],
        "com.google.Chrome.beta": ["--new-window"],
        "com.microsoft.edgemac": ["--new-window"],
        "com.brave.Browser": ["--new-window"],
        "com.operasoftware.Opera": ["--new-window"],
        "com.vivaldi.Vivaldi": ["--new-window"],

        // Browsers - Firefox-based (use -new-window)
        "org.mozilla.firefox": ["-new-window"],
        "org.mozilla.firefoxdeveloperedition": ["-new-window"],
        "org.mozilla.nightly": ["-new-window"],
        "org.mozilla.thunderbird": ["-new-window"], // Thunderbird also uses -new-window

        // Terminals with explicit new-window or single-instance flags
        "net.kovidgoyal.kitty": ["--single-instance"],
    ]



    /// Apps known to reliably create new windows via Cmd+N (no special CLI arg needed).
    /// Used only for UI display (full opacity) — the reopen chain handles the actual launch.
    static let knownCmdNNewWindowApps: Set<String> = [
        // Terminals
        "com.googlecode.iterm2",
        "com.apple.Terminal",
        "dev.warp.Warp-Stable",
        "com.github.wez.wezterm",
        "com.mitchellh.ghostty",
        "org.tabby",
        "net.kovidgoyal.kitty",
        "org.alacritty",
        "co.zeit.hyper",

        // Editors and IDEs with standard document-style Cmd+N behavior
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.vscodium",
        "com.sublimetext.4",
        "com.sublimetext.3",
        "com.sublimetext.2",
        "dev.zed.Zed",
        "com.github.atom",
        "com.barebones.bbedit",
        "com.macromates.TextMate",
        "com.panic.Nova",
        "com.coteditor.CotEditor",

        // JetBrains IDEs often support Cmd+N for new projects/files
        "com.jetbrains.intellij",
        "com.jetbrains.intellij.ce",
        "com.jetbrains.WebStorm",
        "com.jetbrains.pycharm",
        "com.jetbrains.pycharm.ce",
        "com.jetbrains.CLion",
        "com.jetbrains.GoLand",
        "com.jetbrains.RubyMine",
        "com.jetbrains.PhpStorm",
        "com.jetbrains.DataGrip",
        "com.jetbrains.AppCode",
        "com.jetbrains.Rider",
        "com.jetbrains.Fleet",
        "com.jetbrains.dataspell",
        "com.google.android.studio",
        "com.jetbrains.AppCode-EAP",
        "com.jetbrains.intellij-EAP",
        "com.jetbrains.WebStorm-EAP",
        "com.jetbrains.pycharm-EAP",
        "com.jetbrains.CLion-EAP",
        "com.jetbrains.DataGrip-EAP",
        "com.jetbrains.GoLand-EAP",
        "com.jetbrains.PhpStorm-EAP",
        "com.jetbrains.Rider-EAP",
        "com.jetbrains.RubyMine-EAP",
        "com.jetbrains.dataspell-EAP",

        // Apple apps with document-based new windows
        "com.apple.TextEdit",
        "com.apple.Preview",
        "com.apple.Notes",
        "com.apple.iWork.Pages",
        "com.apple.iWork.Numbers",
        "com.apple.iWork.Keynote",
        "com.apple.dt.Xcode",

        // Browsers (Cmd+N typically opens a new window, not just a tab)
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.google.Chrome.dev",
        "com.google.Chrome.beta",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi",
        "org.mozilla.firefox",
        "org.mozilla.firefoxdeveloperedition",
        "org.mozilla.nightly",
        "com.apple.Safari",
        "company.thebrowser.Browser",
        "org.mozilla.thunderbird",

        // Some productivity apps that have clear "new document/window" Cmd+N
        "md.obsidian",
        "com.tinyspeck.slackmacgap",
        "com.hnc.Discord",
        "com.microsoft.teams",
        "us.zoom.xos",
        "notion.id",

        // Design Tools (often have Cmd+N for new document)
        "com.figma.Desktop",
        "com.sketchapp",
        "com.pixelmator.pro",
        "com.bohemiancoding.sketch3",
        "com.adobe.illustrator",
        "com.adobe.photoshop",
        "com.adobe.xd",
        "com.adobe.lightroom",
        "com.adobe.PremierePro",
        "com.adobe.AfterEffects",
        "com.adobe.Audition",
        "com.adobe.InDesign",
        "com.adobe.dreamweaver",
        "com.adobe.bridge",
        "com.adobe.acrobat",
        "com.adobe.Reader",
        "com.pixelmatorteam.pixelmator",
    ]

    static func hasNativeNewWindowSupport(bundleID: String) -> Bool {
        if knownNewWindowArgs[bundleID] != nil { return true }
        if knownCmdNNewWindowApps.contains(bundleID) { return true }
        if BrowserProviderResolver.knownChromiumBundleIDs.contains(bundleID) { return true }
        if BrowserProviderResolver.knownFirefoxBundleIDs.contains(bundleID) { return true }
        if BrowserProviderResolver.knownSafariBundleIDs.contains(bundleID) { return true }
        return false
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
        case "com.googlecode.iterm2":
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

    private static func sendNewWindowKeystrokes(bundleID: String) -> Bool {
        let escapedID = bundleID.replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        tell application id "\(escapedID)"
            activate
        end tell
        delay 0.3
        tell application "System Events"
            keystroke "n" using command down
        end tell
        """
        var error: NSDictionary?
        let script = NSAppleScript(source: source)
        _ = script?.executeAndReturnError(&error)
        if let error {
            Logger.log("[APP_LAUNCH] new-window keystroke failed bundle=\(bundleID): \(error)")
            return false
        }
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
