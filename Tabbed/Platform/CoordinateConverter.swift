import AppKit

enum CoordinateConverter {
    /// Primary screen height — used for global AX↔AppKit conversion.
    /// Both coordinate systems are global, rooted at the primary screen,
    /// so this is correct regardless of which monitor the window is on.
    private static var primaryScreenHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }

    /// Convert from AX/CG coordinates (top-left origin, Y down)
    /// to AppKit coordinates (bottom-left origin, Y up)
    static func axToAppKit(point: CGPoint, windowHeight: CGFloat) -> CGPoint {
        let h = primaryScreenHeight
        guard h > 0 else { return point }
        return CGPoint(
            x: point.x,
            y: h - point.y - windowHeight
        )
    }

    /// Convert from AppKit coordinates (bottom-left origin, Y up)
    /// to AX/CG coordinates (top-left origin, Y down)
    static func appKitToAX(point: CGPoint, windowHeight: CGFloat) -> CGPoint {
        let h = primaryScreenHeight
        guard h > 0 else { return point }
        return CGPoint(
            x: point.x,
            y: h - point.y - windowHeight
        )
    }

    /// Find the screen containing the given point in AX/CG coordinates.
    static func screen(containingAXPoint axPoint: CGPoint) -> NSScreen? {
        let h = primaryScreenHeight
        guard h > 0 else { return NSScreen.screens.first }
        // Convert the AX point to AppKit to test against NSScreen frames
        let appKitPoint = CGPoint(x: axPoint.x, y: h - axPoint.y)
        return NSScreen.screens.first { $0.frame.contains(appKitPoint) }
            ?? NSScreen.screens.first
    }

    /// Get the visible frame in AX coordinates (excludes menu bar and Dock)
    /// for the screen containing the given AX point.
    static func visibleFrameInAX(at axPoint: CGPoint) -> CGRect {
        guard let screen = screen(containingAXPoint: axPoint) else { return .zero }
        return visibleFrameInAX(for: screen)
    }

    /// Get the visible frame in AX coordinates for a specific screen.
    static func visibleFrameInAX(for screen: NSScreen) -> CGRect {
        let h = primaryScreenHeight
        guard h > 0 else { return .zero }
        let visible = screen.visibleFrame
        return CGRect(
            x: visible.origin.x,
            y: h - visible.origin.y - visible.height,
            width: visible.width,
            height: visible.height
        )
    }
}
