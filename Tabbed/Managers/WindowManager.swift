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
}
