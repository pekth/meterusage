import Foundation

// MARK: - CodexLocalSource
//
// Counts Codex sessions and tokens per day from the local session store, for
// the weekly heatmap and the unified "AI coding today" strip, and estimates
// each session's cost from its model and tokens. Codex persists one rollout
// file per session under `~/.codex/sessions/**/*.jsonl`.
//
// Codex exposes no stable per-session token ledger on disk beyond the rollout
// files themselves, so this source reads the minimum it needs: the first line
// of each rollout (the `session_meta` event, carrying the start timestamp and
// working directory), the tail of the file (the last `token_count` event,
// whose `total_token_usage` is the session's cumulative ledger), and the model
// named by the nearest `turn_context` event. Nothing else in the payloads is
// read — no prompts, no tool output.
public actor CodexLocalSource: LocalActivitySource {

    public nonisolated let slot: ProviderSlot
    public nonisolated var provider: Provider { slot.provider }

    private let root: URL
    private let fileManager: FileManager

    /// One Codex account slot. The default scans the primary account's
    /// rollout store under the real home; an additional-account instance
    /// passes the account's slot and a `root` under its own Codex home (see
    /// `ManagedAccount`), so only that login's sessions are counted. The
    /// rollout format is identical across accounts — only the directory
    /// differs.
    public init(slot: ProviderSlot = .primary(.codex), root: URL? = nil, fileManager: FileManager = .default) {
        self.slot = slot
        self.root = root ?? HomeDirectory.real
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        self.fileManager = fileManager
    }

    var diagnosticFiles: [DiagnosticsReport.FileObservation] {
        [.inspect(root, role: .sessions, fileManager: fileManager)]
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
        var dayCosts: [Date: Double] = [:]
        var sessions: [SessionSummary] = []

        for url in Self.sessionFiles(in: root, fileManager: fileManager) {
            let start = Self.sessionStart(for: url, fileManager: fileManager)
            let modified = Self.modificationDate(for: url, fileManager: fileManager)
            guard let startedAt = start?.date ?? modified else {
                continue
            }
            let ledger = Self.lastTokenLedger(for: url)
            let tokens = ledger?.tokens ?? TokenTotals()
            // Codex reports no USD ledger, so cost is estimated from the
            // session's own tokens against `Pricing`, using the model of the
            // session's last turn (read from the rollout). A session whose
            // model can't be read falls back to "codex", which `Pricing`
            // treats as an unrecognised Codex id and prices, flagged, at the
            // current default tier — never silently at zero.
            let model = ledger?.model ?? "codex"
            let cost = Pricing.estimate(model: model, tokens: tokens).costUSD

            let day = Self.utcCalendar.startOfDay(for: startedAt)
            dayCounts[day, default: 0] += 1
            if tokens.total > 0 {
                dayTokens[day, default: TokenTotals()] = (dayTokens[day] ?? TokenTotals()) + tokens
                dayCosts[day, default: 0] += cost
            }

            sessions.append(
                SessionSummary(
                    id: Privacy.opaqueID(url.path),
                    projectName: start?.project ?? "",
                    model: model,
                    tokens: tokens,
                    estimatedCostUSD: cost,
                    startedAt: startedAt,
                    lastActivityAt: modified,
                    messageCount: 0,
                    isAutomation: start?.isAutomation ?? false
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
                    estimatedCostUSD: dayCosts[day] ?? 0,
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
            provider: slot.provider,
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
        /// True when the rollout's `session_meta` marks it a scheduled run
        /// (`thread_source == "automation"`). Those sessions execute in
        /// per-thread folders instead of a repo, so attribution skips them
        /// and the card names the repos the user actually worked in.
        let isAutomation: Bool
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
        let payload = object["payload"] as? [String: Any]
        let project = payload
            .flatMap { $0["cwd"] as? String }
            .map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
        let isAutomation = (payload?["thread_source"] as? String) == "automation"
        return SessionStart(date: date, project: project, isAutomation: isAutomation)
    }

    // MARK: - Token ledger

    /// A session's cumulative token ledger plus the model its last turn ran on.
    /// The model is `nil` when the rollout has no readable `turn_context`
    /// within the backward-read budget.
    struct TokenLedger: Equatable {
        let tokens: TokenTotals
        var model: String?
    }

    private static let totalUsageMarker = Data("\"total_token_usage\"".utf8)
    private static let turnContextMarker = Data("turn_context".utf8)

    /// Token totals only, for callers that don't care about the model.
    static func lastTokenUsage(for url: URL) -> TokenTotals? {
        lastTokenLedger(for: url)?.tokens
    }

    /// Extracts the session's cumulative token ledger from the LAST
    /// `token_count` event in the rollout, plus the model from the nearest
    /// preceding `turn_context` event. Those events appear throughout the
    /// file and the events after the final ledger can be large (tool output),
    /// so the search reads backward from the end of the file in 1 MB chunks,
    /// giving up after 16 MB. A session whose ledger cannot be found within
    /// that budget reports no tokens rather than a wrong partial number; a
    /// session whose model can't be found still reports its tokens, with a
    /// `nil` model.
    static func lastTokenLedger(for url: URL) -> TokenLedger? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let fileSize = Int((try? handle.seekToEnd()) ?? 0)
        let chunkSize = 1 << 20
        let budget = 16 * chunkSize
        // Once the ledger is found, the model is usually in the same chunk or
        // the one just before it. Cap how much further back we will read for
        // it, so a session with a huge final turn can't turn the model hunt
        // into a second full-file search; a session whose model lies beyond
        // this reports its tokens with a nil model instead.
        let modelSearchBudget = 4 * chunkSize
        var modelSearchSpent = 0
        var remaining = fileSize
        var spent = 0
        // Bytes carried from the previous (later) chunk whose first line was
        // cut mid-line, prepended to the next earlier chunk to complete it.
        var pendingHead = Data()
        var ledger: TokenLedger?

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
                if ledger == nil {
                    // The latest `token_count` line wins; once found, keep
                    // scanning earlier lines for the turn's model.
                    if line.range(of: totalUsageMarker) != nil,
                       let totals = parseTokenCountLine(Data(line)) {
                        ledger = TokenLedger(tokens: totals, model: nil)
                    }
                    continue
                }
                if ledger?.model == nil, let model = parseTurnContextModel(Data(line)) {
                    ledger?.model = model
                    break
                }
            }
            if let complete = ledger, complete.model != nil { return complete }
            if ledger != nil {
                modelSearchSpent += length
                if modelSearchSpent >= modelSearchBudget { return ledger }
            }
        }
        return ledger
    }

    /// Reads the model from one `turn_context` event line. Codex writes the
    /// active model there (not in `session_meta` or `token_count`), so this is
    /// the only place a session's model is recorded on disk. Returns nil for
    /// any other line, including a `turn_context` with no model.
    static func parseTurnContextModel(_ data: Data) -> String? {
        guard data.range(of: turnContextMarker) != nil,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "turn_context",
              let payload = object["payload"] as? [String: Any],
              let model = payload["model"] as? String,
              !model.isEmpty else { return nil }
        return model
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
