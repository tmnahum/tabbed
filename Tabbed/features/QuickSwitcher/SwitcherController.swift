import AppKit
import SwiftUI

/// Manages a single quick-switcher session (show -> navigate -> commit/dismiss).
class SwitcherController {

    enum Scope {
        case global          // All windows + groups
        case withinGroup     // Tabs in active group (MRU order)
    }

    private var panel: SwitcherPanel?
    private var session = SwitcherSession()
    var scope: Scope { session.scope }

    /// Stable sub-selection identity for group entries.
    private var subSelectedWindowID: CGWindowID? {
        get { session.subSelectedWindowID }
        set { session.subSelectedWindowID = newValue }
    }
    /// Current sub-selection index for the selected group item.
    var subSelectedWindowIndex: Int? {
        guard session.scope == .global,
              session.hasItems,
              session.selectedIndex < session.items.count,
              case .group(let group) = session.items[session.selectedIndex],
              let subSelectedWindowID else {
            return nil
        }
        return group.managedWindows.firstIndex { $0.id == subSelectedWindowID }
    }

    /// Called when the user commits a selection. Passes the selected SwitcherItem and optional sub-selection index.
    var onCommit: ((SwitcherItem, Int?) -> Void)?
    /// Called when the user dismisses without selecting.
    var onDismiss: (() -> Void)?

    var isActive: Bool { panel != nil }

    // MARK: - Show

    func show(
        items: [SwitcherItem],
        style: SwitcherStyle,
        scope: Scope,
        namedGroupLabelMode: NamedGroupLabelMode = .groupAppWindow
    ) {
        guard !items.isEmpty else { return }

        session.start(items: items, style: style, scope: scope, namedGroupLabelMode: namedGroupLabelMode)

        updatePanel()
    }

    // MARK: - Navigate

    func advance() {
        guard session.hasItems else { return }
        session.advance()
        updatePanelContent()
    }

    func retreat() {
        guard session.hasItems else { return }
        session.retreat()
        updatePanelContent()
    }

    /// Cycle through windows within the currently selected group item (MRU order).
    /// No-op if the selected item is not a multi-window group.
    func cycleWithinGroup() {
        guard session.scope == .global,
              session.hasItems,
              session.selectedIndex < session.items.count else { return }
        guard case .group(let group) = session.items[session.selectedIndex], group.managedWindowCount > 1 else { return }

        let indices = mruWindowIndices(for: group)
        guard !indices.isEmpty else { return }
        // Start from the existing sub-selection, or MRU position 0 (the visual
        // head) if this is the first press — NOT group.activeIndex, which may
        // differ from what's displayed.
        let currentPos = subSelectedWindowPosition(in: group, mruIndices: indices) ?? 0
        let nextIndex = indices[(currentPos + 1) % indices.count]
        session.subSelectedWindowID = group.managedWindows[nextIndex].id
        updatePanelContent()
    }

    // MARK: - Directional Navigation

    enum ArrowDirection { case left, right, up, down }

    func handleArrowKey(_ direction: ArrowDirection) {
        guard session.hasItems else { return }
        let isPrimaryAxis: Bool
        switch session.style {
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

    /// Cycle backward through windows within the currently selected group item (MRU order).
    func cycleWithinGroupBackward() {
        guard session.scope == .global,
              session.hasItems,
              session.selectedIndex < session.items.count else { return }
        guard case .group(let group) = session.items[session.selectedIndex], group.managedWindowCount > 1 else { return }

        let indices = mruWindowIndices(for: group)
        guard !indices.isEmpty else { return }
        let currentPos = subSelectedWindowPosition(in: group, mruIndices: indices) ?? 0
        let nextIndex = indices[(currentPos - 1 + indices.count) % indices.count]
        session.subSelectedWindowID = group.managedWindows[nextIndex].id
        updatePanelContent()
    }

    // MARK: - Commit / Dismiss

    /// Select an item by its index in the full items array and commit immediately.
    func selectAndCommit(at index: Int) {
        guard session.select(index: index) else { return }
        commit()
    }

    func commit() {
        guard let selected = session.selectedItem else {
            dismiss()
            return
        }
        let subIndex = subSelectedWindowIndex(for: selected)
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
        let visibleStartOffset = session.selectedIndex - visible.adjustedIndex
        let precomputedGroupIcons = precomputeGroupIcons(
            for: visible.items,
            selectedVisibleIndex: visible.adjustedIndex
        )
        let view = SwitcherView(
            items: visible.items,
            selectedIndex: visible.adjustedIndex,
            style: session.style,
            namedGroupLabelMode: session.namedGroupLabelMode,
            showLeadingOverflow: visible.leadingOverflow,
            showTrailingOverflow: visible.trailingOverflow,
            subSelectedWindowIndex: subSelectedWindowIndex,
            precomputedGroupIcons: precomputedGroupIcons,
            onItemClicked: { [weak self] visibleIndex in
                self?.selectAndCommit(at: visibleStartOffset + visibleIndex)
            }
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
        switch session.style {
        case .appIcons:
            // Each icon cell is ~96px wide + 16px spacing
            let available = screenSize.width * 0.85
            maxItems = max(3, Int((available - 40) / 112))
        case .titles:
            // Each title row is ~42px tall (14pt font + 16px vertical padding + 2px spacing)
            let available = screenSize.height * 0.85
            maxItems = max(3, Int((available - 32) / 42))
        }

        guard session.items.count > maxItems else {
            return (session.items, session.selectedIndex, false, false)
        }

        // Sliding window centered on selectedIndex.
        var start = session.selectedIndex - maxItems / 2
        var end = start + maxItems

        if start < 0 {
            start = 0
            end = min(maxItems, session.items.count)
        }
        if end > session.items.count {
            end = session.items.count
            start = max(0, end - maxItems)
        }

        return (
            Array(session.items[start..<end]),
            session.selectedIndex - start,
            start > 0,
            end < session.items.count
        )
    }

    /// Returns indices into `group.managedWindows` ordered by MRU (most-recent first).
    private func mruWindowIndices(for group: TabGroup) -> [Int] {
        let windowIDs = Set(group.managedWindows.map(\.id))
        let mruIDs = group.focusHistory.filter { windowIDs.contains($0) }
        let remainingIDs = group.managedWindows.map(\.id).filter { !mruIDs.contains($0) }
        return (mruIDs + remainingIDs).compactMap { id in
            group.managedWindows.firstIndex { $0.id == id }
        }
    }

    private func subSelectedWindowPosition(in group: TabGroup, mruIndices: [Int]) -> Int? {
        guard let subSelectedWindowID,
              let selectedWindowIndex = group.managedWindows.firstIndex(where: { $0.id == subSelectedWindowID }) else {
            return nil
        }
        return mruIndices.firstIndex(of: selectedWindowIndex)
    }

    private func subSelectedWindowIndex(for item: SwitcherItem) -> Int? {
        guard case .group(let group) = item,
              let subSelectedWindowID else { return nil }
        return group.managedWindows.firstIndex { $0.id == subSelectedWindowID }
    }

    private func precomputeGroupIcons(
        for items: [SwitcherItem],
        selectedVisibleIndex: Int
    ) -> [String: [(icon: NSImage?, isFullscreened: Bool)]] {
        let maxGroupIcons = 8
        var cache: [String: [(icon: NSImage?, isFullscreened: Bool)]] = [:]
        for (index, item) in items.enumerated() where item.isGroup {
            let frontIndex = (index == selectedVisibleIndex) ? subSelectedWindowIndex : nil
            cache[item.id] = item.iconsInMRUOrder(frontIndex: frontIndex, maxVisible: maxGroupIcons)
        }
        return cache
    }

    private func tearDown() {
        panel?.dismiss()
        panel = nil
        session.clear()
    }
}
