import SwiftUI

struct SettingsView: View {
    @State private var config: ShortcutConfig
    @State private var recordingAction: ShortcutAction?
    var onConfigChanged: (ShortcutConfig) -> Void

    init(config: ShortcutConfig, onConfigChanged: @escaping (ShortcutConfig) -> Void) {
        self._config = State(initialValue: config)
        self.onConfigChanged = onConfigChanged
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Keyboard Shortcuts")
                .font(.headline)
                .padding(.top, 16)
                .padding(.bottom, 12)

            Divider()

            ScrollView {
                VStack(spacing: 1) {
                    shortcutRow(.newTab)
                    shortcutRow(.releaseTab)
                    shortcutRow(.cycleTab)

                    Divider()
                        .padding(.vertical, 4)

                    ForEach(1...9, id: \.self) { n in
                        shortcutRow(.switchToTab(n))
                    }
                }
                .padding(12)
            }

            Divider()

            HStack {
                Button("Reset to Defaults") {
                    config = .default
                    onConfigChanged(config)
                }
                .controlSize(.small)

                Spacer()

                if recordingAction != nil {
                    Text("Press a key combo (2+ modifiers)…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
        }
        .frame(width: 400, height: 420)
        .background(ShortcutRecorderBridge(
            isRecording: recordingAction != nil,
            onKeyDown: { event in
                guard let action = recordingAction else { return }
                let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue
                let binding = KeyBinding(modifiers: mods, keyCode: event.keyCode)
                updateBinding(for: action, to: binding)
                recordingAction = nil
            },
            onEscape: {
                recordingAction = nil
            }
        ))
    }

    private func shortcutRow(_ action: ShortcutAction) -> some View {
        HStack {
            Text(action.label)
                .frame(maxWidth: .infinity, alignment: .leading)

            let binding = self.binding(for: action)
            let isRecording = recordingAction == action

            Button {
                recordingAction = isRecording ? nil : action
            } label: {
                Text(isRecording ? "Recording…" : binding.displayString)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(isRecording ? .orange : .primary)
                    .frame(minWidth: 100)
                    .padding(.vertical, 3)
                    .padding(.horizontal, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(isRecording
                                  ? Color.orange.opacity(0.1)
                                  : Color.primary.opacity(0.05))
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
    }

    private func binding(for action: ShortcutAction) -> KeyBinding {
        switch action {
        case .newTab: return config.newTab
        case .releaseTab: return config.releaseTab
        case .cycleTab: return config.cycleTab
        case .switchToTab(let n): return config.switchToTab[n - 1]
        }
    }

    private func updateBinding(for action: ShortcutAction, to binding: KeyBinding) {
        // Clear the binding from any other action that already uses it
        clearConflicts(for: action, binding: binding)

        switch action {
        case .newTab: config.newTab = binding
        case .releaseTab: config.releaseTab = binding
        case .cycleTab: config.cycleTab = binding
        case .switchToTab(let n): config.switchToTab[n - 1] = binding
        }
        onConfigChanged(config)
    }

    /// If another action already uses this binding, reset that action to avoid conflicts.
    private func clearConflicts(for action: ShortcutAction, binding: KeyBinding) {
        let unused = KeyBinding(modifiers: 0, keyCode: 0)
        if action != .newTab, config.newTab == binding { config.newTab = unused }
        if action != .releaseTab, config.releaseTab == binding { config.releaseTab = unused }
        if action != .cycleTab, config.cycleTab == binding { config.cycleTab = unused }
        for i in 0..<config.switchToTab.count {
            if action != .switchToTab(i + 1), config.switchToTab[i] == binding {
                config.switchToTab[i] = unused
            }
        }
    }
}

// MARK: - Shortcut Actions

enum ShortcutAction: Equatable {
    case newTab
    case releaseTab
    case cycleTab
    case switchToTab(Int)

    var label: String {
        switch self {
        case .newTab: return "New Tab"
        case .releaseTab: return "Release Tab"
        case .cycleTab: return "Cycle Tabs (MRU)"
        case .switchToTab(let n): return "Switch to Tab \(n)"
        }
    }
}

// MARK: - NSEvent Bridge for Shortcut Recording

/// Hosts an invisible NSView that captures key events for shortcut recording.
struct ShortcutRecorderBridge: NSViewRepresentable {
    var isRecording: Bool
    var onKeyDown: (NSEvent) -> Void
    var onEscape: () -> Void

    func makeNSView(context: Context) -> ShortcutRecorderView {
        let view = ShortcutRecorderView()
        view.onKeyDown = onKeyDown
        view.onEscape = onEscape
        return view
    }

    func updateNSView(_ nsView: ShortcutRecorderView, context: Context) {
        nsView.isRecording = isRecording
        nsView.onKeyDown = onKeyDown
        nsView.onEscape = onEscape
        if isRecording {
            DispatchQueue.main.async {
                nsView.window?.makeFirstResponder(nsView)
            }
        }
    }
}

class ShortcutRecorderView: NSView {
    var isRecording = false
    var onKeyDown: ((NSEvent) -> Void)?
    var onEscape: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }
        if event.keyCode == 53 { // Escape
            onEscape?()
            return
        }
        // Require at least 2 modifiers to avoid conflicts with normal typing
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let modCount = [
            mods.contains(.command), mods.contains(.control),
            mods.contains(.option), mods.contains(.shift),
        ].filter { $0 }.count
        guard modCount >= 2 else { return }
        onKeyDown?(event)
    }
}
