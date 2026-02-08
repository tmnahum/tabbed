import AppKit
import SwiftUI

// MARK: - Group Lifecycle

extension AppDelegate {

    func focusWindow(_ window: WindowInfo) {
        if let freshElement = AccessibilityHelper.raiseWindow(window),
           let group = groupManager.group(for: window.id),
           let idx = group.windows.firstIndex(where: { $0.id == window.id }) {
            group.windows[idx].element = freshElement
        }
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
            onMergeGroup: { [weak self] sourceGroup in
                guard let group = group else { return }
                self?.mergeGroup(sourceGroup, into: group)
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

        let visibleFrame = CoordinateConverter.visibleFrameInAX(at: firstFrame.origin)
        let (windowFrame, squeezeDelta) = applyClamp(
            element: first.element, windowID: first.id,
            frame: firstFrame, visibleFrame: visibleFrame
        )

        guard let group = setupGroup(with: windows, frame: windowFrame, squeezeDelta: squeezeDelta) else { return }
        if let activeWindow = group.activeWindow {
            bringTabToFront(activeWindow, in: group)
        }
    }

    @discardableResult
    func setupGroup(
        with windows: [WindowInfo],
        frame: CGRect,
        squeezeDelta: CGFloat,
        activeIndex: Int = 0
    ) -> TabGroup? {
        let spaceID = windows.first.flatMap { SpaceUtils.spaceID(for: $0.id) } ?? 0
        guard let group = groupManager.createGroup(with: windows, frame: frame, spaceID: spaceID) else { return nil }
        Logger.log("[SPACE] Created group \(group.id) on space \(spaceID)")
        group.tabBarSqueezeDelta = squeezeDelta
        group.switchTo(index: activeIndex)

        setExpectedFrame(frame, for: group.windows.map(\.id))

        for window in group.windows {
            AccessibilityHelper.setFrame(of: window.element, to: frame)
        }

        let panel = TabBarPanel()
        panel.setContent(
            group: group,
            tabBarConfig: tabBarConfig,
            onSwitchTab: { [weak self, weak panel] index in
                guard let panel else { return }
                self?.switchTab(in: group, to: index, panel: panel)
            },
            onReleaseTab: { [weak self, weak panel] index in
                guard let panel else { return }
                self?.releaseTab(at: index, from: group, panel: panel)
            },
            onCloseTab: { [weak self, weak panel] index in
                guard let panel else { return }
                self?.closeTab(at: index, from: group, panel: panel)
            },
            onAddWindow: { [weak self] in
                self?.showWindowPicker(addingTo: group)
            },
            onReleaseTabs: { [weak self, weak panel] ids in
                guard let panel else { return }
                self?.releaseTabs(withIDs: ids, from: group, panel: panel)
            },
            onMoveToNewGroup: { [weak self, weak panel] ids in
                guard let panel else { return }
                self?.moveTabsToNewGroup(withIDs: ids, from: group, panel: panel)
            },
            onCloseTabs: { [weak self, weak panel] ids in
                guard let panel else { return }
                self?.closeTabs(withIDs: ids, from: group, panel: panel)
            },
            onCrossPanelDrop: { [weak self, weak panel] ids, targetGroupID, insertionIndex in
                guard let panel else { return }
                self?.moveTabsToExistingGroup(
                    withIDs: ids, from: group, sourcePanel: panel,
                    toGroupID: targetGroupID, at: insertionIndex
                )
            },
            onDragOverPanels: { [weak self] mouseLocation -> CrossPanelDropTarget? in
                self?.handleDragOverPanels(from: group, at: mouseLocation)
            },
            onDragEnded: { [weak self] in
                self?.clearAllDropIndicators()
            }
        )

        panel.onBarDragged = { [weak self] totalDx, totalDy in
            self?.handleBarDrag(group: group, totalDx: totalDx, totalDy: totalDy)
        }
        panel.onBarDragEnded = { [weak self, weak panel] in
            guard let panel else { return }
            self?.handleBarDragEnded(group: group, panel: panel)
        }
        panel.onBarDoubleClicked = { [weak self, weak panel] in
            guard let panel else { return }
            self?.toggleZoom(group: group, panel: panel)
        }

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
            let (clamped, squeezeDelta) = self.applyClamp(
                element: activeWindow.element, windowID: activeWindow.id,
                frame: actualFrame, visibleFrame: visibleFrame,
                existingSqueezeDelta: group.tabBarSqueezeDelta
            )
            if !self.framesMatch(clamped, group.frame) {
                group.frame = clamped
                group.tabBarSqueezeDelta = squeezeDelta
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

    /// Bring a tab to front: raise its window, activate its app, and order the
    /// tab bar panel above it.  This is the single entry point for making a
    /// grouped window visible — every tab switch, window addition, and
    /// "show next tab after removal" path goes through here.
    ///
    /// Silently no-ops when the group is on a different Space, preventing
    /// cross-space focus stealing.  For intentional cross-space switches
    /// (e.g. QuickSwitcher), use `focusWindow(_:)` directly instead.
    func bringTabToFront(_ window: WindowInfo, in group: TabGroup) {
        guard isGroupOnCurrentSpace(group) else { return }
        if let freshElement = AccessibilityHelper.raiseWindow(window) {
            if let idx = group.windows.firstIndex(where: { $0.id == window.id }) {
                group.windows[idx].element = freshElement
            }
        }
        tabBarPanels[group.id]?.orderAbove(windowID: window.id)
    }

    /// Move the tab bar panel to the same Space as the given window, if they differ.
    func movePanelToWindowSpace(_ panel: TabBarPanel, windowID: CGWindowID) {
        guard panel.windowNumber > 0 else { return }
        guard let targetSpace = SpaceUtils.spaceID(for: windowID) else { return }
        let panelWID = CGWindowID(panel.windowNumber)
        guard SpaceUtils.spaceID(for: panelWID) != targetSpace else { return }
        let conn = CGSMainConnectionID()
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

        bringTabToFront(window, in: group)
    }

    func releaseTab(at index: Int, from group: TabGroup, panel: TabBarPanel) {
        guard let window = group.windows[safe: index] else { return }

        windowObserver.stopObserving(window: window)
        expectedFrames.removeValue(forKey: window.id)

        // Expand the released window upward to cover the tab bar area.
        // Size first so the window can grow, then position to move it up.
        // Re-push position after a delay because some apps revert position
        // changes asynchronously (same issue solved in applicationWillTerminate
        // where the process is terminating and can't fight back).
        if let frame = AccessibilityHelper.getFrame(of: window.element) {
            let delta = max(group.tabBarSqueezeDelta, ScreenCompensation.tabBarHeight)
            let expanded = ScreenCompensation.expandFrame(frame, undoingSqueezeDelta: delta)
            let element = window.element
            AccessibilityHelper.setSize(of: element, to: expanded.size)
            AccessibilityHelper.setPosition(of: element, to: expanded.origin)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                AccessibilityHelper.setPosition(of: element, to: expanded.origin)
                AccessibilityHelper.setSize(of: element, to: expanded.size)
            }
        }

        groupManager.releaseWindow(withID: window.id, from: group)

        if !groupManager.groups.contains(where: { $0.id == group.id }) {
            handleGroupDissolution(group: group, panel: panel)
        } else if let newActive = group.activeWindow {
            // Don't raise the next tab — keep the released window focused
            panel.orderAbove(windowID: newActive.id)
        }
        evaluateAutoCapture()
    }

    func closeTab(at index: Int, from group: TabGroup, panel: TabBarPanel) {
        guard let window = group.windows[safe: index] else { return }

        windowObserver.stopObserving(window: window)
        expectedFrames.removeValue(forKey: window.id)

        AccessibilityHelper.closeWindow(window.element)
        groupManager.releaseWindow(withID: window.id, from: group)

        if !groupManager.groups.contains(where: { $0.id == group.id }) {
            handleGroupDissolution(group: group, panel: panel)
        } else if let newActive = group.activeWindow {
            bringTabToFront(newActive, in: group)
        }
        evaluateAutoCapture()
    }

    func addWindow(_ window: WindowInfo, to group: TabGroup) {
        if group.spaceID != 0,
           let windowSpace = SpaceUtils.spaceID(for: window.id),
           windowSpace != group.spaceID {
            Logger.log("[SPACE] Rejected addWindow wid=\(window.id) (space \(windowSpace)) to group \(group.id) (space \(group.spaceID))")
            return
        }
        globalMRU.removeAll { $0 == .window(window.id) }
        setExpectedFrame(group.frame, for: [window.id])
        AccessibilityHelper.setFrame(of: window.element, to: group.frame)
        // If active tab is from the same app, insert right after it
        let insertAfterActive = group.activeWindow.map { $0.bundleID == window.bundleID } ?? false
        let insertionIndex = insertAfterActive ? group.activeIndex + 1 : nil
        groupManager.addWindow(window, to: group, at: insertionIndex)
        windowObserver.observe(window: window)

        let newIndex = group.windows.firstIndex(where: { $0.id == window.id }) ?? group.windows.count - 1
        group.switchTo(index: newIndex)
        lastActiveGroupID = group.id
        bringTabToFront(window, in: group)
        evaluateAutoCapture()
    }

    func handleGroupDissolution(group: TabGroup, panel: TabBarPanel) {
        if barDraggingGroupID == group.id { barDraggingGroupID = nil }
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

        if barDraggingGroupID == group.id { barDraggingGroupID = nil }
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

    func quitGroup(_ group: TabGroup) {
        guard let panel = tabBarPanels[group.id] else { return }

        if barDraggingGroupID == group.id { barDraggingGroupID = nil }
        if autoCaptureGroup === group { deactivateAutoCapture() }
        if lastActiveGroupID == group.id { lastActiveGroupID = nil }
        globalMRU.removeAll { $0 == .group(group.id) }

        if cyclingGroup === group { cyclingGroup = nil }
        resyncWorkItems[group.id]?.cancel()
        resyncWorkItems.removeValue(forKey: group.id)

        for window in group.windows {
            windowObserver.stopObserving(window: window)
            expectedFrames.removeValue(forKey: window.id)
            AccessibilityHelper.closeWindow(window.element)
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

    func mergeGroup(_ source: TabGroup, into target: TabGroup) {
        guard let sourcePanel = tabBarPanels[source.id] else { return }
        if target.spaceID != 0, source.spaceID != 0, target.spaceID != source.spaceID {
            Logger.log("[SPACE] Rejected merge: source space \(source.spaceID) != target space \(target.spaceID)")
            return
        }
        let windowsToMerge = source.windows
        guard !windowsToMerge.isEmpty else { return }

        // Stop observing source windows (they'll be re-observed under target)
        for window in windowsToMerge {
            windowObserver.stopObserving(window: window)
            expectedFrames.removeValue(forKey: window.id)
        }

        // Clean up source group state (like disbandGroup but without frame expansion)
        if autoCaptureGroup === source { deactivateAutoCapture() }
        if lastActiveGroupID == source.id { lastActiveGroupID = nil }
        globalMRU.removeAll { $0 == .group(source.id) }
        if cyclingGroup === source { cyclingGroup = nil }
        resyncWorkItems[source.id]?.cancel()
        resyncWorkItems.removeValue(forKey: source.id)

        // Dissolve source group and close its panel
        groupManager.dissolveGroup(source)
        sourcePanel.close()
        tabBarPanels.removeValue(forKey: source.id)

        // Add all source windows to target group
        for window in windowsToMerge {
            setExpectedFrame(target.frame, for: [window.id])
            AccessibilityHelper.setFrame(of: window.element, to: target.frame)
            groupManager.addWindow(window, to: target)
            windowObserver.observe(window: window)
        }

        // Keep target's current active tab
        if let panel = tabBarPanels[target.id],
           let activeWindow = target.activeWindow {
            panel.orderAbove(windowID: activeWindow.id)
        }

        evaluateAutoCapture()
    }

    func handleHotkeyNewTab() {
        let result = focusedWindowGroup()
        Logger.log("[HK] handleHotkeyNewTab called — focusedGroup=\(result != nil)")
        if let (group, _) = result {
            Logger.log("[HK] showing window picker for group \(group.id)")
            showWindowPicker(addingTo: group)
        } else {
            Logger.log("[HK] no focused group — showing window picker for new group")
            showWindowPicker()
        }
    }

    /// Returns the group that the currently focused window belongs to,
    /// without falling back to `lastActiveGroupID`.
    func focusedWindowGroup() -> (TabGroup, TabBarPanel)? {
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

    func handleHotkeyReleaseTab() {
        guard let (group, panel) = activeGroup() else { return }
        releaseTab(at: group.activeIndex, from: group, panel: panel)
    }

    func handleHotkeyCloseTab() {
        guard let (group, panel) = activeGroup() else { return }
        closeTab(at: group.activeIndex, from: group, panel: panel)
    }

    func handleHotkeySwitchToTab(_ index: Int) {
        guard let (group, panel) = activeGroup(),
              index >= 0, !group.windows.isEmpty else { return }
        let targetIndex = (index == 8) ? group.windows.count - 1 : index
        guard targetIndex < group.windows.count else { return }
        switchTab(in: group, to: targetIndex, panel: panel)
    }

    // MARK: - Bar Drag & Zoom

    func handleBarDrag(group: TabGroup, totalDx: CGFloat, totalDy: CGFloat) {
        if barDraggingGroupID == nil {
            barDraggingGroupID = group.id
            barDragInitialFrame = group.frame
        }
        guard let initial = barDragInitialFrame else { return }

        // AppKit Y increases upward, AX Y increases downward — negate dy
        let newFrame = CGRect(
            x: initial.origin.x + totalDx,
            y: initial.origin.y - totalDy,
            width: initial.width,
            height: initial.height
        )
        group.frame = newFrame

        let allIDs = group.windows.map(\.id)
        setExpectedFrame(newFrame, for: allIDs)
        for window in group.windows {
            AccessibilityHelper.setPosition(of: window.element, to: newFrame.origin)
        }
    }

    func handleBarDragEnded(group: TabGroup, panel: TabBarPanel) {
        barDraggingGroupID = nil
        barDragInitialFrame = nil

        // Sync all windows to the final position
        let allIDs = group.windows.map(\.id)
        setExpectedFrame(group.frame, for: allIDs)
        for window in group.windows {
            AccessibilityHelper.setFrame(of: window.element, to: group.frame)
        }

        // Apply clamping in case group was dragged near top of screen
        guard let activeWindow = group.activeWindow else { return }
        let visibleFrame = CoordinateConverter.visibleFrameInAX(at: group.frame.origin)
        let (adjustedFrame, squeezeDelta) = applyClamp(
            element: activeWindow.element, windowID: activeWindow.id,
            frame: group.frame, visibleFrame: visibleFrame,
            existingSqueezeDelta: group.tabBarSqueezeDelta
        )
        if adjustedFrame != group.frame {
            group.frame = adjustedFrame
            group.tabBarSqueezeDelta = squeezeDelta
            let otherIDs = group.windows.filter { $0.id != activeWindow.id }.map(\.id)
            setExpectedFrame(adjustedFrame, for: otherIDs)
            for window in group.windows where window.id != activeWindow.id {
                AccessibilityHelper.setFrame(of: window.element, to: adjustedFrame)
            }
        }

        panel.positionAbove(windowFrame: group.frame)
        panel.orderAbove(windowID: activeWindow.id)
        evaluateAutoCapture()
    }

    func toggleZoom(group: TabGroup, panel: TabBarPanel) {
        let visibleFrame = CoordinateConverter.visibleFrameInAX(at: group.frame.origin)
        let isMaxed = ScreenCompensation.isMaximized(
            groupFrame: group.frame,
            squeezeDelta: group.tabBarSqueezeDelta,
            visibleFrame: visibleFrame
        )

        if isMaxed, let preZoom = group.preZoomFrame {
            // Restore pre-zoom frame
            group.preZoomFrame = nil
            setGroupFrame(group, to: preZoom, panel: panel)
        } else {
            // Save current frame and zoom to fill screen
            group.preZoomFrame = group.frame
            let zoomedFrame = CGRect(
                x: visibleFrame.origin.x,
                y: visibleFrame.origin.y + ScreenCompensation.tabBarHeight,
                width: visibleFrame.width,
                height: visibleFrame.height - ScreenCompensation.tabBarHeight
            )
            group.tabBarSqueezeDelta = ScreenCompensation.tabBarHeight
            setGroupFrame(group, to: zoomedFrame, panel: panel)
        }
    }

    private func setGroupFrame(_ group: TabGroup, to frame: CGRect, panel: TabBarPanel) {
        group.frame = frame
        let allIDs = group.windows.map(\.id)
        setExpectedFrame(frame, for: allIDs)
        for window in group.windows {
            AccessibilityHelper.setFrame(of: window.element, to: frame)
        }
        panel.positionAbove(windowFrame: frame)
        if let activeWindow = group.activeWindow {
            panel.orderAbove(windowID: activeWindow.id)
        }
        evaluateAutoCapture()
    }

    // MARK: - Cross-Panel Drag & Drop

    func clearAllDropIndicators() {
        for group in groupManager.groups {
            group.dropIndicatorIndex = nil
        }
    }

    /// Find which panel (if any) the cursor is over, excluding the source group.
    /// Returns insertion index based on cursor X position.
    func findDropTarget(from sourceGroup: TabGroup, at mouseLocation: NSPoint) -> CrossPanelDropTarget? {
        for (groupID, panel) in tabBarPanels {
            guard groupID != sourceGroup.id,
                  let group = groupManager.groups.first(where: { $0.id == groupID }) else { continue }

            // Expand hit area vertically for easier targeting (30px padding above and below the 28px bar)
            var hitRect = panel.frame
            hitRect.origin.y -= 30
            hitRect.size.height += 60

            guard NSMouseInRect(mouseLocation, hitRect, false) else { continue }

            let tabCount = group.windows.count
            let panelWidth = panel.frame.width
            let tabStep = tabCount > 0
                ? (panelWidth - TabBarView.horizontalPadding - TabBarView.addButtonWidth) / CGFloat(tabCount)
                : 0

            // Convert mouse X to local panel coordinates
            let localX = mouseLocation.x - panel.frame.origin.x
            let insertionIndex: Int
            if tabStep > 0 {
                insertionIndex = max(0, min(tabCount, Int(round((localX - TabBarView.horizontalPadding / 2) / tabStep))))
            } else {
                insertionIndex = 0
            }

            return CrossPanelDropTarget(groupID: groupID, insertionIndex: insertionIndex)
        }
        return nil
    }

    /// Poll during drag to update drop indicators. Returns the target if cursor is over another panel.
    func handleDragOverPanels(from sourceGroup: TabGroup, at mouseLocation: NSPoint) -> CrossPanelDropTarget? {
        clearAllDropIndicators()

        guard let target = findDropTarget(from: sourceGroup, at: mouseLocation) else {
            return nil
        }

        if let targetGroup = groupManager.groups.first(where: { $0.id == target.groupID }) {
            targetGroup.dropIndicatorIndex = target.insertionIndex
        }

        return target
    }

    /// Move tabs from source group to an existing target group at the given insertion index.
    func moveTabsToExistingGroup(
        withIDs ids: Set<CGWindowID>,
        from sourceGroup: TabGroup,
        sourcePanel: TabBarPanel,
        toGroupID targetGroupID: UUID,
        at insertionIndex: Int
    ) {
        guard let targetGroup = groupManager.groups.first(where: { $0.id == targetGroupID }),
              let targetPanel = tabBarPanels[targetGroupID] else { return }

        if targetGroup.spaceID != 0, sourceGroup.spaceID != 0, targetGroup.spaceID != sourceGroup.spaceID {
            Logger.log("[SPACE] Rejected cross-panel drop: source space \(sourceGroup.spaceID) != target space \(targetGroup.spaceID)")
            return
        }

        Logger.log("[DRAG] Cross-panel drop: \(ids) from group \(sourceGroup.id) to group \(targetGroupID) at index \(insertionIndex)")
        targetGroup.dropIndicatorIndex = nil

        let windowsToMove = sourceGroup.windows.filter { ids.contains($0.id) }
        guard !windowsToMove.isEmpty else { return }

        // Stop observing source windows (they'll be re-observed under target)
        for window in windowsToMove {
            windowObserver.stopObserving(window: window)
            expectedFrames.removeValue(forKey: window.id)
        }

        // Release from source group (auto-dissolves if empty)
        groupManager.releaseWindows(withIDs: ids, from: sourceGroup)

        if !groupManager.groups.contains(where: { $0.id == sourceGroup.id }) {
            handleGroupDissolution(group: sourceGroup, panel: sourcePanel)
        } else if let newActive = sourceGroup.activeWindow {
            bringTabToFront(newActive, in: sourceGroup)
        }

        // Add each window to target at insertion index
        for (offset, window) in windowsToMove.enumerated() {
            setExpectedFrame(targetGroup.frame, for: [window.id])
            AccessibilityHelper.setFrame(of: window.element, to: targetGroup.frame)
            groupManager.addWindow(window, to: targetGroup, at: insertionIndex + offset)
            windowObserver.observe(window: window)
        }

        // Switch target group to the first moved tab and raise it
        if let firstMoved = windowsToMove.first,
           let newIndex = targetGroup.windows.firstIndex(where: { $0.id == firstMoved.id }) {
            targetGroup.switchTo(index: newIndex)
            lastActiveGroupID = targetGroup.id
            targetGroup.recordFocus(windowID: firstMoved.id)
            bringTabToFront(firstMoved, in: targetGroup)
        }

        evaluateAutoCapture()
    }

    // MARK: - Multi-Tab Operations

    func releaseTabs(withIDs ids: Set<CGWindowID>, from group: TabGroup, panel: TabBarPanel) {
        // Capture windows before removal so we can raise one afterward
        let releasedWindows = group.windows.filter { ids.contains($0.id) }

        for window in releasedWindows {
            windowObserver.stopObserving(window: window)
            expectedFrames.removeValue(forKey: window.id)

            if let frame = AccessibilityHelper.getFrame(of: window.element) {
                let delta = max(group.tabBarSqueezeDelta, ScreenCompensation.tabBarHeight)
                let expanded = ScreenCompensation.expandFrame(frame, undoingSqueezeDelta: delta)
                let element = window.element
                AccessibilityHelper.setSize(of: element, to: expanded.size)
                AccessibilityHelper.setPosition(of: element, to: expanded.origin)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    AccessibilityHelper.setPosition(of: element, to: expanded.origin)
                    AccessibilityHelper.setSize(of: element, to: expanded.size)
                }
            }
        }

        groupManager.releaseWindows(withIDs: ids, from: group)

        // Raise the first released window so it becomes focused
        if let first = releasedWindows.first {
            _ = AccessibilityHelper.raiseWindow(first)
        }

        if !groupManager.groups.contains(where: { $0.id == group.id }) {
            handleGroupDissolution(group: group, panel: panel)
        } else if let newActive = group.activeWindow {
            panel.orderAbove(windowID: newActive.id)
        }
        evaluateAutoCapture()
    }

    func moveTabsToNewGroup(withIDs ids: Set<CGWindowID>, from group: TabGroup, panel: TabBarPanel) {
        let windowsToMove = group.windows.filter { ids.contains($0.id) }
        guard !windowsToMove.isEmpty else { return }

        let frame = group.frame
        let squeezeDelta = group.tabBarSqueezeDelta

        for window in windowsToMove {
            windowObserver.stopObserving(window: window)
            expectedFrames.removeValue(forKey: window.id)
        }

        groupManager.releaseWindows(withIDs: ids, from: group)

        if !groupManager.groups.contains(where: { $0.id == group.id }) {
            handleGroupDissolution(group: group, panel: panel)
        } else if let newActive = group.activeWindow {
            bringTabToFront(newActive, in: group)
        }

        guard let newGroup = setupGroup(with: windowsToMove, frame: frame, squeezeDelta: squeezeDelta) else { return }
        if let activeWindow = newGroup.activeWindow {
            bringTabToFront(activeWindow, in: newGroup)
        }
    }

    func closeTabs(withIDs ids: Set<CGWindowID>, from group: TabGroup, panel: TabBarPanel) {
        for id in ids {
            guard let window = group.windows.first(where: { $0.id == id }) else { continue }
            windowObserver.stopObserving(window: window)
            expectedFrames.removeValue(forKey: window.id)
            AccessibilityHelper.closeWindow(window.element)
        }

        groupManager.releaseWindows(withIDs: ids, from: group)

        if !groupManager.groups.contains(where: { $0.id == group.id }) {
            handleGroupDissolution(group: group, panel: panel)
        } else if let newActive = group.activeWindow {
            bringTabToFront(newActive, in: group)
        }
        evaluateAutoCapture()
    }

    @objc func handleAppTerminated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        let pid = app.processIdentifier
        Logger.log("[DEBUG] handleAppTerminated: app=\(app.localizedName ?? "?") pid=\(pid)")

        for group in groupManager.groups {
            let affectedWindows = group.windows.filter { $0.ownerPID == pid }
            guard !affectedWindows.isEmpty else { continue }
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
            } else if let newActive = group.activeWindow {
                bringTabToFront(newActive, in: group)
            }
        }
    }
}
