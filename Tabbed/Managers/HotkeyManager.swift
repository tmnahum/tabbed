import AppKit

class HotkeyManager {
    private(set) var config: ShortcutConfig
    private var globalMonitor: Any?
    private var localMonitor: Any?

    var onNewTab: (() -> Void)?
    var onReleaseTab: (() -> Void)?
    var onCycleTab: (() -> Void)?
    var onSwitchToTab: ((Int) -> Void)?

    init(config: ShortcutConfig) {
        self.config = config
    }

    func start() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyDown(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if self?.handleKeyDown(event) == true {
                return nil
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
        if config.cycleTab.matches(event) {
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
