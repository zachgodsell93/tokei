import SwiftUI

struct ProviderSectionView: View {
    @ObservedObject var store: UsageStore
    let provider: AIProvider

    private var status: ProviderStatus {
        store.statuses[provider] ?? .loading
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            headerRow
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
    }

    private var headerRow: some View {
        HStack(spacing: 6) {
            ProviderLogo(provider: provider)
                .foregroundStyle(provider.tint)
                .frame(width: 14, height: 14)
            Text(provider.displayName)
                .font(.subheadline.weight(.semibold))
                .help(status.snapshot?.accountLabel ?? provider.displayName)
            if let plan = status.snapshot?.planLabel {
                Text(plan)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(provider.tint.opacity(0.16)))
                    .foregroundStyle(provider.tint)
            }
            Spacer()
            if let note = store.staleNotes[provider] {
                Image(systemName: "wifi.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.yellow)
                    .help("Last refresh failed: \(note)\nShowing previous data.")
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch status {
        case .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Loading…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)

        case .notConnected(let hint):
            Text(hint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Label {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                        .font(.caption)
                }
                Button("Retry") { store.refresh(provider) }
                    .controlSize(.small)
            }

        case .ready(let snapshot):
            if snapshot.metrics.isEmpty {
                Text("No usage reported yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 9) {
                    ForEach(snapshot.metrics) { metric in
                        MetricRowView(store: store, metric: metric)
                    }
                }
            }
            if let note = snapshot.note {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

struct MetricRowView: View {
    @ObservedObject var store: UsageStore
    let metric: UsageMetric

    private var pinned: Bool { store.isPinned(metric.id) }

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 4) {
                Text(metric.label)
                    .font(.caption.weight(.medium))
                if let sublabel = metric.sublabel {
                    Text(sublabel)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Text("\(Int(metric.clampedPercent.rounded()))%")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(metric.clampedPercent >= 90 ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                Button {
                    store.togglePin(metric.id)
                } label: {
                    Image(systemName: pinned ? "pin.fill" : "pin")
                        .font(.caption2)
                        .foregroundStyle(pinned ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                }
                .buttonStyle(.plain)
                .help(pinned ? "Remove from menu bar" : "Show in menu bar")
            }
            TimelineView(.periodic(from: .now, by: 60)) { context in
                let paceEnabled = store.showPaceIndicator
                VStack(spacing: 3) {
                    UsageBarView(
                        percent: metric.clampedPercent,
                        color: metric.severityColor,
                        paceFraction: paceEnabled ? metric.elapsedFraction(at: context.date) : nil)
                    if let resetsAt = metric.resetsAt {
                        HStack(spacing: 4) {
                            Text("resets in \(Timestamps.shortCountdown(to: resetsAt, from: context.date))")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            if paceEnabled, let pace = metric.pace(at: context.date) {
                                Text("· \(pace.text)")
                                    .font(.caption2)
                                    .foregroundStyle(pace == .ahead
                                        ? AnyShapeStyle(.orange)
                                        : AnyShapeStyle(.tertiary))
                            }
                            Spacer()
                        }
                    }
                }
            }
        }
    }
}

struct UsageBarView: View {
    let percent: Double
    let color: Color
    /// 0...1 elapsed-time position in the window. Rendered as a hatched blue
    /// segment beneath the fill: fill short of the blue means there's runway
    /// left at an even burn rate; fill covering it means ahead of pace.
    var paceFraction: Double? = nil

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                if let paceFraction, paceFraction > 0 {
                    Capsule()
                        .fill(Color.blue.opacity(0.16))
                        .overlay(
                            DiagonalStripes()
                                .stroke(Color.blue.opacity(0.45), lineWidth: 1.5)
                        )
                        .clipShape(Capsule())
                        .frame(width: max(6, geo.size.width * paceFraction))
                }
                if percent > 0 {
                    Capsule()
                        .fill(color.gradient)
                        .frame(width: max(6, geo.size.width * percent / 100))
                }
            }
        }
        .frame(height: 7)
        .animation(.easeOut(duration: 0.25), value: percent)
    }
}

/// Diagonal cross-hatching for the pace segment.
struct DiagonalStripes: Shape {
    var spacing: CGFloat = 4.5

    func path(in rect: CGRect) -> Path {
        var path = Path()
        var x = -rect.height
        while x < rect.width {
            path.move(to: CGPoint(x: x, y: rect.height))
            path.addLine(to: CGPoint(x: x + rect.height, y: 0))
            x += spacing
        }
        return path
    }
}
