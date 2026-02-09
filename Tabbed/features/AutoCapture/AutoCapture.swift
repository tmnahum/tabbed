import AppKit

// MARK: - Auto-Capture

extension AppDelegate {

    /// Check if a group has any windows visible on the current Space.
    /// Uses the on-screen CG window list which only includes current-space windows.
    func isGroupOnCurrentSpace(_ group: TabGroup) -> Bool {
        let onScreenIDs = Set(
            AccessibilityHelper.getWindowList()
                .compactMap { $0[kCGWindowNumber as String] as? CGWindowID }
        )
        return group.windows.contains { onScreenIDs.contains($0.id) }
    }

    func isGroupMaximized(_ group: TabGroup) -> (Bool, NSScreen?) {
        guard let screen = CoordinateConverter.screen(containingAXPoint: group.frame.origin) else {
            Logger.log("[AutoCapture] isGroupMaximized: no screen for origin \(group.frame.origin)")
            return (false, nil)
        }
        let visibleFrame = CoordinateConverter.visibleFrameInAX(for: screen)
        let maximized = ScreenCompensation.isMaximized(
            groupFrame: group.frame,
            squeezeDelta: group.tabBarSqueezeDelta,
            visibleFrame: visibleFrame
        )
        if !maximized {
            Logger.log("[AutoCapture] isGroupMaximized: NO — groupFrame=\(group.frame) delta=\(group.tabBarSqueezeDelta) visibleFrame=\(visibleFrame)")
        }
        return (maximized, screen)
    }

    func evaluateAutoCapture() {
        let mode = sessionConfig.autoCaptureMode
        guard mode != .never else {
            Logger.log("[AutoCapture] evaluate: disabled in config")
            return
        }

        // Re-validate already-active group
        if let activeGroup = autoCaptureGroup,
           let activeScreen = autoCaptureScreen {
            if !isGroupOnCurrentSpace(activeGroup) {
                Logger.log("[AutoCapture] evaluate: group not on current space, deactivating")
                deactivateAutoCapture()
                return
            }

            switch mode {
            case .never:
                return // unreachable, handled above
            case .always:
                // Always valid as long as it's on current space
                if let newScreen = screenForGroup(activeGroup), newScreen != activeScreen {
                    Logger.log("[AutoCapture] evaluate: group moved to \(newScreen.localizedName)")
                    autoCaptureScreen = newScreen
                }
            case .whenMaximized:
                let (maximized, newScreen) = isGroupMaximized(activeGroup)
                if !maximized {
                    Logger.log("[AutoCapture] evaluate: group no longer maximized, deactivating")
                    deactivateAutoCapture()
                } else if let newScreen, newScreen != activeScreen {
                    Logger.log("[AutoCapture] evaluate: group moved to \(newScreen.localizedName)")
                    autoCaptureScreen = newScreen
                }
            case .whenOnly:
                let groupsOnSpace = groupManager.groups.filter { isGroupOnCurrentSpace($0) }
                if groupsOnSpace.count != 1 || groupsOnSpace.first?.id != activeGroup.id {
                    Logger.log("[AutoCapture] evaluate: no longer only group on space, deactivating")
                    deactivateAutoCapture()
                } else if let newScreen = screenForGroup(activeGroup), newScreen != activeScreen {
                    Logger.log("[AutoCapture] evaluate: group moved to \(newScreen.localizedName)")
                    autoCaptureScreen = newScreen
                }
            }
            return
        }

        // Try to find a group to activate
        Logger.log("[AutoCapture] evaluate: checking \(groupManager.groups.count) groups for activation (mode=\(mode.rawValue))")

        switch mode {
        case .never:
            return
        case .always:
            if let (group, screen) = mostRecentGroupOnCurrentSpace() {
                activateAutoCapture(for: group, on: screen)
            }
        case .whenMaximized:
            for group in groupManager.groups {
                let onSpace = isGroupOnCurrentSpace(group)
                let (maximized, screen) = isGroupMaximized(group)
                Logger.log("[AutoCapture] evaluate: group \(group.id) — onSpace=\(onSpace), maximized=\(maximized)")
                guard onSpace else { continue }
                guard maximized, let screen else { continue }
                activateAutoCapture(for: group, on: screen)
                return
            }
        case .whenOnly:
            let groupsOnSpace = groupManager.groups.filter { isGroupOnCurrentSpace($0) }
            if groupsOnSpace.count == 1, let group = groupsOnSpace.first,
               let screen = screenForGroup(group) {
                Logger.log("[AutoCapture] evaluate: only group on space — \(group.id)")
                activateAutoCapture(for: group, on: screen)
            }
        }
    }

    /// Find the most recently used group on the current space via globalMRU.
    /// Falls back to the first group on the current space if none appear in MRU.
    private func mostRecentGroupOnCurrentSpace() -> (TabGroup, NSScreen)? {
        // Walk MRU for most recent group on current space
        for entry in globalMRU {
            guard case .group(let id) = entry,
                  let group = groupManager.groups.first(where: { $0.id == id }),
                  isGroupOnCurrentSpace(group),
                  let screen = screenForGroup(group) else { continue }
            return (group, screen)
        }
        // Fallback: first group on current space
        for group in groupManager.groups {
            guard isGroupOnCurrentSpace(group),
                  let screen = screenForGroup(group) else { continue }
            return (group, screen)
        }
        return nil
    }

    private func screenForGroup(_ group: TabGroup) -> NSScreen? {
        CoordinateConverter.screen(containingAXPoint: group.frame.origin)
    }

    func activateAutoCapture(for group: TabGroup, on screen: NSScreen) {
        autoCaptureGroup = group
        autoCaptureScreen = screen

        let ownPID = ProcessInfo.processInfo.processIdentifier
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            let pid = app.processIdentifier
            guard pid != ownPID else { continue }
            addAutoCaptureObserver(for: pid)
        }

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

        let screenToken = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.evaluateAutoCapture()
        }

        autoCaptureNotificationTokens = [launchToken, terminateToken]
        autoCaptureDefaultCenterTokens = [screenToken]

        Logger.log("[AutoCapture] Activated for group \(group.id) on \(screen.localizedName), observing \(autoCaptureObservers.count) PIDs")
    }

    func deactivateAutoCapture() {
        guard autoCaptureGroup != nil else { return }

        // Clean up pending window watchers before removing observers
        for (element, pid) in pendingAutoCaptureWindows {
            if let observer = autoCaptureObservers[pid] {
                AccessibilityHelper.removeNotification(
                    observer: observer, element: element,
                    notification: kAXMovedNotification as String
                )
                AccessibilityHelper.removeNotification(
                    observer: observer, element: element,
                    notification: kAXResizedNotification as String
                )
            }
        }
        pendingAutoCaptureWindows.removeAll()

        for (pid, observer) in autoCaptureObservers {
            if let appElement = autoCaptureAppElements[pid] {
                AccessibilityHelper.removeNotification(
                    observer: observer,
                    element: appElement,
                    notification: kAXWindowCreatedNotification as String
                )
                AccessibilityHelper.removeNotification(
                    observer: observer,
                    element: appElement,
                    notification: kAXFocusedWindowChangedNotification as String
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

    func addAutoCaptureObserver(for pid: pid_t) {
        guard autoCaptureObservers[pid] == nil else { return }

        let callback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon else { return }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()
            var pid: pid_t = 0
            AXUIElementGetPid(element, &pid)
            let notifString = notification as String
            if notifString == kAXWindowCreatedNotification as String {
                delegate.handleWindowCreated(element: element, pid: pid)
            } else if notifString == kAXFocusedWindowChangedNotification as String {
                delegate.handleAutoCaptureFocusChanged(element: element, pid: pid)
            } else if notifString == kAXMovedNotification as String
                        || notifString == kAXResizedNotification as String {
                delegate.handlePendingWindowChanged(element: element, pid: pid)
            }
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
        AccessibilityHelper.addNotification(
            observer: observer,
            element: appElement,
            notification: kAXFocusedWindowChangedNotification as String,
            context: context
        )
        autoCaptureObservers[pid] = observer
        autoCaptureAppElements[pid] = appElement
    }

    func removeAutoCaptureObserver(for pid: pid_t) {
        guard let observer = autoCaptureObservers.removeValue(forKey: pid) else { return }
        pendingAutoCaptureWindows.removeAll { $0.pid == pid }
        if let appElement = autoCaptureAppElements.removeValue(forKey: pid) {
            AccessibilityHelper.removeNotification(
                observer: observer,
                element: appElement,
                notification: kAXWindowCreatedNotification as String
            )
            AccessibilityHelper.removeNotification(
                observer: observer,
                element: appElement,
                notification: kAXFocusedWindowChangedNotification as String
            )
        }
        AccessibilityHelper.removeObserver(observer)
    }

    func handleWindowCreated(element: AXUIElement, pid: pid_t) {
        guard autoCaptureGroup != nil else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, self.autoCaptureGroup != nil else { return }
            if self.captureWindowIfEligible(element: element, pid: pid, source: "created") {
                return
            }
            // Window not ready yet (still being dragged, animating, etc.)
            // Watch for resize/move events to retry when the window settles.
            self.watchPendingWindow(element: element, pid: pid)
        }
    }

    func handleAutoCaptureFocusChanged(element: AXUIElement, pid: pid_t) {
        guard autoCaptureGroup != nil else { return }

        let windowElement: AXUIElement
        if AccessibilityHelper.windowID(for: element) != nil {
            windowElement = element
        } else {
            var focusedWindow: AnyObject?
            let result = AXUIElementCopyAttributeValue(
                element, kAXFocusedWindowAttribute as CFString, &focusedWindow
            )
            guard result == .success, let ref = focusedWindow else { return }
            windowElement = ref as! AXUIElement // swiftlint:disable:this force_cast
        }

        captureWindowIfEligible(element: windowElement, pid: pid, source: "focus")
    }

    // MARK: - Pending Window Watchers

    /// Register per-window move/resize watchers for windows that weren't immediately
    /// capturable (e.g. browser tab drag-outs that are still mid-drag when created).
    func watchPendingWindow(element: AXUIElement, pid: pid_t) {
        guard let observer = autoCaptureObservers[pid] else { return }
        if pendingAutoCaptureWindows.contains(where: { $0.element === element }) { return }

        let context = Unmanaged.passUnretained(self).toOpaque()
        AccessibilityHelper.addNotification(
            observer: observer, element: element,
            notification: kAXMovedNotification as String, context: context
        )
        AccessibilityHelper.addNotification(
            observer: observer, element: element,
            notification: kAXResizedNotification as String, context: context
        )
        pendingAutoCaptureWindows.append((element: element, pid: pid))
        Logger.log("[AutoCapture] Watching pending window for pid \(pid)")
    }

    func handlePendingWindowChanged(element: AXUIElement, pid: pid_t) {
        guard autoCaptureGroup != nil else { return }
        if captureWindowIfEligible(element: element, pid: pid, source: "pending") {
            removePendingWindowWatch(element: element, pid: pid)
        }
    }

    func removePendingWindowWatch(element: AXUIElement, pid: pid_t) {
        guard let observer = autoCaptureObservers[pid] else { return }
        AccessibilityHelper.removeNotification(
            observer: observer, element: element,
            notification: kAXMovedNotification as String
        )
        AccessibilityHelper.removeNotification(
            observer: observer, element: element,
            notification: kAXResizedNotification as String
        )
        pendingAutoCaptureWindows.removeAll { $0.element === element }
    }

    // MARK: - Capture

    @discardableResult
    func captureWindowIfEligible(element: AXUIElement, pid: pid_t, source: String) -> Bool {
        guard let group = autoCaptureGroup,
              let screen = autoCaptureScreen else {
            Logger.log("[AutoCapture] captureIfEligible[\(source)]: no active group/screen")
            return false
        }

        guard let window = WindowDiscovery.buildWindowInfo(element: element, pid: pid) else {
            Logger.log("[AutoCapture] captureIfEligible[\(source)]: buildWindowInfo failed for pid \(pid)")
            return false
        }

        guard !groupManager.isWindowGrouped(window.id) else { return false }

        if let size = AccessibilityHelper.getSize(of: element),
           size.width < 200 || size.height < 150 {
            Logger.log("[AutoCapture] captureIfEligible[\(source)]: too small \(size) — \(window.appName): \(window.title)")
            return false
        }

        guard let frame = AccessibilityHelper.getFrame(of: element) else {
            Logger.log("[AutoCapture] captureIfEligible[\(source)]: no frame — \(window.appName): \(window.title)")
            return false
        }
        let visibleFrame = CoordinateConverter.visibleFrameInAX(for: screen)
        guard visibleFrame.intersects(frame) else {
            Logger.log("[AutoCapture] captureIfEligible[\(source)]: not on screen — \(window.appName): \(window.title) frame=\(frame) visible=\(visibleFrame)")
            return false
        }

        // Reject windows on a different space than the capture group
        if group.spaceID != 0,
           let windowSpace = SpaceUtils.spaceID(for: window.id),
           windowSpace != group.spaceID {
            Logger.log("[AutoCapture] captureIfEligible[\(source)]: wrong space (\(windowSpace) != \(group.spaceID)) — \(window.appName): \(window.title)")
            return false
        }

        Logger.log("[AutoCapture] Capturing window \(window.id) (\(window.appName): \(window.title)) [\(source)]")
        setExpectedFrame(group.frame, for: [window.id])
        addWindow(window, to: group, afterActive: true)
        // Note: addWindow already calls evaluateAutoCapture()
        return true
    }
}
