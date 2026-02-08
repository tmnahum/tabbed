import SwiftUI

struct SwitcherView: View {
    let items: [SwitcherItem]
    let selectedIndex: Int
    let style: SwitcherStyle
    let showLeadingOverflow: Bool
    let showTrailingOverflow: Bool

    /// Maximum icons to show stacked for a group entry.
    private static let maxGroupIcons = 4

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
                iconCell(item: item, isSelected: index == selectedIndex)
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

    private func iconCell(item: SwitcherItem, isSelected: Bool) -> some View {
        VStack(spacing: 6) {
            ZStack {
                if item.isGroup {
                    groupedIconStack(icons: item.icons)
                } else if let icon = item.icons.first ?? nil {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 64, height: 64)
                } else {
                    Image(systemName: "macwindow")
                        .font(.system(size: 40))
                        .frame(width: 64, height: 64)
                }
            }
            .frame(width: 80, height: 64)
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.accentColor.opacity(0.3) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2.5)
            )

            Text(item.appName)
                .font(.system(size: 11))
                .lineLimit(1)
                .foregroundStyle(isSelected ? .primary : .secondary)
        }
        .frame(width: 96)
    }

    /// Stacked/overlapping icons for a group entry.
    private func groupedIconStack(icons: [NSImage?]) -> some View {
        let capped = Array(icons.prefix(Self.maxGroupIcons))
        let iconSize: CGFloat = 48
        let overlap: CGFloat = 16

        return ZStack {
            ForEach(Array(capped.enumerated()), id: \.offset) { index, icon in
                Group {
                    if let icon {
                        Image(nsImage: icon)
                            .resizable()
                    } else {
                        Image(systemName: "macwindow")
                            .font(.system(size: 28))
                    }
                }
                .frame(width: iconSize, height: iconSize)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(.background)
                )
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                .offset(x: CGFloat(index) * overlap - CGFloat(capped.count - 1) * overlap / 2)
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
                titleRow(item: item, isSelected: index == selectedIndex)
            }
            if showTrailingOverflow {
                Text("⋯")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 2)
            }
        }
        .frame(minWidth: 340)
        .padding(4)
    }

    private func titleRow(item: SwitcherItem, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            // Icon(s)
            if item.isGroup {
                groupedIconRowStack(icons: item.icons)
                    .frame(width: 32, height: 24)
            } else if let icon = item.icons.first ?? nil {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 24, height: 24)
            } else {
                Image(systemName: "macwindow")
                    .frame(width: 24, height: 24)
            }

            Text("\(item.appName) — \(item.displayTitle)")
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

            if item.windowCount > 1 {
                Text("\(item.windowCount)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.25) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5)
        )
    }

    /// Small overlapping icons for the titles-style row.
    private func groupedIconRowStack(icons: [NSImage?]) -> some View {
        let capped = Array(icons.prefix(Self.maxGroupIcons))
        let iconSize: CGFloat = 20
        let overlap: CGFloat = 8

        return ZStack {
            ForEach(Array(capped.enumerated()), id: \.offset) { index, icon in
                Group {
                    if let icon {
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
                .offset(x: CGFloat(index) * overlap - CGFloat(capped.count - 1) * overlap / 2)
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
