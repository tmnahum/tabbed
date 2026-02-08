import SwiftUI

struct TabBarView: View {
    @ObservedObject var group: TabGroup
    var onSwitchTab: (Int) -> Void
    var onReleaseTab: (Int) -> Void
    var onCloseTab: (Int) -> Void
    var onAddWindow: () -> Void

    private static let horizontalPadding: CGFloat = 8 // 4 per side via .padding(.horizontal, 4)
    private static let addButtonWidth: CGFloat = 20

    @State private var hoveredWindowID: CGWindowID? = nil
    @State private var draggingID: CGWindowID? = nil
    @State private var dragTranslation: CGFloat = 0
    @State private var dragStartIndex: Int = 0

    var body: some View {
        GeometryReader { geo in
            let tabCount = group.windows.count
            let tabStep: CGFloat = tabCount > 0
                ? (geo.size.width - Self.horizontalPadding - Self.addButtonWidth) / CGFloat(tabCount)
                : 0

            let targetIndex = computeTargetIndex(tabStep: tabStep)

            HStack(spacing: 1) {
                ForEach(Array(group.windows.enumerated()), id: \.element.id) { index, window in
                    let isDragging = draggingID == window.id

                    tabItem(for: window, at: index)
                        .offset(x: isDragging
                            ? dragTranslation
                            : shiftOffset(for: index, targetIndex: targetIndex, tabStep: tabStep))
                        .zIndex(isDragging ? 1 : 0)
                        .scaleEffect(isDragging ? 1.03 : 1.0, anchor: .center)
                        .shadow(
                            color: isDragging ? .black.opacity(0.3) : .clear,
                            radius: isDragging ? 6 : 0,
                            y: isDragging ? 1 : 0
                        )
                        // Animate non-dragged tabs sliding over when target changes;
                        // nil for the dragged tab so it tracks the cursor without lag.
                        .animation(isDragging ? nil : .easeInOut(duration: 0.15), value: targetIndex)
                        .gesture(
                            DragGesture(minimumDistance: 5)
                                .onChanged { value in
                                    if draggingID == nil {
                                        draggingID = window.id
                                        dragStartIndex = index
                                    }
                                    dragTranslation = value.translation.width
                                }
                                .onEnded { _ in
                                    handleDragEnded(tabStep: tabStep)
                                }
                        )
                }
                addButton
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Drag Logic

    /// Compute where the dragged tab should land based on total drag distance from its start position.
    private func computeTargetIndex(tabStep: CGFloat) -> Int? {
        guard draggingID != nil, tabStep > 0 else { return nil }
        let positions = Int(round(dragTranslation / tabStep))
        return max(0, min(group.windows.count - 1, dragStartIndex + positions))
    }

    /// How much should a non-dragged tab shift to make room at the target position?
    private func shiftOffset(for index: Int, targetIndex: Int?, tabStep: CGFloat) -> CGFloat {
        guard let target = targetIndex else { return 0 }

        if dragStartIndex < target {
            // Dragging right: tabs between start (exclusive) and target (inclusive) shift left
            if index > dragStartIndex && index <= target {
                return -tabStep
            }
        } else if dragStartIndex > target {
            // Dragging left: tabs between target (inclusive) and start (exclusive) shift right
            if index >= target && index < dragStartIndex {
                return tabStep
            }
        }
        return 0
    }

    /// Convert a visual target index into an insertion index for `moveTab`.
    /// When dragging right, the source is removed first, shifting indices down,
    /// so the insertion point is target + 1. When dragging left (or not moving),
    /// the target index is already correct.
    static func insertionIndex(from sourceIndex: Int, to targetIndex: Int) -> Int {
        sourceIndex < targetIndex ? targetIndex + 1 : targetIndex
    }

    private func handleDragEnded(tabStep: CGFloat) {
        guard let dragID = draggingID else { return }

        let target = computeTargetIndex(tabStep: tabStep) ?? dragStartIndex
        let sourceIndex = group.windows.firstIndex(where: { $0.id == dragID })

        // Commit reorder + reset offsets in the same animation transaction.
        // The natural-position shift from moveTab cancels the offset going to 0,
        // so each tab smoothly slides just the small residual to its final slot.
        withAnimation(.easeOut(duration: 0.15)) {
            if let sourceIndex, sourceIndex != target {
                group.moveTab(from: sourceIndex, to: Self.insertionIndex(from: sourceIndex, to: target))
            }
            dragTranslation = 0
            draggingID = nil
        }
    }

    // MARK: - Tab Item

    @ViewBuilder
    private func tabItem(for window: WindowInfo, at index: Int) -> some View {
        let isActive = index == group.activeIndex
        let isHovered = hoveredWindowID == window.id && draggingID == nil

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

            if isHovered {
                Image(systemName: isActive ? "minus" : "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
                    .highPriorityGesture(TapGesture().onEnded {
                        if isActive {
                            onReleaseTab(index)
                        } else {
                            onCloseTab(index)
                        }
                    })
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? Color.primary.opacity(0.1) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onSwitchTab(index)
        }
        .onHover { hovering in
            hoveredWindowID = hovering ? window.id : nil
        }
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
