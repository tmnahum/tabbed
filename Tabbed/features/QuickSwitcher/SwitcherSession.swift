import CoreGraphics

/// Mutable state for a single switcher interaction session.
struct SwitcherSession {
    var items: [SwitcherItem] = []
    var selectedIndex: Int = 0
    var style: SwitcherStyle = .appIcons
    var namedGroupLabelMode: NamedGroupLabelMode = .groupAppWindow
    var scope: SwitcherController.Scope = .global
    var subSelectedWindowID: CGWindowID?

    var hasItems: Bool { !items.isEmpty }

    var selectedItem: SwitcherItem? {
        guard selectedIndex >= 0, selectedIndex < items.count else { return nil }
        return items[selectedIndex]
    }

    mutating func start(
        items: [SwitcherItem],
        style: SwitcherStyle,
        scope: SwitcherController.Scope,
        namedGroupLabelMode: NamedGroupLabelMode
    ) {
        self.items = items
        self.style = style
        self.scope = scope
        self.namedGroupLabelMode = namedGroupLabelMode
        self.selectedIndex = 0
        self.subSelectedWindowID = nil
    }

    mutating func clear() {
        items = []
        selectedIndex = 0
        subSelectedWindowID = nil
    }

    mutating func clearSubSelection() {
        subSelectedWindowID = nil
    }

    mutating func advance() {
        guard hasItems else { return }
        clearSubSelection()
        selectedIndex = (selectedIndex + 1) % items.count
    }

    mutating func retreat() {
        guard hasItems else { return }
        clearSubSelection()
        selectedIndex = (selectedIndex - 1 + items.count) % items.count
    }

    mutating func select(index: Int) -> Bool {
        guard index >= 0, index < items.count else { return false }
        selectedIndex = index
        clearSubSelection()
        return true
    }
}
