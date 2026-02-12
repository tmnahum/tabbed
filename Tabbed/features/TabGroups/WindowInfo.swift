import AppKit
import ApplicationServices

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
    var isPinned: Bool = false

    var displayedCustomTabName: String? {
        guard let customTabName else { return nil }
        let trimmed = customTabName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var displayTitle: String {
        displayedCustomTabName ?? (title.isEmpty ? appName : title)
    }

    static func == (lhs: WindowInfo, rhs: WindowInfo) -> Bool {
        lhs.id == rhs.id && lhs.isFullscreened == rhs.isFullscreened && lhs.isPinned == rhs.isPinned
    }
}
