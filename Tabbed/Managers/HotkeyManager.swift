import AppKit

class HotkeyManager {
    private(set) var config: ShortcutConfig
    private var globalMonitor: Any?
    private var localMonitor: Any?

    var onNewTab: (() -> Void)?
    var onReleaseTab: (() -> Void)?
    var onCycleTab: (() -> Void)?
    var onSwitchToTab: ((Int) -> Void)?
    var onGlobalSwitcher: (() -> Void)?
    /// Fires when modifier keys are released (used by both within-group and global switcher).
    var onModifierReleased: (() -> Void)?
    /// Fires when the escape key is pressed. Returns true if handled (event should be consumed).
    var onEscapePressed: (() -> Bool)?
    var onSwitcherAdvance: (() -> Void)?
    var onSwitcherRetreat: (() -> Void)?

    init(config: ShortcutConfig) {
        self.config = config
    }

    func start() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            switch event.type {
            case .keyDown:
                self?.handleKeyDown(event)
            case .flagsChanged:
                self?.handleFlagsChanged(event)
            default:
                break
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            switch event.type {
            case .keyDown:
                if self?.handleKeyDown(event) == true {
                    return nil
                }
            case .flagsChanged:
                self?.handleFlagsChanged(event)
            default:
                break
            }
            return event
        }
    }

    func stop() {
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
    }

    func updateConfig(_ newConfig: ShortcutConfig) {
        config = newConfig
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let currentMods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue
        // Check if either switcher's required modifiers have been released.
        let cycleMods = config.cycleTab.modifiers
        let globalMods = config.globalSwitcher.modifiers
        let anyRequired = cycleMods | globalMods
        if (currentMods & anyRequired) != anyRequired {
            onModifierReleased?()
        }
    }

    @discardableResult
    private func handleKeyDown(_ event: NSEvent) -> Bool {
        // Escape — let the handler decide whether to consume
        if event.keyCode == 53 {
            if onEscapePressed?() == true {
                return true
            }
        }

        // Arrow keys for switcher navigation
        if event.keyCode == 123 || event.keyCode == 126 { // Left or Up arrow
            onSwitcherRetreat?()
        }
        if event.keyCode == 124 || event.keyCode == 125 { // Right or Down arrow
            onSwitcherAdvance?()
        }

        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue
        let hyper: UInt = 0x1E0000
        if (mods & hyper) == hyper {
            Logger.log("[HK] hyper keyDown: keyCode=\(event.keyCode) mods=0x\(String(mods, radix: 16)) | newTab binding: keyCode=\(config.newTab.keyCode) mods=0x\(String(config.newTab.modifiers, radix: 16)) unbound=\(config.newTab.isUnbound)")
        }
        if config.newTab.matches(event) {
            Logger.log("[HK] newTab MATCHED — calling handler")
            onNewTab?()
            return true
        }
        if config.releaseTab.matches(event) {
            onReleaseTab?()
            return true
        }
        if config.cycleTab.matches(event), !event.isARepeat {
            onCycleTab?()
            return true
        }
        if config.globalSwitcher.matches(event), !event.isARepeat {
            onGlobalSwitcher?()
            return true
        }
        for (i, binding) in config.switchToTab.enumerated() {
            if binding.matches(event) {
                onSwitchToTab?(i)
                return true
            }
        }
        return false
    }
}
