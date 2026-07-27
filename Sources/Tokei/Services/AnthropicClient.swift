import Foundation

/// Reads the Claude Code OAuth token (macOS Keychain, with a file fallback)
/// and queries Anthropic's OAuth usage endpoint — the same data `/usage`
/// shows inside Claude Code: 5-hour and 7-day rate-limit utilization.
/// An actor so the account profile (plan/email, effectively static) is
/// fetched once per process instead of on every poll.
actor AnthropicClient {
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let profileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!
    static let keychainService = "Claude Code-credentials"

    static var credentialsFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
    }

    struct Credentials: Decodable {
        struct OAuth: Decodable {
            let accessToken: String
            let expiresAt: Double?
        }
        let claudeAiOauth: OAuth
    }

    struct UsageResponse: Decodable {
        struct Window: Decodable {
            let utilization: Double?
            let resets_at: String?
        }
        struct Limit: Decodable {
            struct Scope: Decodable {
                struct Model: Decodable {
                    let display_name: String?
                }
                let model: Model?
                let surface: String?
            }
            let kind: String?
            let group: String?
            let percent: Double?
            let resets_at: String?
            let scope: Scope?
        }
        let five_hour: Window?
        let seven_day: Window?
        let seven_day_opus: Window?
        let seven_day_sonnet: Window?
        let limits: [Limit]?
    }

    /// Model/surface-scoped limits (e.g. the Fable weekly cap) arrive in the
    /// `limits` array rather than as named fields; session and weekly_all
    /// duplicate `five_hour`/`seven_day`, everything else becomes a row.
    static func scopedMetrics(from limits: [UsageResponse.Limit]) -> [UsageMetric] {
        limits.compactMap { limit -> UsageMetric? in
            guard let kind = limit.kind, let percent = limit.percent,
                  kind != "session", kind != "weekly_all" else { return nil }
            let scopeName = limit.scope?.model?.display_name ?? limit.scope?.surface
            let name = scopeName
                ?? kind.replacingOccurrences(of: "_", with: " ").capitalized
            let idSuffix = (scopeName ?? kind).lowercased()
                .replacingOccurrences(of: " ", with: "_")
            return UsageMetric(
                id: "claude.limit.\(idSuffix)",
                provider: .claude,
                label: limit.group == "weekly" ? "7-day · \(name)" : name,
                usedPercent: percent,
                resetsAt: limit.resets_at.flatMap(Timestamps.parseISO))
        }
    }

    struct ProfileResponse: Decodable {
        struct Account: Decodable {
            let email: String?
            let has_claude_max: Bool?
            let has_claude_pro: Bool?
        }
        struct Organization: Decodable {
            let rate_limit_tier: String?
        }
        let account: Account?
        let organization: Organization?
    }

    private var cachedProfile: ProfileResponse?

    nonisolated func loadAccessToken() throws -> String {
        var data = Keychain.read(service: Self.keychainService)
        var fromKeychain = data != nil
        if data == nil {
            data = try? Data(contentsOf: Self.credentialsFile)
            fromKeychain = false
        }
        guard let data else {
            throw ProviderError.notConnected(AIProvider.claude.setupHint)
        }
        guard let creds = try? JSONDecoder().decode(Credentials.self, from: data) else {
            throw ProviderError(kind: .decoding, message: "Could not read Claude Code credentials.")
        }
        if let expiresAt = creds.claudeAiOauth.expiresAt,
           expiresAt / 1000 < Date.now.timeIntervalSince1970 {
            let source = fromKeychain ? "keychain" : "credentials file"
            throw ProviderError.tokenExpired(
                "Claude token in \(source) has expired — open Claude Code once to refresh it.")
        }
        return creds.claudeAiOauth.accessToken
    }

    private nonisolated func request(_ url: URL, token: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    func fetch() async throws -> ProviderSnapshot {
        let token = try loadAccessToken()
        let usage: UsageResponse
        do {
            usage = try await HTTP.send(request(Self.usageURL, token: token))
        } catch let error as ProviderError where error.isAuthFailure {
            throw ProviderError.tokenExpired(
                "Claude token was rejected — open Claude Code once to refresh it.")
        } catch let error as ProviderError where error.kind == .http(429) {
            throw ProviderError(
                kind: .http(429),
                message: "Anthropic rate-limited the usage check — it recovers on its own shortly.")
        }

        var snapshot = ProviderSnapshot(provider: .claude)
        var metrics: [UsageMetric] = []

        func add(_ window: UsageResponse.Window?, id: String, label: String, sublabel: String? = nil) {
            guard let window, let used = window.utilization else { return }
            metrics.append(UsageMetric(
                id: id,
                provider: .claude,
                label: label,
                sublabel: sublabel,
                usedPercent: used,
                resetsAt: window.resets_at.flatMap(Timestamps.parseISO)))
        }

        add(usage.five_hour, id: "claude.five_hour", label: "5-hour limit")
        add(usage.seven_day, id: "claude.seven_day", label: "7-day limit")
        add(usage.seven_day_opus, id: "claude.seven_day_opus", label: "7-day · Opus")
        add(usage.seven_day_sonnet, id: "claude.seven_day_sonnet", label: "7-day · Sonnet")
        metrics.append(contentsOf: Self.scopedMetrics(from: usage.limits ?? []))
        snapshot.metrics = metrics

        if cachedProfile == nil {
            cachedProfile = try? await HTTP.send(request(Self.profileURL, token: token))
        }
        if let profile = cachedProfile {
            snapshot.accountLabel = profile.account?.email
            if profile.account?.has_claude_max == true {
                // rate_limit_tier looks like "default_claude_max_20x".
                if let tier = profile.organization?.rate_limit_tier,
                   let multiplier = tier.split(separator: "_").last, multiplier.hasSuffix("x") {
                    snapshot.planLabel = "Max \(multiplier)"
                } else {
                    snapshot.planLabel = "Max"
                }
            } else if profile.account?.has_claude_pro == true {
                snapshot.planLabel = "Pro"
            }
        }
        return snapshot
    }
}
