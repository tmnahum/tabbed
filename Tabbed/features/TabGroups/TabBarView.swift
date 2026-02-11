import SwiftUI

struct CrossPanelDropTarget {
    let groupID: UUID
    let insertionIndex: Int
}

struct TabBarView: View {
    @ObservedObject var group: TabGroup
    @ObservedObject var tabBarConfig: TabBarConfig
    var onSwitchTab: (Int) -> Void
    var onReleaseTab: (Int) -> Void
    var onCloseTab: (Int) -> Void
    var onAddWindow: () -> Void
    var onAddWindowAfterTab: (Int) -> Void
    var onBeginGroupNameEdit: () -> Void
    var onCommitGroupName: (String?) -> Void
    var onReleaseTabs: (Set<CGWindowID>) -> Void
    var onMoveToNewGroup: (Set<CGWindowID>) -> Void
    var onCloseTabs: (Set<CGWindowID>) -> Void
    var onCrossPanelDrop: (Set<CGWindowID>, UUID, Int) -> Void
    var onDragOverPanels: (NSPoint) -> CrossPanelDropTarget?
    var onDragEnded: () -> Void
    var onTooltipHover: ((_ title: String?, _ tabLeadingX: CGFloat) -> Void)?

    static let horizontalPadding: CGFloat = 8
    static let addButtonWidth: CGFloat = 20
    static let maxCompactTabWidth: CGFloat = 240
    static let dragHandleWidth: CGFloat = 16
    static let groupNameMaxWidth: CGFloat = 180
    static let groupNameHorizontalPadding: CGFloat = 8
    static let groupNameFontSize: CGFloat = 11
    static let groupNameEmptyHitWidth: CGFloat = 3
    static let groupNameEditingMinWidth: CGFloat = 110

    static func displayedGroupName(from rawName: String?) -> String? {
        guard let rawName else { return nil }
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func groupNameReservedWidth(for rawName: String?, isEditing: Bool = false) -> CGFloat {
        guard let name = displayedGroupName(from: rawName) else {
            return isEditing ? groupNameEditingMinWidth + 6 : groupNameEmptyHitWidth
        }
        let textWidth = (name as NSString).size(
            withAttributes: [.font: NSFont.systemFont(ofSize: groupNameFontSize, weight: .semibold)]
        ).width
        let contentWidth = min(groupNameMaxWidth, textWidth + groupNameHorizontalPadding * 2)
        let renderedWidth = contentWidth + 6
        return isEditing ? max(renderedWidth, groupNameEditingMinWidth + 6) : renderedWidth
    }

    // Chrome/Firefox-style horizontal expand transition for new tabs
    private struct HorizontalScale: ViewModifier {
        let fraction: CGFloat
        func body(content: Content) -> some View {
            content.scaleEffect(x: fraction, y: 1, anchor: .leading)
        }
    }

    private static let tabExpandTransition: AnyTransition =
        .modifier(
            active: HorizontalScale(fraction: 0.01),
            identity: HorizontalScale(fraction: 1)
        ).combined(with: .opacity)

    @State private var hoveredWindowID: CGWindowID? = nil
    @State private var confirmingCloseID: CGWindowID? = nil
    @State private var draggingID: CGWindowID? = nil
    @State private var dragTranslation: CGFloat = 0
    @State private var dragStartIndex: Int = 0
    @State private var selectedIDs: Set<CGWindowID> = []
    @State private var lastClickedIndex: Int? = nil
    /// IDs being dragged (either the multi-selection or just the single dragged tab)
    @State private var draggingIDs: Set<CGWindowID> = []
    /// Set true during drag if the cursor moves far enough vertically to detach
    @State private var draggedOffBar = false
    @State private var currentDropTarget: CrossPanelDropTarget? = nil
    /// Post-drag snap-to-grid: residual offset animated to 0 after instant reorder
    @State private var snapIDs: Set<CGWindowID> = []
    @State private var snapOffset: CGFloat = 0
    @State private var tabLeadingXs: [CGWindowID: CGFloat] = [:]
    @State private var isEditingGroupName = false
    @State private var groupNameDraft = ""
    @FocusState private var isGroupNameFieldFocused: Bool

    var body: some View {
        GeometryReader { geo in
            let tabCount = group.windows.count
            let isCompact = tabBarConfig.style == .compact
            let handleWidth: CGFloat = tabBarConfig.showDragHandle ? Self.dragHandleWidth : 0
            let groupNameWidth = Self.groupNameReservedWidth(for: group.name, isEditing: isEditingGroupName)
            let leadingPad: CGFloat = tabBarConfig.showDragHandle ? 4 : 2
            let trailingPad: CGFloat = 4
            let availableWidth = max(0, geo.size.width - leadingPad - trailingPad - Self.addButtonWidth - handleWidth - groupNameWidth)
            let totalSpacing: CGFloat = tabCount > 1 ? CGFloat(tabCount - 1) : 0
            let equalTabStep: CGFloat = tabCount > 0
                ? availableWidth / CGFloat(tabCount)
                : 0
            let compactTabWidth: CGFloat = tabCount > 0
                ? min((availableWidth - totalSpacing) / CGFloat(tabCount), Self.maxCompactTabWidth)
                : 0
            let tabStep: CGFloat = isCompact ? compactTabWidth + 1 : equalTabStep

            let targetIndex = computeTargetIndex(tabStep: tabStep)

            ZStack(alignment: .leading) {
                HStack(spacing: 1) {
                    if tabBarConfig.showDragHandle {
                        dragHandle
                    }
                    groupNameControl(groupNameWidth: groupNameWidth)
                    ForEach(Array(group.windows.enumerated()), id: \.element.id) { index, window in
                        let isDragging = draggingIDs.contains(window.id)

                        let tabWidth = isCompact ? compactTabWidth : equalTabStep

                        tabItem(for: window, at: index, compactWidth: isCompact ? compactTabWidth : nil, tabWidth: tabWidth)
                            .offset(x: isDragging
                                ? dragTranslation
                                : shiftOffset(for: index, targetIndex: targetIndex, tabStep: tabStep))
                            .offset(x: snapIDs.contains(window.id) ? snapOffset : 0)
                            .zIndex(isDragging ? 1 : 0)
                            .scaleEffect(isDragging ? 1.03 : 1.0, anchor: .center)
                            .shadow(
                                color: isDragging ? .black.opacity(0.3) : .clear,
                                radius: isDragging ? 6 : 0,
                                y: isDragging ? 1 : 0
                            )
                            .animation(isDragging ? nil : .easeOut(duration: 0.15), value: targetIndex)
                            .transition(Self.tabExpandTransition)
                            .gesture(
                                DragGesture(minimumDistance: 3)
                                    .onChanged { value in
                                        if draggingID == nil {
                                            draggingID = window.id
                                            dragStartIndex = index
                                            snapIDs = []
                                            snapOffset = 0
                                            if selectedIDs.contains(window.id) {
                                                draggingIDs = selectedIDs
                                            } else {
                                                selectedIDs = []
                                                draggingIDs = [window.id]
                                            }
                                        }
                                        dragTranslation = value.translation.width
                                        // Track if cursor has left the tab bar vertically.
                                        // Latch true so even if the gesture stops tracking
                                        // outside the panel, we still detach on end.
                                        if abs(value.translation.height) > 15 {
                                            draggedOffBar = true
                                        }
                                        if draggedOffBar {
                                            currentDropTarget = onDragOverPanels(NSEvent.mouseLocation)
                                        }
                                    }
                                    .onEnded { _ in
                                        if draggedOffBar, let target = currentDropTarget {
                                            let ids = draggingIDs
                                            resetDragState()
                                            selectedIDs = []
                                            onCrossPanelDrop(ids, target.groupID, target.insertionIndex)
                                        } else if draggedOffBar {
                                            handleDragDetach()
                                        } else {
                                            handleDragEnded(tabStep: tabStep)
                                        }
                                    }
                            )
                    }
                    addButton

                    if isCompact {
                        Spacer(minLength: 0)
                    }
                }
                .padding(.leading, leadingPad)
                .padding(.trailing, trailingPad)
                .padding(.vertical, 2)

                // Drop indicator line when another group is dragging tabs over this bar
                if let dropIndex = group.dropIndicatorIndex {
                    let xPos = Self.horizontalPadding / 2 + handleWidth + groupNameWidth + tabStep * CGFloat(dropIndex)
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.accentColor)
                        .frame(width: 2, height: 20)
                        .offset(x: xPos)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                        .animation(.easeInOut(duration: 0.1), value: dropIndex)
                }
            }
            .coordinateSpace(name: "tabBar")
            .contentShape(Rectangle())
            .contextMenu {
                Button(group.displayName == nil ? "Name Group…" : "Rename Group…") {
                    beginGroupNameEditing(fromContextMenu: true)
                }
                Divider()
                Button("Ungroup") {
                    let allIDs = Set(group.windows.map(\.id))
                    selectedIDs = []
                    onReleaseTabs(allIDs)
                }
                Divider()
                Button("Close All Windows") {
                    let allIDs = Set(group.windows.map(\.id))
                    selectedIDs = []
                    onCloseTabs(allIDs)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            groupNameDraft = group.displayName ?? ""
        }
        .onChange(of: group.name) { _ in
            guard !isEditingGroupName else { return }
            groupNameDraft = group.displayName ?? ""
        }
        .onChange(of: isGroupNameFieldFocused) { focused in
            if !focused {
                commitGroupNameEdit()
            }
        }
        .onChange(of: group.windows.count) { _ in
            // Clear stale selection when windows are externally added/removed
            let validIDs = Set(group.windows.map(\.id))
            selectedIDs = selectedIDs.intersection(validIDs)
            if let idx = lastClickedIndex, idx >= group.windows.count {
                lastClickedIndex = nil
            }
        }
    }

    // MARK: - Selection

    private func handleClick(index: Int, window: WindowInfo) {
        let modifiers = NSApp.currentEvent?.modifierFlags ?? []

        if modifiers.contains(.command) {
            // Cmd-click: toggle individual selection, don't switch tab
            if selectedIDs.contains(window.id) {
                selectedIDs.remove(window.id)
            } else {
                selectedIDs.insert(window.id)
            }
            lastClickedIndex = index
        } else if modifiers.contains(.shift) && index == group.activeIndex {
            // Shift-click active tab: close its window
            onCloseTab(index)
        } else if modifiers.contains(.shift), let anchor = lastClickedIndex {
            // Shift-click: range select from anchor to clicked
            let range = min(anchor, index)...max(anchor, index)
            for i in range {
                selectedIDs.insert(group.windows[i].id)
            }
        } else {
            // Plain click: clear selection, switch tab
            selectedIDs = []
            lastClickedIndex = index
            onSwitchTab(index)
        }
    }

    // MARK: - Context Menu

    /// Resolve which window IDs the context menu should act on.
    /// If the right-clicked tab is in the selection, act on all selected.
    /// Otherwise act on just that tab.
    private func contextTargets(for window: WindowInfo) -> Set<CGWindowID> {
        if selectedIDs.contains(window.id) {
            return selectedIDs
        }
        return [window.id]
    }

    // MARK: - Drag Logic

    private func computeTargetIndex(tabStep: CGFloat) -> Int? {
        guard draggingID != nil, tabStep > 0 else { return nil }
        let positions = Int(round(dragTranslation / tabStep))
        return max(0, min(group.windows.count - 1, dragStartIndex + positions))
    }

    private func shiftOffset(for index: Int, targetIndex: Int?, tabStep: CGFloat) -> CGFloat {
        guard let target = targetIndex else { return 0 }

        if draggingIDs.count > 1 {
            let windowIDs = group.windows.map(\.id)
            let positionDelta = Self.multiDragPositionDelta(
                for: index, windowIDs: windowIDs, draggedIDs: draggingIDs, targetIndex: target
            )
            return CGFloat(positionDelta) * tabStep
        }

        // Single-drag: shift tabs between source and target
        if dragStartIndex < target {
            if index > dragStartIndex && index <= target {
                return -tabStep
            }
        } else if dragStartIndex > target {
            if index >= target && index < dragStartIndex {
                return tabStep
            }
        }
        return 0
    }

    /// Compute how many positions a non-dragged tab at `index` shifts when a block of
    /// dragged tabs is moved to `targetIndex`. Mirrors the logic of `moveTabs(withIDs:toIndex:)`.
    static func multiDragPositionDelta(
        for index: Int, windowIDs: [CGWindowID], draggedIDs: Set<CGWindowID>, targetIndex: Int
    ) -> Int {
        let remaining = windowIDs.enumerated().filter { !draggedIDs.contains($0.element) }
        let insertAt = max(0, min(targetIndex, remaining.count))
        let draggedCount = draggedIDs.count

        for (finalPos, entry) in remaining.enumerated() {
            if entry.offset == index {
                let adjustedPos = finalPos < insertAt ? finalPos : finalPos + draggedCount
                return adjustedPos - index
            }
        }
        return 0
    }

    static func insertionIndex(from sourceIndex: Int, to targetIndex: Int) -> Int {
        sourceIndex < targetIndex ? targetIndex + 1 : targetIndex
    }

    private func handleDragEnded(tabStep: CGFloat) {
        guard draggingID != nil else { return }

        let target = computeTargetIndex(tabStep: tabStep) ?? dragStartIndex
        let exactTranslation = CGFloat(target - dragStartIndex) * tabStep
        let residual = dragTranslation - exactTranslation
        let ids = draggingIDs
        let isMulti = draggingIDs.count > 1

        // Phase 1: commit reorder + reset instantly (no animation).
        // Set snapOffset to the residual so the dragged tab stays at its
        // current visual position despite the instant HStack reorder.
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            if isMulti {
                group.moveTabs(withIDs: ids, toIndex: target)
            } else {
                let sourceIndex = group.windows.firstIndex(where: { $0.id == draggingID! })
                if let sourceIndex, sourceIndex != target {
                    group.moveTab(from: sourceIndex, to: Self.insertionIndex(from: sourceIndex, to: target))
                }
            }
            resetDragState()
            if isMulti { selectedIDs = [] }
            snapIDs = ids
            snapOffset = residual
        }

        // Phase 2: animate the residual to 0 in the next frame.
        // Only snapOffset changes — no ForEach reorder, no competing animations.
        // Don't clear snapIDs here; it's a Set (not interpolatable) and would
        // cause the offset to jump to 0 immediately. It gets cleared on next drag start.
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.12)) {
                snapOffset = 0
            }
        }
    }

    /// Drag ended with vertical movement — detach dragged tabs to a new group.
    private func handleDragDetach() {
        let ids = draggingIDs
        resetDragState()
        selectedIDs = []
        onMoveToNewGroup(ids)
    }

    private func resetDragState() {
        dragTranslation = 0
        draggingID = nil
        draggingIDs = []
        draggedOffBar = false
        currentDropTarget = nil
        onDragEnded()
    }

    // MARK: - Tab Item

    /// Whether a title would be truncated at the given tab width.
    /// Accounts for icon (16), spacing (6), horizontal padding (8×2), and close button on hover (16).
    static func isTitleTruncated(title: String, tabWidth: CGFloat) -> Bool {
        guard !title.isEmpty else { return false }
        let chrome: CGFloat = 8 + 16 + 6 + 8 + 16 // left pad + icon + spacing + right pad + close button
        let availableTextWidth = tabWidth - chrome
        guard availableTextWidth > 0 else { return true }
        let textSize = (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)])
        return textSize.width > availableTextWidth
    }

    @ViewBuilder
    private func tabItem(for window: WindowInfo, at index: Int, compactWidth: CGFloat? = nil, tabWidth: CGFloat = 0) -> some View {
        let isActive = index == group.activeIndex
        let isHovered = hoveredWindowID == window.id && draggingID == nil
        let isSelected = selectedIDs.contains(window.id)

        HStack(spacing: 6) {
            if let icon = window.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 16, height: 16)
            }
            Text(window.title.isEmpty ? window.appName : window.title)
                .lineLimit(1)
                .truncationMode(.tail)
                .font(.system(size: 12))
                .foregroundStyle(isActive ? .primary : .secondary)

            Spacer(minLength: 0)

            if isHovered && !isSelected {
                if isActive {
                    Image(systemName: "minus")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                        .highPriorityGesture(TapGesture().onEnded {
                            onReleaseTab(index)
                        })
                } else {
                    Image(systemName: confirmingCloseID == window.id ? "questionmark" : "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(confirmingCloseID == window.id ? .primary : .secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                        .highPriorityGesture(TapGesture().onEnded {
                            if confirmingCloseID == window.id {
                                confirmingCloseID = nil
                                onCloseTab(index)
                            } else {
                                confirmingCloseID = window.id
                            }
                        })
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: compactWidth ?? .infinity, alignment: .leading)
        .background(
            GeometryReader { tabGeo in
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected
                        ? Color.accentColor.opacity(0.15)
                        : isActive
                            ? Color.primary.opacity(0.1)
                            : Color.clear)
                    .onAppear {
                        tabLeadingXs[window.id] = tabGeo.frame(in: .named("tabBar")).minX
                    }
                    .onChange(of: tabGeo.frame(in: .named("tabBar")).minX) { newX in
                        tabLeadingXs[window.id] = newX
                    }
            }
        )
        .contentShape(Rectangle())
        .onTapGesture {
            handleClick(index: index, window: window)
        }
        .onHover { hovering in
            hoveredWindowID = hovering ? window.id : nil
            if !hovering && confirmingCloseID == window.id {
                confirmingCloseID = nil
            }
            if tabBarConfig.showTooltip {
                let title = window.title.isEmpty ? window.appName : window.title
                if hovering && Self.isTitleTruncated(title: title, tabWidth: tabWidth) {
                    onTooltipHover?(title, tabLeadingXs[window.id] ?? 0)
                } else {
                    onTooltipHover?(nil, 0)
                }
            }
        }
        .contextMenu {
            let targets = contextTargets(for: window)
            Button("New Tab to the Right") {
                onAddWindowAfterTab(index)
            }
            Divider()
            Button("Release from Group") {
                selectedIDs = []
                onReleaseTabs(targets)
            }
            Button("Move to New Group") {
                selectedIDs = []
                onMoveToNewGroup(targets)
            }
            Divider()
            Button(targets.count == 1 ? "Close Window" : "Close Windows") {
                selectedIDs = []
                onCloseTabs(targets)
            }
        }
    }

    private var dragHandle: some View {
        HStack(spacing: 2) {
            ForEach(0..<2, id: \.self) { _ in
                VStack(spacing: 2) {
                    ForEach(0..<3, id: \.self) { _ in
                        Circle()
                            .fill(Color.primary.opacity(0.1))
                            .frame(width: 2.5, height: 2.5)
                    }
                }
            }
        }
        .frame(width: Self.dragHandleWidth)
    }

    @ViewBuilder
    private func groupNameControl(groupNameWidth: CGFloat) -> some View {
        if isEditingGroupName {
            TextField("Group name", text: $groupNameDraft)
                .textFieldStyle(.plain)
                .font(.system(size: Self.groupNameFontSize, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, Self.groupNameHorizontalPadding)
                .frame(width: groupNameWidth, alignment: .leading)
                .focused($isGroupNameFieldFocused)
                .onSubmit {
                    commitGroupNameEdit()
                }
                .onExitCommand {
                    cancelGroupNameEdit()
                }
        } else {
            Group {
                if let name = Self.displayedGroupName(from: group.name) {
                    Text(name)
                        .font(.system(size: Self.groupNameFontSize, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.horizontal, Self.groupNameHorizontalPadding)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Color.clear
                }
            }
            .frame(width: groupNameWidth, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                beginGroupNameEditing()
            }
        }
    }

    private func beginGroupNameEditing(fromContextMenu: Bool = false) {
        onBeginGroupNameEdit()
        groupNameDraft = group.displayName ?? ""
        isEditingGroupName = true
        let delay = fromContextMenu ? DispatchTimeInterval.milliseconds(100) : .milliseconds(0)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            isGroupNameFieldFocused = true
        }
    }

    private func commitGroupNameEdit() {
        guard isEditingGroupName else { return }
        let trimmed = groupNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.isEmpty ? nil : trimmed
        groupNameDraft = normalized ?? ""
        onCommitGroupName(normalized)
        isEditingGroupName = false
        isGroupNameFieldFocused = false
    }

    private func cancelGroupNameEdit() {
        guard isEditingGroupName else { return }
        groupNameDraft = group.displayName ?? ""
        isEditingGroupName = false
        isGroupNameFieldFocused = false
    }

    private var addButton: some View {
        Button {
            onAddWindow()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
    }
}
