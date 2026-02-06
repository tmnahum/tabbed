import AppKit
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    let windowManager = WindowManager()
    let groupManager = GroupManager()
    let windowObserver = WindowObserver()

    private var windowPickerPanel: NSPanel?
    private var tabBarPanels: [UUID: TabBarPanel] = [:]
    /// Window IDs we're programmatically moving/resizing — suppress their AX notifications.
    /// Each window has its own cancellable timer so overlapping programmatic changes
    /// extend the suppression window instead of leaving gaps.
    private var suppressedWindowIDs: Set<CGWindowID> = []
    private var suppressionWorkItems: [CGWindowID: DispatchWorkItem] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !AXIsProcessTrusted() {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
        }

        windowObserver.onWindowMoved = { [weak self] windowID in
            self?.handleWindowMoved(windowID)
        }
        windowObserver.onWindowResized = { [weak self] windowID in
            self?.handleWindowResized(windowID)
        }
        windowObserver.onWindowFocused = { [weak self] pid, element in
            self?.handleWindowFocused(pid: pid, element: element)
        }
        windowObserver.onWindowDestroyed = { [weak self] windowID in
            self?.handleWindowDestroyed(windowID)
        }
        windowObserver.onTitleChanged = { [weak self] windowID in
            self?.handleTitleChanged(windowID)
        }

        // Watch for apps quitting/crashing to clean up their grouped windows
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleAppTerminated(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )

        // Watch for app activation (dock clicks, Cmd-Tab, links from other apps).
        // kAXFocusedWindowChangedNotification only fires when the focused window
        // *within* an app changes — not when the app merely re-activates with the
        // same focused window. This observer covers that gap.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleAppActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        windowObserver.stopAll()
        // Expand all grouped windows upward to reclaim tab bar space
        let tabBarHeight = TabBarPanel.tabBarHeight
        for group in groupManager.groups {
            for window in group.windows {
                if let frame = AccessibilityHelper.getFrame(of: window.element) {
                    let expandedFrame = CGRect(
                        x: frame.origin.x,
                        y: frame.origin.y - tabBarHeight,
                        width: frame.width,
                        height: frame.height + tabBarHeight
                    )
                    AccessibilityHelper.setFrame(of: window.element, to: expandedFrame)
                }
            }
        }
        for (_, panel) in tabBarPanels {
            panel.close()
        }
        tabBarPanels.removeAll()
        groupManager.dissolveAllGroups()
    }

    // MARK: - Window Picker

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
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        windowPickerPanel = panel
    }

    private func dismissWindowPicker() {
        windowPickerPanel?.close()
        windowPickerPanel = nil
    }

    // MARK: - Group Lifecycle

    private func createGroup(with windows: [WindowInfo]) {
        guard let first = windows.first,
              let firstFrame = AccessibilityHelper.getFrame(of: first.element) else { return }

        let tabBarHeight = TabBarPanel.tabBarHeight
        let windowFrame = CGRect(
            x: firstFrame.origin.x,
            y: firstFrame.origin.y + tabBarHeight,
            width: firstFrame.width,
            height: firstFrame.height - tabBarHeight
        )

        guard let group = groupManager.createGroup(with: windows, frame: windowFrame) else { return }

        // Suppress notifications while we sync frames to prevent observer races
        suppressNotifications(for: group.windows.map(\.id))

        // Sync all windows to same frame
        for window in group.windows {
            AccessibilityHelper.setFrame(of: window.element, to: windowFrame)
        }

        // Create and show tab bar
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

        panel.onPanelMoved = { [weak self, weak panel] in
            guard let panel else { return }
            self?.handlePanelMoved(group: group, panel: panel)
        }

        tabBarPanels[group.id] = panel

        for window in group.windows {
            windowObserver.observe(window: window)
        }

        if let activeWindow = group.activeWindow {
            panel.show(above: windowFrame, windowID: activeWindow.id)
            // Raise the active window last so it's on top of the other grouped windows.
            // This must happen after panel.show() to establish correct z-order.
            raiseAndUpdate(activeWindow, in: group)
            panel.orderAbove(windowID: activeWindow.id)
        }
    }

    /// Raise a window and update the group's stored AXUIElement if a fresh one was resolved.
    private func raiseAndUpdate(_ window: WindowInfo, in group: TabGroup) {
        if let freshElement = AccessibilityHelper.raiseWindow(window) {
            if let idx = group.windows.firstIndex(where: { $0.id == window.id }) {
                group.windows[idx].element = freshElement
            }
        }
    }

    private func switchTab(in group: TabGroup, to index: Int, panel: TabBarPanel) {
        group.switchTo(index: index)
        guard let window = group.activeWindow else { return }
        // Activate the owning app first — the tab bar is a non-activating panel,
        // so clicking a tab won't activate the app. Without this, raiseWindow
        // may succeed (bringing the window to front within the app) but the app
        // itself stays in the background, leaving the window unfocused.
        if let app = NSRunningApplication(processIdentifier: window.ownerPID) {
            if #available(macOS 14.0, *) {
                app.activate()
            } else {
                app.activate(options: [])
            }
        }
        raiseAndUpdate(window, in: group)
        panel.orderAbove(windowID: window.id)
    }

    private func releaseTab(at index: Int, from group: TabGroup, panel: TabBarPanel) {
        guard let window = group.windows[safe: index] else { return }

        windowObserver.stopObserving(window: window)

        let tabBarHeight = TabBarPanel.tabBarHeight

        // Expand window upward into tab bar area
        if let frame = AccessibilityHelper.getFrame(of: window.element) {
            let expandedFrame = CGRect(
                x: frame.origin.x,
                y: frame.origin.y - tabBarHeight,
                width: frame.width,
                height: frame.height + tabBarHeight
            )
            AccessibilityHelper.setFrame(of: window.element, to: expandedFrame)
        }

        groupManager.releaseWindow(withID: window.id, from: group)

        if !groupManager.groups.contains(where: { $0.id == group.id }) {
            handleGroupDissolution(group: group, panel: panel)
        } else if let newActive = group.activeWindow {
            raiseAndUpdate(newActive, in: group)
            panel.orderAbove(windowID: newActive.id)
        }
    }

    private func addWindow(_ window: WindowInfo, to group: TabGroup) {
        AccessibilityHelper.setFrame(of: window.element, to: group.frame)
        groupManager.addWindow(window, to: group)
        windowObserver.observe(window: window)
    }

    /// Handle group dissolution: expand the last surviving window upward into tab bar space,
    /// stop its observer, and close the panel. Call this after `groupManager.releaseWindow`
    /// when the group no longer exists.
    private func handleGroupDissolution(group: TabGroup, panel: TabBarPanel) {
        let tabBarHeight = TabBarPanel.tabBarHeight
        if let lastWindow = group.windows.first {
            windowObserver.stopObserving(window: lastWindow)
            if let lastFrame = AccessibilityHelper.getFrame(of: lastWindow.element) {
                let expandedFrame = CGRect(
                    x: lastFrame.origin.x,
                    y: lastFrame.origin.y - tabBarHeight,
                    width: lastFrame.width,
                    height: lastFrame.height + tabBarHeight
                )
                AccessibilityHelper.setFrame(of: lastWindow.element, to: expandedFrame)
            }
        }
        panel.close()
        tabBarPanels.removeValue(forKey: group.id)
    }

    // MARK: - Notification Suppression

    /// Suppress AX move/resize notifications for the given window IDs.
    /// Each window gets its own cancellable timer. If a new programmatic change
    /// arrives for an already-suppressed window, the old timer is cancelled and
    /// a fresh one starts — preventing gaps in suppression during rapid updates.
    private func suppressNotifications(for windowIDs: [CGWindowID]) {
        for id in windowIDs {
            suppressionWorkItems[id]?.cancel()
            suppressedWindowIDs.insert(id)
            let workItem = DispatchWorkItem { [weak self] in
                self?.suppressedWindowIDs.remove(id)
                self?.suppressionWorkItems.removeValue(forKey: id)
            }
            suppressionWorkItems[id] = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: workItem)
        }
    }

    // MARK: - Panel Drag

    private func handlePanelMoved(group: TabGroup, panel: TabBarPanel) {
        let panelFrame = panel.frame
        let tabBarHeight = TabBarPanel.tabBarHeight

        // Convert panel's AppKit frame to AX coordinates for the window area below it
        let windowOriginAX = CoordinateConverter.appKitToAX(
            point: CGPoint(x: panelFrame.origin.x, y: panelFrame.origin.y),
            windowHeight: tabBarHeight
        )
        let windowFrame = CGRect(
            x: windowOriginAX.x,
            y: windowOriginAX.y + tabBarHeight,
            width: panelFrame.width,
            height: group.frame.height
        )

        group.frame = windowFrame
        suppressNotifications(for: group.windows.map(\.id))

        for window in group.windows {
            AccessibilityHelper.setFrame(of: window.element, to: windowFrame)
        }

        if let activeWindow = group.activeWindow {
            raiseAndUpdate(activeWindow, in: group)
            panel.orderAbove(windowID: activeWindow.id)
        }
    }

    // MARK: - AXObserver Handlers

    /// Clamp a window frame so the tab bar has room above it within the visible screen area.
    private func clampFrameForTabBar(_ frame: CGRect) -> CGRect {
        let visibleFrame = CoordinateConverter.visibleFrameInAX(at: frame.origin)
        let tabBarHeight = TabBarPanel.tabBarHeight
        var adjusted = frame
        if frame.origin.y < visibleFrame.origin.y + tabBarHeight {
            let delta = (visibleFrame.origin.y + tabBarHeight) - frame.origin.y
            adjusted.origin.y += delta
            adjusted.size.height -= delta
        }
        return adjusted
    }

    private func handleWindowMoved(_ windowID: CGWindowID) {
        guard !suppressedWindowIDs.contains(windowID) else { return }
        guard let group = groupManager.group(for: windowID),
              let panel = tabBarPanels[group.id],
              let activeWindow = group.activeWindow,
              activeWindow.id == windowID,
              let frame = AccessibilityHelper.getFrame(of: activeWindow.element) else { return }

        let adjustedFrame = clampFrameForTabBar(frame)
        if adjustedFrame.origin != frame.origin {
            AccessibilityHelper.setPosition(of: activeWindow.element, to: adjustedFrame.origin)
        }

        group.frame = adjustedFrame

        // Suppress notifications for other windows we're about to sync
        let otherIDs = group.windows.filter { $0.id != windowID }.map(\.id)
        suppressNotifications(for: otherIDs)

        // Sync other windows
        for window in group.windows where window.id != windowID {
            AccessibilityHelper.setFrame(of: window.element, to: adjustedFrame)
        }

        // Update panel position
        panel.positionAbove(windowFrame: adjustedFrame)
        panel.orderAbove(windowID: activeWindow.id)
    }

    private func handleWindowResized(_ windowID: CGWindowID) {
        guard !suppressedWindowIDs.contains(windowID) else { return }
        guard let group = groupManager.group(for: windowID),
              let panel = tabBarPanels[group.id],
              let activeWindow = group.activeWindow,
              activeWindow.id == windowID,
              let frame = AccessibilityHelper.getFrame(of: activeWindow.element) else { return }

        // Detect native full-screen (green button / Mission Control).
        // We use the AXFullScreen attribute rather than a size heuristic so that
        // merely maximising a window to fill the screen doesn't eject it.
        if AccessibilityHelper.isFullScreen(activeWindow.element) {
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

        // Clamp to visible frame — ensure room for tab bar
        let adjustedFrame = clampFrameForTabBar(frame)
        if adjustedFrame.origin != frame.origin {
            AccessibilityHelper.setPosition(of: activeWindow.element, to: adjustedFrame.origin)
        }

        group.frame = adjustedFrame

        // Suppress notifications for other windows we're about to sync
        let otherIDs = group.windows.filter { $0.id != windowID }.map(\.id)
        suppressNotifications(for: otherIDs)

        // Sync other windows
        for window in group.windows where window.id != windowID {
            AccessibilityHelper.setFrame(of: window.element, to: adjustedFrame)
        }

        // Update panel size and position
        panel.positionAbove(windowFrame: adjustedFrame)
        panel.orderAbove(windowID: activeWindow.id)
    }

    private func handleWindowFocused(pid: pid_t, element: AXUIElement) {
        guard let windowID = AccessibilityHelper.windowID(for: element),
              let group = groupManager.group(for: windowID),
              let panel = tabBarPanels[group.id] else { return }

        group.switchTo(windowID: windowID)
        panel.orderAbove(windowID: windowID)
    }

    private func handleWindowDestroyed(_ windowID: CGWindowID) {
        guard let group = groupManager.group(for: windowID),
              let panel = tabBarPanels[group.id],
              let window = group.windows.first(where: { $0.id == windowID }) else { return }

        // Clean up the old (now-invalid) element from observer bookkeeping.
        windowObserver.handleDestroyedWindow(pid: window.ownerPID, elementHash: CFHash(window.element))

        // Some apps destroy and recreate their AXUIElement without actually
        // closing the window (e.g. browser tab switches). If the window is
        // still on screen, find the new element and re-observe it.
        if AccessibilityHelper.windowExists(id: windowID) {
            let newElements = AccessibilityHelper.windowElements(for: window.ownerPID)
            if let newElement = newElements.first(where: { AccessibilityHelper.windowID(for: $0) == windowID }),
               let index = group.windows.firstIndex(where: { $0.id == windowID }) {
                group.windows[index].element = newElement
                windowObserver.observe(window: group.windows[index])
            }
            return
        }

        groupManager.releaseWindow(withID: windowID, from: group)

        if !groupManager.groups.contains(where: { $0.id == group.id }) {
            handleGroupDissolution(group: group, panel: panel)
        } else if let newActive = group.activeWindow {
            raiseAndUpdate(newActive, in: group)
            panel.orderAbove(windowID: newActive.id)
        }
    }

    private func handleTitleChanged(_ windowID: CGWindowID) {
        guard let group = groupManager.group(for: windowID) else { return }
        if let index = group.windows.firstIndex(where: { $0.id == windowID }),
           let newTitle = AccessibilityHelper.getTitle(of: group.windows[index].element) {
            group.windows[index].title = newTitle
        }
    }

    @objc private func handleAppActivated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        let pid = app.processIdentifier

        // Query which window the activated app considers focused
        let appElement = AccessibilityHelper.appElement(for: pid)
        var focusedValue: AnyObject?
        let result = AXUIElementCopyAttributeValue(
            appElement, kAXFocusedWindowAttribute as CFString, &focusedValue
        )
        guard result == .success, let focusedValue else { return }
        let windowElement = focusedValue as! AXUIElement

        guard let windowID = AccessibilityHelper.windowID(for: windowElement),
              let group = groupManager.group(for: windowID),
              let panel = tabBarPanels[group.id] else { return }

        group.switchTo(windowID: windowID)
        panel.orderAbove(windowID: windowID)
    }

    @objc private func handleAppTerminated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        let pid = app.processIdentifier

        // Find all grouped windows belonging to this PID and release them
        for group in groupManager.groups {
            let affectedWindows = group.windows.filter { $0.ownerPID == pid }
            for window in affectedWindows {
                windowObserver.handleDestroyedWindow(pid: pid, elementHash: CFHash(window.element))
                groupManager.releaseWindow(withID: window.id, from: group)
            }
            // If group was dissolved, expand surviving window and clean up panel
            if !groupManager.groups.contains(where: { $0.id == group.id }),
               let panel = tabBarPanels[group.id] {
                handleGroupDissolution(group: group, panel: panel)
            } else if let panel = tabBarPanels[group.id],
                      let newActive = group.activeWindow {
                raiseAndUpdate(newActive, in: group)
                panel.orderAbove(windowID: newActive.id)
            }
        }
    }
}

// Safe array subscript
extension Array {
    subscript(safe index: Int) -> Element? {
        index >= 0 && index < count ? self[index] : nil
    }
}
