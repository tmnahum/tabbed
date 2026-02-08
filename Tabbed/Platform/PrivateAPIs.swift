import ApplicationServices
import Foundation

// MARK: - Private SPI Declarations

@_silgen_name("_AXUIElementCreateWithRemoteToken")
func _AXUIElementCreateWithRemoteToken(_ data: CFData) -> Unmanaged<AXUIElement>?

@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> UInt32

@_silgen_name("CGSGetWindowLevel")
func CGSGetWindowLevel(_ cid: UInt32, _ wid: CGWindowID, _ level: inout Int32) -> Int32

// MARK: - Brute-Force Window Discovery

/// Discovers AXUIElements across all Spaces for a given PID by brute-forcing element IDs.
///
/// When `targetWindowIDs` is provided, only searches for those specific CGWindowIDs and
/// stops early once all targets are found. This avoids scanning 10,000 element IDs when
/// only a few windows are missing from the standard AX query.
///
/// Constructs a 20-byte remote token per element ID and calls `_AXUIElementCreateWithRemoteToken`.
/// Returns discovered (AXUIElement, CGWindowID) pairs for the caller to filter.
func discoverWindowsByBruteForce(
    pid: pid_t,
    maxID: UInt64 = 2000,
    targetWindowIDs: Set<CGWindowID>? = nil
) -> [(element: AXUIElement, windowID: CGWindowID)] {
    var results: [(element: AXUIElement, windowID: CGWindowID)] = []
    var remaining = targetWindowIDs
    let pidInt32 = Int32(pid)
    let magic: UInt32 = 0x636f636f // "coco"

    for elementID: UInt64 in 0...maxID {
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

        var windowID: CGWindowID = 0
        let err = _AXUIElementGetWindow(element, &windowID)
        if err == .success, windowID != 0 {
            results.append((element: element, windowID: windowID))
            remaining?.remove(windowID)
            if let r = remaining, r.isEmpty { break }
        }
    }

    return results
}
