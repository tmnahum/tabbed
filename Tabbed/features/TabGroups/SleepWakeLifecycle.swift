import AppKit

// MARK: - Sleep/Wake Lifecycle

extension AppDelegate {

    static let wakeRecoveryDelay: TimeInterval = 0.8

    @objc func handleSystemWillSleep(_ notification: Notification) {
        Logger.log("[LIFECYCLE] System will sleep")
    }

    @objc func handleSystemDidWake(_ notification: Notification) {
        Logger.log("[LIFECYCLE] System did wake")
        scheduleWakeRecovery()
    }

    /// Delay wake recovery slightly so WindowServer and AX settle first.
    func scheduleWakeRecovery() {
        wakeRecoveryWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.runWakeRecovery()
        }
        wakeRecoveryWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.wakeRecoveryDelay, execute: work)
    }

    private func runWakeRecovery() {
        wakeRecoveryWorkItem = nil
        Logger.log("[LIFECYCLE] Running wake recovery")

        // Rebuild auto-capture observers after wake; AX observers can become stale.
        deactivateAutoCapture()
        evaluateAutoCapture()

        // Refresh cached discovery and re-evaluate space membership once display/space
        // state is stable.
        windowInventory.refreshAsync()
        scheduleSpaceChangeCheck()
    }
}
