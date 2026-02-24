import AppKit

// MARK: - Global Switcher

extension AppDelegate {

    func globalSwitcherEligibleWindows(
        from windows: [WindowInfo],
        currentProcessID: pid_t = ProcessInfo.processInfo.processIdentifier
    ) -> [WindowInfo] {
        windows.filter { $0.ownerPID != currentProcessID }
    }

    func noteRecentExternalActivation(windowID: CGWindowID, at date: Date = Date()) {
        recentExternalActivationWindowID = windowID
        recentExternalActivationAt = date
    }

    func shouldForceSynchronousInventoryRefreshForRecentExternalActivation(now: Date = Date()) -> Bool {
        guard let windowID = recentExternalActivationWindowID,
              let activationAt = recentExternalActivationAt else { return false }
        if now.timeIntervalSince(activationAt) > Self.recentExternalActivationLifetime {
            recentExternalActivationWindowID = nil
            recentExternalActivationAt = nil
            return false
        }
        return !windowInventory.cachedAllSpacesWindows.contains(where: { $0.id == windowID })
    }

    func clearRecentExternalActivationIfVisible(in windows: [WindowInfo]) {
        guard let windowID = recentExternalActivationWindowID else { return }
        guard windows.contains(where: { $0.id == windowID }) else { return }
        recentExternalActivationWindowID = nil
        recentExternalActivationAt = nil
    }

    func beginCommitEchoSuppression(targetWindowID: CGWindowID, source: String = "unspecified") {
        pendingCommitEchoTargetWindowID = targetWindowID
        pendingCommitEchoDeadline = Date().addingTimeInterval(Self.commitEchoSuppressionTimeout)
        pendingCommitEchoSource = source
        Logger.log("[ECHO] begin target=\(targetWindowID) source=\(source) timeoutMs=\(Int(Self.commitEchoSuppressionTimeout * 1000))")
    }

    func clearCommitEchoSuppression() {
        if let target = pendingCommitEchoTargetWindowID {
            Logger.log("[ECHO] clear target=\(target) source=\(pendingCommitEchoSource ?? "unknown")")
        }
        pendingCommitEchoTargetWindowID = nil
        pendingCommitEchoDeadline = nil
        pendingCommitEchoSource = nil
    }

    /// Suppress post-commit focus echoes until the intended target is observed.
    /// Once the target is seen, clear suppression on the next main-queue turn so
    /// paired focus notifications in the same event burst are also ignored.
    func shouldSuppressCommitEcho(for windowID: CGWindowID) -> Bool {
        guard let deadline = pendingCommitEchoDeadline,
              let targetWindowID = pendingCommitEchoTargetWindowID else { return false }

        if Date() >= deadline {
            Logger.log("[ECHO] expired target=\(targetWindowID) source=\(pendingCommitEchoSource ?? "unknown")")
            clearCommitEchoSuppression()
            return false
        }

        let remainingMs = max(0, Int(deadline.timeIntervalSinceNow * 1000))

        if windowID == targetWindowID {
            Logger.log("[ECHO] suppress target-observed window=\(windowID) source=\(pendingCommitEchoSource ?? "unknown") remainingMs=\(remainingMs)")
            DispatchQueue.main.async { [weak self] in
                guard let self, self.pendingCommitEchoTargetWindowID == targetWindowID else { return }
                self.clearCommitEchoSuppression()
            }
        } else {
            Logger.log("[ECHO] suppress non-target window=\(windowID) target=\(targetWindowID) source=\(pendingCommitEchoSource ?? "unknown") remainingMs=\(remainingMs)")
        }
        return true
    }

    func recordGlobalActivation(_ entry: MRUEntry) {
        mruTracker.recordActivation(entry)
    }

    func handleGlobalSwitcher(reverse: Bool) {
        Logger.log("[GS] handleGlobalSwitcher ENTERED reverse=\(reverse)")
        if switcherController.isActive {
            if reverse { switcherController.retreat() } else { switcherController.advance() }
            return
        }

        if shouldForceSynchronousInventoryRefreshForRecentExternalActivation() {
            windowInventory.refreshSync(force: true)
        }
        let discoveredWindows = windowInventory.allSpacesForSwitcher()
        let zWindows = globalSwitcherEligibleWindows(from: discoveredWindows)
        clearRecentExternalActivationIfVisible(in: zWindows)
        guard !zWindows.isEmpty else {
            Logger.log("[GS] inventory empty; refresh in progress")
            return
        }
        let preferredSuperPinGroupID = activeGroup()?.0.id
        let items = mruTracker.buildSwitcherItems(
            groups: groupManager.groups,
            zOrderedWindows: zWindows,
            splitPinnedTabsIntoSeparateGroup: switcherConfig.splitPinnedTabsIntoSeparateGroup,
            splitSuperPinnedTabsIntoSeparateGroup: switcherConfig.splitSuperPinnedTabsIntoSeparateGroup,
            preferredGroupIDForSuperPins: preferredSuperPinGroupID,
            splitSeparatedTabsIntoSeparateGroups: switcherConfig.splitSeparatedTabsIntoSeparateGroups
        )

        Logger.log("[GS] groups=\(groupManager.groups.count) mru=\(mruTracker.count) items=\(items.map { $0.isGroup ? "G" : "W" }.joined())")

        guard !items.isEmpty else { return }

        switcherController.onCommit = { [weak self] item, subIndex in
            self?.commitSwitcherSelection(item, subIndex: subIndex)
        }
        switcherController.onDismiss = nil

        switcherController.show(
            items: items,
            style: switcherConfig.globalStyle,
            scope: .global,
            namedGroupLabelMode: switcherConfig.namedGroupLabelMode,
            splitPinnedTabsIntoSeparateGroup: switcherConfig.splitPinnedTabsIntoSeparateGroup,
            splitSuperPinnedTabsIntoSeparateGroup: switcherConfig.splitSuperPinnedTabsIntoSeparateGroup,
            splitSeparatedTabsIntoSeparateGroups: switcherConfig.splitSeparatedTabsIntoSeparateGroups
        )
        if reverse { switcherController.retreat() } else { switcherController.advance() }
        hotkeyManager?.startModifierWatch(modifiers: hotkeyManager?.config.globalSwitcher.modifiers ?? 0)
    }

    func handleModifierReleased() {
        hotkeyManager?.stopModifierWatch()
        if switcherController.isActive {
            switcherController.commit()

            if let group = cyclingGroup {
                group.endCycle()
                cyclingGroup = nil
            }
            return
        }
        guard let group = cyclingGroup, group.isCycling else { return }

        group.endCycle()
        cyclingGroup = nil
    }

    func handleSwitcherArrow(_ direction: SwitcherController.ArrowDirection) {
        guard switcherController.isActive else { return }
        switcherController.handleArrowKey(direction)
    }

    func commitSwitcherSelection(_ item: SwitcherItem, subIndex: Int?) {
        switch item {
        case .singleWindow(let window):
            guard window.ownerPID != ProcessInfo.processInfo.processIdentifier else { return }
            beginCommitEchoSuppression(targetWindowID: window.id, source: "quick-switcher.single")
            recordGlobalActivation(.window(window.id))
            focusWindow(window)
        case .group(let group):
            if let subIndex {
                group.switchTo(index: subIndex)
            }
            guard let activeWindow = group.activeWindow else { return }
            beginCommitEchoSuppression(targetWindowID: activeWindow.id, source: "quick-switcher.group")
            recordGlobalActivation(.groupWindow(groupID: group.id, windowID: activeWindow.id))
            promoteWindowOwnership(windowID: activeWindow.id, group: group)
            group.recordFocus(windowID: activeWindow.id)
            if !activeWindow.isFullscreened {
                setExpectedFrame(group.frame, for: [activeWindow.id])
                AccessibilityHelper.setFrameAsync(of: activeWindow.element, to: group.frame)
            }
            if !activeWindow.isFullscreened, let panel = tabBarPanels[group.id] {
                focusWindow(activeWindow) { panel.orderAbove(windowID: activeWindow.id) }
            } else {
                focusWindow(activeWindow)
            }
        case .groupSegment(let group, let windowIDs):
            if let subIndex,
               let selectedWindowID = windowIDs[safe: subIndex] {
                group.switchTo(windowID: selectedWindowID)
            } else if let activeWindowID = group.activeWindow?.id,
                      windowIDs.contains(activeWindowID) {
                // Keep current segment-local active tab; no switch needed.
            } else if let mruWindowID = group.focusHistory.first(where: { windowIDs.contains($0) }) {
                group.switchTo(windowID: mruWindowID)
            } else if let firstWindowID = windowIDs.first {
                group.switchTo(windowID: firstWindowID)
            }
            guard let activeWindow = group.activeWindow, windowIDs.contains(activeWindow.id) else { return }
            beginCommitEchoSuppression(targetWindowID: activeWindow.id, source: "quick-switcher.segment")
            recordGlobalActivation(.groupWindow(groupID: group.id, windowID: activeWindow.id))
            promoteWindowOwnership(windowID: activeWindow.id, group: group)
            group.recordFocus(windowID: activeWindow.id)
            if !activeWindow.isFullscreened {
                setExpectedFrame(group.frame, for: [activeWindow.id])
                AccessibilityHelper.setFrameAsync(of: activeWindow.element, to: group.frame)
            }
            if !activeWindow.isFullscreened, let panel = tabBarPanels[group.id] {
                focusWindow(activeWindow) { panel.orderAbove(windowID: activeWindow.id) }
            } else {
                focusWindow(activeWindow)
            }
        }
    }
}
