import SwiftUI
import AppKit

struct MenuBarView: View {
    @ObservedObject var groupManager: GroupManager
    @StateObject private var menuState = MenuPanelState()

    var onNewGroup: () -> Void
    var onFocusWindow: (WindowInfo) -> Void
    var onDisbandGroup: (TabGroup) -> Void
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
                ForEach(groupManager.groups) { group in
                    groupRow(group)
                }
            }

            menuItem("New Group", systemImage: "plus") {
                menuState.dismiss()
                onNewGroup()
            }

            Divider()
                .padding(.vertical, 4)

            menuItem("Settings…", systemImage: "gear") {
                menuState.dismiss()
                onSettings()
            }

            menuItem("Quit Tabbed") {
                onQuit()
            }
        }
        .padding(4)
        .background(MenuPanelTracker(state: menuState))
    }

    private func menuItem(_ title: String, systemImage: String? = nil, action: @escaping () -> Void) -> some View {
        MenuItemButton(title: title, systemImage: systemImage, action: action)
    }

    private func groupRow(_ group: TabGroup) -> some View {
        HStack(spacing: 4) {
            ForEach(group.windows) { window in
                Button {
                    menuState.dismiss()
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
                menuState.dismiss()
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

// MARK: - Menu Panel State & Tracker

/// Tracks the MenuBarExtra's hosting window for dismissal and menu bar pinning.
private class MenuPanelState: ObservableObject {
    weak var menuWindow: NSWindow?

    func dismiss() {
        menuWindow?.close()
    }
}

/// NSViewRepresentable that captures the hosting window reference and prevents
/// the menu bar from auto-hiding while the panel is visible.
private struct MenuPanelTracker: NSViewRepresentable {
    let state: MenuPanelState

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.setFrameSize(.zero)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let window = nsView.window {
            state.menuWindow = window
            context.coordinator.startObserving(window: window)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator {
        private var savedOptions: NSApplication.PresentationOptions?
        private var observers: [NSObjectProtocol] = []
        private weak var observedWindow: NSWindow?

        func startObserving(window: NSWindow) {
            guard observedWindow !== window else { return }
            stopObserving()
            observedWindow = window
            pinMenuBar()

            observers.append(
                NotificationCenter.default.addObserver(
                    forName: NSWindow.willCloseNotification,
                    object: window, queue: .main
                ) { [weak self] _ in self?.unpinMenuBar() }
            )
            observers.append(
                NotificationCenter.default.addObserver(
                    forName: NSWindow.didResignKeyNotification,
                    object: window, queue: .main
                ) { [weak self] _ in self?.unpinMenuBar() }
            )
        }

        func stopObserving() {
            for obs in observers { NotificationCenter.default.removeObserver(obs) }
            observers.removeAll()
            observedWindow = nil
        }

        private func pinMenuBar() {
            let current = NSApp.presentationOptions
            if current.contains(.autoHideMenuBar) {
                savedOptions = current
                var opts = current
                opts.remove(.autoHideMenuBar)
                opts.remove(.autoHideDock)
                NSApp.presentationOptions = opts
            }
        }

        func unpinMenuBar() {
            if let saved = savedOptions {
                NSApp.presentationOptions = saved
                savedOptions = nil
            }
            stopObserving()
        }

        deinit { unpinMenuBar() }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.unpinMenuBar()
    }
}
