import AppKit

/// Identifies a switchable entity in the global MRU list.
enum MRUEntry: Equatable {
    case group(UUID)        // a tab group, tracked by its stable UUID
    case window(CGWindowID) // a standalone (ungrouped) window
}

// MARK: - Global Switcher

extension AppDelegate {

    func recordGlobalActivation(_ entry: MRUEntry) {
        globalMRU.removeAll { $0 == entry }
        globalMRU.insert(entry, at: 0)
    }

    func handleGlobalSwitcher(reverse: Bool) {
        Logger.log("[GS] handleGlobalSwitcher ENTERED reverse=\(reverse)")
        if switcherController.isActive {
            if reverse { switcherController.retreat() } else { switcherController.advance() }
            return
        }

        let zWindows = WindowDiscovery.allSpaces()
        let groupFrames = groupManager.groups.map { $0.frame }

        var items: [SwitcherItem] = []
        var seenGroupIDs: Set<UUID> = []
        var seenWindowIDs: Set<CGWindowID> = []

        // Phase 1: place items in MRU order
        for entry in globalMRU {
            switch entry {
            case .group(let groupID):
                guard let group = groupManager.groups.first(where: { $0.id == groupID }),
                      seenGroupIDs.insert(groupID).inserted else { continue }
                items.append(.group(group))
                seenWindowIDs.formUnion(group.windows.map(\.id))
            case .window(let windowID):
                guard let window = zWindows.first(where: { $0.id == windowID }),
                      !seenWindowIDs.contains(windowID),
                      groupManager.group(for: windowID) == nil else { continue }
                items.append(.singleWindow(window))
                seenWindowIDs.insert(windowID)
            }
        }

        // Phase 2: remaining windows/groups in z-order
        for window in zWindows where !seenWindowIDs.contains(window.id) {
            if let group = groupManager.group(for: window.id) {
                if seenGroupIDs.insert(group.id).inserted {
                    items.append(.group(group))
                    seenWindowIDs.formUnion(group.windows.map(\.id))
                }
            } else {
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
                seenWindowIDs.insert(window.id)
            }
        }

        // Phase 3: groups with no visible members (e.g., on another space)
        for group in groupManager.groups where !seenGroupIDs.contains(group.id) {
            items.append(.group(group))
        }

        Logger.log("[GS] groups=\(groupManager.groups.count) mru=\(globalMRU.count) items=\(items.map { $0.isGroup ? "G" : "W" }.joined())")

        guard !items.isEmpty else { return }

        switcherController.onCommit = { [weak self] item, subIndex in
            self?.commitSwitcherSelection(item, subIndex: subIndex)
        }
        switcherController.onDismiss = nil

        switcherController.show(
            items: items,
            style: switcherConfig.globalStyle,
            scope: .global
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
            // Always set cooldown after any switcher commit — suppresses
            // async focus notifications from our own raiseWindow/activate.
            cycleEndTime = Date()
            return
        }
        guard let group = cyclingGroup, group.isCycling else { return }

        group.endCycle()
        cyclingGroup = nil
        cycleEndTime = Date()
    }

    func handleSwitcherArrow(_ direction: SwitcherController.ArrowDirection) {
        guard switcherController.isActive else { return }
        switcherController.handleArrowKey(direction)
    }

    func commitSwitcherSelection(_ item: SwitcherItem, subIndex: Int?) {
        switch item {
        case .singleWindow(let window):
            recordGlobalActivation(.window(window.id))
            focusWindow(window)
        case .group(let group):
            if let subIndex {
                group.switchTo(index: subIndex)
            }
            guard let activeWindow = group.activeWindow else { return }
            recordGlobalActivation(.group(group.id))
            lastActiveGroupID = group.id
            group.recordFocus(windowID: activeWindow.id)
            focusWindow(activeWindow)
            if !activeWindow.isFullscreened, let panel = tabBarPanels[group.id] {
                panel.orderAbove(windowID: activeWindow.id)
            }
        }
    }
}
