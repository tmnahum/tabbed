import AppKit
import SwiftUI

class TabBarPanel: NSPanel {
    static let tabBarHeight: CGFloat = ScreenCompensation.tabBarHeight
    /// Corner radius when the group is maximized (tiny rounding on all four corners).
    private static let maximizedCornerRadius: CGFloat = 2
    /// Corner radius when the group is not maximized (top corners only).
    private static let normalCornerRadius: CGFloat = 8

    private var visualEffectView: NSVisualEffectView!

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // MARK: - Bar drag & double-click callbacks

    var onBarDragged: ((_ dx: CGFloat, _ dy: CGFloat) -> Void)?
    var onBarDragEnded: (() -> Void)?
    var onBarDoubleClicked: (() -> Void)?

    weak var group: TabGroup?
    weak var tabBarConfig: TabBarConfig?

    private var barDragStartMouse: NSPoint?
    private var barDragStartPanelOrigin: NSPoint?
    /// The mouseDown location in panel-local coordinates, used for background hit test.
    private var mouseDownLocalPoint: NSPoint?
    private var isBarDragging = false
    /// Whether we've decided this gesture is a tab drag (not a bar drag).
    private var isTabDrag = false

    // MARK: - Tooltip

    private lazy var tooltipPanel = TabTooltipPanel()
    private var tooltipTimer: Timer?

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
        // Top corners only by default; positionAbove may switch to all corners when maximized.
        visualEffect.layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        visualEffect.layer?.cornerRadius = Self.normalCornerRadius
        self.contentView?.addSubview(visualEffect, positioned: .below, relativeTo: nil)
        self.visualEffectView = visualEffect
    }

    func setContent(
        group groupRef: TabGroup,
        tabBarConfig tabBarConfigRef: TabBarConfig,
        onSwitchTab: @escaping (Int) -> Void,
        onReleaseTab: @escaping (Int) -> Void,
        onCloseTab: @escaping (Int) -> Void,
        onFocusGroup: @escaping (UUID) -> Void,
        onAddWindow: @escaping () -> Void,
        onAddWindowAfterTab: @escaping (Int) -> Void,
        onAddSeparatorAfterTab: @escaping (Int) -> Void,
        onBeginTabNameEdit: @escaping () -> Void,
        onCommitTabName: @escaping (CGWindowID, String?) -> Void,
        onBeginGroupNameEdit: @escaping () -> Void,
        onCommitGroupName: @escaping (String?) -> Void,
        onReleaseTabs: @escaping (Set<CGWindowID>) -> Void,
        onMoveToNewGroup: @escaping (Set<CGWindowID>) -> Void,
        onCloseTabs: @escaping (Set<CGWindowID>) -> Void,
        onSelectionChanged: @escaping (Set<CGWindowID>) -> Void,
        onCrossPanelDrop: @escaping (Set<CGWindowID>, UUID, Int) -> Void,
        onDragOverPanels: @escaping (NSPoint) -> CrossPanelDropTarget?,
        onDragEnded: @escaping () -> Void
    ) {
        self.group = groupRef
        self.tabBarConfig = tabBarConfigRef

        let tabBarView = TabBarView(
            group: groupRef,
            tabBarConfig: tabBarConfigRef,
            onSwitchTab: onSwitchTab,
            onReleaseTab: onReleaseTab,
            onCloseTab: onCloseTab,
            onFocusGroup: onFocusGroup,
            onAddWindow: onAddWindow,
            onAddWindowAfterTab: onAddWindowAfterTab,
            onAddSeparatorAfterTab: onAddSeparatorAfterTab,
            onBeginTabNameEdit: onBeginTabNameEdit,
            onCommitTabName: onCommitTabName,
            onBeginGroupNameEdit: onBeginGroupNameEdit,
            onCommitGroupName: onCommitGroupName,
            onReleaseTabs: onReleaseTabs,
            onMoveToNewGroup: onMoveToNewGroup,
            onCloseTabs: onCloseTabs,
            onSelectionChanged: onSelectionChanged,
            onCrossPanelDrop: onCrossPanelDrop,
            onDragOverPanels: onDragOverPanels,
            onDragEnded: onDragEnded,
            onTooltipHover: { [weak self] title, tabLeadingX in
                self?.handleTooltipHover(title: title, tabLeadingX: tabLeadingX)
            }
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

    /// Position the panel above the given window frame (in AX/CG coordinates).
    /// When `isMaximized` is true, uses a tiny radius on all four corners; otherwise top corners only with larger radius.
    func positionAbove(windowFrame: CGRect, isMaximized: Bool = false) {
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
        guard let layer = visualEffectView.layer else { return }
        if isMaximized {
            layer.cornerRadius = Self.maximizedCornerRadius
            layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        } else {
            layer.cornerRadius = Self.normalCornerRadius
            layer.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        }
    }

    /// Order this panel directly above the specified window
    func orderAbove(windowID: CGWindowID) {
        self.order(.above, relativeTo: Int(windowID))
    }

    func show(above windowFrame: CGRect, windowID: CGWindowID, isMaximized: Bool = false) {
        positionAbove(windowFrame: windowFrame, isMaximized: isMaximized)
        orderFront(nil)
        orderAbove(windowID: windowID)
    }

    override func orderOut(_ sender: Any?) {
        dismissTooltip()
        super.orderOut(sender)
    }

    // MARK: - Tooltip

    private func handleTooltipHover(title: String?, tabLeadingX: CGFloat) {
        tooltipTimer?.invalidate()
        tooltipTimer = nil

        guard let title else {
            // Brief delay before dismiss so tooltip stays visible between tab transitions,
            // allowing the animate path to fire when the next tab's hover-in arrives.
            tooltipTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
                self?.tooltipPanel.dismiss()
            }
            return
        }

        let screenX = frame.origin.x + tabLeadingX

        // If tooltip is already visible, glide immediately (no delay)
        if tooltipPanel.isVisible {
            tooltipPanel.show(title: title, belowPanelFrame: frame, tabLeadingX: screenX, animate: true)
            return
        }

        tooltipTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.tooltipPanel.show(title: title, belowPanelFrame: self.frame, tabLeadingX: screenX)
        }
    }

    func dismissTooltip() {
        tooltipTimer?.invalidate()
        tooltipTimer = nil
        tooltipPanel.dismiss()
    }

    // MARK: - Mouse Event Handling

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            dismissTooltip()
            barDragStartMouse = NSEvent.mouseLocation
            barDragStartPanelOrigin = self.frame.origin
            mouseDownLocalPoint = event.locationInWindow
            isBarDragging = false
            isTabDrag = false

            // Treat double-click as a zoom/“titlebar” double-click when it lands
            // either on the bar background *or* on a tab body, but never when it
            // lands on tab controls (close/confirm, release, etc.).
            if event.clickCount == 2 {
                let localPoint = mouseDownLocalPoint ?? event.locationInWindow
                if isOnBackground(localPoint) || !isOnTabControl(localPoint) {
                    onBarDoubleClicked?()
                    return
                }
            }

            super.sendEvent(event)

        case .leftMouseDragged:
            guard let startMouse = barDragStartMouse,
                  let startOrigin = barDragStartPanelOrigin else {
                super.sendEvent(event)
                return
            }

            // Already decided this is a tab drag — let SwiftUI handle it
            if isTabDrag {
                super.sendEvent(event)
                return
            }

            let current = NSEvent.mouseLocation
            let totalDx = current.x - startMouse.x
            let totalDy = current.y - startMouse.y

            // Already bar-dragging — move panel and notify
            if isBarDragging {
                var f = self.frame
                f.origin.x = startOrigin.x + totalDx
                f.origin.y = startOrigin.y + totalDy
                self.setFrame(f, display: true)
                onBarDragged?(totalDx, totalDy)
                return
            }

            // Haven't decided yet — check distance threshold
            let dist = hypot(totalDx, totalDy)
            guard dist > 3 else {
                super.sendEvent(event)
                return
            }

            // Decide: did the mouseDown land on background or on a tab?
            // Use the original mouseDown location, not the current drag position,
            // so that 3+ px of mouse movement doesn't shift the test point off the tab.
            let localPoint = mouseDownLocalPoint ?? event.locationInWindow
            if isOnBackground(localPoint) {
                isBarDragging = true
                var f = self.frame
                f.origin.x = startOrigin.x + totalDx
                f.origin.y = startOrigin.y + totalDy
                self.setFrame(f, display: true)
                onBarDragged?(totalDx, totalDy)
            } else {
                isTabDrag = true
                super.sendEvent(event)
            }

        case .leftMouseUp:
            let wasBarDragging = isBarDragging
            if isBarDragging {
                onBarDragEnded?()
            }
            barDragStartMouse = nil
            barDragStartPanelOrigin = nil
            mouseDownLocalPoint = nil
            isBarDragging = false
            isTabDrag = false
            // Don't pass mouseUp to SwiftUI after a bar drag — otherwise
            // interactive views (like the + button) fire from the original mouseDown.
            if !wasBarDragging {
                super.sendEvent(event)
            }

        default:
            super.sendEvent(event)
        }
    }

    /// Check if a point (in window/panel coordinates) is on the bar background
    /// rather than on a tab item. Background = padding areas and spacer in compact mode.
    private func isOnBackground(_ point: NSPoint) -> Bool {
        let panelWidth = frame.width
        let panelHeight = frame.height
        let verticalPad: CGFloat = 2
        let showHandle = tabBarConfig?.showDragHandle ?? true
        // Match SwiftUI layout: leading pad is 4 with handle, 2 without
        let leadingPad: CGFloat = showHandle ? 4 : 2
        let trailingPad: CGFloat = 4
        let counterIDs = group?.maximizedGroupCounterIDs ?? []
        let currentGroupID = group?.id ?? UUID()
        let countersEnabled = tabBarConfig?.showMaximizedGroupCounters ?? true
        let groupCounterWidth = TabBarView.groupCounterReservedWidth(
            counterGroupIDs: counterIDs,
            currentGroupID: currentGroupID,
            enabled: countersEnabled
        )

        // Top/bottom padding is always background
        if point.y < verticalPad || point.y > panelHeight - verticalPad {
            return true
        }
        // Left padding + drag handle area
        let handleWidth: CGFloat = showHandle ? TabBarView.dragHandleWidth : 0
        let groupNameWidth = TabBarView.groupNameReservedWidth(for: group?.name)
        let groupCounterStartX = leadingPad
        let groupCounterEndX = groupCounterStartX + groupCounterWidth
        let dragHandleStartX = groupCounterEndX
        let groupNameStartX = dragHandleStartX + handleWidth
        if point.x < leadingPad {
            return true
        }
        if point.x >= dragHandleStartX && point.x < groupNameStartX {
            return true
        }
        // Group title zone: click/release enters inline edit, drag moves the group.
        if !isInlineTextEditing,
           Self.isGroupNameDragRegion(
               pointX: point.x,
               leadingPad: leadingPad,
               groupCounterWidth: groupCounterWidth,
               handleWidth: handleWidth,
               groupNameWidth: groupNameWidth
           ) {
            return true
        }
        // Right padding
        if point.x > panelWidth - trailingPad {
            return true
        }

        // Calculate where tab content ends
        let tabCount = group?.windows.count ?? 0
        guard tabCount > 0 else { return true }

        let availableWidth = panelWidth - leadingPad - trailingPad - TabBarView.addButtonWidth - groupCounterWidth - handleWidth - groupNameWidth
        let style = tabBarConfig?.style ?? .compact
        let layout = TabBarView.tabWidthLayout(
            availableWidth: availableWidth,
            tabs: group?.windows ?? [],
            style: style
        )
        let tabContentWidth = TabBarView.tabContentWidth(tabWidths: layout.widths, tabs: group?.windows ?? [])

        let tabContentStartX = groupNameStartX + groupNameWidth
        let tabContentEndX = tabContentStartX + tabContentWidth

        // After tab content = background (+ button still clickable via mouseDown passthrough)
        if point.x > tabContentEndX {
            return true
        }

        return false
    }

    static func isGroupNameDragRegion(
        pointX: CGFloat,
        leadingPad: CGFloat,
        groupCounterWidth: CGFloat,
        handleWidth: CGFloat,
        groupNameWidth: CGFloat
    ) -> Bool {
        guard groupNameWidth > 0 else { return false }
        let minX = leadingPad + groupCounterWidth + handleWidth
        let maxX = minX + groupNameWidth
        return pointX >= minX && pointX <= maxX
    }

    private var isInlineTextEditing: Bool {
        firstResponder is NSTextView
    }

    /// Check if a point is within the trailing control area of any tab
    /// (close/confirm, release, etc.). Used to *suppress* treating double-clicks
    /// as zoom when the user is interacting with those controls.
    private func isOnTabControl(_ point: NSPoint) -> Bool {
        // Background (including left/right padding and areas with no tabs)
        // is never considered a control region.
        if isOnBackground(point) {
            return false
        }

        guard let group,
              let tabBarConfig,
              !group.windows.isEmpty else {
            return false
        }

        let tabCount = group.windows.count
        let panelWidth = frame.width
        let panelHeight = frame.height

        let verticalPad: CGFloat = 2
        let showHandle = tabBarConfig.showDragHandle
        let leadingPad: CGFloat = showHandle ? 4 : 2
        let trailingPad: CGFloat = 4
        let handleWidth: CGFloat = showHandle ? TabBarView.dragHandleWidth : 0
        let groupCounterWidth = TabBarView.groupCounterReservedWidth(
            counterGroupIDs: group.maximizedGroupCounterIDs,
            currentGroupID: group.id,
            enabled: tabBarConfig.showMaximizedGroupCounters
        )
        let groupNameWidth = TabBarView.groupNameReservedWidth(for: group.name)
        let groupCounterStartX = leadingPad
        let groupCounterEndX = groupCounterStartX + groupCounterWidth

        if groupCounterWidth > 0 && point.x >= groupCounterStartX && point.x <= groupCounterEndX {
            return true
        }

        // Points in top/bottom padding are not on controls
        if point.y < verticalPad || point.y > panelHeight - verticalPad {
            return false
        }

        let availableWidth = panelWidth - leadingPad - trailingPad - TabBarView.addButtonWidth - groupCounterWidth - handleWidth - groupNameWidth
        let layout = TabBarView.tabWidthLayout(
            availableWidth: availableWidth,
            tabs: group.windows,
            style: tabBarConfig.style
        )

        let tabContentStartX = leadingPad + groupCounterWidth + handleWidth + groupNameWidth

        // Approximate the trailing control hit area as the last 22pt of each tab.
        // The actual close/confirm button is a 16×16 square with horizontal padding,
        // so 22pt is a safe, slightly generous bound.
        let controlInset: CGFloat = 22

        var tabOriginX = tabContentStartX
        for index in 0..<tabCount {
            let tab = group.windows[index]
            // Pinned tabs don't show trailing close/release controls.
            if tab.isPinned || tab.isSeparator {
                tabOriginX += (layout.widths[safe: index] ?? 0) + TabBarView.tabGap(after: index, tabs: group.windows)
                continue
            }
            let tabWidth = layout.widths[safe: index] ?? 0
            let tabEndX = tabOriginX + tabWidth
            let controlStartX = max(tabOriginX, tabEndX - controlInset)

            if point.x >= controlStartX && point.x <= tabEndX {
                return true
            }
            tabOriginX += tabWidth + TabBarView.tabGap(after: index, tabs: group.windows)
        }

        return false
    }
}
