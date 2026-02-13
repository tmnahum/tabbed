import AppKit

// MARK: - Tab Cycling (within-group switcher)

extension AppDelegate {

    func handleHotkeyCycleTab(reverse: Bool) {
        // If the global switcher is active, cycle within the selected group
        if switcherController.isActive, switcherController.scope == .global {
            if reverse {
                switcherController.cycleWithinGroupBackward()
            } else {
                switcherController.cycleWithinGroup()
            }
            return
        }

        guard let (group, _) = activeGroup() else { return }
        guard group.managedWindowCount > 1 else { return }

        cyclingGroup = group

        if switcherController.isActive {
            if reverse { switcherController.retreat() } else { switcherController.advance() }
            return
        }

        let windowIDs = Set(group.managedWindows.map(\.id))
        let mruOrder = group.focusHistory.filter { windowIDs.contains($0) }
        let orderedWindows: [WindowInfo] = mruOrder.compactMap { id in
            group.managedWindows.first { $0.id == id }
        }
        let remaining = group.managedWindows.filter { w in !mruOrder.contains(w.id) }
        let allWindows = orderedWindows + remaining

        let items = allWindows.map { SwitcherItem.singleWindow($0) }
        guard !items.isEmpty else { return }

        switcherController.onCommit = { [weak self] item, _ in
            guard let self, let (group, panel) = self.activeGroup() else { return }
            if let windowID = item.windowIDs.first,
               let index = group.windows.firstIndex(where: { $0.id == windowID }) {
                self.beginCommitEchoSuppression(targetWindowID: windowID)
                self.switchTab(in: group, to: index, panel: panel)
                group.endCycle(landedWindowID: windowID)
                self.cyclingGroup = nil
            }
        }
        switcherController.onDismiss = { [weak self] in
            guard let self else { return }
            self.cyclingGroup?.endCycle()
            self.cyclingGroup = nil
        }

        if !group.isCycling {
            group.beginCycle()
        }

        switcherController.show(
            items: items,
            style: switcherConfig.tabCycleStyle,
            scope: .withinGroup
        )
        if reverse { switcherController.retreat() } else { switcherController.advance() }
        hotkeyManager?.startModifierWatch(modifiers: hotkeyManager?.config.cycleTab.modifiers ?? 0)
    }
}
