import AppKit

/// Floating tooltip panel that shows the full window title below the tab bar.
class TabTooltipPanel: NSPanel {
    private let label: NSTextField
    private let visualEffect: NSVisualEffectView
    private static let padding: CGFloat = 12
    private static let tooltipHeight: CGFloat = 24

    init() {
        label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 12)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1

        visualEffect = NSVisualEffectView()
        visualEffect.material = .menu
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 6

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: Self.tooltipHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.level = .floating
        self.isFloatingPanel = true
        self.becomesKeyOnlyIfNeeded = true
        self.hidesOnDeactivate = false
        self.isOpaque = false
        self.backgroundColor = .clear
        self.isMovableByWindowBackground = false
        self.animationBehavior = .none
        self.collectionBehavior = [.transient, .ignoresCycle]

        // Autoresizing masks so subviews follow animated window frame changes
        visualEffect.autoresizingMask = [.width, .height]
        label.autoresizingMask = [.width]

        label.wantsLayer = true

        contentView?.addSubview(visualEffect)
        visualEffect.addSubview(label)
    }

    /// Show the tooltip below the tab bar panel, left-aligned with `tabLeadingX` (in screen coordinates).
    /// When `animate` is true, smoothly glides to the new position and crossfades the text (Chrome-style).
    func show(title: String, belowPanelFrame panelFrame: NSRect, tabLeadingX: CGFloat, animate: Bool = false) {
        let titleChanged = label.stringValue != title
        let shouldAnimate = animate && isVisible

        // CATransition must be added BEFORE the content change —
        // it captures the current layer state, then crossfades to the new one.
        if shouldAnimate && titleChanged {
            let crossfade = CATransition()
            crossfade.type = .fade
            crossfade.duration = 0.25
            crossfade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            label.layer?.add(crossfade, forKey: "textFade")
        }

        label.stringValue = title
        label.sizeToFit()

        let width = min(label.frame.width + Self.padding * 2, 400)
        let x = tabLeadingX
        let y = panelFrame.origin.y - Self.tooltipHeight - 2
        let newFrame = NSRect(x: x, y: y, width: width, height: Self.tooltipHeight)

        // setFrame(_:display:animate:) is AppKit's built-in window frame animation.
        // Subviews follow automatically via autoresizing masks.
        setFrame(newFrame, display: true, animate: shouldAnimate)

        // Layout label within the (now final-sized) content view
        let bounds = contentView!.bounds
        visualEffect.frame = bounds
        label.frame = NSRect(
            x: Self.padding,
            y: (bounds.height - label.frame.height) / 2,
            width: bounds.width - Self.padding * 2,
            height: label.frame.height
        )

        orderFront(nil)
    }

    func dismiss() {
        orderOut(nil)
    }
}
