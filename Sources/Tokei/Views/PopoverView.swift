import AppKit
import ServiceManagement
import SwiftUI

struct PopoverView: View {
    @ObservedObject var store: UsageStore
    var openSettings: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            updateBanner
            // Deliberately not a ScrollView: content is bounded (one card per
            // provider), and ScrollView content fails to render inside menu
            // bar hosts on some macOS builds.
            VStack(spacing: 10) {
                ForEach(store.orderedProviders) { provider in
                    ProviderSectionView(store: store, provider: provider)
                }
                if store.orderedProviders.isEmpty {
                    Text("All providers are hidden. Re-enable them from the gear menu.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.vertical, 24)
                }
            }
            .padding(12)
        }
        .frame(width: 336)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { store.refreshIfStale() }
    }

    @ViewBuilder
    private var updateBanner: some View {
        switch store.updateState {
        case .none:
            EmptyView()
        case .available(let info):
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(Color.accentColor)
                Text("Tokei \(info.version) is available")
                    .font(.caption)
                Spacer()
                Button("Install") { store.installUpdate() }
                    .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.accentColor.opacity(0.08))
        case .installing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Installing update — Tokei will relaunch…")
                    .font(.caption)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.accentColor.opacity(0.08))
        case .failed(let message, let info):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .font(.caption)
                Text(message)
                    .font(.caption)
                    .lineLimit(2)
                Spacer()
                if let page = info.pageURL {
                    Button("Open release") { NSWorkspace.shared.open(page) }
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.yellow.opacity(0.08))
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Tokei")
                .font(.headline)
            Spacer()
            if let last = store.lastRefreshed {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(relativeAge(of: last, now: context.date))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Button {
                Task { await store.refreshAll() }
            } label: {
                if store.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 16, height: 16)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderless)
            .help("Refresh now")
            .disabled(store.isRefreshing)

            Button {
                openSettings()
            } label: {
                Label("Settings", systemImage: "gearshape")
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Open Tokei Settings")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func relativeAge(of date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "updated just now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "updated \(minutes)m ago" }
        return "updated \(Int(minutes / 60))h ago"
    }
}

