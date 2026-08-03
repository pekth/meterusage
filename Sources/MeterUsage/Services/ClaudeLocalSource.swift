import Foundation

// MARK: - ClaudeLocalSource
//
// Computes local Claude Code usage analytics by scanning transcript files
// under `~/.claude/projects/<encoded-project-dir>/<session-uuid>.jsonl`.
// This type never touches the network — it only reads files the user
// already owns on their own disk.
//
// TRANSCRIPT SCHEMA (verified against real files on 2026-07-31, Claude Code
// CLI 2.1.201; not officially documented and may drift between versions):
//
//   Each `.jsonl` file is one session. Lines are heterogeneous JSON objects
//   sharing a top-level "type" discriminator, e.g. "user", "assistant",
//   "attachment", "mode", "permission-mode", "last-prompt", "ai-title",
//   "system", "queue-operation", "file-history-snapshot", "pr-link", ...
//   Only "assistant" lines carry token usage. The relevant shape is:
//
//   {
//     "type": "assistant",
//     "timestamp": "2026-07-05T07:08:04.242Z",
//     "message": {
//       "model": "claude-opus-4-8",
//       "usage": {
//         "input_tokens": 51077,
//         "output_tokens": 128,
//         "cache_read_input_tokens": 11434,
//         "cache_creation_input_tokens": 23352,
//         ... (server_tool_use, service_tier, cache_creation, iterations —
//         all ignored; not needed for token/cost accounting)
//       }
//     },
//     ...
//   }
//
//   `model` strings seen in the wild include full dated ids
//   ("claude-opus-4-8", "claude-haiku-4-5-20251001"), bare aliases
//   ("opus", "sonnet", "haiku", "fable"), and internal markers
//   ("<synthetic>"). `Pricing.rate(forModel:)` matches substrings and
//   flags anything it doesn't recognise rather than guessing silently.
//
//   The file is append-only while a session is active, so the final line
//   can be truncated mid-write if a scan races a live session. Every line
//   is parsed independently and unparseable lines are skipped — one bad
//   line never fails the whole file or the whole scan.
//
// PERFORMANCE (measured against a real 1.4 GB / 2227-file corpus,
// 2026-07-31): a naive chunked-read-plus-front-buffer-drain implementation
// took 150s+ — pathological, not inherent to the corpus size (raw I/O over
// the same corpus is ~1.3s; JSON-decoding a representative sample
// extrapolates to ~6s for the whole thing). Three fixes get real-world
// wall clock in line with that budget:
//   1. Memory-map each file and slice line ranges by index instead of
//      chunk-reading into a `Data` buffer and calling `removeSubrange` on
//      the front after every line. That drain is a full memmove of
//      whatever's left in the buffer, on every single line — O(n^2) over a
//      file's line count, and it dominated the 150s.
//   2. Reuse one `JSONDecoder` per file (originally per scan overall — see
//      below) instead of allocating one per line.
//   3. Byte-level prefilter (`containsUsageMarkers`) rejects the ~85% of
//      lines that can't possibly be assistant/usage lines before paying
//      for a JSON decode at all.
public actor ClaudeLocalSource: LocalActivitySource {

    public nonisolated let provider: Provider = .claude

    /// Root directory to scan. Defaults to the real `~/.claude/projects`,
    /// but is injectable so tests can point at a fixture tree instead of
    /// the user's actual home directory.
    private let root: URL
    private let fileManager: FileManager

    /// Where the on-disk scan cache is persisted. Injectable so tests never
    /// touch the user's real Application Support directory.
    private let cacheFileURL: URL

    /// Per-file parse cache, keyed by a non-reversible hash of the file's
    /// absolute path (never the path itself — see `Privacy.opaqueID`).
    /// Loaded from `cacheFileURL` on first use and persisted back at the
    /// end of a scan that changed it, so the *second* app launch (and every
    /// one after, as long as transcripts don't change) is a stat-only pass
    /// instead of a full re-read of potentially gigabytes of transcripts.
    private var diskCache: [String: DiskCacheEntry] = [:]
    private var diskCacheLoaded = false
    private var diskCacheDirty = false

    public init(root: URL? = nil, fileManager: FileManager = .default, cacheFileURL: URL? = nil) {
        self.root = root ?? HomeDirectory.real.appendingPathComponent(".claude/projects", isDirectory: true)
        self.fileManager = fileManager
        self.cacheFileURL = cacheFileURL ?? Self.defaultCacheFileURL
    }

    private static var defaultCacheFileURL: URL {
        HomeDirectory.real
            .appendingPathComponent("Library/Application Support/MeterUsage", isDirectory: true)
            .appendingPathComponent("claude-local-scan-cache.json")
    }

    public func scan() async throws -> LocalActivity {
        loadDiskCacheIfNeeded()

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw SourceUnavailable.noData
        }

        let projectDirs = (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil))?
            .filter { $0.hasDirectoryPath } ?? []

        var sessions: [SessionSummary] = []
        // Day (UTC midnight) -> running totals. Grouping by UTC rather than
        // the host's local calendar keeps the heatmap deterministic and
        // matches the "Z"-suffixed timestamps stored in the transcripts, so
        // tests don't depend on the machine's time zone.
        var dayTotals: [Date: DayAccumulator] = [:]

        for projectDir in projectDirs {
            let projectRawName = projectDir.lastPathComponent
            let projectName = Privacy.projectName(fromEncodedPath: projectRawName)

            let sessionFiles = (try? fileManager.contentsOfDirectory(at: projectDir, includingPropertiesForKeys: nil))?
                .filter { $0.pathExtension == "jsonl" } ?? []

            for fileURL in sessionFiles {
                guard let stat = fileStat(fileURL) else { continue }
                let pathHash = Privacy.opaqueID(fileURL.path)

                let parsed: FileParseResult
                if let cached = diskCache[pathHash], cached.mtime == stat.mtime, cached.size == stat.size {
                    parsed = cached.result
                } else {
                    parsed = Self.parse(fileURL: fileURL)
                    diskCache[pathHash] = DiskCacheEntry(mtime: stat.mtime, size: stat.size, result: parsed)
                    diskCacheDirty = true
                }

                guard parsed.messageCount > 0 else { continue }

                let rawSessionID = fileURL.deletingPathExtension().lastPathComponent
                sessions.append(
                    SessionSummary(
                        id: Privacy.opaqueID(rawSessionID),
                        projectName: projectName,
                        model: parsed.model ?? "unknown",
                        tokens: parsed.tokens,
                        estimatedCostUSD: parsed.totalCostUSD,
                        startedAt: parsed.earliestTimestamp ?? .distantPast,
                        messageCount: parsed.messageCount
                    )
                )

                for (day, bucket) in parsed.dailyBuckets {
                    var running = dayTotals[day] ?? DayAccumulator()
                    running.tokens = running.tokens + bucket.tokens
                    running.costUSD += bucket.costUSD
                    running.sessionCount += 1 // one file == one session touching this day
                    dayTotals[day] = running
                }
            }
        }

        persistDiskCacheIfNeeded()

        guard !sessions.isEmpty else {
            throw SourceUnavailable.noData
        }

        let daily = dayTotals
            .map { day, acc in
                DailyActivity(day: day, tokens: acc.tokens, estimatedCostUSD: acc.costUSD, sessionCount: acc.sessionCount)
            }
            .sorted { $0.day < $1.day }

        return LocalActivity(
            provider: .claude,
            sessions: sessions.sorted { $0.startedAt < $1.startedAt },
            daily: daily,
            scannedAt: Date()
        )
    }

    private func fileStat(_ url: URL) -> (mtime: TimeInterval, size: Int64)? {
        guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
              let mtime = attrs[.modificationDate] as? Date
        else { return nil }
        // `.size` comes back as NSNumber via the Any-typed attributes dict;
        // go through NSNumber explicitly rather than `as? Int64`, which is
        // not guaranteed to bridge cleanly from an untyped Any box.
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        return (mtime.timeIntervalSince1970, size)
    }

    // MARK: - Disk cache (persists across app launches)

    private func loadDiskCacheIfNeeded() {
        guard !diskCacheLoaded else { return }
        diskCacheLoaded = true
        // Missing file (first-ever launch) and corrupt/unreadable file
        // (partial write, format change, disk error) both fall through to
        // "start empty" — a bad cache must degrade to a full re-scan, never
        // to a thrown error. `diskCache` is already `[:]`, so there's
        // nothing else to do in either case.
        guard let data = try? Data(contentsOf: cacheFileURL),
              let decoded = try? JSONDecoder().decode([String: DiskCacheEntry].self, from: data)
        else { return }
        diskCache = decoded
    }

    private func persistDiskCacheIfNeeded() {
        guard diskCacheDirty else { return }
        // Best-effort: a failed cache write just means the next launch
        // re-scans from cold, which is correct-but-slow, never wrong.
        try? fileManager.createDirectory(
            at: cacheFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let data = try? JSONEncoder().encode(diskCache) else { return }
        try? data.write(to: cacheFileURL, options: .atomic)
        diskCacheDirty = false
    }

    /// On-disk representation of one file's parse result. Keyed externally
    /// by `Privacy.opaqueID(path)` — this struct itself never stores the
    /// path, so the cache file on disk carries no absolute path and no OS
    /// username, matching the same privacy contract as the in-app models.
    fileprivate struct DiskCacheEntry: Codable {
        let mtime: TimeInterval
        let size: Int64
        let result: FileParseResult
    }

    // MARK: - Per-file parse

    fileprivate struct DayAccumulator {
        var tokens = TokenTotals()
        var costUSD: Double = 0
        var sessionCount: Int = 0
    }

    /// `Codable` so it can round-trip through the disk cache. `Date` keys
    /// in `dailyBuckets` are bridged to/from epoch seconds for encoding —
    /// see `CodingKeys`/`init(from:)`/`encode(to:)`.
    fileprivate struct FileParseResult: Codable {
        var tokens = TokenTotals()
        var totalCostUSD: Double = 0
        var messageCount = 0
        /// Model of the most recently seen assistant message in the file.
        /// Sessions can switch models mid-conversation; this favours the
        /// model most representative of how the session ended, which is
        /// what a user glancing at a session list would expect to see.
        var model: String?
        var earliestTimestamp: Date?
        var dailyBuckets: [Date: DayBucket] = [:]

        init(
            tokens: TokenTotals = TokenTotals(),
            totalCostUSD: Double = 0,
            messageCount: Int = 0,
            model: String? = nil,
            earliestTimestamp: Date? = nil,
            dailyBuckets: [Date: DayBucket] = [:]
        ) {
            self.tokens = tokens
            self.totalCostUSD = totalCostUSD
            self.messageCount = messageCount
            self.model = model
            self.earliestTimestamp = earliestTimestamp
            self.dailyBuckets = dailyBuckets
        }

        private enum CodingKeys: String, CodingKey {
            case tokens, totalCostUSD, messageCount, model, earliestTimestamp, dailyBuckets
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            tokens = try c.decode(TokenTotals.self, forKey: .tokens)
            totalCostUSD = try c.decode(Double.self, forKey: .totalCostUSD)
            messageCount = try c.decode(Int.self, forKey: .messageCount)
            model = try c.decodeIfPresent(String.self, forKey: .model)
            let earliestEpoch = try c.decodeIfPresent(TimeInterval.self, forKey: .earliestTimestamp)
            earliestTimestamp = earliestEpoch.map(Date.init(timeIntervalSince1970:))
            let bucketPairs = try c.decode([DayBucketEntry].self, forKey: .dailyBuckets)
            dailyBuckets = Dictionary(uniqueKeysWithValues: bucketPairs.map {
                (Date(timeIntervalSince1970: $0.dayEpoch), $0.bucket)
            })
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(tokens, forKey: .tokens)
            try c.encode(totalCostUSD, forKey: .totalCostUSD)
            try c.encode(messageCount, forKey: .messageCount)
            try c.encodeIfPresent(model, forKey: .model)
            try c.encodeIfPresent(earliestTimestamp?.timeIntervalSince1970, forKey: .earliestTimestamp)
            let bucketPairs = dailyBuckets.map { DayBucketEntry(dayEpoch: $0.key.timeIntervalSince1970, bucket: $0.value) }
            try c.encode(bucketPairs, forKey: .dailyBuckets)
        }
    }

    fileprivate struct DayBucketEntry: Codable {
        let dayEpoch: TimeInterval
        let bucket: DayBucket
    }

    fileprivate struct DayBucket: Codable {
        var tokens = TokenTotals()
        var costUSD: Double = 0
    }

    private static let utcCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    private static let isoFormatterFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoFormatterWhole: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func parseTimestamp(_ raw: String) -> Date? {
        isoFormatterFractional.date(from: raw) ?? isoFormatterWhole.date(from: raw)
    }

    // Byte patterns for the cheap prefilter in `containsUsageMarkers`.
    // Matching the quoted JSON key/value tokens (not bare "usage"/
    // "assistant") avoids false positives from prose that happens to
    // contain those words without being the field we care about.
    private static let usageMarker = Data("\"usage\"".utf8)
    private static let assistantMarker = Data("\"assistant\"".utf8)

    /// Cheap reject-fast check run before paying for a JSON decode. Real
    /// corpora are ~15% assistant/usage lines, so skipping the other ~85%
    /// here is most of the win described in the performance note above.
    /// Order-independent by design — key order in JSON is not guaranteed,
    /// and a real observed line puts `"usage"` before `"type":"assistant"`
    /// (nested inside `message` first) — so this checks presence, not
    /// sequence.
    private static func containsUsageMarkers(_ data: Data) -> Bool {
        data.range(of: usageMarker) != nil && data.range(of: assistantMarker) != nil
    }

    /// Parses one `.jsonl` transcript into a `FileParseResult`.
    ///
    /// Memory-maps the file (`.mappedIfSafe`) instead of chunk-reading into
    /// a growable buffer: slicing a mapped `Data` by index range is O(1)
    /// (shared storage, no copy), so splitting on newlines this way is
    /// linear in file size overall — each byte is visited a small constant
    /// number of times, never re-scanned from the top of a shrinking
    /// buffer. This also keeps the original memory guarantee (nothing
    /// spikes on a multi-hundred-MB transcript): the OS pages the mapped
    /// region in on demand rather than the process holding it all resident
    /// at once.
    fileprivate static func parse(fileURL: URL) -> FileParseResult {
        var result = FileParseResult()

        guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else {
            return result
        }

        // One decoder for the whole file (previously one per line, which
        // was pure allocation overhead multiplied by line count).
        let decoder = JSONDecoder()

        let newline: UInt8 = 0x0A
        var start = data.startIndex
        let end = data.endIndex

        while start < end {
            // `firstIndex(of:)` only scans the *remaining* slice
            // (`start..<end`), not the whole file, each time — since
            // `start` advances past each line as it's consumed, total work
            // across the loop is O(n) in file size, not O(n^2).
            let newlineIndex = data[start..<end].firstIndex(of: newline) ?? end
            // Index-range slicing shares the mapped storage rather than
            // copying, so this is cheap even for very long lines.
            let line = data[start..<newlineIndex]
            process(line, into: &result, decoder: decoder)
            start = newlineIndex < end ? data.index(after: newlineIndex) : end
        }

        return result
    }

    private static func process(_ lineData: Data, into result: inout FileParseResult, decoder: JSONDecoder) {
        guard !lineData.isEmpty else { return }
        // Reject-fast before decoding: ~85% of lines can't be assistant/
        // usage lines at all, and a byte-level substring scan is far
        // cheaper than constructing a JSON object graph just to discard it.
        guard containsUsageMarkers(lineData) else { return }
        // Defensive: skip anything that isn't valid JSON, isn't an object,
        // isn't an assistant/usage line, or has a schema we don't
        // recognise. Any of these is expected noise (including a
        // truncated final line from a live session), never a scan failure.
        guard let line = try? decoder.decode(TranscriptLine.self, from: lineData) else { return }
        guard line.type == "assistant", let message = line.message, let usage = message.usage else { return }

        let tokens = TokenTotals(
            input: usage.input_tokens ?? 0,
            output: usage.output_tokens ?? 0,
            cacheRead: usage.cache_read_input_tokens ?? 0,
            cacheWrite: usage.cache_creation_input_tokens ?? 0
        )
        let model = message.model ?? "unknown"
        let cost = Pricing.estimate(model: model, tokens: tokens).costUSD

        result.tokens = result.tokens + tokens
        result.totalCostUSD += cost
        result.messageCount += 1
        result.model = model

        let timestamp = line.timestamp.flatMap(parseTimestamp)
        if let timestamp {
            if result.earliestTimestamp == nil || timestamp < result.earliestTimestamp! {
                result.earliestTimestamp = timestamp
            }
            let day = utcCalendar.startOfDay(for: timestamp)
            var bucket = result.dailyBuckets[day] ?? DayBucket()
            bucket.tokens = bucket.tokens + tokens
            bucket.costUSD += cost
            result.dailyBuckets[day] = bucket
        }
    }

    // MARK: - Wire types
    //
    // Deliberately minimal and fully Optional: we only decode the fields we
    // need, so unrelated line types (which don't have "message"/"usage" at
    // all) decode fine with those fields as nil and get skipped by `process`
    // rather than throwing.

    private struct TranscriptLine: Decodable {
        let type: String?
        let timestamp: String?
        let message: TranscriptMessage?
    }

    private struct TranscriptMessage: Decodable {
        let model: String?
        let usage: TranscriptUsage?
    }

    private struct TranscriptUsage: Decodable {
        let input_tokens: Int?
        let output_tokens: Int?
        let cache_read_input_tokens: Int?
        let cache_creation_input_tokens: Int?
    }
}

extension TokenTotals: Codable {
    private enum CodingKeys: String, CodingKey {
        case input, output, reasoning, cacheRead, cacheWrite
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            input: try c.decode(Int.self, forKey: .input),
            output: try c.decode(Int.self, forKey: .output),
            reasoning: try c.decodeIfPresent(Int.self, forKey: .reasoning) ?? 0,
            cacheRead: try c.decode(Int.self, forKey: .cacheRead),
            cacheWrite: try c.decode(Int.self, forKey: .cacheWrite)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(input, forKey: .input)
        try c.encode(output, forKey: .output)
        try c.encode(reasoning, forKey: .reasoning)
        try c.encode(cacheRead, forKey: .cacheRead)
        try c.encode(cacheWrite, forKey: .cacheWrite)
    }
}

private extension URL {
    var hasDirectoryPath: Bool {
        (try? resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }
}
