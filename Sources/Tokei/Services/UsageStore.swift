import Foundation
import SwiftUI

@MainActor
final class UsageStore: ObservableObject {
    enum UpdateState: Equatable {
        case none
        case available(UpdateInfo)
        case installing
        case failed(String, UpdateInfo)
    }

    @Published private(set) var statuses: [AIProvider: ProviderStatus] = [:]
    @Published private(set) var updateState: UpdateState = .none
    @Published private(set) var lastUpdateCheckedAt: Date?
    /// Transient fetch problems (network blips) shown as a warning while the
    /// last good snapshot stays on screen.
    @Published private(set) var staleNotes: [AIProvider: String] = [:]
    @Published private(set) var lastRefreshed: Date?
    @Published private(set) var isRefreshing = false

    @Published var pollMinutes: Int {
        didSet {
            defaults.set(pollMinutes, forKey: Keys.pollMinutes)
            startPolling()
        }
    }

    @Published var enabledProviders: Set<AIProvider> {
        didSet {
            defaults.set(enabledProviders.map(\.rawValue).sorted(), forKey: Keys.enabledProviders)
            for provider in AIProvider.allCases where !enabledProviders.contains(provider) {
                statuses[provider] = nil
                staleNotes[provider] = nil
            }
            Task { await refreshAll() }
        }
    }

    @Published var pinnedMetricIDs: [String] {
        didSet { defaults.set(pinnedMetricIDs, forKey: Keys.pinnedMetrics) }
    }

    private enum Keys {
        static let pollMinutes = "pollMinutes"
        static let enabledProviders = "enabledProviders"
        // v2: pin IDs became slot-based (openai.five_hour) and the default
        // set grew to one entry per provider when logos landed.
        static let pinnedMetrics = "pinnedMetricsV2"
    }

    static let defaultPinnedMetricIDs = [
        "claude.five_hour", "claude.seven_day",
        "openai.five_hour", "openai.seven_day",
        "gemini.pro",
    ]

    private let defaults: UserDefaults
    private let anthropic = AnthropicClient()
    private let openai = OpenAIClient()
    private let gemini = GeminiClient()
    private var pollTask: Task<Void, Never>?
    private var lastUpdateCheck: Date?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedMinutes = defaults.integer(forKey: Keys.pollMinutes)
        pollMinutes = storedMinutes > 0 ? storedMinutes : 5
        if let stored = defaults.stringArray(forKey: Keys.enabledProviders) {
            enabledProviders = Set(stored.compactMap(AIProvider.init(rawValue:)))
        } else {
            enabledProviders = Set(AIProvider.allCases)
        }
        pinnedMetricIDs = defaults.stringArray(forKey: Keys.pinnedMetrics)
            ?? Self.defaultPinnedMetricIDs
        startPolling()
    }

    func startPolling() {
        pollTask?.cancel()
        let interval = max(1, pollMinutes)
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshAll()
                self?.checkForUpdates()
                try? await Task.sleep(for: .seconds(interval * 60))
            }
        }
    }

    // MARK: - Updates

    /// Throttled to twice a day unless forced from the gear menu.
    func checkForUpdates(force: Bool = false) {
        if case .installing = updateState { return }
        if !force, let last = lastUpdateCheck,
           Date.now.timeIntervalSince(last) < 12 * 3600 { return }
        lastUpdateCheck = .now
        Task { [weak self] in
            if let info = await UpdateChecker.check() {
                self?.updateState = .available(info)
            } else if force {
                self?.updateState = .none
            }
            self?.lastUpdateCheckedAt = .now
        }
    }

    func installUpdate() {
        guard case .available(let info) = updateState else { return }
        updateState = .installing
        Task { [weak self] in
            do {
                try await UpdateInstaller.install(info)
                UpdateInstaller.relaunch()
            } catch {
                self?.updateState = .failed(error.localizedDescription, info)
            }
        }
    }

    func refreshIfStale(maxAge: TimeInterval = 45) {
        guard !isRefreshing else { return }
        if let last = lastRefreshed, Date.now.timeIntervalSince(last) < maxAge { return }
        Task { await refreshAll() }
    }

    func refresh(_ provider: AIProvider) {
        Task {
            let status = await fetchStatus(for: provider)
            apply(status, for: provider)
        }
    }

    func refreshAll() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let providers = AIProvider.allCases.filter { enabledProviders.contains($0) }
        for provider in providers where statuses[provider] == nil {
            statuses[provider] = .loading
        }
        await withTaskGroup(of: (AIProvider, ProviderStatus).self) { group in
            for provider in providers {
                group.addTask { [self] in
                    (provider, await fetchStatus(for: provider))
                }
            }
            for await (provider, status) in group {
                apply(status, for: provider)
            }
        }
        lastRefreshed = .now

        // A transient failure right after launch would otherwise leave a
        // provider (and the menu bar readout) empty until the next poll —
        // retry failed fetches once after a short beat.
        let failed = providers.filter {
            if case .failed = statuses[$0] { return true }
            return false
        }
        if !failed.isEmpty {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                guard let self else { return }
                for provider in failed {
                    if case .failed = self.statuses[provider] {
                        self.refresh(provider)
                    }
                }
            }
        }
    }

    private nonisolated func fetchStatus(for provider: AIProvider) async -> ProviderStatus {
        do {
            // The timeout abandons hung work (e.g. a keychain read stuck on a
            // permission dialog) so one provider can never wedge refreshes.
            let snapshot = try await Async.withTimeout(
                seconds: 20,
                timeoutMessage: "\(provider.displayName) timed out — a keychain or network prompt may be waiting."
            ) { [anthropic, openai, gemini] in
                switch provider {
                case .claude: return try await anthropic.fetch()
                case .openai: return try await openai.fetch()
                case .gemini: return try await gemini.fetch()
                }
            }
            return .ready(snapshot)
        } catch let error as ProviderError {
            switch error.kind {
            case .notConnected: return .notConnected(error.message)
            default: return .failed(error.message)
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func apply(_ status: ProviderStatus, for provider: AIProvider) {
        switch status {
        case .ready(let snap):
            Diagnostics.log("\(provider.rawValue): ready, \(snap.metrics.count) metrics")
        case .failed(let message):
            Diagnostics.log("\(provider.rawValue): FAILED — \(message)")
        case .notConnected(let hint):
            Diagnostics.log("\(provider.rawValue): not connected — \(hint)")
        case .loading:
            break
        }
        switch status {
        case .failed(let message):
            // Keep showing the last good data through transient failures;
            // auth problems need user action, so those replace the view.
            if case .ready(let previous)? = statuses[provider] {
                statuses[provider] = .ready(previous)
                staleNotes[provider] = message
                return
            }
            statuses[provider] = status
        default:
            staleNotes[provider] = nil
            statuses[provider] = status
        }
    }

    // MARK: - Metrics

    var orderedProviders: [AIProvider] {
        AIProvider.allCases.filter { enabledProviders.contains($0) }
    }

    var allMetrics: [UsageMetric] {
        orderedProviders.flatMap { statuses[$0]?.snapshot?.metrics ?? [] }
    }

    func metric(id: String) -> UsageMetric? {
        allMetrics.first { $0.id == id }
    }

    func isPinned(_ id: String) -> Bool {
        pinnedMetricIDs.contains(id)
    }

    func togglePin(_ id: String) {
        if let index = pinnedMetricIDs.firstIndex(of: id) {
            pinnedMetricIDs.remove(at: index)
        } else {
            pinnedMetricIDs.append(id)
        }
    }

    struct MenuBarGroup: Identifiable, Equatable {
        let provider: AIProvider
        /// Pinned metric percentages in pin order, e.g. [19, 37].
        let percents: [Double]
        var id: String { provider.rawValue }

        /// "19·37%" — values joined with a middot, one trailing percent sign.
        var text: String {
            percents.map { String(Int($0.rounded())) }.joined(separator: "·") + "%"
        }
    }

    /// Pinned metrics grouped per provider for the menu bar:
    /// one provider logo followed by that provider's pinned percentages.
    var menuBarGroups: [MenuBarGroup] {
        orderedProviders.compactMap { provider in
            let pinned = pinnedMetricIDs
                .compactMap { metric(id: $0) }
                .filter { $0.provider == provider }
            guard !pinned.isEmpty else { return nil }
            return MenuBarGroup(provider: provider, percents: pinned.map(\.clampedPercent))
        }
    }
}
