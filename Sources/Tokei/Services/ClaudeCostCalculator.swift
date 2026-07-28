import Foundation

/// Computes the dollar value of local Claude Code inference by parsing the
/// per-message token usage that Claude Code writes to
/// ~/.claude/projects/**/*.jsonl and pricing it at API rates (the same
/// approach as ccusage). Subscription plans aren't billed per token, so this
/// is the *API-equivalent value* of the usage in a window — measured from
/// this machine's transcripts.
actor ClaudeCostCalculator {
    static let shared = ClaudeCostCalculator()

    static var projectsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
    }

    struct CostEntry: Sendable {
        let dedupeKey: String
        let timestamp: Date
        let model: String
        let costDollars: Double
    }

    /// Per-token USD prices. Cache writes: 1.25x input for 5-minute TTL,
    /// 2x for 1-hour TTL; cache reads: 0.1x input.
    struct Pricing: Sendable {
        let input: Double
        let output: Double
        let cacheWrite5m: Double
        let cacheWrite1h: Double
        let cacheRead: Double

        init(inputPerMTok: Double, outputPerMTok: Double) {
            input = inputPerMTok / 1e6
            output = outputPerMTok / 1e6
            cacheWrite5m = inputPerMTok * 1.25 / 1e6
            cacheWrite1h = inputPerMTok * 2.0 / 1e6
            cacheRead = inputPerMTok * 0.1 / 1e6
        }
    }

    static func pricing(for model: String) -> Pricing? {
        let m = model.lowercased()
        // Order matters: specific older models before generic family matches.
        if m.contains("fable") || m.contains("mythos") {
            return Pricing(inputPerMTok: 10, outputPerMTok: 50)
        }
        if m.contains("opus-4-1") || m.contains("opus-4-2025") {
            return Pricing(inputPerMTok: 15, outputPerMTok: 75)
        }
        if m.contains("opus") {
            return Pricing(inputPerMTok: 5, outputPerMTok: 25)
        }
        if m.contains("sonnet") {
            return Pricing(inputPerMTok: 3, outputPerMTok: 15)
        }
        if m.contains("haiku-3") {
            return Pricing(inputPerMTok: 0.8, outputPerMTok: 4)
        }
        if m.contains("haiku") {
            return Pricing(inputPerMTok: 1, outputPerMTok: 5)
        }
        return nil // synthetic/unknown models contribute nothing
    }

    // MARK: - Transcript line decoding

    struct TranscriptLine: Decodable {
        struct Message: Decodable {
            struct Usage: Decodable {
                struct CacheCreation: Decodable {
                    let ephemeral_1h_input_tokens: Double?
                    let ephemeral_5m_input_tokens: Double?
                }
                let input_tokens: Double?
                let output_tokens: Double?
                let cache_creation_input_tokens: Double?
                let cache_read_input_tokens: Double?
                let cache_creation: CacheCreation?
            }
            let id: String?
            let model: String?
            let usage: Usage?
        }
        let type: String?
        let timestamp: String?
        let requestId: String?
        let message: Message?
    }

    static func cost(of usage: TranscriptLine.Message.Usage, pricing: Pricing) -> Double {
        var cost = (usage.input_tokens ?? 0) * pricing.input
            + (usage.output_tokens ?? 0) * pricing.output
            + (usage.cache_read_input_tokens ?? 0) * pricing.cacheRead
        if let split = usage.cache_creation {
            cost += (split.ephemeral_5m_input_tokens ?? 0) * pricing.cacheWrite5m
            cost += (split.ephemeral_1h_input_tokens ?? 0) * pricing.cacheWrite1h
        } else {
            cost += (usage.cache_creation_input_tokens ?? 0) * pricing.cacheWrite5m
        }
        return cost
    }

    static func parse(line: Data) -> CostEntry? {
        guard let parsed = try? JSONDecoder().decode(TranscriptLine.self, from: line),
              parsed.type == "assistant",
              let message = parsed.message,
              let usage = message.usage,
              let model = message.model,
              let timestamp = parsed.timestamp.flatMap(Timestamps.parseISO),
              let pricing = pricing(for: model) else { return nil }
        return CostEntry(
            dedupeKey: "\(message.id ?? "?")|\(parsed.requestId ?? "?")",
            timestamp: timestamp,
            model: model,
            costDollars: cost(of: usage, pricing: pricing))
    }

    // MARK: - File scanning with cache

    private struct FileCacheEntry {
        let mtime: Date
        let size: Int
        let entries: [CostEntry]
    }

    private var fileCache: [String: FileCacheEntry] = [:]

    /// All deduplicated cost entries newer than `oldest`, scanning only
    /// transcript files modified since then (a file untouched since the
    /// window opened cannot contain entries inside it). Streaming rewrites
    /// can repeat a message id; the last occurrence wins.
    func entries(since oldest: Date) -> [CostEntry] {
        let fileManager = FileManager.default
        var deduped: [String: CostEntry] = [:]
        var liveFiles: Set<String> = []

        let enumerator = fileManager.enumerator(
            at: Self.projectsDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles])
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "jsonl" else { continue }
            guard let values = try? url.resourceValues(
                    forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let mtime = values.contentModificationDate,
                  let size = values.fileSize,
                  mtime >= oldest else { continue }
            liveFiles.insert(url.path)

            let entries: [CostEntry]
            if let cached = fileCache[url.path], cached.mtime == mtime, cached.size == size {
                entries = cached.entries
            } else {
                entries = Self.parseFile(at: url)
                fileCache[url.path] = FileCacheEntry(mtime: mtime, size: size, entries: entries)
            }
            for entry in entries where entry.timestamp >= oldest {
                deduped[entry.dedupeKey] = entry
            }
        }

        // Drop cache for files that aged out of every window.
        fileCache = fileCache.filter { liveFiles.contains($0.key) }
        return Array(deduped.values)
    }

    private static func parseFile(at url: URL) -> [CostEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let marker = Data("\"assistant\"".utf8)
        var entries: [CostEntry] = []
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard line.range(of: marker) != nil else { continue }
            if let entry = parse(line: Data(line)) {
                entries.append(entry)
            }
        }
        return entries
    }

    // MARK: - Window sums

    /// Sums entry costs inside a window, optionally restricted to models
    /// whose id contains `modelSubstring` (e.g. "fable" for the Fable cap).
    static func sum(_ entries: [CostEntry], since start: Date,
                    modelSubstring: String? = nil) -> Double {
        entries.reduce(0) { total, entry in
            guard entry.timestamp >= start else { return total }
            if let filter = modelSubstring,
               !entry.model.lowercased().contains(filter) { return total }
            return total + entry.costDollars
        }
    }
}
