import AppKit

// MARK: - Auto-Capture

extension AppDelegate {

    static let systemBundleIDs: Set<String> = [
        "com.apple.dock",
        "com.apple.notificationcenterui",
        "com.apple.Spotlight",
    ]

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
            return (false, nil)
        }
        let visibleFrame = CoordinateConverter.visibleFrameInAX(for: screen)
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

    func allWindowsOnScreenBelongToGroup(_ group: TabGroup, on screen: NSScreen) -> Bool {
        let visibleFrame = CoordinateConverter.visibleFrameInAX(for: screen)
        let allWindows = WindowDiscovery.currentSpace()

        for window in allWindows {
            guard !groupManager.isWindowGrouped(window.id) else { continue }
            if Self.systemBundleIDs.contains(window.bundleID) { continue }
            guard let frame = AccessibilityHelper.getFrame(of: window.element) else { continue }
            if visibleFrame.intersects(frame) {
                return false
            }
        }

        let hasWindowOnScreen = group.windows.contains { window in
            guard let frame = AccessibilityHelper.getFrame(of: window.element) else { return false }
            return visibleFrame.intersects(frame)
        }
        return hasWindowOnScreen
    }

    func evaluateAutoCapture() {
        guard sessionConfig.autoCaptureEnabled else { return }

        if let activeGroup = autoCaptureGroup,
           let activeScreen = autoCaptureScreen {
            if !isGroupOnCurrentSpace(activeGroup) {
                deactivateAutoCapture()
                return
            }
            let (maximized, _) = isGroupMaximized(activeGroup)
            if !maximized || !allWindowsOnScreenBelongToGroup(activeGroup, on: activeScreen) {
                deactivateAutoCapture()
            }
            return
        }

        for group in groupManager.groups {
            guard isGroupOnCurrentSpace(group) else { continue }
            let (maximized, screen) = isGroupMaximized(group)
            guard maximized, let screen else { continue }
            if allWindowsOnScreenBelongToGroup(group, on: screen) {
                activateAutoCapture(for: group, on: screen)
                return
            }
        }
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

    func deactivateAutoCapture() {
        guard autoCaptureGroup != nil else { return }

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
            if WindowDiscovery.buildWindowInfo(element: element, pid: pid) != nil {
                self.captureWindowIfEligible(element: element, pid: pid, source: "created")
            } else {
                Logger.log("[AutoCapture] Window not in CG list yet for pid \(pid), will retry")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    self?.captureWindowIfEligible(element: element, pid: pid, source: "created-retry")
                }
            }
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

    func captureWindowIfEligible(element: AXUIElement, pid: pid_t, source: String) {
        guard let group = autoCaptureGroup,
              let screen = autoCaptureScreen else { return }

        guard let window = WindowDiscovery.buildWindowInfo(element: element, pid: pid) else { return }

        guard !groupManager.isWindowGrouped(window.id) else { return }

        if let size = AccessibilityHelper.getSize(of: element),
           size.width < 200 || size.height < 150 {
            return
        }

        guard let frame = AccessibilityHelper.getFrame(of: element) else { return }
        let visibleFrame = CoordinateConverter.visibleFrameInAX(for: screen)
        guard visibleFrame.intersects(frame) else { return }

        Logger.log("[AutoCapture] Capturing window \(window.id) (\(window.appName): \(window.title)) [\(source)]")
        setExpectedFrame(group.frame, for: [window.id])
        addWindow(window, to: group)
        evaluateAutoCapture()
    }
}
