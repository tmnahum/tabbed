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
        // Always activate the owning app so the window actually receives
        // focus. Without this, kAXRaiseAction brings the window to front
        // within its app but the app itself may stay in the background.
        if let app = NSRunningApplication(processIdentifier: window.ownerPID) {
            if #available(macOS 14.0, *) {
                app.activate()
            } else {
                app.activate(options: [])
            }
        }

        // Fast path: raise with the stored element
        if raise(window.element) == .success { return nil }

        // The stored AXUIElement may be stale. Look up a fresh one by CGWindowID.
        let freshElement: AXUIElement
        let allElements = windowElements(for: window.ownerPID)
        if let match = allElements.first(where: { windowID(for: $0) == window.id }) {
            freshElement = match
        } else {
            freshElement = window.element
        }

        raise(freshElement)
        return freshElement !== window.element ? freshElement : nil
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
