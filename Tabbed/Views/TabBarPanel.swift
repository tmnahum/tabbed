import AppKit

class TabBarPanel: NSPanel {
    static let tabBarHeight: CGFloat = 36

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: Self.tabBarHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.level = .normal
        self.isFloatingPanel = false
        self.becomesKeyOnlyIfNeeded = true
        self.hidesOnDeactivate = false
        self.isOpaque = false
        self.backgroundColor = .clear
        self.isMovableByWindowBackground = true
        self.animationBehavior = .none

        let visualEffect = NSVisualEffectView(frame: self.contentView!.bounds)
        visualEffect.autoresizingMask = [.width, .height]
        visualEffect.material = .menu
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        // Top corners only: in AppKit's non-flipped layer coords,
        // MaxY = top edge, so these mask the top-left and top-right corners.
        visualEffect.layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        visualEffect.layer?.cornerRadius = 8
        self.contentView?.addSubview(visualEffect, positioned: .below, relativeTo: nil)
    }

    /// Position the panel above the given window frame (in AX/CG coordinates)
    func positionAbove(windowFrame: CGRect) {
        let appKitOrigin = CoordinateConverter.axToAppKit(
            point: CGPoint(
                x: windowFrame.origin.x,
                y: windowFrame.origin.y - Self.tabBarHeight
            ),
            windowHeight: Self.tabBarHeight
        )
        self.setFrame(
            NSRect(
                x: appKitOrigin.x,
                y: appKitOrigin.y,
                width: windowFrame.width,
                height: Self.tabBarHeight
            ),
            display: true
        )
    }

    /// Order this panel directly above the specified window
    func orderAbove(windowID: CGWindowID) {
        self.order(.above, relativeTo: Int(windowID))
    }

    func show(above windowFrame: CGRect, windowID: CGWindowID) {
        positionAbove(windowFrame: windowFrame)
        orderFront(nil)
        orderAbove(windowID: windowID)
    }
}
