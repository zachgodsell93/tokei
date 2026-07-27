import AppKit
import SwiftUI

@main
enum Main {
    static func main() {
        if CommandLine.arguments.contains("--check") {
            let semaphore = DispatchSemaphore(value: 0)
            let box = ExitCodeBox()
            Task.detached {
                box.code = await CheckCommand.run()
                semaphore.signal()
            }
            semaphore.wait()
            exit(box.code)
        }
        AIUsageMonitorApp.main()
    }
}

private final class ExitCodeBox: @unchecked Sendable {
    var code: Int32 = 1
}

struct AIUsageMonitorApp: App {
    @StateObject private var store = UsageStore()

    var body: some Scene {
        MenuBarExtra {
            PopoverView(store: store)
        } label: {
            MenuBarLabelView(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabelView: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        if let summary = store.menuBarSummary {
            Text(summary)
                .font(.system(size: 12, weight: .medium).monospacedDigit())
        } else {
            Image(systemName: "gauge.with.needle")
        }
    }
}

/// Headless verification mode: `AIUsageMonitor --check` fetches every
/// provider and prints the metrics to stdout. Exits 0 if at least one
/// provider returned data.
enum CheckCommand {
    static func run() async -> Int32 {
        let anthropic = AnthropicClient()
        let openai = OpenAIClient()
        let gemini = GeminiClient()

        var successes = 0
        for provider in AIProvider.allCases {
            do {
                let snapshot: ProviderSnapshot
                switch provider {
                case .claude: snapshot = try await anthropic.fetch()
                case .openai: snapshot = try await openai.fetch()
                case .gemini: snapshot = try await gemini.fetch()
                }
                successes += 1
                let plan = snapshot.planLabel.map { " [\($0)]" } ?? ""
                let account = snapshot.accountLabel.map { " (\($0))" } ?? ""
                print("\(provider.displayName)\(plan)\(account)")
                if snapshot.metrics.isEmpty {
                    print("  no usage reported yet")
                }
                for metric in snapshot.metrics {
                    let reset = metric.resetsAt.map {
                        "  resets in \(Timestamps.shortCountdown(to: $0))"
                    } ?? ""
                    let sub = metric.sublabel.map { " (\($0))" } ?? ""
                    let percent = String(format: "%3.0f%%", metric.clampedPercent)
                    print("  \(metric.label)\(sub): \(percent)\(reset)")
                }
            } catch {
                print("\(provider.displayName): ✗ \(error.localizedDescription)")
            }
        }
        return successes > 0 ? 0 : 1
    }
}
