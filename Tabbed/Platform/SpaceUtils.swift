import CoreGraphics

enum SpaceUtils {
    /// Returns the primary space ID for a window, or nil if the window doesn't exist.
    static func spaceID(for windowID: CGWindowID) -> UInt64? {
        let conn = CGSMainConnectionID()
        let spaces = CGSCopySpacesForWindows(conn, 0x7, [windowID] as CFArray) as? [UInt64] ?? []
        return spaces.first
    }

    /// Batch query: returns a dictionary mapping each window ID to its space ID.
    /// Windows that don't exist are omitted from the result.
    static func spaceIDs(for windowIDs: [CGWindowID]) -> [CGWindowID: UInt64] {
        guard !windowIDs.isEmpty else { return [:] }
        let conn = CGSMainConnectionID()
        var result: [CGWindowID: UInt64] = [:]
        for wid in windowIDs {
            let spaces = CGSCopySpacesForWindows(conn, 0x7, [wid] as CFArray) as? [UInt64] ?? []
            if let space = spaces.first {
                result[wid] = space
            }
        }
        return result
    }

    /// Returns the CGS window level for a window, or nil on lookup failure.
    static func windowLevel(for windowID: CGWindowID) -> Int? {
        let conn = CGSMainConnectionID()
        var rawLevel: Int32 = 0
        guard CGSGetWindowLevel(conn, windowID, &rawLevel) == 0 else { return nil }
        return Int(rawLevel)
    }

    /// Move a window to a specific managed Space.
    static func moveWindow(_ windowID: CGWindowID, toSpace spaceID: UInt64) {
        let conn = CGSMainConnectionID()
        CGSMoveWindowsToManagedSpace(conn, [windowID] as CFArray, spaceID)
    }
}
