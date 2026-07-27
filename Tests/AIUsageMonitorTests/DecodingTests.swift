import XCTest
@testable import AIUsageMonitor

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

    func testOpenAIWindowLabels() {
        XCTAssertEqual(OpenAIClient.windowLabel(seconds: 18000).label, "5-hour limit")
        XCTAssertEqual(OpenAIClient.windowLabel(seconds: 18000).compact, "O5h")
        XCTAssertEqual(OpenAIClient.windowLabel(seconds: 604800).label, "Weekly limit")
        XCTAssertEqual(OpenAIClient.windowLabel(seconds: 604800).compact, "O7d")
        XCTAssertEqual(OpenAIClient.windowLabel(seconds: 259200).label, "3-day limit")
    }

    // MARK: - Gemini

    func testGeminiQuotaDecoding() throws {
        let json = """
        {
          "buckets": [
            {"resetTime": "2026-07-28T00:02:18Z", "tokenType": "REQUESTS",
             "modelId": "gemini-2.5-pro", "remainingFraction": 0.25},
            {"resetTime": "2026-07-28T00:02:18Z", "tokenType": "TOKENS",
             "modelId": "gemini-2.5-pro", "remainingFraction": 1}
          ]
        }
        """
        let quota = try JSONDecoder().decode(
            GeminiClient.QuotaResponse.self, from: Data(json.utf8))
        XCTAssertEqual(quota.buckets?.count, 2)
        let requests = quota.buckets?.filter { $0.tokenType == "REQUESTS" }
        XCTAssertEqual(requests?.count, 1)
        XCTAssertEqual(requests?.first?.remainingFraction, 0.25)
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
        XCTAssertEqual(GeminiClient.compactModelCode("2.5 Pro"), "GP")
        XCTAssertEqual(GeminiClient.compactModelCode("2.5 Flash Lite"), "GFL")
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

    func testMetricSeverityAndMenuBarText() {
        func metric(_ percent: Double) -> UsageMetric {
            UsageMetric(id: "t", provider: .claude, label: "t", compactCode: "C5h",
                        usedPercent: percent)
        }
        XCTAssertEqual(metric(10).severityColor, .green)
        XCTAssertEqual(metric(60).severityColor, .yellow)
        XCTAssertEqual(metric(80).severityColor, .orange)
        XCTAssertEqual(metric(95).severityColor, .red)
        XCTAssertEqual(metric(150).clampedPercent, 100)
        XCTAssertEqual(metric(-5).clampedPercent, 0)
        XCTAssertEqual(metric(11.4).menuBarText, "C5h 11%")
    }
}
