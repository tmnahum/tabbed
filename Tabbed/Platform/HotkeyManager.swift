import AppKit

// MARK: - CGEvent Tap Callback (file-scope, required by CGEventTapCallBack)

private func hotkeyEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()

    // Re-enable tap if macOS disabled it (timeout or user input)
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = manager.eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        return Unmanaged.passUnretained(event)
    }

    guard let nsEvent = NSEvent(cgEvent: event) else {
        return Unmanaged.passUnretained(event)
    }

    switch type {
    case .keyDown:
        if manager.handleKeyDown(nsEvent) {
            return nil // suppress
        }
    case .flagsChanged:
        manager.handleFlagsChanged(nsEvent)
    default:
        break
    }

    return Unmanaged.passUnretained(event)
}

// MARK: - HotkeyManager

class HotkeyManager {
    private(set) var config: ShortcutConfig
    fileprivate var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var retainedSelf: Unmanaged<HotkeyManager>?

    var onNewTab: (() -> Void)?
    var onReleaseTab: (() -> Void)?
    var onGroupAllInSpace: (() -> Void)?
    var onCycleTab: ((_ reverse: Bool) -> Void)?
    var onSwitchToTab: ((Int) -> Void)?
    var onGlobalSwitcher: ((_ reverse: Bool) -> Void)?
    /// Fires when modifier keys are released (used by both within-group and global switcher).
    var onModifierReleased: (() -> Void)?
    /// Fires when the escape key is pressed. Returns true if handled (event should be consumed).
    var onEscapePressed: (() -> Bool)?
    var onArrowLeft: (() -> Void)?
    var onArrowRight: (() -> Void)?
    var onArrowUp: (() -> Void)?
    var onArrowDown: (() -> Void)?

    init(config: ShortcutConfig) {
        self.config = config
    }

    deinit {
        stop()
    }

    func start() {
        guard eventTap == nil else { return }

        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        retainedSelf = Unmanaged.passRetained(self)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: hotkeyEventTapCallback,
            userInfo: retainedSelf!.toOpaque()
        ) else {
            Logger.log("[HK] CGEvent tap creation failed — accessibility permissions not granted?")
            retainedSelf?.release()
            retainedSelf = nil
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private var modifierPollTimer: Timer?

    func stop() {
        stopModifierWatch()
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
                runLoopSource = nil
            }
            CFMachPortInvalidate(tap)
            eventTap = nil
        }
        if let retained = retainedSelf {
            retained.release()
            retainedSelf = nil
        }
    }

    /// Start polling NSEvent.modifierFlags to detect modifier release.
    /// This is a reliable fallback when flagsChanged events aren't delivered
    /// (e.g. Karabiner Hyper key setups, certain event routing quirks).
    func startModifierWatch(modifiers: UInt) {
        modifierPollTimer?.invalidate()
        let requiredMods = modifiers
        modifierPollTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            let currentMods = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue
            if (currentMods & requiredMods) != requiredMods {
                timer.invalidate()
                self.modifierPollTimer = nil
                self.onModifierReleased?()
            }
        }
    }

    func stopModifierWatch() {
        modifierPollTimer?.invalidate()
        modifierPollTimer = nil
    }

    func updateConfig(_ newConfig: ShortcutConfig) {
        config = newConfig
    }

    func handleFlagsChanged(_ event: NSEvent) {
        let currentMods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue
        // Check if either switcher's required modifiers have been released.
        let cycleMods = config.cycleTab.modifiers
        let globalMods = config.globalSwitcher.modifiers
        let anyRequired = cycleMods | globalMods
        if (currentMods & anyRequired) != anyRequired {
            stopModifierWatch() // Prevent double-fire from poll timer
            onModifierReleased?()
        }
    }

    @discardableResult
    func handleKeyDown(_ event: NSEvent) -> Bool {
        // Escape — let the handler decide whether to consume
        if event.keyCode == 53 {
            if onEscapePressed?() == true {
                return true
            }
        }

        // Arrow keys for switcher navigation
        if event.keyCode == 123 { onArrowLeft?() }
        if event.keyCode == 124 { onArrowRight?() }
        if event.keyCode == 126 { onArrowUp?() }
        if event.keyCode == 125 { onArrowDown?() }

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
        if config.groupAllInSpace.matches(event) {
            onGroupAllInSpace?()
            return true
        }
        if config.cycleTab.matches(event) {
            if !event.isARepeat { onCycleTab?(false) }
            return true  // suppress even repeats
        }
        if config.cycleTab.matchesWithExtraShift(event) {
            if !event.isARepeat { onCycleTab?(true) }
            return true
        }
        if config.globalSwitcher.matches(event) {
            if !event.isARepeat { onGlobalSwitcher?(false) }
            return true  // suppress even repeats
        }
        if config.globalSwitcher.matchesWithExtraShift(event) {
            if !event.isARepeat { onGlobalSwitcher?(true) }
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
