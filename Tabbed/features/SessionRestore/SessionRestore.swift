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
            // Intentionally use the frontmost window (z-order) as the active tab
            // rather than the saved activeIndex. This ensures the highlighted tab
            // matches what's visually on top, so the user's current view isn't
            // disrupted by raising a different window during restore.
            let frontmostIndex = matchedWindows.indices.min(by: { a, b in
                let zA = liveWindows.firstIndex(where: { $0.id == matchedWindows[a].id }) ?? .max
                let zB = liveWindows.firstIndex(where: { $0.id == matchedWindows[b].id }) ?? .max
                return zA < zB
            }) ?? 0

            setupGroup(
                with: matchedWindows,
                frame: restoredFrame,
                squeezeDelta: effectiveSqueezeDelta,
                activeIndex: frontmostIndex
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
