import AppKit
import Combine
import SwiftUI

@main
enum Main {
    static func main() {
        let arguments = CommandLine.arguments
        if arguments.contains("--check") {
            let semaphore = DispatchSemaphore(value: 0)
            let box = ExitCodeBox()
            Task.detached {
                box.code = await CheckCommand.run()
                semaphore.signal()
            }
            semaphore.wait()
            exit(box.code)
        }
        if let index = arguments.firstIndex(of: "--render-popover"), arguments.count > index + 1 {
            RenderCommand.run(target: .popover, path: arguments[index + 1])
        }
        if let index = arguments.firstIndex(of: "--render-label"), arguments.count > index + 1 {
            RenderCommand.run(target: .label, path: arguments[index + 1])
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

private final class ExitCodeBox: @unchecked Sendable {
    var code: Int32 = 1
}

/// AppKit status-item host. MenuBarExtra (the SwiftUI equivalent) drops
/// custom Shape views from its label and its window-style content host has
/// rendering quirks, so the status item and popover are managed directly.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var store: UsageStore?
    private var labelSubscription: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let store = UsageStore()
        self.store = store

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        item.button?.toolTip = "AI Usage Monitor"

        popover.behavior = .transient
        popover.animates = false
        let host = NSHostingController(rootView: PopoverView(store: store))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host

        // objectWillChange fires before values mutate; hopping through the
        // main queue re-renders the label after the change lands.
        labelSubscription = store.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateLabel() }
        updateLabel()
    }

    private func updateLabel() {
        guard let button = statusItem?.button, let store else { return }
        if let image = MenuBarLabelRenderer.image(for: store.menuBarGroups) {
            button.image = image
        } else {
            button.image = NSImage(
                systemSymbolName: "gauge.with.needle",
                accessibilityDescription: "AI Usage Monitor")
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            store?.refreshIfStale()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
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
                if let note = snapshot.note {
                    print("  note: \(note)")
                }
            } catch {
                print("\(provider.displayName): ✗ \(error.localizedDescription)")
            }
        }
        return successes > 0 ? 0 : 1
    }
}

/// Offscreen UI verification: renders the popover or menu bar label with
/// live data straight to a PNG — no screen recording permission needed.
enum RenderCommand {
    enum Target { case popover, label }

    static func run(target: Target, path: String) -> Never {
        Task { @MainActor in
            let store = UsageStore()
            await store.refreshAll()

            let renderer: ImageRenderer<AnyView>
            switch target {
            case .popover:
                renderer = ImageRenderer(content: AnyView(
                    PopoverView(store: store).frame(width: 336)))
                renderer.proposedSize = ProposedViewSize(width: 336, height: nil)
            case .label:
                renderer = ImageRenderer(content: AnyView(
                    MenuBarLabelContent(groups: store.menuBarGroups)
                        .padding(4)
                        .background(Color.white)))
            }
            renderer.scale = 2

            guard let image = renderer.nsImage,
                  let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else {
                FileHandle.standardError.write(Data("render failed\n".utf8))
                exit(1)
            }
            do {
                try png.write(to: URL(fileURLWithPath: path))
                print("wrote \(path) (\(Int(image.size.width))x\(Int(image.size.height)) pt)")
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("write failed: \(error)\n".utf8))
                exit(1)
            }
        }
        RunLoop.main.run()
        fatalError("unreachable")
    }
}
