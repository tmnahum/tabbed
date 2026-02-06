import SwiftUI

@main
struct TabbedApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra("Tabbed", systemImage: "rectangle.stack") {
            MenuBarView(
                groupManager: appDelegate.groupManager,
                onNewGroup: { appDelegate.showWindowPicker() },
                onQuit: { NSApplication.shared.terminate(nil) }
            )
        }
    }
}
