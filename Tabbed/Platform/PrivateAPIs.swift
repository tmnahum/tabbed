import ApplicationServices
import Foundation

// MARK: - Private SPI Declarations

@_silgen_name("_AXUIElementCreateWithRemoteToken")
func _AXUIElementCreateWithRemoteToken(_ data: CFData) -> Unmanaged<AXUIElement>?

@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> UInt32

@_silgen_name("CGSGetWindowLevel")
func CGSGetWindowLevel(_ cid: UInt32, _ wid: CGWindowID, _ level: inout Int32) -> Int32

@_silgen_name("CGSCopySpacesForWindows")
func CGSCopySpacesForWindows(_ cid: UInt32, _ mask: UInt32, _ wids: CFArray) -> CFArray

@_silgen_name("CGSMoveWindowsToManagedSpace")
func CGSMoveWindowsToManagedSpace(_ cid: UInt32, _ wids: CFArray, _ sid: UInt64)

// MARK: - Brute-Force Window Discovery

/// Promote a discovered accessibility element to its containing window element
/// when possible. Some remote tokens resolve to child controls (e.g. radio
/// groups) that still map to the right CGWindowID but fail window-role checks.
func canonicalizeDiscoveredElement<Element>(
    _ element: Element,
    expectedWindowID: CGWindowID,
    windowAttribute: (Element) -> Element?,
    windowID: (Element) -> CGWindowID?
) -> Element {
    guard let container = windowAttribute(element),
          windowID(container) == expectedWindowID else {
        return element
    }
    return container
}

/// Discovers AXUIElements across all Spaces for a given PID by brute-forcing element IDs.
///
/// When `targetWindowIDs` is provided, only searches for those specific CGWindowIDs and
/// stops early once all targets are found. This avoids scanning the full range when
/// only a few windows are missing from the standard AX query.
///
/// A wall-clock `timeout` (default 0.5s) caps total elapsed time per call so that one
/// slow/unresponsive app can't block discovery for seconds.  A per-element AX messaging
/// timeout (100ms) guards against individual probes hanging.
///
/// Constructs a 20-byte remote token per element ID and calls `_AXUIElementCreateWithRemoteToken`.
/// Returns discovered (AXUIElement, CGWindowID) pairs for the caller to filter.
func discoverWindowsByBruteForce(
    pid: pid_t,
    maxID: UInt64 = 10_000,
    targetWindowIDs: Set<CGWindowID>? = nil,
    timeout: TimeInterval = 0.5
) -> [(element: AXUIElement, windowID: CGWindowID)] {
    var results: [(element: AXUIElement, windowID: CGWindowID)] = []
    var remaining = targetWindowIDs
    let pidInt32 = Int32(pid)
    let magic: UInt32 = 0x636f636f // "coco"
    let deadline = CFAbsoluteTimeGetCurrent() + timeout

    for elementID: UInt64 in 0...maxID {
        // Bail out if we've exceeded the wall-clock timeout
        if CFAbsoluteTimeGetCurrent() > deadline { break }

        // 20-byte token: pid(4) | 0x00(4) | "coco"(4) | elementID(8)
        var tokenData = Data(count: 20)
        tokenData.withUnsafeMutableBytes { buf in
            buf.storeBytes(of: pidInt32.littleEndian, toByteOffset: 0, as: Int32.self)
            buf.storeBytes(of: UInt32(0).littleEndian, toByteOffset: 4, as: UInt32.self)
            buf.storeBytes(of: magic.littleEndian, toByteOffset: 8, as: UInt32.self)
            buf.storeBytes(of: elementID.littleEndian, toByteOffset: 12, as: UInt64.self)
        }

        guard let unmanaged = _AXUIElementCreateWithRemoteToken(tokenData as NSData as CFData) else { continue }
        let element = unmanaged.takeRetainedValue()

        // Cap individual AX probes so a hung app can't block a single call for seconds
        AXUIElementSetMessagingTimeout(element, 0.1)

        var wid: CGWindowID = 0
        let err = _AXUIElementGetWindow(element, &wid)
        if err == .success, wid != 0 {
            let normalized = canonicalizeDiscoveredElement(
                element,
                expectedWindowID: wid,
                windowAttribute: { candidate in
                    var windowValue: AnyObject?
                    let result = AXUIElementCopyAttributeValue(
                        candidate,
                        kAXWindowAttribute as CFString,
                        &windowValue
                    )
                    guard result == .success, let windowValue else {
                        return nil
                    }
                    // AX value is a CFTypeRef; cast succeeds when non-nil.
                    let windowElement = windowValue as! AXUIElement // swiftlint:disable:this force_cast
                    return windowElement
                },
                windowID: { candidate in
                    var candidateWindowID: CGWindowID = 0
                    let result = _AXUIElementGetWindow(candidate, &candidateWindowID)
                    guard result == .success, candidateWindowID != 0 else {
                        return nil
                    }
                    return candidateWindowID
                }
            )
            results.append((element: normalized, windowID: wid))
            remaining?.remove(wid)
            if let r = remaining, r.isEmpty { break }
        }
    }

    return results
}
