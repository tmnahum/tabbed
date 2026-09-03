# Airtight Plan: Split Fullscreen Groups Into A Separate Screen-Level Mode

## Summary

This change introduces a real mode split for tab groups:

- `bound` mode: existing behavior. The group owns a shared frame and keeps its windows bound together.
- `fullscreen` mode: new behavior. The group no longer owns member window positions or sizes. It becomes a screen-level tab strip that:
  - sits at the top of the screen at full visible width,
  - makes room for itself by pushing group windows below the bar without stretching them,
  - switches between windows by focusing them only,
  - leaves individual window sizes/positions alone,
  - toggles back to bound mode and restores the pre-fullscreen shared frame.

This is not a small tweak to tab switching. It is a structural change: the codebase currently assumes `group.frame` is the canonical geometry for nearly every group behavior. The implementation must explicitly replace that assumption with a mode-aware model.

## Locked Product Spec

### Core behavior

- Double-clicking a tab bar toggles group display mode.
- `bound -> fullscreen`
- `fullscreen -> bound`

### Bound mode

- Preserve current behavior.
- Group owns one shared frame.
- Moving/resizing one grouped window syncs the rest.
- Tab switching may continue to snap the selected tab to the group frame.
- Existing maximize/restore semantics are replaced by the new fullscreen-mode toggle.

### Fullscreen mode

- The tab bar is pinned to the top of one screen.
- The tab bar width is the screen’s visible width.
- The tab bar height remains `ScreenCompensation.tabBarHeight`.
- The tab bar is the aligned object. Member windows do not need to be geometrically aligned.
- Clicking a tab only focuses/raises that window.
- Clicking a tab does not move or resize that window.
- Group windows are pushed below the top bar if they intrude into the reserved strip.
- Group windows are not stretched to match the screen or each other.
- Moving/resizing one window in fullscreen mode does not move/resize sibling windows.
- Exiting fullscreen mode restores the exact shared frame the group had when it entered fullscreen mode.

### Screen ownership

- A fullscreen group belongs to one screen at a time.
- The active/focused window determines which screen the fullscreen bar belongs to.
- If the active window changes to a different screen, the bar moves to that screen.
- A fullscreen group may have windows on multiple screens, but only one bar exists, on the active screen.

### Native macOS fullscreen windows

- Native per-window fullscreen remains distinct from group fullscreen mode.
- Group fullscreen mode must not collapse just because one member window enters native fullscreen.
- A native-fullscreen member window cannot become the visible bound-layout anchor.
- Existing native-fullscreen tracking should stay in place, but fullscreen-group behavior must stop restoring native-fullscreen exits to `group.frame`.

## Canonical Settings And Planning Consequences

### Current enabled settings that matter

From the live `com.tabbed.Tabbed` preferences domain:

- `restoreMode = always`
- `autoCaptureMode = whenMaximizedOrOnly`
- `autoCaptureRequireResizableToMatchGroup = true`
- `tabBar style = compact`
- `groupCounterMode = maximizedAndPositionAligned`
- `showDragHandle = true`
- `showTooltip = true`
- `showCloseConfirmation = true`
- switcher uses `titles`
- `splitSeparatedTabsIntoSeparateGroups = true`
- `splitSuperPinnedTabsIntoSeparateGroup = true`
- `includeSuperPinnedTabsInInGroupSwitcher = true`

### Settings policy for this change

- Do not collapse settings unless necessary.
- Do not add new fullscreen-only settings unless implementation proves a current setting is structurally incompatible.
- Reinterpret maximized-related settings so fullscreen groups participate coherently.

### Specific locked reinterpretations

- `autoCaptureMode = whenMaximized`, `whenOnly`, `whenMaximizedOrOnly`
  - fullscreen groups count as “maximized-like” for these policies.
- `groupCounterMode = maximizedAndPositionAligned`
  - fullscreen groups on the same screen count as aligned because the bar is aligned at the screen top, even if windows are not.
- `hideInactiveWindows`
  - treat as dead legacy state unless implementation discovers active code using it.
  - It is not part of this design.

## Architecture Changes

### 1. Add explicit group display mode

In [TabGroup.swift](/Users/tmn/.t3/worktrees/tabbed/t3code-ceecea20/Tabbed/features/TabGroups/TabGroup.swift), add:

```swift
enum TabGroupDisplayMode: String, Codable {
    case bound
    case fullscreen
}
```

Add:

- `@Published var displayMode: TabGroupDisplayMode = .bound`

Add fullscreen session state:

```swift
struct FullscreenGroupState: Codable, Equatable {
    var screenIdentity: ScreenIdentity
    var preFullscreenFrame: CGRect
}
```

Also add a screen identity type that can be resolved across sessions:

```swift
struct ScreenIdentity: Codable, Equatable {
    var frame: CodableRect
}
```

Use visible-frame identity, not display UUID, because the codebase already reasons mostly in geometry and screen UUID persistence is not currently established.

### 2. Re-scope `group.frame`

`group.frame` must no longer mean “current geometry of the group” in fullscreen mode.

New meaning:

- In `bound` mode:
  - `group.frame` remains the live shared frame.
- In `fullscreen` mode:
  - `group.frame` is preserved only as the bound-mode restore target.
  - it is not updated from ordinary move/resize events.
  - it is not used to position the fullscreen bar.
  - it is not used to infer member window layout.

This is the central invariant that the implementation must maintain.

### 3. Split panel placement APIs

In [TabBarPanel.swift](/Users/tmn/.t3/worktrees/tabbed/t3code-ceecea20/Tabbed/features/TabGroups/TabBarPanel.swift), keep window-relative placement for bound mode and add screen-relative placement for fullscreen mode.

Required API additions:

- `positionBound(above windowFrame: CGRect, isVisuallyMaximized: Bool)`
- `positionFullscreen(on visibleFrame: CGRect)`
- `showFullscreen(on visibleFrame: CGRect, relativeTo windowID: CGWindowID)`

Do not keep using `positionAbove(windowFrame:)` as the generic API. That API shape encodes the old assumption.

### 4. Add fullscreen-only room-making helper

In [ScreenCompensation.swift](/Users/tmn/.t3/worktrees/tabbed/t3code-ceecea20/Tabbed/features/TabGroups/ScreenCompensation.swift), add a new pure helper:

```swift
static func pushBelowTopBarWithoutStretch(
    frame: CGRect,
    visibleFrame: CGRect
) -> CGRect
```

Behavior:

- Reserved top strip:
  - `visibleFrame.minY ..< visibleFrame.minY + tabBarHeight`
- If a window’s top edge intrudes into that strip:
  - move its `origin.y` down to `visibleFrame.minY + tabBarHeight`
  - reduce height only by the amount required to keep the bottom edge fixed
- Never modify width
- Never horizontally reposition
- Never increase height
- If the result would shrink below a minimal height, clamp to a non-negative sensible minimum already consistent with existing code expectations

This helper is separate from `clampResult`, which is bound/shared-layout logic.

### 5. Add explicit mode toggle orchestration

Replace `toggleZoom(group:panel:)` in [TabGroups.swift](/Users/tmn/.t3/worktrees/tabbed/t3code-ceecea20/Tabbed/features/TabGroups/TabGroups.swift) with:

- `toggleGroupDisplayMode(group:panel:)`
- `enterFullscreenMode(group:panel:)`
- `exitFullscreenMode(group:panel:)`

#### Enter fullscreen mode

Steps:

1. Resolve active window.
2. Resolve screen from active window frame.
3. Save:
   - `group.displayMode = .fullscreen`
   - `group.fullscreenState.preFullscreenFrame = group.frame`
   - `group.fullscreenState.screenIdentity = resolved visible frame`
4. Position bar fullscreen on that screen.
5. For each non-native-fullscreen group window:
   - read its current frame
   - push below top bar if needed
   - do not synchronize to any common frame
6. Order panel above active window and move panel to active window’s space.
7. Refresh auto-capture and counters.

#### Exit fullscreen mode

Steps:

1. Load `preFullscreenFrame`.
2. Set `group.displayMode = .bound`
3. Clear `fullscreenState`
4. Restore `group.frame = preFullscreenFrame`
5. Sync every visible non-native-fullscreen window to `group.frame`
6. Reposition bar in bound mode above the restored shared frame
7. Refresh auto-capture and counters.

## Mode-Aware Behavior By Code Path

### Tab switching

In `switchTab(in:to:panel:)`:

#### Bound mode
- Keep current behavior:
  - update active tab
  - record focus
  - set selected window to `group.frame`
  - bring to front

#### Fullscreen mode
- update active tab
- record focus
- focus/raise selected window
- do not call `setFrameAsync` on the selected window
- resolve selected window’s screen
- update `fullscreenState.screenIdentity` if screen changed
- reposition fullscreen bar on that screen
- order bar above selected window

### Focus events

In `handleWindowFocused` and `handleResolvedAppActivation`:

#### Bound mode
- preserve current behavior

#### Fullscreen mode
- allow active tab to track the focused group member
- do not resize/move that window
- update bar screen ownership from the focused window
- keep commit-echo and switcher suppression logic unchanged

### Window moved

In `handleWindowMoved`:

#### Bound mode
- preserve current shared sync logic

#### Fullscreen mode
- do not write moved frame into `group.frame`
- do not sync siblings
- if moved window is now on another screen and becomes active owner, move the bar there
- if moved window overlaps the top reserved strip, push it below the bar without stretch
- refresh counters/auto-capture after any screen change

### Window resized

In `handleWindowResized`:

#### Bound mode
- preserve current shared sync logic and delayed resync

#### Fullscreen mode
- do not write resized frame into `group.frame`
- do not sync siblings
- do not schedule bound-mode resync work
- if resized window overlaps the top reserved strip, push it below the bar without stretch
- keep fullscreen bar on the active screen

### Resync work items

Current delayed resync logic assumes active window defines shared frame.

In fullscreen mode:

- never schedule these resyncs
- cancel outstanding resync for a group when entering fullscreen mode
- ignore stale fullscreen-mode resync callbacks if they fire after mode change

### Bar drag

In fullscreen mode, dragging the bar as a shared group move is incompatible with the new semantics.

Decision:

- Disable bar-drag repositioning in fullscreen mode.
- The bar is screen-pinned.
- Keep drag handle visible if desired visually, but it must not initiate shared window movement in fullscreen mode.
- Simpler and clearer option:
  - hide/disable drag affordance while `displayMode == .fullscreen`
  - keep the setting intact for bound mode

This is a justified mode-specific behavior difference, not a setting collapse.

### Cross-panel drag/drop and tab rearrangement

These features remain available in fullscreen mode, but geometry rules change:

- moving tabs between fullscreen groups must not normalize frames
- adding a window into a fullscreen group should only push it below the top strip if necessary
- creating a new group from detached tabs defaults to `bound` mode
- detached windows keep their current frame
- dissolving a fullscreen group must not expand windows via `tabBarSqueezeDelta`

### Group creation and setup

`setupGroup` and `createGroup` continue to create groups in bound mode.

Do not add a second setup pipeline. Instead:

- create in bound mode as today
- any future direct fullscreen creation should call `enterFullscreenMode(...)` immediately after setup

## Auto-Capture And Counter Policy Rewrite

### Current problem

`AutoCapture.isGroupMaximized(_:)` and counter participation currently depend on `group.frame` geometry. That is invalid for fullscreen mode.

### New participation model

Introduce a helper in AppDelegate or policy layer:

- `groupPresentationState(for:) -> GroupPresentationState`

```swift
enum GroupPresentationState {
    case bound(frame: CGRect, squeezeDelta: CGFloat, screen: NSScreen?)
    case fullscreen(screen: NSScreen?)
}
```

### Auto-capture

Policy mapping:

- `never`
  - unchanged
- `always`
  - unchanged
- `whenMaximized`
  - true for:
    - fullscreen groups
    - bound groups whose shared frame is maximized under old geometry rules
- `whenOnly`
  - based on group count on screen/space, independent of mode
- `whenMaximizedOrOnly`
  - union of the above

`autoCaptureRequireResizableToMatchGroup` interpretation:

- bound mode:
  - unchanged
- fullscreen mode:
  - relax shared-size matching
  - only require that the window can be pushed below the top bar without impossible geometry
  - do not require resizability to a shared frame, because fullscreen groups do not own a shared frame

This is an intentional reinterpretation required by the new modality.

### Maximized/aligned counters

For `groupCounterMode = maximizedAndPositionAligned`:

- fullscreen groups on the same screen participate together automatically
- bound groups continue to use the existing geometric alignment/maximized criteria
- fullscreen and bound groups may coexist in the same space
  - fullscreen groups participate by screen-top alignment
  - bound groups participate by frame alignment
- Do not require fullscreen windows themselves to align

## Session Restore

### Snapshot additions

Extend [SessionSnapshot.swift](/Users/tmn/.t3/worktrees/tabbed/t3code-ceecea20/Tabbed/features/SessionRestore/SessionSnapshot.swift) to persist:

- `displayMode`
- `fullscreenState.screenIdentity`
- `fullscreenState.preFullscreenFrame`

### Restore behavior

#### Bound groups
- unchanged

#### Fullscreen groups
1. Restore membership and tab ordering.
2. Restore saved `displayMode = .fullscreen`.
3. Restore `preFullscreenFrame`.
4. Re-resolve saved screen from `screenIdentity`.
5. If screen resolves:
   - show fullscreen bar on that screen
   - individually push windows below top strip if needed
   - do not normalize to `group.frame`
6. If screen does not resolve:
   - fall back to `bound` mode
   - use `preFullscreenFrame` as restore frame

### Focus sync after restore

Current restore code syncs active tab to actual focused window. Keep that, but in fullscreen mode it must be a focus-only update.

## Native Fullscreen Member Behavior

### Enter native fullscreen

When a member window enters native fullscreen:

- keep existing `isFullscreened` tracking
- if it was the active tab, choose next visible non-native-fullscreen tab if available
- if all tabs are native fullscreen:
  - hide bar as current code already does
- do not exit group fullscreen mode automatically

### Exit native fullscreen

#### Bound mode
- preserve current shared-frame restoration behavior

#### Fullscreen mode
- restore visibility
- if the exiting window becomes active, move the bar to its screen
- push it below the top strip if needed
- do not restore it to `group.frame`

## Public Interface / Type Changes

### Additions

In [TabGroup.swift](/Users/tmn/.t3/worktrees/tabbed/t3code-ceecea20/Tabbed/features/TabGroups/TabGroup.swift):

- `TabGroupDisplayMode`
- `FullscreenGroupState`
- `ScreenIdentity`

In [TabBarPanel.swift](/Users/tmn/.t3/worktrees/tabbed/t3code-ceecea20/Tabbed/features/TabGroups/TabBarPanel.swift):

- screen-relative fullscreen positioning APIs

In [ScreenCompensation.swift](/Users/tmn/.t3/worktrees/tabbed/t3code-ceecea20/Tabbed/features/TabGroups/ScreenCompensation.swift):

- `pushBelowTopBarWithoutStretch(...)`

In session restore snapshot types:

- new serialized mode/fullscreen fields

### No new user-facing settings by default

Keep current settings UI unchanged unless implementation forces one narrow change:

- fullscreen mode disables shared bar dragging regardless of `showDragHandle`
- this is a behavior difference, not a new setting

## Files To Change

Primary:

- [TabGroup.swift](/Users/tmn/.t3/worktrees/tabbed/t3code-ceecea20/Tabbed/features/TabGroups/TabGroup.swift)
- [TabGroups.swift](/Users/tmn/.t3/worktrees/tabbed/t3code-ceecea20/Tabbed/features/TabGroups/TabGroups.swift)
- [WindowEventHandlers.swift](/Users/tmn/.t3/worktrees/tabbed/t3code-ceecea20/Tabbed/features/TabGroups/WindowEventHandlers.swift)
- [TabBarPanel.swift](/Users/tmn/.t3/worktrees/tabbed/t3code-ceecea20/Tabbed/features/TabGroups/TabBarPanel.swift)
- [ScreenCompensation.swift](/Users/tmn/.t3/worktrees/tabbed/t3code-ceecea20/Tabbed/features/TabGroups/ScreenCompensation.swift)
- [AutoCapture.swift](/Users/tmn/.t3/worktrees/tabbed/t3code-ceecea20/Tabbed/features/AutoCapture/AutoCapture.swift)
- [MaximizedGroupCounterPolicy.swift](/Users/tmn/.t3/worktrees/tabbed/t3code-ceecea20/Tabbed/features/TabGroups/MaximizedGroupCounterPolicy.swift)
- [SessionSnapshot.swift](/Users/tmn/.t3/worktrees/tabbed/t3code-ceecea20/Tabbed/features/SessionRestore/SessionSnapshot.swift)
- [SessionRestore.swift](/Users/tmn/.t3/worktrees/tabbed/t3code-ceecea20/Tabbed/features/SessionRestore/SessionRestore.swift)
- [SessionManager.swift](/Users/tmn/.t3/worktrees/tabbed/t3code-ceecea20/Tabbed/features/SessionRestore/SessionManager.swift)

Secondary audit targets:

- [TabBarView.swift](/Users/tmn/.t3/worktrees/tabbed/t3code-ceecea20/Tabbed/features/TabGroups/TabBarView.swift)
- any code path that:
  - writes `group.frame`
  - reads `group.frame` as live geometry truth
  - calls `setFrameAsync` for all group windows
  - uses `isGroupMaximized(group)` as a behavioral switch

## Test Plan

### Unit tests

#### `ScreenCompensationTests`
Add:

- fullscreen push helper moves top-overlapping window down
- fullscreen push helper preserves width
- fullscreen push helper preserves bottom edge where possible
- fullscreen push helper does nothing when already below bar
- fullscreen push helper handles tiny windows safely

#### `TabGroupFocusTests`
Add:

- fullscreen mode tab switch changes active tab only
- fullscreen mode tab switch does not mutate `group.frame`
- fullscreen mode MRU behavior remains unchanged

#### New `FullscreenGroupModeTests`
Add:

- enter fullscreen stores `preFullscreenFrame`
- exit fullscreen restores `preFullscreenFrame`
- fullscreen mode does not overwrite restore frame during ordinary moves/resizes
- fullscreen screen identity updates when active window changes screens
- detached tab from fullscreen group keeps its frame

#### `AutoCapturePolicyTests` / `MaximizedGroupCounterPolicyTests`
Add:

- fullscreen groups count as maximized-like
- fullscreen groups on same screen count as aligned for counters
- bound groups still use geometry-based aligned/maximized behavior
- mixed fullscreen/bound scenarios are deterministic

#### `SessionRestore` tests
Add:

- fullscreen groups serialize and restore mode/state
- unresolved restore screen falls back to bound mode
- restored fullscreen group focuses active tab without resizing it

### Integration-style behavior tests where seams allow

Add coverage for:

- fullscreen mode tab switch does not call shared-frame sync path
- fullscreen mode move does not resize siblings
- fullscreen mode resize does not resize siblings
- exiting fullscreen mode resynchronizes visible windows to saved `preFullscreenFrame`
- fullscreen panel uses screen visible width, not active window width

## Acceptance Criteria

- Double-click on a bound group enters fullscreen group mode.
- The bar becomes screen-top and full-width.
- In fullscreen group mode, clicking a tab focuses that window without changing its frame.
- In fullscreen group mode, windows are pushed below the bar if needed but are not stretched.
- In fullscreen group mode, moving/resizing one window does not affect siblings.
- Double-click again exits fullscreen group mode and restores the exact pre-fullscreen shared frame.
- Current bound-mode behavior remains intact.
- Existing settings remain unless strictly necessary to reinterpret behavior.
- Maximized-related settings work coherently with fullscreen groups.
- Session restore preserves fullscreen groups.

## Implementation Order

1. Add explicit mode/state types to `TabGroup`.
2. Refactor panel APIs into bound vs fullscreen placement.
3. Add fullscreen push-below-bar geometry helper.
4. Replace zoom/maximize toggle with display-mode toggle.
5. Make tab switching mode-aware.
6. Make focus/move/resize handlers mode-aware.
7. Rewrite auto-capture and counter participation around mode-aware presentation state.
8. Update detach/merge/release paths for fullscreen semantics.
9. Update session snapshot and restore.
10. Add tests.
11. Run `scripts/test.sh`.

## Main Risks And Mitigations

### Risk: hidden assumptions around `group.frame`
Mitigation:
- audit every read/write of `group.frame`
- require explicit mode branch at each behavioral use site

### Risk: delayed resync code fights fullscreen mode
Mitigation:
- cancel and disable `resyncWorkItems` in fullscreen mode

### Risk: counter/auto-capture regressions
Mitigation:
- centralize mode-aware presentation-state helper instead of scattering reinterpretations

### Risk: panel placement bugs across spaces/screens
Mitigation:
- make fullscreen panel placement screen-based, not window-frame-based
- keep `movePanelToWindowSpace` but separate it from geometry choice

## Explicit Assumptions

- Group fullscreen mode replaces the old double-click maximize/restore feature.
- No new settings are added unless implementation proves one is necessary.
- Fullscreen groups remain single-screen bar constructs even if member windows span multiple screens.
- `hideInactiveWindows` is legacy and out of scope unless active references are discovered during implementation.
- Bar dragging is disabled in fullscreen mode because the bar is screen-pinned and windows are no longer group-position-controlled.
