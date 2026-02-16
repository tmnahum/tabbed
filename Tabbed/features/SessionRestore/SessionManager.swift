import Foundation
import CoreGraphics

enum SessionManager {
    private static let userDefaultsKey = "savedSession"
    private static let maximizedCounterOrderKey = "savedSessionMaximizedCounterOrder"
    private static let bundleAndTitleSeparator = "\u{1f}"

    /// Saved maximized counter order: space ID (as string) -> restore indices.
    /// Applied after restore to preserve user's tab bar order when multiple groups are maximized.
    struct MaximizedCounterOrderMetadata: Codable {
        let orderBySpaceID: [String: [Int]]
    }

    struct SnapshotWindowIdentity: Hashable {
        let windowID: CGWindowID
        let bundleID: String
        let title: String
    }

    struct LiveWindowIndex {
        let windowByID: [CGWindowID: WindowInfo]
        let windowsByBundleAndTitle: [String: [WindowInfo]]
    }

    // MARK: - Save / Load

    static func saveSession(
        groups: [TabGroup],
        mruGroupOrder: [UUID] = [],
        maximizedCounterOrderBySpaceID: [UInt64: [UUID]] = [:]
    ) {
        let snapshots = groups.map { group in
            GroupSnapshot(
                windows: group.windows.map { window in
                    WindowSnapshot(
                        windowID: window.id,
                        bundleID: window.bundleID,
                        title: window.title,
                        appName: window.appName,
                        isPinned: window.isPinned,
                        pinState: window.pinState,
                        customTabName: window.customTabName,
                        isSeparator: window.isSeparator
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

        saveMaximizedCounterOrder(
            maximizedCounterOrderBySpaceID: maximizedCounterOrderBySpaceID,
            mruGroupOrder: mruGroupOrder,
            groups: groups
        )
    }

    private static func saveMaximizedCounterOrder(
        maximizedCounterOrderBySpaceID: [UInt64: [UUID]],
        mruGroupOrder: [UUID],
        groups: [TabGroup]
    ) {
        guard !maximizedCounterOrderBySpaceID.isEmpty else { return }
        let restoreOrder = mruGroupOrder + groups.map(\.id).filter { !mruGroupOrder.contains($0) }
        var groupIDToIndex: [UUID: Int] = [:]
        for (index, groupID) in restoreOrder.enumerated() {
            groupIDToIndex[groupID] = index
        }
        var orderBySpaceID: [String: [Int]] = [:]
        for (spaceID, orderedGroupIDs) in maximizedCounterOrderBySpaceID {
            let indices = orderedGroupIDs.compactMap { groupIDToIndex[$0] }
            guard !indices.isEmpty else { continue }
            orderBySpaceID[String(spaceID)] = indices
        }
        guard !orderBySpaceID.isEmpty else { return }
        let metadata = MaximizedCounterOrderMetadata(orderBySpaceID: orderBySpaceID)
        guard let data = try? JSONEncoder().encode(metadata) else { return }
        UserDefaults.standard.set(data, forKey: maximizedCounterOrderKey)
    }

    static func loadMaximizedCounterOrderMetadata() -> MaximizedCounterOrderMetadata? {
        guard let data = UserDefaults.standard.data(forKey: maximizedCounterOrderKey),
              let metadata = try? JSONDecoder().decode(MaximizedCounterOrderMetadata.self, from: data) else {
            return nil
        }
        return metadata
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
        mode: RestoreMode,
        diagnosticsEnabled: Bool = SessionRestoreDiagnostics.isEnabled()
    ) -> [WindowInfo]? {
        var sharedMatchesBySnapshotIdentity: [SnapshotWindowIdentity: WindowInfo] = [:]
        return matchGroup(
            snapshot: snapshot,
            liveWindowIndex: makeLiveWindowIndex(liveWindows: liveWindows),
            alreadyClaimed: alreadyClaimed,
            sharedMatchesBySnapshotIdentity: &sharedMatchesBySnapshotIdentity,
            mode: mode,
            diagnosticsEnabled: diagnosticsEnabled
        )
    }

    static func matchGroup(
        snapshot: GroupSnapshot,
        liveWindowIndex: LiveWindowIndex,
        alreadyClaimed: Set<CGWindowID>,
        mode: RestoreMode,
        diagnosticsEnabled: Bool = SessionRestoreDiagnostics.isEnabled()
    ) -> [WindowInfo]? {
        var sharedMatchesBySnapshotIdentity: [SnapshotWindowIdentity: WindowInfo] = [:]
        return matchGroup(
            snapshot: snapshot,
            liveWindowIndex: liveWindowIndex,
            alreadyClaimed: alreadyClaimed,
            sharedMatchesBySnapshotIdentity: &sharedMatchesBySnapshotIdentity,
            mode: mode,
            diagnosticsEnabled: diagnosticsEnabled
        )
    }

    static func matchGroup(
        snapshot: GroupSnapshot,
        liveWindowIndex: LiveWindowIndex,
        alreadyClaimed: Set<CGWindowID>,
        sharedMatchesBySnapshotIdentity: inout [SnapshotWindowIdentity: WindowInfo],
        mode: RestoreMode,
        diagnosticsEnabled: Bool = SessionRestoreDiagnostics.isEnabled()
    ) -> [WindowInfo]? {
        var claimed = alreadyClaimed
        var matched: [WindowInfo] = []

        for snap in snapshot.windows {
            if snap.isSeparator {
                matched.append(WindowInfo.separator(withID: snap.windowID))
                continue
            }
            let snapshotIdentity = SnapshotWindowIdentity(
                windowID: snap.windowID,
                bundleID: snap.bundleID,
                title: snap.title
            )

            if let reusedMatch = sharedMatchesBySnapshotIdentity[snapshotIdentity] {
                if diagnosticsEnabled {
                    Logger.log("[SessionMatch] ✓ reused match: \(snap.appName)(\(snap.windowID)) → live(\(reusedMatch.id))")
                }
                var matchedWindow = reusedMatch
                matchedWindow.pinState = snap.pinState
                matchedWindow.customTabName = snap.customTabName
                matched.append(matchedWindow)
                continue
            }

            // 1. Exact CGWindowID match — window still exists
            if let byID = liveWindowIndex.windowByID[snap.windowID],
               !claimed.contains(byID.id) {
                if diagnosticsEnabled {
                    Logger.log("[SessionMatch] ✓ wid match: \(snap.appName)(\(snap.windowID))")
                }
                var matchedWindow = byID
                matchedWindow.pinState = snap.pinState
                matchedWindow.customTabName = snap.customTabName
                matched.append(matchedWindow)
                sharedMatchesBySnapshotIdentity[snapshotIdentity] = byID
                claimed.insert(matchedWindow.id)
                continue
            }

            // 2. Fallback: bundleID + title (app restarted, window has same title)
            let titleKey = makeBundleAndTitleKey(bundleID: snap.bundleID, title: snap.title)
            if let byTitle = liveWindowIndex.windowsByBundleAndTitle[titleKey]?.first(where: {
                !claimed.contains($0.id)
            }) {
                if diagnosticsEnabled {
                    Logger.log("[SessionMatch] ✓ title match: \(snap.appName)(\(snap.windowID)) → live(\(byTitle.id))")
                }
                var matchedWindow = byTitle
                matchedWindow.pinState = snap.pinState
                matchedWindow.customTabName = snap.customTabName
                matched.append(matchedWindow)
                sharedMatchesBySnapshotIdentity[snapshotIdentity] = byTitle
                claimed.insert(matchedWindow.id)
                continue
            }

            // 3. No match — skip this window.
            if diagnosticsEnabled {
                let widInLive = liveWindowIndex.windowByID[snap.windowID] != nil
                let widClaimed = claimed.contains(snap.windowID)
                Logger.log("[SessionMatch] ✗ no match: \(snap.appName)(\(snap.windowID)):\"\(snap.title)\" bundle=\(snap.bundleID) | widInLive=\(widInLive) widClaimed=\(widClaimed)")
            }
            // Smart mode: ALL windows must be present, so fail the whole group.
            if mode == .smart {
                if diagnosticsEnabled {
                    Logger.log("[SessionMatch] → smart mode: rejecting entire group")
                }
                return nil
            }
        }

        return matched.contains(where: { !$0.isSeparator }) ? matched : nil
    }

    static func makeLiveWindowIndex(liveWindows: [WindowInfo]) -> LiveWindowIndex {
        var windowByID: [CGWindowID: WindowInfo] = [:]
        var windowsByBundleAndTitle: [String: [WindowInfo]] = [:]
        windowByID.reserveCapacity(liveWindows.count)
        windowsByBundleAndTitle.reserveCapacity(liveWindows.count)

        for window in liveWindows {
            windowByID[window.id] = window
            let key = makeBundleAndTitleKey(bundleID: window.bundleID, title: window.title)
            windowsByBundleAndTitle[key, default: []].append(window)
        }

        return LiveWindowIndex(
            windowByID: windowByID,
            windowsByBundleAndTitle: windowsByBundleAndTitle
        )
    }

    private static func makeBundleAndTitleKey(bundleID: String, title: String) -> String {
        "\(bundleID)\(bundleAndTitleSeparator)\(title)"
    }
}
