import AppKit
import ServiceManagement
import SwiftUI

struct PopoverView: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
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

            SettingsMenu(store: store)
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

struct SettingsMenu: View {
    @ObservedObject var store: UsageStore
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    private var isBundledApp: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    var body: some View {
        Menu {
            Picker("Refresh every", selection: $store.pollMinutes) {
                Text("1 minute").tag(1)
                Text("5 minutes").tag(5)
                Text("15 minutes").tag(15)
                Text("30 minutes").tag(30)
            }
            .pickerStyle(.menu)

            Section("Providers") {
                ForEach(AIProvider.allCases) { provider in
                    Toggle(provider.displayName, isOn: providerBinding(provider))
                }
            }

            Divider()

            if isBundledApp {
                Toggle("Launch at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enable in
                        do {
                            if enable {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }

            Divider()

            Button("Quit Tokei") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        } label: {
            Image(systemName: "gearshape")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Settings")
    }

    private func providerBinding(_ provider: AIProvider) -> Binding<Bool> {
        Binding(
            get: { store.enabledProviders.contains(provider) },
            set: { enabled in
                if enabled {
                    store.enabledProviders.insert(provider)
                } else {
                    store.enabledProviders.remove(provider)
                }
            })
    }
}
