import AppKit
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let windowManager = WindowManager()
    let groupManager = GroupManager()
    let windowObserver = WindowObserver()

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    var windowPickerPanel: NSPanel?
    private var settingsWindow: NSWindow?
    private var keyMonitor: Any?
    var tabBarPanels: [UUID: TabBarPanel] = [:]
    var hotkeyManager: HotkeyManager?
    var lastActiveGroupID: UUID?
    var pendingSessionSnapshots: [GroupSnapshot]?
    let sessionState = SessionState()
    var expectedFrames: [CGWindowID: (frame: CGRect, deadline: Date)] = [:]
    var resyncWorkItems: [UUID: DispatchWorkItem] = [:]
    var autoCaptureGroup: TabGroup?
    var autoCaptureScreen: NSScreen?
    var autoCaptureObservers: [pid_t: AXObserver] = [:]
    var autoCaptureAppElements: [pid_t: AXUIElement] = [:]
    var autoCaptureNotificationTokens: [NSObjectProtocol] = []
    var autoCaptureDefaultCenterTokens: [NSObjectProtocol] = []
    var pendingAutoCaptureWindows: [(element: AXUIElement, pid: pid_t)] = []
    var knownWindowIDsByPID: [pid_t: Set<CGWindowID>] = [:]
    var launchGraceUntilByPID: [pid_t: Date] = [:]
    var suppressedAutoJoinWindowIDs: Set<CGWindowID> = []
    var captureRetryWorkItems: [AutoCaptureRetryKey: DispatchWorkItem] = [:]
    var sessionConfig = SessionConfig.load()
    var switcherController = SwitcherController()
    var switcherConfig = SwitcherConfig.load()
    var tabBarConfig = TabBarConfig.load()
    var addWindowLauncherConfig = AddWindowLauncherConfig.load()
    let launcherEngine = LauncherEngine()
    let appCatalogService = AppCatalogService()
    let browserProviderResolver = BrowserProviderResolver()
    lazy var launchOrchestrator: LaunchOrchestrator = {
        var dependencies = LaunchOrchestrator.Dependencies()
        dependencies.isWindowGrouped = { [weak self] windowID in
            self?.groupManager.isWindowGrouped(windowID) ?? false
        }
        return LaunchOrchestrator(
            resolver: browserProviderResolver,
            dependencies: dependencies
        )
    }()
    let useLegacyWindowPicker = false
    weak var cyclingGroup: TabGroup?
    var cycleEndTime: Date?
    static let cycleCooldownDuration: TimeInterval = 0.15
    var globalMRU: [MRUEntry] = []
    /// Set during tab bar drag to suppress window move/resize handlers for the dragged group.
    var barDraggingGroupID: UUID?
    /// Group frame at bar drag start, for absolute positioning.
    var barDragInitialFrame: CGRect?
    /// Debounce token for space-change handling — lets the animation settle before querying.
    var spaceChangeWorkItem: DispatchWorkItem?

    var isCycleCooldownActive: Bool {
        cycleEndTime.map { Date().timeIntervalSince($0) < Self.cycleCooldownDuration } ?? false
    }

    var isExplicitQuit = false

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        isExplicitQuit ? .terminateNow : .terminateCancel
    }

    private func installSignalHandler() {
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        source.setEventHandler { [weak self] in
            self?.isExplicitQuit = true
            NSApplication.shared.terminate(nil)
        }
        source.resume()
        signal(SIGINT, SIG_IGN)
        signalSource = source
    }
    private var signalSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Logger.log("[STARTUP] Tabbed launched — debug build \(Date())")
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

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleAppTerminated(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleAppActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleSpaceChangeCheck()
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags == .command, event.charactersIgnoringModifiers == "," {
                self?.showSettings()
                return nil
            }
            return event
        }

        let config = ShortcutConfig.load()
        let hkm = HotkeyManager(config: config)

        hkm.onNewTab = { [weak self] in
            self?.handleHotkeyNewTab()
        }
        hkm.onReleaseTab = { [weak self] in
            self?.handleHotkeyReleaseTab()
        }
        hkm.onCloseTab = { [weak self] in
            self?.handleHotkeyCloseTab()
        }
        hkm.onGroupAllInSpace = { [weak self] in
            self?.groupAllInSpace()
        }
        hkm.onCycleTab = { [weak self] reverse in
            self?.handleHotkeyCycleTab(reverse: reverse)
        }
        hkm.onSwitchToTab = { [weak self] index in
            self?.handleHotkeySwitchToTab(index)
        }
        hkm.onModifierReleased = { [weak self] in
            self?.handleModifierReleased()
        }
        hkm.onGlobalSwitcher = { [weak self] reverse in
            self?.handleGlobalSwitcher(reverse: reverse)
        }
        hkm.onArrowLeft  = { [weak self] in self?.handleSwitcherArrow(.left) }
        hkm.onArrowRight = { [weak self] in self?.handleSwitcherArrow(.right) }
        hkm.onArrowUp    = { [weak self] in self?.handleSwitcherArrow(.up) }
        hkm.onArrowDown  = { [weak self] in self?.handleSwitcherArrow(.down) }
        hkm.onEscapePressed = { [weak self] in
            guard let self, self.switcherController.isActive else { return false }
            self.hotkeyManager?.stopModifierWatch()
            self.switcherController.dismiss()
            if let group = self.cyclingGroup {
                group.endCycle()
                self.cyclingGroup = nil
            }
            return true
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
            shortcutConfig: hotkeyManager?.config ?? .default,
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
                self?.disbandGroup(group)
            },
            onQuitGroup: { [weak self] group in
                guard let self else { return }
                self.popover.performClose(nil)

                let appNames = Set(group.windows.map(\.appName))
                let description = appNames.sorted().joined(separator: ", ")

                let alert = NSAlert()
                alert.messageText = "Quit all windows in this group?"
                alert.informativeText = "This will close \(group.windows.count) window\(group.windows.count == 1 ? "" : "s") (\(description))."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Quit All")
                alert.addButton(withTitle: "Cancel")

                guard alert.runModal() == .alertFirstButtonReturn else { return }
                self.quitGroup(group)
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
        switcherController.dismiss()
        deactivateAutoCapture()
        windowObserver.stopAll()
        let mruGroupOrder = globalMRU.compactMap { entry -> UUID? in
            if case .group(let id) = entry { return id } else { return nil }
        }
        SessionManager.saveSession(groups: groupManager.groups, mruGroupOrder: mruGroupOrder)
        for group in groupManager.groups {
            let delta = group.tabBarSqueezeDelta
            guard delta > 0 else { continue }
            for window in group.windows {
                if !window.isFullscreened, let frame = AccessibilityHelper.getFrame(of: window.element) {
                    let expandedFrame = ScreenCompensation.expandFrame(frame, undoingSqueezeDelta: delta)
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
            contentRect: NSRect(x: 0, y: 0, width: SettingsView.contentWidth, height: SettingsTab.general.contentHeight),
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
            switcherConfig: switcherConfig,
            launcherConfig: addWindowLauncherConfig,
            tabBarConfig: tabBarConfig,
            onConfigChanged: { [weak self] newConfig in
                newConfig.save()
                self?.hotkeyManager?.updateConfig(newConfig)
            },
            onSessionConfigChanged: { [weak self] newConfig in
                newConfig.save()
                self?.sessionConfig = newConfig
                if newConfig.autoCaptureMode != .never {
                    self?.evaluateAutoCapture()
                } else {
                    self?.deactivateAutoCapture()
                }
            },
            onSwitcherConfigChanged: { [weak self] newConfig in
                newConfig.save()
                self?.switcherConfig = newConfig
            },
            onLauncherConfigChanged: { [weak self] newConfig in
                newConfig.save()
                self?.addWindowLauncherConfig = newConfig
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
}

// Safe array subscript
extension Array {
    subscript(safe index: Int) -> Element? {
        index >= 0 && index < count ? self[index] : nil
    }
}
