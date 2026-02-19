import AppKit
import SwiftUI

// MARK: - Group Lifecycle

extension AppDelegate {

    func focusWindow(_ window: WindowInfo, completion: (() -> Void)? = nil) {
        Logger.log("[FOCUSDBG] focusWindow begin window=\(window.id) pid=\(window.ownerPID) memberships=\(groupManager.membershipCount(for: window.id))")
        AccessibilityHelper.raiseWindowAsync(window) { [weak self] freshElement in
            guard let self else { return }
            let groups = self.groupManager.groups(for: window.id)
            guard !groups.isEmpty else { return }
            Logger.log("[FOCUSDBG] focusWindow refreshedElement window=\(window.id)")
            for group in groups {
                if let idx = group.windows.firstIndex(where: { $0.id == window.id }) {
                    group.windows[idx].element = freshElement
                }
            }
            completion?()
        }
    }

    func ownerGroup(for windowID: CGWindowID, source: String = "unknown") -> TabGroup? {
        let membershipCount = groupManager.membershipCount(for: windowID)
        let shouldLog = membershipCount > 1
        let memberIDs = shouldLog
            ? groupManager.groups(for: windowID).map(\.id.uuidString).joined(separator: ",")
            : ""

        if let lastActiveGroupID,
           let lastActiveGroup = groupManager.groups.first(where: { $0.id == lastActiveGroupID }),
           lastActiveGroup.contains(windowID: windowID) {
            if shouldLog {
                Logger.log(
                    "[OWNERDBG] source=\(source) window=\(windowID) memberships=\(membershipCount) resolve=lastActive group=\(lastActiveGroup.id) members=[\(memberIDs)]"
                )
            }
            return lastActiveGroup
        }
        let resolved = groupManager.group(for: windowID)
        if shouldLog {
            Logger.log(
                "[OWNERDBG] source=\(source) window=\(windowID) memberships=\(membershipCount) resolve=primary group=\(resolved?.id.uuidString ?? "nil") lastActive=\(lastActiveGroupID?.uuidString ?? "nil") members=[\(memberIDs)]"
            )
        }
        return resolved
    }

    /// For move/resize events: when a mirrored window is dragged, resolve the group whose
    /// frame is spatially closest to the window's current frame — that's the tab bar that
    /// should follow. Falls back to ownerGroup for single-membership or when frame is unavailable.
    func ownerGroupForWindowMove(for windowID: CGWindowID, currentFrame: CGRect, source: String = "unknown") -> TabGroup? {
        let groups = groupManager.groups(for: windowID)
        guard !groups.isEmpty else { return nil }
        guard groups.count > 1 else { return groups[0] }

        let closest = groups.min(by: { a, b in
            let da = hypot(a.frame.origin.x - currentFrame.origin.x, a.frame.origin.y - currentFrame.origin.y)
            let db = hypot(b.frame.origin.x - currentFrame.origin.x, b.frame.origin.y - currentFrame.origin.y)
            return da < db
        })
        if let g = closest {
            Logger.log(
                "[OWNERDBG] source=\(source) window=\(windowID) memberships=\(groups.count) resolve=spatial group=\(g.id)"
            )
        }
        return closest
    }

    func promoteWindowOwnership(windowID: CGWindowID, group: TabGroup) {
        let previous = lastActiveGroupID
        lastActiveGroupID = group.id
        let promoted = groupManager.promotePrimaryGroup(windowID: windowID, groupID: group.id)
        let membershipCount = groupManager.membershipCount(for: windowID)
        if membershipCount > 1 || !promoted {
            Logger.log(
                "[OWNERDBG] promote window=\(windowID) group=\(group.id) memberships=\(membershipCount) promoted=\(promoted) lastActive=\(previous?.uuidString ?? "nil")->\(group.id.uuidString)"
            )
        }
    }

    func beginObservingWindowIfNeeded(_ window: WindowInfo) {
        guard !window.isSeparator else { return }
        guard groupManager.membershipCount(for: window.id) > 0 else { return }
        guard !windowObserver.isObserving(windowID: window.id) else { return }
        windowObserver.observe(window: window)
    }

    func stopObservingWindowIfUnused(_ window: WindowInfo) {
        guard !window.isSeparator else { return }
        guard groupManager.membershipCount(for: window.id) == 0 else { return }
        guard windowObserver.isObserving(windowID: window.id) else { return }
        windowObserver.stopObserving(window: window)
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
        let appCatalog = appCatalogService.loadCatalog()
        let resolvedURLProvider = browserProviderResolver.resolve(selection: addWindowLauncherConfig.urlProviderSelection)
        let resolvedSearchProvider = browserProviderResolver.resolve(selection: addWindowLauncherConfig.searchProviderSelection)
        let currentSpaceID = resolveCurrentSpaceID(windowsOnCurrentSpace: spaceWindows)

        let mergeGroups: [TabGroup]
        let looseWindows: [WindowInfo]
        let mirroredWindowIDs: Set<CGWindowID>
        let mode: LauncherMode
        if let group {
            mode = .addToGroup(targetGroupID: group.id, targetSpaceID: group.spaceID)
            let resolvedTargetSpaceID: UInt64? = {
                if group.spaceID != 0 { return group.spaceID }
                if let activeWindowID = group.activeWindow?.id {
                    return SpaceUtils.spaceID(for: activeWindowID)
                }
                return nil
            }()
            looseWindows = spaceWindows.filter { window in
                if group.contains(windowID: window.id) {
                    return false
                }
                if let targetSpaceID = resolvedTargetSpaceID,
                   let windowSpaceID = SpaceUtils.spaceID(for: window.id),
                   windowSpaceID != targetSpaceID {
                    return false
                }
                return true
            }
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
            mirroredWindowIDs = Set(
                looseWindows
                    .map(\.id)
                    .filter { groupManager.isWindowGrouped($0) }
            )
        } else {
            mode = .newGroup
            looseWindows = spaceWindows.filter { !groupManager.isWindowGrouped($0.id) }
            mergeGroups = []
            mirroredWindowIDs = []
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
            mirroredWindowIDs: mirroredWindowIDs,
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
        AccessibilityHelper.frontmostFocusedWindowID()
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
                addWindow(window, to: targetGroup, at: insertAt, allowSharedMembership: true)
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
        name: String? = nil,
        allowSharedMembership: Bool = false
    ) -> TabGroup? {
        let spaceID = windows.first.flatMap { SpaceUtils.spaceID(for: $0.id) } ?? 0
        guard let group = groupManager.createGroup(
            with: windows,
            frame: frame,
            spaceID: spaceID,
            name: name,
            allowSharedMembership: allowSharedMembership
        ) else { return nil }
        Logger.log("[SPACE] Created group \(group.id) on space \(spaceID)")
        group.tabBarSqueezeDelta = squeezeDelta
        group.switchTo(index: activeIndex)

        setExpectedFrame(frame, for: group.visibleWindows.map(\.id))

        for window in group.visibleWindows {
            AccessibilityHelper.setFrameAsync(of: window.element, to: frame)
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
            onReorderGroupCounters: { [weak self] orderedGroupIDs in
                self?.reorderMaximizedGroupCounters(from: group.id, orderedGroupIDs: orderedGroupIDs)
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
            onSetPinned: { [weak self] ids, pinned in
                self?.setPinned(pinned, forWindowIDs: ids, in: group)
            },
            onSetSuperPinned: { [weak self] ids, superPinned in
                self?.setSuperPinned(superPinned, forWindowIDs: ids, in: group)
            },
            onSuperPinnedOrderChanged: { [weak self] orderedWindowIDs in
                self?.syncSuperPinnedOrder(from: group, orderedWindowIDs: orderedWindowIDs)
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
            },
            isWindowShared: { [weak self] windowID in
                (self?.groupManager.membershipCount(for: windowID) ?? 0) > 1
            },
            groupNameForCounterGroupID: { [weak self] targetGroupID in
                self?.groupManager.groups.first(where: { $0.id == targetGroupID })?.displayName
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
            beginObservingWindowIfNeeded(window)
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
                        AccessibilityHelper.setFrameAsync(of: window.element, to: clamped)
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
        let previousCounterIDsByGroupID = Dictionary(
            uniqueKeysWithValues: groupManager.groups.map { ($0.id, $0.maximizedGroupCounterIDs) }
        )
        let candidates = groupManager.groups.map { group in
            MaximizedGroupCounterPolicy.Candidate(
                groupID: group.id,
                spaceID: resolvedSpaceID(for: group),
                isMaximized: isGroupMaximized(group).0
            )
        }
        var validIDsBySpaceID: [UInt64: Set<UUID>] = [:]
        for candidate in candidates where candidate.isMaximized {
            guard let spaceID = candidate.spaceID else { continue }
            validIDsBySpaceID[spaceID, default: []].insert(candidate.groupID)
        }
        for (spaceID, order) in maximizedCounterOrderBySpaceID {
            guard let validIDs = validIDsBySpaceID[spaceID], !validIDs.isEmpty else {
                maximizedCounterOrderBySpaceID.removeValue(forKey: spaceID)
                continue
            }
            let pruned = order.filter { validIDs.contains($0) }
            if pruned.isEmpty {
                maximizedCounterOrderBySpaceID.removeValue(forKey: spaceID)
            } else if pruned != order {
                maximizedCounterOrderBySpaceID[spaceID] = pruned
            }
        }
        let countersByGroupID = MaximizedGroupCounterPolicy.counterGroupIDsByGroupID(
            candidates: candidates,
            preferredOrderBySpaceID: maximizedCounterOrderBySpaceID
        )
        for group in groupManager.groups {
            let next = countersByGroupID[group.id] ?? []
            if group.maximizedGroupCounterIDs != next {
                group.maximizedGroupCounterIDs = next
            }
        }

        applySuperpinMaximizeTransitions(
            candidates: candidates,
            previousCounterIDsByGroupID: previousCounterIDsByGroupID
        )
        var nextKnownStates: [UUID: Bool] = [:]
        for candidate in candidates {
            nextKnownStates[candidate.groupID] = candidate.isMaximized
        }
        lastKnownMaximizedStateByGroupID = nextKnownStates
    }

    private func applySuperpinMaximizeTransitions(
        candidates: [MaximizedGroupCounterPolicy.Candidate],
        previousCounterIDsByGroupID: [UUID: [UUID]]
    ) {
        guard !isApplyingSuperpinMaximizeTransitions else { return }
        guard tabBarConfig.showMaximizedGroupCounters else { return }

        isApplyingSuperpinMaximizeTransitions = true
        defer { isApplyingSuperpinMaximizeTransitions = false }

        let previousStates = lastKnownMaximizedStateByGroupID
        let candidatesByGroupID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.groupID, $0) })
        var didMutate = false
        for candidate in candidates {
            let wasMaximized = previousStates[candidate.groupID] ?? false
            let previousCounterIDs = previousCounterIDsByGroupID[candidate.groupID] ?? []
            guard (wasMaximized != candidate.isMaximized) || previousCounterIDs != (groupManager.groups.first(where: { $0.id == candidate.groupID })?.maximizedGroupCounterIDs ?? []),
                  let group = groupManager.groups.first(where: { $0.id == candidate.groupID }) else { continue }

            var alreadySynchronized = false
            var alreadyHandledSupportLoss = false
            if wasMaximized != candidate.isMaximized {
                if candidate.isMaximized {
                    didMutate = handleGroupDidMaximize(group) || didMutate
                    alreadySynchronized = true
                } else {
                    let remainingPeerCount = previousCounterIDs
                        .filter { $0 != group.id && (candidatesByGroupID[$0]?.isMaximized ?? false) }
                        .count
                    didMutate = handleGroupDidUnmaximize(group, remainingPeerCount: remainingPeerCount) || didMutate
                    alreadyHandledSupportLoss = true
                }
            }

            let previousSupportsSuperpin = supportsSuperpin(
                counterGroupIDs: previousCounterIDs,
                currentGroupID: group.id
            )
            let nextCounterIDs = group.maximizedGroupCounterIDs
            let nextSupportsSuperpin = supportsSuperpin(
                counterGroupIDs: nextCounterIDs,
                currentGroupID: group.id
            )

            if previousSupportsSuperpin && !nextSupportsSuperpin {
                if !alreadyHandledSupportLoss {
                    let remainingPeerCount = previousCounterIDs
                        .filter { $0 != group.id && (candidatesByGroupID[$0]?.isMaximized ?? false) }
                        .count
                    didMutate = handleGroupLostSuperpinSupport(group, remainingPeerCount: remainingPeerCount) || didMutate
                }
            } else if nextSupportsSuperpin && !alreadySynchronized {
                didMutate = synchronizeSuperpins(for: group) || didMutate
            }
        }

        if didMutate {
            dissolveFunctionallyEmptySuperpinGroups()
            groupManager.objectWillChange.send()
        }
    }

    private func supportsSuperpin(counterGroupIDs: [UUID], currentGroupID: UUID) -> Bool {
        TabBarView.supportsSuperpin(
            counterGroupIDs: counterGroupIDs,
            currentGroupID: currentGroupID,
            enabled: tabBarConfig.showMaximizedGroupCounters
        )
    }

    @discardableResult
    func handleGroupLostSuperpinSupport(_ group: TabGroup, remainingPeerCount: Int) -> Bool {
        pruneSuperpinMirrorTracking()

        let mirroredWindowIDs = superpinMirroredWindowIDsByGroupID[group.id] ?? []
        let superPinnedWindowIDs = Set(
            group.windows
                .filter { !$0.isSeparator && $0.pinState == .super }
                .map(\.id)
        )
        let mirroredSuperPinnedWindowIDs = mirroredWindowIDs.intersection(superPinnedWindowIDs)
        let mirroredNonSuperPinnedWindowIDs = mirroredWindowIDs.subtracting(mirroredSuperPinnedWindowIDs)

        let localWindowIDs = superPinnedWindowIDs.subtracting(mirroredSuperPinnedWindowIDs)
        var didMutate = false
        if !localWindowIDs.isEmpty {
            group.setSuperPinned(
                false,
                forWindowIDs: localWindowIDs,
                downgradeToNormalWhenUnset: remainingPeerCount == 0
            )
            didMutate = true
        }
        if !mirroredSuperPinnedWindowIDs.isEmpty {
            _ = releaseMirroredSuperpinWindows(withIDs: mirroredSuperPinnedWindowIDs, from: group)
            didMutate = true
        }
        if !mirroredNonSuperPinnedWindowIDs.isEmpty {
            removeSuperpinMirrors(windowIDs: mirroredNonSuperPinnedWindowIDs, from: group.id)
        }
        return didMutate
    }

    @discardableResult
    private func handleGroupDidUnmaximize(_ group: TabGroup, remainingPeerCount: Int) -> Bool {
        handleGroupLostSuperpinSupport(group, remainingPeerCount: remainingPeerCount)
    }

    @discardableResult
    private func synchronizeSuperpins(for group: TabGroup) -> Bool {
        pruneSuperpinMirrorTracking()

        guard supportsSuperpin(
            counterGroupIDs: group.maximizedGroupCounterIDs,
            currentGroupID: group.id
        ) else {
            return false
        }

        let groupsByID = Dictionary(uniqueKeysWithValues: groupManager.groups.map { ($0.id, $0) })
        let peerGroups = group.maximizedGroupCounterIDs.compactMap { id -> TabGroup? in
            guard id != group.id else { return nil }
            return groupsByID[id]
        }
        guard !peerGroups.isEmpty else { return false }

        var superPinnedByWindowID: [CGWindowID: WindowInfo] = [:]
        for peer in peerGroups {
            for window in peer.windows where !window.isSeparator && window.pinState == .super {
                if superPinnedByWindowID[window.id] == nil {
                    superPinnedByWindowID[window.id] = window
                }
            }
        }

        let expectedSuperPinnedWindowIDs = Set(superPinnedByWindowID.keys)
        let trackedMirrors = superpinMirroredWindowIDsByGroupID[group.id] ?? []
        let staleMirrors = trackedMirrors.subtracting(expectedSuperPinnedWindowIDs)
        let currentSuperPinnedWindowIDs = Set(
            group.windows
                .filter { !$0.isSeparator && $0.pinState == .super }
                .map(\.id)
        )
        let staleSuperPinnedMirrors = staleMirrors.intersection(currentSuperPinnedWindowIDs)
        let staleNonSuperPinnedMirrors = staleMirrors.subtracting(staleSuperPinnedMirrors)

        var didMutate = false
        if !staleSuperPinnedMirrors.isEmpty {
            _ = releaseMirroredSuperpinWindows(withIDs: staleSuperPinnedMirrors, from: group)
            didMutate = true
        }
        if !staleNonSuperPinnedMirrors.isEmpty {
            removeSuperpinMirrors(windowIDs: staleNonSuperPinnedMirrors, from: group.id)
        }
        guard !superPinnedByWindowID.isEmpty else { return didMutate }

        for (windowID, windowInfo) in superPinnedByWindowID {
            if group.contains(windowID: windowID) {
                group.setSuperPinned(true, forWindowIDs: [windowID])
                if let ownerGroupID = groupManager.group(for: windowID)?.id, ownerGroupID != group.id {
                    markSuperpinMirror(windowID: windowID, in: group.id)
                }
                didMutate = true
                continue
            }

            var mirrored = windowInfo
            mirrored.pinState = .super
            let didAdd = groupManager.addWindow(
                mirrored,
                to: group,
                at: group.superPinnedCount,
                allowSharedMembership: true
            )
            guard didAdd else { continue }
            markSuperpinMirror(windowID: windowID, in: group.id)
            beginObservingWindowIfNeeded(mirrored)
            didMutate = true
        }
        return didMutate
    }

    @discardableResult
    private func handleGroupDidMaximize(_ group: TabGroup) -> Bool {
        synchronizeSuperpins(for: group)
    }

    func focusGroupFromCounter(_ targetGroupID: UUID) {
        guard let group = groupManager.groups.first(where: { $0.id == targetGroupID }),
              let activeWindow = group.activeWindow else { return }
        let sharedGroupIDs = groupManager.groups(for: activeWindow.id).map(\.id.uuidString).joined(separator: ",")
        Logger.log("[COUNTERDBG] click targetGroup=\(targetGroupID) activeWindow=\(activeWindow.id) lastActiveGroup=\(lastActiveGroupID?.uuidString ?? "nil") focusedWindowBefore=\(focusedWindowID().map(String.init) ?? "nil") sharedGroups=[\(sharedGroupIDs)]")
        promoteWindowOwnership(windowID: activeWindow.id, group: group)
        group.recordFocus(windowID: activeWindow.id)
        performCounterFocus(
            on: group,
            activeWindow: activeWindow,
            focusedWindowID: focusedWindowID()
        )
    }

    func performCounterFocus(on group: TabGroup, activeWindow: WindowInfo, focusedWindowID: CGWindowID?) {
        Logger.log(
            "[COUNTER] focus group=\(group.id) window=\(activeWindow.id) focused=\(focusedWindowID.map(String.init) ?? "nil") memberships=\(groupManager.membershipCount(for: activeWindow.id))"
        )
        if prepareCounterFocusTransition(targetWindowID: activeWindow.id, focusedWindowID: focusedWindowID) {
            focusWindow(activeWindow)
        }
        showCounterTargetPanel(group: group, activeWindow: activeWindow)
    }

    @discardableResult
    func prepareCounterFocusTransition(targetWindowID: CGWindowID, focusedWindowID: CGWindowID?) -> Bool {
        guard focusedWindowID != targetWindowID else {
            Logger.log("[COUNTERDBG] transition skip reason=already-focused target=\(targetWindowID)")
            return false
        }
        Logger.log("[COUNTERDBG] transition apply target=\(targetWindowID) focusedBefore=\(focusedWindowID.map(String.init) ?? "nil")")
        beginCommitEchoSuppression(targetWindowID: targetWindowID, source: "counter-click")
        invalidateDeferredFocusPanelOrdering(reason: "counter-click target=\(targetWindowID)")
        return true
    }

    func showCounterTargetPanel(group: TabGroup, activeWindow: WindowInfo) {
        guard !activeWindow.isFullscreened,
              let panel = tabBarPanels[group.id] else { return }
        panel.show(
            above: group.frame,
            windowID: activeWindow.id,
            isMaximized: isGroupMaximized(group).0
        )
        movePanelToWindowSpace(panel, windowID: activeWindow.id)
        prioritizePanelZOrderForSharedWindow(windowID: activeWindow.id, ownerGroupID: group.id)
    }

    func prioritizePanelZOrderForSharedWindow(windowID: CGWindowID, ownerGroupID: UUID) {
        guard let ownerPanel = tabBarPanels[ownerGroupID] else { return }
        ownerPanel.orderFrontRegardless()

        let sharedGroupIDs = groupManager
            .groups(for: windowID)
            .map(\.id)
            .filter { $0 != ownerGroupID }

        Logger.log(
            "[COUNTER] panel-priority window=\(windowID) owner=\(ownerGroupID) ownerPanel=\(ownerPanel.windowNumber) sharedCount=\(sharedGroupIDs.count)"
        )

        for groupID in sharedGroupIDs {
            guard let panel = tabBarPanels[groupID] else { continue }
            Logger.log(
                "[COUNTERDBG] panel-hide window=\(windowID) owner=\(ownerGroupID) targetGroup=\(groupID) targetPanel=\(panel.windowNumber) relativeToOwnerPanel=\(ownerPanel.windowNumber) visibleBefore=\(panel.isVisible)"
            )
            // Keep only the selected group's bar visible for shared windows.
            // `order(.below, ...)` can still leave stale bars flashing above during
            // rapid focus/activation churn; explicitly hiding avoids that race.
            panel.orderOut(nil)
        }
    }

    func reorderMaximizedGroupCounters(from sourceGroupID: UUID, orderedGroupIDs: [UUID]) {
        guard let sourceGroup = groupManager.groups.first(where: { $0.id == sourceGroupID }),
              let spaceID = resolvedSpaceID(for: sourceGroup) else { return }
        let maximizedGroupIDs = groupManager.groups.compactMap { group -> UUID? in
            guard resolvedSpaceID(for: group) == spaceID, isGroupMaximized(group).0 else { return nil }
            return group.id
        }
        guard maximizedGroupIDs.count >= 2 else { return }

        let validSet = Set(maximizedGroupIDs)
        var preferred: [UUID] = []
        preferred.reserveCapacity(maximizedGroupIDs.count)
        for id in orderedGroupIDs where validSet.contains(id) && !preferred.contains(id) {
            preferred.append(id)
        }
        for id in maximizedGroupIDs where !preferred.contains(id) {
            preferred.append(id)
        }
        maximizedCounterOrderBySpaceID[spaceID] = preferred
        refreshMaximizedGroupCounters()
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
        let windowID = window.id
        let groupID = group.id
        AccessibilityHelper.raiseWindowAsync(window) { [weak self] freshElement in
            guard let self else { return }
            if let idx = group.windows.firstIndex(where: { $0.id == windowID }) {
                group.windows[idx].element = freshElement
            }
            self.tabBarPanels[groupID]?.orderAbove(windowID: windowID)
        }
    }

    /// Move the tab bar panel to the same Space as the given window, if they differ.
    func movePanelToWindowSpace(_ panel: TabBarPanel, windowID: CGWindowID) {
        guard panel.windowNumber > 0 else { return }
        guard let targetSpace = SpaceUtils.spaceID(for: windowID) else { return }
        let panelWID = CGWindowID(panel.windowNumber)
        guard SpaceUtils.spaceID(for: panelWID) != targetSpace else { return }
        SpaceUtils.moveWindow(panelWID, toSpace: targetSpace)
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
        promoteWindowOwnership(windowID: window.id, group: group)
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
        AccessibilityHelper.setFrameAsync(of: window.element, to: group.frame)

        bringTabToFront(window, in: group)
    }

    func releaseTab(at index: Int, from group: TabGroup, panel: TabBarPanel) {
        guard let window = group.windows[safe: index] else { return }
        if window.isSeparator {
            groupManager.releaseWindow(withID: window.id, from: group)
            removeSuperpinMirrors(windowIDs: [window.id], from: group.id)
            if !groupManager.groups.contains(where: { $0.id == group.id }) {
                handleGroupDissolution(group: group, panel: panel)
            } else if let newActive = group.activeWindow {
                panel.orderAbove(windowID: newActive.id)
            }
            evaluateAutoCapture()
            return
        }
        let wasSharedAcrossGroups = groupManager.membershipCount(for: window.id) > 1

        if !wasSharedAcrossGroups {
            suppressAutoJoin(windowIDs: [window.id])
            expectedFrames.removeValue(forKey: window.id)

            // Fullscreened windows: skip frame expansion (macOS manages their frame)
            if !window.isFullscreened {
                if let frame = AccessibilityHelper.getFrame(of: window.element) {
                    let delta = max(group.tabBarSqueezeDelta, ScreenCompensation.tabBarHeight)
                    let expanded = ScreenCompensation.expandFrame(frame, undoingSqueezeDelta: delta)
                    let element = window.element
                    AccessibilityHelper.setSizeAsync(of: element, to: expanded.size)
                    AccessibilityHelper.setPositionAsync(of: element, to: expanded.origin)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        AccessibilityHelper.setPositionAsync(of: element, to: expanded.origin)
                        AccessibilityHelper.setSizeAsync(of: element, to: expanded.size)
                    }
                }
            }
        }

        _ = groupManager.releaseWindow(withID: window.id, from: group)
        removeSuperpinMirrors(windowIDs: [window.id], from: group.id)
        stopObservingWindowIfUnused(window)
        if wasSharedAcrossGroups {
            normalizeSingleMembershipAfterUnlink(windowID: window.id)
        }

        if !groupManager.groups.contains(where: { $0.id == group.id }) {
            handleGroupDissolution(group: group, panel: panel)
        } else if let newActive = group.activeWindow {
            // Don't raise the next tab — keep the released window focused
            panel.orderAbove(windowID: newActive.id)
        }
        dissolveFunctionallyEmptySuperpinGroups()
        evaluateAutoCapture()
    }

    func closeTab(at index: Int, from group: TabGroup, panel: TabBarPanel) {
        guard let window = group.windows[safe: index] else { return }
        if window.isSeparator {
            _ = groupManager.releaseWindow(withID: window.id, from: group)
            removeSuperpinMirrors(windowIDs: [window.id], from: group.id)
            if !groupManager.groups.contains(where: { $0.id == group.id }) {
                handleGroupDissolution(group: group, panel: panel)
            } else if let newActive = group.activeWindow {
                panel.orderAbove(windowID: newActive.id)
            }
            evaluateAutoCapture()
            return
        }

        expectedFrames.removeValue(forKey: window.id)

        let isSharedWindow = groupManager.membershipCount(for: window.id) > 1
        AccessibilityHelper.closeWindowAsync(window.element)
        if isSharedWindow {
            removeWindowFromAllGroups(windowID: window.id)
        } else {
            _ = groupManager.releaseWindow(withID: window.id, from: group)
            removeSuperpinMirrors(windowIDs: [window.id], from: group.id)
            stopObservingWindowIfUnused(window)
        }

        if !groupManager.groups.contains(where: { $0.id == group.id }) {
            handleGroupDissolution(group: group, panel: panel)
        } else if let newActive = group.activeWindow {
            bringTabToFront(newActive, in: group)
        }
        dissolveFunctionallyEmptySuperpinGroups()
        evaluateAutoCapture()
    }

    func removeWindowFromAllGroups(windowID: CGWindowID) {
        let containingGroups = groupManager.groups(for: windowID)
        guard !containingGroups.isEmpty else { return }
        removeSuperpinTracking(forWindowID: windowID)

        let representativeWindow = containingGroups
            .compactMap { group in group.windows.first(where: { $0.id == windowID }) }
            .first

        for group in containingGroups {
            let panel = tabBarPanels[group.id]
            _ = groupManager.releaseWindow(withID: windowID, from: group)
            removeSuperpinMirrors(windowIDs: [windowID], from: group.id)
            if !groupManager.groups.contains(where: { $0.id == group.id }) {
                if let panel {
                    handleGroupDissolution(group: group, panel: panel)
                }
            } else if let panel, let newActive = group.activeWindow {
                if lastActiveGroupID == group.id {
                    bringTabToFront(newActive, in: group)
                } else {
                    panel.orderAbove(windowID: newActive.id)
                }
            }
        }

        if let representativeWindow {
            stopObservingWindowIfUnused(representativeWindow)
        }
    }

    func addWindow(
        _ window: WindowInfo,
        to group: TabGroup,
        afterActive: Bool = false,
        at explicitIndex: Int? = nil,
        allowSharedMembership: Bool = false
    ) {
        guard !window.isSeparator else {
            insertSeparatorTab(into: group, at: explicitIndex)
            return
        }
        let resolvedGroupSpaceID: UInt64? = {
            if group.spaceID != 0 { return group.spaceID }
            if let activeWindowID = group.activeWindow?.id {
                return SpaceUtils.spaceID(for: activeWindowID)
            }
            return nil
        }()
        if let resolvedGroupSpaceID,
           let windowSpace = SpaceUtils.spaceID(for: window.id),
           windowSpace != resolvedGroupSpaceID {
            Logger.log("[SPACE] Rejected addWindow wid=\(window.id) (space \(windowSpace)) to group \(group.id) (space \(resolvedGroupSpaceID))")
            return
        }
        mruTracker.removeWindow(window.id)
        setExpectedFrame(group.frame, for: [window.id])
        AccessibilityHelper.setFrameAsync(of: window.element, to: group.frame)
        // Use explicit index if provided, otherwise insert after active for same-app or auto-capture
        let insertionIndex: Int?
        if let explicitIndex {
            insertionIndex = explicitIndex
        } else {
            let insertAfterActive = afterActive || (group.activeWindow.map { $0.bundleID == window.bundleID } ?? false)
            insertionIndex = insertAfterActive ? group.activeIndex + 1 : nil
        }
        let didAdd = groupManager.addWindow(
            window,
            to: group,
            at: insertionIndex,
            allowSharedMembership: allowSharedMembership
        )
        guard didAdd else { return }
        beginObservingWindowIfNeeded(window)

        let newIndex = group.windows.firstIndex(where: { $0.id == window.id }) ?? group.windows.count - 1
        group.switchTo(index: newIndex)
        promoteWindowOwnership(windowID: window.id, group: group)
        if !group.isCycling {
            group.recordFocus(windowID: window.id)
        }
        bringTabToFront(window, in: group)
        evaluateAutoCapture()
    }

    func setPinned(_ pinned: Bool, forWindowIDs ids: Set<CGWindowID>, in sourceGroup: TabGroup) {
        guard !ids.isEmpty else { return }
        pruneSuperpinMirrorTracking()
        if pinned {
            sourceGroup.setPinned(true, forWindowIDs: ids)
            groupManager.objectWillChange.send()
            return
        }

        let sourceWindowsByID = Dictionary(uniqueKeysWithValues: sourceGroup.windows.map { ($0.id, $0) })
        let mirroredInSourceGroup = superpinMirroredWindowIDsByGroupID[sourceGroup.id] ?? []
        sourceGroup.setPinned(false, forWindowIDs: ids)

        for windowID in ids {
            let sourceWasMirror = mirroredInSourceGroup.contains(windowID)
            let sourceWasSuperPinned = sourceWindowsByID[windowID]?.pinState == .super
            let hasMirroredPeers = superpinMirroredWindowIDsByGroupID.contains { groupID, mirroredWindowIDs in
                groupID != sourceGroup.id && mirroredWindowIDs.contains(windowID)
            }
            guard sourceWasMirror || sourceWasSuperPinned || hasMirroredPeers else { continue }

            removeSuperpinMirrors(windowIDs: [windowID], from: sourceGroup.id)
            collapseSuperpinMembership(forWindowID: windowID, keeping: sourceGroup)
        }
        dissolveFunctionallyEmptySuperpinGroups()
        groupManager.objectWillChange.send()
    }

    /// Collapse shared superpin memberships so a window lives only in the chosen source group.
    private func collapseSuperpinMembership(forWindowID windowID: CGWindowID, keeping sourceGroup: TabGroup) {
        let groupsToRelease = groupManager.groups(for: windowID).filter { $0.id != sourceGroup.id }
        for group in groupsToRelease {
            if isSuperpinMirror(windowID: windowID, in: group.id) {
                _ = releaseMirroredSuperpinWindows(withIDs: [windowID], from: group)
                continue
            }

            let representativeWindow = group.windows.first(where: { $0.id == windowID })
            _ = groupManager.releaseWindow(withID: windowID, from: group)
            removeSuperpinMirrors(windowIDs: [windowID], from: group.id)

            if !groupManager.groups.contains(where: { $0.id == group.id }) {
                if let panel = tabBarPanels[group.id] {
                    handleGroupDissolution(group: group, panel: panel)
                }
            } else if let panel = tabBarPanels[group.id], let newActive = group.activeWindow {
                if lastActiveGroupID == group.id {
                    bringTabToFront(newActive, in: group)
                } else {
                    panel.orderAbove(windowID: newActive.id)
                }
            }

            if let representativeWindow {
                stopObservingWindowIfUnused(representativeWindow)
            }
        }

        promoteWindowOwnership(windowID: windowID, group: sourceGroup)
    }

    /// Remove maximized groups that now only contain superpinned tabs.
    private func dissolveFunctionallyEmptySuperpinGroups() {
        pruneSuperpinMirrorTracking()

        let groupsToDissolve = groupManager.groups.filter { group in
            guard supportsSuperpin(
                counterGroupIDs: group.maximizedGroupCounterIDs,
                currentGroupID: group.id
            ) else {
                return false
            }
            let managedWindows = group.managedWindows
            guard !managedWindows.isEmpty else { return false }
            let managedWindowIDs = Set(managedWindows.map(\.id))
            guard let mirroredWindowIDs = superpinMirroredWindowIDsByGroupID[group.id],
                  !mirroredWindowIDs.isEmpty,
                  managedWindowIDs.isSubset(of: mirroredWindowIDs) else {
                return false
            }
            guard managedWindows.allSatisfy(\.isSuperPinned) else { return false }
            return managedWindows.allSatisfy { groupManager.membershipCount(for: $0.id) > 1 }
        }

        for group in groupsToDissolve {
            groupManager.dissolveGroup(group)
            if let panel = tabBarPanels[group.id] {
                handleGroupDissolution(group: group, panel: panel)
                continue
            }

            if barDraggingGroupID == group.id { barDraggingGroupID = nil }
            if autoCaptureGroup === group { deactivateAutoCapture() }
            if lastActiveGroupID == group.id { lastActiveGroupID = nil }
            selectedTabIDsByGroupID.removeValue(forKey: group.id)
            superpinMirroredWindowIDsByGroupID.removeValue(forKey: group.id)
            lastKnownMaximizedStateByGroupID.removeValue(forKey: group.id)
            mruTracker.removeGroup(group.id)
            if cyclingGroup === group { cyclingGroup = nil }
            resyncWorkItems[group.id]?.cancel()
            resyncWorkItems.removeValue(forKey: group.id)
            for window in group.managedWindows {
                expectedFrames.removeValue(forKey: window.id)
            }
            refreshMaximizedGroupCounters()
        }
    }

    func setSuperPinned(_ superPinned: Bool, forWindowIDs ids: Set<CGWindowID>, in sourceGroup: TabGroup) {
        guard !ids.isEmpty else { return }
        guard supportsSuperpin(
            counterGroupIDs: sourceGroup.maximizedGroupCounterIDs,
            currentGroupID: sourceGroup.id
        ) else { return }

        pruneSuperpinMirrorTracking()
        let sourceWindowsByID = Dictionary(uniqueKeysWithValues: sourceGroup.windows.map { ($0.id, $0) })
        var didMutate = false

        if superPinned {
            removeSuperpinMirrors(windowIDs: ids, from: sourceGroup.id)
            for windowID in ids {
                promoteWindowOwnership(windowID: windowID, group: sourceGroup)
            }
            let targetGroupsByID = Dictionary(uniqueKeysWithValues: groupManager.groups.map { ($0.id, $0) })
            for targetGroupID in sourceGroup.maximizedGroupCounterIDs {
                guard let targetGroup = targetGroupsByID[targetGroupID] else { continue }
                for windowID in ids {
                    guard var sourceWindow = sourceWindowsByID[windowID], !sourceWindow.isSeparator else { continue }
                    if targetGroup.contains(windowID: windowID) {
                        targetGroup.setSuperPinned(true, forWindowIDs: [windowID])
                        if targetGroup.id != sourceGroup.id,
                           let ownerGroupID = groupManager.group(for: windowID)?.id,
                           ownerGroupID != targetGroup.id {
                            markSuperpinMirror(windowID: windowID, in: targetGroup.id)
                        }
                        didMutate = true
                        continue
                    }
                    sourceWindow.pinState = .super
                    let didAdd = groupManager.addWindow(
                        sourceWindow,
                        to: targetGroup,
                        at: targetGroup.superPinnedCount,
                        allowSharedMembership: true
                    )
                    guard didAdd else { continue }
                    if targetGroup.id != sourceGroup.id {
                        markSuperpinMirror(windowID: windowID, in: targetGroup.id)
                    }
                    beginObservingWindowIfNeeded(sourceWindow)
                    didMutate = true
                }
            }
        } else {
            for windowID in ids {
                let groupsToUpdate = groupManager.groups(for: windowID)
                for group in groupsToUpdate {
                    guard groupManager.groups.contains(where: { $0.id == group.id }) else { continue }
                    if isSuperpinMirror(windowID: windowID, in: group.id) {
                        _ = releaseMirroredSuperpinWindows(withIDs: [windowID], from: group)
                        didMutate = true
                        continue
                    }
                    group.setSuperPinned(false, forWindowIDs: [windowID], downgradeToNormalWhenUnset: true)
                    didMutate = true
                }
            }
        }

        if didMutate {
            dissolveFunctionallyEmptySuperpinGroups()
            groupManager.objectWillChange.send()
        }
    }

    func syncSuperPinnedOrder(from sourceGroup: TabGroup, orderedWindowIDs: [CGWindowID]) {
        guard supportsSuperpin(
            counterGroupIDs: sourceGroup.maximizedGroupCounterIDs,
            currentGroupID: sourceGroup.id
        ) else { return }

        let sourceSuperPinnedOrder = sourceGroup.windows
            .filter { !$0.isSeparator && $0.isSuperPinned }
            .map(\.id)
        guard sourceSuperPinnedOrder.count >= 2 else { return }

        let candidateOrder = orderedWindowIDs.filter { sourceSuperPinnedOrder.contains($0) }
        let desiredOrder = candidateOrder.isEmpty ? sourceSuperPinnedOrder : candidateOrder
        let desiredRank = Dictionary(uniqueKeysWithValues: desiredOrder.enumerated().map { ($0.element, $0.offset) })
        let groupsByID = Dictionary(uniqueKeysWithValues: groupManager.groups.map { ($0.id, $0) })

        var didMutate = false
        for targetGroupID in sourceGroup.maximizedGroupCounterIDs where targetGroupID != sourceGroup.id {
            guard let targetGroup = groupsByID[targetGroupID] else { continue }
            let targetSuperPinnedOrder = targetGroup.windows
                .filter { !$0.isSeparator && $0.isSuperPinned }
                .map(\.id)
            guard targetSuperPinnedOrder.count >= 2 else { continue }

            let existingRank = Dictionary(
                uniqueKeysWithValues: targetSuperPinnedOrder.enumerated().map { ($0.element, $0.offset) }
            )
            let reordered = targetSuperPinnedOrder.sorted { lhs, rhs in
                let lhsDesired = desiredRank[lhs] ?? Int.max
                let rhsDesired = desiredRank[rhs] ?? Int.max
                if lhsDesired != rhsDesired { return lhsDesired < rhsDesired }
                return (existingRank[lhs] ?? Int.max) < (existingRank[rhs] ?? Int.max)
            }
            guard reordered != targetSuperPinnedOrder else { continue }

            for (index, windowID) in reordered.enumerated() {
                targetGroup.movePinnedTab(withID: windowID, toPinnedIndex: index)
            }
            didMutate = true
        }

        if didMutate {
            groupManager.objectWillChange.send()
        }
    }

    private func markSuperpinMirror(windowID: CGWindowID, in groupID: UUID) {
        superpinMirroredWindowIDsByGroupID[groupID, default: []].insert(windowID)
    }

    private func unmarkSuperpinMirror(windowID: CGWindowID, in groupID: UUID) {
        guard var mirrored = superpinMirroredWindowIDsByGroupID[groupID] else { return }
        mirrored.remove(windowID)
        if mirrored.isEmpty {
            superpinMirroredWindowIDsByGroupID.removeValue(forKey: groupID)
        } else {
            superpinMirroredWindowIDsByGroupID[groupID] = mirrored
        }
    }

    private func isSuperpinMirror(windowID: CGWindowID, in groupID: UUID) -> Bool {
        superpinMirroredWindowIDsByGroupID[groupID]?.contains(windowID) ?? false
    }

    private func removeSuperpinTracking(forWindowID windowID: CGWindowID) {
        for groupID in Array(superpinMirroredWindowIDsByGroupID.keys) {
            unmarkSuperpinMirror(windowID: windowID, in: groupID)
        }
    }

    private func removeSuperpinMirrors(windowIDs: Set<CGWindowID>, from groupID: UUID) {
        guard !windowIDs.isEmpty else { return }
        for windowID in windowIDs {
            unmarkSuperpinMirror(windowID: windowID, in: groupID)
        }
    }

    private func pruneSuperpinMirrorTracking() {
        for (groupID, mirroredWindowIDs) in superpinMirroredWindowIDsByGroupID {
            guard let group = groupManager.groups.first(where: { $0.id == groupID }) else {
                superpinMirroredWindowIDsByGroupID.removeValue(forKey: groupID)
                continue
            }
            let valid = Set(mirroredWindowIDs.filter { group.contains(windowID: $0) })
            if valid.isEmpty {
                superpinMirroredWindowIDsByGroupID.removeValue(forKey: groupID)
            } else {
                superpinMirroredWindowIDsByGroupID[groupID] = valid
            }
        }
    }

    private func normalizeSingleMembershipAfterUnlink(windowID: CGWindowID) {
        guard groupManager.membershipCount(for: windowID) == 1,
              let remainingGroup = groupManager.groups(for: windowID).first,
              let remainingWindow = remainingGroup.windows.first(where: { $0.id == windowID }) else { return }

        removeSuperpinTracking(forWindowID: windowID)

        guard !remainingWindow.isSeparator, remainingWindow.pinState == .super else { return }
        remainingGroup.setSuperPinned(
            false,
            forWindowIDs: [windowID],
            downgradeToNormalWhenUnset: false
        )
        groupManager.objectWillChange.send()
    }

    @discardableResult
    private func releaseMirroredSuperpinWindows(withIDs ids: Set<CGWindowID>, from group: TabGroup) -> Bool {
        guard !ids.isEmpty else { return false }

        let windowsToRelease = group.managedWindows.filter { ids.contains($0.id) }
        _ = groupManager.releaseWindows(withIDs: ids, from: group)
        removeSuperpinMirrors(windowIDs: ids, from: group.id)
        for window in windowsToRelease {
            stopObservingWindowIfUnused(window)
        }

        guard !groupManager.groups.contains(where: { $0.id == group.id }) else {
            if let panel = tabBarPanels[group.id], let newActive = group.activeWindow {
                panel.orderAbove(windowID: newActive.id)
            }
            return true
        }

        if let panel = tabBarPanels[group.id] {
            handleGroupDissolution(group: group, panel: panel)
        }
        return true
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
        superpinMirroredWindowIDsByGroupID.removeValue(forKey: group.id)
        lastKnownMaximizedStateByGroupID.removeValue(forKey: group.id)
        mruTracker.removeGroup(group.id)

        if cyclingGroup === group { cyclingGroup = nil }
        resyncWorkItems[group.id]?.cancel()
        resyncWorkItems.removeValue(forKey: group.id)
        for window in group.managedWindows { expectedFrames.removeValue(forKey: window.id) }

        if let lastWindow = group.managedWindows.first {
            stopObservingWindowIfUnused(lastWindow)
            if !lastWindow.isFullscreened, group.tabBarSqueezeDelta > 0,
               let lastFrame = AccessibilityHelper.getFrame(of: lastWindow.element) {
                let expandedFrame = ScreenCompensation.expandFrame(lastFrame, undoingSqueezeDelta: group.tabBarSqueezeDelta)
                AccessibilityHelper.setFrameAsync(of: lastWindow.element, to: expandedFrame)
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
        superpinMirroredWindowIDsByGroupID.removeValue(forKey: group.id)
        lastKnownMaximizedStateByGroupID.removeValue(forKey: group.id)
        mruTracker.removeGroup(group.id)

        if cyclingGroup === group { cyclingGroup = nil }
        resyncWorkItems[group.id]?.cancel()
        resyncWorkItems.removeValue(forKey: group.id)
        for window in group.managedWindows { expectedFrames.removeValue(forKey: window.id) }

        for window in group.managedWindows {
            if !window.isFullscreened, group.tabBarSqueezeDelta > 0,
               let frame = AccessibilityHelper.getFrame(of: window.element) {
                let expandedFrame = ScreenCompensation.expandFrame(frame, undoingSqueezeDelta: group.tabBarSqueezeDelta)
                AccessibilityHelper.setFrameAsync(of: window.element, to: expandedFrame)
            }
        }

        let windowsToMaybeUnobserve = group.managedWindows
        groupManager.dissolveGroup(group)
        for window in windowsToMaybeUnobserve {
            stopObservingWindowIfUnused(window)
        }
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
        superpinMirroredWindowIDsByGroupID.removeValue(forKey: group.id)
        lastKnownMaximizedStateByGroupID.removeValue(forKey: group.id)
        mruTracker.removeGroup(group.id)

        if cyclingGroup === group { cyclingGroup = nil }
        resyncWorkItems[group.id]?.cancel()
        resyncWorkItems.removeValue(forKey: group.id)

        for window in group.managedWindows {
            expectedFrames.removeValue(forKey: window.id)
            AccessibilityHelper.closeWindowAsync(window.element)
        }

        let windowsToMaybeUnobserve = group.managedWindows
        groupManager.dissolveGroup(group)
        for window in windowsToMaybeUnobserve {
            stopObservingWindowIfUnused(window)
        }
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
        guard let windowID = AccessibilityHelper.frontmostFocusedWindowID(),
              let group = ownerGroup(for: windowID),
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

        for window in windowsToMerge {
            expectedFrames.removeValue(forKey: window.id)
        }

        // Clean up source group state (like disbandGroup but without frame expansion)
        if autoCaptureGroup === source { deactivateAutoCapture() }
        if lastActiveGroupID == source.id { lastActiveGroupID = nil }
        selectedTabIDsByGroupID.removeValue(forKey: source.id)
        superpinMirroredWindowIDsByGroupID.removeValue(forKey: source.id)
        lastKnownMaximizedStateByGroupID.removeValue(forKey: source.id)
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
            AccessibilityHelper.setFrameAsync(of: window.element, to: target.frame)
            let index = insertAt.map { $0 + offset }
            _ = groupManager.addWindow(window, to: target, at: index, allowSharedMembership: true)
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
        guard let windowID = AccessibilityHelper.frontmostFocusedWindowID(),
              let group = ownerGroup(for: windowID),
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
            AccessibilityHelper.setPositionAsync(of: window.element, to: newFrame.origin)
        }
    }

    func handleBarDragEnded(group: TabGroup, panel: TabBarPanel) {
        barDraggingGroupID = nil
        barDragInitialFrame = nil

        // Sync all windows to the final position
        let allIDs = group.visibleWindows.map(\.id)
        setExpectedFrame(group.frame, for: allIDs)
        for window in group.visibleWindows {
            AccessibilityHelper.setFrameAsync(of: window.element, to: group.frame)
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
                AccessibilityHelper.setFrameAsync(of: window.element, to: adjustedFrame)
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
            AccessibilityHelper.setFrameAsync(of: window.element, to: frame)
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
                enabled: tabBarConfig.showMaximizedGroupCounters,
                showDragHandle: showHandle
            )
            let groupNameWidth = TabBarView.groupNameReservedWidth(for: group.name)
            let availableWidth = panelWidth - leadingPad - trailingPad - TabBarView.addButtonWidth - groupCounterWidth - handleWidth - groupNameWidth
            let layout = TabBarView.tabWidthLayout(
                availableWidth: availableWidth,
                tabs: group.windows,
                style: tabBarConfig.style
            )
            let superPinnedSectionWidth = TabBarView.superPinnedSectionWidth(
                tabs: group.windows,
                tabWidths: layout.widths
            )
            let mainTabs = Array(group.windows.dropFirst(group.superPinnedCount))
            let mainTabWidths = Array(layout.widths.dropFirst(group.superPinnedCount))

            // Convert mouse X to local panel coordinates
            let localX = mouseLocation.x - panel.frame.origin.x
            let tabContentStartX = leadingPad + groupCounterWidth + handleWidth + superPinnedSectionWidth + groupNameWidth
            let localTabX = localX - tabContentStartX
            let insertionInMain = TabBarView.insertionIndexForPoint(
                localTabX: localTabX,
                tabWidths: mainTabWidths,
                tabs: mainTabs
            )
            let insertionIndex = group.superPinnedCount + insertionInMain

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

        // Keep observers alive; membership may transfer between groups.
        for window in windowsToMove {
            expectedFrames.removeValue(forKey: window.id)
        }

        // Release from source group (auto-dissolves if empty)
        _ = groupManager.releaseWindows(withIDs: ids, from: sourceGroup)
        removeSuperpinMirrors(windowIDs: ids, from: sourceGroup.id)

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
            AccessibilityHelper.setFrameAsync(of: window.element, to: targetGroup.frame)
            _ = groupManager.addWindow(
                windowToInsert,
                to: targetGroup,
                at: insertionIndex + offset,
                allowSharedMembership: true
            )
        }

        // Switch target group to the first moved tab and raise it
        if let firstMoved = windowsToMove.first,
           let newIndex = targetGroup.windows.firstIndex(where: { $0.id == firstMoved.id }) {
            targetGroup.switchTo(index: newIndex)
            promoteWindowOwnership(windowID: firstMoved.id, group: targetGroup)
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
        let sharedWindowIDs = Set(releasedWindows.filter { groupManager.membershipCount(for: $0.id) > 1 }.map(\.id))
        let fullyReleasedWindows = releasedWindows.filter { !sharedWindowIDs.contains($0.id) }
        suppressAutoJoin(windowIDs: fullyReleasedWindows.map(\.id))

        for window in fullyReleasedWindows {
            expectedFrames.removeValue(forKey: window.id)

            if !window.isFullscreened, let frame = AccessibilityHelper.getFrame(of: window.element) {
                let delta = max(group.tabBarSqueezeDelta, ScreenCompensation.tabBarHeight)
                let expanded = ScreenCompensation.expandFrame(frame, undoingSqueezeDelta: delta)
                let element = window.element
                AccessibilityHelper.setSizeAsync(of: element, to: expanded.size)
                AccessibilityHelper.setPositionAsync(of: element, to: expanded.origin)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    AccessibilityHelper.setPositionAsync(of: element, to: expanded.origin)
                    AccessibilityHelper.setSizeAsync(of: element, to: expanded.size)
                }
            }
        }

        _ = groupManager.releaseWindows(withIDs: Set(releasedWindows.map(\.id)).union(separatorIDs), from: group)
        removeSuperpinMirrors(windowIDs: Set(releasedWindows.map(\.id)), from: group.id)
        for window in releasedWindows {
            stopObservingWindowIfUnused(window)
        }
        for windowID in sharedWindowIDs {
            normalizeSingleMembershipAfterUnlink(windowID: windowID)
        }

        // Raise the first released window so it becomes focused
        if let first = fullyReleasedWindows.first {
            AccessibilityHelper.raiseWindowAsync(first)
        }

        if !groupManager.groups.contains(where: { $0.id == group.id }) {
            handleGroupDissolution(group: group, panel: panel)
        } else if let newActive = group.activeWindow {
            panel.orderAbove(windowID: newActive.id)
        }
        dissolveFunctionallyEmptySuperpinGroups()
        evaluateAutoCapture()
    }

    func moveTabsToNewGroup(withIDs ids: Set<CGWindowID>, from group: TabGroup, panel: TabBarPanel) {
        let windowsToMove = group.managedWindows.filter { ids.contains($0.id) }
        guard !windowsToMove.isEmpty else { return }

        let frame = group.frame
        let squeezeDelta = group.tabBarSqueezeDelta

        for window in windowsToMove {
            expectedFrames.removeValue(forKey: window.id)
        }

        _ = groupManager.releaseWindows(withIDs: ids, from: group)
        removeSuperpinMirrors(windowIDs: ids, from: group.id)

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
        if !separatorIDs.isEmpty {
            _ = groupManager.releaseWindows(withIDs: separatorIDs, from: group)
            removeSuperpinMirrors(windowIDs: separatorIDs, from: group.id)
        }

        let windowsToClose = group.managedWindows.filter { ids.contains($0.id) }
        for window in windowsToClose {
            expectedFrames.removeValue(forKey: window.id)
            AccessibilityHelper.closeWindowAsync(window.element)
            removeWindowFromAllGroups(windowID: window.id)
        }

        dissolveFunctionallyEmptySuperpinGroups()

        guard tabBarPanels[group.id] != nil else {
            evaluateAutoCapture()
            return
        }

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

        let affectedWindowIDs = Set(
            groupManager.groups
                .flatMap { $0.managedWindows }
                .filter { $0.ownerPID == pid }
                .map(\.id)
        )

        for windowID in affectedWindowIDs {
            mruTracker.removeWindow(windowID)
            expectedFrames.removeValue(forKey: windowID)
            if let representative = groupManager.groups(for: windowID)
                .compactMap({ group in group.windows.first(where: { $0.id == windowID }) })
                .first {
                windowObserver.handleDestroyedWindow(pid: pid, elementHash: CFHash(representative.element))
            }
            removeWindowFromAllGroups(windowID: windowID)
        }
        evaluateAutoCapture()
    }
}
