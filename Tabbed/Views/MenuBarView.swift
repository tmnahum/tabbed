import SwiftUI

struct MenuBarView: View {
    @ObservedObject var groupManager: GroupManager

    var onNewGroup: () -> Void
    var onFocusWindow: (WindowInfo) -> Void
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
                Group {
                    if let icon = window.icon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 18, height: 18)
                    } else {
                        Image(systemName: "macwindow")
                            .frame(width: 18, height: 18)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { onFocusWindow(window) }
                .help(window.title.isEmpty ? window.appName : window.title)
            }
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.05))
        )
        .padding(.horizontal, 4)
    }
}
