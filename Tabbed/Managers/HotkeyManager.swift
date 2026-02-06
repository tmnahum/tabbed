import AppKit

class HotkeyManager {
    private(set) var config: ShortcutConfig
    private var globalMonitor: Any?
    private var localMonitor: Any?

    var onNewTab: (() -> Void)?
    var onReleaseTab: (() -> Void)?
    var onCycleTab: (() -> Void)?
    var onSwitchToTab: ((Int) -> Void)?
    var onCycleModifierReleased: (() -> Void)?

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
        let requiredMods = config.cycleTab.modifiers
        if (currentMods & requiredMods) != requiredMods {
            onCycleModifierReleased?()
        }
    }

    @discardableResult
    private func handleKeyDown(_ event: NSEvent) -> Bool {
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
        for (i, binding) in config.switchToTab.enumerated() {
            if binding.matches(event) {
                onSwitchToTab?(i)
                return true
            }
        }
        return false
    }
}
