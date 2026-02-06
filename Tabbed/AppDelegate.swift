import AppKit
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    let windowManager = WindowManager()
    let groupManager = GroupManager()

    private var windowPickerPanel: NSPanel?
    private var tabBarPanels: [UUID: TabBarPanel] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !AXIsProcessTrusted() {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Expand all grouped windows upward to reclaim tab bar space
        let tabBarHeight = TabBarPanel.tabBarHeight
        for group in groupManager.groups {
            for window in group.windows {
                if let frame = AccessibilityHelper.getFrame(of: window.element) {
                    let expandedFrame = CGRect(
                        x: frame.origin.x,
                        y: frame.origin.y - tabBarHeight,
                        width: frame.width,
                        height: frame.height + tabBarHeight
                    )
                    AccessibilityHelper.setFrame(of: window.element, to: expandedFrame)
                }
            }
        }
        for (_, panel) in tabBarPanels {
            panel.close()
        }
        tabBarPanels.removeAll()
        groupManager.dissolveAllGroups()
    }

    // MARK: - Window Picker

    func showWindowPicker(addingTo group: TabGroup? = nil) {
        dismissWindowPicker()
        windowManager.refreshWindowList()

        let picker = WindowPickerView(
            windowManager: windowManager,
            groupManager: groupManager,
            onCreateGroup: { [weak self] windows in
                self?.createGroup(with: windows)
                self?.dismissWindowPicker()
            },
            onAddToGroup: { [weak self] window in
                guard let group = group else { return }
                self?.addWindow(window, to: group)
                self?.dismissWindowPicker()
            },
            onDismiss: { [weak self] in
                self?.dismissWindowPicker()
            },
            addingToGroup: group
        )

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 350, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.contentView = NSHostingView(rootView: picker)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        windowPickerPanel = panel
    }

    private func dismissWindowPicker() {
        windowPickerPanel?.close()
        windowPickerPanel = nil
    }

    // MARK: - Group Lifecycle

    private func createGroup(with windows: [WindowInfo]) {
        guard let first = windows.first,
              let firstFrame = AccessibilityHelper.getFrame(of: first.element) else { return }

        let tabBarHeight = TabBarPanel.tabBarHeight
        let windowFrame = CGRect(
            x: firstFrame.origin.x,
            y: firstFrame.origin.y + tabBarHeight,
            width: firstFrame.width,
            height: firstFrame.height - tabBarHeight
        )

        guard let group = groupManager.createGroup(with: windows, frame: windowFrame) else { return }

        // Sync all windows to same frame
        for window in group.windows {
            AccessibilityHelper.setFrame(of: window.element, to: windowFrame)
        }

        // Raise the first window
        AccessibilityHelper.raise(group.windows[0].element)

        // Create and show tab bar
        let panel = TabBarPanel()
        panel.setContent(
            group: group,
            onSwitchTab: { [weak self, weak panel] index in
                guard let panel else { return }
                self?.switchTab(in: group, to: index, panel: panel)
            },
            onReleaseTab: { [weak self, weak panel] index in
                guard let panel else { return }
                self?.releaseTab(at: index, from: group, panel: panel)
            },
            onAddWindow: { [weak self] in
                self?.showWindowPicker(addingTo: group)
            }
        )

        tabBarPanels[group.id] = panel

        if let activeWindow = group.activeWindow {
            panel.show(above: windowFrame, windowID: activeWindow.id)
        }
    }

    private func switchTab(in group: TabGroup, to index: Int, panel: TabBarPanel) {
        group.switchTo(index: index)
        guard let window = group.activeWindow else { return }
        AccessibilityHelper.raise(window.element)
        panel.orderAbove(windowID: window.id)
    }

    private func releaseTab(at index: Int, from group: TabGroup, panel: TabBarPanel) {
        guard let window = group.windows[safe: index] else { return }

        let tabBarHeight = TabBarPanel.tabBarHeight

        // Expand window upward into tab bar area
        if let frame = AccessibilityHelper.getFrame(of: window.element) {
            let expandedFrame = CGRect(
                x: frame.origin.x,
                y: frame.origin.y - tabBarHeight,
                width: frame.width,
                height: frame.height + tabBarHeight
            )
            AccessibilityHelper.setFrame(of: window.element, to: expandedFrame)
        }

        groupManager.releaseWindow(withID: window.id, from: group)

        // If group was dissolved, remove the panel
        if !groupManager.groups.contains(where: { $0.id == group.id }) {
            panel.close()
            tabBarPanels.removeValue(forKey: group.id)
        }
    }

    private func addWindow(_ window: WindowInfo, to group: TabGroup) {
        AccessibilityHelper.setFrame(of: window.element, to: group.frame)
        groupManager.addWindow(window, to: group)
    }
}

// Safe array subscript
extension Array {
    subscript(safe index: Int) -> Element? {
        index >= 0 && index < count ? self[index] : nil
    }
}
