import Foundation
import CoreGraphics

enum SessionManager {
    private static let userDefaultsKey = "savedSession"

    // MARK: - Save / Load

    static func saveSession(groups: [TabGroup], mruGroupOrder: [UUID] = []) {
        let snapshots = groups.map { group in
            GroupSnapshot(
                windows: group.windows.map { window in
                    WindowSnapshot(
                        windowID: window.id,
                        bundleID: window.bundleID,
                        title: window.title,
                        appName: window.appName,
                        isPinned: window.isPinned
                    )
                },
                activeIndex: group.activeIndex,
                frame: CodableRect(group.frame),
                tabBarSqueezeDelta: group.tabBarSqueezeDelta,
                name: group.displayName
            )
        }

        // Reorder snapshots: MRU groups first, then remaining in original order
        var snapshotsByGroupID: [UUID: GroupSnapshot] = [:]
        for (group, snapshot) in zip(groups, snapshots) {
            snapshotsByGroupID[group.id] = snapshot
        }
        var ordered: [GroupSnapshot] = []
        for groupID in mruGroupOrder {
            if let snapshot = snapshotsByGroupID.removeValue(forKey: groupID) {
                ordered.append(snapshot)
            }
        }
        for group in groups {
            if let snapshot = snapshotsByGroupID.removeValue(forKey: group.id) {
                ordered.append(snapshot)
            }
        }

        guard let data = try? JSONEncoder().encode(ordered) else { return }
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
                Logger.log("[SessionMatch] ✓ wid match: \(snap.appName)(\(snap.windowID))")
                var matchedWindow = byID
                matchedWindow.isPinned = snap.isPinned
                matched.append(matchedWindow)
                claimed.insert(matchedWindow.id)
                continue
            }

            // 2. Fallback: bundleID + title (app restarted, window has same title)
            if let byTitle = liveWindows.first(where: {
                !claimed.contains($0.id) && $0.bundleID == snap.bundleID && $0.title == snap.title
            }) {
                Logger.log("[SessionMatch] ✓ title match: \(snap.appName)(\(snap.windowID)) → live(\(byTitle.id))")
                var matchedWindow = byTitle
                matchedWindow.isPinned = snap.isPinned
                matched.append(matchedWindow)
                claimed.insert(matchedWindow.id)
                continue
            }

            // 3. No match — skip this window.
            let widInLive = liveWindows.contains { $0.id == snap.windowID }
            let widClaimed = claimed.contains(snap.windowID)
            Logger.log("[SessionMatch] ✗ no match: \(snap.appName)(\(snap.windowID)):\"\(snap.title)\" bundle=\(snap.bundleID) | widInLive=\(widInLive) widClaimed=\(widClaimed)")
            // Smart mode: ALL windows must be present, so fail the whole group.
            if mode == .smart {
                Logger.log("[SessionMatch] → smart mode: rejecting entire group")
                return nil
            }
        }

        return matched.isEmpty ? nil : matched
    }
}
