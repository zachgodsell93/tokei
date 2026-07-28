import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    enum Tab: String, CaseIterable {
        case general = "General"
        case models = "Models"
        case about = "About"

        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .models: return "chart.bar.horizontal.page"
            case .about: return "info.circle"
            }
        }
    }

    @ObservedObject var store: UsageStore
    @State private var selection: Tab

    init(store: UsageStore, initialTab: Tab = .general) {
        self.store = store
        _selection = State(initialValue: initialTab)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            Group {
                switch selection {
                case .general: GeneralSettingsTab(store: store)
                case .models: ModelsSettingsTab(store: store)
                case .about: AboutSettingsTab(store: store)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: 600, height: 430)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 3) {
            sidebarButton(.general)
            sidebarButton(.models)
            Spacer()
            sidebarButton(.about)
        }
        .padding(8)
        .frame(width: 150)
        .background(.thinMaterial)
    }

    private func sidebarButton(_ tab: Tab) -> some View {
        Button {
            selection = tab
        } label: {
            Label(tab.rawValue, systemImage: tab.icon)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selection == tab ? Color.accentColor.opacity(0.18) : .clear)
        )
        .foregroundStyle(selection == tab ? Color.accentColor : Color.primary)
    }
}

// MARK: - General

struct GeneralSettingsTab: View {
    @ObservedObject var store: UsageStore
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    private var isBundledApp: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("General")
                .font(.title3.weight(.semibold))

            Toggle("Open at login", isOn: $launchAtLogin)
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
                .disabled(!isBundledApp)
                .help(isBundledApp ? "Start Tokei automatically when you log in"
                                   : "Available when running the installed app")

            Picker("Refresh usage every", selection: $store.pollMinutes) {
                Text("1 minute").tag(1)
                Text("5 minutes").tag(5)
                Text("15 minutes").tag(15)
                Text("30 minutes").tag(30)
            }
            .pickerStyle(.menu)
            .fixedSize()

            VStack(alignment: .leading, spacing: 2) {
                Toggle("Show pace indicator", isOn: $store.showPaceIndicator)
                Text("Shows a hatched blue segment up to where usage would sit if burned evenly until the window resets — the zone you're tracking toward. Fill past the blue means you're ahead of pace.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Updates")
                    .font(.headline)
                UpdateStatusRow(store: store)
            }

            Spacer()

            HStack {
                Spacer()
                Button("Quit Tokei") { NSApp.terminate(nil) }
            }
        }
        .padding(20)
    }
}

/// Shared update status + actions, used by General and About.
struct UpdateStatusRow: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch store.updateState {
            case .none:
                HStack(spacing: 8) {
                    Button("Check for Updates") { store.checkForUpdates(force: true) }
                    if let checked = store.lastUpdateCheckedAt {
                        Text("Up to date · checked \(Timestamps.shortCountdown(to: .now, from: checked)) ago")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            case .available(let info):
                HStack(spacing: 8) {
                    Text("Tokei \(info.version) is available")
                        .font(.callout)
                    Button("Install Update") { store.installUpdate() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            case .installing:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Installing — Tokei will relaunch…")
                        .font(.callout)
                }
            case .failed(let message, let info):
                VStack(alignment: .leading, spacing: 4) {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let page = info.pageURL {
                        Button("Open Release Page") { NSWorkspace.shared.open(page) }
                            .controlSize(.small)
                    }
                }
            }
        }
    }
}

// MARK: - Models

struct ModelsSettingsTab: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Models")
                .font(.title3.weight(.semibold))
            Text("Choose which providers appear in the dropdown, and pin metrics to show them in the menu bar.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 6)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(AIProvider.allCases) { provider in
                        providerSection(provider)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .padding(20)
    }

    private func providerSection(_ provider: AIProvider) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: providerBinding(provider)) {
                HStack(spacing: 6) {
                    ProviderLogo(provider: provider)
                        .foregroundStyle(provider.tint)
                        .frame(width: 13, height: 13)
                    Text(provider.displayName)
                        .font(.subheadline.weight(.semibold))
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            if store.enabledProviders.contains(provider) {
                let metrics = store.statuses[provider]?.snapshot?.metrics ?? []
                if metrics.isEmpty {
                    Text("No metrics reported yet — they appear after the first refresh.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 22)
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(metrics) { metric in
                            Toggle(isOn: pinBinding(metric.id)) {
                                HStack(spacing: 5) {
                                    Text(metric.label)
                                        .font(.caption)
                                    if let sub = metric.sublabel {
                                        Text(sub)
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                    Text("· show in menu bar")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                    .padding(.leading, 22)
                }
            }
        }
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

    private func pinBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { store.isPinned(id) },
            set: { _ in store.togglePin(id) })
    }
}

// MARK: - About

struct AboutSettingsTab: View {
    @ObservedObject var store: UsageStore

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    private var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "–"
    }

    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                .resizable()
                .frame(width: 76, height: 76)
            Text("Tokei")
                .font(.title2.weight(.bold))
            Text("時計 — your AI usage, on the clock.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Version \(version) (build \(build))")
                .font(.callout)
                .foregroundStyle(.secondary)

            if let checked = store.lastUpdateCheckedAt {
                Text("Last checked for updates \(Timestamps.shortCountdown(to: .now, from: checked)) ago")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            UpdateStatusRow(store: store)
                .padding(.top, 2)

            Spacer()

            HStack(spacing: 14) {
                Button("GitHub") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/zachgodsell93/tokei")!)
                }
                .buttonStyle(.link)
                Button("Report an Issue") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/zachgodsell93/tokei/issues")!)
                }
                .buttonStyle(.link)
            }
            Text("© 2026 Zach Godsell · MIT License")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
    }
}
