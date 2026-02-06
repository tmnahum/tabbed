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
