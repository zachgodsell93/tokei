import Foundation

/// Reads the Codex CLI's ChatGPT OAuth token from ~/.codex/auth.json and
/// queries the same usage endpoint the Codex CLI uses for its /status
/// display: rolling rate-limit windows (5-hour / weekly) with used percent.
struct OpenAIClient: Sendable {
    static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    static var authFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
    }

    struct AuthFile: Decodable {
        struct Tokens: Decodable {
            let access_token: String
            let account_id: String?
        }
        let tokens: Tokens?
    }

    struct UsageResponse: Decodable {
        struct Window: Decodable {
            let used_percent: Double?
            let limit_window_seconds: Double?
            let reset_at: Double?
            let reset_after_seconds: Double?
        }
        struct RateLimit: Decodable {
            let primary_window: Window?
            let secondary_window: Window?
        }
        struct Credits: Decodable {
            let has_credits: Bool?
            let balance: String?
        }
        let plan_type: String?
        let email: String?
        let rate_limit: RateLimit?
        let credits: Credits?
    }

    /// "5-hour limit" for a ~5h window, "Weekly limit" for ~7d, otherwise a
    /// humanized duration.
    static func windowLabel(seconds: Double) -> (label: String, compact: String) {
        let hours = Int((seconds / 3600).rounded())
        if hours < 24 {
            return ("\(hours)-hour limit", "O\(hours)h")
        }
        let days = Int((seconds / 86400).rounded())
        if days == 7 { return ("Weekly limit", "O7d") }
        return ("\(days)-day limit", "O\(days)d")
    }

    func fetch() async throws -> ProviderSnapshot {
        guard let data = try? Data(contentsOf: Self.authFile) else {
            throw ProviderError.notConnected(AIProvider.openai.setupHint)
        }
        guard let auth = try? JSONDecoder().decode(AuthFile.self, from: data),
              let tokens = auth.tokens else {
            throw ProviderError.notConnected(AIProvider.openai.setupHint)
        }

        var request = URLRequest(url: Self.usageURL)
        request.setValue("Bearer \(tokens.access_token)", forHTTPHeaderField: "Authorization")
        if let accountID = tokens.account_id {
            request.setValue(accountID, forHTTPHeaderField: "chatgpt-account-id")
        }
        // chatgpt.com's edge only accepts requests that identify as the
        // Codex CLI; a generic User-Agent gets a 403 block page.
        request.setValue("codex_cli_rs", forHTTPHeaderField: "originator")
        request.setValue("codex_cli_rs/0.142.5 (AIUsageMonitor; macOS)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let usage: UsageResponse
        do {
            usage = try await HTTP.send(request)
        } catch let error as ProviderError where error.isAuthFailure {
            throw ProviderError.tokenExpired(
                "Codex token was rejected — run `codex login` (or any codex command) to refresh it.")
        }

        var snapshot = ProviderSnapshot(provider: .openai)
        snapshot.planLabel = usage.plan_type?.capitalized
        snapshot.accountLabel = usage.email

        func add(_ window: UsageResponse.Window?, id: String) {
            guard let window, let used = window.used_percent,
                  let seconds = window.limit_window_seconds else { return }
            let (label, compact) = Self.windowLabel(seconds: seconds)
            var resetsAt: Date?
            if let epoch = window.reset_at {
                resetsAt = Date(timeIntervalSince1970: epoch)
            } else if let after = window.reset_after_seconds {
                resetsAt = Date.now.addingTimeInterval(after)
            }
            snapshot.metrics.append(UsageMetric(
                id: id,
                provider: .openai,
                label: label,
                compactCode: compact,
                usedPercent: used,
                resetsAt: resetsAt))
        }

        add(usage.rate_limit?.primary_window, id: "openai.primary")
        add(usage.rate_limit?.secondary_window, id: "openai.secondary")

        if usage.credits?.has_credits == true, let balance = usage.credits?.balance {
            snapshot.note = "Credits balance: \(balance)"
        }
        return snapshot
    }
}
