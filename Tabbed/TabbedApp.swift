import SwiftUI

@main
struct TabbedApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra("Tabbed", systemImage: "rectangle.stack") {
            MenuBarView(
                groupManager: appDelegate.groupManager,
                onNewGroup: { appDelegate.showWindowPicker() },
                onFocusWindow: { window in appDelegate.focusWindow(window) },
                onDisbandGroup: { group in appDelegate.disbandGroup(group) },
                onSettings: { appDelegate.showSettings() },
                onQuit: {
                    appDelegate.isExplicitQuit = true
                    NSApplication.shared.terminate(nil)
                }
            )
        }
        .menuBarExtraStyle(.window)
    }
}
