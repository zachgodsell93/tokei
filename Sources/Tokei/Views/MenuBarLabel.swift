import AppKit
import SwiftUI

/// The menu bar readout: one logo glyph per provider followed by that
/// provider's pinned percentages. Status items only reliably display plain
/// text and images — custom Shape views get dropped by the host — so this
/// view is rasterized into a template NSImage before it reaches the bar.
struct MenuBarLabelContent: View {
    let groups: [UsageStore.MenuBarGroup]
    /// Template rendering only uses alpha, so black is right for the real
    /// menu bar; screenshot renders pass white for dark backgrounds.
    var tint: Color = .black

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
        .foregroundStyle(tint)
        .padding(.horizontal, 2)
        .frame(height: 18)
        .fixedSize()
    }
}

@MainActor
enum MenuBarLabelRenderer {
    private static var cache: (key: String, image: NSImage)?

    static func image(for groups: [UsageStore.MenuBarGroup]) -> NSImage? {
        guard !groups.isEmpty else { return nil }
        let key = groups.map { "\($0.provider.rawValue)=\($0.text)" }.joined(separator: ",")
        if let cache, cache.key == key { return cache.image }
        let renderer = ImageRenderer(content: MenuBarLabelContent(groups: groups))
        renderer.scale = 2
        guard let image = renderer.nsImage else { return nil }
        image.isTemplate = true
        cache = (key, image)
        return image
    }
}
