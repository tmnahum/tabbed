import AppKit
import ApplicationServices

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: inout CGWindowID) -> AXError

enum AccessibilityHelper {

    /// Timeout for AX calls to avoid blocking the main thread when target apps are slow.
    private static let axMessagingTimeout: Float = 0.5

    /// Serial queue for AX operations that must not block the main thread.
    private static let axQueue = DispatchQueue(label: "com.tabbed.ax", qos: .userInitiated)

    static func setPositionAsync(of element: AXUIElement, to point: CGPoint) {
        axQueue.async { setPosition(of: element, to: point) }
    }

    static func setSizeAsync(of element: AXUIElement, to size: CGSize) {
        axQueue.async { setSize(of: element, to: size) }
    }

    static func setFrameAsync(of element: AXUIElement, to frame: CGRect) {
        axQueue.async { setFrame(of: element, to: frame) }
    }

    static func closeWindowAsync(_ element: AXUIElement) {
        axQueue.async { closeWindow(element) }
    }

    static func raiseWindowAsync(_ window: WindowInfo, completion: ((AXUIElement) -> Void)? = nil) {
        axQueue.async {
            guard let freshElement = raiseWindow(window) else { return }
            if let completion {
                DispatchQueue.main.async { completion(freshElement) }
            }
        }
    }

    private static func setMessagingTimeout(_ element: AXUIElement) {
        AXUIElementSetMessagingTimeout(element, axMessagingTimeout)
    }

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
        setMessagingTimeout(app)
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        guard result == .success, let windows = value as? [AXUIElement] else { return [] }
        return windows
    }

    static func windowID(for element: AXUIElement) -> CGWindowID? {
        setMessagingTimeout(element)
        var windowID: CGWindowID = 0
        let result = _AXUIElementGetWindow(element, &windowID)
        guard result == .success else { return nil }
        return windowID
    }

    // MARK: - Read Attributes

    static func getPosition(of element: AXUIElement) -> CGPoint? {
        setMessagingTimeout(element)
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
        setMessagingTimeout(element)
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

    static func isSizeSettable(of element: AXUIElement) -> Bool? {
        isAttributeSettable(kAXSizeAttribute as String, of: element)
    }

    static func isResizable(_ element: AXUIElement) -> Bool? {
        if let isSizeSettable = isSizeSettable(of: element) {
            return isSizeSettable
        }

        setMessagingTimeout(element)
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, "AXResizable" as CFString, &value)
        guard result == .success, let boolValue = value as? Bool else { return nil }
        return boolValue
    }

    static func getTitle(of element: AXUIElement) -> String? {
        setMessagingTimeout(element)
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value)
        guard result == .success, let title = value as? String else { return nil }
        return title
    }

    static func getRole(of element: AXUIElement) -> String? {
        setMessagingTimeout(element)
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value)
        guard result == .success, let role = value as? String else { return nil }
        return role
    }

    static func getSubrole(of element: AXUIElement) -> String? {
        setMessagingTimeout(element)
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &value)
        guard result == .success, let subrole = value as? String else { return nil }
        return subrole
    }

    static func isMinimized(_ element: AXUIElement) -> Bool {
        setMessagingTimeout(element)
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, kAXMinimizedAttribute as CFString, &value)
        guard result == .success, let boolValue = value as? Bool else { return false }
        return boolValue
    }

    static func isFullScreen(_ element: AXUIElement) -> Bool {
        setMessagingTimeout(element)
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, "AXFullScreen" as CFString, &value)
        guard result == .success, let boolValue = value as? Bool else { return false }
        return boolValue
    }

    static func isModal(_ element: AXUIElement) -> Bool {
        setMessagingTimeout(element)
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, "AXModal" as CFString, &value)
        guard result == .success, let boolValue = value as? Bool else { return false }
        return boolValue
    }

    static func focusedWindowID(for pid: pid_t) -> CGWindowID? {
        guard let focusedElement = focusedWindowElement(forAppPID: pid) else { return nil }
        return windowID(for: focusedElement)
    }

    static func focusedWindowElement(for app: AXUIElement) -> AXUIElement? {
        setMessagingTimeout(app)
        var focusedValue: AnyObject?
        let result = AXUIElementCopyAttributeValue(
            app,
            kAXFocusedWindowAttribute as CFString,
            &focusedValue
        )
        guard result == .success,
              let focusedRef = focusedValue else { return nil }
        return focusedRef as! AXUIElement // swiftlint:disable:this force_cast
    }

    static func focusedWindowElement(forAppPID pid: pid_t) -> AXUIElement? {
        let app = appElement(for: pid)
        return focusedWindowElement(for: app)
    }

    static func frontmostFocusedWindowID(
        frontmostAppProvider: () -> NSRunningApplication? = { NSWorkspace.shared.frontmostApplication }
    ) -> CGWindowID? {
        guard let frontApp = frontmostAppProvider(),
              let focusedElement = focusedWindowElement(forAppPID: frontApp.processIdentifier) else {
            return nil
        }
        return windowID(for: focusedElement)
    }

    // MARK: - Write Attributes

    private static func isAttributeSettable(_ attribute: String, of element: AXUIElement) -> Bool? {
        setMessagingTimeout(element)
        var isSettable = DarwinBoolean(false)
        let result = AXUIElementIsAttributeSettable(element, attribute as CFString, &isSettable)
        guard result == .success else { return nil }
        return isSettable.boolValue
    }

    @discardableResult
    private static func setPosition(of element: AXUIElement, to point: CGPoint) -> AXError {
        setMessagingTimeout(element)
        var mutablePoint = point
        guard let value = AXValueCreate(.cgPoint, &mutablePoint) else { return .failure }
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
    }

    @discardableResult
    private static func setSize(of element: AXUIElement, to size: CGSize) -> AXError {
        setMessagingTimeout(element)
        var mutableSize = size
        guard let value = AXValueCreate(.cgSize, &mutableSize) else { return .failure }
        return AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
    }

    private static func setFrame(of element: AXUIElement, to frame: CGRect) {
        // Position first so the window is at the target origin before resizing.
        // Size-first can cause the window to temporarily extend off-screen at
        // the old position, leading apps to constrain the size incorrectly.
        setPosition(of: element, to: frame.origin)
        setSize(of: element, to: frame.size)
    }

    @discardableResult
    static func setMain(_ element: AXUIElement, to value: Bool = true) -> AXError {
        setMessagingTimeout(element)
        return AXUIElementSetAttributeValue(
            element,
            kAXMainAttribute as CFString,
            value ? kCFBooleanTrue : kCFBooleanFalse
        )
    }

    @discardableResult
    static func setFocusedWindow(_ element: AXUIElement, appPID: pid_t) -> AXError {
        let app = appElement(for: appPID)
        setMessagingTimeout(app)
        return AXUIElementSetAttributeValue(
            app,
            kAXFocusedWindowAttribute as CFString,
            element
        )
    }

    static func shouldPromoteAfterRaise(
        appIsActive: Bool,
        focusedWindowID: CGWindowID?,
        targetWindowID: CGWindowID
    ) -> Bool {
        if !appIsActive { return true }
        return focusedWindowID != targetWindowID
    }

    static func shouldRetryRaiseAfterActivation(
        focusedWindowID: CGWindowID?,
        targetWindowID: CGWindowID
    ) -> Bool {
        focusedWindowID != targetWindowID
    }

    static func shouldActivateViaNSApp(
        windowOwnerPID: pid_t,
        currentProcessID: pid_t = ProcessInfo.processInfo.processIdentifier
    ) -> Bool {
        windowOwnerPID == currentProcessID
    }

    // MARK: - Actions

    @discardableResult
    static func raise(_ element: AXUIElement) -> AXError {
        setMessagingTimeout(element)
        return AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    }

    /// Press the close button on a window (equivalent to clicking the red traffic light).
    @discardableResult
    private static func closeWindow(_ element: AXUIElement) -> Bool {
        setMessagingTimeout(element)
        var buttonRef: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, kAXCloseButtonAttribute as CFString, &buttonRef)
        guard result == .success, let button = buttonRef else { return false }
        return AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString) == .success
    }

    /// Activate/raise the owning app window with a fallback chain:
    /// 1. Re-resolve AXUIElement by CGWindowID (when available), then raise.
    /// 2. If app is inactive OR focused window is still not the target, activate + re-raise.
    /// 3. If still not focused, nudge AX main/focused-window attributes and re-raise.
    ///
    /// Returns a fresh AXUIElement if one was resolved (caller should update
    /// the group's stored element), or nil if the original was fine.
    @discardableResult
    private static func raiseWindow(_ window: WindowInfo) -> AXUIElement? {
        // Raise the target window BEFORE activating the app so the correct
        // window is already in front when the app comes forward, avoiding a
        // brief flash of whatever window the app had focused previously.

        // Re-resolve by CGWindowID when possible; some apps (including Preview)
        // can keep a "valid" AX object that no longer raises reliably.
        var freshElement: AXUIElement?
        let resolvedElement = windowElements(for: window.ownerPID)
            .first(where: { windowID(for: $0) == window.id })
        if let resolvedElement, resolvedElement !== window.element {
            freshElement = resolvedElement
        }
        let elementToRaise = freshElement ?? window.element
        raise(elementToRaise)

        let useNSAppActivation = shouldActivateViaNSApp(windowOwnerPID: window.ownerPID)
        let appForActivation = useNSAppActivation ? nil : NSRunningApplication(processIdentifier: window.ownerPID)
        let appIsActive = useNSAppActivation ? NSApp.isActive : (appForActivation?.isActive ?? false)
        let focusedAfterRaise = focusedWindowID(for: window.ownerPID)
        if shouldPromoteAfterRaise(
            appIsActive: appIsActive,
            focusedWindowID: focusedAfterRaise,
            targetWindowID: window.id
        ) {
            // When activating an inactive app, pre-seed AX focus so activation is
            // less likely to land on a stale window in another Space.
            if !appIsActive {
                setMain(elementToRaise)
                setFocusedWindow(elementToRaise, appPID: window.ownerPID)
            }

            if useNSAppActivation {
                activateCurrentApp()
            } else if let app = appForActivation {
                activate(app)
            }

            let focusedAfterActivation = focusedWindowID(for: window.ownerPID)
            if shouldRetryRaiseAfterActivation(
                focusedWindowID: focusedAfterActivation,
                targetWindowID: window.id
            ) {
                raise(elementToRaise)
            }

            // Some same-app multi-window cases ignore raise+activate; set
            // main/focused window attributes as a final accessibility nudge.
            if focusedWindowID(for: window.ownerPID) != window.id {
                setMain(elementToRaise)
                setFocusedWindow(elementToRaise, appPID: window.ownerPID)
                raise(elementToRaise)
            }
        }

        if let fresh = freshElement, fresh !== window.element {
            return fresh
        }
        return nil
    }

    private static func activate(_ app: NSRunningApplication) {
        if #available(macOS 14.0, *) {
            app.activate()
        } else {
            app.activate(options: [])
        }
    }

    private static func activateCurrentApp() {
        NSApp.activate(ignoringOtherApps: true)
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
