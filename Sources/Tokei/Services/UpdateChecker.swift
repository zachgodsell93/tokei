import AppKit
import Foundation

struct UpdateInfo: Equatable, Sendable {
    let version: String
    let dmgURL: URL?
    let pageURL: URL?
}

/// Checks the GitHub releases feed for a newer version and installs it in
/// place: download the DMG, swap the app bundle, relaunch. Only active when
/// running from a real .app bundle (dev builds from `swift run` skip it).
enum UpdateChecker {
    static let latestReleaseURL =
        URL(string: "https://api.github.com/repos/zachgodsell93/tokei/releases/latest")!

    struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: String
        }
        let tag_name: String
        let html_url: String?
        let assets: [Asset]?
    }

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    static var isRunningFromBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    /// Numeric semver comparison; tags may carry a leading "v".
    static func isNewer(_ tag: String, than current: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                .split(separator: ".")
                .map { Int($0) ?? 0 }
        }
        let a = parts(tag)
        let b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    static func check() async -> UpdateInfo? {
        guard isRunningFromBundle else { return nil }
        var request = URLRequest(url: latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let release: Release = try? await HTTP.send(request),
              isNewer(release.tag_name, than: currentVersion) else { return nil }
        let dmg = release.assets?.first { $0.name.hasSuffix(".dmg") }
        return UpdateInfo(
            version: release.tag_name,
            dmgURL: dmg.flatMap { URL(string: $0.browser_download_url) },
            pageURL: release.html_url.flatMap(URL.init(string:)))
    }
}

enum UpdateInstaller {
    enum InstallError: LocalizedError {
        case failed(String)
        var errorDescription: String? {
            if case .failed(let message) = self { return message }
            return nil
        }
    }

    /// Downloads the release DMG, replaces the current app bundle with the
    /// new one, and relaunches. The app is not quarantine-flagged for its
    /// own downloads, so the swapped bundle launches without a Gatekeeper
    /// re-prompt (and release builds are notarized anyway).
    static func install(_ info: UpdateInfo) async throws {
        guard let dmgURL = info.dmgURL else {
            throw InstallError.failed("Release has no DMG asset.")
        }
        let targetURL = Bundle.main.bundleURL
        guard targetURL.pathExtension == "app" else {
            throw InstallError.failed("Not running from an app bundle.")
        }

        let (tempFile, response) = try await HTTP.session.download(for: URLRequest(url: dmgURL))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw InstallError.failed("Download failed.")
        }
        let dmgPath = tempFile.deletingPathExtension().appendingPathExtension("dmg")
        try? FileManager.default.removeItem(at: dmgPath)
        try FileManager.default.moveItem(at: tempFile, to: dmgPath)
        defer { try? FileManager.default.removeItem(at: dmgPath) }

        let mountPoint = "/tmp/tokei-update-\(ProcessInfo.processInfo.processIdentifier)"
        try run("/usr/bin/hdiutil",
                ["attach", dmgPath.path, "-nobrowse", "-quiet", "-mountpoint", mountPoint])
        defer { try? run("/usr/bin/hdiutil", ["detach", mountPoint, "-quiet", "-force"]) }

        let sourceApp = "\(mountPoint)/Tokei.app"
        guard FileManager.default.fileExists(atPath: sourceApp) else {
            throw InstallError.failed("Tokei.app not found in the update image.")
        }

        // Replace atomically-ish: stage next to the target, then swap.
        // (ditto preserves signatures, resources, and extended attributes.)
        let staging = targetURL.deletingLastPathComponent()
            .appendingPathComponent(".Tokei-update.app")
        try? FileManager.default.removeItem(at: staging)
        try run("/usr/bin/ditto", [sourceApp, staging.path])
        let old = targetURL.deletingLastPathComponent()
            .appendingPathComponent(".Tokei-old.app")
        try? FileManager.default.removeItem(at: old)
        try FileManager.default.moveItem(at: targetURL, to: old)
        do {
            try FileManager.default.moveItem(at: staging, to: targetURL)
        } catch {
            // Roll back so the user still has a working app.
            try? FileManager.default.moveItem(at: old, to: targetURL)
            throw InstallError.failed("Could not replace the app: \(error.localizedDescription)")
        }
        try? FileManager.default.removeItem(at: old)
        Diagnostics.log("updated to \(info.version), relaunching")
    }

    /// Relaunches the (freshly replaced) bundle and quits this process.
    @MainActor
    static func relaunch() {
        let path = Bundle.main.bundleURL.path
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; /usr/bin/open \"\(path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw InstallError.failed("\(URL(fileURLWithPath: tool).lastPathComponent) failed (\(process.terminationStatus)).")
        }
        return process.terminationStatus
    }
}
