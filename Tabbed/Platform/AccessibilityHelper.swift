import AppKit
import ApplicationServices

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: inout CGWindowID) -> AXError

enum AccessibilityHelper {

    static func checkPermission() -> Bool {
        return AXIsProcessTrusted()
    }

    static func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Window Discovery

    static func getWindowList() -> [[String: Any]] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return windowList.filter { info in
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { return false }
            guard let _ = info[kCGWindowOwnerPID as String] as? pid_t else { return false }
            return true
        }
    }

    /// Check whether a CGWindowID still appears in the on-screen window list.
    static func windowExists(id: CGWindowID) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        return list.contains { ($0[kCGWindowNumber as String] as? CGWindowID) == id }
    }

    static func appElement(for pid: pid_t) -> AXUIElement {
        return AXUIElementCreateApplication(pid)
    }

    static func windowElements(for pid: pid_t) -> [AXUIElement] {
        let app = appElement(for: pid)
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        guard result == .success, let windows = value as? [AXUIElement] else { return [] }
        return windows
    }

    static func windowID(for element: AXUIElement) -> CGWindowID? {
        var windowID: CGWindowID = 0
        let result = _AXUIElementGetWindow(element, &windowID)
        guard result == .success else { return nil }
        return windowID
    }

    // MARK: - Read Attributes

    static func getPosition(of element: AXUIElement) -> CGPoint? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &value)
        guard result == .success, let value else { return nil }
        // AXValue is a CFTypeRef; the cast always succeeds when non-nil
        let axValue = value as! AXValue
        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
        return point
    }

    static func getSize(of element: AXUIElement) -> CGSize? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &value)
        guard result == .success, let value else { return nil }
        // AXValue is a CFTypeRef; the cast always succeeds when non-nil
        let axValue = value as! AXValue
        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else { return nil }
        return size
    }

    static func getFrame(of element: AXUIElement) -> CGRect? {
        guard let position = getPosition(of: element),
              let size = getSize(of: element) else { return nil }
        return CGRect(origin: position, size: size)
    }

    static func getTitle(of element: AXUIElement) -> String? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value)
        guard result == .success, let title = value as? String else { return nil }
        return title
    }

    static func getRole(of element: AXUIElement) -> String? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value)
        guard result == .success, let role = value as? String else { return nil }
        return role
    }

    static func getSubrole(of element: AXUIElement) -> String? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &value)
        guard result == .success, let subrole = value as? String else { return nil }
        return subrole
    }

    static func isMinimized(_ element: AXUIElement) -> Bool {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, kAXMinimizedAttribute as CFString, &value)
        guard result == .success, let boolValue = value as? Bool else { return false }
        return boolValue
    }

    static func isFullScreen(_ element: AXUIElement) -> Bool {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, "AXFullScreen" as CFString, &value)
        guard result == .success, let boolValue = value as? Bool else { return false }
        return boolValue
    }

    // MARK: - Write Attributes

    @discardableResult
    static func setPosition(of element: AXUIElement, to point: CGPoint) -> AXError {
        var mutablePoint = point
        guard let value = AXValueCreate(.cgPoint, &mutablePoint) else { return .failure }
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
    }

    @discardableResult
    static func setSize(of element: AXUIElement, to size: CGSize) -> AXError {
        var mutableSize = size
        guard let value = AXValueCreate(.cgSize, &mutableSize) else { return .failure }
        return AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
    }

    static func setFrame(of element: AXUIElement, to frame: CGRect) {
        // Position first so the window is at the target origin before resizing.
        // Size-first can cause the window to temporarily extend off-screen at
        // the old position, leading apps to constrain the size incorrectly.
        setPosition(of: element, to: frame.origin)
        setSize(of: element, to: frame.size)
    }

    // MARK: - Actions

    @discardableResult
    static func raise(_ element: AXUIElement) -> AXError {
        return AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    }

    /// Press the close button on a window (equivalent to clicking the red traffic light).
    @discardableResult
    static func closeWindow(_ element: AXUIElement) -> Bool {
        var buttonRef: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, kAXCloseButtonAttribute as CFString, &buttonRef)
        guard result == .success, let button = buttonRef else { return false }
        return AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString) == .success
    }

    /// Activate the owning app and raise the window, with a fallback chain
    /// for stale AXUIElements:
    /// 1. Activate app + kAXRaiseAction on stored element
    /// 2. Refresh AXUIElement by CGWindowID, retry kAXRaiseAction
    /// 3. kAXRaiseAction on fresh element (app already active)
    ///
    /// Returns a fresh AXUIElement if one was resolved (caller should update
    /// the group's stored element), or nil if the original was fine.
    @discardableResult
    static func raiseWindow(_ window: WindowInfo) -> AXUIElement? {
        // Raise the target window BEFORE activating the app so the correct
        // window is already in front when the app comes forward, avoiding a
        // brief flash of whatever window the app had focused previously.

        // Fast path: raise with the stored element
        var freshElement: AXUIElement? = nil
        if raise(window.element) != .success {
            // The stored AXUIElement may be stale. Look up a fresh one by CGWindowID.
            let allElements = windowElements(for: window.ownerPID)
            if let match = allElements.first(where: { windowID(for: $0) == window.id }) {
                freshElement = match
            } else {
                freshElement = window.element
            }
            raise(freshElement!)
        }

        // Activate the app only if it isn't already active.  When the app is
        // already frontmost, AXRaise alone is sufficient; calling activate()
        // again can cause macOS to switch Spaces to the app's "main" window
        // when it has windows on multiple Spaces.
        let appForActivation = NSRunningApplication(processIdentifier: window.ownerPID)
        if let app = appForActivation, !app.isActive {
            if #available(macOS 14.0, *) {
                app.activate()
            } else {
                app.activate(options: [])
            }

            // Re-raise after activate: app.activate() can bring forward the
            // app's own previously-focused window, overriding our initial
            // raise.  This matters for same-app multi-window groups.
            let elementToRaise = freshElement ?? window.element
            raise(elementToRaise)
        }

        if let fresh = freshElement, fresh !== window.element {
            return fresh
        }
        return nil
    }

    // MARK: - Observer

    static func createObserver(
        for pid: pid_t,
        callback: @escaping AXObserverCallback
    ) -> AXObserver? {
        var observer: AXObserver?
        let result = AXObserverCreate(pid, callback, &observer)
        guard result == .success, let obs = observer else { return nil }
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(obs),
            .defaultMode
        )
        return obs
    }

    @discardableResult
    static func addNotification(
        observer: AXObserver,
        element: AXUIElement,
        notification: String,
        context: UnsafeMutableRawPointer?
    ) -> AXError {
        return AXObserverAddNotification(observer, element, notification as CFString, context)
    }

    @discardableResult
    static func removeNotification(
        observer: AXObserver,
        element: AXUIElement,
        notification: String
    ) -> AXError {
        return AXObserverRemoveNotification(observer, element, notification as CFString)
    }

    static func removeObserver(_ observer: AXObserver) {
        CFRunLoopRemoveSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .defaultMode
        )
    }
}
