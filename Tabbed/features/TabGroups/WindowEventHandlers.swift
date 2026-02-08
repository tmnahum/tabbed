import AppKit

// MARK: - Window Event Handlers

extension AppDelegate {

    func handleWindowMoved(_ windowID: CGWindowID) {
        guard let group = groupManager.group(for: windowID),
              let panel = tabBarPanels[group.id],
              let activeWindow = group.activeWindow,
              activeWindow.id == windowID,
              let frame = AccessibilityHelper.getFrame(of: activeWindow.element) else { return }

        if shouldSuppress(windowID: windowID, currentFrame: frame) { return }

        let adjustedFrame = clampFrameForTabBar(frame)
        if adjustedFrame != frame {
            setExpectedFrame(adjustedFrame, for: [windowID])
            AccessibilityHelper.setFrame(of: activeWindow.element, to: adjustedFrame)
        }

        group.frame = adjustedFrame
        if adjustedFrame.origin.y != frame.origin.y {
            group.tabBarSqueezeDelta = adjustedFrame.origin.y - frame.origin.y
        }

        let otherIDs = group.windows.filter { $0.id != windowID }.map(\.id)
        setExpectedFrame(adjustedFrame, for: otherIDs)
        for window in group.windows where window.id != windowID {
            AccessibilityHelper.setFrame(of: window.element, to: adjustedFrame)
        }

        panel.positionAbove(windowFrame: adjustedFrame)
        panel.orderAbove(windowID: activeWindow.id)
        evaluateAutoCapture()
    }

    func handleWindowResized(_ windowID: CGWindowID) {
        guard let group = groupManager.group(for: windowID),
              let panel = tabBarPanels[group.id],
              let activeWindow = group.activeWindow,
              activeWindow.id == windowID,
              let frame = AccessibilityHelper.getFrame(of: activeWindow.element) else { return }

        if shouldSuppress(windowID: windowID, currentFrame: frame) { return }

        if AccessibilityHelper.isFullScreen(activeWindow.element) {
            expectedFrames.removeValue(forKey: windowID)
            windowObserver.stopObserving(window: activeWindow)
            groupManager.releaseWindow(withID: windowID, from: group)
            if !groupManager.groups.contains(where: { $0.id == group.id }) {
                handleGroupDissolution(group: group, panel: panel)
            } else if let newActive = group.activeWindow {
                raiseAndUpdate(newActive, in: group)
                panel.orderAbove(windowID: newActive.id)
            }
            return
        }

        let adjustedFrame = clampFrameForTabBar(frame)
        if adjustedFrame != frame {
            setExpectedFrame(adjustedFrame, for: [windowID])
            AccessibilityHelper.setFrame(of: activeWindow.element, to: adjustedFrame)
        }

        group.frame = adjustedFrame
        if adjustedFrame.origin.y != frame.origin.y {
            group.tabBarSqueezeDelta = adjustedFrame.origin.y - frame.origin.y
        }

        let otherIDs = group.windows.filter { $0.id != windowID }.map(\.id)
        setExpectedFrame(adjustedFrame, for: otherIDs)
        for window in group.windows where window.id != windowID {
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

            let clamped = self.clampFrameForTabBar(currentFrame)
            guard clamped != group.frame else { return }

            if clamped != currentFrame {
                self.setExpectedFrame(clamped, for: [activeWindow.id])
                AccessibilityHelper.setFrame(of: activeWindow.element, to: clamped)
            }
            group.frame = clamped
            let others = group.windows.filter { $0.id != activeWindow.id }
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

        let previousID = group.activeWindow?.id
        if previousID != windowID {
            Logger.log("[DEBUG] handleWindowFocused: switching \(previousID.map(String.init) ?? "nil") → \(windowID) (pid=\(pid))")
        }
        group.switchTo(windowID: windowID)
        lastActiveGroupID = group.id
        if !group.isCycling, !isCycleCooldownActive {
            group.recordFocus(windowID: windowID)
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
        guard let group = groupManager.group(for: windowID),
              let panel = tabBarPanels[group.id],
              let window = group.windows.first(where: { $0.id == windowID }) else { return }

        Logger.log("[DEBUG] handleWindowDestroyed: windowID=\(windowID), stillExists=\(AccessibilityHelper.windowExists(id: windowID)), activeID=\(group.activeWindow.map { String($0.id) } ?? "nil")")

        windowObserver.handleDestroyedWindow(pid: window.ownerPID, elementHash: CFHash(window.element))

        if AccessibilityHelper.windowExists(id: windowID) {
            let newElements = AccessibilityHelper.windowElements(for: window.ownerPID)
            if let newElement = newElements.first(where: { AccessibilityHelper.windowID(for: $0) == windowID }),
               let index = group.windows.firstIndex(where: { $0.id == windowID }) {
                group.windows[index].element = newElement
                windowObserver.observe(window: group.windows[index])
            }
            return
        }

        expectedFrames.removeValue(forKey: windowID)
        groupManager.releaseWindow(withID: windowID, from: group)

        if !groupManager.groups.contains(where: { $0.id == group.id }) {
            handleGroupDissolution(group: group, panel: panel)
        } else if let newActive = group.activeWindow {
            raiseAndUpdate(newActive, in: group)
            panel.orderAbove(windowID: newActive.id)
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

        recordGlobalActivation(pid: pid)

        let appElement = AccessibilityHelper.appElement(for: pid)
        var focusedValue: AnyObject?
        let result = AXUIElementCopyAttributeValue(
            appElement, kAXFocusedWindowAttribute as CFString, &focusedValue
        )
        guard result == .success,
              let focusedRef = focusedValue else { return }
        let windowElement = focusedRef as! AXUIElement // swiftlint:disable:this force_cast

        guard let windowID = AccessibilityHelper.windowID(for: windowElement),
              let group = groupManager.group(for: windowID),
              let panel = tabBarPanels[group.id] else { return }

        let previousID = group.activeWindow?.id
        if previousID != windowID {
            Logger.log("[DEBUG] handleAppActivated: switching \(previousID.map(String.init) ?? "nil") → \(windowID) (app=\(app.localizedName ?? "?"), pid=\(pid))")
        }
        group.switchTo(windowID: windowID)
        lastActiveGroupID = group.id
        if !group.isCycling, !isCycleCooldownActive {
            group.recordFocus(windowID: windowID)
        }
        movePanelToWindowSpace(panel, windowID: windowID)
        panel.orderAbove(windowID: windowID)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak panel] in
            panel?.orderAbove(windowID: windowID)
        }
    }
}
