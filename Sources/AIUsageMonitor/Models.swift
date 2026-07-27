import SwiftUI

enum AIProvider: String, CaseIterable, Codable, Identifiable, Sendable {
    case claude
    case openai
    case gemini

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .openai: return "OpenAI"
        case .gemini: return "Gemini"
        }
    }

    var shortCode: String {
        switch self {
        case .claude: return "C"
        case .openai: return "O"
        case .gemini: return "G"
        }
    }

    var tint: Color {
        switch self {
        case .claude: return Color(red: 0.85, green: 0.47, blue: 0.34) // #D97757
        case .openai: return Color(red: 0.06, green: 0.64, blue: 0.50) // #10A37F
        case .gemini: return Color(red: 0.26, green: 0.52, blue: 0.96) // #4285F4
        }
    }

    var setupHint: String {
        switch self {
        case .claude: return "Sign in with the Claude Code CLI (run `claude`) to connect."
        case .openai: return "Sign in with the Codex CLI (run `codex login`) to connect."
        case .gemini: return "Sign in with the Gemini CLI (run `gemini`) to connect."
        }
    }
}

struct UsageMetric: Identifiable, Equatable, Sendable {
    let id: String
    let provider: AIProvider
    /// Row title in the popover, e.g. "5-hour limit" or "2.5 Pro".
    let label: String
    /// Compact form for the menu bar, e.g. "C5h".
    let compactCode: String
    var sublabel: String?
    let usedPercent: Double
    var resetsAt: Date?

    var clampedPercent: Double { min(max(usedPercent, 0), 100) }

    var severityColor: Color {
        switch clampedPercent {
        case ..<50: return .green
        case ..<75: return .yellow
        case ..<90: return .orange
        default: return .red
        }
    }

    var menuBarText: String { "\(compactCode) \(Int(clampedPercent.rounded()))%" }
}

struct ProviderSnapshot: Sendable {
    let provider: AIProvider
    var planLabel: String?
    var accountLabel: String?
    var metrics: [UsageMetric] = []
    var note: String?
    var fetchedAt: Date = .now
}

enum ProviderStatus: Sendable {
    case loading
    case ready(ProviderSnapshot)
    case notConnected(String)
    case failed(String)

    var snapshot: ProviderSnapshot? {
        if case .ready(let snap) = self { return snap }
        return nil
    }
}

struct ProviderError: LocalizedError, Sendable {
    enum Kind: Sendable, Equatable {
        case notConnected
        case tokenExpired
        case http(Int)
        case decoding
        case network
    }

    let kind: Kind
    let message: String

    var errorDescription: String? { message }

    var isAuthFailure: Bool {
        switch kind {
        case .tokenExpired: return true
        case .http(let code): return code == 401 || code == 403
        default: return false
        }
    }

    static func notConnected(_ message: String) -> ProviderError {
        ProviderError(kind: .notConnected, message: message)
    }

    static func tokenExpired(_ message: String) -> ProviderError {
        ProviderError(kind: .tokenExpired, message: message)
    }
}
