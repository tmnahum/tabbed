# Multi-Tab Selection & Context Menu Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add shift/cmd-click multi-tab selection, multi-tab drag (reorder + detach), and right-click context menu to the tab bar.

**Architecture:** Selection state lives purely in TabBarView (UI concern). New batch methods on TabGroup/GroupManager handle multi-window operations. Context menu uses SwiftUI `.contextMenu` modifier. New callbacks from TabBarView → AppDelegate handle multi-tab release/move/close. Modifier keys captured from `NSApp.currentEvent` for reliable cmd/shift detection.

**Tech Stack:** SwiftUI, AppKit (NSPanel, NSApp.currentEvent for modifier keys), Accessibility APIs

---

### Task 1: Add batch removal to TabGroup

**Files:**
- Modify: `Tabbed/features/TabGroups/TabGroup.swift:50-66`
- Test: `TabbedTests/TabGroupTests.swift`

**Step 1: Write the failing test**

In `TabbedTests/TabGroupTests.swift`, add at the end of the class:

```swift
func testRemoveWindowsWithIDs() {
    let group = TabGroup(windows: [makeWindow(id: 1), makeWindow(id: 2), makeWindow(id: 3), makeWindow(id: 4)], frame: .zero)
    group.switchTo(index: 2) // Window 3 is active
    let removed = group.removeWindows(withIDs: [1, 3])
    XCTAssertEqual(removed.map(\.id).sorted(), [1, 3])
    XCTAssertEqual(group.windows.map(\.id), [2, 4])
    // Active was window 3 (removed), should fall to valid index
    XCTAssertTrue(group.activeIndex >= 0 && group.activeIndex < group.windows.count)
}

func testRemoveWindowsWithIDsPreservesOrder() {
    let group = TabGroup(windows: [makeWindow(id: 1), makeWindow(id: 2), makeWindow(id: 3), makeWindow(id: 4), makeWindow(id: 5)], frame: .zero)
    group.switchTo(index: 4) // Window 5 is active
    let removed = group.removeWindows(withIDs: [2, 4])
    XCTAssertEqual(removed.map(\.id), [2, 4])
    XCTAssertEqual(group.windows.map(\.id), [1, 3, 5])
    XCTAssertEqual(group.activeWindow?.id, 5)
}

func testRemoveWindowsWithIDsActiveBeforeRemoved() {
    let group = TabGroup(windows: [makeWindow(id: 1), makeWindow(id: 2), makeWindow(id: 3)], frame: .zero)
    group.switchTo(index: 0) // Window 1 is active
    let removed = group.removeWindows(withIDs: [2, 3])
    XCTAssertEqual(removed.map(\.id), [2, 3])
    XCTAssertEqual(group.activeWindow?.id, 1)
    XCTAssertEqual(group.activeIndex, 0)
}

func testRemoveWindowsEmptySetDoesNothing() {
    let group = TabGroup(windows: [makeWindow(id: 1), makeWindow(id: 2)], frame: .zero)
    let removed = group.removeWindows(withIDs: [])
    XCTAssertTrue(removed.isEmpty)
    XCTAssertEqual(group.windows.count, 2)
}

func testRemoveAllWindows() {
    let group = TabGroup(windows: [makeWindow(id: 1), makeWindow(id: 2), makeWindow(id: 3)], frame: .zero)
    let removed = group.removeWindows(withIDs: [1, 2, 3])
    XCTAssertEqual(removed.count, 3)
    XCTAssertTrue(group.windows.isEmpty)
    XCTAssertEqual(group.activeIndex, 0)
}
```

**Step 2: Run test to verify it fails**

Run: `scripts/test.sh`
Expected: FAIL — `removeWindows(withIDs:)` not found

**Step 3: Write minimal implementation**

In `TabGroup.swift`, add after the existing `removeWindow(withID:)` method (line 66):

```swift
/// Remove multiple windows by ID. Returns removed windows in their original order.
func removeWindows(withIDs ids: Set<CGWindowID>) -> [WindowInfo] {
    guard !ids.isEmpty else { return [] }

    let activeID = activeWindow?.id
    var removed: [WindowInfo] = []

    // Remove from end to avoid index shifting issues
    for index in stride(from: windows.count - 1, through: 0, by: -1) {
        if ids.contains(windows[index].id) {
            let window = windows.remove(at: index)
            focusHistory.removeAll { $0 == window.id }
            cycleOrder.removeAll { $0 == window.id }
            removed.append(window)
        }
    }
    removed.reverse() // Restore original order

    // Fix activeIndex
    if windows.isEmpty {
        activeIndex = 0
    } else if let activeID, let newIndex = windows.firstIndex(where: { $0.id == activeID }) {
        activeIndex = newIndex
    } else {
        activeIndex = max(0, min(activeIndex, windows.count - 1))
    }

    return removed
}
```

**Step 4: Run test to verify it passes**

Run: `scripts/test.sh`
Expected: PASS

**Step 5: Commit**

```bash
git add Tabbed/features/TabGroups/TabGroup.swift TabbedTests/TabGroupTests.swift
git commit -m "feat: add batch removeWindows(withIDs:) to TabGroup"
```

---

### Task 2: Add batch moveTabs to TabGroup

**Files:**
- Modify: `Tabbed/features/TabGroups/TabGroup.swift:129-148`
- Test: `TabbedTests/TabGroupTests.swift`

**Step 1: Write the failing test**

In `TabbedTests/TabGroupTests.swift`:

```swift
func testMoveTabsToEnd() {
    let group = TabGroup(windows: [makeWindow(id: 1), makeWindow(id: 2), makeWindow(id: 3), makeWindow(id: 4), makeWindow(id: 5)], frame: .zero)
    group.switchTo(index: 0) // Window 1 active
    // toIndex=4 means block's first element targets final position 4.
    // remaining=[2,4,5], insertAt=min(4, 3)=3 → [2,4,5,1,3]
    group.moveTabs(withIDs: [1, 3], toIndex: 4)
    XCTAssertEqual(group.windows.map(\.id), [2, 4, 5, 1, 3])
    XCTAssertEqual(group.activeWindow?.id, 1)
}

func testMoveTabsToBeginning() {
    let group = TabGroup(windows: [makeWindow(id: 1), makeWindow(id: 2), makeWindow(id: 3), makeWindow(id: 4)], frame: .zero)
    group.switchTo(index: 3) // Window 4 active
    // toIndex=0, remaining=[1,2], insertAt=0 → [3,4,1,2]
    group.moveTabs(withIDs: [3, 4], toIndex: 0)
    XCTAssertEqual(group.windows.map(\.id), [3, 4, 1, 2])
    XCTAssertEqual(group.activeWindow?.id, 4)
}

func testMoveTabsPreservesRelativeOrder() {
    let group = TabGroup(windows: [makeWindow(id: 1), makeWindow(id: 2), makeWindow(id: 3), makeWindow(id: 4), makeWindow(id: 5)], frame: .zero)
    // toIndex=1, remaining=[1,3,5], insertAt=1 → [1,2,4,3,5]
    group.moveTabs(withIDs: [4, 2], toIndex: 1)
    XCTAssertEqual(group.windows.map(\.id), [1, 2, 4, 3, 5])
}

func testMoveTabsSingleTab() {
    let group = TabGroup(windows: [makeWindow(id: 1), makeWindow(id: 2), makeWindow(id: 3)], frame: .zero)
    // toIndex=2, remaining=[2,3], insertAt=min(2, 2)=2 → [2,3,1]
    group.moveTabs(withIDs: [1], toIndex: 2)
    XCTAssertEqual(group.windows.map(\.id), [2, 3, 1])
}

func testMoveTabsToMiddle() {
    let group = TabGroup(windows: [makeWindow(id: 1), makeWindow(id: 2), makeWindow(id: 3), makeWindow(id: 4), makeWindow(id: 5)], frame: .zero)
    // toIndex=2, remaining=[1,3,5], insertAt=min(2, 3)=2 → [1,3,2,4,5]
    group.moveTabs(withIDs: [2, 4], toIndex: 2)
    XCTAssertEqual(group.windows.map(\.id), [1, 3, 2, 4, 5])
}

func testMoveTabsNoOpWhenAlreadyInPlace() {
    let group = TabGroup(windows: [makeWindow(id: 1), makeWindow(id: 2), makeWindow(id: 3)], frame: .zero)
    group.moveTabs(withIDs: [1, 2], toIndex: 0)
    XCTAssertEqual(group.windows.map(\.id), [1, 2, 3])
}

func testMoveTabsActiveNotMoved() {
    let group = TabGroup(windows: [makeWindow(id: 1), makeWindow(id: 2), makeWindow(id: 3), makeWindow(id: 4)], frame: .zero)
    group.switchTo(index: 1) // Window 2 is active
    // Move windows 3,4 to the beginning; window 2 should stay active
    group.moveTabs(withIDs: [3, 4], toIndex: 0)
    XCTAssertEqual(group.windows.map(\.id), [3, 4, 1, 2])
    XCTAssertEqual(group.activeWindow?.id, 2)
}
```

**Step 2: Run test to verify it fails**

Run: `scripts/test.sh`
Expected: FAIL — `moveTabs(withIDs:toIndex:)` not found

**Step 3: Write minimal implementation**

In `TabGroup.swift`, add after the existing `moveTab(from:to:)` method:

```swift
/// Move multiple tabs so they form a contiguous block starting at `toIndex` in the final array.
/// Preserves relative order of moved tabs. `toIndex` is clamped to valid range.
func moveTabs(withIDs ids: Set<CGWindowID>, toIndex: Int) {
    let moved = windows.filter { ids.contains($0.id) }
    guard !moved.isEmpty else { return }

    let activeID = activeWindow?.id
    windows.removeAll { ids.contains($0.id) }
    let insertAt = max(0, min(toIndex, windows.count))
    windows.insert(contentsOf: moved, at: insertAt)

    if let activeID, let newIndex = windows.firstIndex(where: { $0.id == activeID }) {
        activeIndex = newIndex
    }
}
```

**Step 4: Run test to verify it passes**

Run: `scripts/test.sh`
Expected: PASS

**Step 5: Commit**

```bash
git add Tabbed/features/TabGroups/TabGroup.swift TabbedTests/TabGroupTests.swift
git commit -m "feat: add batch moveTabs(withIDs:toIndex:) to TabGroup"
```

---

### Task 3: Add batch operations to GroupManager

**Files:**
- Modify: `Tabbed/features/TabGroups/GroupManager.swift`
- Test: `TabbedTests/GroupManagerTests.swift`

**Step 1: Write the failing tests**

In `TabbedTests/GroupManagerTests.swift`:

```swift
func testReleaseWindowsFromGroup() {
    let gm = GroupManager()
    let windows = [makeWindow(id: 1), makeWindow(id: 2), makeWindow(id: 3)]
    let group = gm.createGroup(with: windows, frame: .zero)!
    let released = gm.releaseWindows(withIDs: [1, 3], from: group)
    XCTAssertEqual(released.map(\.id).sorted(), [1, 3])
    XCTAssertEqual(group.windows.count, 1)
    XCTAssertEqual(gm.groups.count, 1)
}

func testReleaseAllWindowsDissolvesGroup() {
    let gm = GroupManager()
    let windows = [makeWindow(id: 1), makeWindow(id: 2)]
    let group = gm.createGroup(with: windows, frame: .zero)!
    let released = gm.releaseWindows(withIDs: [1, 2], from: group)
    XCTAssertEqual(released.count, 2)
    XCTAssertEqual(gm.groups.count, 0)
}

func testReleaseWindowsFromForeignGroupIsIgnored() {
    let gm = GroupManager()
    let foreignGroup = TabGroup(windows: [makeWindow(id: 10), makeWindow(id: 11)], frame: .zero)
    let released = gm.releaseWindows(withIDs: [10], from: foreignGroup)
    XCTAssertTrue(released.isEmpty)
    XCTAssertEqual(foreignGroup.windows.count, 2)
}
```

**Step 2: Run test to verify it fails**

Run: `scripts/test.sh`
Expected: FAIL — `releaseWindows(withIDs:from:)` not found

**Step 3: Write minimal implementation**

In `GroupManager.swift`, add after the existing `releaseWindow(withID:from:)` method:

```swift
/// Remove multiple windows from a group. Returns the removed windows.
/// Auto-dissolves the group if it becomes empty.
@discardableResult
func releaseWindows(withIDs ids: Set<CGWindowID>, from group: TabGroup) -> [WindowInfo] {
    guard groups.contains(where: { $0.id == group.id }) else { return [] }
    let removed = group.removeWindows(withIDs: ids)

    if group.windows.isEmpty {
        dissolveGroup(group)
    } else {
        objectWillChange.send()
    }
    return removed
}
```

**Step 4: Run test to verify it passes**

Run: `scripts/test.sh`
Expected: PASS

**Step 5: Commit**

```bash
git add Tabbed/features/TabGroups/GroupManager.swift TabbedTests/GroupManagerTests.swift
git commit -m "feat: add batch releaseWindows(withIDs:from:) to GroupManager"
```

---

### Task 4: Add multi-tab UI + callbacks + wiring (TabBarView, TabBarPanel, TabGroups.swift)

This task modifies the view layer, panel, and AppDelegate wiring together to avoid a build break between commits.

**Files:**
- Modify: `Tabbed/features/TabGroups/TabBarView.swift`
- Modify: `Tabbed/features/TabGroups/TabBarPanel.swift`
- Modify: `Tabbed/features/TabGroups/TabGroups.swift`

**Step 1: Replace TabBarView.swift**

Key changes from original:
- `@State var selectedIDs` for multi-selection
- `@State var lastClickedIndex` for shift-click range anchoring
- New callbacks: `onReleaseTabs`, `onMoveToNewGroup`, `onCloseTabs` (all take `Set<CGWindowID>`)
- Uses `NSApp.currentEvent?.modifierFlags` for reliable modifier detection (not `NSEvent.modifierFlags`)
- `.contextMenu` on each tab (clears selection in action handlers when acting on unselected tab)
- Multi-tab drag: dragging selected tab drags all selected; dragging unselected clears selection
- Drag-off-bar detection: vertical drag > 30px triggers detach to new group
- `.onChange(of: group.windows.count)` clears stale selection when windows are externally added/removed

```swift
import SwiftUI

struct TabBarView: View {
    @ObservedObject var group: TabGroup
    var onSwitchTab: (Int) -> Void
    var onReleaseTab: (Int) -> Void
    var onCloseTab: (Int) -> Void
    var onAddWindow: () -> Void
    var onReleaseTabs: (Set<CGWindowID>) -> Void
    var onMoveToNewGroup: (Set<CGWindowID>) -> Void
    var onCloseTabs: (Set<CGWindowID>) -> Void

    private static let horizontalPadding: CGFloat = 8
    private static let addButtonWidth: CGFloat = 20

    @State private var hoveredWindowID: CGWindowID? = nil
    @State private var draggingID: CGWindowID? = nil
    @State private var dragTranslation: CGFloat = 0
    @State private var dragStartIndex: Int = 0
    @State private var selectedIDs: Set<CGWindowID> = []
    @State private var lastClickedIndex: Int? = nil
    /// IDs being dragged (either the multi-selection or just the single dragged tab)
    @State private var draggingIDs: Set<CGWindowID> = []

    var body: some View {
        GeometryReader { geo in
            let tabCount = group.windows.count
            let tabStep: CGFloat = tabCount > 0
                ? (geo.size.width - Self.horizontalPadding - Self.addButtonWidth) / CGFloat(tabCount)
                : 0

            let targetIndex = computeTargetIndex(tabStep: tabStep)

            HStack(spacing: 1) {
                ForEach(Array(group.windows.enumerated()), id: \.element.id) { index, window in
                    let isDragging = draggingIDs.contains(window.id)

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
                        .animation(isDragging ? nil : .easeInOut(duration: 0.15), value: targetIndex)
                        .gesture(
                            DragGesture(minimumDistance: 5)
                                .onChanged { value in
                                    if draggingID == nil {
                                        draggingID = window.id
                                        dragStartIndex = index
                                        if selectedIDs.contains(window.id) {
                                            draggingIDs = selectedIDs
                                        } else {
                                            selectedIDs = []
                                            draggingIDs = [window.id]
                                        }
                                    }
                                    dragTranslation = value.translation.width
                                }
                                .onEnded { value in
                                    if abs(value.translation.height) > 30 {
                                        handleDragDetach()
                                    } else {
                                        handleDragEnded(tabStep: tabStep)
                                    }
                                }
                        )
                }
                addButton
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        // Multi-drag: non-dragged tabs stay in place, dragged tabs float over
        if draggingIDs.count > 1 { return 0 }
        // Single-drag: original shift logic
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

    static func insertionIndex(from sourceIndex: Int, to targetIndex: Int) -> Int {
        sourceIndex < targetIndex ? targetIndex + 1 : targetIndex
    }

    private func handleDragEnded(tabStep: CGFloat) {
        guard draggingID != nil else { return }

        let target = computeTargetIndex(tabStep: tabStep) ?? dragStartIndex

        if draggingIDs.count > 1 {
            // Multi-tab drag: target is the visual position the anchor hovers over.
            // Pass directly — moveTabs treats it as the desired final position (clamped).
            withAnimation(.easeOut(duration: 0.15)) {
                group.moveTabs(withIDs: draggingIDs, toIndex: target)
                resetDragState()
            }
            selectedIDs = []
        } else {
            // Single-tab drag: existing behavior
            let sourceIndex = group.windows.firstIndex(where: { $0.id == draggingID! })
            withAnimation(.easeOut(duration: 0.15)) {
                if let sourceIndex, sourceIndex != target {
                    group.moveTab(from: sourceIndex, to: Self.insertionIndex(from: sourceIndex, to: target))
                }
                resetDragState()
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
    }

    // MARK: - Tab Item

    @ViewBuilder
    private func tabItem(for window: WindowInfo, at index: Int) -> some View {
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
                .fill(isActive
                    ? Color.primary.opacity(0.1)
                    : isSelected
                        ? Color.accentColor.opacity(0.15)
                        : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            handleClick(index: index, window: window)
        }
        .onHover { hovering in
            hoveredWindowID = hovering ? window.id : nil
        }
        .contextMenu {
            let targets = contextTargets(for: window)
            Button("Release from Group") {
                selectedIDs = []
                onReleaseTabs(targets)
            }
            Button("Move to New Group") {
                selectedIDs = []
                onMoveToNewGroup(targets)
            }
            Divider()
            Button("Close Windows") {
                selectedIDs = []
                onCloseTabs(targets)
            }
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
```

**Step 2: Update TabBarPanel.setContent to pass new callbacks**

In `TabBarPanel.swift`, replace the `setContent` method:

```swift
func setContent(
    group: TabGroup,
    onSwitchTab: @escaping (Int) -> Void,
    onReleaseTab: @escaping (Int) -> Void,
    onCloseTab: @escaping (Int) -> Void,
    onAddWindow: @escaping () -> Void,
    onReleaseTabs: @escaping (Set<CGWindowID>) -> Void,
    onMoveToNewGroup: @escaping (Set<CGWindowID>) -> Void,
    onCloseTabs: @escaping (Set<CGWindowID>) -> Void
) {
    let tabBarView = TabBarView(
        group: group,
        onSwitchTab: onSwitchTab,
        onReleaseTab: onReleaseTab,
        onCloseTab: onCloseTab,
        onAddWindow: onAddWindow,
        onReleaseTabs: onReleaseTabs,
        onMoveToNewGroup: onMoveToNewGroup,
        onCloseTabs: onCloseTabs
    )
    visualEffectView.subviews.forEach { $0.removeFromSuperview() }

    let hostingView = NSHostingView(rootView: tabBarView)
    hostingView.frame = visualEffectView.bounds
    hostingView.autoresizingMask = [.width, .height]
    hostingView.wantsLayer = true
    hostingView.layer?.backgroundColor = .clear
    visualEffectView.addSubview(hostingView)
}
```

**Step 3: Add handler methods to TabGroups.swift and update setupGroup**

In `TabGroups.swift`, add three new methods before `handleAppTerminated`:

```swift
func releaseTabs(withIDs ids: Set<CGWindowID>, from group: TabGroup, panel: TabBarPanel) {
    for id in ids {
        guard let window = group.windows.first(where: { $0.id == id }) else { continue }
        windowObserver.stopObserving(window: window)
        expectedFrames.removeValue(forKey: window.id)

        if let frame = AccessibilityHelper.getFrame(of: window.element) {
            let delta = max(group.tabBarSqueezeDelta, ScreenCompensation.tabBarHeight)
            let expanded = ScreenCompensation.expandFrame(frame, undoingSqueezeDelta: delta)
            let element = window.element
            AccessibilityHelper.setSize(of: element, to: expanded.size)
            AccessibilityHelper.setPosition(of: element, to: expanded.origin)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                AccessibilityHelper.setPosition(of: element, to: expanded.origin)
                AccessibilityHelper.setSize(of: element, to: expanded.size)
            }
        }
    }

    groupManager.releaseWindows(withIDs: ids, from: group)

    if !groupManager.groups.contains(where: { $0.id == group.id }) {
        handleGroupDissolution(group: group, panel: panel)
    } else if let newActive = group.activeWindow {
        panel.orderAbove(windowID: newActive.id)
    }
    evaluateAutoCapture()
}

func moveTabsToNewGroup(withIDs ids: Set<CGWindowID>, from group: TabGroup, panel: TabBarPanel) {
    let windowsToMove = group.windows.filter { ids.contains($0.id) }
    guard !windowsToMove.isEmpty else { return }

    // Capture frame/squeeze before modifying the old group — windows are already
    // sized for tab-bar mode, so we pass the existing frame directly to setupGroup
    // to avoid double-squeezing through createGroup → applyClamp.
    let frame = group.frame
    let squeezeDelta = group.tabBarSqueezeDelta

    for window in windowsToMove {
        windowObserver.stopObserving(window: window)
        expectedFrames.removeValue(forKey: window.id)
    }

    groupManager.releaseWindows(withIDs: ids, from: group)

    if !groupManager.groups.contains(where: { $0.id == group.id }) {
        handleGroupDissolution(group: group, panel: panel)
    } else if let newActive = group.activeWindow {
        raiseAndUpdate(newActive, in: group)
        panel.orderAbove(windowID: newActive.id)
    }

    // Use setupGroup directly with the known frame to avoid re-clamping
    setupGroup(with: windowsToMove, frame: frame, squeezeDelta: squeezeDelta)
}

func closeTabs(withIDs ids: Set<CGWindowID>, from group: TabGroup, panel: TabBarPanel) {
    for id in ids {
        guard let window = group.windows.first(where: { $0.id == id }) else { continue }
        windowObserver.stopObserving(window: window)
        expectedFrames.removeValue(forKey: window.id)
        AccessibilityHelper.closeWindow(window.element)
    }

    groupManager.releaseWindows(withIDs: ids, from: group)

    if !groupManager.groups.contains(where: { $0.id == group.id }) {
        handleGroupDissolution(group: group, panel: panel)
    } else if let newActive = group.activeWindow {
        raiseAndUpdate(newActive, in: group)
        panel.orderAbove(windowID: newActive.id)
    }
    evaluateAutoCapture()
}
```

Then update the `panel.setContent(...)` call inside `setupGroup` to pass the new callbacks:

```swift
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
    onCloseTab: { [weak self, weak panel] index in
        guard let panel else { return }
        self?.closeTab(at: index, from: group, panel: panel)
    },
    onAddWindow: { [weak self] in
        self?.showWindowPicker(addingTo: group)
    },
    onReleaseTabs: { [weak self, weak panel] ids in
        guard let panel else { return }
        self?.releaseTabs(withIDs: ids, from: group, panel: panel)
    },
    onMoveToNewGroup: { [weak self, weak panel] ids in
        guard let panel else { return }
        self?.moveTabsToNewGroup(withIDs: ids, from: group, panel: panel)
    },
    onCloseTabs: { [weak self, weak panel] ids in
        guard let panel else { return }
        self?.closeTabs(withIDs: ids, from: group, panel: panel)
    }
)
```

**Step 4: Build to verify everything compiles**

Run: `scripts/build.sh`
Expected: PASS

**Step 5: Run tests**

Run: `scripts/test.sh`
Expected: PASS

**Step 6: Commit**

```bash
git add Tabbed/features/TabGroups/TabBarView.swift Tabbed/features/TabGroups/TabBarPanel.swift Tabbed/features/TabGroups/TabGroups.swift
git commit -m "feat: add multi-select, context menu, drag-detach, and multi-tab callbacks"
```

---

### Task 5: Manual testing and edge case fixes

**No test file changes — this is integration verification.**

**Step 1: Build and run the app**

Run: `scripts/build.sh`

**Step 2: Manual test checklist**

Test each scenario:

1. **Plain click** — clicking a tab switches to it, clears any selection
2. **Cmd-click** — toggles tabs in/out of selection without switching active tab
3. **Shift-click** — selects range from last-clicked to shift-clicked
4. **Selected tabs highlight** — selected (non-active) tabs show accent color background
5. **Context menu on unselected tab** — shows menu, acts on just that tab, clears selection
6. **Context menu on selected tab** — shows menu, acts on all selected tabs
7. **"Release from Group"** — releases tab(s) as standalone windows (expanded)
8. **"Move to New Group"** — creates new group with selected tabs at same frame
9. **"Close Windows"** — closes the windows
10. **Single-tab drag** — reorders within bar (existing behavior preserved)
11. **Multi-tab drag** — drags selected tabs as a block, reorders within bar
12. **Drag-off-bar** — vertical drag (>30px) detaches tabs to a new group
13. **Edge: release all tabs** — group dissolves
14. **Edge: move all tabs to new group** — old group dissolves, new one created
15. **Edge: window externally closed** — selection clears stale IDs

**Step 3: Fix any issues found, commit**

```bash
git add -u
git commit -m "fix: address edge cases from manual testing"
```
