import AppKit

// MARK: - Global Switcher

extension AppDelegate {

    func globalSwitcherEligibleWindows(
        from windows: [WindowInfo],
        currentProcessID: pid_t = ProcessInfo.processInfo.processIdentifier
    ) -> [WindowInfo] {
        windows.filter {
            $0.ownerPID != currentProcessID || isAllowedSelfWindowInGlobalSwitcher($0, currentProcessID: currentProcessID)
        }
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
        scheduleSessionAutosave(reason: "global-activation")
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
        let eligibleItems = globalSwitcherEligibleItems(from: items)

        Logger.log("[GS] groups=\(groupManager.groups.count) mru=\(mruTracker.count) items=\(items.map { $0.isGroup ? "G" : "W" }.joined()) eligible=\(eligibleItems.map { $0.isGroup ? "G" : "W" }.joined())")

        guard !eligibleItems.isEmpty else { return }

        switcherController.onCommit = { [weak self] item, subIndex in
            self?.commitSwitcherSelection(item, subIndex: subIndex)
        }
        switcherController.onDismiss = nil

        switcherController.show(
            items: eligibleItems,
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
            guard let targetWindow = externalWindowForCommit(
                for: .singleWindow(window),
                subIndex: subIndex
            ) else { return }
            beginCommitEchoSuppression(targetWindowID: targetWindow.id, source: "quick-switcher.single")
            recordGlobalActivation(.window(targetWindow.id))
            focusWindow(targetWindow)
        case .group(let group):
            if let subIndex {
                group.switchTo(index: subIndex)
            }
            guard let targetWindow = externalWindowForCommit(for: .group(group), subIndex: subIndex) else { return }
            if group.activeWindow?.id != targetWindow.id {
                group.switchTo(windowID: targetWindow.id)
            }
            beginCommitEchoSuppression(targetWindowID: targetWindow.id, source: "quick-switcher.group")
            recordGlobalActivation(.groupWindow(groupID: group.id, windowID: targetWindow.id))
            promoteWindowOwnership(windowID: targetWindow.id, group: group)
            group.recordFocus(windowID: targetWindow.id)
            if group.displayMode == .bound, !targetWindow.isFullscreened {
                setExpectedFrame(group.frame, for: [targetWindow.id])
                AccessibilityHelper.setFrameAsync(of: targetWindow.element, to: group.frame)
            } else if group.displayMode == .fullscreen,
                      fullscreenModeKeepsResizedWindows,
                      let fullscreenFrame = fullscreenManagedFrame(for: group) {
                setExpectedFrame(fullscreenFrame, for: [targetWindow.id])
                AccessibilityHelper.setFrameAsync(of: targetWindow.element, to: fullscreenFrame)
            }
            if !targetWindow.isFullscreened, let panel = tabBarPanels[group.id] {
                focusWindow(targetWindow) { [weak self] in
                    self?.refreshPanelPlacement(for: group, panel: panel, relativeTo: targetWindow.id, orderFront: false)
                }
            } else {
                focusWindow(targetWindow)
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
            guard let targetWindow = externalWindowForCommit(
                for: .groupSegment(group, windowIDs: windowIDs),
                subIndex: subIndex
            ), windowIDs.contains(targetWindow.id) else { return }
            if group.activeWindow?.id != targetWindow.id {
                group.switchTo(windowID: targetWindow.id)
            }
            beginCommitEchoSuppression(targetWindowID: targetWindow.id, source: "quick-switcher.segment")
            recordGlobalActivation(.groupWindow(groupID: group.id, windowID: targetWindow.id))
            promoteWindowOwnership(windowID: targetWindow.id, group: group)
            group.recordFocus(windowID: targetWindow.id)
            if group.displayMode == .bound, !targetWindow.isFullscreened {
                setExpectedFrame(group.frame, for: [targetWindow.id])
                AccessibilityHelper.setFrameAsync(of: targetWindow.element, to: group.frame)
            } else if group.displayMode == .fullscreen,
                      fullscreenModeKeepsResizedWindows,
                      let fullscreenFrame = fullscreenManagedFrame(for: group) {
                setExpectedFrame(fullscreenFrame, for: [targetWindow.id])
                AccessibilityHelper.setFrameAsync(of: targetWindow.element, to: fullscreenFrame)
            }
            if !targetWindow.isFullscreened, let panel = tabBarPanels[group.id] {
                focusWindow(targetWindow) { [weak self] in
                    self?.refreshPanelPlacement(for: group, panel: panel, relativeTo: targetWindow.id, orderFront: false)
                }
            } else {
                focusWindow(targetWindow)
            }
        }
    }

    func globalSwitcherEligibleItems(
        from items: [SwitcherItem],
        currentProcessID: pid_t = ProcessInfo.processInfo.processIdentifier
    ) -> [SwitcherItem] {
        items.filter {
            externalWindowForCommit(for: $0, subIndex: nil, currentProcessID: currentProcessID) != nil
        }
    }

    func externalWindowForCommit(
        for item: SwitcherItem,
        subIndex: Int?,
        currentProcessID: pid_t = ProcessInfo.processInfo.processIdentifier
    ) -> WindowInfo? {
        let isExternal: (WindowInfo) -> Bool = { [self] window in
            guard !window.isSeparator else { return false }
            if window.ownerPID != currentProcessID { return true }
            return self.isAllowedSelfWindowInGlobalSwitcher(window, currentProcessID: currentProcessID)
        }

        switch item {
        case .singleWindow(let window):
            return isExternal(window) ? window : nil
        case .group(let group):
            return preferredExternalWindow(
                candidates: group.managedWindows,
                preferredIndex: subIndex,
                activeWindow: group.activeWindow,
                focusHistory: group.focusHistory,
                isExternal: isExternal
            )
        case .groupSegment(let group, let windowIDs):
            let windowsByID = Dictionary(uniqueKeysWithValues: group.managedWindows.map { ($0.id, $0) })
            let segmentWindows = windowIDs.compactMap { windowsByID[$0] }
            let activeWindow = group.activeWindow.flatMap { active in
                windowIDs.contains(active.id) ? active : nil
            }
            let segmentFocusHistory = group.focusHistory.filter { windowIDs.contains($0) }
            return preferredExternalWindow(
                candidates: segmentWindows,
                preferredIndex: subIndex,
                activeWindow: activeWindow,
                focusHistory: segmentFocusHistory,
                isExternal: isExternal
            )
        }
    }

    private func preferredExternalWindow(
        candidates: [WindowInfo],
        preferredIndex: Int?,
        activeWindow: WindowInfo?,
        focusHistory: [CGWindowID],
        isExternal: (WindowInfo) -> Bool
    ) -> WindowInfo? {
        guard !candidates.isEmpty else { return nil }

        if let preferredIndex,
           let preferredWindow = candidates[safe: preferredIndex],
           isExternal(preferredWindow) {
            return preferredWindow
        }

        if let activeWindow, isExternal(activeWindow) {
            return activeWindow
        }

        let candidatesByID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        if let mruWindow = focusHistory.compactMap({ candidatesByID[$0] }).first(where: isExternal) {
            return mruWindow
        }

        return candidates.first(where: isExternal)
    }

    func isAllowedSelfWindowInGlobalSwitcher(
        _ window: WindowInfo,
        currentProcessID: pid_t = ProcessInfo.processInfo.processIdentifier
    ) -> Bool {
        guard window.ownerPID == currentProcessID else { return false }
        return window.title.trimmingCharacters(in: .whitespacesAndNewlines) == "Tabbed Settings"
    }
}
