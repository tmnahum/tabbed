import CoreGraphics

enum ScreenCompensation {

    static let tabBarHeight: CGFloat = 28

    struct ClampResult {
        let frame: CGRect
        /// How many pixels the window was pushed down to make room for the tab bar (0 if none).
        let squeezeDelta: CGFloat
    }

    /// Clamp a window frame so there's room for the tab bar above it.
    /// Returns the adjusted frame and the squeeze delta.
    /// Pure function — no side effects.
    static func clampResult(frame: CGRect, visibleFrame: CGRect) -> ClampResult {
        let minY = visibleFrame.origin.y + tabBarHeight
        guard frame.origin.y < minY else {
            return ClampResult(frame: frame, squeezeDelta: 0)
        }
        let delta = minY - frame.origin.y
        let adjustedHeight = max(frame.size.height - delta, tabBarHeight)
        let adjusted = CGRect(
            x: frame.origin.x,
            y: minY,
            width: frame.size.width,
            height: adjustedHeight
        )
        return ClampResult(frame: adjusted, squeezeDelta: delta)
    }

    private static let maximizeTolerance: CGFloat = 20

    /// Check if a group (accounting for its squeeze delta) fills the given visible frame.
    /// Pure function — no side effects, no screen lookups.
    static func isMaximized(
        groupFrame: CGRect,
        squeezeDelta: CGFloat,
        visibleFrame: CGRect
    ) -> Bool {
        if fillsFrame(groupFrame: groupFrame, squeezeDelta: squeezeDelta, visibleFrame: visibleFrame) {
            return true
        }
        // Squeeze delta may be 0 if session restore didn't preserve it —
        // also try with the tab bar height as the assumed delta.
        if squeezeDelta == 0 {
            return fillsFrame(groupFrame: groupFrame, squeezeDelta: tabBarHeight, visibleFrame: visibleFrame)
        }
        return false
    }

    private static func fillsFrame(
        groupFrame: CGRect,
        squeezeDelta: CGFloat,
        visibleFrame: CGRect
    ) -> Bool {
        let logicalRect = CGRect(
            x: groupFrame.origin.x,
            y: groupFrame.origin.y - squeezeDelta,
            width: groupFrame.width,
            height: groupFrame.height + squeezeDelta
        )
        return abs(logicalRect.origin.x - visibleFrame.origin.x) <= maximizeTolerance &&
               abs(logicalRect.origin.y - visibleFrame.origin.y) <= maximizeTolerance &&
               abs(logicalRect.width - visibleFrame.width) <= maximizeTolerance &&
               abs(logicalRect.height - visibleFrame.height) <= maximizeTolerance
    }

    /// Expand a frame upward by the squeeze delta (reverses a previous clamp).
    /// Used when dissolving/disbanding a group.
    static func expandFrame(_ frame: CGRect, undoingSqueezeDelta delta: CGFloat) -> CGRect {
        guard delta > 0 else { return frame }
        return CGRect(
            x: frame.origin.x,
            y: frame.origin.y - delta,
            width: frame.width,
            height: frame.height + delta
        )
    }
}
