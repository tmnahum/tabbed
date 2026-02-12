import AppKit

struct ResolvedBrowserProvider {
    let selection: BrowserProviderSelection
    let appURL: URL
}

final class BrowserProviderResolver {
    static let heliumBundleID = "net.imput.helium"

    // Keep these ordered by preference.
    static let knownChromiumBundleIDs: [String] = [
        heliumBundleID,
        "company.thebrowser.Browser", // Arc
        "company.thebrowser.dia", // Dia
        "org.chromium.Chromium",
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "com.operasoftware.Opera",
        "com.operasoftware.OperaGX",
        "com.operasoftware.OperaAir",
        "com.vivaldi.Vivaldi",
        "com.pushplaylabs.sidekick"
    ]

    static let knownFirefoxBundleIDs: [String] = [
        "org.mozilla.firefox",
        "org.mozilla.firefoxdeveloperedition",
        "org.mozilla.nightly",
        "app.zen-browser.zen",
        "org.mozilla.floorp",
        "net.waterfox.waterfox",
        "org.mozilla.librewolf",
        "org.torproject.torbrowser",
        "net.mullvad.mullvadbrowser"
    ]

    static let knownSafariBundleIDs: [String] = [
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview"
    ]

    typealias AppURLLookup = (String) -> URL?

    private let appURLLookup: AppURLLookup

    init(appURLLookup: @escaping AppURLLookup = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }) {
        self.appURLLookup = appURLLookup
    }

    func resolve(config: AddWindowLauncherConfig) -> ResolvedBrowserProvider? {
        guard config.hasAnyLaunchActionEnabled else { return nil }

        switch config.providerMode {
        case .manual:
            let bundleID = config.manualSelection.bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !bundleID.isEmpty,
                  let appURL = appURLLookup(bundleID) else { return nil }
            return ResolvedBrowserProvider(
                selection: BrowserProviderSelection(bundleID: bundleID, engine: config.manualSelection.engine),
                appURL: appURL
            )
        case .auto:
            if let appURL = appURLLookup(Self.heliumBundleID) {
                return ResolvedBrowserProvider(
                    selection: BrowserProviderSelection(bundleID: Self.heliumBundleID, engine: .chromium),
                    appURL: appURL
                )
            }

            for bundleID in Self.knownChromiumBundleIDs where bundleID != Self.heliumBundleID {
                if let appURL = appURLLookup(bundleID) {
                    return ResolvedBrowserProvider(
                        selection: BrowserProviderSelection(bundleID: bundleID, engine: .chromium),
                        appURL: appURL
                    )
                }
            }

            for bundleID in Self.knownFirefoxBundleIDs {
                if let appURL = appURLLookup(bundleID) {
                    return ResolvedBrowserProvider(
                        selection: BrowserProviderSelection(bundleID: bundleID, engine: .firefox),
                        appURL: appURL
                    )
                }
            }

            for bundleID in Self.knownSafariBundleIDs {
                if let appURL = appURLLookup(bundleID) {
                    return ResolvedBrowserProvider(
                        selection: BrowserProviderSelection(bundleID: bundleID, engine: .safari),
                        appURL: appURL
                    )
                }
            }

            return nil
        }
    }

    func engine(for bundleID: String) -> BrowserEngine? {
        if Self.knownChromiumBundleIDs.contains(bundleID) {
            return .chromium
        }
        if Self.knownFirefoxBundleIDs.contains(bundleID) {
            return .firefox
        }
        if Self.knownSafariBundleIDs.contains(bundleID) {
            return .safari
        }
        return nil
    }

    func manualSelection(forBundleID bundleID: String, fallbackEngine: BrowserEngine = .chromium) -> BrowserProviderSelection {
        let trimmedBundleID = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        return BrowserProviderSelection(
            bundleID: trimmedBundleID,
            engine: engine(for: trimmedBundleID) ?? fallbackEngine
        )
    }
}

protocol BrowserLauncher {
    var engine: BrowserEngine { get }
    func openNewWindow(provider: ResolvedBrowserProvider) -> Bool
    func openURL(_ url: URL, provider: ResolvedBrowserProvider) -> Bool
    func openSearch(
        query: String,
        provider: ResolvedBrowserProvider,
        searchEngine: SearchEngine,
        customSearchTemplate: String
    ) -> Bool
}

final class ChromiumBrowserLauncher: BrowserLauncher {
    let engine: BrowserEngine = .chromium

    func openNewWindow(provider: ResolvedBrowserProvider) -> Bool {
        let script = """
        tell application id "\(provider.selection.bundleID)"
            activate
            try
                make new window
                return true
            on error
                return false
            end try
        end tell
        """
        if runAppleScript(script) { return true }
        if runExecutable(appURL: provider.appURL, args: ["--new-window", "about:blank"]) {
            return true
        }
        return runOpenWithArgs(bundleID: provider.selection.bundleID, args: ["--new-window", "about:blank"])
    }

    func openURL(_ url: URL, provider: ResolvedBrowserProvider) -> Bool {
        let escapedURL = url.absoluteString.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application id "\(provider.selection.bundleID)"
            activate
            try
                set newWindow to make new window
                set URL of active tab of newWindow to "\(escapedURL)"
                return true
            on error
                return false
            end try
        end tell
        """
        if runAppleScript(script) { return true }
        if runExecutable(appURL: provider.appURL, args: ["--new-window", url.absoluteString]) {
            return true
        }
        if runOpenWithArgs(bundleID: provider.selection.bundleID, args: ["--new-window", url.absoluteString]) {
            return true
        }
        return runOpenURL(bundleID: provider.selection.bundleID, url: url)
    }

    func openSearch(
        query: String,
        provider: ResolvedBrowserProvider,
        searchEngine: SearchEngine,
        customSearchTemplate: String
    ) -> Bool {
        guard let url = searchEngine.searchURL(for: query, customTemplate: customSearchTemplate) else { return false }
        return openURL(url, provider: provider)
    }
}

final class FirefoxBrowserLauncher: BrowserLauncher {
    let engine: BrowserEngine = .firefox
    static let newWindowFlag = "--new-window"

    static func newWindowArgs(url: URL?) -> [String] {
        if let url {
            return [newWindowFlag, url.absoluteString]
        }
        return [newWindowFlag, "about:blank"]
    }

    func openNewWindow(provider: ResolvedBrowserProvider) -> Bool {
        runFirefox(provider: provider, args: Self.newWindowArgs(url: nil))
    }

    func openURL(_ url: URL, provider: ResolvedBrowserProvider) -> Bool {
        runFirefox(provider: provider, args: Self.newWindowArgs(url: url))
    }

    func openSearch(
        query: String,
        provider: ResolvedBrowserProvider,
        searchEngine: SearchEngine,
        customSearchTemplate: String
    ) -> Bool {
        guard let url = searchEngine.searchURL(for: query, customTemplate: customSearchTemplate) else { return false }
        return openURL(url, provider: provider)
    }

    private func runFirefox(provider: ResolvedBrowserProvider, args: [String]) -> Bool {
        if runExecutable(appURL: provider.appURL, args: args) {
            return true
        }
        return runOpenWithArgs(bundleID: provider.selection.bundleID, args: args)
    }
}

final class SafariBrowserLauncher: BrowserLauncher {
    let engine: BrowserEngine = .safari

    func openNewWindow(provider: ResolvedBrowserProvider) -> Bool {
        let script = """
        tell application id "\(provider.selection.bundleID)"
            activate
            try
                make new document
                return true
            on error
                return false
            end try
        end tell
        """
        if runAppleScript(script) { return true }
        return runOpenWithArgs(bundleID: provider.selection.bundleID, args: [])
    }

    func openURL(_ url: URL, provider: ResolvedBrowserProvider) -> Bool {
        let escapedURL = url.absoluteString.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application id "\(provider.selection.bundleID)"
            activate
            try
                make new document with properties {URL:"\(escapedURL)"}
                return true
            on error
                try
                    open location "\(escapedURL)"
                    return true
                on error
                    return false
                end try
            end try
        end tell
        """
        if runAppleScript(script) { return true }
        return runOpenURL(bundleID: provider.selection.bundleID, url: url)
    }

    func openSearch(
        query: String,
        provider: ResolvedBrowserProvider,
        searchEngine: SearchEngine,
        customSearchTemplate: String
    ) -> Bool {
        guard let url = searchEngine.searchURL(for: query, customTemplate: customSearchTemplate) else { return false }
        return openURL(url, provider: provider)
    }
}

@discardableResult
private func runOpenWithArgs(bundleID: String, args: [String]) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-b", bundleID] + (args.isEmpty ? [] : ["--args"] + args)

    return runProcess(process, logPrefix: "[URL_LAUNCH] open command failed bundle=\(bundleID)")
}

@discardableResult
private func runOpenURL(bundleID: String, url: URL) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-b", bundleID, url.absoluteString]

    return runProcess(process, logPrefix: "[URL_LAUNCH] open URL failed bundle=\(bundleID)")
}

@discardableResult
private func runExecutable(appURL: URL, args: [String]) -> Bool {
    guard let bundle = Bundle(url: appURL),
          let executableURL = bundle.executableURL else {
        return false
    }

    let process = Process()
    process.executableURL = executableURL
    process.arguments = args

    return runProcess(process, logPrefix: "[URL_LAUNCH] executable launch failed app=\(appURL.lastPathComponent)")
}

@discardableResult
private func runProcess(_ process: Process, logPrefix: String) -> Bool {
    do {
        try process.run()
        let deadline = Date().addingTimeInterval(0.8)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            return true
        }
        return process.terminationStatus == 0
    } catch {
        Logger.log("\(logPrefix): \(error.localizedDescription)")
        return false
    }
}

private func runAppleScript(_ source: String) -> Bool {
    var error: NSDictionary?
    let script = NSAppleScript(source: source)
    let result = script?.executeAndReturnError(&error)
    if let error {
        Logger.log("[URL_LAUNCH] AppleScript error: \(error)")
        return false
    }
    guard let result else {
        return false
    }
    return result.booleanValue
}
