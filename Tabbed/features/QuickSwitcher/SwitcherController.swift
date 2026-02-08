import AppKit
import SwiftUI

/// Manages a single quick-switcher session (show -> navigate -> commit/dismiss).
class SwitcherController {

    enum Scope {
        case global          // All windows + groups
        case withinGroup     // Tabs in active group (MRU order)
    }

    private var panel: SwitcherPanel?
    private var items: [SwitcherItem] = []
    private var selectedIndex: Int = 0
    private var style: SwitcherStyle = .appIcons
    private(set) var scope: Scope = .global

    /// When non-nil, the user is sub-selecting within a group item.
    /// Value is an index into the group's `windows` array.
    private(set) var subSelectedWindowIndex: Int?

    /// Called when the user commits a selection. Passes the selected SwitcherItem and optional sub-selection index.
    var onCommit: ((SwitcherItem, Int?) -> Void)?
    /// Called when the user dismisses without selecting.
    var onDismiss: (() -> Void)?

    var isActive: Bool { panel != nil }

    // MARK: - Show

    func show(items: [SwitcherItem], style: SwitcherStyle, scope: Scope) {
        guard !items.isEmpty else { return }

        self.items = items
        self.style = style
        self.scope = scope
        self.selectedIndex = 0
        self.subSelectedWindowIndex = nil

        updatePanel()
    }

    // MARK: - Navigate

    func advance() {
        guard !items.isEmpty else { return }
        subSelectedWindowIndex = nil
        selectedIndex = (selectedIndex + 1) % items.count
        updatePanelContent()
    }

    func retreat() {
        guard !items.isEmpty else { return }
        subSelectedWindowIndex = nil
        selectedIndex = (selectedIndex - 1 + items.count) % items.count
        updatePanelContent()
    }

    /// Cycle through windows within the currently selected group item.
    /// No-op if the selected item is not a multi-window group.
    func cycleWithinGroup() {
        guard scope == .global, !items.isEmpty, selectedIndex < items.count else { return }
        guard case .group(let group) = items[selectedIndex], group.windows.count > 1 else { return }

        let current = subSelectedWindowIndex ?? group.activeIndex
        subSelectedWindowIndex = (current + 1) % group.windows.count
        updatePanelContent()
    }

    // MARK: - Directional Navigation

    enum ArrowDirection { case left, right, up, down }

    func handleArrowKey(_ direction: ArrowDirection) {
        guard !items.isEmpty else { return }
        let isPrimaryAxis: Bool
        switch style {
        case .appIcons: isPrimaryAxis = (direction == .left || direction == .right)
        case .titles:   isPrimaryAxis = (direction == .up || direction == .down)
        }
        if isPrimaryAxis {
            let isForward = (direction == .right || direction == .down)
            if isForward { advance() } else { retreat() }
        } else {
            let isForward = (direction == .right || direction == .down)
            if isForward { cycleWithinGroup() } else { cycleWithinGroupBackward() }
        }
    }

    /// Cycle backward through windows within the currently selected group item.
    func cycleWithinGroupBackward() {
        guard scope == .global, !items.isEmpty, selectedIndex < items.count else { return }
        guard case .group(let group) = items[selectedIndex], group.windows.count > 1 else { return }

        let current = subSelectedWindowIndex ?? group.activeIndex
        subSelectedWindowIndex = (current - 1 + group.windows.count) % group.windows.count
        updatePanelContent()
    }

    // MARK: - Commit / Dismiss

    func commit() {
        guard !items.isEmpty, selectedIndex < items.count else {
            dismiss()
            return
        }
        let selected = items[selectedIndex]
        let subIndex = subSelectedWindowIndex
        tearDown()
        onCommit?(selected, subIndex)
    }

    func dismiss() {
        tearDown()
        onDismiss?()
    }

    // MARK: - Private

    private func updatePanel() {
        if panel == nil {
            // Initial size doesn't matter — updatePanelContent resizes to fit
            panel = SwitcherPanel(contentRect: NSRect(origin: .zero, size: NSSize(width: 400, height: 200)))
        }
        updatePanelContent()
        panel?.showCentered()
    }

    private func updatePanelContent() {
        guard let panel else { return }

        let visible = computeVisibleWindow()
        let view = SwitcherView(
            items: visible.items,
            selectedIndex: visible.adjustedIndex,
            style: style,
            showLeadingOverflow: visible.leadingOverflow,
            showTrailingOverflow: visible.trailingOverflow,
            subSelectedWindowIndex: subSelectedWindowIndex
        )

        let hostingView: NSHostingView<SwitcherView>
        if let existing = panel.contentView?.subviews.compactMap({ $0 as? NSHostingView<SwitcherView> }).first {
            existing.rootView = view
            hostingView = existing
        } else {
            hostingView = NSHostingView(rootView: view)
            panel.contentView?.addSubview(hostingView)
        }

        // Use SwiftUI's intrinsic size rather than manual calculation
        let fittingSize = hostingView.fittingSize
        hostingView.frame = NSRect(origin: .zero, size: fittingSize)

        let currentOrigin = panel.frame.origin
        let newFrame = NSRect(
            x: currentOrigin.x + (panel.frame.width - fittingSize.width) / 2,
            y: currentOrigin.y + (panel.frame.height - fittingSize.height) / 2,
            width: fittingSize.width,
            height: fittingSize.height
        )
        panel.setFrame(newFrame, display: true)
    }

    private func computeVisibleWindow() -> (items: [SwitcherItem], adjustedIndex: Int, leadingOverflow: Bool, trailingOverflow: Bool) {
        let screen = NSScreen.screens.first(where: {
            NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
        }) ?? NSScreen.main
        let screenSize = screen?.visibleFrame.size ?? CGSize(width: 1440, height: 900)

        let maxItems: Int
        switch style {
        case .appIcons:
            // Each icon cell is ~96px wide + 16px spacing
            let available = screenSize.width * 0.85
            maxItems = max(3, Int((available - 40) / 112))
        case .titles:
            // Each title row is ~38px tall
            let available = screenSize.height * 0.85
            maxItems = max(3, Int((available - 32) / 38))
        }

        guard items.count > maxItems else {
            return (items, selectedIndex, false, false)
        }

        // Sliding window centered on selectedIndex
        var start = selectedIndex - maxItems / 2
        var end = start + maxItems

        if start < 0 {
            start = 0
            end = min(maxItems, items.count)
        }
        if end > items.count {
            end = items.count
            start = max(0, end - maxItems)
        }

        return (
            Array(items[start..<end]),
            selectedIndex - start,
            start > 0,
            end < items.count
        )
    }

    private func tearDown() {
        panel?.dismiss()
        panel = nil
        items = []
        selectedIndex = 0
        subSelectedWindowIndex = nil
    }
}
