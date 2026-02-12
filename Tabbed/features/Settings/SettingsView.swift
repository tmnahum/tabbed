import SwiftUI
import ServiceManagement

enum SettingsTab: Int {
    case general, launcher, tabBar, shortcuts, switcher

    var contentHeight: CGFloat {
        switch self {
        case .general:   return 390
        case .launcher:  return 420
        case .tabBar:    return 330
        case .shortcuts: return 520
        case .switcher:  return 430
        }
    }
}

struct SettingsView: View {
    static let contentWidth: CGFloat = 560

    @State private var config: ShortcutConfig
    @State private var sessionConfig: SessionConfig
    @State private var switcherConfig: SwitcherConfig
    @State private var launcherConfig: AddWindowLauncherConfig
    @ObservedObject var tabBarConfig: TabBarConfig
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var recordingAction: ShortcutAction?
    @State private var selectedTab: SettingsTab = .general
    @State private var manualProviderError: String?
    private let browserProviderResolver = BrowserProviderResolver()
    var onConfigChanged: (ShortcutConfig) -> Void
    var onSessionConfigChanged: (SessionConfig) -> Void
    var onSwitcherConfigChanged: (SwitcherConfig) -> Void
    var onLauncherConfigChanged: (AddWindowLauncherConfig) -> Void

    init(
        config: ShortcutConfig,
        sessionConfig: SessionConfig,
        switcherConfig: SwitcherConfig,
        launcherConfig: AddWindowLauncherConfig,
        tabBarConfig: TabBarConfig,
        onConfigChanged: @escaping (ShortcutConfig) -> Void,
        onSessionConfigChanged: @escaping (SessionConfig) -> Void,
        onSwitcherConfigChanged: @escaping (SwitcherConfig) -> Void,
        onLauncherConfigChanged: @escaping (AddWindowLauncherConfig) -> Void
    ) {
        self._config = State(initialValue: config)
        self._sessionConfig = State(initialValue: sessionConfig)
        self._switcherConfig = State(initialValue: switcherConfig)
        self._launcherConfig = State(initialValue: launcherConfig)
        self.tabBarConfig = tabBarConfig
        self.onConfigChanged = onConfigChanged
        self.onSessionConfigChanged = onSessionConfigChanged
        self.onSwitcherConfigChanged = onSwitcherConfigChanged
        self.onLauncherConfigChanged = onLauncherConfigChanged
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            generalTab
                .tabItem { Label("General", systemImage: "gear") }
                .tag(SettingsTab.general)
            launcherTab
                .tabItem { Label("Launcher", systemImage: "magnifyingglass") }
                .tag(SettingsTab.launcher)
            tabBarTab
                .tabItem { Label("Tab Bar", systemImage: "paintbrush") }
                .tag(SettingsTab.tabBar)
            shortcutsTab
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
                .tag(SettingsTab.shortcuts)
            switcherTab
                .tabItem { Label("Switcher", systemImage: "rectangle.grid.1x2") }
                .tag(SettingsTab.switcher)
        }
        .frame(width: Self.contentWidth)
        .onChange(of: selectedTab) { _ in
            resizeWindowToFit()
        }
        .onChange(of: sessionConfig.restoreMode) { _ in
            onSessionConfigChanged(sessionConfig)
        }
        .onChange(of: sessionConfig.autoCaptureMode) { _ in
            onSessionConfigChanged(sessionConfig)
        }
        .onChange(of: sessionConfig.autoCaptureUnmatchedToNewGroup) { _ in
            onSessionConfigChanged(sessionConfig)
        }
        .onChange(of: switcherConfig.globalStyle) { _ in
            onSwitcherConfigChanged(switcherConfig)
        }
        .onChange(of: switcherConfig.tabCycleStyle) { _ in
            onSwitcherConfigChanged(switcherConfig)
        }
        .onChange(of: switcherConfig.namedGroupLabelMode) { _ in
            onSwitcherConfigChanged(switcherConfig)
        }
        .onChange(of: launcherConfig.urlLaunchEnabled) { _ in
            onLauncherConfigChanged(launcherConfig)
        }
        .onChange(of: launcherConfig.searchLaunchEnabled) { _ in
            onLauncherConfigChanged(launcherConfig)
        }
        .onChange(of: launcherConfig.providerMode) { _ in
            onLauncherConfigChanged(launcherConfig)
        }
        .onChange(of: launcherConfig.searchEngine) { _ in
            onLauncherConfigChanged(launcherConfig)
        }
        .onChange(of: launcherConfig.customSearchTemplate) { _ in
            onLauncherConfigChanged(launcherConfig)
        }
        .onChange(of: launcherConfig.manualSelection.bundleID) { _ in
            onLauncherConfigChanged(launcherConfig)
        }
        .onChange(of: launcherConfig.manualSelection.engine) { _ in
            onLauncherConfigChanged(launcherConfig)
        }
        // tabBarConfig auto-saves via didSet on its properties
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

            Text("Capture New Windows")
                .font(.headline)
                .padding(.top, 16)
                .padding(.bottom, 8)

            Picker("Mode", selection: $sessionConfig.autoCaptureMode) {
                Text("Never").tag(AutoCaptureMode.never)
                Text("Always").tag(AutoCaptureMode.always)
                Text("When Maximized").tag(AutoCaptureMode.whenMaximized)
                Text("When Only Group").tag(AutoCaptureMode.whenOnly)
                Text("Maximized or Only").tag(AutoCaptureMode.whenMaximizedOrOnly)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)

            Text(autoCaptureModeDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.top, 4)
                .padding(.bottom, 12)

            Toggle(isOn: $sessionConfig.autoCaptureUnmatchedToNewGroup) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Create One-Tab Group for Unmatched Windows")
                    Text("If a new window can’t join an existing group, create a new group containing only that window.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.checkbox)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
            .disabled(sessionConfig.autoCaptureMode == .never)

            Spacer()
        }
    }

    // MARK: - Tab Bar Tab

    private var launcherTab: some View {
        ScrollView {
            VStack(spacing: 0) {
                Toggle(isOn: $launcherConfig.urlLaunchEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Enable Open URL Action")
                        Text("Show an \"Open URL\" candidate in Add Window when query looks like a URL.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .padding(.top, 8)

                Divider()

                Toggle(isOn: $launcherConfig.searchLaunchEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Enable Web Search Action")
                        Text("Show a \"Web Search\" candidate in Add Window when query is non-empty.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Browser Provider")
                        .font(.headline)

                    Picker("Mode", selection: $launcherConfig.providerMode) {
                        Text("Auto").tag(BrowserProviderMode.auto)
                        Text("Manual").tag(BrowserProviderMode.manual)
                    }
                    .pickerStyle(.segmented)

                    Text(providerDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 10)

                if launcherConfig.providerMode == .manual {
                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Manual Provider")
                            .font(.headline)

                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 10) {
                                manualProviderIcon
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 30, height: 30)
                                    .padding(6)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .fill(Color(nsColor: .windowBackgroundColor))
                                    )

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(manualProviderNameText)
                                        .font(.subheadline.weight(.semibold))

                                    if launcherConfig.hasManualSelection {
                                        Text(manualProviderBundleIDText)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .textSelection(.enabled)
                                            .lineLimit(1)
                                    } else {
                                        Text("Select a browser app to use for URL and web search actions.")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                Spacer()
                            }

                            HStack(spacing: 8) {
                                Button(launcherConfig.hasManualSelection ? "Change Browser App…" : "Choose Browser App…") {
                                    chooseManualBrowserApp()
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)

                                if launcherConfig.hasManualSelection {
                                    Button("Clear") {
                                        launcherConfig.manualSelection.bundleID = ""
                                        manualProviderError = nil
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }

                            if let manualProviderError {
                                Text(manualProviderError)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color(nsColor: .controlBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                        )

                        Picker("Engine", selection: $launcherConfig.manualSelection.engine) {
                            Text("Chromium").tag(BrowserEngine.chromium)
                            Text("Firefox").tag(BrowserEngine.firefox)
                            Text("Safari").tag(BrowserEngine.safari)
                        }
                        .pickerStyle(.segmented)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Search Provider")
                        .font(.headline)

                    Picker("Provider", selection: $launcherConfig.searchEngine) {
                        ForEach(SearchEngine.commonProviders, id: \.rawValue) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                        Divider()
                        ForEach(SearchEngine.aiProviders, id: \.rawValue) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                        Divider()
                        Text(SearchEngine.custom.displayName).tag(SearchEngine.custom)
                    }
                    .pickerStyle(.menu)
                    .disabled(!launcherConfig.searchLaunchEnabled)

                    Text(searchProviderDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if launcherConfig.searchEngine == .custom {
                        TextField(
                            "https://example.com/search?q=%s",
                            text: $launcherConfig.customSearchTemplate
                        )
                        .textFieldStyle(.roundedBorder)
                        .disabled(!launcherConfig.searchLaunchEnabled)

                        if let customSearchTemplateValidationMessage {
                            Text(customSearchTemplateValidationMessage)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 16)
            }
        }
    }

    private var tabBarTab: some View {
        VStack(spacing: 0) {
            Text("Tab Bar Style")
                .font(.headline)
                .padding(.top, 16)
                .padding(.bottom, 4)

            Text("Choose how tabs are laid out in the tab bar.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)

            Picker("Style", selection: $tabBarConfig.style) {
                Text("Equal Width").tag(TabBarStyle.equal)
                Text("Compact").tag(TabBarStyle.compact)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)

            Text(tabBarStyleDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.top, 4)
                .padding(.bottom, 12)

            Divider()

            Toggle(isOn: $tabBarConfig.showDragHandle) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show Drag Handle")
                    Text("Adds a grip area on the left for dragging the tab bar.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.checkbox)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            Toggle(isOn: $tabBarConfig.showTooltip) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show Title Tooltip")
                    Text("Shows the full window title on hover when tabs are narrow.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.checkbox)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            VStack(spacing: 0) {
                Text("Tab Close Button")
                    .font(.headline)
                    .padding(.top, 12)
                    .padding(.bottom, 4)

                Picker("Close Button", selection: $tabBarConfig.closeButtonMode) {
                    Text("X on All Tabs").tag(TabCloseButtonMode.xmarkOnAllTabs)
                    Text("- on Current, X on Others").tag(TabCloseButtonMode.minusOnCurrentTab)
                    Text("- on All Tabs").tag(TabCloseButtonMode.minusOnAllTabs)
                }
                .pickerStyle(.menu)
                .padding(.horizontal, 12)

                Text(closeButtonModeDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
                    .padding(.bottom, 8)

                Toggle(isOn: $tabBarConfig.showCloseConfirmation) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show ? Confirmation on X")
                        Text("When enabled, X requires a second click to close.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }

            Spacer()
        }
    }

    // MARK: - Shortcuts Tab

    private var shortcutsTab: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 1) {
                    shortcutRow(.newTab)
                    shortcutRow(.releaseTab)
                    shortcutRow(.closeTab)
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

    private var tabBarStyleDescription: String {
        switch tabBarConfig.style {
        case .equal:
            return "Tabs expand to fill the entire bar width equally."
        case .compact:
            return "Tabs are left-aligned with a maximum width, like browser tabs."
        }
    }

    private var closeButtonModeDescription: String {
        switch tabBarConfig.closeButtonMode {
        case .xmarkOnAllTabs:
            return "Default: all tabs show X on hover."
        case .minusOnCurrentTab:
            return "Current tab shows -, other tabs show X."
        case .minusOnAllTabs:
            return "All tabs show - on hover."
        }
    }

    // MARK: - Switcher Tab

    private var switcherTab: some View {
        VStack(spacing: 0) {
            switcherStyleSection(
                title: "Global Switcher",
                description: "Switches between all windows and tab groups.",
                selection: $switcherConfig.globalStyle,
                shortcutAction: .globalSwitcher
            )

            Divider()

            namedGroupLabelSection

            Divider()

            switcherStyleSection(
                title: "Tab Cycling",
                description: "Cycles through tabs within the active group.",
                selection: $switcherConfig.tabCycleStyle,
                shortcutAction: .cycleTab
            )

            Spacer()
        }
    }

    private var namedGroupLabelSection: some View {
        VStack(spacing: 0) {
            Text("Named Group Labels")
                .font(.headline)
                .padding(.top, 16)
                .padding(.bottom, 4)

            Text("Choose how named tab groups appear in the global switcher.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)

            Picker("Format", selection: $switcherConfig.namedGroupLabelMode) {
                Text("Group Name Only").tag(NamedGroupLabelMode.groupNameOnly)
                Text("Group - App - Window").tag(NamedGroupLabelMode.groupAppWindow)
            }
            .pickerStyle(.menu)
            .padding(.horizontal, 12)

            Text(namedGroupLabelDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.top, 4)
                .padding(.bottom, 12)
        }
    }

    private func switcherStyleSection(title: String, description: String, selection: Binding<SwitcherStyle>, shortcutAction: ShortcutAction? = nil) -> some View {
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
                .padding(.bottom, 8)

            if let action = shortcutAction {
                shortcutRow(action)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }
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

    private var namedGroupLabelDescription: String {
        switch switcherConfig.namedGroupLabelMode {
        case .groupNameOnly:
            return "Show only the group name for named groups."
        case .groupAppWindow:
            return "Show group name first, then app name and window title."
        }
    }

    private var autoCaptureModeDescription: String {
        switch sessionConfig.autoCaptureMode {
        case .never:
            return "New windows are never automatically added to groups."
        case .always:
            return "New windows join the most recently used group."
        case .whenMaximized:
            return "New windows join a group when it fills the screen."
        case .whenOnly:
            return "New windows join a group when it's the only one in the space."
        case .whenMaximizedOrOnly:
            return "New windows join a group when it fills the screen or when it's the only one in the space."
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

    private var providerDescription: String {
        switch launcherConfig.providerMode {
        case .auto:
            return "Auto prefers Helium, then known Chromium providers, then Firefox providers, then Safari."
        case .manual:
            return "Manual uses the browser app you select and a matching engine adapter."
        }
    }

    private var searchProviderDescription: String {
        if launcherConfig.searchEngine == .custom {
            return "Use %s as a placeholder for the typed query."
        }
        return "Choose a default web search provider for Add Window search actions."
    }

    private var customSearchTemplateValidationMessage: String? {
        guard launcherConfig.searchEngine == .custom else { return nil }
        guard !launcherConfig.isCustomSearchTemplateValid else { return nil }
        return "Custom template must include %s, for example: https://example.com/search?q=%s"
    }

    private var manualProviderBundleIDText: String {
        launcherConfig.manualSelection.bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var manualProviderNameText: String {
        guard launcherConfig.hasManualSelection else {
            return "No browser selected."
        }

        let bundleID = manualProviderBundleIDText
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return appURL.deletingPathExtension().lastPathComponent
        }
        return bundleID
    }

    private var manualProviderIcon: Image {
        guard launcherConfig.hasManualSelection else {
            if let fallback = NSImage(systemSymbolName: "globe", accessibilityDescription: nil) {
                return Image(nsImage: fallback)
            }
            return Image(systemName: "globe")
        }

        let bundleID = manualProviderBundleIDText
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
        }

        if let fallback = NSImage(systemSymbolName: "app", accessibilityDescription: nil) {
            return Image(nsImage: fallback)
        }
        return Image(systemName: "app")
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

            Button {
                let unbound = KeyBinding(modifiers: 0, keyCode: 0)
                updateBinding(for: action, to: unbound)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .opacity(binding.isUnbound ? 0 : 1)
            .disabled(binding.isUnbound)
            .help("Disable this shortcut")
        }
        .padding(.vertical, 2)
    }

    private func binding(for action: ShortcutAction) -> KeyBinding {
        switch action {
        case .newTab: return config.newTab
        case .releaseTab: return config.releaseTab
        case .closeTab: return config.closeTab
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
        case .closeTab: config.closeTab = binding
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
        if action != .closeTab, config.closeTab == binding { config.closeTab = unused }
        if action != .groupAllInSpace, config.groupAllInSpace == binding { config.groupAllInSpace = unused }
        if action != .cycleTab, config.cycleTab == binding { config.cycleTab = unused }
        if action != .globalSwitcher, config.globalSwitcher == binding { config.globalSwitcher = unused }
        for i in 0..<config.switchToTab.count {
            if action != .switchToTab(i + 1), config.switchToTab[i] == binding {
                config.switchToTab[i] = unused
            }
        }
    }

    private func resizeWindowToFit() {
        guard let window = NSApp.windows.first(where: { $0.title == "Tabbed Settings" }) else { return }
        let newHeight = selectedTab.contentHeight
        var frame = window.frame
        let contentHeight = window.contentRect(forFrameRect: frame).height
        let chrome = frame.height - contentHeight
        let targetHeight = newHeight + chrome
        let delta = targetHeight - frame.height
        frame.origin.y -= delta
        frame.size.height = targetHeight
        window.setFrame(frame, display: true)
    }

    private func chooseManualBrowserApp() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedFileTypes = ["app"]
        panel.allowsOtherFileTypes = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.prompt = "Choose Browser"
        panel.message = "Select a browser app for URL and web search actions."

        guard panel.runModal() == .OK, let appURL = panel.url else { return }
        applyManualProviderSelection(appURL: appURL)
    }

    private func applyManualProviderSelection(appURL: URL) {
        guard let bundleID = Bundle(url: appURL)?.bundleIdentifier else {
            manualProviderError = "Could not read a bundle identifier from the selected app."
            return
        }

        launcherConfig.manualSelection = browserProviderResolver.manualSelection(
            forBundleID: bundleID,
            fallbackEngine: launcherConfig.manualSelection.engine
        )
        manualProviderError = nil
    }
}

// MARK: - Shortcut Actions

enum ShortcutAction: Equatable {
    case newTab
    case releaseTab
    case closeTab
    case groupAllInSpace
    case cycleTab
    case globalSwitcher
    case switchToTab(Int)

    var label: String {
        switch self {
        case .newTab: return "New Tab / New Group"
        case .releaseTab: return "Release Tab"
        case .closeTab: return "Close Tab"
        case .groupAllInSpace: return "Group All in Space"
        case .cycleTab: return "Cycle Tabs (MRU)"
        case .globalSwitcher: return "Global Switcher"
        case .switchToTab(let n): return n == 9 ? "Switch to Last Tab" : "Switch to Tab \(n)"
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
