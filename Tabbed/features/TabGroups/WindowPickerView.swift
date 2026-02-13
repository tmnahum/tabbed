import SwiftUI

struct WindowPickerView: View {
    @ObservedObject var windowManager: WindowManager
    @ObservedObject var groupManager: GroupManager
    let onCreateGroup: ([WindowInfo]) -> Void
    let onAddToGroup: (WindowInfo) -> Void
    let onMergeGroup: (TabGroup) -> Void
    let onDismiss: () -> Void

    /// If non-nil, we're adding to an existing group (show single-select).
    /// If nil, we're creating a new group (show multi-select).
    let addingToGroup: TabGroup?

    @State private var selectedIDs: Set<CGWindowID> = []
    @State private var focusedIndex: Int = 0

    /// Windows sorted with ungrouped first, grouped last.
    private var sortedWindows: [WindowInfo] {
        windowManager.availableWindows.sorted { a, b in
            let aGrouped = groupManager.isWindowGrouped(a.id)
            let bGrouped = groupManager.isWindowGrouped(b.id)
            if aGrouped != bGrouped { return !aGrouped }
            return false
        }
    }

    /// Ungrouped windows only (for keyboard navigation).
    private var ungroupedWindows: [WindowInfo] {
        sortedWindows.filter { !groupManager.isWindowGrouped($0.id) }
    }

    /// Other groups on the same Space as addingToGroup (for merge).
    private var mergeableGroups: [TabGroup] {
        guard let target = addingToGroup,
              let targetWindowID = target.activeWindow?.id,
              let targetSpace = SpaceUtils.spaceID(for: targetWindowID) else { return [] }
        return groupManager.groups.filter { group in
            guard group.id != target.id,
                  let windowID = group.activeWindow?.id else { return false }
            return SpaceUtils.spaceID(for: windowID) == targetSpace
        }
    }

    /// Total navigable items: ungrouped windows + mergeable groups.
    private var totalNavigableCount: Int {
        ungroupedWindows.count + mergeableGroups.count
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            windowList
            if addingToGroup == nil {
                Divider()
                footer
            }
        }
        .frame(width: 350, height: 400)
        .background(KeyEventHandler(
            onArrowDown: { moveFocus(by: 1) },
            onArrowUp: { moveFocus(by: -1) },
            onTab: { moveFocus(by: 1) },
            onReturn: { confirmFocused() },
            onEscape: { onDismiss() }
        ))
    }

    private func moveFocus(by delta: Int) {
        let count = totalNavigableCount
        guard count > 0 else { return }
        focusedIndex = max(0, min(count - 1, focusedIndex + delta))
    }

    private func confirmFocused() {
        let ungrouped = ungroupedWindows
        if focusedIndex < ungrouped.count {
            let window = ungrouped[focusedIndex]
            if addingToGroup != nil {
                onAddToGroup(window)
            } else {
                // Create a group with just this window
                onCreateGroup([window])
            }
        } else if addingToGroup != nil {
            let groupIndex = focusedIndex - ungrouped.count
            let groups = mergeableGroups
            guard groupIndex >= 0, groupIndex < groups.count else { return }
            onMergeGroup(groups[groupIndex])
        }
    }

    private var header: some View {
        HStack {
            Text(addingToGroup != nil ? "Add Window" : "New Group")
                .font(.headline)
            Spacer()
            Button {
                windowManager.refreshWindowList()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            Button("Cancel") { onDismiss() }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .padding(12)
    }

    private var windowList: some View {
        ScrollView {
            if !AccessibilityHelper.checkPermission() {
                VStack(spacing: 12) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text("Accessibility Access Required")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Tabbed needs accessibility permission to see and manage windows.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Open System Settings") {
                        AccessibilityHelper.requestPermission()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    Button("Check Again") {
                        windowManager.refreshWindowList()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, 40)
            } else if ungroupedWindows.isEmpty && mergeableGroups.isEmpty {
                VStack(spacing: 12) {
                    Text("No available windows")
                        .foregroundStyle(.secondary)
                    Button("Refresh") {
                        windowManager.refreshWindowList()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, 40)
            } else {
                LazyVStack(spacing: 2) {
                    if addingToGroup != nil {
                        // Add-to-group mode: ungrouped windows + mergeable groups
                        ForEach(Array(ungroupedWindows.enumerated()), id: \.element.id) { index, window in
                            windowRow(window: window, isGrouped: false, isFocused: index == focusedIndex)
                        }

                        let groups = mergeableGroups
                        if !groups.isEmpty {
                            sectionHeader("Groups")
                            ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                                let navIndex = ungroupedWindows.count + index
                                groupRow(group: group, isFocused: navIndex == focusedIndex)
                            }
                        }
                    } else {
                        // New-group mode: all windows, grouped ones disabled
                        let windows = sortedWindows
                        ForEach(Array(windows.enumerated()), id: \.element.id) { _, window in
                            let isGrouped = groupManager.isWindowGrouped(window.id)
                            let ungroupedIdx = isGrouped ? -1 : ungroupedWindows.firstIndex(where: { $0.id == window.id }) ?? -1
                            windowRow(window: window, isGrouped: isGrouped, isFocused: ungroupedIdx == focusedIndex)
                        }
                    }
                }
                .padding(8)
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }

    private func windowRow(window: WindowInfo, isGrouped: Bool, isFocused: Bool) -> some View {
        let isSelected = selectedIDs.contains(window.id)

        return Button {
            guard !isGrouped else { return }
            if addingToGroup != nil {
                onAddToGroup(window)
            } else {
                if isSelected {
                    selectedIDs.remove(window.id)
                } else {
                    selectedIDs.insert(window.id)
                }
            }
        } label: {
            HStack(spacing: 8) {
                if let icon = window.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 20, height: 20)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(window.appName)
                        .font(.system(size: 12, weight: .medium))
                    Text(window.title)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if isGrouped {
                    Text("Grouped")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                } else if addingToGroup == nil {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? .blue : .secondary)
                }
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.blue.opacity(0.1)
                          : isFocused ? Color.primary.opacity(0.08)
                          : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isFocused ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isGrouped)
        .opacity(isGrouped ? 0.4 : 1)
    }

    private func groupRow(group: TabGroup, isFocused: Bool) -> some View {
        Button {
            onMergeGroup(group)
        } label: {
            HStack(spacing: 8) {
                groupIconStack(group: group)
                VStack(alignment: .leading, spacing: 1) {
                    Text(groupDisplayName(group))
                        .font(.system(size: 12, weight: .medium))
                    Text("\(group.managedWindowCount) tabs")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.right.square")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isFocused ? Color.primary.opacity(0.08) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isFocused ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func groupDisplayName(_ group: TabGroup) -> String {
        let appNames = Array(Set(group.managedWindows.map(\.appName)))
        if appNames.count == 1 {
            return "\(group.managedWindowCount) \(appNames[0]) windows"
        } else if appNames.count <= 2 {
            return appNames.joined(separator: ", ")
        } else {
            return "\(appNames.prefix(2).joined(separator: ", ")) + \(appNames.count - 2) more"
        }
    }

    /// Small overlapping icons for a group row.
    private func groupIconStack(group: TabGroup) -> some View {
        let icons = Array(group.managedWindows.prefix(4).map(\.icon))
        let count = icons.count
        let iconSize: CGFloat = 20
        let overlap: CGFloat = 8

        return ZStack {
            ForEach(Array(icons.enumerated()), id: \.offset) { index, icon in
                Group {
                    if let icon {
                        Image(nsImage: icon)
                            .resizable()
                    } else {
                        Image(systemName: "macwindow")
                            .font(.system(size: 12))
                    }
                }
                .frame(width: iconSize, height: iconSize)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .shadow(color: .black.opacity(0.1), radius: 1, y: 0.5)
                .offset(x: CGFloat(index) * overlap - CGFloat(count - 1) * overlap / 2)
            }
        }
        .frame(width: CGFloat(min(count, 4)) * overlap + iconSize - overlap, height: iconSize)
    }

    @ViewBuilder
    private var footer: some View {
        if addingToGroup == nil {
            HStack {
                Button("Group All in Space") {
                    let allUngrouped = windowManager.availableWindows.filter { !groupManager.isWindowGrouped($0.id) }
                    guard !allUngrouped.isEmpty else { return }
                    onCreateGroup(allUngrouped)
                }
                .disabled(windowManager.availableWindows.filter { !groupManager.isWindowGrouped($0.id) }.isEmpty)
                Spacer()
                Button("Create Group") {
                    let selected = windowManager.availableWindows.filter { selectedIDs.contains($0.id) }
                    onCreateGroup(selected)
                }
                .disabled(selectedIDs.count < 1)
            }
            .padding(12)
        }
    }
}

// MARK: - Keyboard Event Handler

struct KeyEventHandler: NSViewRepresentable {
    var onArrowDown: () -> Void
    var onArrowUp: () -> Void
    var onTab: () -> Void
    var onReturn: () -> Void
    var onEscape: () -> Void

    func makeNSView(context: Context) -> KeyEventView {
        let view = KeyEventView()
        view.onArrowDown = onArrowDown
        view.onArrowUp = onArrowUp
        view.onTab = onTab
        view.onReturn = onReturn
        view.onEscape = onEscape
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ nsView: KeyEventView, context: Context) {
        nsView.onArrowDown = onArrowDown
        nsView.onArrowUp = onArrowUp
        nsView.onTab = onTab
        nsView.onReturn = onReturn
        nsView.onEscape = onEscape
    }
}

class KeyEventView: NSView {
    var onArrowDown: (() -> Void)?
    var onArrowUp: (() -> Void)?
    var onTab: (() -> Void)?
    var onReturn: (() -> Void)?
    var onEscape: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 125: onArrowDown?()    // Down arrow
        case 126: onArrowUp?()      // Up arrow
        case 48:  onTab?()          // Tab
        case 36:  onReturn?()       // Return/Enter
        case 53:  onEscape?()       // Escape
        default: super.keyDown(with: event)
        }
    }
}
