# CLAUDE.md

## What This Is

Tabbed is a native macOS menu bar utility that groups arbitrary windows into tab groups with a browser-style floating tab bar. It uses the Accessibility API to manage window positions, detect focus changes, and synchronize grouped windows.

## Build & Run

Requires: Xcode CLI tools, XcodeGen (`brew install xcodegen`), macOS 13.0+

```bash
./buildandrun.sh
./run.sh

# Build
xcodegen generate && xcodebuild -project Tabbed.xcodeproj -scheme Tabbed -derivedDataPath build build

# Run tests
xcodegen generate && xcodebuild -project Tabbed.xcodeproj -scheme TabbedTests -derivedDataPath build test
```

After adding/removing source files or changing `project.yml`, regenerate the Xcode project with `xcodegen generate` before building.

The `.xcodeproj` is gitignored — `project.yml` is the source of truth for project configuration.

## Architecture

**AppDelegate** (`Tabbed/AppDelegate.swift`) is the central orchestrator. It owns all managers, creates tab bar panels, wires up observer callbacks, and coordinates frame synchronization. This is the largest file and where most integration logic lives.

**Data flow:** WindowManager discovers windows → user selects in WindowPickerView → GroupManager creates TabGroup → AppDelegate creates TabBarPanel and registers WindowObserver notifications → observer callbacks flow back to AppDelegate handlers for sync.

### Key Layers

- **Models** (`Tabbed/Models/`) — `WindowInfo` (wraps CGWindowID + AXUIElement) and `TabGroup` (ObservableObject with published windows/activeIndex/frame)
- **Managers** (`Tabbed/Managers/`) — `WindowManager` (window discovery via CG+AX APIs), `GroupManager` (group lifecycle), `WindowObserver` (AX notification subscriptions, one observer per PID)
- **Views** (`Tabbed/Views/`) — SwiftUI views hosted in AppKit containers. `TabBarPanel` is an NSPanel subclass (not a SwiftUI Window) for z-order control and non-activating behavior
- **Accessibility** (`Tabbed/Accessibility/`) — `AccessibilityHelper` (thin AX API wrapper) and `CoordinateConverter` (AX top-left ↔ AppKit bottom-left coordinate conversion)

### Critical Patterns

**Coordinate systems:** macOS Accessibility/CG uses top-left origin (Y down), AppKit uses bottom-left origin (Y up). `CoordinateConverter` bridges these using primary screen height. All model frames use AX coordinates; conversion happens at the AppKit boundary (TabBarPanel positioning).

**AXUIElement ↔ CGWindowID bridging:** Uses private API `_AXUIElementGetWindow` to get the CGWindowID from an AXUIElement. This is the only way to correlate CG window list entries with AX elements.

**Notification suppression:** Programmatic window moves trigger AX notifications that would cause feedback loops. `AppDelegate.suppressedWindowIDs` with per-window cancellable `DispatchWorkItem` timers (0.2s) prevents this. New programmatic changes cancel/reset the timer.

**Frame synchronization:** All windows in a group share the same frame. When the active window moves/resizes, all other windows sync to match, the tab bar repositions, and notifications are suppressed during sync.

**Focus stealing prevention:** TabBarPanel uses `.nonactivatingPanel` style so clicking tabs doesn't steal focus from the managed window. Tab switches use `AXRaise` action.

**Full-screen detection:** If a window resize makes it fill the screen (width ≥ screen width AND height ≥ screen height), the window is released from its group.

## App Configuration

- `LSUIElement: true` in Info.plist — menu bar app, no Dock icon
- App Sandbox disabled (required for Accessibility API)
- Code signing: unsigned (`-`) for local development
