import AppKit
import ApplicationServices

/// Pure window detection and list building. Two entry points:
/// - `currentSpace()` — on-screen windows on the active Space, z-ordered
/// - `allSpaces()` — windows across every Space, z-ordered
enum WindowDiscovery {

    private static let ownPID = ProcessInfo.processInfo.processIdentifier

    // MARK: - Entry Points

    /// Returns on-screen windows on the current Space, ordered by z-index (front-most first).
    /// CG-first: walks the CoreGraphics window list and matches each to its AX element.
    static func currentSpace() -> [WindowInfo] {
        let cgWindows = AccessibilityHelper.getWindowList()
        var results: [WindowInfo] = []

        // Cache app metadata + AX elements per PID
        struct AppCache {
            let app: NSRunningApplication?
            let axWindows: [CGWindowID: AXUIElement]
        }
        var cacheByPID: [pid_t: AppCache] = [:]

        for info in cgWindows {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  pid != ownPID else { continue }

            if cacheByPID[pid] == nil {
                let app = NSRunningApplication(processIdentifier: pid)
                guard app?.activationPolicy == .regular else {
                    cacheByPID[pid] = AppCache(app: nil, axWindows: [:])
                    continue
                }
                let axWindows = AccessibilityHelper.windowElements(for: pid)
                var map: [CGWindowID: AXUIElement] = [:]
                for ax in axWindows {
                    if let wid = AccessibilityHelper.windowID(for: ax) {
                        map[wid] = ax
                    }
                }
                cacheByPID[pid] = AppCache(app: app, axWindows: map)
            }
        }

        // Walk CG windows in z-order and filter through WindowDiscriminator
        for info in cgWindows {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  pid != ownPID,
                  let windowID = info[kCGWindowNumber as String] as? CGWindowID,
                  let cache = cacheByPID[pid],
                  let app = cache.app,
                  let axElement = cache.axWindows[windowID] else { continue }

            let subrole = AccessibilityHelper.getSubrole(of: axElement)
            let role = AccessibilityHelper.getRole(of: axElement)
            let title = AccessibilityHelper.getTitle(of: axElement)
            let size = AccessibilityHelper.getSize(of: axElement)

            guard WindowDiscriminator.isActualWindow(
                cgWindowID: windowID,
                subrole: subrole,
                role: role,
                title: title,
                size: size,
                level: 0, // CG getWindowList pre-filters to layer 0
                bundleIdentifier: app.bundleIdentifier,
                localizedName: app.localizedName,
                executableURL: app.executableURL,
                qualification: .windowDiscovery
            ) else { continue }

            results.append(WindowInfo(
                id: windowID,
                element: axElement,
                ownerPID: pid,
                bundleID: app.bundleIdentifier ?? "",
                title: title ?? "",
                appName: app.localizedName ?? (info[kCGWindowOwnerName as String] as? String ?? "Unknown"),
                icon: app.icon
            ))
        }

        return results
    }

    /// Returns windows across ALL Spaces in z-order (front-most first).
    /// AX-first: discovers apps via NSWorkspace, queries AX windows per app
    /// (with brute-force cross-space fallback), filters via WindowDiscriminator,
    /// then sorts by CG z-order.
    static func allSpaces(includeHidden: Bool = false) -> [WindowInfo] {
        // Step 1: App discovery
        let apps = NSWorkspace.shared.runningApplications.filter { app in
            app.activationPolicy == .regular &&
            app.processIdentifier != ownPID &&
            (includeHidden || !app.isHidden)
        }

        // Step 2 (prefetch): CG window list for bounds and z-order
        let cgOptions: CGWindowListOption = [.excludeDesktopElements]
        let cgWindowList = CGWindowListCopyWindowInfo(cgOptions, kCGNullWindowID) as? [[String: Any]] ?? []

        var cgLookup: [CGWindowID: (bounds: CGRect, zOrder: Int)] = [:]
        var cgWindowsByPID: [pid_t: Set<CGWindowID>] = [:]
        for (index, info) in cgWindowList.enumerated() {
            guard let wid = info[kCGWindowNumber as String] as? CGWindowID,
                  let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            var bounds = CGRect.zero
            if let boundsDict = info[kCGWindowBounds as String] as? NSDictionary as CFDictionary? {
                CGRectMakeWithDictionaryRepresentation(boundsDict, &bounds)
            }
            cgLookup[wid] = (bounds: bounds, zOrder: index)
            if let pid = info[kCGWindowOwnerPID as String] as? pid_t {
                cgWindowsByPID[pid, default: []].insert(wid)
            }
        }

        // Step 3: AX-first window discovery + filtering (parallelized per-app)
        let cgsConn = CGSMainConnectionID()

        struct AppSnapshot {
            let pid: pid_t
            let bundleID: String?
            let appName: String
            let icon: NSImage?
            let localizedName: String?
            let executableURL: URL?
        }
        let appSnapshots = apps.map { AppSnapshot(
            pid: $0.processIdentifier,
            bundleID: $0.bundleIdentifier,
            appName: $0.localizedName ?? "Unknown",
            icon: $0.icon,
            localizedName: $0.localizedName,
            executableURL: $0.executableURL
        )}

        // Each app writes to its own slot — no synchronization needed
        var perAppResults: [[WindowInfo]?] = Array(repeating: nil, count: appSnapshots.count)
        perAppResults.withUnsafeMutableBufferPointer { buffer in
            DispatchQueue.concurrentPerform(iterations: appSnapshots.count) { i in
                let snap = appSnapshots[i]

                // Set messaging timeout (100ms) to cap slow/hung apps
                let appElement = AccessibilityHelper.appElement(for: snap.pid)
                AXUIElementSetMessagingTimeout(appElement, 0.1)

                // Standard AX windows (current space)
                var windowsByID: [CGWindowID: AXUIElement] = [:]
                var axValue: AnyObject?
                let axResult = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &axValue)
                if axResult == .success, let axWindows = axValue as? [AXUIElement] {
                    for ax in axWindows {
                        if let wid = AccessibilityHelper.windowID(for: ax), wid != 0 {
                            windowsByID[wid] = ax
                        }
                    }
                }

                // Brute-force cross-space discovery (only if CG shows windows AX missed)
                let cgWindows = cgWindowsByPID[snap.pid] ?? []
                let missingFromAX = cgWindows.subtracting(windowsByID.keys)
                if !missingFromAX.isEmpty {
                    let bruteForce = discoverWindowsByBruteForce(pid: snap.pid, targetWindowIDs: missingFromAX)
                    for (element, wid) in bruteForce {
                        if windowsByID[wid] == nil {
                            windowsByID[wid] = element
                        }
                    }
                }

                // Filter and build WindowInfo
                var appWindows: [WindowInfo] = []
                for (wid, element) in windowsByID {
                    AXUIElementSetMessagingTimeout(element, 0.1)

                    if AccessibilityHelper.isMinimized(element) { continue }

                    let subrole = AccessibilityHelper.getSubrole(of: element)
                    let role = AccessibilityHelper.getRole(of: element)
                    let title = AccessibilityHelper.getTitle(of: element)
                    let size = AccessibilityHelper.getSize(of: element)

                    var windowLevel: Int32 = 0
                    let levelOK = CGSGetWindowLevel(cgsConn, wid, &windowLevel) == 0
                    let level: Int? = levelOK ? Int(windowLevel) : nil

                    guard WindowDiscriminator.isActualWindow(
                        cgWindowID: wid,
                        subrole: subrole,
                        role: role,
                        title: title,
                        size: size,
                        level: level,
                        bundleIdentifier: snap.bundleID,
                        localizedName: snap.localizedName,
                        executableURL: snap.executableURL,
                        qualification: .windowDiscovery
                    ) else { continue }

                    appWindows.append(WindowInfo(
                        id: wid,
                        element: element,
                        ownerPID: snap.pid,
                        bundleID: snap.bundleID ?? "",
                        title: title ?? "",
                        appName: snap.appName,
                        icon: snap.icon,
                        cgBounds: cgLookup[wid]?.bounds
                    ))
                }
                buffer[i] = appWindows
            }
        }
        var results = perAppResults.compactMap { $0 }.flatMap { $0 }

        // Step 4: Sort by CG z-order (frontmost first)
        results.sort { a, b in
            let zA = cgLookup[a.id]?.zOrder ?? Int.max
            let zB = cgLookup[b.id]?.zOrder ?? Int.max
            return zA < zB
        }

        return results
    }

    // MARK: - Single Window Validation

    /// Validate a single AX element as a real window, verifying it against the CG window list.
    static func buildWindowInfo(
        element: AXUIElement,
        pid: pid_t,
        qualification: WindowDiscriminator.QualificationProfile = .windowDiscovery
    ) -> WindowInfo? {
        guard let windowID = AccessibilityHelper.windowID(for: element) else { return nil }

        // Verify this window is on-screen at layer 0
        let cgWindows = AccessibilityHelper.getWindowList()
        guard cgWindows.contains(where: {
            ($0[kCGWindowOwnerPID as String] as? pid_t) == pid &&
            ($0[kCGWindowNumber as String] as? CGWindowID) == windowID
        }) else { return nil }

        let app = NSRunningApplication(processIdentifier: pid)
        guard app?.activationPolicy == .regular else { return nil }

        let subrole = AccessibilityHelper.getSubrole(of: element)
        let role = AccessibilityHelper.getRole(of: element)
        let title = AccessibilityHelper.getTitle(of: element)
        let size = AccessibilityHelper.getSize(of: element)

        guard WindowDiscriminator.isActualWindow(
            cgWindowID: windowID,
            subrole: subrole,
            role: role,
            title: title,
            size: size,
            level: 0,
            bundleIdentifier: app?.bundleIdentifier,
            localizedName: app?.localizedName,
            executableURL: app?.executableURL,
            qualification: qualification
        ) else { return nil }

        return WindowInfo(
            id: windowID,
            element: element,
            ownerPID: pid,
            bundleID: app?.bundleIdentifier ?? "",
            title: title ?? "",
            appName: app?.localizedName ?? "Unknown",
            icon: app?.icon
        )
    }
}
