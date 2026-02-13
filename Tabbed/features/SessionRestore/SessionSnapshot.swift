import Foundation
import CoreGraphics

/// A serializable snapshot of a single window within a group.
struct WindowSnapshot: Codable {
    let windowID: CGWindowID   // exact match when the window still exists
    let bundleID: String
    let title: String
    let appName: String
    let isPinned: Bool
    let customTabName: String?
    let isSeparator: Bool

    init(
        windowID: CGWindowID,
        bundleID: String,
        title: String,
        appName: String,
        isPinned: Bool,
        customTabName: String? = nil,
        isSeparator: Bool = false
    ) {
        self.windowID = windowID
        self.bundleID = bundleID
        self.title = title
        self.appName = appName
        self.isPinned = isPinned
        self.customTabName = customTabName
        self.isSeparator = isSeparator
    }

    private enum CodingKeys: String, CodingKey {
        case windowID
        case bundleID
        case title
        case appName
        case isPinned
        case customTabName
        case isSeparator
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        windowID = try container.decode(CGWindowID.self, forKey: .windowID)
        bundleID = try container.decode(String.self, forKey: .bundleID)
        title = try container.decode(String.self, forKey: .title)
        appName = try container.decode(String.self, forKey: .appName)
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        customTabName = try container.decodeIfPresent(String.self, forKey: .customTabName)
        isSeparator = try container.decodeIfPresent(Bool.self, forKey: .isSeparator) ?? false
    }
}

/// A serializable snapshot of a tab group.
struct GroupSnapshot: Codable {
    let windows: [WindowSnapshot]
    let activeIndex: Int
    let frame: CodableRect
    let tabBarSqueezeDelta: CGFloat
    let name: String?
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
