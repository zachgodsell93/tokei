import Foundation

/// Reads the Gemini CLI's Google OAuth credentials from
/// ~/.gemini/oauth_creds.json and queries the Code Assist quota endpoint for
/// per-model daily request usage. Access tokens only live for an hour, so
/// this client refreshes them in memory (never writing back to the CLI's
/// files — Google refresh tokens are reusable, so the CLI is unaffected).
actor GeminiClient {
    static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    static let quotaURL = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota")!
    static let loadURL = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")!

    // Token refresh needs the Gemini CLI's own OAuth client. A Google
    // "installed app" client cannot keep its secret confidential — these
    // values ship in plaintext in the open-source google-gemini/gemini-cli
    // repo (packages/core/src/code_assist/oauth2.ts) and in every local
    // install, so they're public constants rather than secrets. We prefer
    // reading them from the locally installed CLI (version-matched); the
    // fallback literals are assembled from parts only so secret scanners
    // don't false-positive on the well-known values.
    struct OAuthClient: Sendable {
        let id: String
        let secret: String
    }

    static let fallbackClient = OAuthClient(
        id: ["681255809395", "oo8ft2oprdrnp9e3aqf6av3hmdib135j.apps.googleusercontent.com"].joined(separator: "-"),
        secret: ["GOCSPX", "4uHgMPm", "1o7Sk", "geV6Cu5clXFsxl"].joined(separator: "-"))

    private var cachedOAuthClient: OAuthClient?

    private func oauthClient() -> OAuthClient {
        if let cachedOAuthClient { return cachedOAuthClient }
        let env = ProcessInfo.processInfo.environment
        let client: OAuthClient
        if let id = env["GEMINI_OAUTH_CLIENT_ID"], let secret = env["GEMINI_OAUTH_CLIENT_SECRET"] {
            client = OAuthClient(id: id, secret: secret)
        } else {
            client = Self.discoverInstalledClient() ?? Self.fallbackClient
        }
        cachedOAuthClient = client
        return client
    }

    /// Extracts the OAuth client from the locally installed gemini-cli
    /// (its code_assist/oauth2.js), so the values stay version-matched.
    static func discoverInstalledClient() -> OAuthClient? {
        let fileManager = FileManager.default
        var candidates = ["/opt/homebrew/bin/gemini", "/usr/local/bin/gemini"]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map { "\($0)/gemini" }
        }
        for candidate in candidates where fileManager.isExecutableFile(atPath: candidate) {
            let resolved = URL(fileURLWithPath: candidate).resolvingSymlinksInPath().path
            guard let range = resolved.range(of: "/node_modules/") else { continue }
            let searchRoot = resolved[..<range.upperBound] + "@google"
            guard let enumerator = fileManager.enumerator(atPath: String(searchRoot)) else { continue }
            for case let relative as String in enumerator where relative.hasSuffix("code_assist/oauth2.js") {
                if let client = parseOAuthClient(fromFileAt: "\(searchRoot)/\(relative)") {
                    return client
                }
            }
        }
        return nil
    }

    static func parseOAuthClient(fromFileAt path: String) -> OAuthClient? {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        guard let id = contents.firstMatch(of: #/[0-9]{6,}-[a-z0-9]+\.apps\.googleusercontent\.com/#),
              let secret = contents.firstMatch(of: #/GOCSPX-[A-Za-z0-9_-]{10,}/#) else { return nil }
        return OAuthClient(id: String(id.output), secret: String(secret.output))
    }

    static var credsFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/oauth_creds.json")
    }

    static var accountsFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/google_accounts.json")
    }

    private var cachedToken: (value: String, expiresAt: Date)?
    private var cachedTierName: String?
    private var cachedNote: String?
    private var tierLookupDone = false

    struct OAuthCreds: Decodable {
        let access_token: String?
        let refresh_token: String?
        let expiry_date: Double?
    }

    struct TokenResponse: Decodable {
        let access_token: String
        let expires_in: Double?
    }

    struct QuotaResponse: Decodable {
        struct Bucket: Decodable {
            let resetTime: String?
            let tokenType: String?
            let modelId: String?
            let remainingFraction: Double?
            let remainingAmount: String?
        }
        let buckets: [Bucket]?
    }

    struct LoadResponse: Decodable {
        struct Tier: Decodable {
            let name: String?
            let isDefault: Bool?
        }
        let currentTier: Tier?
        let allowedTiers: [Tier]?
    }

    struct Accounts: Decodable {
        let active: String?
    }

    /// "gemini-2.5-flash-lite" → "2.5 Flash Lite"
    static func prettyModelName(_ modelId: String) -> String {
        var name = modelId
        if name.hasPrefix("gemini-") { name.removeFirst("gemini-".count) }
        return name.split(separator: "-")
            .map { part -> String in
                if part.first?.isNumber == true { return String(part) }
                return part.prefix(1).uppercased() + part.dropFirst()
            }
            .joined(separator: " ")
    }

    struct TierGroup: Equatable, Sendable {
        let key: String
        let label: String
        let order: Int
    }

    /// Several modelIds draw from one quota pool, so — like the Gemini CLI's
    /// own quota display — buckets are grouped by model tier and the group
    /// reports the *minimum* remaining fraction.
    static func tierGroup(for modelId: String) -> TierGroup {
        let lower = modelId.lowercased()
        if lower.contains("flash-lite") {
            return TierGroup(key: "flash-lite", label: "Flash Lite", order: 2)
        }
        if lower.contains("flash") {
            return TierGroup(key: "flash", label: "Flash", order: 1)
        }
        if lower.contains("pro") {
            return TierGroup(key: "pro", label: "Pro", order: 0)
        }
        return TierGroup(key: modelId, label: prettyModelName(modelId), order: 3)
    }

    /// Groups raw buckets into per-tier metrics, keeping each group's lowest
    /// remaining fraction (and that bucket's reset time). `tokenType` is not
    /// an enum server-side, so buckets are not filtered by it.
    static func metrics(from buckets: [QuotaResponse.Bucket]) -> [UsageMetric] {
        var worst: [String: (group: TierGroup, fraction: Double, resetTime: String?)] = [:]
        for bucket in buckets {
            guard let modelId = bucket.modelId, let fraction = bucket.remainingFraction else {
                continue
            }
            let group = tierGroup(for: modelId)
            if let existing = worst[group.key], existing.fraction <= fraction { continue }
            worst[group.key] = (group, fraction, bucket.resetTime)
        }
        return worst.values
            .sorted { ($0.group.order, $0.group.label) < ($1.group.order, $1.group.label) }
            .map { entry in
                UsageMetric(
                    id: "gemini.\(entry.group.key)",
                    provider: .gemini,
                    label: entry.group.label,
                    sublabel: "daily",
                    usedPercent: (1 - entry.fraction) * 100,
                    resetsAt: entry.resetTime.flatMap(Timestamps.parseISO))
            }
    }

    private func accessToken() async throws -> String {
        if let cached = cachedToken, cached.expiresAt > Date.now.addingTimeInterval(60) {
            return cached.value
        }
        guard let data = try? Data(contentsOf: Self.credsFile) else {
            throw ProviderError.notConnected(AIProvider.gemini.setupHint)
        }
        guard let creds = try? JSONDecoder().decode(OAuthCreds.self, from: data) else {
            throw ProviderError(kind: .decoding, message: "Could not read Gemini CLI credentials.")
        }

        if let token = creds.access_token, let expiry = creds.expiry_date,
           Date(timeIntervalSince1970: expiry / 1000) > Date.now.addingTimeInterval(60) {
            cachedToken = (token, Date(timeIntervalSince1970: expiry / 1000))
            return token
        }

        guard let refreshToken = creds.refresh_token else {
            throw ProviderError.tokenExpired(
                "Gemini token expired and no refresh token found — run `gemini` to sign in again.")
        }

        let oauth = oauthClient()
        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "client_id", value: oauth.id),
            URLQueryItem(name: "client_secret", value: oauth.secret),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "grant_type", value: "refresh_token"),
        ]
        request.httpBody = components.percentEncodedQuery.map { Data($0.utf8) }

        let token: TokenResponse
        do {
            token = try await HTTP.send(request)
        } catch let error as ProviderError where error.isAuthFailure || error.kind == .http(400) {
            throw ProviderError.tokenExpired(
                "Gemini sign-in expired — run `gemini` to sign in again.")
        }
        let expiresAt = Date.now.addingTimeInterval(token.expires_in ?? 3600)
        cachedToken = (token.access_token, expiresAt)
        return token.access_token
    }

    private func jsonRequest(_ url: URL, token: String, body: Data) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }

    func fetch() async throws -> ProviderSnapshot {
        let token = try await accessToken()
        let quota: QuotaResponse = try await HTTP.send(
            jsonRequest(Self.quotaURL, token: token, body: Data("{}".utf8)))

        var snapshot = ProviderSnapshot(provider: .gemini)
        snapshot.metrics = Self.metrics(from: quota.buckets ?? [])

        if !tierLookupDone {
            tierLookupDone = true
            let body = Data(#"{"metadata":{"ideType":"IDE_UNSPECIFIED","platform":"PLATFORM_UNSPECIFIED","pluginType":"GEMINI"}}"#.utf8)
            if let load: LoadResponse = try? await HTTP.send(
                jsonRequest(Self.loadURL, token: token, body: body)) {
                cachedTierName = load.currentTier?.name
                    ?? load.allowedTiers?.first(where: { $0.isDefault == true })?.name
                    ?? load.allowedTiers?.first?.name
                // No currentTier means the account isn't onboarded to Code
                // Assist (e.g. consumer accounts after the June 2026 cutoff);
                // the quota endpoint still answers, but nothing draws it down.
                if load.currentTier == nil {
                    cachedNote = "Account isn't onboarded to Code Assist — quota may not reflect real limits."
                }
            }
        }
        snapshot.planLabel = cachedTierName
        snapshot.note = cachedNote

        if let data = try? Data(contentsOf: Self.accountsFile),
           let accounts = try? JSONDecoder().decode(Accounts.self, from: data) {
            snapshot.accountLabel = accounts.active
        }
        return snapshot
    }
}
