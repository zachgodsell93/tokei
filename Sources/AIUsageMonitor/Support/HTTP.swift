import Foundation

enum HTTP {
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    /// Sends a request and decodes a JSON response, mapping transport and
    /// status failures into `ProviderError`.
    static func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ProviderError(kind: .network, message: "Network error: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError(kind: .network, message: "No HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ProviderError(kind: .http(http.statusCode), message: "Request failed (HTTP \(http.statusCode)).")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ProviderError(kind: .decoding, message: "Unexpected response format.")
        }
    }
}

enum Timestamps {
    /// Parses ISO-8601 timestamps with or without fractional seconds,
    /// including the 6-digit microsecond form some APIs return
    /// (e.g. "2026-07-27T02:50:00.774492+00:00").
    static func parseISO(_ string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]

        if let date = plain.date(from: string) { return date }
        // ISO8601DateFormatter only accepts exactly 3 fractional digits,
        // so truncate longer fractions before retrying.
        if let range = string.range(of: #"\.\d+"#, options: .regularExpression) {
            let digits = String(string[range].dropFirst())
            let trimmed = "." + digits.prefix(3)
            let normalized = string.replacingCharacters(in: range, with: trimmed)
            if let date = fractional.date(from: normalized) { return date }
        }
        return fractional.date(from: string)
    }

    /// Short human-readable countdown, e.g. "2h 14m" or "38m".
    static func shortCountdown(to date: Date, from now: Date = .now) -> String {
        let seconds = date.timeIntervalSince(now)
        if seconds <= 0 { return "now" }
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h \(minutes % 60)m" }
        let days = hours / 24
        return "\(days)d \(hours % 24)h"
    }
}
