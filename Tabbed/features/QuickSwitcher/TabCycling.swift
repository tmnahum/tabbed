import AppKit

// MARK: - Tab Cycling (within-group switcher)

extension AppDelegate {

    func handleHotkeyCycleTab() {
        guard let (group, _) = activeGroup() else { return }
        guard group.windows.count > 1 else { return }

        cyclingGroup = group

        if switcherController.isActive {
            switcherController.advance()
            return
        }

        let windowIDs = Set(group.windows.map(\.id))
        let mruOrder = group.focusHistory.filter { windowIDs.contains($0) }
        let orderedWindows: [WindowInfo] = mruOrder.compactMap { id in
            group.windows.first { $0.id == id }
        }
        let remaining = group.windows.filter { w in !mruOrder.contains(w.id) }
        let allWindows = orderedWindows + remaining

        let items = allWindows.map { SwitcherItem.singleWindow($0) }
        guard !items.isEmpty else { return }

        switcherController.onCommit = { [weak self] item in
            guard let self, let (group, panel) = self.activeGroup() else { return }
            if let windowID = item.windowIDs.first,
               let index = group.windows.firstIndex(where: { $0.id == windowID }) {
                self.switchTab(in: group, to: index, panel: panel)
                group.endCycle()
                self.cyclingGroup = nil
                self.cycleEndTime = Date()
            }
        }
        switcherController.onDismiss = { [weak self] in
            guard let self else { return }
            self.cyclingGroup?.endCycle()
            self.cyclingGroup = nil
        }

        if !group.isCycling {
            _ = group.nextInMRUCycle()
        }

        switcherController.show(
            items: items,
            style: switcherConfig.style,
            scope: .withinGroup
        )
        switcherController.advance()
        hotkeyManager?.startModifierWatch(modifiers: hotkeyManager?.config.cycleTab.modifiers ?? 0)
    }
}
