import Foundation
import CoreGraphics

enum SessionManager {
    private static let userDefaultsKey = "savedSession"

    // MARK: - Save / Load

    static func saveSession(groups: [TabGroup]) {
        let snapshots = groups.map { group in
            GroupSnapshot(
                windows: group.windows.map { window in
                    WindowSnapshot(
                        bundleID: window.bundleID,
                        title: window.title,
                        appName: window.appName
                    )
                },
                activeIndex: group.activeIndex,
                frame: CodableRect(group.frame),
                tabBarSqueezeDelta: group.tabBarSqueezeDelta
            )
        }
        guard let data = try? JSONEncoder().encode(snapshots) else { return }
        UserDefaults.standard.set(data, forKey: userDefaultsKey)
    }

    static func loadSession() -> [GroupSnapshot]? {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let snapshots = try? JSONDecoder().decode([GroupSnapshot].self, from: data) else {
            return nil
        }
        return snapshots.isEmpty ? nil : snapshots
    }

    // MARK: - Matching

    /// Attempt to match snapshot windows to live windows.
    /// Returns nil if the group can't be restored under the given mode.
    /// Returns matched WindowInfos (in snapshot order) on success.
    ///
    /// Space-aware: after the first window is matched, subsequent candidates
    /// prefer windows on the same Space to avoid cross-space capture.
    static func matchGroup(
        snapshot: GroupSnapshot,
        liveWindows: [WindowInfo],
        alreadyClaimed: Set<CGWindowID>,
        mode: RestoreMode
    ) -> [WindowInfo]? {
        var claimed = alreadyClaimed
        var matched: [WindowInfo] = []
        var groupSpace: UInt64?

        for snap in snapshot.windows {
            let candidates = liveWindows.filter { w in
                !claimed.contains(w.id) && w.bundleID == snap.bundleID
            }

            // Prefer candidates on the same Space as already-matched windows
            let preferred: [WindowInfo]
            if let space = groupSpace {
                let sameSpace = candidates.filter { spaceForWindow($0.id) == space }
                preferred = sameSpace.isEmpty ? candidates : sameSpace
            } else {
                preferred = candidates
            }

            if let window = preferred.first(where: { $0.title == snap.title })
                          ?? candidates.first(where: { $0.title == snap.title })
                          ?? preferred.first
                          ?? candidates.first {
                matched.append(window)
                claimed.insert(window.id)
                if groupSpace == nil { groupSpace = spaceForWindow(window.id) }
                continue
            }

            // No candidates at all (app not running).
            // Smart mode: ALL apps must be present, so fail the whole group.
            if mode == .smart {
                return nil
            }
        }

        return matched.isEmpty ? nil : matched
    }

    private static func spaceForWindow(_ windowID: CGWindowID) -> UInt64? {
        let conn = CGSMainConnectionID()
        let spaces = CGSCopySpacesForWindows(conn, 0x7, [windowID] as CFArray) as? [UInt64] ?? []
        return spaces.first
    }
}
