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
            AccessibilityHelper.setPosition(of: element, to: targetFrame.origin)
            return (targetFrame, existingSqueezeDelta)
        }

        // First-time squeeze: push position down and shrink height.
        Logger.log("[CLAMP] squeeze wid=\(windowID) frame=\(frame) → \(result.frame) delta=\(result.squeezeDelta)")
        setExpectedFrame(result.frame, for: [windowID])
        AccessibilityHelper.setFrame(of: element, to: result.frame)

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
            AccessibilityHelper.setPosition(of: element, to: target.origin)
        }

        return (result.frame, delta)
    }
}

// MARK: - Window Event Handlers

extension AppDelegate {

    func handleWindowMoved(_ windowID: CGWindowID) {
        guard let group = groupManager.group(for: windowID),
              let panel = tabBarPanels[group.id],
              let activeWindow = group.activeWindow,
              activeWindow.id == windowID,
              let frame = AccessibilityHelper.getFrame(of: activeWindow.element) else { return }

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
            element: activeWindow.element, windowID: windowID,
            frame: frame, visibleFrame: visibleFrame,
            existingSqueezeDelta: existingSqueeze
        )

        group.frame = adjustedFrame
        group.tabBarSqueezeDelta = squeezeDelta

        let others = group.visibleWindows.filter { $0.id != windowID }
        setExpectedFrame(adjustedFrame, for: others.map(\.id))
        for window in others {
            AccessibilityHelper.setFrame(of: window.element, to: adjustedFrame)
        }

        panel.positionAbove(windowFrame: adjustedFrame, isMaximized: isGroupMaximized(group).0)
        panel.orderAbove(windowID: activeWindow.id)
        evaluateAutoCapture()
    }

    func handleWindowResized(_ windowID: CGWindowID) {
        // Check if a fullscreened window is exiting fullscreen.
        // This runs before the main guard because the fullscreened window
        // won't be the activeWindow (a visible tab is active instead).
        if let group = groupManager.group(for: windowID),
           let idx = group.windows.firstIndex(where: { $0.id == windowID }),
           idx < group.windows.count,
           group.windows[idx].isFullscreened {
            // Capture window reference safely to avoid multiple array accesses
            let window = group.windows[idx]
            if !AccessibilityHelper.isFullScreen(window.element) {
                handleFullscreenExit(windowID: windowID, group: group)
            }
            return
        }

        guard let group = groupManager.group(for: windowID),
              let panel = tabBarPanels[group.id],
              let activeWindow = group.activeWindow,
              activeWindow.id == windowID,
              let frame = AccessibilityHelper.getFrame(of: activeWindow.element) else { return }

        if barDraggingGroupID == group.id { return }
        if shouldSuppress(windowID: windowID, currentFrame: frame) { return }

        if AccessibilityHelper.isFullScreen(activeWindow.element) {
            Logger.log("[FULLSCREEN] Window \(windowID) entered fullscreen in group \(group.id)")
            expectedFrames.removeValue(forKey: windowID)
            if let idx = group.windows.firstIndex(where: { $0.id == windowID }) {
                group.windows[idx].isFullscreened = true
            }
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
            element: activeWindow.element, windowID: windowID,
            frame: frame, visibleFrame: visibleFrame,
            existingSqueezeDelta: existingSqueeze
        )

        group.frame = adjustedFrame
        group.tabBarSqueezeDelta = squeezeDelta

        let others = group.visibleWindows.filter { $0.id != windowID }
        setExpectedFrame(adjustedFrame, for: others.map(\.id))
        for window in others {
            AccessibilityHelper.setFrame(of: window.element, to: adjustedFrame)
        }

        panel.positionAbove(windowFrame: adjustedFrame, isMaximized: isGroupMaximized(group).0)
        panel.orderAbove(windowID: activeWindow.id)
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
                AccessibilityHelper.setFrame(of: window.element, to: clamped)
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
              let group = groupManager.group(for: windowID),
              let panel = tabBarPanels[group.id] else { return }

        // Don't let a fullscreened window become the active tab —
        // it would confuse frame sync since it's on a different Space.
        if let w = group.windows.first(where: { $0.id == windowID }), w.isFullscreened { return }

        // During an active switcher session or commit-echo suppression,
        // don't let OS focus events mutate group state — the switcher
        // owns the selection, and post-commit events are echoes of our
        // own raiseWindow/activate calls.
        let suppressGroupState = switcherController.isActive || shouldSuppressCommitEcho(for: windowID)
        if !suppressGroupState {
            let previousID = group.activeWindow?.id
            if previousID != windowID {
                Logger.log("[DEBUG] handleWindowFocused: switching \(previousID.map(String.init) ?? "nil") → \(windowID) (pid=\(pid))")
            }
            group.switchTo(windowID: windowID)
            lastActiveGroupID = group.id
            if !group.isCycling {
                group.recordFocus(windowID: windowID)
            }
            evaluateAutoCapture()
        }

        // Don't drag the group's panel to a different space — the window is about
        // to be ejected by the space-change handler and will get its own group.
        if group.spaceID == 0 || SpaceUtils.spaceID(for: windowID) == group.spaceID {
            movePanelToWindowSpace(panel, windowID: windowID)
        }
        panel.orderAbove(windowID: windowID)
        // Re-order after a delay — when the OS raises a window (dock click, Cmd-Tab,
        // third-party switcher), its reordering may finish after our orderAbove call.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak panel] in
            panel?.orderAbove(windowID: windowID)
        }
    }

    func handleWindowDestroyed(_ windowID: CGWindowID) {
        mruTracker.removeWindow(windowID)
        guard let group = groupManager.group(for: windowID),
              let panel = tabBarPanels[group.id],
              let window = group.windows.first(where: { $0.id == windowID }) else { return }

        Logger.log("[DEBUG] handleWindowDestroyed: windowID=\(windowID), stillExists=\(AccessibilityHelper.windowExists(id: windowID)), activeID=\(group.activeWindow.map { String($0.id) } ?? "nil")")

        windowObserver.handleDestroyedWindow(pid: window.ownerPID, elementHash: CFHash(window.element))

        if AccessibilityHelper.windowExists(id: windowID) {
            // AXUIElement was destroyed but the window is still on-screen.
            // This can happen when apps recreate their AX hierarchy (e.g. web
            // browsers during navigation). Try to re-acquire a fresh element.
            let newElements = AccessibilityHelper.windowElements(for: window.ownerPID)
            if let newElement = newElements.first(where: { AccessibilityHelper.windowID(for: $0) == windowID }),
               let index = group.windows.firstIndex(where: { $0.id == windowID }) {
                group.windows[index].element = newElement
                windowObserver.observe(window: group.windows[index])
                return
            }
            // Window is in CGWindowList but has no AX element — likely the
            // macOS close animation is still running. Fall through to remove.
            Logger.log("[DEBUG] handleWindowDestroyed: windowID=\(windowID) on-screen but no AX element, removing")
        }

        removeDestroyedWindow(windowID, from: group, panel: panel)
    }

    private func removeDestroyedWindow(_ windowID: CGWindowID, from group: TabGroup, panel: TabBarPanel) {
        expectedFrames.removeValue(forKey: windowID)
        groupManager.releaseWindow(withID: windowID, from: group)

        if !groupManager.groups.contains(where: { $0.id == group.id }) {
            handleGroupDissolution(group: group, panel: panel)
        } else if let newActive = group.activeWindow {
            bringTabToFront(newActive, in: group)
        }
        evaluateAutoCapture()
    }

    func handleTitleChanged(_ windowID: CGWindowID) {
        guard let group = groupManager.group(for: windowID) else { return }
        if let index = group.windows.firstIndex(where: { $0.id == windowID }),
           let newTitle = AccessibilityHelper.getTitle(of: group.windows[index].element) {
            groupManager.updateWindowTitle(withID: windowID, in: group, to: newTitle)
        }
    }

    @objc func handleAppActivated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        let pid = app.processIdentifier

        let appElement = AccessibilityHelper.appElement(for: pid)
        var focusedValue: AnyObject?
        let result = AXUIElementCopyAttributeValue(
            appElement, kAXFocusedWindowAttribute as CFString, &focusedValue
        )
        guard result == .success,
              let focusedRef = focusedValue else { return }
        let windowElement = focusedRef as! AXUIElement // swiftlint:disable:this force_cast
        guard let windowID = AccessibilityHelper.windowID(for: windowElement) else { return }
        windowInventory.refreshAsync()

        let suppressGroupState = switcherController.isActive || shouldSuppressCommitEcho(for: windowID)

        // Record entity-level MRU (skip during active switcher sessions and commit echoes)
        if !suppressGroupState {
            if let group = groupManager.group(for: windowID) {
                recordGlobalActivation(.groupWindow(groupID: group.id, windowID: windowID))
            } else {
                recordGlobalActivation(.window(windowID))
            }
        }

        // Group state updates
        guard let group = groupManager.group(for: windowID),
              let panel = tabBarPanels[group.id] else { return }

        // Don't let a fullscreened window become the active tab
        if let w = group.windows.first(where: { $0.id == windowID }), w.isFullscreened { return }

        if !suppressGroupState {
            let previousID = group.activeWindow?.id
            if previousID != windowID {
                Logger.log("[DEBUG] handleAppActivated: switching \(previousID.map(String.init) ?? "nil") → \(windowID) (app=\(app.localizedName ?? "?"), pid=\(pid))")
            }
            group.switchTo(windowID: windowID)
            lastActiveGroupID = group.id
            if !group.isCycling {
                group.recordFocus(windowID: windowID)
            }
            evaluateAutoCapture()
        }

        if group.spaceID == 0 || SpaceUtils.spaceID(for: windowID) == group.spaceID {
            movePanelToWindowSpace(panel, windowID: windowID)
        }
        panel.orderAbove(windowID: windowID)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak panel] in
            panel?.orderAbove(windowID: windowID)
        }
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

            for windowID in strayIDs {
                guard let window = group.managedWindows.first(where: { $0.id == windowID }) else { continue }
                windowObserver.stopObserving(window: window)
                expectedFrames.removeValue(forKey: window.id)

                // Window will get its own tab bar — keep the squeezed frame
                straysToRegroup.append(StrayInfo(
                    window: window,
                    frame: groupFrame,
                    squeezeDelta: groupSqueezeDelta
                ))
            }

            groupManager.releaseWindows(withIDs: Set(strayIDs), from: group)

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
              let idx = group.windows.firstIndex(where: { $0.id == windowID }),
              idx < group.windows.count else { return }

        Logger.log("[FULLSCREEN] Window \(windowID) exited fullscreen in group \(group.id)")
        group.windows[idx].isFullscreened = false

        // Make this the active tab immediately so the tab bar updates
        group.switchTo(windowID: windowID)
        group.recordFocus(windowID: windowID)
        lastActiveGroupID = group.id

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
            AccessibilityHelper.setFrame(of: element, to: targetFrame)
            self.bringTabToFront(group.windows[idx], in: group)
        }
    }
}
