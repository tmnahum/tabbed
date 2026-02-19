import AppKit

// MARK: - Screen Compensation Helpers

extension AppDelegate {

    /// Apply screen compensation: push window down for tab bar and shrink height.
    ///
    /// When `existingSqueezeDelta > 0`, the window was already squeezed but the
    /// app reverted the position. In that case we only re-push position without
    /// re-shrinking (prevents cumulative height loss on each clamp cycle).
    func applyClamp(
        element: AXUIElement,
        windowID: CGWindowID,
        frame: CGRect,
        visibleFrame: CGRect,
        existingSqueezeDelta: CGFloat = 0
    ) -> (frame: CGRect, squeezeDelta: CGFloat) {
        let result = ScreenCompensation.clampResult(frame: frame, visibleFrame: visibleFrame)
        guard result.squeezeDelta > 0 else {
            return (result.frame, result.squeezeDelta)
        }

        if existingSqueezeDelta > 0 {
            // Already squeezed — re-push position only, don't re-shrink height.
            let targetY = visibleFrame.origin.y + ScreenCompensation.tabBarHeight
            let targetFrame = CGRect(x: frame.origin.x, y: targetY,
                                     width: frame.width, height: frame.height)
            Logger.log("[CLAMP] re-push wid=\(windowID) frame=\(frame) → y=\(targetY) (height unchanged)")
            setExpectedFrame(targetFrame, for: [windowID])
            AccessibilityHelper.setPositionAsync(of: element, to: targetFrame.origin)
            return (targetFrame, existingSqueezeDelta)
        }

        // First-time squeeze: push position down and shrink height.
        Logger.log("[CLAMP] squeeze wid=\(windowID) frame=\(frame) → \(result.frame) delta=\(result.squeezeDelta)")
        setExpectedFrame(result.frame, for: [windowID])
        AccessibilityHelper.setFrameAsync(of: element, to: result.frame)

        // Quick re-check: some apps accept the position synchronously but
        // revert it asynchronously (~50-200ms). Catch it fast so the user
        // doesn't see the window jump back and forth.
        let target = result.frame
        let delta = result.squeezeDelta
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self,
                  let actual = AccessibilityHelper.getFrame(of: element),
                  abs(actual.origin.y - target.origin.y) > Self.frameTolerance else { return }
            Logger.log("[CLAMP] quick re-push wid=\(windowID) actual=\(actual) → y=\(target.origin.y)")
            self.expectedFrames.removeValue(forKey: windowID)
            self.setExpectedFrame(target, for: [windowID])
            AccessibilityHelper.setPositionAsync(of: element, to: target.origin)
        }

        return (result.frame, delta)
    }
}

// MARK: - Window Event Handlers

extension AppDelegate {

    func nextFocusDiagnosticSequence() -> UInt64 {
        focusDiagnosticSequence &+= 1
        return focusDiagnosticSequence
    }

    func invalidateDeferredFocusPanelOrdering(reason: String = "unspecified") {
        let previous = focusDrivenPanelOrderGeneration
        focusDrivenPanelOrderGeneration &+= 1
        Logger.log("[FOCUSDBG] invalidate-generation reason=\(reason) \(previous)->\(focusDrivenPanelOrderGeneration)")
    }

    func shouldProcessFocusDrivenPanelOrdering(for windowID: CGWindowID, source: String = "unknown") -> Bool {
        guard isCommitEchoSuppressionActive,
              let targetWindowID = pendingCommitEchoTargetWindowID else { return true }
        let shouldProcess = windowID == targetWindowID
        if !shouldProcess {
            Logger.log("[FOCUSDBG] gate drop source=\(source) window=\(windowID) target=\(targetWindowID) echoSource=\(pendingCommitEchoSource ?? "unknown")")
        } else {
            Logger.log("[FOCUSDBG] gate allow source=\(source) window=\(windowID) target=\(targetWindowID)")
        }
        return shouldProcess
    }

    func orderPanelAboveFromFocusEvent(_ panel: TabBarPanel, windowID: CGWindowID, source: String = "unknown") {
        guard shouldProcessFocusDrivenPanelOrdering(for: windowID, source: source) else { return }

        focusDrivenPanelOrderGeneration &+= 1
        let generation = focusDrivenPanelOrderGeneration
        Logger.log("[FOCUSDBG] order immediate source=\(source) window=\(windowID) generation=\(generation)")
        panel.orderAbove(windowID: windowID)
        onFocusPanelOrdered?(windowID)

        // Re-order after a delay — when the OS raises a window (dock click, Cmd-Tab,
        // third-party switcher), its reordering may finish after our orderAbove call.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self, weak panel] in
            guard let self, let panel else { return }
            guard self.focusDrivenPanelOrderGeneration == generation else {
                Logger.log("[FOCUSDBG] order deferred drop reason=stale source=\(source) window=\(windowID) scheduledGeneration=\(generation) currentGeneration=\(self.focusDrivenPanelOrderGeneration)")
                return
            }
            guard self.shouldProcessFocusDrivenPanelOrdering(for: windowID, source: "\(source)-deferred") else {
                Logger.log("[FOCUSDBG] order deferred drop reason=gated source=\(source) window=\(windowID) generation=\(generation)")
                return
            }
            Logger.log("[FOCUSDBG] order deferred apply source=\(source) window=\(windowID) generation=\(generation)")
            panel.orderAbove(windowID: windowID)
            self.onFocusPanelOrdered?(windowID)
        }
    }

    func handleWindowMoved(_ windowID: CGWindowID) {
        let containingGroups = groupManager.groups(for: windowID)
        guard !containingGroups.isEmpty,
              let windowInfo = containingGroups.compactMap({ g in g.windows.first(where: { $0.id == windowID }) }).first,
              let frame = AccessibilityHelper.getFrame(of: windowInfo.element) else { return }

        let group: TabGroup? = containingGroups.count > 1
            ? ownerGroupForWindowMove(for: windowID, currentFrame: frame, source: "windowMoved")
            : containingGroups[0]
        guard let group = group,
              let panel = tabBarPanels[group.id] else { return }

        if barDraggingGroupID == group.id { return }
        if shouldSuppress(windowID: windowID, currentFrame: frame) { return }

        let existingSqueeze = ScreenCompensation.existingSqueezeForReclamp(
            previousFrame: group.frame,
            incomingFrame: frame,
            existingSqueezeDelta: group.tabBarSqueezeDelta,
            tolerance: Self.frameTolerance
        )
        let visibleFrame = CoordinateConverter.visibleFrameInAX(at: frame.origin)
        let (adjustedFrame, squeezeDelta) = applyClamp(
            element: windowInfo.element, windowID: windowID,
            frame: frame, visibleFrame: visibleFrame,
            existingSqueezeDelta: existingSqueeze
        )

        group.frame = adjustedFrame
        group.tabBarSqueezeDelta = squeezeDelta

        let others = group.visibleWindows.filter { $0.id != windowID }
        setExpectedFrame(adjustedFrame, for: others.map(\.id))
        for window in others {
            AccessibilityHelper.setFrameAsync(of: window.element, to: adjustedFrame)
        }

        panel.positionAbove(windowFrame: adjustedFrame, isMaximized: isGroupMaximized(group).0)
        panel.orderAbove(windowID: windowID)
        if containingGroups.count > 1 {
            promoteWindowOwnership(windowID: windowID, group: group)
        }
        evaluateAutoCapture()
    }

    private func setWindowFullscreenState(_ isFullscreened: Bool, for windowID: CGWindowID) {
        for group in groupManager.groups(for: windowID) {
            if let index = group.windows.firstIndex(where: { $0.id == windowID }) {
                group.windows[index].isFullscreened = isFullscreened
            }
        }
    }

    private func setWindowElement(_ element: AXUIElement, for windowID: CGWindowID) {
        for group in groupManager.groups(for: windowID) {
            if let index = group.windows.firstIndex(where: { $0.id == windowID }) {
                group.windows[index].element = element
            }
        }
    }

    func handleWindowResized(_ windowID: CGWindowID) {
        let containingGroups = groupManager.groups(for: windowID)
        guard !containingGroups.isEmpty,
              let windowInfo = containingGroups.compactMap({ g in g.windows.first(where: { $0.id == windowID }) }).first else { return }

        // Check if a fullscreened window is exiting fullscreen.
        // This runs before the main guard because the fullscreened window
        // won't be the activeWindow (a visible tab is active instead).
        if let group = ownerGroup(for: windowID, source: "windowResized-fullscreen-check"),
           let idx = group.windows.firstIndex(where: { $0.id == windowID }),
           idx < group.windows.count,
           group.windows[idx].isFullscreened {
            let window = group.windows[idx]
            if !AccessibilityHelper.isFullScreen(window.element) {
                handleFullscreenExit(windowID: windowID, group: group)
            }
            return
        }

        guard let frame = AccessibilityHelper.getFrame(of: windowInfo.element) else { return }
        let group: TabGroup? = containingGroups.count > 1
            ? ownerGroupForWindowMove(for: windowID, currentFrame: frame, source: "windowResized")
            : containingGroups[0]
        guard let group = group,
              let panel = tabBarPanels[group.id] else { return }

        if barDraggingGroupID == group.id { return }
        if shouldSuppress(windowID: windowID, currentFrame: frame) { return }

        if AccessibilityHelper.isFullScreen(windowInfo.element) {
            Logger.log("[FULLSCREEN] Window \(windowID) entered fullscreen in group \(group.id)")
            expectedFrames.removeValue(forKey: windowID)
            setWindowFullscreenState(true, for: windowID)
            // Switch to next visible tab if available
            if let nextVisible = group.visibleWindows.first {
                group.switchTo(windowID: nextVisible.id)
                bringTabToFront(nextVisible, in: group)
            } else {
                // All windows fullscreened — hide the tab bar
                panel.orderOut(nil)
            }
            evaluateAutoCapture()
            return
        }

        let existingSqueeze = ScreenCompensation.existingSqueezeForReclamp(
            previousFrame: group.frame,
            incomingFrame: frame,
            existingSqueezeDelta: group.tabBarSqueezeDelta,
            tolerance: Self.frameTolerance
        )

        let visibleFrame = CoordinateConverter.visibleFrameInAX(at: frame.origin)
        let (adjustedFrame, squeezeDelta) = applyClamp(
            element: windowInfo.element, windowID: windowID,
            frame: frame, visibleFrame: visibleFrame,
            existingSqueezeDelta: existingSqueeze
        )

        group.frame = adjustedFrame
        group.tabBarSqueezeDelta = squeezeDelta

        let others = group.visibleWindows.filter { $0.id != windowID }
        setExpectedFrame(adjustedFrame, for: others.map(\.id))
        for window in others {
            AccessibilityHelper.setFrameAsync(of: window.element, to: adjustedFrame)
        }

        panel.positionAbove(windowFrame: adjustedFrame, isMaximized: isGroupMaximized(group).0)
        panel.orderAbove(windowID: windowID)
        if containingGroups.count > 1 {
            promoteWindowOwnership(windowID: windowID, group: group)
        }
        evaluateAutoCapture()

        let groupID = group.id
        resyncWorkItems[groupID]?.cancel()
        let resync = DispatchWorkItem { [weak self] in
            self?.resyncWorkItems.removeValue(forKey: groupID)
            guard let self,
                  let group = self.groupManager.groups.first(where: { $0.id == groupID }),
                  let panel = self.tabBarPanels[groupID],
                  let activeWindow = group.activeWindow,
                  let currentFrame = AccessibilityHelper.getFrame(of: activeWindow.element) else { return }

            let existingSqueeze = ScreenCompensation.existingSqueezeForReclamp(
                previousFrame: group.frame,
                incomingFrame: currentFrame,
                existingSqueezeDelta: group.tabBarSqueezeDelta,
                tolerance: Self.frameTolerance
            )
            let visibleFrame = CoordinateConverter.visibleFrameInAX(at: currentFrame.origin)
            let (clamped, squeezeDelta) = self.applyClamp(
                element: activeWindow.element, windowID: activeWindow.id,
                frame: currentFrame, visibleFrame: visibleFrame,
                existingSqueezeDelta: existingSqueeze
            )
            guard clamped != group.frame else {
                // Frame is already correct. Clear suppression so if the app
                // reverts position after this point, handleWindowMoved fires
                // immediately and re-pushes without waiting for the deadline.
                self.expectedFrames.removeValue(forKey: activeWindow.id)
                return
            }

            group.frame = clamped
            group.tabBarSqueezeDelta = squeezeDelta
            let others = group.visibleWindows.filter { $0.id != activeWindow.id }
            self.setExpectedFrame(clamped, for: others.map(\.id))
            for window in others {
                AccessibilityHelper.setFrameAsync(of: window.element, to: clamped)
            }
            panel.positionAbove(windowFrame: clamped, isMaximized: self.isGroupMaximized(group).0)
            panel.orderAbove(windowID: activeWindow.id)
            self.evaluateAutoCapture()
        }
        resyncWorkItems[groupID] = resync
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: resync)
    }

    func handleWindowFocused(pid: pid_t, element: AXUIElement) {
        guard let windowID = AccessibilityHelper.windowID(for: element),
              let group = ownerGroup(for: windowID, source: "windowFocused"),
              let panel = tabBarPanels[group.id] else { return }
        let eventID = nextFocusDiagnosticSequence()

        // Don't let a fullscreened window become the active tab —
        // it would confuse frame sync since it's on a different Space.
        if let w = group.windows.first(where: { $0.id == windowID }), w.isFullscreened { return }

        // During an active switcher session or commit-echo suppression,
        // don't let OS focus events mutate group state — the switcher
        // owns the selection, and post-commit events are echoes of our
        // own raiseWindow/activate calls.
        let commitEchoSuppressed = shouldSuppressCommitEcho(for: windowID)
        let suppressGroupState = switcherController.isActive || commitEchoSuppressed
        Logger.log("[FOCUSDBG] event=\(eventID) type=windowFocused pid=\(pid) window=\(windowID) group=\(group.id) switcherActive=\(switcherController.isActive) commitEchoSuppressed=\(commitEchoSuppressed) suppressGroupState=\(suppressGroupState) lastActiveGroup=\(lastActiveGroupID?.uuidString ?? "nil")")
        if !suppressGroupState {
            let previousID = group.activeWindow?.id
            if previousID != windowID {
                Logger.log("[DEBUG] handleWindowFocused: switching \(previousID.map(String.init) ?? "nil") → \(windowID) (pid=\(pid))")
            }
            group.switchTo(windowID: windowID)
            promoteWindowOwnership(windowID: windowID, group: group)
            if !group.isCycling {
                group.recordFocus(windowID: windowID)
            }
            evaluateAutoCapture()
        }

        guard shouldProcessFocusDrivenPanelOrdering(for: windowID, source: "windowFocused#\(eventID)") else {
            Logger.log("[FOCUSDBG] event=\(eventID) type=windowFocused panelOrdering=skipped window=\(windowID)")
            return
        }

        // Don't drag the group's panel to a different space — the window is about
        // to be ejected by the space-change handler and will get its own group.
        if group.spaceID == 0 || SpaceUtils.spaceID(for: windowID) == group.spaceID {
            movePanelToWindowSpace(panel, windowID: windowID)
        }
        Logger.log("[FOCUSDBG] event=\(eventID) type=windowFocused panelOrdering=apply window=\(windowID)")
        orderPanelAboveFromFocusEvent(panel, windowID: windowID, source: "windowFocused#\(eventID)")
    }

    func handleWindowDestroyed(_ windowID: CGWindowID) {
        mruTracker.removeWindow(windowID)
        let containingGroups = groupManager.groups(for: windowID)
        guard !containingGroups.isEmpty,
              let representativeWindow = containingGroups
                .compactMap({ group in group.windows.first(where: { $0.id == windowID }) })
                .first else { return }

        Logger.log("[DEBUG] handleWindowDestroyed: windowID=\(windowID), stillExists=\(AccessibilityHelper.windowExists(id: windowID)), groups=\(containingGroups.count)")

        windowObserver.handleDestroyedWindow(
            pid: representativeWindow.ownerPID,
            elementHash: CFHash(representativeWindow.element)
        )

        if AccessibilityHelper.windowExists(id: windowID) {
            // AXUIElement was destroyed but the window is still on-screen.
            // This can happen when apps recreate their AX hierarchy (e.g. web
            // browsers during navigation). Try to re-acquire a fresh element.
            let newElements = AccessibilityHelper.windowElements(for: representativeWindow.ownerPID)
            if let newElement = newElements.first(where: { AccessibilityHelper.windowID(for: $0) == windowID }) {
                setWindowElement(newElement, for: windowID)
                if let refreshedWindow = groupManager.groups(for: windowID)
                    .compactMap({ group in group.windows.first(where: { $0.id == windowID }) })
                    .first {
                    beginObservingWindowIfNeeded(refreshedWindow)
                }
                return
            }
            // Window is in CGWindowList but has no AX element — likely the
            // macOS close animation is still running. Fall through to remove.
            Logger.log("[DEBUG] handleWindowDestroyed: windowID=\(windowID) on-screen but no AX element, removing")
        }

        expectedFrames.removeValue(forKey: windowID)
        removeWindowFromAllGroups(windowID: windowID)
        evaluateAutoCapture()
    }

    func handleTitleChanged(_ windowID: CGWindowID) {
        let containingGroups = groupManager.groups(for: windowID)
        guard !containingGroups.isEmpty,
              let representativeWindow = containingGroups
                .compactMap({ group in group.windows.first(where: { $0.id == windowID }) })
                .first,
              let newTitle = AccessibilityHelper.getTitle(of: representativeWindow.element) else { return }
        for group in containingGroups {
            _ = groupManager.updateWindowTitle(withID: windowID, in: group, to: newTitle)
        }
    }

    @objc func handleAppActivated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        let pid = app.processIdentifier

        guard let windowElement = AccessibilityHelper.focusedWindowElement(forAppPID: pid) else { return }
        guard let windowID = AccessibilityHelper.windowID(for: windowElement) else { return }
        windowInventory.refreshAsync()
        let eventID = nextFocusDiagnosticSequence()

        let commitEchoSuppressed = shouldSuppressCommitEcho(for: windowID)
        let suppressGroupState = switcherController.isActive || commitEchoSuppressed
        Logger.log("[FOCUSDBG] event=\(eventID) type=appActivated app=\(app.localizedName ?? "?") pid=\(pid) window=\(windowID) switcherActive=\(switcherController.isActive) commitEchoSuppressed=\(commitEchoSuppressed) suppressGroupState=\(suppressGroupState) lastActiveGroup=\(lastActiveGroupID?.uuidString ?? "nil")")

        // Record entity-level MRU (skip during active switcher sessions and commit echoes)
        if !suppressGroupState {
            if let group = ownerGroup(for: windowID, source: "appActivated-mru") {
                recordGlobalActivation(.groupWindow(groupID: group.id, windowID: windowID))
            } else {
                recordGlobalActivation(.window(windowID))
            }
        }

        // Group state updates
        guard let group = ownerGroup(for: windowID, source: "appActivated"),
              let panel = tabBarPanels[group.id] else { return }

        // Don't let a fullscreened window become the active tab
        if let w = group.windows.first(where: { $0.id == windowID }), w.isFullscreened { return }

        if !suppressGroupState {
            let previousID = group.activeWindow?.id
            if previousID != windowID {
                Logger.log("[DEBUG] handleAppActivated: switching \(previousID.map(String.init) ?? "nil") → \(windowID) (app=\(app.localizedName ?? "?"), pid=\(pid))")
            }
            group.switchTo(windowID: windowID)
            promoteWindowOwnership(windowID: windowID, group: group)
            if !group.isCycling {
                group.recordFocus(windowID: windowID)
            }
            evaluateAutoCapture()
        }

        guard shouldProcessFocusDrivenPanelOrdering(for: windowID, source: "appActivated#\(eventID)") else {
            Logger.log("[FOCUSDBG] event=\(eventID) type=appActivated panelOrdering=skipped window=\(windowID)")
            return
        }

        if group.spaceID == 0 || SpaceUtils.spaceID(for: windowID) == group.spaceID {
            movePanelToWindowSpace(panel, windowID: windowID)
        }
        Logger.log("[FOCUSDBG] event=\(eventID) type=appActivated panelOrdering=apply window=\(windowID)")
        orderPanelAboveFromFocusEvent(panel, windowID: windowID, source: "appActivated#\(eventID)")
    }

    // MARK: - Space Change Handler

    /// Debounce space-change handling so the animation settles before we query window spaces.
    func scheduleSpaceChangeCheck() {
        spaceChangeWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.handleSpaceChanged()
        }
        spaceChangeWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    func handleSpaceChanged() {
        struct StrayInfo {
            let window: WindowInfo
            let frame: CGRect
            let squeezeDelta: CGFloat
        }
        var straysToRegroup: [StrayInfo] = []

        for group in groupManager.groups {
            guard group.spaceID != 0 else { continue }
            let spaceMap = SpaceUtils.spaceIDs(for: group.managedWindows.map(\.id))

            // If all windows report the same new space, the space ID was reassigned
            // (or a single-tab group was moved). Update the stored ID, don't eject.
            let reportedSpaces = Set(spaceMap.values)
            if reportedSpaces.count == 1,
               let newSpace = reportedSpaces.first,
               newSpace != group.spaceID,
               spaceMap.count == group.managedWindowCount {
                Logger.log("[SPACE] Updating group \(group.id) spaceID \(group.spaceID) → \(newSpace) (all windows moved together)")
                group.spaceID = newSpace
                if let panel = tabBarPanels[group.id], let activeWindow = group.activeWindow {
                    movePanelToWindowSpace(panel, windowID: activeWindow.id)
                }
                continue
            }

            // Find windows whose space differs from the group's space.
            // Windows where the query returned nil are NOT marked stray — the window
            // server may not have settled yet, or the window is mid-transition.
            let strayIDs = group.managedWindows.compactMap { window -> CGWindowID? in
                guard !window.isFullscreened else { return nil }
                guard let windowSpace = spaceMap[window.id],
                      windowSpace != group.spaceID else { return nil }
                return window.id
            }
            guard !strayIDs.isEmpty else { continue }
            Logger.log("[SPACE] Ejecting \(strayIDs.count) stray windows from group \(group.id): \(strayIDs)")

            guard let panel = tabBarPanels[group.id] else { continue }

            let groupFrame = group.frame
            let groupSqueezeDelta = group.tabBarSqueezeDelta
            let strayWindows = group.managedWindows.filter { strayIDs.contains($0.id) }

            for window in strayWindows {
                expectedFrames.removeValue(forKey: window.id)

                // Window will get its own tab bar — keep the squeezed frame
                straysToRegroup.append(StrayInfo(
                    window: window,
                    frame: groupFrame,
                    squeezeDelta: groupSqueezeDelta
                ))
            }

            groupManager.releaseWindows(withIDs: Set(strayIDs), from: group)
            for window in strayWindows {
                stopObservingWindowIfUnused(window)
            }

            if !groupManager.groups.contains(where: { $0.id == group.id }) {
                handleGroupDissolution(group: group, panel: panel)
            } else if let newActive = group.activeWindow {
                // Ensure the panel is on the group's space — a focus event that
                // fired before this handler may have dragged it to the stray's space.
                movePanelToWindowSpace(panel, windowID: newActive.id)
                bringTabToFront(newActive, in: group)
            }
        }

        // Create new single-tab groups for ejected windows on their new space
        for stray in straysToRegroup {
            Logger.log("[SPACE] Creating solo group for ejected window \(stray.window.id)")
            setupGroup(with: [stray.window], frame: stray.frame, squeezeDelta: stray.squeezeDelta)
        }

        evaluateAutoCapture()
    }

    // MARK: - Fullscreen Restoration

    func handleFullscreenExit(windowID: CGWindowID, group: TabGroup) {
        guard let panel = tabBarPanels[group.id],
              group.windows.contains(where: { $0.id == windowID }) else { return }

        Logger.log("[FULLSCREEN] Window \(windowID) exited fullscreen in group \(group.id)")
        setWindowFullscreenState(false, for: windowID)

        // Make this the active tab immediately so the tab bar updates
        group.switchTo(windowID: windowID)
        group.recordFocus(windowID: windowID)
        promoteWindowOwnership(windowID: windowID, group: group)

        // Ensure tab bar is visible (it may have been hidden if all were fullscreened)
        let maximized = isGroupMaximized(group).0
        panel.positionAbove(windowFrame: group.frame, isMaximized: maximized)
        panel.show(above: group.frame, windowID: windowID, isMaximized: maximized)

        // Delay frame restoration — macOS fullscreen exit animation takes ~0.7s.
        // Setting the frame immediately fights the animation and looks janky.
        let groupID = group.id
        let targetFrame = group.frame
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self,
                  let group = self.groupManager.groups.first(where: { $0.id == groupID }),
                  let idx = group.windows.firstIndex(where: { $0.id == windowID }),
                  idx < group.windows.count,
                  !group.windows[idx].isFullscreened else { return }

            let element = group.windows[idx].element
            self.setExpectedFrame(targetFrame, for: [windowID])
            AccessibilityHelper.setFrameAsync(of: element, to: targetFrame)
            self.bringTabToFront(group.windows[idx], in: group)
        }
    }
}
