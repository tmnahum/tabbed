import AppKit
import SwiftUI

// MARK: - Group Lifecycle

extension AppDelegate {

    func focusWindow(_ window: WindowInfo) {
        _ = AccessibilityHelper.raiseWindow(window)
    }

    func showWindowPicker(addingTo group: TabGroup? = nil) {
        dismissWindowPicker()
        windowManager.refreshWindowList()

        let picker = WindowPickerView(
            windowManager: windowManager,
            groupManager: groupManager,
            onCreateGroup: { [weak self] windows in
                self?.createGroup(with: windows)
                self?.dismissWindowPicker()
            },
            onAddToGroup: { [weak self] window in
                guard let group = group else { return }
                self?.addWindow(window, to: group)
                self?.dismissWindowPicker()
            },
            onDismiss: { [weak self] in
                self?.dismissWindowPicker()
            },
            addingToGroup: group
        )

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 350, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.contentView = NSHostingView(rootView: picker)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        windowPickerPanel = panel
    }

    func dismissWindowPicker() {
        windowPickerPanel?.close()
        windowPickerPanel = nil
    }

    func groupAllInSpace() {
        let allWindows = WindowDiscovery.currentSpace()
        let ungrouped = allWindows.filter { !groupManager.isWindowGrouped($0.id) }
        guard !ungrouped.isEmpty else { return }
        createGroup(with: ungrouped)
    }

    func createGroup(with windows: [WindowInfo]) {
        guard let first = windows.first,
              let firstFrame = AccessibilityHelper.getFrame(of: first.element) else { return }

        let windowFrame = clampFrameForTabBar(firstFrame)
        let squeezeDelta = windowFrame.origin.y - firstFrame.origin.y

        guard let group = setupGroup(with: windows, frame: windowFrame, squeezeDelta: squeezeDelta) else { return }
        if let activeWindow = group.activeWindow {
            raiseAndUpdate(activeWindow, in: group)
            if let panel = tabBarPanels[group.id] {
                panel.orderAbove(windowID: activeWindow.id)
            }
        }
    }

    @discardableResult
    func setupGroup(
        with windows: [WindowInfo],
        frame: CGRect,
        squeezeDelta: CGFloat,
        activeIndex: Int = 0
    ) -> TabGroup? {
        guard let group = groupManager.createGroup(with: windows, frame: frame) else { return nil }
        group.tabBarSqueezeDelta = squeezeDelta
        group.switchTo(index: activeIndex)

        setExpectedFrame(frame, for: group.windows.map(\.id))

        for window in group.windows {
            AccessibilityHelper.setFrame(of: window.element, to: frame)
        }

        let panel = TabBarPanel()
        panel.setContent(
            group: group,
            onSwitchTab: { [weak self, weak panel] index in
                guard let panel else { return }
                self?.switchTab(in: group, to: index, panel: panel)
            },
            onReleaseTab: { [weak self, weak panel] index in
                guard let panel else { return }
                self?.releaseTab(at: index, from: group, panel: panel)
            },
            onAddWindow: { [weak self] in
                self?.showWindowPicker(addingTo: group)
            }
        )

        tabBarPanels[group.id] = panel

        for window in group.windows {
            windowObserver.observe(window: window)
        }

        if let activeWindow = group.activeWindow {
            panel.show(above: frame, windowID: activeWindow.id)
            panel.orderAbove(windowID: activeWindow.id)
            movePanelToWindowSpace(panel, windowID: activeWindow.id)
        }

        let groupID = group.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self,
                  let group = self.groupManager.groups.first(where: { $0.id == groupID }),
                  let panel = self.tabBarPanels[groupID],
                  let activeWindow = group.activeWindow,
                  let actualFrame = AccessibilityHelper.getFrame(of: activeWindow.element) else { return }

            let visibleFrame = CoordinateConverter.visibleFrameInAX(at: actualFrame.origin)
            let result = ScreenCompensation.clampResult(frame: actualFrame, visibleFrame: visibleFrame)
            let clamped = result.frame
            if !self.framesMatch(clamped, group.frame) {
                if clamped != actualFrame {
                    self.setExpectedFrame(clamped, for: [activeWindow.id])
                    AccessibilityHelper.setFrame(of: activeWindow.element, to: clamped)
                }
                group.frame = clamped
                group.tabBarSqueezeDelta = result.squeezeDelta
                let others = group.windows.filter { $0.id != activeWindow.id }
                if !others.isEmpty {
                    self.setExpectedFrame(clamped, for: others.map(\.id))
                    for window in others {
                        AccessibilityHelper.setFrame(of: window.element, to: clamped)
                    }
                }
            }
            panel.positionAbove(windowFrame: group.frame)
            panel.orderAbove(windowID: activeWindow.id)
            self.movePanelToWindowSpace(panel, windowID: activeWindow.id)
        }

        evaluateAutoCapture()
        return group
    }

    func raiseAndUpdate(_ window: WindowInfo, in group: TabGroup) {
        if let freshElement = AccessibilityHelper.raiseWindow(window) {
            if let idx = group.windows.firstIndex(where: { $0.id == window.id }) {
                group.windows[idx].element = freshElement
            }
        }
    }

    /// Move the tab bar panel to the same Space as the given window, if they differ.
    func movePanelToWindowSpace(_ panel: TabBarPanel, windowID: CGWindowID) {
        guard panel.windowNumber > 0 else { return }
        let conn = CGSMainConnectionID()
        let panelWID = CGWindowID(panel.windowNumber)

        let windowSpaces = CGSCopySpacesForWindows(conn, 0x7, [windowID] as CFArray) as? [UInt64] ?? []
        guard let targetSpace = windowSpaces.first else { return }

        let panelSpaces = CGSCopySpacesForWindows(conn, 0x7, [panelWID] as CFArray) as? [UInt64] ?? []
        if panelSpaces.first == targetSpace { return }

        CGSMoveWindowsToManagedSpace(conn, [panelWID] as CFArray, targetSpace)
    }

    func switchTab(in group: TabGroup, to index: Int, panel: TabBarPanel) {
        let previousID = group.activeWindow?.id
        group.switchTo(index: index)
        guard let window = group.activeWindow else { return }
        Logger.log("[DEBUG] switchTab: \(previousID.map(String.init) ?? "nil") → \(window.id) (index=\(index))")
        lastActiveGroupID = group.id
        if !group.isCycling {
            group.recordFocus(windowID: window.id)
        }
        setExpectedFrame(group.frame, for: [window.id])
        AccessibilityHelper.setFrame(of: window.element, to: group.frame)

        raiseAndUpdate(window, in: group)
        panel.orderAbove(windowID: window.id)
    }

    func releaseTab(at index: Int, from group: TabGroup, panel: TabBarPanel) {
        guard let window = group.windows[safe: index] else { return }

        windowObserver.stopObserving(window: window)
        expectedFrames.removeValue(forKey: window.id)

        groupManager.releaseWindow(withID: window.id, from: group)

        if !groupManager.groups.contains(where: { $0.id == group.id }) {
            handleGroupDissolution(group: group, panel: panel)
        } else if let newActive = group.activeWindow {
            raiseAndUpdate(newActive, in: group)
            panel.orderAbove(windowID: newActive.id)
        }
        evaluateAutoCapture()
    }

    func addWindow(_ window: WindowInfo, to group: TabGroup) {
        globalMRU.removeAll { $0 == .window(window.id) }
        setExpectedFrame(group.frame, for: [window.id])
        AccessibilityHelper.setFrame(of: window.element, to: group.frame)
        groupManager.addWindow(window, to: group)
        windowObserver.observe(window: window)

        let newIndex = group.windows.count - 1
        group.switchTo(index: newIndex)
        lastActiveGroupID = group.id
        raiseAndUpdate(window, in: group)
        if let panel = tabBarPanels[group.id] {
            panel.orderAbove(windowID: window.id)
        }
        evaluateAutoCapture()
    }

    func handleGroupDissolution(group: TabGroup, panel: TabBarPanel) {
        if autoCaptureGroup === group { deactivateAutoCapture() }
        if lastActiveGroupID == group.id { lastActiveGroupID = nil }
        globalMRU.removeAll { $0 == .group(group.id) }

        if cyclingGroup === group { cyclingGroup = nil }
        resyncWorkItems[group.id]?.cancel()
        resyncWorkItems.removeValue(forKey: group.id)
        for window in group.windows { expectedFrames.removeValue(forKey: window.id) }

        if let lastWindow = group.windows.first {
            windowObserver.stopObserving(window: lastWindow)
            if group.tabBarSqueezeDelta > 0, let lastFrame = AccessibilityHelper.getFrame(of: lastWindow.element) {
                let expandedFrame = ScreenCompensation.expandFrame(lastFrame, undoingSqueezeDelta: group.tabBarSqueezeDelta)
                AccessibilityHelper.setFrame(of: lastWindow.element, to: expandedFrame)
            }
        }
        panel.close()
        tabBarPanels.removeValue(forKey: group.id)
    }

    func disbandGroup(_ group: TabGroup) {
        guard let panel = tabBarPanels[group.id] else { return }

        if autoCaptureGroup === group { deactivateAutoCapture() }
        if lastActiveGroupID == group.id { lastActiveGroupID = nil }
        globalMRU.removeAll { $0 == .group(group.id) }

        if cyclingGroup === group { cyclingGroup = nil }
        resyncWorkItems[group.id]?.cancel()
        resyncWorkItems.removeValue(forKey: group.id)
        for window in group.windows { expectedFrames.removeValue(forKey: window.id) }

        for window in group.windows {
            windowObserver.stopObserving(window: window)
            if group.tabBarSqueezeDelta > 0, let frame = AccessibilityHelper.getFrame(of: window.element) {
                let expandedFrame = ScreenCompensation.expandFrame(frame, undoingSqueezeDelta: group.tabBarSqueezeDelta)
                AccessibilityHelper.setFrame(of: window.element, to: expandedFrame)
            }
        }

        groupManager.dissolveGroup(group)
        panel.close()
        tabBarPanels.removeValue(forKey: group.id)
    }

    /// Resolve the group the user is currently interacting with.
    func activeGroup() -> (TabGroup, TabBarPanel)? {
        if let id = lastActiveGroupID,
           let group = groupManager.groups.first(where: { $0.id == id }),
           let panel = tabBarPanels[id] {
            return (group, panel)
        }
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AccessibilityHelper.appElement(for: frontApp.processIdentifier)
        var focusedValue: AnyObject?
        let result = AXUIElementCopyAttributeValue(
            appElement, kAXFocusedWindowAttribute as CFString, &focusedValue
        )
        guard result == .success, let ref = focusedValue else { return nil }
        let element = ref as! AXUIElement // swiftlint:disable:this force_cast
        guard let windowID = AccessibilityHelper.windowID(for: element),
              let group = groupManager.group(for: windowID),
              let panel = tabBarPanels[group.id] else { return nil }
        return (group, panel)
    }

    func handleHotkeyNewTab() {
        let result = activeGroup()
        Logger.log("[HK] handleHotkeyNewTab called — activeGroup=\(result != nil)")
        guard let (group, _) = result else { return }
        Logger.log("[HK] showing window picker for group \(group.id)")
        showWindowPicker(addingTo: group)
    }

    func handleHotkeyReleaseTab() {
        guard let (group, panel) = activeGroup() else { return }
        releaseTab(at: group.activeIndex, from: group, panel: panel)
    }

    func handleHotkeySwitchToTab(_ index: Int) {
        guard let (group, panel) = activeGroup(),
              index >= 0, !group.windows.isEmpty else { return }
        let targetIndex = (index == 8) ? group.windows.count - 1 : index
        guard targetIndex < group.windows.count else { return }
        switchTab(in: group, to: targetIndex, panel: panel)
    }

    @objc func handleAppTerminated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        let pid = app.processIdentifier

        for group in groupManager.groups {
            let affectedWindows = group.windows.filter { $0.ownerPID == pid }
            for window in affectedWindows {
                globalMRU.removeAll { $0 == .window(window.id) }
                expectedFrames.removeValue(forKey: window.id)
                windowObserver.handleDestroyedWindow(pid: pid, elementHash: CFHash(window.element))
                groupManager.releaseWindow(withID: window.id, from: group)
            }
            if !groupManager.groups.contains(where: { $0.id == group.id }),
               let panel = tabBarPanels[group.id] {
                if let survivor = group.windows.first, survivor.ownerPID != pid {
                    handleGroupDissolution(group: group, panel: panel)
                } else {
                    if cyclingGroup === group { cyclingGroup = nil }
                    panel.close()
                    tabBarPanels.removeValue(forKey: group.id)
                }
            } else if let panel = tabBarPanels[group.id],
                      let newActive = group.activeWindow {
                raiseAndUpdate(newActive, in: group)
                panel.orderAbove(windowID: newActive.id)
            }
        }
    }
}
