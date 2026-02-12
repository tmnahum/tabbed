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

// MARK: - System Shortcut Overrides

/// Manages disabling/restoring macOS system shortcuts that conflict with user bindings.
/// Uses com.apple.symbolichotkeys to disable WindowServer-level shortcuts that
/// CGEvent taps cannot intercept (e.g., Cmd+` "Move focus to next window").
private enum SystemShortcutOverride {
    /// Symbolic hotkey IDs and the (keyCode, cmdModifiers) they correspond to.
    /// ID 27 = "Move focus to next window" = Cmd+` (keyCode 50, Cmd)
    /// Note: Cmd+Tab is handled by the Dock, not symbolic hotkeys — the CGEvent tap alone suppresses it.
    private static let overrides: [(id: Int, keyCode: UInt16, ascii: Int, modifierMask: Int)] = [
        (27, KeyBinding.keyCodeBacktick, 96, 1048576),  // Cmd+`
    ]

    /// IDs we've disabled during this session.
    private static var disabledIDs: Set<Int> = []

    static func syncWithConfig(_ config: ShortcutConfig) {
        let bindings = [config.cycleTab, config.globalSwitcher]
        for entry in overrides {
            let needsDisable = bindings.contains { binding in
                !binding.isUnbound && binding.keyCode == entry.keyCode &&
                // Binding uses Cmd (possibly with other mods) and matches this system shortcut
                (binding.modifiers & UInt(entry.modifierMask)) == UInt(entry.modifierMask)
            }
            if needsDisable {
                disable(id: entry.id, ascii: entry.ascii, keyCode: entry.keyCode, modifierMask: entry.modifierMask)
            } else {
                restore(id: entry.id, ascii: entry.ascii, keyCode: entry.keyCode, modifierMask: entry.modifierMask)
            }
        }
    }

    static func restoreAll() {
        for entry in overrides where disabledIDs.contains(entry.id) {
            restore(id: entry.id, ascii: entry.ascii, keyCode: entry.keyCode, modifierMask: entry.modifierMask)
        }
    }

    private static func disable(id: Int, ascii: Int, keyCode: UInt16, modifierMask: Int) {
        guard !disabledIDs.contains(id) else { return }
        disabledIDs.insert(id)
        writeSymbolicHotKey(id: id, enabled: false, ascii: ascii, keyCode: keyCode, modifierMask: modifierMask)
        Logger.log("[HK] Disabled system shortcut ID \(id)")
    }

    private static func restore(id: Int, ascii: Int, keyCode: UInt16, modifierMask: Int) {
        guard disabledIDs.remove(id) != nil else { return }
        writeSymbolicHotKey(id: id, enabled: true, ascii: ascii, keyCode: keyCode, modifierMask: modifierMask)
        Logger.log("[HK] Restored system shortcut ID \(id)")
    }

    private static func writeSymbolicHotKey(id: Int, enabled: Bool, ascii: Int, keyCode: UInt16, modifierMask: Int) {
        let plist: [String: Any] = [
            "enabled": enabled,
            "value": [
                "parameters": [ascii, Int(keyCode), modifierMask],
                "type": "standard"
            ] as [String: Any]
        ]
        // Read current hotkeys, update the specific key, write back
        var hotkeys = UserDefaults(suiteName: "com.apple.symbolichotkeys")?
            .dictionary(forKey: "AppleSymbolicHotKeys") as? [String: Any] ?? [:]
        hotkeys[String(id)] = plist
        UserDefaults(suiteName: "com.apple.symbolichotkeys")?
            .set(hotkeys, forKey: "AppleSymbolicHotKeys")

        // Apply immediately via the private SystemAdministration framework
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings")
        task.arguments = ["-u"]
        try? task.run()
    }
}

// MARK: - HotkeyManager

class HotkeyManager {
    private(set) var config: ShortcutConfig
    fileprivate var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var retainedSelf: Unmanaged<HotkeyManager>?

    var onNewTab: (() -> Void)?
    var onReleaseTab: (() -> Void)?
    var onCloseTab: (() -> Void)?
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
            place: .tailAppendEventTap,
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
        SystemShortcutOverride.syncWithConfig(config)
    }

    private var modifierPollTimer: Timer?
    private var activeModifierWatchMask: UInt?

    func stop() {
        SystemShortcutOverride.restoreAll()
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
        activeModifierWatchMask = modifiers == 0 ? nil : modifiers
        guard let requiredMods = activeModifierWatchMask else { return }
        modifierPollTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            let currentMods = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue
                & KeyBinding.shortcutModifiersMask
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
        activeModifierWatchMask = nil
    }

    func updateConfig(_ newConfig: ShortcutConfig) {
        config = newConfig
        SystemShortcutOverride.syncWithConfig(config)
    }

    func handleFlagsChanged(_ event: NSEvent) {
        guard let requiredMods = activeModifierWatchMask else { return }
        let currentMods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue
            & KeyBinding.shortcutModifiersMask
        if (currentMods & requiredMods) != requiredMods {
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

        let rawMods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue
        let mods = rawMods & KeyBinding.shortcutModifiersMask
        let hyper: UInt = 0x1E0000
        if (mods & hyper) == hyper {
            Logger.log("[HK] hyper keyDown: keyCode=\(event.keyCode) rawMods=0x\(String(rawMods, radix: 16)) mods=0x\(String(mods, radix: 16)) | newTab binding: keyCode=\(config.newTab.keyCode) mods=0x\(String(config.newTab.modifiers, radix: 16)) unbound=\(config.newTab.isUnbound)")
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
        if config.closeTab.matches(event) {
            onCloseTab?()
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
