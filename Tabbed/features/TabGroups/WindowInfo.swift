import AppKit
import ApplicationServices

enum WindowPinState: String, Codable {
    case none
    case locked
    case normal
    case `super`
}

struct WindowInfo: Identifiable, Equatable {
    let id: CGWindowID
    var element: AXUIElement
    let ownerPID: pid_t
    let bundleID: String
    var title: String
    var appName: String
    var customTabName: String?
    var icon: NSImage?
    /// CG-reported bounds; available for all windows including off-space ones
    /// where the AX element is a placeholder app element.
    var cgBounds: CGRect?
    var isFullscreened: Bool = false
    var pinState: WindowPinState = .none
    var isSeparator: Bool = false

    var isPinned: Bool {
        get { pinState != .none }
        set { pinState = newValue ? .normal : .none }
    }

    var isSuperPinned: Bool {
        pinState == .super
    }

    var isLocked: Bool {
        pinState == .locked
    }

    var isCompactPinned: Bool {
        pinState == .normal || pinState == .super
    }

    init(
        id: CGWindowID,
        element: AXUIElement,
        ownerPID: pid_t,
        bundleID: String,
        title: String,
        appName: String,
        customTabName: String? = nil,
        icon: NSImage? = nil,
        cgBounds: CGRect? = nil,
        isFullscreened: Bool = false,
        isPinned: Bool = false,
        isSeparator: Bool = false,
        pinState: WindowPinState? = nil
    ) {
        self.id = id
        self.element = element
        self.ownerPID = ownerPID
        self.bundleID = bundleID
        self.title = title
        self.appName = appName
        self.customTabName = customTabName
        self.icon = icon
        self.cgBounds = cgBounds
        self.isFullscreened = isFullscreened
        self.pinState = pinState ?? (isPinned ? .normal : .none)
        self.isSeparator = isSeparator
    }

    static func separator(withID id: CGWindowID) -> WindowInfo {
        WindowInfo(
            id: id,
            element: AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier),
            ownerPID: ProcessInfo.processInfo.processIdentifier,
            bundleID: "dev.tabbed.separator",
            title: "Separator",
            appName: "Separator",
            icon: nil,
            isSeparator: true
        )
    }

    var displayedCustomTabName: String? {
        guard let customTabName else { return nil }
        let trimmed = customTabName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var displayTitle: String {
        if isSeparator { return "" }
        return displayedCustomTabName ?? (title.isEmpty ? appName : title)
    }

    static func == (lhs: WindowInfo, rhs: WindowInfo) -> Bool {
        lhs.id == rhs.id &&
            lhs.isFullscreened == rhs.isFullscreened &&
            lhs.pinState == rhs.pinState &&
            lhs.isSeparator == rhs.isSeparator
    }
}
