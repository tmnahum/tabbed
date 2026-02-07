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
    private var scope: Scope = .global

    /// Called when the user commits a selection. Passes the selected SwitcherItem.
    var onCommit: ((SwitcherItem) -> Void)?
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

        updatePanel()
    }

    // MARK: - Navigate

    func advance() {
        guard !items.isEmpty else { return }
        selectedIndex = (selectedIndex + 1) % items.count
        updatePanelContent()
    }

    func retreat() {
        guard !items.isEmpty else { return }
        selectedIndex = (selectedIndex - 1 + items.count) % items.count
        updatePanelContent()
    }

    // MARK: - Commit / Dismiss

    func commit() {
        guard !items.isEmpty, selectedIndex < items.count else {
            dismiss()
            return
        }
        let selected = items[selectedIndex]
        tearDown()
        onCommit?(selected)
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

        let view = SwitcherView(
            items: items,
            selectedIndex: selectedIndex,
            style: style
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

    private func tearDown() {
        panel?.dismiss()
        panel = nil
        items = []
        selectedIndex = 0
    }
}
