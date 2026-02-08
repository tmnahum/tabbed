import AppKit
import SwiftUI

class TabBarPanel: NSPanel {
    static let tabBarHeight: CGFloat = ScreenCompensation.tabBarHeight

    private var visualEffectView: NSVisualEffectView!

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
        self.isMovableByWindowBackground = false
        self.animationBehavior = .none
        self.collectionBehavior = [.managed, .ignoresCycle, .fullScreenDisallowsTiling]

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
        self.visualEffectView = visualEffect
    }

    func setContent(
        group: TabGroup,
        tabBarConfig: TabBarConfig,
        onSwitchTab: @escaping (Int) -> Void,
        onReleaseTab: @escaping (Int) -> Void,
        onCloseTab: @escaping (Int) -> Void,
        onAddWindow: @escaping () -> Void,
        onReleaseTabs: @escaping (Set<CGWindowID>) -> Void,
        onMoveToNewGroup: @escaping (Set<CGWindowID>) -> Void,
        onCloseTabs: @escaping (Set<CGWindowID>) -> Void,
        onCrossPanelDrop: @escaping (Set<CGWindowID>, UUID, Int) -> Void,
        onDragOverPanels: @escaping (NSPoint) -> CrossPanelDropTarget?,
        onDragEnded: @escaping () -> Void
    ) {
        let tabBarView = TabBarView(
            group: group,
            tabBarConfig: tabBarConfig,
            onSwitchTab: onSwitchTab,
            onReleaseTab: onReleaseTab,
            onCloseTab: onCloseTab,
            onAddWindow: onAddWindow,
            onReleaseTabs: onReleaseTabs,
            onMoveToNewGroup: onMoveToNewGroup,
            onCloseTabs: onCloseTabs,
            onCrossPanelDrop: onCrossPanelDrop,
            onDragOverPanels: onDragOverPanels,
            onDragEnded: onDragEnded
        )
        // Remove previous hosting view if setContent is called again
        visualEffectView.subviews.forEach { $0.removeFromSuperview() }

        let hostingView = NSHostingView(rootView: tabBarView)
        hostingView.frame = visualEffectView.bounds
        hostingView.autoresizingMask = [.width, .height]
        // Make hosting view transparent so NSVisualEffectView vibrancy shows through
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear
        visualEffectView.addSubview(hostingView)
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
