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
        setSize(of: element, to: frame.size)
        setPosition(of: element, to: frame.origin)
    }

    /// Sets the frame, then reads back the size to confirm the app accepted it.
    /// Returns the actual frame (which may differ if the app enforces min/max sizes).
    @discardableResult
    static func setFrameAndVerify(of element: AXUIElement, to frame: CGRect) -> CGRect {
        setFrame(of: element, to: frame)
        let actualSize = getSize(of: element) ?? frame.size
        let actualPosition = getPosition(of: element) ?? frame.origin
        return CGRect(origin: actualPosition, size: actualSize)
    }

    // MARK: - Actions

    @discardableResult
    static func raise(_ element: AXUIElement) -> AXError {
        return AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    }

    /// Raise with fallback: kAXRaiseAction → activate app + nudge position
    static func raiseWindow(_ window: WindowInfo) {
        let result = raise(window.element)
        if result == .success { return }

        guard let app = NSRunningApplication(processIdentifier: window.ownerPID) else { return }
        if #available(macOS 14.0, *) {
            app.activate()
        } else {
            app.activate(options: [])
        }
        // Re-set position to current value — forces this specific window
        // to front within the now-active app (not just any window of the app)
        if let position = getPosition(of: window.element) {
            setPosition(of: window.element, to: position)
        }
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
