import AppKit

// MARK: - Global Switcher

extension AppDelegate {

    func recordGlobalActivation(pid: pid_t) {
        globalAppMRU.removeAll { $0 == pid }
        globalAppMRU.insert(pid, at: 0)
    }

    func handleGlobalSwitcher() {
        Logger.log("[GS] handleGlobalSwitcher ENTERED")
        if switcherController.isActive {
            switcherController.advance()
            return
        }

        let zWindows = WindowDiscovery.allSpaces()

        let sortedWindows: [WindowInfo]
        if globalAppMRU.isEmpty {
            sortedWindows = zWindows
        } else {
            var placed = Set<CGWindowID>()
            var result: [WindowInfo] = []

            for pid in globalAppMRU {
                if let window = zWindows.first(where: { $0.ownerPID == pid && !placed.contains($0.id) }) {
                    result.append(window)
                    placed.insert(window.id)
                }
            }

            for window in zWindows where !placed.contains(window.id) {
                result.append(window)
            }

            sortedWindows = result
        }

        let groupFrames = groupManager.groups.map { $0.frame }

        var items: [SwitcherItem] = []
        var seenGroupIDs: Set<UUID> = []

        Logger.log("[GS] groups=\(groupManager.groups.count) windows=\(sortedWindows.count)")
        for window in sortedWindows {
            if let group = groupManager.group(for: window.id) {
                if seenGroupIDs.insert(group.id).inserted {
                    items.append(.group(group))
                }
                continue
            }

            if let frame = window.cgBounds {
                let matchesGroupFrame = groupFrames.contains { gf in
                    abs(frame.origin.x - gf.origin.x) < 2 &&
                    abs(frame.origin.y - gf.origin.y) < 2 &&
                    abs(frame.width - gf.width) < 2 &&
                    abs(frame.height - gf.height) < 2
                }
                if matchesGroupFrame { continue }
            }

            items.append(.singleWindow(window))
        }

        for group in groupManager.groups where !seenGroupIDs.contains(group.id) {
            items.append(.group(group))
        }

        if case .singleWindow(let w) = items.first, groupManager.groups.count > 0 {
            Logger.log("[GS] WARNING: frontmost window \(w.id) is singleWindow but groups exist — possible stale ID")
        }
        Logger.log("[GS] items=\(items.map { $0.isGroup ? "G" : "W" }.joined())")

        guard !items.isEmpty else { return }

        switcherController.onCommit = { [weak self] item in
            self?.commitSwitcherSelection(item)
        }
        switcherController.onDismiss = nil

        switcherController.show(
            items: items,
            style: switcherConfig.style,
            scope: .global
        )
        switcherController.advance()
        hotkeyManager?.startModifierWatch(modifiers: hotkeyManager?.config.globalSwitcher.modifiers ?? 0)
    }

    func handleModifierReleased() {
        hotkeyManager?.stopModifierWatch()
        if switcherController.isActive {
            switcherController.commit()

            if let group = cyclingGroup {
                group.endCycle()
                cyclingGroup = nil
                cycleEndTime = Date()
            }
            return
        }
        guard let group = cyclingGroup, group.isCycling else { return }

        group.endCycle()
        cyclingGroup = nil
        cycleEndTime = Date()
    }

    func commitSwitcherSelection(_ item: SwitcherItem) {
        switch item {
        case .singleWindow(let window):
            recordGlobalActivation(pid: window.ownerPID)
            focusWindow(window)
        case .group(let group):
            guard let activeWindow = group.activeWindow else { return }
            recordGlobalActivation(pid: activeWindow.ownerPID)
            lastActiveGroupID = group.id
            focusWindow(activeWindow)
            if let panel = tabBarPanels[group.id] {
                panel.orderAbove(windowID: activeWindow.id)
            }
        }
    }
}
