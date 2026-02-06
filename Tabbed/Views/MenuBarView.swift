import SwiftUI

struct MenuBarView: View {
    @ObservedObject var groupManager: GroupManager

    var onNewGroup: () -> Void
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

            Divider()

            Button {
                onQuit()
            } label: {
                Text("Quit Tabbed")
            }
            .padding(.horizontal, 8)
        }
        .padding(8)
        .frame(width: 220)
    }

    private func groupRow(_ group: TabGroup) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(group.windows) { window in
                HStack(spacing: 4) {
                    if let icon = window.icon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 14, height: 14)
                    }
                    Text(window.title.isEmpty ? window.appName : window.title)
                        .font(.system(size: 12))
                        .lineLimit(1)
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.05))
        )
        .padding(.horizontal, 4)
    }
}
