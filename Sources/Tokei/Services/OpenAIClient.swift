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
            let allowed: Bool?
            let limit_reached: Bool?
            let primary_window: Window?
            let secondary_window: Window?
        }
        struct AdditionalRateLimit: Decodable {
            let limit_name: String?
            let rate_limit: RateLimit?
        }
        struct Credits: Decodable {
            let has_credits: Bool?
            let balance: String?

            private enum CodingKeys: String, CodingKey {
                case has_credits, balance
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                has_credits = try? container.decode(Bool.self, forKey: .has_credits)
                // The server has shipped balance as both a string and a
                // number at different times — accept either.
                if let text = try? container.decode(String.self, forKey: .balance) {
                    balance = text
                } else if let value = try? container.decode(Double.self, forKey: .balance) {
                    balance = value == value.rounded() ? String(Int(value)) : String(value)
                } else {
                    balance = nil
                }
            }
        }
        let plan_type: String?
        let email: String?
        let rate_limit: RateLimit?
        let additional_rate_limits: [AdditionalRateLimit]?
        let credits: Credits?
    }

    /// Extracts the `exp` claim from a JWT so an expired token surfaces as a
    /// clear "re-authenticate" state instead of an opaque 401.
    static func jwtExpiry(_ token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = parts[1]
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = payload["exp"] as? Double else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    /// "5-hour limit" for a ~5h window, "Weekly limit" for ~7d, otherwise a
    /// humanized duration.
    static func windowLabel(seconds: Double) -> String {
        let hours = Int((seconds / 3600).rounded())
        if hours < 24 {
            return "\(hours)-hour limit"
        }
        let days = Int((seconds / 86400).rounded())
        return days == 7 ? "Weekly limit" : "\(days)-day limit"
    }

    func fetch() async throws -> ProviderSnapshot {
        guard let data = try? Data(contentsOf: Self.authFile) else {
            throw ProviderError.notConnected(AIProvider.openai.setupHint)
        }
        guard let auth = try? JSONDecoder().decode(AuthFile.self, from: data),
              let tokens = auth.tokens else {
            throw ProviderError.notConnected(AIProvider.openai.setupHint)
        }

        // Codex CLI access tokens live ~10 days and the CLI refreshes them on
        // use. Refresh tokens rotate server-side, so refreshing here could
        // invalidate the CLI's copy — instead, surface expiry and let the
        // CLI do the refreshing.
        if let expiry = Self.jwtExpiry(tokens.access_token), expiry < .now {
            throw ProviderError.tokenExpired(
                "Codex token expired — run any codex command to refresh it.")
        }

        var request = URLRequest(url: Self.usageURL)
        request.setValue("Bearer \(tokens.access_token)", forHTTPHeaderField: "Authorization")
        if let accountID = tokens.account_id {
            // Scopes the query to the right workspace on team/business plans.
            request.setValue(accountID, forHTTPHeaderField: "chatgpt-account-id")
        }
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

        func makeMetric(_ window: UsageResponse.Window, id: String, sublabel: String? = nil) -> UsageMetric? {
            guard let used = window.used_percent,
                  let seconds = window.limit_window_seconds else { return nil }
            var resetsAt: Date?
            if let epoch = window.reset_at {
                resetsAt = Date(timeIntervalSince1970: epoch)
            } else if let after = window.reset_after_seconds {
                resetsAt = Date.now.addingTimeInterval(after)
            }
            return UsageMetric(
                id: id,
                provider: .openai,
                label: Self.windowLabel(seconds: seconds),
                sublabel: sublabel,
                usedPercent: used,
                resetsAt: resetsAt)
        }

        // The API only reports windows with activity (a fresh account gets
        // just the weekly window, or none). Present stable 5-hour and weekly
        // slots regardless: an unreported window genuinely means 0% used.
        var fiveHour: UsageMetric?
        var weekly: UsageMetric?
        for window in [usage.rate_limit?.primary_window, usage.rate_limit?.secondary_window] {
            guard let window, let seconds = window.limit_window_seconds else { continue }
            if seconds < 86400 {
                if fiveHour == nil { fiveHour = makeMetric(window, id: "openai.five_hour") }
            } else if weekly == nil {
                weekly = makeMetric(window, id: "openai.seven_day")
            }
        }
        snapshot.metrics.append(fiveHour ?? UsageMetric(
            id: "openai.five_hour", provider: .openai, label: "5-hour limit", usedPercent: 0))
        snapshot.metrics.append(weekly ?? UsageMetric(
            id: "openai.seven_day", provider: .openai, label: "Weekly limit", usedPercent: 0))

        // Model-specific limits (e.g. Spark) arrive as named extra rate limits.
        for extra in usage.additional_rate_limits ?? [] {
            guard let limit = extra.rate_limit else { continue }
            let name = extra.limit_name ?? "extra"
            for (slot, window) in [("primary", limit.primary_window), ("secondary", limit.secondary_window)] {
                if let window, let metric = makeMetric(window, id: "openai.\(name).\(slot)", sublabel: name) {
                    snapshot.metrics.append(metric)
                }
            }
        }

        var notes: [String] = []
        if usage.rate_limit?.limit_reached == true {
            notes.append("Rate limit reached.")
        }
        if usage.credits?.has_credits == true, let balance = usage.credits?.balance {
            notes.append("Credits balance: \(balance)")
        }
        if !notes.isEmpty {
            snapshot.note = notes.joined(separator: " ")
        }
        return snapshot
    }
}
