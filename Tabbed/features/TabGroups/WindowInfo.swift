import AppKit
import ApplicationServices

struct WindowInfo: Identifiable, Equatable {
    let id: CGWindowID
    var element: AXUIElement
    let ownerPID: pid_t
    let bundleID: String
    var title: String
    var appName: String
    var icon: NSImage?
    /// CG-reported bounds; available for all windows including off-space ones
    /// where the AX element is a placeholder app element.
    var cgBounds: CGRect?

    static func == (lhs: WindowInfo, rhs: WindowInfo) -> Bool {
        lhs.id == rhs.id
    }
}
