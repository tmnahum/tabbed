import SwiftUI

struct MenuBarView: View {
    @ObservedObject var groupManager: GroupManager
    @ObservedObject var sessionState: SessionState
    @ObservedObject var windowInventory: WindowInventory
    @ObservedObject var menuBarConfig: MenuBarConfig
    @State private var hoveredUngroupedWindowID: CGWindowID?

    var shortcutConfig: ShortcutConfig
    var onNewGroup: () -> Void
    var onAllInSpace: () -> Void
    var onRestoreSession: () -> Void
    var onFocusWindow: (WindowInfo) -> Void
    var onQuitWindow: (WindowInfo) -> Void
    var onDisbandGroup: (TabGroup) -> Void
    var onQuitGroup: (TabGroup) -> Void
    var onSettings: () -> Void
    var onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if groupManager.groups.isEmpty {
                Text("No groups")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            } else {
                groupList
            }

            menuItem("New Group", systemImage: "plus", shortcutHint: shortcutConfig.newTab.displayString) {
                onNewGroup()
            }

            menuItem("Group All in Space", systemImage: "rectangle.stack.fill", shortcutHint: shortcutConfig.groupAllInSpace.displayString) {
                onAllInSpace()
            }

            if menuBarConfig.showUngroupedWindows, !ungroupedWindows.isEmpty {
                ungroupedWindowList
            }

            if sessionState.hasPendingSession {
                menuItem("Restore Previous Session", systemImage: "arrow.counterclockwise") {
                    onRestoreSession()
                }
            }

            Divider()
                .padding(.vertical, 4)

            menuItem("Settings…", systemImage: "gear", shortcutHint: "⌘,") {
                onSettings()
            }

            menuItem("Quit Tabbed") {
                onQuit()
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 7)
        .padding(.bottom, 4)
    }

    private var ungroupedWindows: [WindowInfo] {
        let groupedWindowIDs = Set(
            groupManager.groups.flatMap { $0.managedWindows.map(\.id) }
        )
        return WindowManager.ungroupedWindows(
            from: windowInventory.cachedAllSpacesWindows,
            groupedWindowIDs: groupedWindowIDs
        )
    }

    @ViewBuilder
    private var ungroupedWindowList: some View {
        let rows = VStack(alignment: .leading, spacing: 0) {
            ForEach(ungroupedWindows) { window in
                ungroupedWindowRow(window)
            }
        }

        Divider()
            .padding(.vertical, 4)

        if ungroupedWindows.count > 8 {
            ScrollView { rows }
                .frame(height: 28 * 8.5)
        } else {
            rows
        }
    }

    @ViewBuilder
    private var groupList: some View {
        let rows = VStack(alignment: .leading, spacing: 0) {
            ForEach(groupManager.groups) { group in
                groupRow(group)
            }
        }

        if groupManager.groups.count > 4 {
            ScrollView { rows }
                .frame(height: 34 * 4.5)
        } else {
            rows
        }
    }

    private func menuItem(_ title: String, systemImage: String? = nil, shortcutHint: String? = nil, action: @escaping () -> Void) -> some View {
        MenuItemButton(title: title, systemImage: systemImage, shortcutHint: shortcutHint, action: action)
    }

    private func groupLabel(_ group: TabGroup) -> String {
        group.displayName ?? ""
    }

    private func groupRow(_ group: TabGroup) -> some View {
        HStack(spacing: 4) {
            let label = groupLabel(group)
            if !label.isEmpty {
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(label)
            }

            ForEach(group.managedWindows) { window in
                Button {
                    onFocusWindow(window)
                } label: {
                    if let icon = window.icon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 18, height: 18)
                    } else {
                        Image(systemName: "macwindow")
                            .frame(width: 18, height: 18)
                    }
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .help(window.displayTitle)
            }

            Spacer()

            Button {
                onDisbandGroup(group)
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Disband group")

            Button {
                onQuitGroup(group)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Quit all windows")
        }
        .padding(6)
        .background(
            Button {
                if let window = group.activeWindow {
                    onFocusWindow(window)
                }
            } label: {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.05))
            }
            .buttonStyle(.plain)
        )
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
    }

    private func ungroupedWindowRow(_ window: WindowInfo) -> some View {
        HStack(spacing: 4) {
            Button {
                onFocusWindow(window)
            } label: {
                HStack(spacing: 8) {
                    if let icon = window.icon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 18, height: 18)
                    } else {
                        Image(systemName: "macwindow")
                            .frame(width: 18, height: 18)
                    }

                    Text(window.displayTitle)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Focus \(window.displayTitle)")

            Button {
                onQuitWindow(window)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close \(window.displayTitle)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(hoveredUngroupedWindowID == window.id ? Color.primary.opacity(0.1) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovered in
            if isHovered {
                hoveredUngroupedWindowID = window.id
            } else if hoveredUngroupedWindowID == window.id {
                hoveredUngroupedWindowID = nil
            }
        }
    }
}

private struct MenuItemButton: View {
    let title: String
    var systemImage: String?
    var shortcutHint: String?
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .frame(width: 16)
                }
                Text(title)
                Spacer()
                if let shortcutHint {
                    Text(shortcutHint)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isHovered ? Color.accentColor : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
