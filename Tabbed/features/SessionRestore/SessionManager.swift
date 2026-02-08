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
    static func matchGroup(
        snapshot: GroupSnapshot,
        liveWindows: [WindowInfo],
        alreadyClaimed: Set<CGWindowID>,
        mode: RestoreMode
    ) -> [WindowInfo]? {
        var claimed = alreadyClaimed
        var matched: [WindowInfo] = []

        for snap in snapshot.windows {
            let candidates = liveWindows.filter { w in
                !claimed.contains(w.id) && w.bundleID == snap.bundleID
            }

            // Exact match: bundleID + title
            if let exact = candidates.first(where: { $0.title == snap.title }) {
                matched.append(exact)
                claimed.insert(exact.id)
                continue
            }

            // Fall back to bundleID-only match
            if let fallback = candidates.first {
                matched.append(fallback)
                claimed.insert(fallback.id)
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
}
