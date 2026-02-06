# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

Tabbed is a native macOS menu bar utility that groups arbitrary windows into tab groups with a browser-style floating tab bar. It uses the macOS Accessibility API to manage window positions, detect focus changes, and synchronize grouped windows.

## Build & Run

Requires: Xcode CLI tools, XcodeGen (`brew install xcodegen`), macOS 13.0+

```bash
# Build and run (requires .env with DEVELOPMENT_TEAM — see development.md)
./buildandrun.sh

# Run without rebuilding
./run.sh

# Manual build
xcodegen generate && xcodebuild -project Tabbed.xcodeproj -scheme Tabbed -derivedDataPath build build

# Run tests
xcodegen generate && xcodebuild -project Tabbed.xcodeproj -scheme TabbedTests -derivedDataPath build test
```

The `.xcodeproj` is gitignored — `project.yml` is the source of truth. Run `xcodegen generate` after adding/removing source files or changing `project.yml`.

The app requires Accessibility permission (System Settings > Privacy & Security > Accessibility).

## Architecture

**AppDelegate** (`Tabbed/AppDelegate.swift`) is the central orchestrator. It owns all managers, creates tab bar panels, wires up observer callbacks, and coordinates frame synchronization. This is the largest file and where most integration logic lives.

**Data flow:** WindowManager discovers windows → user selects in WindowPickerView → GroupManager creates TabGroup → AppDelegate creates TabBarPanel and registers WindowObserver notifications → observer callbacks flow back to AppDelegate for sync.

### Key Layers

- **Models** (`Tabbed/Models/`) — `WindowInfo` (wraps CGWindowID + AXUIElement) and `TabGroup` (ObservableObject with published windows/activeIndex/frame)
- **Managers** (`Tabbed/Managers/`) — `WindowManager` (window discovery via CG+AX APIs), `GroupManager` (group lifecycle, requires ≥2 windows), `WindowObserver` (AX notification subscriptions, one observer per PID)
- **Views** (`Tabbed/Views/`) — SwiftUI views hosted in AppKit containers. `TabBarPanel` is an NSPanel subclass (not a SwiftUI Window) for z-order control and non-activating behavior. `MenuBarView` is the menu bar dropdown. `WindowPickerView` is the window selection UI.
- **Accessibility** (`Tabbed/Accessibility/`) — `AccessibilityHelper` (thin AX API wrapper) and `CoordinateConverter` (AX ↔ AppKit coordinate conversion)

### Critical Patterns

**Coordinate systems:** Accessibility/CG uses top-left origin (Y down), AppKit uses bottom-left origin (Y up). `CoordinateConverter` bridges these using primary screen height. All model frames use AX coordinates; conversion happens at the AppKit boundary (TabBarPanel positioning).

**AXUIElement ↔ CGWindowID bridging:** Uses private API `_AXUIElementGetWindow` to get CGWindowID from an AXUIElement. This is the only way to correlate CG window list entries with AX elements.

**Notification suppression:** Programmatic window moves trigger AX notifications that would cause feedback loops. `AppDelegate.suppressedWindowIDs` with per-window cancellable `DispatchWorkItem` timers (0.2s) prevents re-entrant handling.

**Frame synchronization:** All windows in a group share the same frame. When the active window moves/resizes, all other windows sync to match and the tab bar repositions. A delayed re-sync (0.15s) catches animated resizes like double-click maximize.

**Focus stealing prevention:** TabBarPanel uses `.nonactivatingPanel` style mask. Tab switches explicitly activate the owning app and use `AXRaise`.
**Stale AXUIElement handling:** AXUIElements can become stale (e.g., browser tab switches destroy/recreate elements). `raiseWindow` has a fallback chain that re-resolves by CGWindowID. `handleWindowDestroyed` checks if the window still exists on screen before actually releasing it.

## App Configuration

- `LSUIElement: true` in Info.plist — menu bar app, no Dock icon
- App Sandbox disabled (required for Accessibility API)
- Code signing: "Apple Development" with team ID from `.env` file (persists accessibility permissions across rebuilds)
