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
            let dark = arguments.count > index + 2 && arguments[index + 2] == "dark"
            RenderCommand.run(target: .label(dark: dark), path: arguments[index + 1])
        }
        if let index = arguments.firstIndex(of: "--self-test"), arguments.count > index + 1 {
            AppDelegate.selfTestDir = arguments[index + 1]
        }
        AppDelegate.demoMode = arguments.contains("--demo")

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
    /// When set, the app snapshots its live status-item and popover windows
    /// into this directory shortly after launch, then exits.
    static var selfTestDir: String?
    /// Factory settings in an ephemeral defaults suite — for screenshots —
    /// leaving the user's real preferences untouched.
    static var demoMode = false

    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    private var store: UsageStore?
    private var labelSubscription: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let defaults = UserDefaults.standard
        let store: UsageStore
        if Self.demoMode {
            let suiteName = "com.zachgodsell.tokei.demo"
            let demo = UserDefaults(suiteName: suiteName)!
            demo.removePersistentDomain(forName: suiteName)
            store = UsageStore(defaults: demo)
        } else {
            // Migrate before the store reads its settings.
            migrateLegacyPreferences(into: defaults)
            store = UsageStore()
        }
        self.store = store

        // A stale saved position (inherited from the earlier MenuBarExtra
        // builds' "Item-0" autosave) can park the item thousands of points
        // off-screen. Purge legacy/bogus positions before creating the item.
        defaults.removeObject(forKey: "NSStatusItem Preferred Position Item-0")
        let positionKey = "NSStatusItem Preferred Position Tokei"
        if abs(defaults.double(forKey: positionKey)) > 4000 {
            defaults.removeObject(forKey: positionKey)
        }
        // On over-full menu bars (e.g. lots of iStat widgets), macOS appends
        // new items to the clipped overflow end where they are never shown —
        // even tiny icons like Dropbox's get hidden. Seeding a slot near the
        // right-side system cluster makes the first launch land in the
        // visible region; afterwards the user's own drag position (autosaved
        // under the same key) wins.
        if defaults.object(forKey: positionKey) == nil {
            defaults.set(50.0, forKey: positionKey)
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        item.autosaveName = "Tokei"
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        item.button?.toolTip = "Tokei"

        popover.behavior = .transient
        popover.animates = false
        let host = NSHostingController(rootView: PopoverView(
            store: store,
            openSettings: { [weak self] in self?.openSettings() }))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host

        // objectWillChange fires before values mutate; hopping through the
        // main queue re-renders the label after the change lands.
        labelSubscription = store.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateLabel() }
        updateLabel()

        if let dir = Self.selfTestDir {
            runSelfTest(outputDir: dir)
        }
    }

    // Note: no "shrink the label if it doesn't fit" heuristics here. On
    // multi-display setups, status-item windows can legitimately report
    // negative coordinates and a nil screen (visible items from Dropbox,
    // 1Password, etc. show the same), so there is no reliable signal for
    // "macOS hid my item" — a ladder keyed on it degrades a perfectly
    // visible label to an icon.
    /// One-time import of settings saved under the app's previous identity
    /// (bundle id com.zachgodsell.ai-usage-monitor, before it became Tokei).
    private func migrateLegacyPreferences(into defaults: UserDefaults) {
        let migratedKey = "didMigrateLegacyPrefs"
        guard !defaults.bool(forKey: migratedKey) else { return }
        defaults.set(true, forKey: migratedKey)
        guard let legacy = UserDefaults(suiteName: "com.zachgodsell.ai-usage-monitor") else { return }
        let mappings: [(from: String, to: String)] = [
            ("pollMinutes", "pollMinutes"),
            ("enabledProviders", "enabledProviders"),
            ("pinnedMetricsV2", "pinnedMetricsV2"),
            ("NSStatusItem Preferred Position AIUsageMonitor", "NSStatusItem Preferred Position Tokei"),
        ]
        for mapping in mappings where defaults.object(forKey: mapping.to) == nil {
            if let value = legacy.object(forKey: mapping.from) {
                defaults.set(value, forKey: mapping.to)
            }
        }
    }

    private func updateLabel() {
        guard let button = statusItem?.button, let store else { return }
        if let image = MenuBarLabelRenderer.image(for: store.menuBarGroups) {
            button.image = image
        } else {
            button.image = NSImage(
                systemSymbolName: "gauge.with.needle",
                accessibilityDescription: "Tokei")
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

    func openSettings() {
        guard let store else { return }
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView(store: store))
            let window = NSWindow(contentViewController: host)
            window.title = "Tokei Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        popover.performClose(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Self test

    /// Captures the app's own live windows (status item + open popover) as
    /// PNGs plus a status report, then exits. Unlike the --render-* modes,
    /// this exercises the real AppKit pipeline the user sees.
    private func runSelfTest(outputDir: String) {
        Task { @MainActor in
            try? FileManager.default.createDirectory(
                atPath: outputDir, withIntermediateDirectories: true)
            var report: [String] = []

            // Long enough for the 20s per-provider fetch timeout to land.
            for _ in 0..<120 where store?.lastRefreshed == nil {
                try? await Task.sleep(for: .milliseconds(250))
            }
            report.append("firstRefreshCompleted: \(store?.lastRefreshed != nil)")

            for (index, screen) in NSScreen.screens.enumerated() {
                report.append("screen[\(index)]: \(screen.frame)")
            }
            if let button = statusItem?.button, let window = button.window {
                report.append("statusItem.isVisible: \(statusItem?.isVisible ?? false)")
                report.append("statusItem.windowFrame: \(window.frame)")
                report.append("statusItem.onScreen: \(window.screen != nil)")
                report.append("statusItem.occlusion.visible: \(window.occlusionState.contains(.visible))")
                report.append("statusItem.hasImage: \(button.image != nil)")
                report.append("statusItem.imageSize: \(button.image?.size ?? .zero)")
                if let content = window.contentView {
                    snapshot(content, to: "\(outputDir)/statusitem-live.png")
                }
            } else {
                report.append("statusItem: MISSING")
            }

            // Snapshots lose the window's vibrancy backdrop, so each capture
            // is composited over an opaque background matching its
            // appearance (white text on transparent reads as blank).
            popover.appearance = NSAppearance(named: .aqua)
            togglePopover()
            try? await Task.sleep(for: .seconds(1))
            report.append("popover.isShown: \(popover.isShown)")
            if let view = popover.contentViewController?.view {
                view.appearance = NSAppearance(named: .aqua)
                view.layoutSubtreeIfNeeded()
                report.append("popover.viewSize: \(view.bounds.size)")
                snapshot(view, to: "\(outputDir)/popover-light.png",
                         background: NSColor(calibratedWhite: 0.97, alpha: 1))
            }
            if let view = popover.contentViewController?.view {
                view.appearance = NSAppearance(named: .darkAqua)
                view.layoutSubtreeIfNeeded()
                try? await Task.sleep(for: .milliseconds(600))
                snapshot(view, to: "\(outputDir)/popover-dark.png",
                         background: NSColor(calibratedWhite: 0.13, alpha: 1))
            }

            // Settings window, one capture per tab.
            openSettings()
            try? await Task.sleep(for: .milliseconds(600))
            if let window = settingsWindow, let store {
                report.append("settingsWindow.visible: \(window.isVisible)")
                for tab in SettingsView.Tab.allCases {
                    let host = NSHostingController(
                        rootView: SettingsView(store: store, initialTab: tab))
                    window.contentViewController = host
                    host.view.layoutSubtreeIfNeeded()
                    try? await Task.sleep(for: .milliseconds(400))
                    snapshot(host.view, to: "\(outputDir)/settings-\(tab.rawValue.lowercased()).png",
                             background: NSColor(calibratedWhite: 0.97, alpha: 1))
                }
                window.close()
            }

            let metricCounts = AIProvider.allCases.map { provider -> String in
                let count = store?.statuses[provider]?.snapshot?.metrics.count ?? -1
                return "\(provider.rawValue)=\(count)"
            }
            report.append("metrics: \(metricCounts.joined(separator: " "))")

            try? report.joined(separator: "\n")
                .write(toFile: "\(outputDir)/status.txt", atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }

    private func snapshot(_ view: NSView, to path: String,
                          background: NSColor = NSColor(calibratedWhite: 0.35, alpha: 1)) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        // Composite over an opaque backdrop: window snapshots lose the
        // vibrancy backing, which would leave template/white content
        // invisible on the PNG's default white.
        let size = view.bounds.size
        let composed = NSImage(size: size)
        composed.lockFocus()
        background.setFill()
        NSRect(origin: .zero, size: size).fill()
        rep.draw(in: NSRect(origin: .zero, size: size))
        composed.unlockFocus()
        if let tiff = composed.tiffRepresentation,
           let outRep = NSBitmapImageRep(data: tiff),
           let png = outRep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
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
    enum Target { case popover, label(dark: Bool) }

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
            case .label(let dark):
                renderer = ImageRenderer(content: AnyView(
                    MenuBarLabelContent(groups: store.menuBarGroups, tint: dark ? .white : .black)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(dark ? Color(white: 0.13) : Color(white: 0.96))))
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
