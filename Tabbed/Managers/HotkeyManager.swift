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
        if config.newTab.matches(event) {
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
