import AppKit

struct KeyBinding: Codable, Equatable {
    var modifiers: UInt    // NSEvent.ModifierFlags.rawValue (device-independent)
    var keyCode: UInt16    // hardware scan code

    func matches(_ event: NSEvent) -> Bool {
        guard !isUnbound else { return false }
        let eventMods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return eventMods.rawValue == modifiers && event.keyCode == keyCode
    }

    /// Whether this binding is unset (cleared by conflict resolution).
    var isUnbound: Bool { modifiers == 0 && keyCode == 0 }

    var displayString: String {
        if isUnbound { return "None" }
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        var parts: [String] = []
        if flags.contains(.control) { parts.append("⌃") }
        if flags.contains(.option) { parts.append("⌥") }
        if flags.contains(.shift) { parts.append("⇧") }
        if flags.contains(.command) { parts.append("⌘") }
        parts.append(keyName)
        return parts.joined()
    }

    private var keyName: String {
        switch keyCode {
        case 48: return "⇥"     // Tab
        case 36: return "↩"     // Return
        case 51: return "⌫"     // Delete
        case 53: return "⎋"     // Escape
        case 49: return "Space"
        default:
            // Use key code to character mapping for printable keys
            if let char = KeyBinding.keyCodeToName[keyCode] {
                return char
            }
            return "Key\(keyCode)"
        }
    }

    // MARK: - Key Code Constants

    static let keyCodeT: UInt16 = 17
    static let keyCodeW: UInt16 = 13
    static let keyCodeTab: UInt16 = 48

    static let keyCode1: UInt16 = 18
    static let keyCode2: UInt16 = 19
    static let keyCode3: UInt16 = 20
    static let keyCode4: UInt16 = 21
    static let keyCode5: UInt16 = 23
    static let keyCode6: UInt16 = 22
    static let keyCode7: UInt16 = 26
    static let keyCode8: UInt16 = 28
    static let keyCode9: UInt16 = 25

    // MARK: - Hyper Key

    static let hyperModifiers: UInt = NSEvent.ModifierFlags(
        [.command, .control, .option, .shift]
    ).intersection(.deviceIndependentFlagsMask).rawValue

    // MARK: - Default Bindings

    static let defaultNewTab = KeyBinding(modifiers: hyperModifiers, keyCode: keyCodeT)
    static let defaultReleaseTab = KeyBinding(modifiers: hyperModifiers, keyCode: keyCodeW)
    static let defaultCycleTab = KeyBinding(modifiers: hyperModifiers, keyCode: keyCodeTab)

    static func defaultSwitchToTab(_ number: Int) -> KeyBinding {
        let codes: [UInt16] = [keyCode1, keyCode2, keyCode3, keyCode4, keyCode5,
                               keyCode6, keyCode7, keyCode8, keyCode9]
        guard number >= 1, number <= 9 else { fatalError("Tab number must be 1-9") }
        return KeyBinding(modifiers: hyperModifiers, keyCode: codes[number - 1])
    }

    // MARK: - Key Code to Name Mapping

    private static let keyCodeToName: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
        8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
        23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
        30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L",
        38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
        45: "N", 46: "M", 47: ".",
    ]
}
