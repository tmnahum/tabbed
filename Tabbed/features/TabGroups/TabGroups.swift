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

    func showWindowPicker(addingTo group: TabGroup? = nil, insertAt: Int? = nil) {
        dismissWindowPicker()
        if useLegacyWindowPicker {
            showLegacyWindowPicker(addingTo: group, insertAt: insertAt)
        } else {
            showAddWindowPalette(addingTo: group, insertAt: insertAt)
        }
    }

    private func showLegacyWindowPicker(addingTo group: TabGroup?, insertAt: Int?) {
        windowManager.refreshWindowList()

        let picker = WindowPickerView(
            windowManager: windowManager,
            groupManager: groupManager,
            onCreateGroup: { [weak self] windows in
                self?.createGroup(with: windows)
                self?.dismissWindowPicker()
            },
            onAddToGroup: { [weak self] window in
                guard let group else { return }
                self?.addWindow(window, to: group, at: insertAt)
                self?.dismissWindowPicker()
            },
            onMergeGroup: { [weak self] sourceGroup in
                guard let group else { return }
                self?.mergeGroup(sourceGroup, into: group, at: insertAt)
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

    private func showAddWindowPalette(addingTo group: TabGroup?, insertAt: Int?) {
        let panel = AddWindowPalettePanel()

        let viewModel = AddWindowPaletteViewModel(
            launcherEngine: launcherEngine,
            contextProvider: { [weak self] in
                self?.buildLauncherContext(addingTo: group) ?? LauncherQueryContext(
                    mode: .newGroup,
                    looseWindows: [],
                    mergeGroups: [],
                    targetGroupDisplayName: nil,
                    targetGroupWindowCount: nil,
                    targetActiveTabID: nil,
                    targetActiveTabTitle: nil,
                    appCatalog: [],
                    launcherConfig: .default,
                    resolvedURLBrowserProvider: nil,
                    resolvedSearchBrowserProvider: nil,
                    currentSpaceID: nil,
                    windowRecency: [:],
                    groupRecency: [:],
                    appRecency: [:],
                    urlHistory: [],
                    appLaunchHistory: [:],
                    actionHistory: [:]
                )
            },
            actionExecutor: { [weak self] action, context, completion in
                self?.executeLauncherAction(
                    action,
                    context: context,
                    addingTo: group,
                    insertAt: insertAt,
                    completion: completion
                )
            },
            dismiss: { [weak self] in
                self?.dismissWindowPicker()
            }
        )

        panel.onMoveSelection = { delta in
            viewModel.moveSelection(by: delta)
        }
        panel.onConfirmSelection = {
            viewModel.executeSelection()
        }
        panel.onEscape = { [weak self] in
            self?.dismissWindowPicker()
        }
        panel.onOutsideClick = { [weak self] in
            self?.dismissWindowPicker()
        }
        panel.onRefresh = {
            viewModel.refreshSources()
        }

        let root = AddWindowPaletteView(
            viewModel: viewModel,
            onDismiss: { [weak self] in self?.dismissWindowPicker() }
        )
        panel.contentView = NSHostingView(rootView: root)
        panel.showCenteredOnActiveScreen()
        windowPickerPanel = panel
    }

    private func buildLauncherContext(addingTo group: TabGroup?) -> LauncherQueryContext {
        let spaceWindows = WindowDiscovery.currentSpace()
        let looseWindows = spaceWindows.filter { !groupManager.isWindowGrouped($0.id) }
        let appCatalog = appCatalogService.loadCatalog()
        let resolvedURLProvider = browserProviderResolver.resolve(selection: addWindowLauncherConfig.urlProviderSelection)
        let resolvedSearchProvider = browserProviderResolver.resolve(selection: addWindowLauncherConfig.searchProviderSelection)
        let currentSpaceID = resolveCurrentSpaceID(windowsOnCurrentSpace: spaceWindows)

        let mergeGroups: [TabGroup]
        let mode: LauncherMode
        if let group {
            mode = .addToGroup(targetGroupID: group.id, targetSpaceID: group.spaceID)
            mergeGroups = groupManager.groups.filter { candidate in
                guard candidate.id != group.id else { return false }
                guard isGroupOnCurrentSpace(candidate) else { return false }
                if group.spaceID == 0 { return true }
                if candidate.spaceID == 0 {
                    guard let activeWindow = candidate.activeWindow,
                          let candidateSpace = SpaceUtils.spaceID(for: activeWindow.id) else { return false }
                    return candidateSpace == group.spaceID
                }
                return candidate.spaceID == group.spaceID
            }
        } else {
            mode = .newGroup
            mergeGroups = []
        }

        var windowRecency: [CGWindowID: Int] = [:]
        var groupRecency: [UUID: Int] = [:]
        for (index, entry) in mruTracker.entries.enumerated() {
            let score = mruTracker.count - index
            switch entry {
            case .window(let windowID):
                windowRecency[windowID] = score
            case .group(let groupID):
                groupRecency[groupID] = score
            case .groupWindow(let groupID, let windowID):
                groupRecency[groupID] = max(groupRecency[groupID] ?? 0, score)
                windowRecency[windowID] = max(windowRecency[windowID] ?? 0, score)
            }
        }

        var appRecency: [String: Int] = [:]
        for (index, app) in appCatalog.enumerated() {
            appRecency[app.bundleID] = appCatalog.count - index
        }

        Logger.log("[LAUNCHER_QUERY] context windows=\(looseWindows.count) groups=\(mergeGroups.count) apps=\(appCatalog.count)")
        return LauncherQueryContext(
            mode: mode,
            looseWindows: looseWindows,
            mergeGroups: mergeGroups,
            targetGroupDisplayName: group?.displayName,
            targetGroupWindowCount: group?.managedWindowCount,
            targetActiveTabID: group?.activeWindow?.id,
            targetActiveTabTitle: group?.activeWindow?.displayTitle,
            appCatalog: appCatalog,
            launcherConfig: addWindowLauncherConfig,
            resolvedURLBrowserProvider: resolvedURLProvider,
            resolvedSearchBrowserProvider: resolvedSearchProvider,
            currentSpaceID: currentSpaceID,
            windowRecency: windowRecency,
            groupRecency: groupRecency,
            appRecency: appRecency,
            urlHistory: launcherHistoryStore.urlEntries(),
            appLaunchHistory: launcherHistoryStore.appEntriesByBundleID(),
            actionHistory: launcherHistoryStore.actionEntriesByID()
        )
    }

    private func resolveCurrentSpaceID(windowsOnCurrentSpace: [WindowInfo]) -> UInt64? {
        if let focused = focusedWindowID(),
           let focusedSpace = SpaceUtils.spaceID(for: focused) {
            return focusedSpace
        }
        if let activeWindow = activeGroup()?.0.activeWindow?.id,
           let activeSpace = SpaceUtils.spaceID(for: activeWindow) {
            return activeSpace
        }
        return windowsOnCurrentSpace.first.flatMap { SpaceUtils.spaceID(for: $0.id) }
    }

    private func focusedWindowID() -> CGWindowID? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AccessibilityHelper.appElement(for: frontApp.processIdentifier)
        var focusedValue: AnyObject?
        let result = AXUIElementCopyAttributeValue(
            appElement, kAXFocusedWindowAttribute as CFString, &focusedValue
        )
        guard result == .success, let focusedValue else { return nil }
        let windowElement = focusedValue as! AXUIElement // swiftlint:disable:this force_cast
        return AccessibilityHelper.windowID(for: windowElement)
    }

    private func executeLauncherAction(
        _ action: LauncherAction,
        context: LauncherQueryContext,
        addingTo _: TabGroup?,
        insertAt: Int?,
        completion: @escaping (LaunchAttemptResult) -> Void
    ) {
        switch action {
        case .looseWindow(let windowID):
            guard let window = context.looseWindows.first(where: { $0.id == windowID }) else {
                completion(.failed(status: "Window is no longer available"))
                return
            }
            switch context.mode {
            case .newGroup:
                createGroup(with: [window])
            case .addToGroup(let targetGroupID, _):
                guard let targetGroup = groupManager.groups.first(where: { $0.id == targetGroupID }) else {
                    completion(.failed(status: "Target group no longer exists"))
                    return
                }
                addWindow(window, to: targetGroup, at: insertAt)
            }
            completion(.succeeded)

        case .groupAllInSpace:
            guard !context.mode.isAddToGroup else {
                completion(.failed(status: "Action unavailable for this picker"))
                return
            }
            let windows = context.looseWindows
            guard windows.count > 1 else {
                completion(.failed(status: "Need at least 2 windows in this space"))
                return
            }
            createGroup(with: windows)
            if let actionID = action.historyKey {
                launcherHistoryStore.recordActionUsage(actionID: actionID, outcome: .succeeded)
            }
            completion(.succeeded)

        case .mergeGroup(let groupID):
            guard case .addToGroup(let targetGroupID, _) = context.mode,
                  let targetGroup = groupManager.groups.first(where: { $0.id == targetGroupID }),
                  let sourceGroup = groupManager.groups.first(where: { $0.id == groupID }) else {
                completion(.failed(status: "Group is no longer available"))
                return
            }
            mergeGroup(sourceGroup, into: targetGroup, at: insertAt)
            completion(.succeeded)

        case .renameTargetGroup:
            guard case .addToGroup(let targetGroupID, _) = context.mode,
                  let targetGroup = groupManager.groups.first(where: { $0.id == targetGroupID }),
                  let panel = tabBarPanels[targetGroupID] else {
                completion(.failed(status: "Group is no longer available"))
                return
            }
            preparePanelForInlineGroupNameEdit(panel, group: targetGroup)
            NotificationCenter.default.post(
                name: .tabbedBeginInlineGroupNameEdit,
                object: nil,
                userInfo: [TabBarView.inlineGroupNameEditGroupIDKey: targetGroup.id]
            )
            if let actionID = action.historyKey {
                launcherHistoryStore.recordActionUsage(actionID: actionID, outcome: .succeeded)
            }
            completion(.succeeded)

        case .renameCurrentTab:
            guard case .addToGroup(let targetGroupID, _) = context.mode,
                  let targetGroup = groupManager.groups.first(where: { $0.id == targetGroupID }),
                  let panel = tabBarPanels[targetGroupID],
                  let activeWindow = targetGroup.activeWindow else {
                completion(.failed(status: "Tab is no longer available"))
                return
            }
            preparePanelForInlineGroupNameEdit(panel, group: targetGroup)
            NotificationCenter.default.post(
                name: .tabbedBeginInlineTabNameEdit,
                object: nil,
                userInfo: [
                    TabBarView.inlineGroupNameEditGroupIDKey: targetGroup.id,
                    TabBarView.inlineTabNameEditWindowIDKey: Int(activeWindow.id)
                ]
            )
            if let actionID = action.historyKey {
                launcherHistoryStore.recordActionUsage(actionID: actionID, outcome: .succeeded)
            }
            completion(.succeeded)

        case .releaseCurrentTab:
            guard case .addToGroup(let targetGroupID, _) = context.mode,
                  let targetGroup = groupManager.groups.first(where: { $0.id == targetGroupID }),
                  let panel = tabBarPanels[targetGroupID],
                  targetGroup.managedWindowCount > 0 else {
                completion(.failed(status: "Tab is no longer available"))
                return
            }
            releaseTab(at: targetGroup.activeIndex, from: targetGroup, panel: panel)
            if let actionID = action.historyKey {
                launcherHistoryStore.recordActionUsage(actionID: actionID, outcome: .succeeded)
            }
            completion(.succeeded)

        case .insertSeparatorTab:
            guard case .addToGroup(let targetGroupID, _) = context.mode,
                  let targetGroup = groupManager.groups.first(where: { $0.id == targetGroupID }) else {
                completion(.failed(status: "Group is no longer available"))
                return
            }
            insertSeparatorTab(into: targetGroup, at: insertAt)
            if let actionID = action.historyKey {
                launcherHistoryStore.recordActionUsage(actionID: actionID, outcome: .succeeded)
            }
            completion(.succeeded)

        case .ungroupTargetGroup:
            guard case .addToGroup(let targetGroupID, _) = context.mode,
                  let targetGroup = groupManager.groups.first(where: { $0.id == targetGroupID }) else {
                completion(.failed(status: "Group is no longer available"))
                return
            }
            disbandGroup(targetGroup)
            if let actionID = action.historyKey {
                launcherHistoryStore.recordActionUsage(actionID: actionID, outcome: .succeeded)
            }
            completion(.succeeded)

        case .closeAllWindowsInTargetGroup:
            guard case .addToGroup(let targetGroupID, _) = context.mode,
                  let targetGroup = groupManager.groups.first(where: { $0.id == targetGroupID }),
                  let panel = tabBarPanels[targetGroupID] else {
                completion(.failed(status: "Group is no longer available"))
                return
            }
            closeTabs(withIDs: Set(targetGroup.managedWindows.map(\.id)), from: targetGroup, panel: panel)
            if let actionID = action.historyKey {
                launcherHistoryStore.recordActionUsage(actionID: actionID, outcome: .succeeded)
            }
            completion(.succeeded)

        case .appLaunch(let bundleID, _, _):
            guard let app = context.appCatalog.first(where: { $0.bundleID == bundleID }) else {
                completion(.failed(status: "App is no longer available"))
                return
            }
            let request = LaunchOrchestrator.CaptureRequest(mode: context.mode, currentSpaceID: context.currentSpaceID)
            launchOrchestrator.launchAppAndCapture(app: app, request: request) { [weak self] outcome in
                self?.launcherHistoryStore.recordAppLaunch(bundleID: bundleID, outcome: outcome.result)
                self?.handleCaptureOutcome(outcome, context: context, completion: completion)
            }

        case .openURL(let url):
            let request = LaunchOrchestrator.CaptureRequest(mode: context.mode, currentSpaceID: context.currentSpaceID)
            launchOrchestrator.launchURLAndCapture(url: url, provider: context.resolvedURLBrowserProvider, request: request) { [weak self] outcome in
                if !LauncherHistoryStore.isSearchURL(url) {
                    self?.launcherHistoryStore.recordURLLaunch(url, outcome: outcome.result)
                }
                self?.handleCaptureOutcome(outcome, context: context, completion: completion)
            }

        case .webSearch(let query):
            let request = LaunchOrchestrator.CaptureRequest(mode: context.mode, currentSpaceID: context.currentSpaceID)
            launchOrchestrator.launchSearchAndCapture(
                query: query,
                provider: context.resolvedSearchBrowserProvider,
                searchEngine: context.launcherConfig.searchEngine,
                customSearchTemplate: context.launcherConfig.customSearchTemplate,
                request: request
            ) { [weak self] outcome in
                self?.handleCaptureOutcome(outcome, context: context, completion: completion)
            }
        }
    }

    private func handleCaptureOutcome(
        _ outcome: LaunchOrchestrator.Outcome,
        context: LauncherQueryContext,
        completion: @escaping (LaunchAttemptResult) -> Void
    ) {
        switch outcome.result {
        case .succeeded:
            guard let capturedWindow = outcome.capturedWindow else {
                completion(.failed(status: "No captured window"))
                return
            }

            switch context.mode {
            case .newGroup:
                createGroup(with: [capturedWindow])
                completion(.succeeded)
            case .addToGroup(let targetGroupID, _):
                guard let targetGroup = groupManager.groups.first(where: { $0.id == targetGroupID }) else {
                    completion(.failed(status: "Target group no longer exists"))
                    return
                }
                addWindow(capturedWindow, to: targetGroup, afterActive: true)
                completion(.succeeded)
            }
        case .timedOut(let status):
            completion(.timedOut(status: status))
        case .failed(let status):
            completion(.failed(status: status))
        }
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
        activeIndex: Int = 0,
        name: String? = nil
    ) -> TabGroup? {
        let spaceID = windows.first.flatMap { SpaceUtils.spaceID(for: $0.id) } ?? 0
        guard let group = groupManager.createGroup(with: windows, frame: frame, spaceID: spaceID, name: name) else { return nil }
        Logger.log("[SPACE] Created group \(group.id) on space \(spaceID)")
        group.tabBarSqueezeDelta = squeezeDelta
        group.switchTo(index: activeIndex)

        setExpectedFrame(frame, for: group.visibleWindows.map(\.id))

        for window in group.visibleWindows {
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
            onFocusGroup: { [weak self] targetGroupID in
                self?.focusGroupFromCounter(targetGroupID)
            },
            onAddWindow: { [weak self] in
                self?.showWindowPicker(addingTo: group)
            },
            onAddWindowAfterTab: { [weak self] index in
                self?.showWindowPicker(addingTo: group, insertAt: index + 1)
            },
            onAddSeparatorAfterTab: { index in
                _ = group.addSeparator(at: index + 1)
            },
            onBeginTabNameEdit: { [weak self, weak panel] in
                guard let self, let panel else { return }
                self.preparePanelForInlineGroupNameEdit(panel, group: group)
            },
            onCommitTabName: { [weak self] windowID, rawName in
                self?.applyTabName(rawName, for: windowID, in: group)
            },
            onBeginGroupNameEdit: { [weak self, weak panel] in
                guard let self, let panel else { return }
                self.preparePanelForInlineGroupNameEdit(panel, group: group)
            },
            onCommitGroupName: { [weak self] newName in
                self?.applyGroupName(newName, to: group)
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
            onSelectionChanged: { [weak self] ids in
                self?.selectedTabIDsByGroupID[group.id] = ids
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

        for window in group.managedWindows {
            windowObserver.observe(window: window)
        }

        if let activeWindow = group.activeWindow {
            let maximized = isGroupMaximized(group).0
            panel.show(above: frame, windowID: activeWindow.id, isMaximized: maximized)
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
                let others = group.visibleWindows.filter { $0.id != activeWindow.id }
                if !others.isEmpty {
                    self.setExpectedFrame(clamped, for: others.map(\.id))
                    for window in others {
                        AccessibilityHelper.setFrame(of: window.element, to: clamped)
                    }
                }
            }
            panel.positionAbove(windowFrame: group.frame, isMaximized: self.isGroupMaximized(group).0)
            panel.orderAbove(windowID: activeWindow.id)
            self.movePanelToWindowSpace(panel, windowID: activeWindow.id)
        }

        evaluateAutoCapture()
        return group
    }

    func resolvedSpaceID(for group: TabGroup) -> UInt64? {
        if group.spaceID != 0 {
            return group.spaceID
        }
        if let activeWindowID = group.activeWindow?.id,
           let spaceID = SpaceUtils.spaceID(for: activeWindowID) {
            return spaceID
        }
        return group.managedWindows.first.flatMap { SpaceUtils.spaceID(for: $0.id) }
    }

    func refreshMaximizedGroupCounters() {
        let candidates = groupManager.groups.map { group in
            MaximizedGroupCounterPolicy.Candidate(
                groupID: group.id,
                spaceID: resolvedSpaceID(for: group),
                isMaximized: isGroupMaximized(group).0
            )
        }
        let countersByGroupID = MaximizedGroupCounterPolicy.counterGroupIDsByGroupID(candidates: candidates)
        for group in groupManager.groups {
            let next = countersByGroupID[group.id] ?? []
            if group.maximizedGroupCounterIDs != next {
                group.maximizedGroupCounterIDs = next
            }
        }
    }

    func focusGroupFromCounter(_ targetGroupID: UUID) {
        guard let group = groupManager.groups.first(where: { $0.id == targetGroupID }),
              let activeWindow = group.activeWindow else { return }
        lastActiveGroupID = group.id
        group.recordFocus(windowID: activeWindow.id)
        focusWindow(activeWindow)
        if !activeWindow.isFullscreened, let panel = tabBarPanels[group.id] {
            panel.orderAbove(windowID: activeWindow.id)
        }
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
        guard let window = group.windows[safe: index] else { return }

        // Fullscreened window: raise it to switch to its fullscreen Space.
        if window.isFullscreened {
            focusWindow(window)
            return
        }

        let previousID = group.activeWindow?.id
        group.switchTo(index: index)
        guard let window = group.activeWindow else { return }
        Logger.log("[DEBUG] switchTab: \(previousID.map(String.init) ?? "nil") → \(window.id) (index=\(index))")
        lastActiveGroupID = group.id
        if !group.isCycling {
            group.recordFocus(windowID: window.id)
        }

        // Defensive invariant guard: if an app/AX race leaves the group frame
        // extending below the visible area, trim it before applying the switch.
        let visibleFrame = CoordinateConverter.visibleFrameInAX(at: group.frame.origin)
        let maxBottom = visibleFrame.origin.y + visibleFrame.height
        let currentBottom = group.frame.origin.y + group.frame.height
        if currentBottom > maxBottom + Self.frameTolerance {
            let correctedHeight = maxBottom - group.frame.origin.y
            group.frame = CGRect(x: group.frame.origin.x, y: group.frame.origin.y,
                                 width: group.frame.width, height: correctedHeight)
            Logger.log("[DEBUG] switchTab: defensive trim applied, corrected height=\(correctedHeight)")
            panel.positionAbove(windowFrame: group.frame, isMaximized: isGroupMaximized(group).0)
        }

        setExpectedFrame(group.frame, for: [window.id])
        AccessibilityHelper.setFrame(of: window.element, to: group.frame)

        bringTabToFront(window, in: group)
    }

    func releaseTab(at index: Int, from group: TabGroup, panel: TabBarPanel) {
        guard let window = group.windows[safe: index] else { return }
        if window.isSeparator {
            groupManager.releaseWindow(withID: window.id, from: group)
            if !groupManager.groups.contains(where: { $0.id == group.id }) {
                handleGroupDissolution(group: group, panel: panel)
            } else if let newActive = group.activeWindow {
                panel.orderAbove(windowID: newActive.id)
            }
            evaluateAutoCapture()
            return
        }
        suppressAutoJoin(windowIDs: [window.id])

        windowObserver.stopObserving(window: window)
        expectedFrames.removeValue(forKey: window.id)

        // Fullscreened windows: skip frame expansion (macOS manages their frame)
        if !window.isFullscreened {
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
        if window.isSeparator {
            groupManager.releaseWindow(withID: window.id, from: group)
            if !groupManager.groups.contains(where: { $0.id == group.id }) {
                handleGroupDissolution(group: group, panel: panel)
            } else if let newActive = group.activeWindow {
                panel.orderAbove(windowID: newActive.id)
            }
            evaluateAutoCapture()
            return
        }

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

    func addWindow(_ window: WindowInfo, to group: TabGroup, afterActive: Bool = false, at explicitIndex: Int? = nil) {
        guard !window.isSeparator else {
            insertSeparatorTab(into: group, at: explicitIndex)
            return
        }
        if group.spaceID != 0,
           let windowSpace = SpaceUtils.spaceID(for: window.id),
           windowSpace != group.spaceID {
            Logger.log("[SPACE] Rejected addWindow wid=\(window.id) (space \(windowSpace)) to group \(group.id) (space \(group.spaceID))")
            return
        }
        mruTracker.removeWindow(window.id)
        setExpectedFrame(group.frame, for: [window.id])
        AccessibilityHelper.setFrame(of: window.element, to: group.frame)
        // Use explicit index if provided, otherwise insert after active for same-app or auto-capture
        let insertionIndex: Int?
        if let explicitIndex {
            insertionIndex = explicitIndex
        } else {
            let insertAfterActive = afterActive || (group.activeWindow.map { $0.bundleID == window.bundleID } ?? false)
            insertionIndex = insertAfterActive ? group.activeIndex + 1 : nil
        }
        groupManager.addWindow(window, to: group, at: insertionIndex)
        windowObserver.observe(window: window)

        let newIndex = group.windows.firstIndex(where: { $0.id == window.id }) ?? group.windows.count - 1
        group.switchTo(index: newIndex)
        lastActiveGroupID = group.id
        bringTabToFront(window, in: group)
        evaluateAutoCapture()
    }

    func insertSeparatorTab(into group: TabGroup, at explicitIndex: Int? = nil) {
        let insertionIndex = explicitIndex ?? min(group.activeIndex + 1, group.windows.count)
        let separatorID = group.addSeparator(at: insertionIndex)
        groupManager.objectWillChange.send()
        Logger.log("[TAB] inserted separator \(separatorID) in group \(group.id) at index \(insertionIndex)")
    }

    func handleGroupDissolution(group: TabGroup, panel: TabBarPanel) {
        if barDraggingGroupID == group.id { barDraggingGroupID = nil }
        if autoCaptureGroup === group { deactivateAutoCapture() }
        if lastActiveGroupID == group.id { lastActiveGroupID = nil }
        selectedTabIDsByGroupID.removeValue(forKey: group.id)
        mruTracker.removeGroup(group.id)

        if cyclingGroup === group { cyclingGroup = nil }
        resyncWorkItems[group.id]?.cancel()
        resyncWorkItems.removeValue(forKey: group.id)
        for window in group.managedWindows { expectedFrames.removeValue(forKey: window.id) }

        if let lastWindow = group.managedWindows.first {
            windowObserver.stopObserving(window: lastWindow)
            if !lastWindow.isFullscreened, group.tabBarSqueezeDelta > 0,
               let lastFrame = AccessibilityHelper.getFrame(of: lastWindow.element) {
                let expandedFrame = ScreenCompensation.expandFrame(lastFrame, undoingSqueezeDelta: group.tabBarSqueezeDelta)
                AccessibilityHelper.setFrame(of: lastWindow.element, to: expandedFrame)
            }
        }
        panel.close()
        tabBarPanels.removeValue(forKey: group.id)
        refreshMaximizedGroupCounters()
    }

    func disbandGroup(_ group: TabGroup) {
        guard let panel = tabBarPanels[group.id] else { return }
        suppressAutoJoin(windowIDs: group.managedWindows.map(\.id))

        if barDraggingGroupID == group.id { barDraggingGroupID = nil }
        if autoCaptureGroup === group { deactivateAutoCapture() }
        if lastActiveGroupID == group.id { lastActiveGroupID = nil }
        selectedTabIDsByGroupID.removeValue(forKey: group.id)
        mruTracker.removeGroup(group.id)

        if cyclingGroup === group { cyclingGroup = nil }
        resyncWorkItems[group.id]?.cancel()
        resyncWorkItems.removeValue(forKey: group.id)
        for window in group.managedWindows { expectedFrames.removeValue(forKey: window.id) }

        for window in group.managedWindows {
            windowObserver.stopObserving(window: window)
            if !window.isFullscreened, group.tabBarSqueezeDelta > 0,
               let frame = AccessibilityHelper.getFrame(of: window.element) {
                let expandedFrame = ScreenCompensation.expandFrame(frame, undoingSqueezeDelta: group.tabBarSqueezeDelta)
                AccessibilityHelper.setFrame(of: window.element, to: expandedFrame)
            }
        }

        groupManager.dissolveGroup(group)
        panel.close()
        tabBarPanels.removeValue(forKey: group.id)
        refreshMaximizedGroupCounters()
    }

    func quitGroup(_ group: TabGroup) {
        guard let panel = tabBarPanels[group.id] else { return }

        if barDraggingGroupID == group.id { barDraggingGroupID = nil }
        if autoCaptureGroup === group { deactivateAutoCapture() }
        if lastActiveGroupID == group.id { lastActiveGroupID = nil }
        selectedTabIDsByGroupID.removeValue(forKey: group.id)
        mruTracker.removeGroup(group.id)

        if cyclingGroup === group { cyclingGroup = nil }
        resyncWorkItems[group.id]?.cancel()
        resyncWorkItems.removeValue(forKey: group.id)

        for window in group.managedWindows {
            windowObserver.stopObserving(window: window)
            expectedFrames.removeValue(forKey: window.id)
            AccessibilityHelper.closeWindow(window.element)
        }

        groupManager.dissolveGroup(group)
        panel.close()
        tabBarPanels.removeValue(forKey: group.id)
        refreshMaximizedGroupCounters()
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

    /// Returns selected tab IDs for hotkey actions only when the active group has a true multi-selection.
    /// Keeps the cache in sync by pruning stale IDs that are no longer in the group.
    func multiSelectedTabIDsForHotkey(in group: TabGroup) -> Set<CGWindowID>? {
        guard let selected = selectedTabIDsByGroupID[group.id] else { return nil }
        let valid = selected.intersection(Set(group.managedWindows.map(\.id)))
        selectedTabIDsByGroupID[group.id] = valid
        return valid.count > 1 ? valid : nil
    }

    func mergeGroup(_ source: TabGroup, into target: TabGroup, at insertAt: Int? = nil) {
        guard let sourcePanel = tabBarPanels[source.id] else { return }
        if target.spaceID != 0, source.spaceID != 0, target.spaceID != source.spaceID {
            Logger.log("[SPACE] Rejected merge: source space \(source.spaceID) != target space \(target.spaceID)")
            return
        }
        let windowsToMerge = source.managedWindows
        guard !windowsToMerge.isEmpty else { return }

        // Stop observing source windows (they'll be re-observed under target)
        for window in windowsToMerge {
            windowObserver.stopObserving(window: window)
            expectedFrames.removeValue(forKey: window.id)
        }

        // Clean up source group state (like disbandGroup but without frame expansion)
        if autoCaptureGroup === source { deactivateAutoCapture() }
        if lastActiveGroupID == source.id { lastActiveGroupID = nil }
        selectedTabIDsByGroupID.removeValue(forKey: source.id)
        mruTracker.removeGroup(source.id)
        if cyclingGroup === source { cyclingGroup = nil }
        resyncWorkItems[source.id]?.cancel()
        resyncWorkItems.removeValue(forKey: source.id)

        // Dissolve source group and close its panel
        groupManager.dissolveGroup(source)
        sourcePanel.close()
        tabBarPanels.removeValue(forKey: source.id)

        // Add all source windows to target group
        for (offset, window) in windowsToMerge.enumerated() {
            setExpectedFrame(target.frame, for: [window.id])
            AccessibilityHelper.setFrame(of: window.element, to: target.frame)
            let index = insertAt.map { $0 + offset }
            groupManager.addWindow(window, to: target, at: index)
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
        if let ids = multiSelectedTabIDsForHotkey(in: group) {
            releaseTabs(withIDs: ids, from: group, panel: panel)
            return
        }
        releaseTab(at: group.activeIndex, from: group, panel: panel)
    }

    func handleHotkeyCloseTab() {
        guard let (group, panel) = activeGroup() else { return }
        if let ids = multiSelectedTabIDsForHotkey(in: group) {
            closeTabs(withIDs: ids, from: group, panel: panel)
            return
        }
        closeTab(at: group.activeIndex, from: group, panel: panel)
    }

    func handleHotkeySwitchToTab(_ index: Int) {
        guard let (group, panel) = activeGroup(),
              index >= 0 else { return }
        let windows = group.managedWindows
        guard !windows.isEmpty else { return }
        let targetWindow = (index == 8) ? windows.last : windows[safe: index]
        guard let targetWindow,
              let targetIndex = group.windows.firstIndex(where: { $0.id == targetWindow.id }) else { return }
        switchTab(in: group, to: targetIndex, panel: panel)
    }

    func preparePanelForInlineGroupNameEdit(_ panel: TabBarPanel, group: TabGroup) {
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        if let activeWindow = group.activeWindow {
            panel.orderAbove(windowID: activeWindow.id)
        }
    }

    func applyGroupName(_ rawName: String?, to group: TabGroup) {
        let trimmed = rawName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = (trimmed?.isEmpty ?? true) ? nil : trimmed
        let previousName = group.displayName
        group.name = normalized
        let updatedName = group.displayName

        guard previousName != updatedName else { return }
        if let updatedName {
            Logger.log("[GroupName] Group \(group.id) renamed to '\(updatedName)'")
        } else {
            Logger.log("[GroupName] Group \(group.id) name cleared")
        }
    }

    func applyTabName(_ rawName: String?, for windowID: CGWindowID, in group: TabGroup) {
        let didUpdate = groupManager.updateWindowCustomTabName(
            withID: windowID,
            in: group,
            to: rawName
        )
        guard didUpdate else { return }

        if let updated = group.windows.first(where: { $0.id == windowID }),
           let customName = updated.displayedCustomTabName {
            Logger.log("[TabName] Window \(windowID) in group \(group.id) renamed to '\(customName)'")
        } else {
            Logger.log("[TabName] Window \(windowID) in group \(group.id) name cleared")
        }
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

        let allIDs = group.visibleWindows.map(\.id)
        setExpectedFrame(newFrame, for: allIDs)
        for window in group.visibleWindows {
            AccessibilityHelper.setPosition(of: window.element, to: newFrame.origin)
        }
    }

    func handleBarDragEnded(group: TabGroup, panel: TabBarPanel) {
        barDraggingGroupID = nil
        barDragInitialFrame = nil

        // Sync all windows to the final position
        let allIDs = group.visibleWindows.map(\.id)
        setExpectedFrame(group.frame, for: allIDs)
        for window in group.visibleWindows {
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
            let others = group.visibleWindows.filter { $0.id != activeWindow.id }
            setExpectedFrame(adjustedFrame, for: others.map(\.id))
            for window in others {
                AccessibilityHelper.setFrame(of: window.element, to: adjustedFrame)
            }
        }

        panel.positionAbove(windowFrame: group.frame, isMaximized: isGroupMaximized(group).0)
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
        let allIDs = group.visibleWindows.map(\.id)
        setExpectedFrame(frame, for: allIDs)
        for window in group.visibleWindows {
            AccessibilityHelper.setFrame(of: window.element, to: frame)
        }
        panel.positionAbove(windowFrame: frame, isMaximized: isGroupMaximized(group).0)
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

            let panelWidth = panel.frame.width
            let showHandle = tabBarConfig.showDragHandle
            let leadingPad: CGFloat = showHandle ? 4 : 2
            let trailingPad: CGFloat = 4
            let handleWidth: CGFloat = showHandle ? TabBarView.dragHandleWidth : 0
            let groupCounterWidth = TabBarView.groupCounterReservedWidth(
                counterGroupIDs: group.maximizedGroupCounterIDs,
                currentGroupID: group.id,
                enabled: tabBarConfig.showMaximizedGroupCounters
            )
            let groupNameWidth = TabBarView.groupNameReservedWidth(for: group.name)
            let availableWidth = panelWidth - leadingPad - trailingPad - TabBarView.addButtonWidth - groupCounterWidth - handleWidth - groupNameWidth
            let layout = TabBarView.tabWidthLayout(
                availableWidth: availableWidth,
                tabs: group.windows,
                style: tabBarConfig.style
            )

            // Convert mouse X to local panel coordinates
            let localX = mouseLocation.x - panel.frame.origin.x
            let tabContentStartX = leadingPad + groupCounterWidth + handleWidth + groupNameWidth
            let localTabX = localX - tabContentStartX
            let insertionIndex = TabBarView.insertionIndexForPoint(
                localTabX: localTabX,
                tabWidths: layout.widths,
                tabs: group.windows
            )

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
              tabBarPanels[targetGroupID] != nil else { return }

        if targetGroup.spaceID != 0, sourceGroup.spaceID != 0, targetGroup.spaceID != sourceGroup.spaceID {
            Logger.log("[SPACE] Rejected cross-panel drop: source space \(sourceGroup.spaceID) != target space \(targetGroup.spaceID)")
            return
        }

        Logger.log("[DRAG] Cross-panel drop: \(ids) from group \(sourceGroup.id) to group \(targetGroupID) at index \(insertionIndex)")
        targetGroup.dropIndicatorIndex = nil

        let windowsToMove = sourceGroup.managedWindows.filter { ids.contains($0.id) }
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
        let shouldPinOnInsert = targetGroup.pinnedCount > 0 && insertionIndex < targetGroup.pinnedCount
        for (offset, window) in windowsToMove.enumerated() {
            var windowToInsert = window
            if shouldPinOnInsert {
                windowToInsert.isPinned = true
            }
            setExpectedFrame(targetGroup.frame, for: [window.id])
            AccessibilityHelper.setFrame(of: window.element, to: targetGroup.frame)
            groupManager.addWindow(windowToInsert, to: targetGroup, at: insertionIndex + offset)
            windowObserver.observe(window: windowToInsert)
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
        let releasedWindows = group.managedWindows.filter { ids.contains($0.id) }
        let separatorIDs = Set(group.windows.filter { ids.contains($0.id) && $0.isSeparator }.map(\.id))
        suppressAutoJoin(windowIDs: releasedWindows.map(\.id))

        for window in releasedWindows {
            windowObserver.stopObserving(window: window)
            expectedFrames.removeValue(forKey: window.id)

            if !window.isFullscreened, let frame = AccessibilityHelper.getFrame(of: window.element) {
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

        groupManager.releaseWindows(withIDs: Set(releasedWindows.map(\.id)).union(separatorIDs), from: group)

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
        let windowsToMove = group.managedWindows.filter { ids.contains($0.id) }
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
        let separatorIDs = Set(group.windows.filter { ids.contains($0.id) && $0.isSeparator }.map(\.id))
        for id in ids {
            guard let window = group.windows.first(where: { $0.id == id }),
                  !window.isSeparator else { continue }
            windowObserver.stopObserving(window: window)
            expectedFrames.removeValue(forKey: window.id)
            AccessibilityHelper.closeWindow(window.element)
        }

        let realWindowIDs = Set(group.managedWindows.filter { ids.contains($0.id) }.map(\.id))
        groupManager.releaseWindows(withIDs: realWindowIDs.union(separatorIDs), from: group)

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
            let affectedWindows = group.managedWindows.filter { $0.ownerPID == pid }
            guard !affectedWindows.isEmpty else { continue }
            for window in affectedWindows {
                mruTracker.removeWindow(window.id)
                expectedFrames.removeValue(forKey: window.id)
                windowObserver.handleDestroyedWindow(pid: pid, elementHash: CFHash(window.element))
                groupManager.releaseWindow(withID: window.id, from: group)
            }
            if !groupManager.groups.contains(where: { $0.id == group.id }),
               let panel = tabBarPanels[group.id] {
                if let survivor = group.managedWindows.first, survivor.ownerPID != pid {
                    handleGroupDissolution(group: group, panel: panel)
                } else {
                    // All windows belonged to the terminated app — no survivor
                    // to expand, but still need full state cleanup.
                    if barDraggingGroupID == group.id { barDraggingGroupID = nil }
                    if autoCaptureGroup === group { deactivateAutoCapture() }
                    if lastActiveGroupID == group.id { lastActiveGroupID = nil }
                    selectedTabIDsByGroupID.removeValue(forKey: group.id)
                    mruTracker.removeGroup(group.id)
                    if cyclingGroup === group { cyclingGroup = nil }
                    resyncWorkItems[group.id]?.cancel()
                    resyncWorkItems.removeValue(forKey: group.id)
                    panel.close()
                    tabBarPanels.removeValue(forKey: group.id)
                }
            } else if let newActive = group.activeWindow {
                bringTabToFront(newActive, in: group)
            }
        }
        evaluateAutoCapture()
    }
}
