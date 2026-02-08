import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @State private var config: ShortcutConfig
    @State private var sessionConfig: SessionConfig
    @State private var switcherConfig: SwitcherConfig
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var recordingAction: ShortcutAction?
    var onConfigChanged: (ShortcutConfig) -> Void
    var onSessionConfigChanged: (SessionConfig) -> Void
    var onSwitcherConfigChanged: (SwitcherConfig) -> Void

    init(
        config: ShortcutConfig,
        sessionConfig: SessionConfig,
        switcherConfig: SwitcherConfig,
        onConfigChanged: @escaping (ShortcutConfig) -> Void,
        onSessionConfigChanged: @escaping (SessionConfig) -> Void,
        onSwitcherConfigChanged: @escaping (SwitcherConfig) -> Void
    ) {
        self._config = State(initialValue: config)
        self._sessionConfig = State(initialValue: sessionConfig)
        self._switcherConfig = State(initialValue: switcherConfig)
        self.onConfigChanged = onConfigChanged
        self.onSessionConfigChanged = onSessionConfigChanged
        self.onSwitcherConfigChanged = onSwitcherConfigChanged
    }

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gear") }
            switcherTab
                .tabItem { Label("Switcher", systemImage: "rectangle.grid.1x2") }
        }
        .frame(width: 400, height: 540)
        .onChange(of: sessionConfig.restoreMode) { _ in
            onSessionConfigChanged(sessionConfig)
        }
        .onChange(of: sessionConfig.autoCaptureEnabled) { _ in
            onSessionConfigChanged(sessionConfig)
        }
        .onChange(of: switcherConfig.globalStyle) { _ in
            onSwitcherConfigChanged(switcherConfig)
        }
        .onChange(of: switcherConfig.tabCycleStyle) { _ in
            onSwitcherConfigChanged(switcherConfig)
        }
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

    // MARK: - General Tab

    private var generalTab: some View {
        VStack(spacing: 0) {
            Toggle(isOn: $launchAtLogin) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Start at Login")
                    Text("Automatically launch Tabbed when you log in.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .padding(.top, 8)
            .onChange(of: launchAtLogin) { newValue in
                do {
                    if newValue {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    launchAtLogin = !newValue
                }
            }

            Divider()

            Text("Session Restore")
                .font(.headline)
                .padding(.top, 16)
                .padding(.bottom, 8)

            Picker("On Launch", selection: $sessionConfig.restoreMode) {
                Text("Smart").tag(RestoreMode.smart)
                Text("Always").tag(RestoreMode.always)
                Text("Off").tag(RestoreMode.off)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)

            Text(restoreModeDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.top, 4)
                .padding(.bottom, 12)

            Divider()

            Toggle(isOn: $sessionConfig.autoCaptureEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Capture new windows when maximized")
                    Text("When a group fills the screen and owns all visible windows, new windows auto-join.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            Text("Keyboard Shortcuts")
                .font(.headline)
                .padding(.top, 12)
                .padding(.bottom, 8)

            Divider()

            ScrollView {
                VStack(spacing: 1) {
                    shortcutRow(.newTab)
                    shortcutRow(.releaseTab)
                    shortcutRow(.groupAllInSpace)
                    shortcutRow(.cycleTab)
                    shortcutRow(.globalSwitcher)

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
                    Text("Press a key combo…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
        }
    }

    // MARK: - Switcher Tab

    private var switcherTab: some View {
        VStack(spacing: 0) {
            switcherStyleSection(
                title: "Global Switcher",
                description: "Switches between all windows and tab groups.",
                selection: $switcherConfig.globalStyle
            )

            Divider()

            switcherStyleSection(
                title: "Tab Cycling",
                description: "Cycles through tabs within the active group.",
                selection: $switcherConfig.tabCycleStyle
            )

            Spacer()
        }
    }

    private func switcherStyleSection(title: String, description: String, selection: Binding<SwitcherStyle>) -> some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.headline)
                .padding(.top, 16)
                .padding(.bottom, 4)

            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)

            Picker("Style", selection: selection) {
                Text("App Icons").tag(SwitcherStyle.appIcons)
                Text("Titles").tag(SwitcherStyle.titles)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)

            Text(styleDescription(for: selection.wrappedValue))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.top, 4)
                .padding(.bottom, 12)
        }
    }

    private func styleDescription(for style: SwitcherStyle) -> String {
        switch style {
        case .appIcons:
            return "Large icons in a horizontal row, like macOS Cmd+Tab."
        case .titles:
            return "Vertical list with app name, window title, and window count."
        }
    }

    private var restoreModeDescription: String {
        switch sessionConfig.restoreMode {
        case .smart:
            return "Restore groups when all their apps are still running."
        case .always:
            return "Always restore groups, even if some windows are missing."
        case .off:
            return "Never auto-restore. Use the menu bar button to restore manually."
        }
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
        case .groupAllInSpace: return config.groupAllInSpace
        case .cycleTab: return config.cycleTab
        case .globalSwitcher: return config.globalSwitcher
        case .switchToTab(let n): return config.switchToTab[n - 1]
        }
    }

    private func updateBinding(for action: ShortcutAction, to binding: KeyBinding) {
        // Clear the binding from any other action that already uses it
        clearConflicts(for: action, binding: binding)

        switch action {
        case .newTab: config.newTab = binding
        case .releaseTab: config.releaseTab = binding
        case .groupAllInSpace: config.groupAllInSpace = binding
        case .cycleTab: config.cycleTab = binding
        case .globalSwitcher: config.globalSwitcher = binding
        case .switchToTab(let n): config.switchToTab[n - 1] = binding
        }
        onConfigChanged(config)
    }

    /// If another action already uses this binding, reset that action to avoid conflicts.
    private func clearConflicts(for action: ShortcutAction, binding: KeyBinding) {
        let unused = KeyBinding(modifiers: 0, keyCode: 0)
        if action != .newTab, config.newTab == binding { config.newTab = unused }
        if action != .releaseTab, config.releaseTab == binding { config.releaseTab = unused }
        if action != .groupAllInSpace, config.groupAllInSpace == binding { config.groupAllInSpace = unused }
        if action != .cycleTab, config.cycleTab == binding { config.cycleTab = unused }
        if action != .globalSwitcher, config.globalSwitcher == binding { config.globalSwitcher = unused }
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
    case groupAllInSpace
    case cycleTab
    case globalSwitcher
    case switchToTab(Int)

    var label: String {
        switch self {
        case .newTab: return "New Tab / New Group"
        case .releaseTab: return "Release Tab"
        case .groupAllInSpace: return "Group All in Space"
        case .cycleTab: return "Cycle Tabs (MRU)"
        case .globalSwitcher: return "Global Switcher"
        case .switchToTab(let n): return "Switch to Tab \(n)"
        }
    }
}

// MARK: - CGEvent Tap Callback for Shortcut Recording (file-scope)

private func recorderEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let view = Unmanaged<ShortcutRecorderView>.fromOpaque(userInfo).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = view.recorderTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        return Unmanaged.passUnretained(event)
    }

    guard type == .keyDown, let nsEvent = NSEvent(cgEvent: event) else {
        return Unmanaged.passUnretained(event)
    }

    guard view.isRecording else { return Unmanaged.passUnretained(event) }

    if nsEvent.keyCode == 53 { // Escape
        view.onEscape?()
        return nil
    }

    let mods = nsEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
    guard !mods.isEmpty else { return Unmanaged.passUnretained(event) }

    view.onKeyDown?(nsEvent)
    return nil // suppress
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
        nsView.onKeyDown = onKeyDown
        nsView.onEscape = onEscape
        let wasRecording = nsView.isRecording
        nsView.isRecording = isRecording
        if isRecording {
            if !wasRecording {
                nsView.installRecorderTap()
            }
            DispatchQueue.main.async {
                nsView.window?.makeFirstResponder(nsView)
            }
        } else if wasRecording {
            nsView.removeRecorderTap()
        }
    }
}

class ShortcutRecorderView: NSView {
    var isRecording = false
    var onKeyDown: ((NSEvent) -> Void)?
    var onEscape: (() -> Void)?
    fileprivate var recorderTap: CFMachPort?
    private var recorderRunLoopSource: CFRunLoopSource?
    private var retainedSelf: Unmanaged<ShortcutRecorderView>?

    override var acceptsFirstResponder: Bool { true }

    deinit {
        removeRecorderTap()
    }

    func installRecorderTap() {
        guard recorderTap == nil else { return } // idempotent

        let eventMask: CGEventMask = 1 << CGEventType.keyDown.rawValue
        retainedSelf = Unmanaged.passRetained(self)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: recorderEventTapCallback,
            userInfo: retainedSelf!.toOpaque()
        ) else {
            retainedSelf?.release()
            retainedSelf = nil
            return
        }

        recorderTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        recorderRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func removeRecorderTap() {
        if let tap = recorderTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = recorderRunLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
                recorderRunLoopSource = nil
            }
            CFMachPortInvalidate(tap)
            recorderTap = nil
        }
        if let retained = retainedSelf {
            retained.release()
            retainedSelf = nil
        }
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }
        if event.keyCode == 53 { // Escape
            onEscape?()
            return
        }
        // Require at least one modifier key
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !mods.isEmpty else { return }
        onKeyDown?(event)
    }
}
