import XCTest
@testable import Tabbed
import Carbon.HIToolbox

final class HotkeyManagerTests: XCTestCase {

    // MARK: - Helpers

    /// Create an NSEvent from a CGEvent with the given key code and modifiers.
    private func makeKeyDown(keyCode: UInt16, modifiers: UInt, isRepeat: Bool = false) -> NSEvent {
        let cgEvent = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: true)!
        var cgFlags = CGEventFlags(rawValue: 0)
        let nsFlags = NSEvent.ModifierFlags(rawValue: modifiers)
        if nsFlags.contains(.command) { cgFlags.insert(.maskCommand) }
        if nsFlags.contains(.control) { cgFlags.insert(.maskControl) }
        if nsFlags.contains(.option) { cgFlags.insert(.maskAlternate) }
        if nsFlags.contains(.shift) { cgFlags.insert(.maskShift) }
        if nsFlags.contains(.capsLock) { cgFlags.insert(.maskAlphaShift) }
        cgEvent.flags = cgFlags
        if isRepeat {
            cgEvent.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        }
        return NSEvent(cgEvent: cgEvent)!
    }

    private func makeFlagsChanged(modifiers: UInt) -> NSEvent {
        let cgEvent = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)!
        cgEvent.type = .flagsChanged
        var cgFlags = CGEventFlags(rawValue: 0)
        let nsFlags = NSEvent.ModifierFlags(rawValue: modifiers)
        if nsFlags.contains(.command) { cgFlags.insert(.maskCommand) }
        if nsFlags.contains(.control) { cgFlags.insert(.maskControl) }
        if nsFlags.contains(.option) { cgFlags.insert(.maskAlternate) }
        if nsFlags.contains(.shift) { cgFlags.insert(.maskShift) }
        cgEvent.flags = cgFlags
        return NSEvent(cgEvent: cgEvent)!
    }

    private var cmdMods: UInt {
        NSEvent.ModifierFlags.command.intersection(.deviceIndependentFlagsMask).rawValue
    }

    private var cmdShiftMods: UInt {
        NSEvent.ModifierFlags([.command, .shift]).intersection(.deviceIndependentFlagsMask).rawValue
    }

    private func unboundConfig() -> ShortcutConfig {
        ShortcutConfig(
            newTab: KeyBinding(modifiers: 0, keyCode: 0),
            releaseTab: KeyBinding(modifiers: 0, keyCode: 0),
            groupAllInSpace: KeyBinding(modifiers: 0, keyCode: 0),
            cycleTab: KeyBinding(modifiers: 0, keyCode: 0),
            switchToTab: (1...9).map { _ in KeyBinding(modifiers: 0, keyCode: 0) },
            globalSwitcher: KeyBinding(modifiers: 0, keyCode: 0)
        )
    }

    // MARK: - KeyBinding.matches Tests

    func testKeyBindingMatchesCmdTab() {
        let binding = KeyBinding(modifiers: cmdMods, keyCode: KeyBinding.keyCodeTab)
        let event = makeKeyDown(keyCode: KeyBinding.keyCodeTab, modifiers: cmdMods)
        XCTAssertTrue(binding.matches(event))
    }

    func testKeyBindingDoesNotMatchDifferentKey() {
        let binding = KeyBinding(modifiers: cmdMods, keyCode: KeyBinding.keyCodeTab)
        let event = makeKeyDown(keyCode: KeyBinding.keyCodeBacktick, modifiers: cmdMods)
        XCTAssertFalse(binding.matches(event))
    }

    func testKeyBindingDoesNotMatchDifferentModifiers() {
        let binding = KeyBinding(modifiers: cmdShiftMods, keyCode: KeyBinding.keyCodeTab)
        let event = makeKeyDown(keyCode: KeyBinding.keyCodeTab, modifiers: cmdMods)
        XCTAssertFalse(binding.matches(event))
    }

    func testUnboundBindingNeverMatches() {
        let binding = KeyBinding(modifiers: 0, keyCode: 0)
        let event = makeKeyDown(keyCode: 0, modifiers: 0)
        XCTAssertFalse(binding.matches(event))
    }

    // MARK: - matchesWithExtraShift Tests

    func testMatchesWithExtraShiftCmdTab() {
        let binding = KeyBinding(modifiers: cmdMods, keyCode: KeyBinding.keyCodeTab)
        let event = makeKeyDown(keyCode: KeyBinding.keyCodeTab, modifiers: cmdShiftMods)
        XCTAssertTrue(binding.matchesWithExtraShift(event), "Cmd+Shift+Tab should match Cmd+Tab with extra shift")
    }

    func testMatchesWithExtraShiftDoesNotMatchExactBinding() {
        let binding = KeyBinding(modifiers: cmdMods, keyCode: KeyBinding.keyCodeTab)
        let event = makeKeyDown(keyCode: KeyBinding.keyCodeTab, modifiers: cmdMods)
        XCTAssertFalse(binding.matchesWithExtraShift(event), "Cmd+Tab should NOT match as extra-shift variant")
    }

    func testMatchesWithExtraShiftIgnoredWhenBindingAlreadyHasShift() {
        let binding = KeyBinding(modifiers: cmdShiftMods, keyCode: KeyBinding.keyCodeTab)
        let event = makeKeyDown(keyCode: KeyBinding.keyCodeTab, modifiers: cmdShiftMods)
        XCTAssertFalse(binding.matchesWithExtraShift(event), "Should not match when binding already includes shift")
    }

    func testMatchesWithExtraShiftUnboundNeverMatches() {
        let binding = KeyBinding(modifiers: 0, keyCode: 0)
        let shiftMods = NSEvent.ModifierFlags.shift.intersection(.deviceIndependentFlagsMask).rawValue
        let event = makeKeyDown(keyCode: 0, modifiers: shiftMods)
        XCTAssertFalse(binding.matchesWithExtraShift(event))
    }

    // MARK: - handleKeyDown Dispatch Tests

    func testHandleKeyDownReturnsTrueForBoundGlobalSwitcher() {
        var config = unboundConfig()
        config.globalSwitcher = KeyBinding(modifiers: cmdMods, keyCode: KeyBinding.keyCodeTab)
        let manager = HotkeyManager(config: config)
        var called = false
        manager.onGlobalSwitcher = { _ in called = true }

        let event = makeKeyDown(keyCode: KeyBinding.keyCodeTab, modifiers: cmdMods)
        let result = manager.handleKeyDown(event)

        XCTAssertTrue(result, "Should return true (suppress) for bound Cmd+Tab")
        XCTAssertTrue(called, "Should fire onGlobalSwitcher")
    }

    func testHandleKeyDownReturnsFalseWhenNotBound() {
        let manager = HotkeyManager(config: unboundConfig())

        let event = makeKeyDown(keyCode: KeyBinding.keyCodeTab, modifiers: cmdMods)
        let result = manager.handleKeyDown(event)

        XCTAssertFalse(result, "Should return false (pass through) when Cmd+Tab is not bound")
    }

    func testHandleKeyDownReturnsFalseWhenBoundToDifferentKey() {
        var config = unboundConfig()
        config.globalSwitcher = KeyBinding(modifiers: cmdMods, keyCode: KeyBinding.keyCodeBacktick)
        let manager = HotkeyManager(config: config)

        let event = makeKeyDown(keyCode: KeyBinding.keyCodeTab, modifiers: cmdMods)
        let result = manager.handleKeyDown(event)

        XCTAssertFalse(result, "Should return false when globalSwitcher bound to Cmd+` and Cmd+Tab pressed")
    }

    // MARK: - Shift-to-Reverse Tests

    func testShiftReversesCycleTab() {
        var config = unboundConfig()
        config.cycleTab = KeyBinding(modifiers: cmdMods, keyCode: KeyBinding.keyCodeBacktick)
        let manager = HotkeyManager(config: config)
        var receivedReverse: Bool?
        manager.onCycleTab = { reverse in receivedReverse = reverse }

        let event = makeKeyDown(keyCode: KeyBinding.keyCodeBacktick, modifiers: cmdShiftMods)
        let result = manager.handleKeyDown(event)

        XCTAssertTrue(result, "Should suppress Cmd+Shift+` when cycleTab is Cmd+`")
        XCTAssertEqual(receivedReverse, true, "Should pass reverse=true")
    }

    func testShiftReversesGlobalSwitcher() {
        var config = unboundConfig()
        config.globalSwitcher = KeyBinding(modifiers: cmdMods, keyCode: KeyBinding.keyCodeTab)
        let manager = HotkeyManager(config: config)
        var receivedReverse: Bool?
        manager.onGlobalSwitcher = { reverse in receivedReverse = reverse }

        let event = makeKeyDown(keyCode: KeyBinding.keyCodeTab, modifiers: cmdShiftMods)
        let result = manager.handleKeyDown(event)

        XCTAssertTrue(result, "Should suppress Cmd+Shift+Tab when globalSwitcher is Cmd+Tab")
        XCTAssertEqual(receivedReverse, true, "Should pass reverse=true")
    }

    func testForwardPassesReverseFalse() {
        var config = unboundConfig()
        config.globalSwitcher = KeyBinding(modifiers: cmdMods, keyCode: KeyBinding.keyCodeTab)
        let manager = HotkeyManager(config: config)
        var receivedReverse: Bool?
        manager.onGlobalSwitcher = { reverse in receivedReverse = reverse }

        let event = makeKeyDown(keyCode: KeyBinding.keyCodeTab, modifiers: cmdMods)
        let result = manager.handleKeyDown(event)

        XCTAssertTrue(result)
        XCTAssertEqual(receivedReverse, false, "Should pass reverse=false for forward")
    }

    func testShiftReverseDoesNotApplyWhenBindingHasShift() {
        var config = unboundConfig()
        config.globalSwitcher = KeyBinding(modifiers: cmdShiftMods, keyCode: KeyBinding.keyCodeTab)
        let manager = HotkeyManager(config: config)
        var receivedReverse: Bool?
        manager.onGlobalSwitcher = { reverse in receivedReverse = reverse }

        // Cmd+Shift+Tab should match as forward (exact match), not reverse
        let event = makeKeyDown(keyCode: KeyBinding.keyCodeTab, modifiers: cmdShiftMods)
        let result = manager.handleKeyDown(event)

        XCTAssertTrue(result)
        XCTAssertEqual(receivedReverse, false, "Should be forward when Shift is part of the binding")
    }

    // MARK: - isARepeat Suppression Tests

    func testCycleTabRepeatSuppressesButDoesNotFire() {
        var config = unboundConfig()
        config.cycleTab = KeyBinding(modifiers: cmdMods, keyCode: KeyBinding.keyCodeTab)
        let manager = HotkeyManager(config: config)
        var callCount = 0
        manager.onCycleTab = { _ in callCount += 1 }

        let repeatEvent = makeKeyDown(keyCode: KeyBinding.keyCodeTab, modifiers: cmdMods, isRepeat: true)
        let result = manager.handleKeyDown(repeatEvent)

        XCTAssertTrue(result, "Should suppress repeat events")
        XCTAssertEqual(callCount, 0, "Should NOT fire onCycleTab for repeats")
    }

    func testGlobalSwitcherRepeatSuppressesButDoesNotFire() {
        var config = unboundConfig()
        config.globalSwitcher = KeyBinding(modifiers: cmdMods, keyCode: KeyBinding.keyCodeTab)
        let manager = HotkeyManager(config: config)
        var callCount = 0
        manager.onGlobalSwitcher = { _ in callCount += 1 }

        let repeatEvent = makeKeyDown(keyCode: KeyBinding.keyCodeTab, modifiers: cmdMods, isRepeat: true)
        let result = manager.handleKeyDown(repeatEvent)

        XCTAssertTrue(result, "Should suppress repeat events")
        XCTAssertEqual(callCount, 0, "Should NOT fire onGlobalSwitcher for repeats")
    }

    func testCycleTabNonRepeatFires() {
        var config = unboundConfig()
        config.cycleTab = KeyBinding(modifiers: cmdMods, keyCode: KeyBinding.keyCodeTab)
        let manager = HotkeyManager(config: config)
        var callCount = 0
        manager.onCycleTab = { _ in callCount += 1 }

        let event = makeKeyDown(keyCode: KeyBinding.keyCodeTab, modifiers: cmdMods, isRepeat: false)
        let result = manager.handleKeyDown(event)

        XCTAssertTrue(result, "Should suppress")
        XCTAssertEqual(callCount, 1, "Should fire onCycleTab for non-repeat")
    }

    func testShiftReverseRepeatSuppressesButDoesNotFire() {
        var config = unboundConfig()
        config.globalSwitcher = KeyBinding(modifiers: cmdMods, keyCode: KeyBinding.keyCodeTab)
        let manager = HotkeyManager(config: config)
        var callCount = 0
        manager.onGlobalSwitcher = { _ in callCount += 1 }

        let repeatEvent = makeKeyDown(keyCode: KeyBinding.keyCodeTab, modifiers: cmdShiftMods, isRepeat: true)
        let result = manager.handleKeyDown(repeatEvent)

        XCTAssertTrue(result, "Should suppress Cmd+Shift+Tab repeat")
        XCTAssertEqual(callCount, 0, "Should NOT fire for repeats even in reverse")
    }

    // MARK: - handleFlagsChanged Tests

    func testModifierReleasedFiresWhenModsDropped() {
        var config = unboundConfig()
        config.cycleTab = KeyBinding(modifiers: cmdMods, keyCode: KeyBinding.keyCodeTab)
        let manager = HotkeyManager(config: config)
        var released = false
        manager.onModifierReleased = { released = true }

        let event = makeFlagsChanged(modifiers: 0)
        manager.handleFlagsChanged(event)

        XCTAssertTrue(released, "Should fire onModifierReleased when Cmd is released")
    }

    func testModifierReleasedDoesNotFireWhenModsStillHeld() {
        var config = unboundConfig()
        config.cycleTab = KeyBinding(modifiers: cmdMods, keyCode: KeyBinding.keyCodeTab)
        let manager = HotkeyManager(config: config)
        var released = false
        manager.onModifierReleased = { released = true }

        let event = makeFlagsChanged(modifiers: cmdMods)
        manager.handleFlagsChanged(event)

        XCTAssertFalse(released, "Should NOT fire onModifierReleased when Cmd is still held")
    }

    // MARK: - Escape Handling

    func testEscapeConsumedWhenHandlerReturnsTrue() {
        let config = ShortcutConfig.default
        let manager = HotkeyManager(config: config)
        manager.onEscapePressed = { return true }

        let event = makeKeyDown(keyCode: 53, modifiers: 0)
        let result = manager.handleKeyDown(event)

        XCTAssertTrue(result, "Should consume escape when handler returns true")
    }

    func testEscapePassesThroughWhenHandlerReturnsFalse() {
        let manager = HotkeyManager(config: unboundConfig())
        manager.onEscapePressed = { return false }

        let event = makeKeyDown(keyCode: 53, modifiers: 0)
        let result = manager.handleKeyDown(event)

        XCTAssertFalse(result, "Should pass through when escape handler returns false")
    }

    // MARK: - switchToTab Dispatch

    func testSwitchToTabDispatchesCorrectIndex() {
        var config = unboundConfig()
        config.switchToTab[2] = KeyBinding(modifiers: cmdMods, keyCode: KeyBinding.keyCode3)

        let manager = HotkeyManager(config: config)
        var receivedIndex: Int?
        manager.onSwitchToTab = { receivedIndex = $0 }

        let event = makeKeyDown(keyCode: KeyBinding.keyCode3, modifiers: cmdMods)
        let result = manager.handleKeyDown(event)

        XCTAssertTrue(result)
        XCTAssertEqual(receivedIndex, 2, "Should dispatch index 2 for tab 3")
    }

    // MARK: - Config Update

    func testUpdateConfigChangesBindings() {
        let config = unboundConfig()
        let manager = HotkeyManager(config: config)
        var called = false
        manager.onGlobalSwitcher = { _ in called = true }

        let event = makeKeyDown(keyCode: KeyBinding.keyCodeTab, modifiers: cmdMods)
        XCTAssertFalse(manager.handleKeyDown(event))

        var newConfig = config
        newConfig.globalSwitcher = KeyBinding(modifiers: cmdMods, keyCode: KeyBinding.keyCodeTab)
        manager.updateConfig(newConfig)

        XCTAssertTrue(manager.handleKeyDown(event))
        XCTAssertTrue(called)
    }

    // MARK: - Hyper Key (Karabiner) Tests

    private var hyperMods: UInt { KeyBinding.hyperModifiers }

    /// Karabiner hyper key sends capsLock flag alongside cmd+ctrl+opt+shift.
    /// CGEvent taps see these raw flags; matches() must still work.
    private var hyperWithCapsLockMods: UInt {
        hyperMods | NSEvent.ModifierFlags.capsLock.rawValue
    }

    func testHyperKeyMatchesWithCapsLockFlag() {
        let binding = KeyBinding(modifiers: hyperMods, keyCode: KeyBinding.keyCodeT)
        let event = makeKeyDown(keyCode: KeyBinding.keyCodeT, modifiers: hyperWithCapsLockMods)
        XCTAssertTrue(binding.matches(event), "Hyper+T should match even when capsLock flag is present (Karabiner)")
    }

    func testHyperKeyHandleKeyDownWithCapsLock() {
        var config = unboundConfig()
        config.newTab = KeyBinding(modifiers: hyperMods, keyCode: KeyBinding.keyCodeT)
        let manager = HotkeyManager(config: config)
        var called = false
        manager.onNewTab = { called = true }

        let event = makeKeyDown(keyCode: KeyBinding.keyCodeT, modifiers: hyperWithCapsLockMods)
        let result = manager.handleKeyDown(event)

        XCTAssertTrue(result, "Should suppress Hyper+T with capsLock flag")
        XCTAssertTrue(called, "Should fire onNewTab")
    }

    func testHyperKeyMatchesWithoutCapsLockFlag() {
        let binding = KeyBinding(modifiers: hyperMods, keyCode: KeyBinding.keyCodeT)
        let event = makeKeyDown(keyCode: KeyBinding.keyCodeT, modifiers: hyperMods)
        XCTAssertTrue(binding.matches(event), "Hyper+T should still match without capsLock flag")
    }
}
