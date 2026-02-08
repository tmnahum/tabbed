import AppKit

// MARK: - Session Restore

extension AppDelegate {

    func restoreSession(snapshots: [GroupSnapshot], mode: RestoreMode) {
        let liveWindows = WindowDiscovery.allSpaces().filter {
            !groupManager.isWindowGrouped($0.id)
        }

        Logger.log("[SessionRestore] mode=\(mode) snapshots=\(snapshots.count) liveWindows=\(liveWindows.count)")
        for (i, snap) in snapshots.enumerated() {
            let descs = snap.windows.map { "\($0.appName)(\($0.windowID)):\"\($0.title)\"" }
            Logger.log("[SessionRestore] snapshot[\(i)]: \(descs.joined(separator: ", "))")
        }

        // Diagnostic: check CG window list for all saved window IDs
        let savedIDs = Set(snapshots.flatMap { $0.windows.map { $0.windowID } })
        let liveIDs = Set(liveWindows.map { $0.id })
        let missingFromLive = savedIDs.subtracting(liveIDs)
        if !missingFromLive.isEmpty {
            Logger.log("[SessionRestore] ⚠ \(missingFromLive.count) saved windows missing from liveWindows: \(missingFromLive.sorted())")
            // Check raw CG list to see if these windows exist at the CG level
            let cgList = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            for wid in missingFromLive.sorted() {
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

        var claimed = Set<CGWindowID>()

        for (snapshotIndex, snapshot) in snapshots.enumerated() {
            guard let matchedWindows = SessionManager.matchGroup(
                snapshot: snapshot,
                liveWindows: liveWindows,
                alreadyClaimed: claimed,
                mode: mode
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

            setupGroup(
                with: matchedWindows,
                frame: restoredFrame,
                squeezeDelta: effectiveSqueezeDelta,
                activeIndex: frontmostIndex
            )
        }

        // Seed globalMRU from restore order (reflects previous session's MRU).
        // Groups restored earlier = higher MRU priority.
        for group in groupManager.groups where !globalMRU.contains(.group(group.id)) {
            globalMRU.append(.group(group.id))
        }

        // Sync active tab to the user's actual focused window.
        // The frontmostIndex heuristic above uses z-order which can diverge from
        // real focus (e.g. macOS ordering quirks, stale z-order from frame expansion).
        // This corrects it by querying the accessibility-level focused window.
        if let frontApp = NSWorkspace.shared.frontmostApplication {
            let appElement = AccessibilityHelper.appElement(for: frontApp.processIdentifier)
            var focusedValue: AnyObject?
            let result = AXUIElementCopyAttributeValue(
                appElement, kAXFocusedWindowAttribute as CFString, &focusedValue
            )
            if result == .success, let focusedRef = focusedValue {
                let windowElement = focusedRef as! AXUIElement // swiftlint:disable:this force_cast
                if let windowID = AccessibilityHelper.windowID(for: windowElement),
                   let group = groupManager.group(for: windowID) {
                    group.switchTo(windowID: windowID)
                    group.recordFocus(windowID: windowID)
                    lastActiveGroupID = group.id
                    recordGlobalActivation(.group(group.id))
                    Logger.log("[SessionRestore] synced active tab to focused window wid=\(windowID) in group=\(group.id)")
                }
            }
        }
    }

    func restorePreviousSession() {
        guard let snapshots = pendingSessionSnapshots else { return }
        pendingSessionSnapshots = nil
        sessionState.hasPendingSession = false
        restoreSession(snapshots: snapshots, mode: .always)
    }
}
