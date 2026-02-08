import SwiftUI

struct SwitcherView: View {
    let items: [SwitcherItem]
    let selectedIndex: Int
    let style: SwitcherStyle
    let showLeadingOverflow: Bool
    let showTrailingOverflow: Bool
    /// When non-nil, the selected group item has a sub-selected window at this index.
    var subSelectedWindowIndex: Int? = nil
    /// Called when the user clicks an item. Parameter is the index in the visible items array.
    var onItemClicked: ((Int) -> Void)? = nil

    @State private var hoveredIndex: Int?

    /// Maximum icons to show stacked for a group entry.
    private static let maxGroupIcons = 8
    /// Maximum characters for a window title before truncation.
    private static let maxTitleLength = 80

    var body: some View {
        Group {
            switch style {
            case .appIcons:
                iconsStyleView
            case .titles:
                titlesStyleView
            }
        }
        .padding(12)
        .background(
            VisualEffectBackground(material: .hudWindow, blendingMode: .behindWindow)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        )
    }

    // MARK: - Display Helpers

    /// Truncates a title to the maximum length, adding ellipsis if needed.
    private func truncatedTitle(_ title: String) -> String {
        guard title.count > Self.maxTitleLength else { return title }
        return String(title.prefix(Self.maxTitleLength)) + "…"
    }

    /// Returns the display title for an item, accounting for sub-selection.
    private func displayTitle(for item: SwitcherItem, isSelected: Bool) -> String {
        let raw: String
        if isSelected, let subIndex = subSelectedWindowIndex, let window = item.window(at: subIndex) {
            raw = window.title.isEmpty ? window.appName : window.title
        } else {
            raw = item.displayTitle
        }
        return truncatedTitle(raw)
    }

    /// Returns the app name for an item, accounting for sub-selection.
    private func displayAppName(for item: SwitcherItem, isSelected: Bool) -> String {
        if isSelected, let subIndex = subSelectedWindowIndex, let window = item.window(at: subIndex) {
            return window.appName
        }
        return item.appName
    }

    // MARK: - App Icons Style

    private var iconsStyleView: some View {
        HStack(spacing: 16) {
            if showLeadingOverflow {
                Text("⋯")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
            }
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                iconCell(item: item, isSelected: index == selectedIndex, isHovered: index == hoveredIndex)
                    .contentShape(Rectangle())
                    .onHover { hovering in hoveredIndex = hovering ? index : nil }
                    .onTapGesture { onItemClicked?(index) }
            }
            if showTrailingOverflow {
                Text("⋯")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
            }
        }
        .padding(8)
    }

    private func iconCell(item: SwitcherItem, isSelected: Bool, isHovered: Bool) -> some View {
        let fillColor = isSelected ? Color.accentColor.opacity(0.3)
            : isHovered ? Color.primary.opacity(0.1)
            : Color.clear
        let strokeColor = isSelected ? Color.accentColor
            : isHovered ? Color.primary.opacity(0.2)
            : Color.clear

        return VStack(spacing: 6) {
            ZStack {
                if item.isGroup {
                    let frontIndex = isSelected ? subSelectedWindowIndex : nil
                    groupedIconStack(entries: item.iconsInMRUOrder(frontIndex: frontIndex, maxVisible: Self.maxGroupIcons))
                } else if let icon = item.icons.first ?? nil {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 64, height: 64)
                        .opacity(item.isWindowFullscreened(at: nil) ? 0.4 : 1.0)
                } else {
                    Image(systemName: "macwindow")
                        .font(.system(size: 40))
                        .frame(width: 64, height: 64)
                        .opacity(item.isWindowFullscreened(at: nil) ? 0.4 : 1.0)
                }
            }
            .frame(width: 80, height: 64)
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(fillColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(strokeColor, lineWidth: 2.5)
            )

            Text(displayAppName(for: item, isSelected: isSelected))
                .font(.system(size: 11))
                .lineLimit(1)
                .foregroundStyle(item.isWindowFullscreened(at: isSelected ? subSelectedWindowIndex : nil) ? .tertiary : isSelected ? .primary : .secondary)
        }
        .frame(width: 96)
    }

    /// Stacked/overlapping icons for a group entry.
    /// Scales icon size down proportionally to fit more icons within a target width.
    private func groupedIconStack(entries: [(icon: NSImage?, isFullscreened: Bool)]) -> some View {
        let count = entries.count
        let maxWidth: CGFloat = 96
        let overlapRatio: CGFloat = 1.0 / 3.0

        // Scale icon size to fit within target width, preserving overlap proportions
        let iconSize: CGFloat
        let overlap: CGFloat
        if count <= 1 {
            iconSize = 48
            overlap = 0
        } else {
            // totalWidth = iconSize * (1 + (count-1) * overlapRatio), solve for iconSize
            iconSize = min(48, max(20, maxWidth / (1 + CGFloat(count - 1) * overlapRatio)))
            overlap = iconSize * overlapRatio
        }
        let cornerRadius = iconSize * (10.0 / 48.0)

        return ZStack {
            ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                Group {
                    if let icon = entry.icon {
                        Image(nsImage: icon)
                            .resizable()
                    } else {
                        Image(systemName: "macwindow")
                            .font(.system(size: iconSize * 0.58))
                    }
                }
                .frame(width: iconSize, height: iconSize)
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(.background)
                )
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                .opacity(entry.isFullscreened ? 0.4 : 1.0)
                .offset(x: CGFloat(index) * overlap - CGFloat(count - 1) * overlap / 2)
            }
        }
    }

    // MARK: - Titles Style

    private var titlesStyleView: some View {
        VStack(spacing: 2) {
            if showLeadingOverflow {
                Text("⋯")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 2)
            }
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                titleRow(item: item, isSelected: index == selectedIndex, isHovered: index == hoveredIndex)
                    .contentShape(Rectangle())
                    .onHover { hovering in hoveredIndex = hovering ? index : nil }
                    .onTapGesture { onItemClicked?(index) }
            }
            if showTrailingOverflow {
                Text("⋯")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 2)
            }
        }
        .frame(minWidth: 420)
        .padding(4)
    }

    private func titleRow(item: SwitcherItem, isSelected: Bool, isHovered: Bool) -> some View {
        let title = displayTitle(for: item, isSelected: isSelected)
        let appName = displayAppName(for: item, isSelected: isSelected)
        let fillColor = isSelected ? Color.accentColor.opacity(0.25)
            : isHovered ? Color.primary.opacity(0.1)
            : Color.clear
        let strokeColor = isSelected ? Color.accentColor
            : isHovered ? Color.primary.opacity(0.2)
            : Color.clear

        return HStack(spacing: 10) {
            // Icon(s)
            if item.isGroup {
                let frontIndex = isSelected ? subSelectedWindowIndex : nil
                let entries = item.iconsInMRUOrder(frontIndex: frontIndex, maxVisible: Self.maxGroupIcons)
                let stackWidth = CGFloat(22 + max(0, entries.count - 1) * 9)
                groupedIconRowStack(entries: entries)
                    .frame(width: max(36, stackWidth), height: 28)
            } else if let icon = item.icons.first ?? nil {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 28, height: 28)
                    .opacity(item.isWindowFullscreened(at: nil) ? 0.4 : 1.0)
            } else {
                Image(systemName: "macwindow")
                    .frame(width: 28, height: 28)
                    .opacity(item.isWindowFullscreened(at: nil) ? 0.4 : 1.0)
            }

            Text("\(appName) — \(title)")
                .font(.system(size: 14))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(item.isWindowFullscreened(at: isSelected ? subSelectedWindowIndex : nil) ? .tertiary : .primary)

            Spacer()

            if item.windowCount > 1 {
                if isSelected, let subIndex = subSelectedWindowIndex {
                    Text("\(subIndex + 1)/\(item.windowCount)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                } else {
                    Text("\(item.windowCount)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(fillColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(strokeColor, lineWidth: 1.5)
        )
    }

    /// Small overlapping icons for the titles-style row.
    private func groupedIconRowStack(entries: [(icon: NSImage?, isFullscreened: Bool)]) -> some View {
        let count = entries.count
        let iconSize: CGFloat = 22
        let overlap: CGFloat = 9

        return ZStack {
            ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                Group {
                    if let icon = entry.icon {
                        Image(nsImage: icon)
                            .resizable()
                    } else {
                        Image(systemName: "macwindow")
                            .font(.system(size: 12))
                    }
                }
                .frame(width: iconSize, height: iconSize)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .shadow(color: .black.opacity(0.1), radius: 1, y: 0.5)
                .opacity(entry.isFullscreened ? 0.4 : 1.0)
                .offset(x: CGFloat(index) * overlap - CGFloat(count - 1) * overlap / 2)
            }
        }
    }
}

// MARK: - Visual Effect Background

struct VisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
