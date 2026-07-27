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

/// Append-only debug log at ~/Library/Caches/Tokei.log recording each fetch
/// outcome — the app has no console when launched normally.
enum Diagnostics {
    static let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Tokei.log")
    private static let queue = DispatchQueue(label: "diagnostics")

    static func log(_ line: String) {
        queue.async {
            let stamp = ISO8601DateFormatter().string(from: .now)
            let entry = "\(stamp) \(line)\n"
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(entry.utf8))
            } else {
                try? entry.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }
}

/// One-shot claim used to guarantee a continuation resumes exactly once.
private final class ResumeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

enum Async {
    /// Runs `operation` but gives up after `seconds`, resuming with a timeout
    /// error. The losing task is abandoned rather than awaited — critical for
    /// operations that can block indefinitely (e.g. a keychain read waiting
    /// on a permission dialog): its eventual result is discarded.
    static func withTimeout<T: Sendable>(
        seconds: Double,
        timeoutMessage: String,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let flag = ResumeFlag()
        return try await withCheckedThrowingContinuation { continuation in
            Task {
                do {
                    let value = try await operation()
                    if flag.claim() { continuation.resume(returning: value) }
                } catch {
                    if flag.claim() { continuation.resume(throwing: error) }
                }
            }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                if flag.claim() {
                    continuation.resume(throwing: ProviderError(
                        kind: .network, message: timeoutMessage))
                }
            }
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
