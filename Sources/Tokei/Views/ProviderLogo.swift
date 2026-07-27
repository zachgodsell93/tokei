import SwiftUI

/// Simple vector marks for each provider — drawn as paths so they render
/// crisply as template (monochrome) glyphs in the menu bar and tinted in
/// the popover. Deliberately schematic rather than trademark-exact.
struct ProviderLogo: View {
    let provider: AIProvider

    var body: some View {
        switch provider {
        case .claude:
            StarburstShape()
                .stroke(style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
                .aspectRatio(1, contentMode: .fit)
        case .openai:
            HexagonShape()
                .stroke(style: StrokeStyle(lineWidth: 1.3, lineJoin: .round))
                .aspectRatio(1, contentMode: .fit)
                .padding(0.5)
        case .gemini:
            SparkleShape()
                .aspectRatio(1, contentMode: .fit)
        }
    }
}

/// Radiating rays, evoking Claude's starburst mark.
struct StarburstShape: Shape {
    var rays = 10
    var innerRatio: CGFloat = 0.32

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        for i in 0..<rays {
            let angle = CGFloat(i) / CGFloat(rays) * 2 * .pi - .pi / 2
            path.move(to: CGPoint(
                x: center.x + cos(angle) * radius * innerRatio,
                y: center.y + sin(angle) * radius * innerRatio))
            path.addLine(to: CGPoint(
                x: center.x + cos(angle) * radius,
                y: center.y + sin(angle) * radius))
        }
        return path
    }
}

/// Hexagonal ring, evoking OpenAI's knot mark.
struct HexagonShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        let points = (0..<6).map { i -> CGPoint in
            let angle = CGFloat(i) / 6 * 2 * .pi - .pi / 2
            return CGPoint(
                x: center.x + cos(angle) * radius,
                y: center.y + sin(angle) * radius)
        }
        path.move(to: points[0])
        for point in points.dropFirst() { path.addLine(to: point) }
        path.closeSubpath()
        return path
    }
}

/// Four-point star with concave sides — Gemini's sparkle.
struct SparkleShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        let top = CGPoint(x: center.x, y: center.y - radius)
        let right = CGPoint(x: center.x + radius, y: center.y)
        let bottom = CGPoint(x: center.x, y: center.y + radius)
        let left = CGPoint(x: center.x - radius, y: center.y)
        path.move(to: top)
        path.addQuadCurve(to: right, control: center)
        path.addQuadCurve(to: bottom, control: center)
        path.addQuadCurve(to: left, control: center)
        path.addQuadCurve(to: top, control: center)
        path.closeSubpath()
        return path
    }
}
