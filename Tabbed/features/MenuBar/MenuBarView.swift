import SwiftUI

struct MenuBarView: View {
    @ObservedObject var groupManager: GroupManager
    @ObservedObject var sessionState: SessionState

    var onNewGroup: () -> Void
    var onAllInSpace: () -> Void
    var onRestoreSession: () -> Void
    var onFocusWindow: (WindowInfo) -> Void
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

            menuItem("New Group", systemImage: "plus") {
                onNewGroup()
            }

            menuItem("All in Space", systemImage: "rectangle.stack.fill") {
                onAllInSpace()
            }

            if sessionState.hasPendingSession {
                menuItem("Restore Previous Session", systemImage: "arrow.counterclockwise") {
                    onRestoreSession()
                }
            }

            Divider()
                .padding(.vertical, 4)

            menuItem("Settings…", systemImage: "gear") {
                onSettings()
            }

            menuItem("Quit Tabbed") {
                onQuit()
            }
        }
        .padding(4)
    }

    @ViewBuilder
    private var groupList: some View {
        let rows = VStack(alignment: .leading, spacing: 0) {
            ForEach(groupManager.groups) { group in
                groupRow(group)
            }
        }

        if groupManager.groups.count > 8 {
            ScrollView { rows }
                .frame(maxHeight: 300)
        } else {
            rows
        }
    }

    private func menuItem(_ title: String, systemImage: String? = nil, action: @escaping () -> Void) -> some View {
        MenuItemButton(title: title, systemImage: systemImage, action: action)
    }

    private func groupRow(_ group: TabGroup) -> some View {
        HStack(spacing: 4) {
            ForEach(group.windows) { window in
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
                .help(window.title.isEmpty ? window.appName : window.title)
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
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.05))
        )
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
    }
}

private struct MenuItemButton: View {
    let title: String
    var systemImage: String?
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
