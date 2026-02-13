import SwiftUI

final class AddWindowPaletteViewModel: ObservableObject {
    typealias ContextProvider = () -> LauncherQueryContext
    typealias ActionExecutor = (_ action: LauncherAction, _ context: LauncherQueryContext, _ completion: @escaping (LaunchAttemptResult) -> Void) -> Void

    @Published var query: String = ""
    @Published private(set) var candidates: [LauncherCandidate] = []
    @Published private(set) var selectedCandidateID: String?
    @Published var statusMessage: String?
    @Published var isExecuting = false

    private let launcherEngine: LauncherEngine
    private let contextProvider: ContextProvider
    private let actionExecutor: ActionExecutor
    private let dismiss: () -> Void
    private let notificationCenter: NotificationCenter

    private var context: LauncherQueryContext
    private var debounceWorkItem: DispatchWorkItem?
    private var historyObserver: NSObjectProtocol?

    init(
        launcherEngine: LauncherEngine,
        contextProvider: @escaping ContextProvider,
        actionExecutor: @escaping ActionExecutor,
        dismiss: @escaping () -> Void,
        notificationCenter: NotificationCenter = .default
    ) {
        self.launcherEngine = launcherEngine
        self.contextProvider = contextProvider
        self.actionExecutor = actionExecutor
        self.dismiss = dismiss
        self.notificationCenter = notificationCenter
        self.context = contextProvider()
        historyObserver = notificationCenter.addObserver(
            forName: LauncherHistoryStore.didUpdateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshSources()
        }
        rerankNow()
    }

    deinit {
        if let historyObserver {
            notificationCenter.removeObserver(historyObserver)
        }
    }

    var modeTitle: String {
        context.mode.isAddToGroup ? "Add To Group" : "New Group"
    }

    var sectionedCandidates: [(title: String, items: [LauncherCandidate])] {
        guard !candidates.isEmpty else { return [] }

        var sections: [(String, [LauncherCandidate])] = []
        for candidate in candidates {
            if sections.last?.0 == candidate.sectionTitle {
                sections[sections.count - 1].1.append(candidate)
            } else {
                sections.append((candidate.sectionTitle, [candidate]))
            }
        }
        return sections
    }

    func handleQueryEdited() {
        debounceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.rerankNow()
        }
        debounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: workItem)
    }

    func refreshSources() {
        Logger.log("[LAUNCHER_QUERY] refresh dynamic sources")
        context = contextProvider()
        rerankNow()
    }

    func moveSelection(by delta: Int) {
        guard !candidates.isEmpty else { return }
        guard delta != 0 else { return }

        let currentIndex = selectedIndex ?? 0
        let nextIndex = (currentIndex + delta + candidates.count) % candidates.count
        selectedCandidateID = candidates[nextIndex].id
    }

    func executeSelection() {
        guard let selected = selectedCandidate else { return }
        execute(candidate: selected)
    }

    func execute(candidate: LauncherCandidate) {
        guard !isExecuting else { return }

        Logger.log("[LAUNCHER_ACTION] execute id=\(candidate.id)")
        isExecuting = true
        statusMessage = nil

        // Dismiss immediately — the action completes in the background.
        let savedContext = context
        dismiss()

        actionExecutor(candidate.action, savedContext) { _ in }
    }

    func isSelected(_ candidate: LauncherCandidate) -> Bool {
        selectedCandidateID == candidate.id
    }

    private var selectedIndex: Int? {
        guard let selectedCandidateID else { return nil }
        return candidates.firstIndex(where: { $0.id == selectedCandidateID })
    }

    private var selectedCandidate: LauncherCandidate? {
        guard let selectedCandidateID else { return candidates.first }
        return candidates.first(where: { $0.id == selectedCandidateID })
    }

    private func rerankNow() {
        let previousSelection = selectedCandidateID
        candidates = launcherEngine.rank(query: query, context: context)

        if let previousSelection,
           candidates.contains(where: { $0.id == previousSelection }) {
            selectedCandidateID = previousSelection
        } else {
            selectedCandidateID = candidates.first?.id
        }
    }
}

struct AddWindowPaletteView: View {
    @ObservedObject var viewModel: AddWindowPaletteViewModel
    let onDismiss: () -> Void

    @FocusState private var searchFocused: Bool
    @State private var hoveredCandidateID: String?

    var body: some View {
        ZStack {
            VisualEffectBackground(material: .hudWindow, blendingMode: .behindWindow)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 1)

            VStack(spacing: 0) {
                header
                Divider().opacity(0.4)
                searchField
                Divider().opacity(0.25)
                candidateList
                footer
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .shadow(color: .black.opacity(0.28), radius: 26, x: 0, y: 12)
        .onAppear {
            viewModel.refreshSources()
            DispatchQueue.main.async {
                searchFocused = true
            }
        }
        .onChange(of: viewModel.query) { _ in
            viewModel.handleQueryEdited()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.modeTitle)
                    .font(.system(size: 16, weight: .semibold))
                Text("Search windows, groups, apps, or URL")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                viewModel.refreshSources()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help("Refresh (⌘R)")

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help("Close (Esc)")
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Type to search…", text: $viewModel.query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .font(.system(size: 14))
                .disableAutocorrection(true)
                .onSubmit {
                    viewModel.executeSelection()
                }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    private var candidateList: some View {
        ScrollView {
            if viewModel.sectionedCandidates.isEmpty {
                VStack(spacing: 8) {
                    Text("No matches")
                        .font(.system(size: 13, weight: .medium))
                    Text("Try another query or refresh data sources.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
                .padding(.bottom, 70)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(viewModel.sectionedCandidates.enumerated()), id: \.offset) { _, section in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(section.title)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)

                            VStack(spacing: 3) {
                                ForEach(section.items, id: \.id) { candidate in
                                    candidateRow(candidate)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("↑/↓, Tab, Return, ⌘R")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Spacer()

            if viewModel.isExecuting {
                ProgressView()
                    .controlSize(.small)
            } else if let status = viewModel.statusMessage {
                Text(status)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private func candidateRow(_ candidate: LauncherCandidate) -> some View {
        let selected = viewModel.isSelected(candidate)
        let hovered = hoveredCandidateID == candidate.id

        return Button {
            viewModel.execute(candidate: candidate)
        } label: {
            HStack(spacing: 10) {
                icon(for: candidate)

                VStack(alignment: .leading, spacing: 2) {
                    Text(candidate.displayName)
                        .font(.system(size: 13, weight: .medium))
                    Text(candidate.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if candidate.isRunningApp {
                    Text("Running")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .opacity(candidate.hasNativeNewWindow ? 1.0 : 0.5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.26) : hovered ? Color.white.opacity(0.07) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(selected ? Color.accentColor.opacity(0.8) : Color.white.opacity(0.08), lineWidth: selected ? 1.2 : 0.8)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredCandidateID = hovering ? candidate.id : nil
        }
    }

    @ViewBuilder
    private func icon(for candidate: LauncherCandidate) -> some View {
        if let icon = candidate.icon {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        } else {
            Image(systemName: symbol(for: candidate.action))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
        }
    }

    private func symbol(for action: LauncherAction) -> String {
        switch action {
        case .looseWindow:
            return "macwindow"
        case .groupAllInSpace:
            return "rectangle.stack.fill"
        case .mergeGroup:
            return "rectangle.on.rectangle"
        case .insertSeparatorTab:
            return "line.3.horizontal.decrease.circle"
        case .renameTargetGroup:
            return "character.cursor.ibeam"
        case .renameCurrentTab:
            return "character.textbox"
        case .releaseCurrentTab:
            return "rectangle.badge.minus"
        case .ungroupTargetGroup:
            return "rectangle.split.3x1"
        case .closeAllWindowsInTargetGroup:
            return "xmark.square"
        case .appLaunch:
            return "app.badge"
        case .openURL:
            return "link"
        case .webSearch:
            return "magnifyingglass"
        }
    }
}
