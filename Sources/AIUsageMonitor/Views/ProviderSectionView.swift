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
            Circle()
                .fill(provider.tint)
                .frame(width: 7, height: 7)
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
            UsageBarView(percent: metric.clampedPercent, color: metric.severityColor)
            if let resetsAt = metric.resetsAt {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    HStack {
                        Text("resets in \(Timestamps.shortCountdown(to: resetsAt, from: context.date))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Spacer()
                    }
                }
            }
        }
    }
}

struct UsageBarView: View {
    let percent: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                if percent > 0 {
                    Capsule()
                        .fill(color.gradient)
                        .frame(width: max(6, geo.size.width * percent / 100))
                }
            }
        }
        .frame(height: 6)
        .animation(.easeOut(duration: 0.25), value: percent)
    }
}
