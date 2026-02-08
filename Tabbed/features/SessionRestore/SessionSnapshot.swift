import Foundation
import CoreGraphics

/// A serializable snapshot of a single window within a group.
struct WindowSnapshot: Codable {
    let bundleID: String
    let title: String
    let appName: String
}

/// A serializable snapshot of a tab group.
struct GroupSnapshot: Codable {
    let windows: [WindowSnapshot]
    let activeIndex: Int
    let frame: CodableRect
    let tabBarSqueezeDelta: CGFloat
}

/// CGRect wrapper that conforms to Codable.
struct CodableRect: Codable {
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat

    init(_ rect: CGRect) {
        self.x = rect.origin.x
        self.y = rect.origin.y
        self.width = rect.size.width
        self.height = rect.size.height
    }

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}
