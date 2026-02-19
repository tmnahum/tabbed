import AppKit

enum AutoCapturePolicy {
    static let launchGraceDuration: TimeInterval = 5.0
    static let launchScanDelays: [TimeInterval] = [0.2, 0.6, 1.2, 2.5, 4.0]
    static let createdRetryDelays: [TimeInterval] = [0.15, 0.35, 0.75, 1.5]

    static func isWithinLaunchGrace(deadline: Date?, now: Date) -> Bool {
        guard let deadline else { return false }
        return now <= deadline
    }

    static func shouldAttemptFocusCapture(
        pid: pid_t,
        windowID: CGWindowID,
        now: Date,
        launchGraceUntilByPID: [pid_t: Date],
        knownWindowIDsByPID: [pid_t: Set<CGWindowID>]
    ) -> Bool {
        guard isWithinLaunchGrace(deadline: launchGraceUntilByPID[pid], now: now) else { return false }
        let knownWindowIDs = knownWindowIDsByPID[pid] ?? []
        return !knownWindowIDs.contains(windowID)
    }

    static func prunedSuppressedWindowIDs(
        _ suppressedWindowIDs: Set<CGWindowID>,
        windowExists: (CGWindowID) -> Bool
    ) -> Set<CGWindowID> {
        Set(suppressedWindowIDs.filter { windowExists($0) })
    }

    static func groupMatchesMode(
        mode: AutoCaptureMode,
        isMaximized: Bool,
        isOnlyGroupOnSpace: Bool
    ) -> Bool {
        switch mode {
        case .never:
            return false
        case .always:
            return true
        case .whenMaximized:
            return isMaximized
        case .whenOnly:
            return isOnlyGroupOnSpace
        case .whenMaximizedOrOnly:
            return isMaximized || isOnlyGroupOnSpace
        }
    }

    static func selectMostRecentGroupID(
        candidates: [UUID],
        lastActiveGroupID: UUID?,
        mruEntries: [MRUEntry]
    ) -> UUID? {
        guard !candidates.isEmpty else { return nil }
        let candidateSet = Set(candidates)

        if let lastActiveGroupID,
           candidateSet.contains(lastActiveGroupID) {
            return lastActiveGroupID
        }

        for entry in mruEntries {
            let groupID: UUID?
            switch entry {
            case .group(let id):
                groupID = id
            case .groupWindow(let id, _):
                groupID = id
            case .window:
                groupID = nil
            }
            guard let groupID, candidateSet.contains(groupID) else { continue }
            return groupID
        }

        return candidates.first
    }

    static func selectCaptureGroupID(
        candidates: [AutoCaptureWindowRoutingCandidate],
        windowFrame: CGRect,
        windowSpaceID: UInt64?,
        lastActiveGroupID: UUID?,
        mruEntries: [MRUEntry]
    ) -> UUID? {
        var matchingGroupIDs: [UUID] = []
        var seen: Set<UUID> = []

        for candidate in candidates {
            guard candidate.screenVisibleFrame.intersects(windowFrame) else { continue }
            if let windowSpaceID,
               candidate.groupSpaceID != 0,
               candidate.groupSpaceID != windowSpaceID {
                continue
            }
            if seen.insert(candidate.groupID).inserted {
                matchingGroupIDs.append(candidate.groupID)
            }
        }

        return selectMostRecentGroupID(
            candidates: matchingGroupIDs,
            lastActiveGroupID: lastActiveGroupID,
            mruEntries: mruEntries
        )
    }

    /// Seed known-window snapshots only when creating a fresh observer.
    /// Re-seeding on every evaluation is expensive and can stall the app,
    /// especially right after wake when AX is slow to respond.
    static func shouldSeedKnownWindows(
        requestedSeed: Bool,
        observerAlreadyExists: Bool
    ) -> Bool {
        requestedSeed && !observerAlreadyExists
    }
}

struct AutoCaptureRetryKey: Hashable {
    let pid: pid_t
    let windowID: CGWindowID
}

struct AutoCaptureWindowRoutingCandidate {
    let groupID: UUID
    let groupSpaceID: UInt64
    let screenVisibleFrame: CGRect
}

// MARK: - Auto-Capture

extension AppDelegate {

    private var shouldCaptureUnmatchedToStandaloneGroup: Bool {
        sessionConfig.autoCaptureMode != .never && sessionConfig.autoCaptureUnmatchedToNewGroup
    }

    /// Check if a group has any windows visible on the current Space.
    /// Uses the on-screen CG window list which only includes current-space windows.
    func isGroupOnCurrentSpace(_ group: TabGroup) -> Bool {
        let onScreenIDs = Set(
            AccessibilityHelper.getWindowList()
                .compactMap { $0[kCGWindowNumber as String] as? CGWindowID }
        )
        return group.managedWindows.contains { onScreenIDs.contains($0.id) }
    }

    func isWindowOnCurrentSpace(_ windowID: CGWindowID) -> Bool {
        let onScreenIDs = Set(
            AccessibilityHelper.getWindowList()
                .compactMap { $0[kCGWindowNumber as String] as? CGWindowID }
        )
        return onScreenIDs.contains(windowID)
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
        refreshMaximizedGroupCounters()
        let mode = sessionConfig.autoCaptureMode
        guard mode != .never else {
            Logger.log("[AutoCapture] evaluate: disabled in config")
            deactivateAutoCapture()
            return
        }

        Logger.log("[AutoCapture] evaluate: checking \(groupManager.groups.count) groups for activation (mode=\(mode.rawValue))")
        if let selected = selectedAutoCaptureGroup(for: mode) {
            if autoCaptureGroup?.id != selected.group.id {
                Logger.log("[AutoCapture] evaluate: selecting most recent eligible group \(selected.group.id)")
            }
            if autoCaptureGroup?.id != selected.group.id || autoCaptureScreen != selected.screen {
                activateAutoCapture(for: selected.group, on: selected.screen)
            } else {
                ensureAutoCaptureObservationActive()
            }
            return
        }

        Logger.log("[AutoCapture] evaluate: no eligible group for mode=\(mode.rawValue)")
        if shouldCaptureUnmatchedToStandaloneGroup {
            activateStandaloneAutoCapture()
        } else {
            deactivateAutoCapture()
        }
    }

    private func selectedAutoCaptureGroup(for mode: AutoCaptureMode) -> (group: TabGroup, screen: NSScreen)? {
        mostRecentCandidate(from: eligibleAutoCaptureGroups(for: mode))
    }

    private func eligibleAutoCaptureGroups(
        for mode: AutoCaptureMode
    ) -> [(group: TabGroup, screen: NSScreen)] {
        switch mode {
        case .never:
            return []
        case .always:
            return groupManager.groups.compactMap { group -> (group: TabGroup, screen: NSScreen)? in
                guard isGroupOnCurrentSpace(group),
                      let screen = screenForGroup(group) else { return nil }
                return (group: group, screen: screen)
            }
        case .whenMaximized:
            return groupManager.groups.compactMap { group -> (group: TabGroup, screen: NSScreen)? in
                let onSpace = isGroupOnCurrentSpace(group)
                let (maximized, screen) = isGroupMaximized(group)
                Logger.log("[AutoCapture] evaluate: group \(group.id) — onSpace=\(onSpace), maximized=\(maximized)")
                guard onSpace,
                      maximized,
                      let screen else { return nil }
                return (group: group, screen: screen)
            }
        case .whenOnly:
            let groupsOnSpace = groupManager.groups.filter { isGroupOnCurrentSpace($0) }
            guard groupsOnSpace.count == 1,
                  let group = groupsOnSpace.first,
                  let screen = screenForGroup(group) else { return [] }
            Logger.log("[AutoCapture] evaluate: only group on space — \(group.id)")
            return [(group: group, screen: screen)]
        case .whenMaximizedOrOnly:
            let groupsOnSpace = groupManager.groups.filter { isGroupOnCurrentSpace($0) }
            let onlyGroupID = groupsOnSpace.count == 1 ? groupsOnSpace.first?.id : nil

            return groupsOnSpace.compactMap { group -> (group: TabGroup, screen: NSScreen)? in
                let (maximized, maximizedScreen) = isGroupMaximized(group)
                let onlyGroupOnSpace = group.id == onlyGroupID
                Logger.log("[AutoCapture] evaluate: group \(group.id) — maximized=\(maximized), only=\(onlyGroupOnSpace)")
                guard AutoCapturePolicy.groupMatchesMode(
                    mode: mode,
                    isMaximized: maximized,
                    isOnlyGroupOnSpace: onlyGroupOnSpace
                ) else { return nil }
                guard let screen = maximizedScreen ?? screenForGroup(group) else { return nil }
                return (group: group, screen: screen)
            }
        }
    }

    private func targetAutoCaptureGroup(
        for windowID: CGWindowID,
        frame: CGRect,
        source: String
    ) -> (group: TabGroup, screen: NSScreen)? {
        let mode = sessionConfig.autoCaptureMode
        guard mode != .never else { return nil }

        let candidates = eligibleAutoCaptureGroups(for: mode)
        guard !candidates.isEmpty else { return nil }

        let routingCandidates = candidates.map { candidate in
            AutoCaptureWindowRoutingCandidate(
                groupID: candidate.group.id,
                groupSpaceID: candidate.group.spaceID,
                screenVisibleFrame: CoordinateConverter.visibleFrameInAX(for: candidate.screen)
            )
        }

        let windowSpaceID = SpaceUtils.spaceID(for: windowID)
        guard let selectedID = AutoCapturePolicy.selectCaptureGroupID(
            candidates: routingCandidates,
            windowFrame: frame,
            windowSpaceID: windowSpaceID,
            lastActiveGroupID: lastActiveGroupID,
            mruEntries: mruTracker.entries
        ) else {
            Logger.log(
                "[AutoCapture] captureIfEligible[\(source)]: no matching eligible group for frame=\(frame) space=\(windowSpaceID.map(String.init) ?? "unknown")"
            )
            return nil
        }

        guard let selected = candidates.first(where: { $0.group.id == selectedID }) else {
            return nil
        }

        if autoCaptureGroup?.id != selected.group.id || autoCaptureScreen != selected.screen {
            Logger.log("[AutoCapture] captureIfEligible[\(source)]: rerouting target group to \(selected.group.id)")
            activateAutoCapture(for: selected.group, on: selected.screen)
        }
        return selected
    }

    private func mostRecentCandidate(
        from candidates: [(group: TabGroup, screen: NSScreen)]
    ) -> (group: TabGroup, screen: NSScreen)? {
        guard !candidates.isEmpty else { return nil }
        let candidateIDs = candidates.map { $0.group.id }
        guard let selectedID = AutoCapturePolicy.selectMostRecentGroupID(
            candidates: candidateIDs,
            lastActiveGroupID: lastActiveGroupID,
            mruEntries: mruTracker.entries
        ) else {
            return nil
        }
        return candidates.first(where: { $0.group.id == selectedID }) ?? candidates.first
    }

    private func screenForGroup(_ group: TabGroup) -> NSScreen? {
        CoordinateConverter.screen(containingAXPoint: group.frame.origin)
    }

    private func isGroupOnlyOnCurrentSpace(_ group: TabGroup) -> Bool {
        let groupsOnSpace = groupManager.groups.filter { isGroupOnCurrentSpace($0) }
        return groupsOnSpace.count == 1 && groupsOnSpace.first?.id == group.id
    }

    func activateAutoCapture(for group: TabGroup, on screen: NSScreen) {
        autoCaptureGroup = group
        autoCaptureScreen = screen
        ensureAutoCaptureObservationActive()
        Logger.log("[AutoCapture] Activated for group \(group.id) on \(screen.localizedName), observing \(autoCaptureObservers.count) PIDs")
    }

    func activateStandaloneAutoCapture() {
        autoCaptureGroup = nil
        autoCaptureScreen = nil
        ensureAutoCaptureObservationActive()
        Logger.log("[AutoCapture] Standalone capture active (unmatched windows form one-tab groups), observing \(autoCaptureObservers.count) PIDs")
    }

    private func ensureAutoCaptureObservationActive() {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            let pid = app.processIdentifier
            guard pid != ownPID else { continue }
            let shouldSeed = AutoCapturePolicy.shouldSeedKnownWindows(
                requestedSeed: true,
                observerAlreadyExists: autoCaptureObservers[pid] != nil
            )
            addAutoCaptureObserver(for: pid, seedKnownWindows: shouldSeed)
        }

        if autoCaptureNotificationTokens.isEmpty {
            let launchToken = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self,
                      let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.activationPolicy == .regular else { return }

                let pid = app.processIdentifier
                if pid == ProcessInfo.processInfo.processIdentifier { return }

                self.addAutoCaptureObserver(for: pid, seedKnownWindows: false)
                self.launchGraceUntilByPID[pid] = Date().addingTimeInterval(AutoCapturePolicy.launchGraceDuration)
                if self.knownWindowIDsByPID[pid] == nil {
                    self.knownWindowIDsByPID[pid] = []
                }
                self.scheduleLaunchReconciliation(for: pid)
                Logger.log("[AutoCapture] launch-grace started for pid \(pid) (\(AutoCapturePolicy.launchGraceDuration)s)")
            }

            let terminateToken = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                self?.removeAutoCaptureObserver(for: app.processIdentifier)
            }

            autoCaptureNotificationTokens = [launchToken, terminateToken]
        }

        if autoCaptureDefaultCenterTokens.isEmpty {
            let screenToken = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.evaluateAutoCapture()
            }
            autoCaptureDefaultCenterTokens = [screenToken]
        }
    }

    func deactivateAutoCapture() {
        let hasActiveState = autoCaptureGroup != nil ||
            autoCaptureScreen != nil ||
            !autoCaptureObservers.isEmpty ||
            !autoCaptureNotificationTokens.isEmpty ||
            !autoCaptureDefaultCenterTokens.isEmpty ||
            !pendingAutoCaptureWindows.isEmpty ||
            !captureRetryWorkItems.isEmpty
        guard hasActiveState else { return }

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

        for (_, workItem) in captureRetryWorkItems {
            workItem.cancel()
        }
        captureRetryWorkItems.removeAll()
        knownWindowIDsByPID.removeAll()
        launchGraceUntilByPID.removeAll()

        Logger.log("[AutoCapture] Deactivated")
        autoCaptureGroup = nil
        autoCaptureScreen = nil
    }

    func addAutoCaptureObserver(for pid: pid_t, seedKnownWindows: Bool = true) {
        if autoCaptureObservers[pid] != nil {
            if seedKnownWindows {
                seedKnownWindowIDs(for: pid)
                launchGraceUntilByPID.removeValue(forKey: pid)
            }
            return
        }

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

        if seedKnownWindows {
            seedKnownWindowIDs(for: pid)
            launchGraceUntilByPID.removeValue(forKey: pid)
        } else {
            if knownWindowIDsByPID[pid] == nil {
                knownWindowIDsByPID[pid] = []
            }
        }
    }

    func removeAutoCaptureObserver(for pid: pid_t) {
        pendingAutoCaptureWindows.removeAll { $0.pid == pid }
        launchGraceUntilByPID.removeValue(forKey: pid)
        knownWindowIDsByPID.removeValue(forKey: pid)
        cancelCaptureRetries(for: pid)

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

    func suppressAutoJoin(windowIDs: [CGWindowID]) {
        pruneSuppressedAutoJoinWindowIDs()
        for windowID in windowIDs {
            let inserted = suppressedAutoJoinWindowIDs.insert(windowID).inserted
            if inserted {
                Logger.log("[AutoCapture] suppressed wid=\(windowID) until close")
            }
        }
    }

    func handleWindowCreated(element: AXUIElement, pid: pid_t) {
        guard autoCaptureGroup != nil || shouldCaptureUnmatchedToStandaloneGroup else { return }

        if let windowID = AccessibilityHelper.windowID(for: element) {
            knownWindowIDsByPID[pid, default: []].insert(windowID)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, self.autoCaptureGroup != nil || self.shouldCaptureUnmatchedToStandaloneGroup else { return }
            if self.captureWindowIfEligible(element: element, pid: pid, source: "created") {
                return
            }
            // Window not ready yet (still being dragged, animating, etc.)
            // Watch for resize/move events to retry when the window settles.
            self.watchPendingWindow(element: element, pid: pid)
            self.scheduleCreatedRetry(element: element, pid: pid, attempt: 0)
        }
    }

    func handleAutoCaptureFocusChanged(element: AXUIElement, pid: pid_t) {
        guard autoCaptureGroup != nil || shouldCaptureUnmatchedToStandaloneGroup else { return }

        let windowElement: AXUIElement
        if AccessibilityHelper.windowID(for: element) != nil {
            windowElement = element
        } else {
            guard let focusedElement = AccessibilityHelper.focusedWindowElement(for: element) else { return }
            windowElement = focusedElement
        }

        guard let windowID = AccessibilityHelper.windowID(for: windowElement) else { return }
        let now = Date()
        guard AutoCapturePolicy.shouldAttemptFocusCapture(
            pid: pid,
            windowID: windowID,
            now: now,
            launchGraceUntilByPID: launchGraceUntilByPID,
            knownWindowIDsByPID: knownWindowIDsByPID
        ) else {
            Logger.log("[AutoCapture] focus ignored wid=\(windowID) pid=\(pid) (outside grace or already known)")
            return
        }

        knownWindowIDsByPID[pid, default: []].insert(windowID)
        _ = captureWindowIfEligible(element: windowElement, pid: pid, source: "focus-grace")
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
        guard autoCaptureGroup != nil || shouldCaptureUnmatchedToStandaloneGroup else { return }
        if captureWindowIfEligible(element: element, pid: pid, source: "pending") {
            removePendingWindowWatch(element: element, pid: pid)
        }
    }

    func removePendingWindowWatch(element: AXUIElement, pid: pid_t) {
        pendingAutoCaptureWindows.removeAll { $0.element === element }
        guard let observer = autoCaptureObservers[pid] else { return }
        AccessibilityHelper.removeNotification(
            observer: observer, element: element,
            notification: kAXMovedNotification as String
        )
        AccessibilityHelper.removeNotification(
            observer: observer, element: element,
            notification: kAXResizedNotification as String
        )
    }

    // MARK: - Capture

    @discardableResult
    func captureWindowIfEligible(element: AXUIElement, pid: pid_t, source: String) -> Bool {
        pruneSuppressedAutoJoinWindowIDs()

        guard let candidateWindowID = AccessibilityHelper.windowID(for: element) else {
            Logger.log("[AutoCapture] captureIfEligible[\(source)]: no windowID for pid \(pid)")
            return false
        }
        knownWindowIDsByPID[pid, default: []].insert(candidateWindowID)

        guard !suppressedAutoJoinWindowIDs.contains(candidateWindowID) else {
            Logger.log("[AutoCapture] captureIfEligible[\(source)]: suppressed wid=\(candidateWindowID)")
            return false
        }

        guard let window = WindowDiscovery.buildWindowInfo(
            element: element,
            pid: pid,
            qualification: .autoJoin
        ) else {
            Logger.log("[AutoCapture] captureIfEligible[\(source)]: strict-filter-reject for pid \(pid), wid=\(candidateWindowID)")
            return false
        }

        guard !groupManager.isWindowGrouped(window.id) else { return false }

        // --- Modal / popup / transient window detection ---
        let subrole = AccessibilityHelper.getSubrole(of: element)
        let isModal = AccessibilityHelper.isModal(element)
        let size = AccessibilityHelper.getSize(of: element)
        let windowLevel = SpaceUtils.windowLevel(for: window.id)

        Logger.log("[AutoCapture] captureIfEligible[\(source)]: \(window.appName): \(window.title) — subrole=\(subrole ?? "nil") modal=\(isModal) level=\(windowLevel.map(String.init) ?? "unknown") size=\(size.map { "\(Int($0.width))x\(Int($0.height))" } ?? "unknown")")

        // Signal 1: AX attributes — definitive modal indicators
        if subrole == "AXSheet" || subrole == "AXSystemDialog" || isModal {
            Logger.log("[AutoCapture] captureIfEligible[\(source)]: REJECTED modal — subrole=\(subrole ?? "nil") modal=\(isModal) — \(window.appName): \(window.title)")
            return false
        }

        // Signal 2: Elevated window level (floating panels, modal panels, popups)
        if let level = windowLevel, level > 0 {
            Logger.log("[AutoCapture] captureIfEligible[\(source)]: REJECTED elevated level \(level) — \(window.appName): \(window.title)")
            return false
        }

        // Signal 3: Size heuristics
        if let s = size {
            // Too tiny in any dimension — not a real work window
            if s.width < 200 || s.height < 150 {
                Logger.log("[AutoCapture] captureIfEligible[\(source)]: REJECTED too small \(Int(s.width))x\(Int(s.height)) — \(window.appName): \(window.title)")
                return false
            }
            // Both dimensions small — likely a popup or extension panel
            if s.width < 400 && s.height < 400 {
                Logger.log("[AutoCapture] captureIfEligible[\(source)]: REJECTED popup-sized \(Int(s.width))x\(Int(s.height)) — \(window.appName): \(window.title)")
                return false
            }
        }

        guard let frame = AccessibilityHelper.getFrame(of: element) else {
            Logger.log("[AutoCapture] captureIfEligible[\(source)]: no frame — \(window.appName): \(window.title)")
            return false
        }
        let shouldCreateUnmatchedGroup = sessionConfig.autoCaptureUnmatchedToNewGroup

        if let target = targetAutoCaptureGroup(for: window.id, frame: frame, source: source) {
            let group = target.group
            let screen = target.screen
            let visibleFrame = CoordinateConverter.visibleFrameInAX(for: screen)
            guard visibleFrame.intersects(frame) else {
                Logger.log("[AutoCapture] captureIfEligible[\(source)]: not on screen — \(window.appName): \(window.title) frame=\(frame) visible=\(visibleFrame)")
                return captureAsStandaloneGroupIfEnabled(
                    window: window,
                    pid: pid,
                    source: source,
                    reason: "outside-active-screen",
                    shouldCreateUnmatchedGroup: shouldCreateUnmatchedGroup
                )
            }

            // Reject windows on a different space than the capture group
            if group.spaceID != 0,
               let windowSpace = SpaceUtils.spaceID(for: window.id),
               windowSpace != group.spaceID {
                Logger.log("[AutoCapture] captureIfEligible[\(source)]: wrong space (\(windowSpace) != \(group.spaceID)) — \(window.appName): \(window.title)")
                return captureAsStandaloneGroupIfEnabled(
                    window: window,
                    pid: pid,
                    source: source,
                    reason: "different-space",
                    shouldCreateUnmatchedGroup: shouldCreateUnmatchedGroup
                )
            }

            Logger.log("[AutoCapture] Capturing window \(window.id) (\(window.appName): \(window.title)) [\(source)]")
            setExpectedFrame(group.frame, for: [window.id])
            addWindow(window, to: group, afterActive: true)
            cancelCaptureRetry(for: pid, windowID: window.id)
            // Note: addWindow already calls evaluateAutoCapture()
            return true
        }

        Logger.log("[AutoCapture] captureIfEligible[\(source)]: no active group/screen")
        return captureAsStandaloneGroupIfEnabled(
            window: window,
            pid: pid,
            source: source,
            reason: "no-active-group",
            shouldCreateUnmatchedGroup: shouldCreateUnmatchedGroup
        )
    }
}

// MARK: - AutoCapture Internals

private extension AppDelegate {

    func seedKnownWindowIDs(for pid: pid_t) {
        let windowIDs = Set(
            AccessibilityHelper.windowElements(for: pid)
                .compactMap { AccessibilityHelper.windowID(for: $0) }
        )
        knownWindowIDsByPID[pid] = windowIDs
        if !windowIDs.isEmpty {
            Logger.log("[AutoCapture] seeded \(windowIDs.count) known windows for pid \(pid)")
        }
    }

    func pruneSuppressedAutoJoinWindowIDs() {
        suppressedAutoJoinWindowIDs = AutoCapturePolicy.prunedSuppressedWindowIDs(
            suppressedAutoJoinWindowIDs,
            windowExists: { AccessibilityHelper.windowExists(id: $0) }
        )
    }

    @discardableResult
    func captureAsStandaloneGroupIfEnabled(
        window: WindowInfo,
        pid: pid_t,
        source: String,
        reason: String,
        shouldCreateUnmatchedGroup: Bool
    ) -> Bool {
        guard shouldCreateUnmatchedGroup else { return false }
        guard !groupManager.isWindowGrouped(window.id) else { return false }
        guard isWindowOnCurrentSpace(window.id) else {
            Logger.log("[AutoCapture] standalone[\(source)]: rejected (not on current space) wid=\(window.id)")
            return false
        }
        guard AccessibilityHelper.getFrame(of: window.element) != nil else {
            Logger.log("[AutoCapture] standalone[\(source)]: rejected (no frame) wid=\(window.id)")
            return false
        }

        Logger.log("[AutoCapture] standalone[\(source)]: creating one-tab group for wid=\(window.id) reason=\(reason)")
        createGroup(with: [window])
        cancelCaptureRetry(for: pid, windowID: window.id)
        return true
    }

    func scheduleLaunchReconciliation(for pid: pid_t) {
        for delay in AutoCapturePolicy.launchScanDelays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.runLaunchReconciliationScan(for: pid)
            }
        }
    }

    func runLaunchReconciliationScan(for pid: pid_t) {
        guard autoCaptureGroup != nil || shouldCaptureUnmatchedToStandaloneGroup else { return }
        let now = Date()
        guard AutoCapturePolicy.isWithinLaunchGrace(deadline: launchGraceUntilByPID[pid], now: now) else {
            launchGraceUntilByPID.removeValue(forKey: pid)
            return
        }

        let windowElements = AccessibilityHelper.windowElements(for: pid)
        guard !windowElements.isEmpty else { return }

        Logger.log("[AutoCapture] launch-scan pid=\(pid) candidates=\(windowElements.count)")
        for element in windowElements {
            _ = captureWindowIfEligible(element: element, pid: pid, source: "launch-scan")
        }
    }

    func scheduleCreatedRetry(element: AXUIElement, pid: pid_t, attempt: Int) {
        guard let windowID = AccessibilityHelper.windowID(for: element) else { return }
        guard attempt < AutoCapturePolicy.createdRetryDelays.count else {
            let key = AutoCaptureRetryKey(pid: pid, windowID: windowID)
            captureRetryWorkItems.removeValue(forKey: key)
            return
        }

        let key = AutoCaptureRetryKey(pid: pid, windowID: windowID)
        if attempt == 0, captureRetryWorkItems[key] != nil {
            return
        }

        let delay = AutoCapturePolicy.createdRetryDelays[attempt]
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.autoCaptureGroup != nil || self.shouldCaptureUnmatchedToStandaloneGroup else {
                self.captureRetryWorkItems.removeValue(forKey: key)
                return
            }

            if self.captureWindowIfEligible(
                element: element,
                pid: pid,
                source: "created-retry-\(attempt + 1)"
            ) {
                self.removePendingWindowWatch(element: element, pid: pid)
                return
            }

            self.scheduleCreatedRetry(element: element, pid: pid, attempt: attempt + 1)
        }

        captureRetryWorkItems[key]?.cancel()
        captureRetryWorkItems[key] = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    func cancelCaptureRetry(for pid: pid_t, windowID: CGWindowID) {
        let key = AutoCaptureRetryKey(pid: pid, windowID: windowID)
        if let workItem = captureRetryWorkItems.removeValue(forKey: key) {
            workItem.cancel()
        }
    }

    func cancelCaptureRetries(for pid: pid_t) {
        let keys = captureRetryWorkItems.keys.filter { $0.pid == pid }
        for key in keys {
            if let workItem = captureRetryWorkItems.removeValue(forKey: key) {
                workItem.cancel()
            }
        }
    }
}
