import AppKit
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let windowManager = WindowManager()
    let groupManager = GroupManager()
    let windowObserver = WindowObserver()

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var windowPickerPanel: NSPanel?
    private var settingsWindow: NSWindow?
    private var keyMonitor: Any?
    private var tabBarPanels: [UUID: TabBarPanel] = [:]
    private var hotkeyManager: HotkeyManager?
    private var lastActiveGroupID: UUID?
    /// Snapshots loaded at launch for deferred "Restore Previous Session" from menu.
    private var pendingSessionSnapshots: [GroupSnapshot]?
    let sessionState = SessionState()
    /// Window IDs we're programmatically moving/resizing — suppress their AX notifications.
    /// Each window has its own cancellable timer so overlapping programmatic changes
    /// extend the suppression window instead of leaving gaps.
    private var suppressedWindowIDs: Set<CGWindowID> = []
    private var suppressionWorkItems: [CGWindowID: DispatchWorkItem] = [:]
    /// Pending delayed re-syncs for animated resizes, keyed by group ID.
    private var resyncWorkItems: [UUID: DispatchWorkItem] = [:]
    /// Auto-capture state: the group currently in "workspace takeover" mode.
    private var autoCaptureGroup: TabGroup?
    private var autoCaptureScreen: NSScreen?
    private var autoCaptureObservers: [pid_t: AXObserver] = [:]
    private var autoCaptureAppElements: [pid_t: AXUIElement] = [:]
    private var autoCaptureNotificationTokens: [NSObjectProtocol] = []
    private var autoCaptureDefaultCenterTokens: [NSObjectProtocol] = []
    private var sessionConfig = SessionConfig.load()
    /// Pending MRU commit after cycling stops.
    private var cycleWorkItem: DispatchWorkItem?
    /// The group currently being MRU-cycled (captured at cycle start so
    /// flagsChanged can end the cycle even if activeGroup() resolves differently).
    private weak var cyclingGroup: TabGroup?
    /// Timestamp when the last cycle ended — focus events within the cooldown
    /// are ignored to prevent delayed AX notifications from corrupting MRU order.
    private var cycleEndTime: Date?
    private static let cycleCooldownDuration: TimeInterval = 0.15

    private var isCycleCooldownActive: Bool {
        cycleEndTime.map { Date().timeIntervalSince($0) < Self.cycleCooldownDuration } ?? false
    }
    /// Only terminate when the user explicitly clicks "Quit Tabbed".
    var isExplicitQuit = false

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        isExplicitQuit ? .terminateNow : .terminateCancel
    }

    /// Install a SIGINT handler so that `kill -INT` from the build script
    /// triggers a graceful quit (with cleanup) rather than a hard kill.
    private func installSignalHandler() {
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        source.setEventHandler { [weak self] in
            self?.isExplicitQuit = true
            NSApplication.shared.terminate(nil)
        }
        source.resume()
        // Ignore the default SIGINT action so our handler runs instead
        signal(SIGINT, SIG_IGN)
        // Store to keep alive
        signalSource = source
    }
    private var signalSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installSignalHandler()
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

        // Cmd+, for Settings (LSUIElement apps have no app menu to attach shortcuts to)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags == .command, event.charactersIgnoringModifiers == "," {
                self?.showSettings()
                return nil
            }
            return event
        }

        // Global keyboard shortcuts
        let config = ShortcutConfig.load()
        let hkm = HotkeyManager(config: config)

        hkm.onNewTab = { [weak self] in
            self?.handleHotkeyNewTab()
        }
        hkm.onReleaseTab = { [weak self] in
            self?.handleHotkeyReleaseTab()
        }
        hkm.onCycleTab = { [weak self] in
            self?.handleHotkeyCycleTab()
        }
        hkm.onSwitchToTab = { [weak self] index in
            self?.handleHotkeySwitchToTab(index)
        }
        hkm.onModifierReleased = { [weak self] in
            self?.handleCycleModifierReleased()
        }

        hkm.start()
        hotkeyManager = hkm

        setupStatusItem()

        // Session restoration
        let sessionConfig = SessionConfig.load()
        if let snapshots = SessionManager.loadSession() {
            if sessionConfig.restoreMode == .smart || sessionConfig.restoreMode == .always {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard let self else { return }
                    self.restoreSession(snapshots: snapshots, mode: sessionConfig.restoreMode)
                    // In smart mode, show manual restore button only if some groups failed
                    if sessionConfig.restoreMode == .smart,
                       self.groupManager.groups.count < snapshots.count {
                        self.pendingSessionSnapshots = snapshots
                        self.sessionState.hasPendingSession = true
                    }
                }
            }
            if sessionConfig.restoreMode == .off {
                pendingSessionSnapshots = snapshots
                sessionState.hasPendingSession = true
            }
        }
    }

    private func setupStatusItem() {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "rectangle.stack", accessibilityDescription: "Tabbed")
            button.action = #selector(togglePopover)
            button.target = self
        }

        let menuBarView = MenuBarView(
            groupManager: groupManager,
            sessionState: sessionState,
            onNewGroup: { [weak self] in
                self?.popover.performClose(nil)
                self?.showWindowPicker()
            },
            onAllInSpace: { [weak self] in
                self?.popover.performClose(nil)
                self?.groupAllInSpace()
            },
            onRestoreSession: { [weak self] in
                self?.popover.performClose(nil)
                self?.restorePreviousSession()
            },
            onFocusWindow: { [weak self] window in
                self?.popover.performClose(nil)
                self?.focusWindow(window)
            },
            onDisbandGroup: { [weak self] group in
                self?.popover.performClose(nil)
                self?.disbandGroup(group)
            },
            onSettings: { [weak self] in
                self?.popover.performClose(nil)
                self?.showSettings()
            },
            onQuit: { [weak self] in
                self?.isExplicitQuit = true
                NSApplication.shared.terminate(nil)
            }
        )

        popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: menuBarView)
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        deactivateAutoCapture()
        windowObserver.stopAll()
        // Save session BEFORE expanding windows (we want the squeezed frame)
        SessionManager.saveSession(groups: groupManager.groups)
        // Expand all grouped windows upward to reclaim tab bar space
        for group in groupManager.groups {
            let delta = group.tabBarSqueezeDelta
            guard delta > 0 else { continue }
            for window in group.windows {
                if let frame = AccessibilityHelper.getFrame(of: window.element) {
                    let expandedFrame = CGRect(
                        x: frame.origin.x,
                        y: frame.origin.y - delta,
                        width: frame.width,
                        height: frame.height + delta
                    )
                    AccessibilityHelper.setFrame(of: window.element, to: expandedFrame)
                }
            }
        }
        for (_, panel) in tabBarPanels {
            panel.close()
        }
        tabBarPanels.removeAll()
        settingsWindow?.close()
        settingsWindow = nil
        if let monitor = keyMonitor { NSEvent.removeMonitor(monitor) }
        keyMonitor = nil
        hotkeyManager?.stop()
        hotkeyManager = nil
        groupManager.dissolveAllGroups()
    }

    // MARK: - Settings

    func showSettings() {
        if let existing = settingsWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Tabbed Settings"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let settingsView = SettingsView(
            config: hotkeyManager?.config ?? .default,
            sessionConfig: SessionConfig.load(),
            onConfigChanged: { [weak self] newConfig in
                newConfig.save()
                self?.hotkeyManager?.updateConfig(newConfig)
            },
            onSessionConfigChanged: { [weak self] newConfig in
                newConfig.save()
                self?.sessionConfig = newConfig
                if newConfig.autoCaptureEnabled {
                    self?.evaluateAutoCapture()
                } else {
                    self?.deactivateAutoCapture()
                }
            }
        )
        window.contentView = NSHostingView(rootView: settingsView)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = window
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === settingsWindow {
            sender.orderOut(nil)
            return false
        }
        return true
    }

    // MARK: - Focus Window

    func focusWindow(_ window: WindowInfo) {
        // raiseWindow already activates the owning app
        _ = AccessibilityHelper.raiseWindow(window)
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
        NSApp.activate(ignoringOtherApps: true)
        windowPickerPanel = panel
    }

    private func dismissWindowPicker() {
        windowPickerPanel?.close()
        windowPickerPanel = nil
    }

    // MARK: - All in Space

    private func groupAllInSpace() {
        let allWindows = windowManager.windowsInZOrder()
        let ungrouped = allWindows.filter { !groupManager.isWindowGrouped($0.id) }
        guard !ungrouped.isEmpty else { return }
        createGroup(with: ungrouped)
    }

    // MARK: - Group Lifecycle

    private func createGroup(with windows: [WindowInfo]) {
        guard let first = windows.first,
              let firstFrame = AccessibilityHelper.getFrame(of: first.element) else { return }

        let windowFrame = clampFrameForTabBar(firstFrame)
        let squeezeDelta = windowFrame.origin.y - firstFrame.origin.y

        setupGroup(with: windows, frame: windowFrame, squeezeDelta: squeezeDelta)
    }

    /// Shared group setup: create the group, sync frames, wire up tab bar panel and observers.
    @discardableResult
    private func setupGroup(
        with windows: [WindowInfo],
        frame: CGRect,
        squeezeDelta: CGFloat,
        activeIndex: Int = 0
    ) -> TabGroup? {
        guard let group = groupManager.createGroup(with: windows, frame: frame) else { return nil }
        group.tabBarSqueezeDelta = squeezeDelta
        group.switchTo(index: activeIndex)

        suppressNotifications(for: group.windows.map(\.id))

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
            // Raise the active window last so it's on top of the other grouped windows.
            // This must happen after panel.show() to establish correct z-order.
            raiseAndUpdate(activeWindow, in: group)
            panel.orderAbove(windowID: activeWindow.id)
        }

        evaluateAutoCapture()
        return group
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
        lastActiveGroupID = group.id
        // Update MRU synchronously for manual switches (cycling defers to endCycle)
        if !group.isCycling {
            group.recordFocus(windowID: window.id)
        }
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

        // Sync window to the group's canonical frame. This acts as a fallback
        // for any prior resize that left this window at the wrong size (e.g.
        // a double-click maximize that only partially synced).
        suppressNotifications(for: [window.id])
        AccessibilityHelper.setFrame(of: window.element, to: group.frame)

        raiseAndUpdate(window, in: group)
        panel.orderAbove(windowID: window.id)
    }

    private func releaseTab(at index: Int, from group: TabGroup, panel: TabBarPanel) {
        guard let window = group.windows[safe: index] else { return }

        windowObserver.stopObserving(window: window)

        groupManager.releaseWindow(withID: window.id, from: group)

        if !groupManager.groups.contains(where: { $0.id == group.id }) {
            handleGroupDissolution(group: group, panel: panel)
        } else if let newActive = group.activeWindow {
            raiseAndUpdate(newActive, in: group)
            panel.orderAbove(windowID: newActive.id)
        }
        evaluateAutoCapture()
    }

    private func addWindow(_ window: WindowInfo, to group: TabGroup) {
        AccessibilityHelper.setFrame(of: window.element, to: group.frame)
        groupManager.addWindow(window, to: group)
        windowObserver.observe(window: window)

        // Switch to the newly added tab
        let newIndex = group.windows.count - 1
        group.switchTo(index: newIndex)
        lastActiveGroupID = group.id
        raiseAndUpdate(window, in: group)
        if let panel = tabBarPanels[group.id] {
            panel.orderAbove(windowID: window.id)
        }
        evaluateAutoCapture()
    }

    // MARK: - Session Restore

    private func restoreSession(snapshots: [GroupSnapshot], mode: RestoreMode) {
        windowManager.refreshWindowList()
        let liveWindows = windowManager.availableWindows.filter {
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
            let restoredActiveIndex = min(snapshot.activeIndex, matchedWindows.count - 1)

            setupGroup(
                with: matchedWindows,
                frame: restoredFrame,
                squeezeDelta: effectiveSqueezeDelta,
                activeIndex: restoredActiveIndex
            )
        }
    }

    private func restorePreviousSession() {
        guard let snapshots = pendingSessionSnapshots else { return }
        pendingSessionSnapshots = nil
        sessionState.hasPendingSession = false
        restoreSession(snapshots: snapshots, mode: .always)
    }

    // MARK: - Hotkey Actions

    /// Resolve the group the user is currently interacting with.
    private func activeGroup() -> (TabGroup, TabBarPanel)? {
        // Try the last-tracked active group first
        if let id = lastActiveGroupID,
           let group = groupManager.groups.first(where: { $0.id == id }),
           let panel = tabBarPanels[id] {
            return (group, panel)
        }
        // Fallback: query the frontmost app's focused window
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

    private func handleHotkeyNewTab() {
        let result = activeGroup()
        Logger.log("[HK] handleHotkeyNewTab called — activeGroup=\(result != nil)")
        guard let (group, _) = result else { return }
        Logger.log("[HK] showing window picker for group \(group.id)")
        showWindowPicker(addingTo: group)
    }

    private func handleHotkeyReleaseTab() {
        guard let (group, panel) = activeGroup() else { return }
        releaseTab(at: group.activeIndex, from: group, panel: panel)
    }

    private func handleHotkeyCycleTab() {
        guard let (group, panel) = activeGroup(),
              let nextIndex = group.nextInMRUCycle() else { return }

        // Cancel any pending MRU commit from a previous cycle step
        cycleWorkItem?.cancel()

        cyclingGroup = group
        switchTab(in: group, to: nextIndex, panel: panel)

        // Fallback: if flagsChanged never fires (e.g. external keyboard quirks),
        // commit MRU order after a longer inactivity timeout.
        let workItem = DispatchWorkItem { [weak self] in
            group.endCycle()
            self?.cycleWorkItem = nil
            self?.cyclingGroup = nil
            self?.cycleEndTime = Date()
        }
        cycleWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }

    private func handleCycleModifierReleased() {
        guard let group = cyclingGroup, group.isCycling else { return }
        cycleWorkItem?.cancel()
        cycleWorkItem = nil
        group.endCycle()
        cyclingGroup = nil
        cycleEndTime = Date()
    }

    private func handleHotkeySwitchToTab(_ index: Int) {
        guard let (group, panel) = activeGroup(),
              index >= 0, !group.windows.isEmpty else { return }
        // Hyper 9 (index 8) always goes to last tab
        let targetIndex = (index == 8) ? group.windows.count - 1 : index
        guard targetIndex < group.windows.count else { return }
        switchTab(in: group, to: targetIndex, panel: panel)
    }

    /// Handle group dissolution: expand the last surviving window upward into tab bar space,
    /// stop its observer, and close the panel. Call this after `groupManager.releaseWindow`
    /// when the group no longer exists. If `group.windows` is empty (e.g. the caller already
    /// expanded and cleaned up the released window), this just closes the panel.
    private func handleGroupDissolution(group: TabGroup, panel: TabBarPanel) {
        if autoCaptureGroup === group { deactivateAutoCapture() }
        if lastActiveGroupID == group.id { lastActiveGroupID = nil }
        cycleWorkItem?.cancel()
        cycleWorkItem = nil
        if cyclingGroup === group { cyclingGroup = nil }
        resyncWorkItems[group.id]?.cancel()
        resyncWorkItems.removeValue(forKey: group.id)

        let delta = group.tabBarSqueezeDelta
        if let lastWindow = group.windows.first {
            windowObserver.stopObserving(window: lastWindow)
            if delta > 0, let lastFrame = AccessibilityHelper.getFrame(of: lastWindow.element) {
                let expandedFrame = CGRect(
                    x: lastFrame.origin.x,
                    y: lastFrame.origin.y - delta,
                    width: lastFrame.width,
                    height: lastFrame.height + delta
                )
                AccessibilityHelper.setFrame(of: lastWindow.element, to: expandedFrame)
            }
        }
        panel.close()
        tabBarPanels.removeValue(forKey: group.id)
    }

    /// Disband an entire group: expand all windows upward to reclaim tab bar space,
    /// stop observers, dissolve the group, and close the panel.
    func disbandGroup(_ group: TabGroup) {
        guard let panel = tabBarPanels[group.id] else { return }

        if autoCaptureGroup === group { deactivateAutoCapture() }
        if lastActiveGroupID == group.id { lastActiveGroupID = nil }
        cycleWorkItem?.cancel()
        cycleWorkItem = nil
        if cyclingGroup === group { cyclingGroup = nil }
        resyncWorkItems[group.id]?.cancel()
        resyncWorkItems.removeValue(forKey: group.id)

        let delta = group.tabBarSqueezeDelta
        for window in group.windows {
            windowObserver.stopObserving(window: window)
            if delta > 0, let frame = AccessibilityHelper.getFrame(of: window.element) {
                let expandedFrame = CGRect(
                    x: frame.origin.x,
                    y: frame.origin.y - delta,
                    width: frame.width,
                    height: frame.height + delta
                )
                AccessibilityHelper.setFrame(of: window.element, to: expandedFrame)
            }
        }

        groupManager.dissolveGroup(group)
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

    // MARK: - AXObserver Handlers

    /// Clamp a window frame so the tab bar has room above it within the visible screen area.
    private func clampFrameForTabBar(_ frame: CGRect) -> CGRect {
        let visibleFrame = CoordinateConverter.visibleFrameInAX(at: frame.origin)
        let tabBarHeight = TabBarPanel.tabBarHeight
        var adjusted = frame
        if frame.origin.y < visibleFrame.origin.y + tabBarHeight {
            let delta = (visibleFrame.origin.y + tabBarHeight) - frame.origin.y
            adjusted.origin.y += delta
            adjusted.size.height = max(adjusted.size.height - delta, tabBarHeight)
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
        // Only update squeeze delta when clamping actually moved the window;
        // otherwise preserve the existing delta so we can still expand on quit.
        if adjustedFrame.origin.y != frame.origin.y {
            group.tabBarSqueezeDelta = adjustedFrame.origin.y - frame.origin.y
        }

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
        evaluateAutoCapture()
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
        // Only update squeeze delta when clamping actually moved the window;
        // otherwise preserve the existing delta so we can still expand on quit.
        if adjustedFrame.origin.y != frame.origin.y {
            group.tabBarSqueezeDelta = adjustedFrame.origin.y - frame.origin.y
        }

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
        evaluateAutoCapture()

        // Schedule a delayed re-sync to catch animated resizes (e.g. double-click
        // maximize). macOS may fire the notification before the animation finishes,
        // so we re-read the frame after a short delay and re-sync if it changed.
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

            group.frame = clamped
            let others = group.windows.filter { $0.id != activeWindow.id }
            self.suppressNotifications(for: others.map(\.id))
            for window in others {
                AccessibilityHelper.setFrame(of: window.element, to: clamped)
            }
            panel.positionAbove(windowFrame: clamped)
            panel.orderAbove(windowID: activeWindow.id)
            self.evaluateAutoCapture()
        }
        resyncWorkItems[groupID] = resync
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: resync)
    }

    private func handleWindowFocused(pid: pid_t, element: AXUIElement) {
        guard let windowID = AccessibilityHelper.windowID(for: element),
              let group = groupManager.group(for: windowID),
              let panel = tabBarPanels[group.id] else { return }

        group.switchTo(windowID: windowID)
        lastActiveGroupID = group.id
        if !group.isCycling, !isCycleCooldownActive {
            group.recordFocus(windowID: windowID)
        }
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
        evaluateAutoCapture()
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
        guard result == .success,
              let focusedRef = focusedValue else { return }
        let windowElement = focusedRef as! AXUIElement // swiftlint:disable:this force_cast

        guard let windowID = AccessibilityHelper.windowID(for: windowElement),
              let group = groupManager.group(for: windowID),
              let panel = tabBarPanels[group.id] else { return }

        group.switchTo(windowID: windowID)
        lastActiveGroupID = group.id
        if !group.isCycling, !isCycleCooldownActive {
            group.recordFocus(windowID: windowID)
        }
        panel.orderAbove(windowID: windowID)
    }

    // MARK: - Auto-Capture

    private static let systemBundleIDs: Set<String> = [
        "com.apple.dock",
        "com.apple.notificationcenterui",
        "com.apple.Spotlight",
    ]

    /// Check if a group's windows fill a screen (with tolerance for grid snapping, dock auto-hide).
    private func isGroupMaximized(_ group: TabGroup) -> (Bool, NSScreen?) {
        guard let screen = CoordinateConverter.screen(containingAXPoint: group.frame.origin) else {
            return (false, nil)
        }
        let visibleFrame = CoordinateConverter.visibleFrameInAX(for: screen)
        // Total group rect = frame expanded up by tabBarSqueezeDelta
        let groupRect = CGRect(
            x: group.frame.origin.x,
            y: group.frame.origin.y - group.tabBarSqueezeDelta,
            width: group.frame.width,
            height: group.frame.height + group.tabBarSqueezeDelta
        )
        let tolerance: CGFloat = 20
        return (
            abs(groupRect.origin.x - visibleFrame.origin.x) <= tolerance &&
            abs(groupRect.origin.y - visibleFrame.origin.y) <= tolerance &&
            abs(groupRect.width - visibleFrame.width) <= tolerance &&
            abs(groupRect.height - visibleFrame.height) <= tolerance,
            screen
        )
    }

    /// Check that all ungrouped on-screen windows on this screen belong to the group
    /// (i.e. there are no stray ungrouped windows), and at least one group window is
    /// visible on the screen.
    private func allWindowsOnScreenBelongToGroup(_ group: TabGroup, on screen: NSScreen) -> Bool {
        let visibleFrame = CoordinateConverter.visibleFrameInAX(for: screen)
        let allWindows = windowManager.windowsInZOrder()

        // Check no ungrouped windows are on this screen
        for window in allWindows {
            guard !groupManager.isWindowGrouped(window.id) else { continue }
            if Self.systemBundleIDs.contains(window.bundleID) { continue }
            guard let frame = AccessibilityHelper.getFrame(of: window.element) else { continue }
            if visibleFrame.intersects(frame) {
                return false
            }
        }

        // Verify at least one group window is on this screen
        let hasWindowOnScreen = group.windows.contains { window in
            guard let frame = AccessibilityHelper.getFrame(of: window.element) else { return false }
            return visibleFrame.intersects(frame)
        }
        return hasWindowOnScreen
    }

    /// Evaluate whether auto-capture should be activated or deactivated.
    func evaluateAutoCapture() {
        guard sessionConfig.autoCaptureEnabled else { return }

        if let activeGroup = autoCaptureGroup,
           let activeScreen = autoCaptureScreen {
            // Currently active — verify still eligible
            let (maximized, _) = isGroupMaximized(activeGroup)
            if !maximized || !allWindowsOnScreenBelongToGroup(activeGroup, on: activeScreen) {
                deactivateAutoCapture()
            }
            return
        }

        // Not active — scan for eligible group
        for group in groupManager.groups {
            let (maximized, screen) = isGroupMaximized(group)
            guard maximized, let screen else { continue }
            if allWindowsOnScreenBelongToGroup(group, on: screen) {
                activateAutoCapture(for: group, on: screen)
                return
            }
        }
    }

    private func activateAutoCapture(for group: TabGroup, on screen: NSScreen) {
        autoCaptureGroup = group
        autoCaptureScreen = screen

        // Observe all regular (GUI) apps — not just those with on-screen windows,
        // since a background app could create a window at any time.
        let ownPID = ProcessInfo.processInfo.processIdentifier
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            let pid = app.processIdentifier
            guard pid != ownPID else { continue }
            addAutoCaptureObserver(for: pid)
        }

        // Watch for new app launches
        let launchToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.addAutoCaptureObserver(for: app.processIdentifier)
        }

        let terminateToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.removeAutoCaptureObserver(for: app.processIdentifier)
        }

        // Watch for space changes and display config changes
        let spaceToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.evaluateAutoCapture()
        }

        let screenToken = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.evaluateAutoCapture()
        }

        autoCaptureNotificationTokens = [launchToken, terminateToken, spaceToken]
        autoCaptureDefaultCenterTokens = [screenToken]

        Logger.log("[AutoCapture] Activated for group \(group.id) on \(screen.localizedName), observing \(autoCaptureObservers.count) PIDs")
    }

    private func deactivateAutoCapture() {
        guard autoCaptureGroup != nil else { return }

        for (pid, observer) in autoCaptureObservers {
            if let appElement = autoCaptureAppElements[pid] {
                AccessibilityHelper.removeNotification(
                    observer: observer,
                    element: appElement,
                    notification: kAXWindowCreatedNotification as String
                )
            }
            AccessibilityHelper.removeObserver(observer)
        }
        autoCaptureObservers.removeAll()
        autoCaptureAppElements.removeAll()

        for token in autoCaptureNotificationTokens {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        autoCaptureNotificationTokens.removeAll()
        for token in autoCaptureDefaultCenterTokens {
            NotificationCenter.default.removeObserver(token)
        }
        autoCaptureDefaultCenterTokens.removeAll()

        Logger.log("[AutoCapture] Deactivated")
        autoCaptureGroup = nil
        autoCaptureScreen = nil
    }

    private func addAutoCaptureObserver(for pid: pid_t) {
        guard autoCaptureObservers[pid] == nil else { return }

        let callback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon else { return }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()
            var pid: pid_t = 0
            AXUIElementGetPid(element, &pid)
            delegate.handleWindowCreated(element: element, pid: pid)
        }

        guard let observer = AccessibilityHelper.createObserver(for: pid, callback: callback) else { return }
        let appElement = AccessibilityHelper.appElement(for: pid)
        let context = Unmanaged.passUnretained(self).toOpaque()
        AccessibilityHelper.addNotification(
            observer: observer,
            element: appElement,
            notification: kAXWindowCreatedNotification as String,
            context: context
        )
        autoCaptureObservers[pid] = observer
        autoCaptureAppElements[pid] = appElement
    }

    private func removeAutoCaptureObserver(for pid: pid_t) {
        guard let observer = autoCaptureObservers.removeValue(forKey: pid) else { return }
        if let appElement = autoCaptureAppElements.removeValue(forKey: pid) {
            AccessibilityHelper.removeNotification(
                observer: observer,
                element: appElement,
                notification: kAXWindowCreatedNotification as String
            )
        }
        AccessibilityHelper.removeObserver(observer)
    }

    private func handleWindowCreated(element: AXUIElement, pid: pid_t) {
        guard autoCaptureGroup != nil else { return }

        // Delay to let the window settle its frame
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self,
                  let group = self.autoCaptureGroup,
                  let screen = self.autoCaptureScreen else { return }

            guard let window = self.windowManager.buildWindowInfo(element: element, pid: pid) else { return }

            // Skip if already grouped
            guard !self.groupManager.isWindowGrouped(window.id) else { return }

            // Skip tiny/zero-size windows
            if let size = AccessibilityHelper.getSize(of: element),
               size.width < 200 || size.height < 150 {
                return
            }

            // Check window is on the auto-capture screen
            guard let frame = AccessibilityHelper.getFrame(of: element) else { return }
            let visibleFrame = CoordinateConverter.visibleFrameInAX(for: screen)
            guard visibleFrame.intersects(frame) else { return }

            Logger.log("[AutoCapture] Capturing window \(window.id) (\(window.appName): \(window.title))")
            self.suppressNotifications(for: [window.id])
            self.addWindow(window, to: group)
            self.evaluateAutoCapture()
        }
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
            // If group was dissolved, clean up the panel (and expand
            // the surviving window if it belongs to a different app).
            if !groupManager.groups.contains(where: { $0.id == group.id }),
               let panel = tabBarPanels[group.id] {
                if let survivor = group.windows.first, survivor.ownerPID != pid {
                    handleGroupDissolution(group: group, panel: panel)
                } else {
                    // All remaining windows are from the terminated app —
                    // nothing to expand, just tear down the panel.
                    if cyclingGroup === group { cyclingGroup = nil }
                    cycleWorkItem?.cancel()
                    cycleWorkItem = nil
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

// Safe array subscript
extension Array {
    subscript(safe index: Int) -> Element? {
        index >= 0 && index < count ? self[index] : nil
    }
}
