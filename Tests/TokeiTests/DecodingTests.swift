import XCTest
@testable import Tokei

final class DecodingTests: XCTestCase {

    // MARK: - Anthropic

    func testAnthropicUsageDecoding() throws {
        let json = """
        {
          "five_hour": {"utilization": 11.0, "resets_at": "2026-07-27T02:50:00.774492+00:00"},
          "seven_day": {"utilization": 35.0, "resets_at": "2026-07-28T01:00:00.774512+00:00"},
          "seven_day_opus": null,
          "seven_day_sonnet": null,
          "extra_usage": {"is_enabled": false}
        }
        """
        let usage = try JSONDecoder().decode(
            AnthropicClient.UsageResponse.self, from: Data(json.utf8))
        XCTAssertEqual(usage.five_hour?.utilization, 11.0)
        XCTAssertEqual(usage.seven_day?.utilization, 35.0)
        XCTAssertNil(usage.seven_day_opus)
        let reset = usage.five_hour?.resets_at.flatMap(Timestamps.parseISO)
        XCTAssertNotNil(reset)
    }

    func testAnthropicScopedLimits() throws {
        let json = """
        [
          {"kind": "session", "group": "session", "percent": 22, "severity": "normal",
           "resets_at": "2026-07-28T02:20:00.514673+00:00", "scope": null, "is_active": false},
          {"kind": "weekly_all", "group": "weekly", "percent": 50, "severity": "normal",
           "resets_at": "2026-07-28T01:00:00.514695+00:00", "scope": null, "is_active": false},
          {"kind": "weekly_scoped", "group": "weekly", "percent": 85, "severity": "warning",
           "resets_at": "2026-07-28T01:00:00.514980+00:00",
           "scope": {"model": {"id": null, "display_name": "Fable"}, "surface": null},
           "is_active": true}
        ]
        """
        let limits = try JSONDecoder().decode(
            [AnthropicClient.UsageResponse.Limit].self, from: Data(json.utf8))
        let metrics = AnthropicClient.scopedMetrics(from: limits)
        XCTAssertEqual(metrics.count, 1)
        XCTAssertEqual(metrics.first?.id, "claude.limit.fable")
        XCTAssertEqual(metrics.first?.label, "7-day · Fable")
        XCTAssertEqual(metrics.first?.usedPercent, 85)
        XCTAssertNotNil(metrics.first?.resetsAt)
    }

    // MARK: - Updates

    func testUpdateVersionComparison() {
        XCTAssertTrue(UpdateChecker.isNewer("v1.1.0", than: "1.0.0"))
        XCTAssertTrue(UpdateChecker.isNewer("1.0.1", than: "1.0.0"))
        XCTAssertTrue(UpdateChecker.isNewer("v2.0", than: "1.9.9"))
        XCTAssertFalse(UpdateChecker.isNewer("v1.0.0", than: "1.0.0"))
        XCTAssertFalse(UpdateChecker.isNewer("v0.9.9", than: "1.0.0"))
        XCTAssertFalse(UpdateChecker.isNewer("v1.0", than: "1.0.0"))
    }

    func testAnthropicProfileDecoding() throws {
        let json = """
        {
          "account": {"email": "z@example.com", "has_claude_max": true, "has_claude_pro": false},
          "organization": {"rate_limit_tier": "default_claude_max_20x"}
        }
        """
        let profile = try JSONDecoder().decode(
            AnthropicClient.ProfileResponse.self, from: Data(json.utf8))
        XCTAssertEqual(profile.account?.has_claude_max, true)
        XCTAssertEqual(profile.organization?.rate_limit_tier, "default_claude_max_20x")
    }

    // MARK: - OpenAI

    func testOpenAIUsageDecoding() throws {
        let json = """
        {
          "plan_type": "plus",
          "email": "z@example.com",
          "rate_limit": {
            "allowed": true,
            "primary_window": {
              "used_percent": 12.5,
              "limit_window_seconds": 18000,
              "reset_after_seconds": 3600,
              "reset_at": 1785715315
            },
            "secondary_window": {
              "used_percent": 40,
              "limit_window_seconds": 604800,
              "reset_after_seconds": 604800,
              "reset_at": 1785715315
            }
          },
          "credits": {"has_credits": false, "balance": "0"}
        }
        """
        let usage = try JSONDecoder().decode(
            OpenAIClient.UsageResponse.self, from: Data(json.utf8))
        XCTAssertEqual(usage.plan_type, "plus")
        XCTAssertEqual(usage.rate_limit?.primary_window?.used_percent, 12.5)
        XCTAssertEqual(usage.rate_limit?.secondary_window?.limit_window_seconds, 604800)
    }

    func testOpenAICreditsBalanceStringOrNumber() throws {
        let asString = try JSONDecoder().decode(
            OpenAIClient.UsageResponse.Credits.self,
            from: Data(#"{"has_credits": true, "balance": "12"}"#.utf8))
        XCTAssertEqual(asString.balance, "12")

        let asNumber = try JSONDecoder().decode(
            OpenAIClient.UsageResponse.Credits.self,
            from: Data(#"{"has_credits": true, "balance": 12.5}"#.utf8))
        XCTAssertEqual(asNumber.balance, "12.5")

        let missing = try JSONDecoder().decode(
            OpenAIClient.UsageResponse.Credits.self,
            from: Data(#"{"has_credits": false}"#.utf8))
        XCTAssertNil(missing.balance)
    }

    func testJWTExpiryParsing() {
        // {"exp": 1785842516} with a dummy header/signature.
        let payload = Data(#"{"exp":1785842516,"iat":1784978516}"#.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let token = "eyJhbGciOiJSUzI1NiJ9.\(payload).sig"
        XCTAssertEqual(
            OpenAIClient.jwtExpiry(token),
            Date(timeIntervalSince1970: 1_785_842_516))
        XCTAssertNil(OpenAIClient.jwtExpiry("not-a-jwt"))
    }

    func testOpenAIWindowLabels() {
        XCTAssertEqual(OpenAIClient.windowLabel(seconds: 18000), "5-hour limit")
        XCTAssertEqual(OpenAIClient.windowLabel(seconds: 604800), "Weekly limit")
        XCTAssertEqual(OpenAIClient.windowLabel(seconds: 259200), "3-day limit")
    }

    // MARK: - Gemini

    func testGeminiQuotaDecoding() throws {
        let json = """
        {
          "buckets": [
            {"resetTime": "2026-07-28T00:02:18Z", "tokenType": "REQUESTS",
             "modelId": "gemini-2.5-pro", "remainingFraction": 0.25},
            {"resetTime": "2026-07-28T00:02:18Z", "tokenType": "REQUESTS",
             "modelId": "gemini-2.5-flash", "remainingFraction": 1,
             "remainingAmount": "1000"}
          ]
        }
        """
        let quota = try JSONDecoder().decode(
            GeminiClient.QuotaResponse.self, from: Data(json.utf8))
        XCTAssertEqual(quota.buckets?.count, 2)
        XCTAssertEqual(quota.buckets?.first?.remainingFraction, 0.25)
        XCTAssertEqual(quota.buckets?.last?.remainingAmount, "1000")
    }

    func testGeminiTierGrouping() {
        // Several modelIds share one pool per tier; the group keeps the
        // minimum remaining fraction (matching the Gemini CLI's display).
        func bucket(_ model: String, _ remaining: Double) -> GeminiClient.QuotaResponse.Bucket {
            try! JSONDecoder().decode(
                GeminiClient.QuotaResponse.Bucket.self,
                from: Data("""
                {"modelId": "\(model)", "remainingFraction": \(remaining),
                 "resetTime": "2026-07-28T00:02:18Z"}
                """.utf8))
        }
        let metrics = GeminiClient.metrics(from: [
            bucket("gemini-2.5-flash", 0.9),
            bucket("gemini-3.1-flash-lite", 0.4),
            bucket("gemini-2.5-flash-lite", 0.8),
            bucket("gemini-2.5-pro", 1.0),
        ])
        XCTAssertEqual(metrics.map(\.id), ["gemini.pro", "gemini.flash", "gemini.flash-lite"])
        XCTAssertEqual(metrics.map(\.label), ["Pro", "Flash", "Flash Lite"])
        XCTAssertEqual(metrics[0].usedPercent, 0, accuracy: 0.001)
        XCTAssertEqual(metrics[1].usedPercent, 10, accuracy: 0.001)
        XCTAssertEqual(metrics[2].usedPercent, 60, accuracy: 0.001)
    }

    func testGeminiOAuthClientParsing() throws {
        let js = """
        const OAUTH_CLIENT_ID = '123456789012-abcdefghijklmnop.apps.googleusercontent.com';
        const OAUTH_CLIENT_SECRET = 'GOCSPX-abc_DEF-12345678';
        """
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("oauth2-test-\(UUID().uuidString).js")
        try js.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        let client = GeminiClient.parseOAuthClient(fromFileAt: file.path)
        XCTAssertEqual(client?.id, "123456789012-abcdefghijklmnop.apps.googleusercontent.com")
        XCTAssertEqual(client?.secret, "GOCSPX-abc_DEF-12345678")
    }

    func testGeminiFallbackClientShape() {
        XCTAssertTrue(GeminiClient.fallbackClient.id.hasSuffix(".apps.googleusercontent.com"))
        XCTAssertTrue(GeminiClient.fallbackClient.secret.hasPrefix("GOCSPX-"))
    }

    func testGeminiModelNames() {
        XCTAssertEqual(GeminiClient.prettyModelName("gemini-2.5-pro"), "2.5 Pro")
        XCTAssertEqual(GeminiClient.prettyModelName("gemini-2.5-flash-lite"), "2.5 Flash Lite")
    }

    // MARK: - Timestamps

    func testISOParsing() {
        XCTAssertNotNil(Timestamps.parseISO("2026-07-28T00:02:18Z"))
        XCTAssertNotNil(Timestamps.parseISO("2026-07-27T02:50:00.774492+00:00"))
        XCTAssertNotNil(Timestamps.parseISO("2026-07-27T02:50:00.774+00:00"))
        XCTAssertNil(Timestamps.parseISO("not a date"))
    }

    func testShortCountdown() {
        let now = Date(timeIntervalSince1970: 1_785_110_400)
        XCTAssertEqual(Timestamps.shortCountdown(to: now.addingTimeInterval(120), from: now), "2m")
        XCTAssertEqual(Timestamps.shortCountdown(to: now.addingTimeInterval(2 * 3600 + 840), from: now), "2h 14m")
        XCTAssertEqual(Timestamps.shortCountdown(to: now.addingTimeInterval(-5), from: now), "now")
        XCTAssertEqual(Timestamps.shortCountdown(to: now.addingTimeInterval(26 * 3600), from: now), "1d 2h")
    }

    // MARK: - Metrics

    func testMetricSeverityAndClamping() {
        func metric(_ percent: Double) -> UsageMetric {
            UsageMetric(id: "t", provider: .claude, label: "t", usedPercent: percent)
        }
        XCTAssertEqual(metric(10).severityColor, .green)
        XCTAssertEqual(metric(60).severityColor, .yellow)
        XCTAssertEqual(metric(80).severityColor, .orange)
        XCTAssertEqual(metric(95).severityColor, .red)
        XCTAssertEqual(metric(150).clampedPercent, 100)
        XCTAssertEqual(metric(-5).clampedPercent, 0)
    }

    func testMenuBarGroupText() {
        let single = UsageStore.MenuBarGroup(provider: .claude, percents: [19.4])
        XCTAssertEqual(single.text, "19%")
        let pair = UsageStore.MenuBarGroup(provider: .claude, percents: [19.4, 36.6])
        XCTAssertEqual(pair.text, "19·37%")
    }
}
