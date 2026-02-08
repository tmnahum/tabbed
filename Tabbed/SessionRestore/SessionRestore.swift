import AppKit

// MARK: - Session Restore

extension AppDelegate {

    func restoreSession(snapshots: [GroupSnapshot], mode: RestoreMode) {
        let liveWindows = WindowDiscovery.allSpaces(includeHidden: true).filter {
            !groupManager.isWindowGrouped($0.id)
        }

        var claimed = Set<CGWindowID>()

        for snapshot in snapshots {
            guard let matchedWindows = SessionManager.matchGroup(
                snapshot: snapshot,
                liveWindows: liveWindows,
                alreadyClaimed: claimed,
                mode: mode
            ) else { continue }

            for w in matchedWindows { claimed.insert(w.id) }

            let savedFrame = snapshot.frame.cgRect
            let restoredFrame = clampFrameForTabBar(savedFrame)
            let squeezeDelta = restoredFrame.origin.y - savedFrame.origin.y
            let effectiveSqueezeDelta = max(snapshot.tabBarSqueezeDelta, squeezeDelta)
            let restoredActiveIndex = min(snapshot.activeIndex, matchedWindows.count - 1)

            setupGroup(
                with: matchedWindows,
                frame: restoredFrame,
                squeezeDelta: effectiveSqueezeDelta,
                activeIndex: restoredActiveIndex
            )
        }
    }

    func restorePreviousSession() {
        guard let snapshots = pendingSessionSnapshots else { return }
        pendingSessionSnapshots = nil
        sessionState.hasPendingSession = false
        restoreSession(snapshots: snapshots, mode: .always)
    }
}
