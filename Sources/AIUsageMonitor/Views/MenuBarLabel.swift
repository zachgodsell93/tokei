import AppKit
import SwiftUI

/// The menu bar readout: one logo glyph per provider followed by that
/// provider's pinned percentages. Status items only reliably display plain
/// text and images — custom Shape views get dropped by the host — so this
/// view is rasterized into a template NSImage before it reaches the bar.
struct MenuBarLabelContent: View {
    let groups: [UsageStore.MenuBarGroup]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(groups) { group in
                HStack(spacing: 3.5) {
                    ProviderLogo(provider: group.provider)
                        .frame(width: 13, height: 13)
                    Text(group.text)
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                }
            }
        }
        // Template images only use the alpha channel; draw solid.
        .foregroundStyle(.black)
        .padding(.horizontal, 2)
        .frame(height: 18)
        .fixedSize()
    }
}

@MainActor
enum MenuBarLabelRenderer {
    private static var cache: (groups: [UsageStore.MenuBarGroup], image: NSImage)?

    static func image(for groups: [UsageStore.MenuBarGroup]) -> NSImage? {
        guard !groups.isEmpty else { return nil }
        if let cache, cache.groups == groups { return cache.image }
        let renderer = ImageRenderer(content: MenuBarLabelContent(groups: groups))
        renderer.scale = 2
        guard let image = renderer.nsImage else { return nil }
        image.isTemplate = true
        cache = (groups, image)
        return image
    }
}
