# Tabbed — Design Document

A macOS menu bar utility that groups arbitrary windows into tab groups with a browser-style tab bar.

## Core Concept

- Select open windows and group them together
- All windows in a group share the same position and size
- A floating tab bar sits above the grouped windows, letting the user switch between them
- Multiple independent groups can exist simultaneously

## Technology

Swift + AppKit. Pure native Mac app. SwiftUI for UI content inside AppKit containers.

If SwiftUI tab drag reordering has issues inside the non-activating `NSPanel`, fall back to implementing just that interaction in AppKit while keeping the rest SwiftUI.

## Architecture

### App Structure

- Menu bar app (`LSUIElement = true`, no Dock icon)
- On launch, checks Accessibility permission via `AXIsProcessTrusted()`
- If not trusted, directs user to System Settings > Privacy & Security > Accessibility
- Menu bar popover (SwiftUI): list of existing groups, "New Group" button, "Quit"
- No App Sandbox (Accessibility API requires it). Distributed directly (DMG or zip), not Mac App Store.

### Key Components

**WindowManager**
- Discovers windows via `CGWindowListCopyWindowInfo`
- Wraps Accessibility API for reading/writing window position, size, and z-order
- Runs `AXObserver` per app to track:
  - `kAXFocusedWindowChangedNotification`
  - `kAXMovedNotification`
  - `kAXResizedNotification`
  - `kAXUIElementDestroyedNotification`
  - `kAXTitleChangedNotification`

**GroupManager**
- Maintains list of tab groups
- Each group holds: member windows, active tab index, group frame
- Handles adding/removing windows from groups
- Prevents a window from being in multiple groups

**TabBarPanel** (one per group)
- `NSPanel` subclass: borderless, `.nonactivatingPanel`, `becomesKeyOnlyIfNeeded = true`
- Window level: `.normal` (0)
- `isMovableByWindowBackground = true` for dragging the whole group
- `NSVisualEffectView` for native translucent material
- Hosts `NSHostingView` with SwiftUI tab strip view
- Positioned via `order(.above, relativeTo:)` on the active window's CGWindowID

**WindowPicker** (SwiftUI)
- Panel listing all open windows for selection
- Shows app icon + app name + window title
- Windows already in a group are shown as disabled/grayed out
- Appears on "New Group" or "+" button click

### AXUIElement to CGWindowID Bridge

Uses the private but widely-used function:
```swift
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: inout CGWindowID) -> AXError
```

## Z-Order Behavior

All grouped windows share the same frame. Only the active one is visible — the others are directly behind it in the z-order stack.

```
Tab bar panel     <- our NSPanel, directly above active window
Window A          <- active tab (visible)
Window B          <- behind A (hidden)
Window C          <- behind A (hidden)
```

### Switching Tabs

1. `AXUIElementPerformAction(targetWindow, kAXRaiseAction)` to bring the target window to front
2. `tabBarPanel.order(.above, relativeTo: targetWindowID)` to keep the panel above it
3. Update tab bar UI to highlight the new active tab
4. Fallback if `kAXRaiseAction` doesn't work: `NSRunningApplication.activate()` + AX position setting

### Focus Stealing Prevention

- `NSPanel` with `.nonactivatingPanel` — our app never becomes the active application
- `becomesKeyOnlyIfNeeded = true` — the panel doesn't become key window on click
- Clicking a tab fires on first click, no double-click needed
- `order(.above, relativeTo:)` only changes z-order, does not activate or steal focus

### External Focus Changes

When a grouped window gains focus externally (Cmd+Tab, Mission Control, clicking it):
1. `kAXFocusedWindowChangedNotification` fires
2. We update our active tab to match
3. Re-position the tab bar panel above the newly focused window

When an unrelated app is focused, the tab bar naturally falls behind it — no manual hiding needed (level 0).

## Window Tracking & Synchronization

### Group Creation

1. User selects windows in the picker, clicks "Create Group"
2. Take the first selected window's frame as the group frame
3. Subtract tab bar height (~36px) from the top: move the window down by 36px, shrink height by 36px
4. Resize/reposition all grouped windows to match via `AXUIElementSetAttributeValue`
5. Create the `TabBarPanel`, position it in the 36px gap above the windows
6. Bring the first window to front, order the panel above it

### Active Window Moved (drag end)

1. `kAXMovedNotification` fires
2. Read the new position
3. If the window is at the top of the screen, push it down to make room for the tab bar (clamp to `NSScreen.visibleFrame`)
4. Move the tab bar panel to match (offset above)
5. Move all other grouped windows to the same position

### Active Window Resized

1. `kAXResizedNotification` fires
2. Read new size and position
3. If at the top of the screen, adjust to make room for tab bar
4. Resize tab bar panel width to match
5. Resize/reposition all other grouped windows to match

### Dragging the Active Window

Dragging the active window does NOT release it from the group. The window moves freely with the drag; the tab bar and other grouped windows stay in place. When the drag ends (`kAXMovedNotification`), everything snaps to the new position. This avoids jitter from IPC overhead.

During the drag, inactive windows may be briefly visible behind the active window. This is acceptable.

## Tab Bar UI

### Design Intent

Native macOS look and feel (system materials, fonts, colors) but browser-inspired UX — tabs behave like browser tabs (reorderable, releasable, add with "+").

### Visual Style

- `NSVisualEffectView` with `.hudWindow` or `.menu` material
- System font, system colors
- Rounded corners on top edges, bottom flush against window
- Height: ~36px

### Tab Layout

```
[icon Title     release] [icon Title     release] [+]
 ^ active tab             ^ inactive tabs          ^ add window
```

- Each tab: app icon (16px) + window title (truncated with ellipsis)
- Active tab: highlighted/elevated background
- Inactive tabs: subdued appearance
- Release button: appears on hover, not always visible
- Tabs fill available width equally, compress when many
- Tab bar width matches window width exactly
- "+" button fixed at right end

### Interactions

- Click tab: switch active window
- Hover tab: show release button
- Click release button: remove window from group (window stays in place, expands upward by 36px into tab bar area)
- Drag tab: reorder within the strip
- Drag empty space on tab bar: move the whole group (windows snap on release)
- "+" button: open window picker

## Coordinate System

macOS has two coordinate systems:
- **Accessibility API / Core Graphics**: origin top-left, Y increases downward
- **AppKit (NSWindow)**: origin bottom-left, Y increases upward

Conversion: `appKitY = primaryScreenHeight - cgY - windowHeight`

All AX calls use top-left coordinates consistently. Convert only when setting NSPanel frame.

## Edge Cases

### Native Full-Screen / Split View

When a grouped window enters native full-screen or Split View, release it from the group automatically. Detect via window frame matching screen bounds or AX notifications.

### Window at Top of Screen

When the active window is moved/resized to the top of the screen (e.g. double-click title bar to maximize), detect this and push the window down to make room for the tab bar. Clamp to `NSScreen.visibleFrame`.

### Minimum / Maximum Window Sizes

Some apps enforce min/max sizes. After setting a new size via AX, read it back to confirm. If the app rejects the resize, accept the limitation — users will learn which apps work well with Tabbed.

### Window Closed Externally

Detect via `kAXUIElementDestroyedNotification`. Remove from group. If group drops to one window, dissolve the group (remove panel, last window expands upward by 36px).

### App of Grouped Window Quits

Same handling as window closed.

### Window Title Changes

Observe `kAXTitleChangedNotification`. Update the tab label.

### Multiple Monitors

Groups work on any monitor. When the active window is dragged to another monitor, other windows and tab bar follow on snap (drag end).

## App Lifecycle

- **Launch**: Check accessibility permission, show menu bar icon
- **Quit**: Remove all tab bar panels, windows stay in place at their current size/position
- **No persistence in MVP**: Groups are not saved across app restarts

## Permissions

- **Accessibility**: Required. Only permission needed.
- **Screen Recording**: Not needed.
- **App Sandbox**: Disabled (incompatible with Accessibility API).

## Post-MVP Features

- Keyboard shortcuts for tab switching (using Hyper key to avoid conflicts with in-app shortcuts)
- Drag a tab out of the tab bar to release it
- Drag a tab into another group's tab bar to move between groups
- Persist groups across app restarts (match by app bundle ID + window title, best-effort)
- Tab thumbnails for inactive windows via ScreenCaptureKit
