import AppKit

/// ObservableObject wrapper for the window picker UI.
/// All actual window detection lives in `WindowDiscovery`.
class WindowManager: ObservableObject {
    @Published var availableWindows: [WindowInfo] = []

    /// Refreshes the window picker list (current space, sorted alphabetically).
    func refreshWindowList() {
        availableWindows = WindowDiscovery.currentSpace().sorted {
            if $0.appName != $1.appName { return $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }
}
