import AppKit
import ApplicationServices

class WindowManager: ObservableObject {
    @Published var availableWindows: [WindowInfo] = []

    private let ownPID = ProcessInfo.processInfo.processIdentifier

    func refreshWindowList() {
        let cgWindows = AccessibilityHelper.getWindowList()
        var results: [WindowInfo] = []

        // Group CG windows by PID
        var pidToWindows: [pid_t: [[String: Any]]] = [:]
        for info in cgWindows {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t else { continue }
            pidToWindows[pid, default: []].append(info)
        }

        for (pid, cgWindowsForPid) in pidToWindows {
            guard pid != ownPID else { continue }

            let app = NSRunningApplication(processIdentifier: pid)
            // Only include regular apps (visible in Dock). Filters out
            // accessory apps (menu-bar utilities, AltTab) and background agents.
            if app?.activationPolicy != .regular { continue }
            let bundleID = app?.bundleIdentifier ?? ""
            let appName = app?.localizedName ?? (cgWindowsForPid.first?[kCGWindowOwnerName as String] as? String ?? "Unknown")
            let icon = app?.icon

            let axWindows = AccessibilityHelper.windowElements(for: pid)

            // Match AX windows to CG windows by window ID
            for axWindow in axWindows {
                guard let windowID = AccessibilityHelper.windowID(for: axWindow) else { continue }

                // Verify this window is in our CG list (on-screen, layer 0)
                guard cgWindowsForPid.contains(where: {
                    ($0[kCGWindowNumber as String] as? CGWindowID) == windowID
                }) else { continue }

                let title = AccessibilityHelper.getTitle(of: axWindow) ?? ""

                // Skip windows with no title and tiny size (likely not real windows)
                if let size = AccessibilityHelper.getSize(of: axWindow),
                   size.width < 50 || size.height < 50, title.isEmpty {
                    continue
                }

                results.append(WindowInfo(
                    id: windowID,
                    element: axWindow,
                    ownerPID: pid,
                    bundleID: bundleID,
                    title: title,
                    appName: appName,
                    icon: icon
                ))
            }
        }

        availableWindows = results.sorted {
            if $0.appName != $1.appName { return $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    /// Build a WindowInfo for a single AX element, verifying it against the CG window list.
    func buildWindowInfo(element: AXUIElement, pid: pid_t) -> WindowInfo? {
        guard let windowID = AccessibilityHelper.windowID(for: element) else { return nil }

        // Verify this window is on-screen at layer 0
        let cgWindows = AccessibilityHelper.getWindowList()
        guard cgWindows.contains(where: {
            ($0[kCGWindowOwnerPID as String] as? pid_t) == pid &&
            ($0[kCGWindowNumber as String] as? CGWindowID) == windowID
        }) else { return nil }

        let app = NSRunningApplication(processIdentifier: pid)
        let title = AccessibilityHelper.getTitle(of: element) ?? ""

        if let size = AccessibilityHelper.getSize(of: element),
           size.width < 50 || size.height < 50, title.isEmpty {
            return nil
        }

        return WindowInfo(
            id: windowID,
            element: element,
            ownerPID: pid,
            bundleID: app?.bundleIdentifier ?? "",
            title: title,
            appName: app?.localizedName ?? "Unknown",
            icon: app?.icon
        )
    }

    /// Returns windows across ALL spaces in z-order (AX-first pipeline).
    ///
    /// 1. Discovers apps via NSWorkspace (regular activation policy only)
    /// 2. Per app: queries standard AX windows + brute-force cross-space discovery
    /// 3. Filters via WindowDiscriminator.isActualWindow
    /// 4. Enriches with CG data (bounds, z-order)
    /// 5. Sorts by CG z-order (frontmost first)
    func windowsInZOrderAllSpaces() -> [WindowInfo] {
        // Step 1: App discovery
        let apps = NSWorkspace.shared.runningApplications.filter { app in
            app.activationPolicy == .regular &&
            app.processIdentifier != ownPID &&
            !app.isHidden
        }

        // Step 4 (prefetch): CG window list for bounds and z-order
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

        // Step 2 & 3: AX-first window discovery + filtering (parallelized per-app)
        let cgsConn = CGSMainConnectionID()

        // Pre-extract app metadata on the calling thread (NSRunningApplication may not be thread-safe)
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

                // 2a. Set messaging timeout (100ms) to cap slow/hung apps
                let appElement = AccessibilityHelper.appElement(for: snap.pid)
                AXUIElementSetMessagingTimeout(appElement, 0.1)

                // 2b. Standard AX windows (current space)
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

                // 2c. Brute-force cross-space discovery (only if CG shows windows AX missed)
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

                // 2d. Filter and build WindowInfo
                var appWindows: [WindowInfo] = []
                for (wid, element) in windowsByID {
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
                        executableURL: snap.executableURL
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

        // Step 5: Sort by CG z-order (frontmost first)
        results.sort { a, b in
            let zA = cgLookup[a.id]?.zOrder ?? Int.max
            let zB = cgLookup[b.id]?.zOrder ?? Int.max
            return zA < zB
        }

        return results
    }

    /// Returns all on-screen windows ordered by z-index (front-most first).
    /// CGWindowListCopyWindowInfo already returns windows in this order,
    /// so we preserve it instead of sorting alphabetically.
    func windowsInZOrder() -> [WindowInfo] {
        let cgWindows = AccessibilityHelper.getWindowList()
        var results: [WindowInfo] = []

        // Build a lookup of AX elements keyed by window ID, per PID
        var axElementsByPID: [pid_t: [CGWindowID: AXUIElement]] = [:]

        for info in cgWindows {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  pid != ownPID else { continue }

            if axElementsByPID[pid] == nil {
                let axWindows = AccessibilityHelper.windowElements(for: pid)
                var map: [CGWindowID: AXUIElement] = [:]
                for ax in axWindows {
                    if let wid = AccessibilityHelper.windowID(for: ax) {
                        map[wid] = ax
                    }
                }
                axElementsByPID[pid] = map
            }
        }

        // Walk CG windows in z-order and build WindowInfo for each
        for info in cgWindows {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  pid != ownPID,
                  let windowID = info[kCGWindowNumber as String] as? CGWindowID,
                  let axElement = axElementsByPID[pid]?[windowID] else { continue }

            // Skip auxiliary/companion windows (GPU surfaces, rendering helpers)
            if AccessibilityHelper.getSubrole(of: axElement) == nil { continue }

            let title = AccessibilityHelper.getTitle(of: axElement) ?? ""
            if let size = AccessibilityHelper.getSize(of: axElement),
               size.width < 50 || size.height < 50, title.isEmpty {
                continue
            }

            let app = NSRunningApplication(processIdentifier: pid)
            if app?.activationPolicy != .regular { continue }
            results.append(WindowInfo(
                id: windowID,
                element: axElement,
                ownerPID: pid,
                bundleID: app?.bundleIdentifier ?? "",
                title: title,
                appName: app?.localizedName ?? (info[kCGWindowOwnerName as String] as? String ?? "Unknown"),
                icon: app?.icon
            ))
        }

        return results
    }
}
