import Foundation
import CoreGraphics

/// A serializable snapshot of a single window within a group.
struct WindowSnapshot: Codable {
    let windowID: CGWindowID   // exact match when the window still exists
    let bundleID: String
    let title: String
    let appName: String
    let pinState: WindowPinState
    let customTabName: String?
    let isSeparator: Bool

    var isPinned: Bool {
        pinState != .none
    }

    init(
        windowID: CGWindowID,
        bundleID: String,
        title: String,
        appName: String,
        isPinned: Bool,
        pinState: WindowPinState? = nil,
        customTabName: String? = nil,
        isSeparator: Bool = false
    ) {
        self.windowID = windowID
        self.bundleID = bundleID
        self.title = title
        self.appName = appName
        self.pinState = pinState ?? (isPinned ? .normal : .none)
        self.customTabName = customTabName
        self.isSeparator = isSeparator
    }

    private enum CodingKeys: String, CodingKey {
        case windowID
        case bundleID
        case title
        case appName
        case pinState
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
        if let decodedPinState = try container.decodeIfPresent(WindowPinState.self, forKey: .pinState) {
            pinState = decodedPinState
        } else {
            let legacyPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
            pinState = legacyPinned ? .normal : .none
        }
        customTabName = try container.decodeIfPresent(String.self, forKey: .customTabName)
        isSeparator = try container.decodeIfPresent(Bool.self, forKey: .isSeparator) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(windowID, forKey: .windowID)
        try container.encode(bundleID, forKey: .bundleID)
        try container.encode(title, forKey: .title)
        try container.encode(appName, forKey: .appName)
        try container.encode(pinState, forKey: .pinState)
        try container.encode(pinState != .none, forKey: .isPinned)
        try container.encodeIfPresent(customTabName, forKey: .customTabName)
        try container.encode(isSeparator, forKey: .isSeparator)
    }
}

/// A serializable snapshot of a tab group.
struct GroupSnapshot: Codable {
    let windows: [WindowSnapshot]
    let activeIndex: Int
    let frame: CodableRect
    let tabBarSqueezeDelta: CGFloat
    let name: String?
    let displayMode: TabGroupDisplayMode
    let fullscreenState: FullscreenGroupState?
}

/// CGRect wrapper that conforms to Codable.
struct CodableRect: Codable, Equatable {
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
