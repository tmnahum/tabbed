import AppKit
import SwiftUI

/// Floating overlay panel for the quick switcher (both global and within-group).
class SwitcherPanel: NSPanel {

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.level = .floating
        self.isFloatingPanel = true
        self.becomesKeyOnlyIfNeeded = true
        self.hidesOnDeactivate = false
        self.isOpaque = false
        self.backgroundColor = .clear
        self.isMovableByWindowBackground = false
        self.acceptsMouseMovedEvents = true
        self.animationBehavior = .none
        self.collectionBehavior = [.transient, .ignoresCycle, .canJoinAllSpaces]
    }

    /// Show centered on the screen containing the mouse cursor.
    func showCentered() {
        guard let screen = NSScreen.screens.first(where: {
            NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
        }) ?? NSScreen.main else { return }

        let panelFrame = self.frame
        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - panelFrame.width / 2
        let y = screenFrame.midY - panelFrame.height / 2
        self.setFrameOrigin(NSPoint(x: x, y: y))
        self.orderFrontRegardless()
    }

    func dismiss() {
        self.orderOut(nil)
    }
}
