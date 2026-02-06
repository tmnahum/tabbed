import SwiftUI

struct WindowPickerView: View {
    @ObservedObject var windowManager: WindowManager
    @ObservedObject var groupManager: GroupManager
    let onCreateGroup: ([WindowInfo]) -> Void
    let onAddToGroup: (WindowInfo) -> Void
    let onDismiss: () -> Void

    /// If non-nil, we're adding to an existing group (show single-select).
    /// If nil, we're creating a new group (show multi-select).
    let addingToGroup: TabGroup?

    @State private var selectedIDs: Set<CGWindowID> = []

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
            } else if windowManager.availableWindows.isEmpty {
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
                    ForEach(windowManager.availableWindows) { window in
                        let isGrouped = groupManager.isWindowGrouped(window.id)
                        windowRow(window: window, isGrouped: isGrouped)
                    }
                }
                .padding(8)
            }
        }
    }

    private func windowRow(window: WindowInfo, isGrouped: Bool) -> some View {
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
                    .fill(isSelected ? Color.blue.opacity(0.1) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isGrouped)
        .opacity(isGrouped ? 0.4 : 1)
    }

    @ViewBuilder
    private var footer: some View {
        if addingToGroup == nil {
            HStack {
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
