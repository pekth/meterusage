import Foundation

// MARK: - CodexLocalSource
//
// Counts Codex sessions and tokens per day from the local session store, for
// the weekly heatmap and the unified "AI coding today" strip. Codex persists
// one rollout file per session under `~/.codex/sessions/**/*.jsonl`.
//
// Codex exposes no stable per-session token ledger on disk beyond the rollout
// files themselves, so this source reads the minimum it needs: the first line
// of each rollout (the `session_meta` event, carrying the start timestamp and
// working directory) and the tail of the file (the last `token_count` event,
// whose `total_token_usage` is the session's cumulative ledger). Nothing else
// in the payloads is read — no prompts, no tool output.
public actor CodexLocalSource: LocalActivitySource {

    public nonisolated let provider: Provider = .codex

    private let root: URL
    private let fileManager: FileManager

    public init(root: URL? = nil, fileManager: FileManager = .default) {
        self.root = root ?? HomeDirectory.real
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        self.fileManager = fileManager
    }

    public func scan() async throws -> LocalActivity {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw SourceUnavailable.noData
        }

        // Day (UTC midnight) -> session count and token totals. Grouping by
        // UTC keeps the heatmap deterministic and matches the "Z"-suffixed
        // timestamps in the rollout files, so tests do not depend on the
        // machine's zone.
        var dayCounts: [Date: Int] = [:]
        var dayTokens: [Date: TokenTotals] = [:]
        var sessions: [SessionSummary] = []

        for url in Self.sessionFiles(in: root, fileManager: fileManager) {
            let start = Self.sessionStart(for: url, fileManager: fileManager)
            guard let startedAt = start?.date ?? Self.modificationDate(for: url, fileManager: fileManager) else {
                continue
            }
            let usage = Self.lastTokenUsage(for: url)

            let day = Self.utcCalendar.startOfDay(for: startedAt)
            dayCounts[day, default: 0] += 1
            if let usage {
                dayTokens[day, default: TokenTotals()] = (dayTokens[day] ?? TokenTotals()) + usage
            }

            sessions.append(
                SessionSummary(
                    id: Privacy.opaqueID(url.path),
                    projectName: start?.project ?? "",
                    model: "codex",
                    tokens: usage ?? TokenTotals(),
                    estimatedCostUSD: 0,
                    startedAt: startedAt,
                    messageCount: 0
                )
            )
        }

        guard !dayCounts.isEmpty else {
            throw SourceUnavailable.noData
        }

        let daily = dayCounts
            .map { day, count in
                DailyActivity(
                    day: day,
                    tokens: dayTokens[day] ?? TokenTotals(),
                    estimatedCostUSD: 0,
                    sessionCount: count
                )
            }
            .sorted { $0.day < $1.day }

        let now = Date()
        let items = sessions.map {
            TelemetrySessionItem(
                startedAt: $0.startedAt,
                tokens: $0.tokens.total,
                messageCount: $0.messageCount
            )
        }
        let telemetry = TelemetryCalculator.calculate(
            sessions: items,
            daily: daily,
            now: now
        )

        return LocalActivity(
            provider: .codex,
            sessions: sessions.sorted { $0.startedAt < $1.startedAt },
            daily: daily,
            scannedAt: now,
            telemetry: telemetry
        )
    }

    // MARK: - Session discovery

    private static func sessionFiles(in root: URL, fileManager: FileManager) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return enumerator.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "jsonl" }
    }

    /// The UTC day a session belongs to: the start timestamp on the rollout's
    /// first event, or the file's modification date when that cannot be read.
    static func sessionDay(for url: URL, fileManager: FileManager = .default) -> Date? {
        guard let date = sessionStart(for: url, fileManager: fileManager)?.date
            ?? modificationDate(for: url, fileManager: fileManager) else {
            return nil
        }
        return utcCalendar.startOfDay(for: date)
    }

    private struct SessionStart {
        let date: Date
        /// Last path component of the session's working directory — the same
        /// directory-basename-only identifier the Claude source reports.
        let project: String
    }

    /// Reads only the first line of a rollout file and takes its top-level
    /// `timestamp` (the `session_meta` event) plus the working directory's
    /// basename. The rest of the file is never opened here, so a
    /// multi-hundred-MB session costs one bounded read.
    private static func sessionStart(for url: URL, fileManager: FileManager) -> SessionStart? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let chunk = handle.readData(ofLength: 64 * 1024)
        guard let newline = chunk.firstIndex(of: 0x0A),
              let object = try? JSONSerialization.jsonObject(with: chunk[..<newline]) as? [String: Any],
              let raw = object["timestamp"] as? String,
              let date = parseTimestamp(raw) else { return nil }
        let project = (object["payload"] as? [String: Any])
            .flatMap { $0["cwd"] as? String }
            .map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
        return SessionStart(date: date, project: project)
    }

    // MARK: - Token ledger

    /// Extracts the session's cumulative token ledger from the LAST
    /// `token_count` event in the rollout. Those events appear throughout the
    /// file and the events after the final one can be large (tool output), so
    /// the search reads backward from the end of the file in 1 MB chunks,
    /// giving up after 16 MB. A session whose ledger cannot be found within
    /// that budget reports no tokens rather than a wrong partial number.
    static func lastTokenUsage(for url: URL) -> TokenTotals? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let fileSize = Int((try? handle.seekToEnd()) ?? 0)
        let chunkSize = 1 << 20
        let budget = 16 * chunkSize
        var remaining = fileSize
        var spent = 0
        // Bytes carried from the previous (later) chunk whose first line was
        // cut mid-line, prepended to the next earlier chunk to complete it.
        var pendingHead = Data()

        while remaining > 0, spent < budget {
            let length = min(chunkSize, remaining)
            let offset = remaining - length
            try? handle.seek(toOffset: UInt64(offset))
            var buffer = handle.readData(ofLength: length) ?? Data()
            remaining = offset
            spent += length
            if !pendingHead.isEmpty {
                buffer.append(pendingHead)
            }

            // The buffer's first line may be partial (cut at the chunk
            // boundary). Everything after the first newline is complete.
            guard let firstNewline = buffer.firstIndex(of: 0x0A) else {
                pendingHead = buffer
                continue
            }
            pendingHead = Data(buffer[..<firstNewline])
            let body = buffer[buffer.index(after: firstNewline)...]

            for line in body.split(separator: 0x0A, omittingEmptySubsequences: true).reversed() {
                guard line.range(of: Data("\"total_token_usage\"".utf8)) != nil,
                      let totals = parseTokenCountLine(Data(line)) else { continue }
                return totals
            }
        }
        return nil
    }

    /// Parses one `token_count` event line into a `TokenTotals`.
    ///
    /// Codex's `total_token_usage` counts cached input inside `input_tokens`
    /// and reasoning inside `output_tokens`, while `TokenTotals.total` is the
    /// plain sum of its fields. The cached and reasoning portions are moved
    /// into their own fields so the sum stays equal to Codex's own total.
    static func parseTokenCountLine(_ data: Data) -> TokenTotals? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "event_msg",
              let payload = object["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any],
              let usage = info["total_token_usage"] as? [String: Any] else { return nil }

        let input = Self.number(usage["input_tokens"])
        let cached = Self.number(usage["cached_input_tokens"])
        let output = Self.number(usage["output_tokens"])
        let reasoning = Self.number(usage["reasoning_output_tokens"])
        guard input > 0 || output > 0 else { return nil }

        return TokenTotals(
            input: max(0, input - cached),
            output: max(0, output - reasoning),
            reasoning: reasoning,
            cacheRead: cached
        )
    }

    private static func number(_ any: Any?) -> Int {
        (any as? NSNumber)?.intValue ?? 0
    }

    private static func modificationDate(for url: URL, fileManager: FileManager) -> Date? {
        guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
              let date = attrs[.modificationDate] as? Date else { return nil }
        return date
    }

    private static let utcCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return cal
    }()

    private static func parseTimestamp(_ raw: String) -> Date? {
        if let d = isoFractional.date(from: raw) { return d }
        return isoPlain.date(from: raw)
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fmt
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        return fmt
    }()
}
