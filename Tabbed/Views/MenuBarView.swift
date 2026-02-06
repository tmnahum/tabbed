import SwiftUI

struct MenuBarView: View {
    @ObservedObject var groupManager: GroupManager

    var onNewGroup: () -> Void
    var onFocusWindow: (WindowInfo) -> Void
    var onDisbandGroup: (TabGroup) -> Void
    var onSettings: () -> Void
    var onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if groupManager.groups.isEmpty {
                Text("No groups")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            } else {
                ForEach(groupManager.groups) { group in
                    groupRow(group)
                }
            }

            Divider()

            Button {
                onNewGroup()
            } label: {
                Label("New Group", systemImage: "plus")
            }
            .padding(.horizontal, 8)

            Button {
                onSettings()
            } label: {
                Label("Settings…", systemImage: "gear")
            }
            .padding(.horizontal, 8)

            Divider()

            Button {
                onQuit()
            } label: {
                Text("Quit Tabbed")
            }
            .padding(.horizontal, 8)
        }
        .padding(8)
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
                .help(window.title.isEmpty ? window.appName : window.title)
            }

            Spacer()

            Button {
                onDisbandGroup(group)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Disband group")
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.05))
        )
        .padding(.horizontal, 4)
    }
}
