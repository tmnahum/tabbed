import AppKit

// MARK: - Session Restore

extension AppDelegate {
    private static let launchRestoreRetryDelay: TimeInterval = 0.2
    private static let launchRestoreMaxAttempts = 15

    func restoreSessionOnLaunch(
        snapshots: [GroupSnapshot],
        mode: RestoreMode,
        maximizedCounterOrderMetadata: SessionManager.MaximizedCounterOrderMetadata? = nil,
        attempt: Int = 0
    ) {
        let inventoryWindows = windowInventory.allSpacesForSwitcher()

        if !windowInventory.hasCompletedRefresh {
            if attempt < Self.launchRestoreMaxAttempts {
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.launchRestoreRetryDelay) { [weak self] in
                    self?.restoreSessionOnLaunch(
                        snapshots: snapshots,
                        mode: mode,
                        maximizedCounterOrderMetadata: maximizedCounterOrderMetadata,
                        attempt: attempt + 1
                    )
                }
                return
            }
            Logger.log("[SessionRestore] launch restore inventory timeout; falling back to sync discovery")
            restoreSession(snapshots: snapshots, mode: mode, maximizedCounterOrderMetadata: maximizedCounterOrderMetadata)
            return
        }

        restoreSession(
            snapshots: snapshots,
            mode: mode,
            preloadedLiveWindows: inventoryWindows,
            maximizedCounterOrderMetadata: maximizedCounterOrderMetadata
        )
    }

    func restoreSession(
        snapshots: [GroupSnapshot],
        mode: RestoreMode,
        preloadedLiveWindows: [WindowInfo]? = nil,
        maximizedCounterOrderMetadata: SessionManager.MaximizedCounterOrderMetadata? = nil
    ) {
        let diagnosticsEnabled = SessionRestoreDiagnostics.isEnabled()
        let discovered = preloadedLiveWindows ?? WindowDiscovery.allSpaces()
        let liveWindows = discovered.filter {
            !groupManager.isWindowGrouped($0.id)
        }
        let liveWindowIndex = SessionManager.makeLiveWindowIndex(liveWindows: liveWindows)

        Logger.log("[SessionRestore] mode=\(mode) snapshots=\(snapshots.count) liveWindows=\(liveWindows.count)")
        if diagnosticsEnabled {
            for (i, snap) in snapshots.enumerated() {
                let descs = snap.windows.map { "\($0.appName)(\($0.windowID)):\"\($0.title)\"" }
                Logger.log("[SessionRestore] snapshot[\(i)]: \(descs.joined(separator: ", "))")
            }
        }

        // Diagnostic: check CG window list for all saved window IDs
        let savedIDs = Set(snapshots.flatMap { $0.windows.map { $0.windowID } })
        let liveIDs = Set(liveWindows.map { $0.id })
        let missingFromLive = savedIDs.subtracting(liveIDs)
        if !missingFromLive.isEmpty {
            let missingIDs = missingFromLive.sorted()
            Logger.log("[SessionRestore] ⚠ \(missingFromLive.count) saved windows missing from liveWindows: \(missingIDs)")
            if diagnosticsEnabled {
                // Check raw CG list to see if these windows exist at the CG level.
                // This can be expensive, so keep it behind an explicit diagnostics flag.
                let cgList = WindowDiscovery.rawWindowList(options: [.excludeDesktopElements])
                for wid in missingIDs {
                    if let info = cgList.first(where: { ($0[kCGWindowNumber as String] as? CGWindowID) == wid }) {
                        let layer = info[kCGWindowLayer as String] as? Int ?? -999
                        let owner = info[kCGWindowOwnerName as String] as? String ?? "?"
                        let pid = info[kCGWindowOwnerPID as String] as? pid_t ?? 0
                        var bounds = CGRect.zero
                        if let bd = info[kCGWindowBounds as String] as? NSDictionary as CFDictionary? {
                            CGRectMakeWithDictionaryRepresentation(bd, &bounds)
                        }
                        Logger.log("[SessionRestore] CG has wid=\(wid): owner=\(owner) pid=\(pid) layer=\(layer) bounds=\(bounds)")
                    } else {
                        Logger.log("[SessionRestore] CG does NOT have wid=\(wid)")
                    }
                }
            }
        }

        var claimed = Set<CGWindowID>()
        var sharedMatchesBySnapshotIdentity: [SessionManager.SnapshotWindowIdentity: WindowInfo] = [:]
        var restoreIndexToGroupID: [Int: UUID] = [:]

        for (snapshotIndex, snapshot) in snapshots.enumerated() {
            guard let matchedWindows = SessionManager.matchGroup(
                snapshot: snapshot,
                liveWindowIndex: liveWindowIndex,
                alreadyClaimed: claimed,
                sharedMatchesBySnapshotIdentity: &sharedMatchesBySnapshotIdentity,
                mode: mode,
                diagnosticsEnabled: diagnosticsEnabled
            ) else {
                Logger.log("[SessionRestore] snapshot[\(snapshotIndex)] FAILED — skipped")
                continue
            }
            Logger.log("[SessionRestore] snapshot[\(snapshotIndex)] matched \(matchedWindows.count)/\(snapshot.windows.count) windows")

            for w in matchedWindows { claimed.insert(w.id) }

            let savedFrame = snapshot.frame.cgRect
            let visibleFrame = CoordinateConverter.visibleFrameInAX(at: savedFrame.origin)
            let (restoredFrame, squeezeDelta): (CGRect, CGFloat)
            if let first = matchedWindows.first {
                (restoredFrame, squeezeDelta) = applyClamp(
                    element: first.element, windowID: first.id,
                    frame: savedFrame, visibleFrame: visibleFrame
                )
            } else {
                let result = ScreenCompensation.clampResult(frame: savedFrame, visibleFrame: visibleFrame)
                (restoredFrame, squeezeDelta) = (result.frame, result.squeezeDelta)
            }
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

            if let group = setupGroup(
                with: matchedWindows,
                frame: restoredFrame,
                squeezeDelta: effectiveSqueezeDelta,
                activeIndex: frontmostIndex,
                name: snapshot.name,
                allowSharedMembership: true
            ), maximizedCounterOrderMetadata != nil {
                restoreIndexToGroupID[snapshotIndex] = group.id
            }
        }

        // Apply persisted maximized counter order. Map saved restore indices to current group IDs.
        // Use each group's current space ID (space IDs can change across restarts).
        if let metadata = maximizedCounterOrderMetadata, !metadata.orderBySpaceID.isEmpty {
            for (_, indices) in metadata.orderBySpaceID {
                let orderedGroupIDs = indices.compactMap { restoreIndexToGroupID[$0] }
                guard orderedGroupIDs.count >= 2,
                      let firstGroupID = orderedGroupIDs.first,
                      let firstGroup = groupManager.groups.first(where: { $0.id == firstGroupID }),
                      let spaceID = resolvedSpaceID(for: firstGroup) else { continue }
                maximizedCounterOrderBySpaceID[spaceID] = orderedGroupIDs
            }
            refreshMaximizedGroupCounters()
        }

        // Seed MRU from restore order (reflects previous session's MRU).
        // Groups restored earlier = higher MRU priority.
        for group in groupManager.groups {
            mruTracker.appendIfMissing(.group(group.id))
        }

        // Sync active tab to the user's actual focused window.
        // The frontmostIndex heuristic above uses z-order which can diverge from
        // real focus (e.g. macOS ordering quirks, stale z-order from frame expansion).
        // This corrects it by querying the accessibility-level focused window.
        if let windowID = AccessibilityHelper.frontmostFocusedWindowID(),
           let group = groupManager.group(for: windowID) {
            group.switchTo(windowID: windowID)
            group.recordFocus(windowID: windowID)
            promoteWindowOwnership(windowID: windowID, group: group)
            recordGlobalActivation(.groupWindow(groupID: group.id, windowID: windowID))
            Logger.log("[SessionRestore] synced active tab to focused window wid=\(windowID) in group=\(group.id)")
        }
    }

    func restorePreviousSession() {
        guard let snapshots = pendingSessionSnapshots else { return }
        pendingSessionSnapshots = nil
        sessionState.hasPendingSession = false
        let metadata = SessionManager.loadMaximizedCounterOrderMetadata()
        restoreSession(snapshots: snapshots, mode: .always, maximizedCounterOrderMetadata: metadata)
    }
}
