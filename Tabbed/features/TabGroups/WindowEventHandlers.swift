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

        let visibleFrame = CoordinateConverter.visibleFrameInAX(at: frame.origin)
        let (adjustedFrame, squeezeDelta) = applyClamp(
            element: activeWindow.element, windowID: windowID,
            frame: frame, visibleFrame: visibleFrame,
            existingSqueezeDelta: group.tabBarSqueezeDelta
        )

        group.frame = adjustedFrame
        group.tabBarSqueezeDelta = squeezeDelta

        let others = group.visibleWindows.filter { $0.id != windowID }
        setExpectedFrame(adjustedFrame, for: others.map(\.id))
        for window in others {
            AccessibilityHelper.setFrame(of: window.element, to: adjustedFrame)
        }

        panel.positionAbove(windowFrame: adjustedFrame)
        panel.orderAbove(windowID: activeWindow.id)
        evaluateAutoCapture()
    }

    func handleWindowResized(_ windowID: CGWindowID) {
        // Check if a fullscreened window is exiting fullscreen.
        // This runs before the main guard because the fullscreened window
        // won't be the activeWindow (a visible tab is active instead).
        if let group = groupManager.group(for: windowID),
           let idx = group.windows.firstIndex(where: { $0.id == windowID }),
           group.windows[idx].isFullscreened {
            if !AccessibilityHelper.isFullScreen(group.windows[idx].element) {
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
            return
        }

        // If the height actually changed (e.g. macOS title bar zoom), reset
        // squeeze delta so applyClamp performs a fresh full clamp rather than
        // just re-pushing position (which would leave the window extending
        // below the visible area).
        let existingSqueeze: CGFloat
        if abs(frame.height - group.frame.height) > Self.frameTolerance {
            existingSqueeze = 0
        } else {
            existingSqueeze = group.tabBarSqueezeDelta
        }

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

        panel.positionAbove(windowFrame: adjustedFrame)
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

            let visibleFrame = CoordinateConverter.visibleFrameInAX(at: currentFrame.origin)
            let (clamped, squeezeDelta) = self.applyClamp(
                element: activeWindow.element, windowID: activeWindow.id,
                frame: currentFrame, visibleFrame: visibleFrame,
                existingSqueezeDelta: group.tabBarSqueezeDelta
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
            panel.positionAbove(windowFrame: clamped)
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

        // During an active switcher session or post-commit cooldown,
        // don't let OS focus events mutate group state — the switcher
        // owns the selection, and post-commit events are echoes of our
        // own raiseWindow/activate calls.
        if !switcherController.isActive, !isCycleCooldownActive {
            let previousID = group.activeWindow?.id
            if previousID != windowID {
                Logger.log("[DEBUG] handleWindowFocused: switching \(previousID.map(String.init) ?? "nil") → \(windowID) (pid=\(pid))")
            }
            group.switchTo(windowID: windowID)
            lastActiveGroupID = group.id
            if !group.isCycling {
                group.recordFocus(windowID: windowID)
            }
        }

        movePanelToWindowSpace(panel, windowID: windowID)
        panel.orderAbove(windowID: windowID)
        // Re-order after a delay — when the OS raises a window (dock click, Cmd-Tab,
        // third-party switcher), its reordering may finish after our orderAbove call.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak panel] in
            panel?.orderAbove(windowID: windowID)
        }
    }

    func handleWindowDestroyed(_ windowID: CGWindowID) {
        globalMRU.removeAll { $0 == .window(windowID) }
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
            group.windows[index].title = newTitle
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

        let suppressGroupState = switcherController.isActive || isCycleCooldownActive

        // Record entity-level MRU (skip during active switcher sessions and cooldown)
        if !suppressGroupState {
            if let group = groupManager.group(for: windowID) {
                recordGlobalActivation(.group(group.id))
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
        }

        movePanelToWindowSpace(panel, windowID: windowID)
        panel.orderAbove(windowID: windowID)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak panel] in
            panel?.orderAbove(windowID: windowID)
        }
    }

    // MARK: - Space Change Handler

    func handleSpaceChanged() {
        for group in groupManager.groups {
            guard group.spaceID != 0 else { continue }
            let spaceMap = SpaceUtils.spaceIDs(for: group.windows.map(\.id))
            let strayIDs = group.windows.compactMap { window -> CGWindowID? in
                guard !window.isFullscreened else { return nil }
                guard let windowSpace = spaceMap[window.id],
                      windowSpace != group.spaceID else { return nil }
                return window.id
            }
            guard !strayIDs.isEmpty else { continue }
            Logger.log("[SPACE] Ejecting \(strayIDs.count) stray windows from group \(group.id): \(strayIDs)")

            guard let panel = tabBarPanels[group.id] else { continue }

            for windowID in strayIDs {
                guard let window = group.windows.first(where: { $0.id == windowID }) else { continue }
                windowObserver.stopObserving(window: window)
                expectedFrames.removeValue(forKey: window.id)

                // Expand the ejected window to cover tab bar space
                if let frame = AccessibilityHelper.getFrame(of: window.element) {
                    let delta = max(group.tabBarSqueezeDelta, ScreenCompensation.tabBarHeight)
                    let expanded = ScreenCompensation.expandFrame(frame, undoingSqueezeDelta: delta)
                    AccessibilityHelper.setSize(of: window.element, to: expanded.size)
                    AccessibilityHelper.setPosition(of: window.element, to: expanded.origin)
                }
            }

            groupManager.releaseWindows(withIDs: Set(strayIDs), from: group)

            if !groupManager.groups.contains(where: { $0.id == group.id }) {
                handleGroupDissolution(group: group, panel: panel)
            } else if let newActive = group.activeWindow {
                bringTabToFront(newActive, in: group)
            }
        }
        evaluateAutoCapture()
    }

    // MARK: - Fullscreen Restoration

    func handleFullscreenExit(windowID: CGWindowID, group: TabGroup) {
        guard let panel = tabBarPanels[group.id],
              let idx = group.windows.firstIndex(where: { $0.id == windowID }) else { return }

        Logger.log("[FULLSCREEN] Window \(windowID) exited fullscreen in group \(group.id)")
        group.windows[idx].isFullscreened = false

        // Make this the active tab immediately so the tab bar updates
        group.switchTo(windowID: windowID)
        group.recordFocus(windowID: windowID)
        lastActiveGroupID = group.id

        // Ensure tab bar is visible (it may have been hidden if all were fullscreened)
        panel.positionAbove(windowFrame: group.frame)
        panel.show(above: group.frame, windowID: windowID)

        // Delay frame restoration — macOS fullscreen exit animation takes ~0.7s.
        // Setting the frame immediately fights the animation and looks janky.
        let groupID = group.id
        let targetFrame = group.frame
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self,
                  let group = self.groupManager.groups.first(where: { $0.id == groupID }),
                  let idx = group.windows.firstIndex(where: { $0.id == windowID }),
                  !group.windows[idx].isFullscreened else { return }

            let element = group.windows[idx].element
            self.setExpectedFrame(targetFrame, for: [windowID])
            AccessibilityHelper.setFrame(of: element, to: targetFrame)
            self.bringTabToFront(group.windows[idx], in: group)
        }
    }
}
