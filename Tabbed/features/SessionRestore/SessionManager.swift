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
                        windowID: window.id,
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
    /// Matching priority:
    /// 1. CGWindowID — same window still exists (app stayed running)
    /// 2. bundleID + title — app restarted but window title matches
    /// 3. No match — skip the entry (no bundleID-only fallback)
    static func matchGroup(
        snapshot: GroupSnapshot,
        liveWindows: [WindowInfo],
        alreadyClaimed: Set<CGWindowID>,
        mode: RestoreMode
    ) -> [WindowInfo]? {
        var claimed = alreadyClaimed
        var matched: [WindowInfo] = []

        for snap in snapshot.windows {
            // 1. Exact CGWindowID match — window still exists
            if let byID = liveWindows.first(where: { $0.id == snap.windowID && !claimed.contains($0.id) }) {
                matched.append(byID)
                claimed.insert(byID.id)
                continue
            }

            // 2. Fallback: bundleID + title (app restarted, window has same title)
            if let byTitle = liveWindows.first(where: {
                !claimed.contains($0.id) && $0.bundleID == snap.bundleID && $0.title == snap.title
            }) {
                matched.append(byTitle)
                claimed.insert(byTitle.id)
                continue
            }

            // 3. No match — skip this window.
            // Smart mode: ALL windows must be present, so fail the whole group.
            if mode == .smart {
                return nil
            }
        }

        return matched.isEmpty ? nil : matched
    }
}
