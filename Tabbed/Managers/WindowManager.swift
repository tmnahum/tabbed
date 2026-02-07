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

    /// Returns windows across ALL spaces in z-order.
    ///
    /// Uses CGWindowListCopyWindowInfo (without `.optionOnScreenOnly`) for discovery,
    /// which returns windows from all Spaces. For each CG window we try to find a
    /// matching AXUIElement; windows without an AX match (typically on other Spaces)
    /// get the app's AXUIElement as a placeholder — `raiseWindow`'s fallback resolves
    /// a fresh element at focus time.
    func windowsInZOrderAllSpaces() -> [WindowInfo] {
        let options: CGWindowListOption = [.excludeDesktopElements]
        guard let cgWindowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return windowsInZOrder()
        }

        let cgWindows = cgWindowList.filter { info in
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { return false }
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID else { return false }
            return true
        }

        // Build AX element lookup per PID (lazy, each PID queried at most once)
        var axByPID: [pid_t: [CGWindowID: AXUIElement]] = [:]
        var appCache: [pid_t: NSRunningApplication?] = [:]
        var excludedPIDs: Set<pid_t> = []

        func ensurePID(_ pid: pid_t, cgOwnerName: String?) {
            guard axByPID[pid] == nil else { return }
            let app = NSRunningApplication(processIdentifier: pid)
            appCache[pid] = app

            // Only include regular apps (visible in Dock). Filters out
            // accessory apps (menu-bar utilities, AltTab) and background agents.
            if app?.activationPolicy != .regular {
                excludedPIDs.insert(pid)
                axByPID[pid] = [:]
                return
            }

            let axWindows = AccessibilityHelper.windowElements(for: pid)
            var map: [CGWindowID: AXUIElement] = [:]
            for ax in axWindows {
                if let wid = AccessibilityHelper.windowID(for: ax) {
                    map[wid] = ax
                }
            }
            axByPID[pid] = map
        }

        var results: [WindowInfo] = []

        for info in cgWindows {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let windowID = info[kCGWindowNumber as String] as? CGWindowID else { continue }

            let cgOwnerName = info[kCGWindowOwnerName as String] as? String
            ensurePID(pid, cgOwnerName: cgOwnerName)
            if excludedPIDs.contains(pid) { continue }

            let app = appCache[pid] ?? nil
            if app?.isHidden == true { continue }

            // Try to match an AX element for this window
            if let axElement = axByPID[pid]?[windowID] {
                // Have AX element — use it for minimized check and metadata
                if AccessibilityHelper.isMinimized(axElement) { continue }
                let title = AccessibilityHelper.getTitle(of: axElement) ?? ""
                if let size = AccessibilityHelper.getSize(of: axElement),
                   size.width < 50 || size.height < 50, title.isEmpty {
                    continue
                }
                results.append(WindowInfo(
                    id: windowID,
                    element: axElement,
                    ownerPID: pid,
                    bundleID: app?.bundleIdentifier ?? "",
                    title: title,
                    appName: app?.localizedName ?? cgOwnerName ?? "Unknown",
                    icon: app?.icon
                ))
            } else {
                // No AX match — check if this is a companion window vs other-space window.
                // Companion/auxiliary CG windows (GPU surfaces, rendering helpers) are
                // on-screen but NOT in the app's AX window list. Other-space windows
                // are off-screen and also lack AX matches. Only include the latter.
                let isOnScreen: Bool
                if let flag = info[kCGWindowIsOnscreen as String] as? Bool {
                    isOnScreen = flag
                } else if let num = info[kCGWindowIsOnscreen as String] as? Int {
                    isOnScreen = num != 0
                } else {
                    isOnScreen = false
                }
                if isOnScreen { continue }

                let cgTitle = info[kCGWindowName as String] as? String ?? ""
                var bounds = CGRect.zero
                if let boundsRef = info[kCGWindowBounds as String] as? NSDictionary as CFDictionary? {
                    CGRectMakeWithDictionaryRepresentation(boundsRef, &bounds)
                }
                if bounds.width < 50 || bounds.height < 50, cgTitle.isEmpty {
                    continue
                }
                results.append(WindowInfo(
                    id: windowID,
                    element: AccessibilityHelper.appElement(for: pid),
                    ownerPID: pid,
                    bundleID: app?.bundleIdentifier ?? "",
                    title: cgTitle,
                    appName: app?.localizedName ?? cgOwnerName ?? "Unknown",
                    icon: app?.icon
                ))
            }
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
