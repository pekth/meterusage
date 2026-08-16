import Foundation

// MARK: - Antigravity

/// Reads Antigravity (agy) session and message counts.
///
/// agy persists one JSON line per prompt to `history.jsonl` under its data
/// directory. A native install keeps that at `~/.gemini/antigravity-cli/`, while
/// containerised setups (e.g. the antigravity-docker wrapper) keep it inside the
/// `antigravity-config` volume, which the host reaches through the container
/// runtime. Only the `conversationId` and `timestamp` fields of each line are
/// used; prompt text and workspace paths are never read.
///
/// Antigravity keeps session and message history, but not input/output token
/// counts. This source therefore reports activity counts only and never turns
/// a missing token total into a fabricated zero-cost estimate.
public struct AntigravityUsageSource: UsageSource {
    public let provider: Provider = .antigravity
    private let historyURL: URL

    public init(historyURL: URL? = nil) {
        self.historyURL = historyURL ?? HomeDirectory.real
            .appendingPathComponent(".gemini", isDirectory: true)
            .appendingPathComponent("antigravity-cli", isDirectory: true)
            .appendingPathComponent("history.jsonl")
    }

    public func fetchUsage() async throws -> ProviderUsage {
        // 1. A native agy install keeps its history directly on the host.
        if let data = try? Data(contentsOf: historyURL),
           let usage = try? Self.parseHistory(data: data, now: Date()) {
            return usage
        }
        // 2. Containerised agy keeps the same file inside the
        //    `antigravity-config` volume, reachable through the runtime.
        if let historyData = Self.readContainerHistory(),
           let usage = try? Self.parseHistory(data: historyData, now: Date()) {
            return usage
        }
        throw SourceUnavailable.dataNotFound("Antigravity usage")
    }

    static func parse(data: Data, now: Date) throws -> ProviderUsage {
        let object = try JSONSerialization.jsonObject(with: data)
        let root = object as? [String: Any] ?? [:]
        let records = Self.sessionRecords(from: root)

        if !records.isEmpty {
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: now)
            let todayRecords = records.filter { record in
                guard let startedAt = record.startedAt else { return false }
                return startedAt >= today
            }
            return ProviderUsage(
                provider: .antigravity,
                sessionCount: records.count,
                messageCount: records.reduce(0) { $0 + $1.messages },
                todaySessionCount: todayRecords.count,
                todayMessageCount: todayRecords.reduce(0) { $0 + $1.messages },
                capturedAt: Self.date(from: root["updated_at"] ?? root["updatedAt"]) ?? now
            )
        }

        let today = root["today"] as? [String: Any]
        let totalSessions = Self.int(
            root["total_sessions"]
                ?? root["totalSessions"]
                ?? root["session_count"]
                ?? root["sessionCount"]
                ?? root["sessions"]
        )
        let totalMessages = Self.int(
            root["total_messages"]
                ?? root["totalMessages"]
                ?? root["message_count"]
                ?? root["messageCount"]
                ?? root["messages"]
        )
        guard totalSessions > 0 || totalMessages > 0 else {
            throw SourceUnavailable.noData
        }
        let todaySessions = Self.int(
            root["today_sessions"]
                ?? root["todaySessions"]
                ?? today?["sessions"]
                ?? today?["session_count"]
        )
        let todayMessages = Self.int(
            root["today_messages"]
                ?? root["todayMessages"]
                ?? today?["messages"]
                ?? today?["message_count"]
        )
        return ProviderUsage(
            provider: .antigravity,
            sessionCount: totalSessions,
            messageCount: totalMessages,
            todaySessionCount: todaySessions,
            todayMessageCount: todayMessages,
            capturedAt: Self.date(from: root["updated_at"] ?? root["updatedAt"]) ?? now
        )
    }

    private struct SessionRecord {
        let startedAt: Date?
        let messages: Int
    }

    private static func sessionRecords(from root: [String: Any]) -> [SessionRecord] {
        let rawSessions = root["sessions"]
        var records: [SessionRecord] = []

        if let array = rawSessions as? [Any] {
            for (index, raw) in array.enumerated() {
                guard let record = record(from: raw, fallbackID: String(index)) else { continue }
                records.append(record)
            }
        } else if let dictionary = rawSessions as? [String: Any] {
            for (id, raw) in dictionary {
                guard let record = record(from: raw, fallbackID: id) else { continue }
                records.append(record)
            }
        }
        return records
    }

    private static func record(from raw: Any, fallbackID: String) -> SessionRecord? {
        guard let dictionary = raw as? [String: Any] else { return nil }
        let dateValue = dictionary["started_at"]
            ?? dictionary["startedAt"]
            ?? dictionary["timestamp"]
            ?? dictionary["created_at"]
            ?? dictionary["createdAt"]
        let messages = int(
            dictionary["messages"]
                ?? dictionary["message_count"]
                ?? dictionary["messageCount"]
                ?? dictionary["num_messages"]
                ?? dictionary["num_chat_messages"]
        )
        _ = fallbackID // The source never exposes a raw conversation id.
        return SessionRecord(startedAt: date(from: dateValue), messages: messages)
    }

    private static func int(_ value: Any?) -> Int {
        (value as? NSNumber)?.intValue ?? 0
    }

    private static func date(from value: Any?) -> Date? {
        if let number = value as? NSNumber {
            let raw = number.doubleValue
            return Date(timeIntervalSince1970: raw > 100_000_000_000 ? raw / 1000 : raw)
        }
        if let string = value as? String {
            return parseTimestamp(string)
        }
        return nil
    }

    /// The Antigravity cache may carry fractional-second ISO timestamps (for
    /// example `2026-08-15T17:57:15.877925Z`), which the default
    /// `ISO8601DateFormatter` rejects. Parse fractional first, then fall back
    /// to whole-second timestamps.
    private static func parseTimestamp(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }

        let whole = ISO8601DateFormatter()
        whole.formatOptions = [.withInternetDateTime]
        return whole.date(from: raw)
    }

    /// Reads agy's session history out of the `antigravity-config` container
    /// volume.
    ///
    /// The volume lives inside the container-runtime VM, so it is read with a
    /// throwaway `alpine` container that prints the history file. Only the
    /// `conversationId` and `timestamp` fields are ever inspected; prompt text
    /// and workspace paths in other fields are never read. Returns `nil` when
    /// the runtime is absent, the volume or image is missing, the container
    /// cannot be started, or the file is missing or empty.
    ///
    /// The volume is only mounted read-only, and only after an existence check:
    /// `docker run` would otherwise create a phantom `antigravity-config`
    /// volume on machines that never had agy's containerised setup.
    private static func readContainerHistory() -> Data? {
        guard let executable = resolveDockerExecutable(),
              runtimeVolumeExists(executable, name: "antigravity-config"),
              runtimeImageExists(executable, name: "alpine") else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = [
            "run", "--rm",
            "-v", "antigravity-config:/data:ro",
            "alpine", "cat", "/data/antigravity-cli/history.jsonl"
        ]
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, !data.isEmpty else { return nil }
        return data
    }

    private static func runtimeVolumeExists(_ executable: String, name: String) -> Bool {
        run(executable: executable, arguments: ["volume", "inspect", name]) != nil
    }

    private static func runtimeImageExists(_ executable: String, name: String) -> Bool {
        run(executable: executable, arguments: ["image", "inspect", name]) != nil
    }

    private static func run(executable: String, arguments: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return data
    }

    private static func resolveDockerExecutable() -> String? {
        let fileManager = FileManager.default
        let candidates: [String] = [
            "/opt/homebrew/bin/docker",
            "/opt/homebrew/bin/podman",
            "/usr/local/bin/docker",
            "/usr/local/bin/podman",
            "/usr/bin/docker"
        ]
        for candidate in candidates where fileManager.isExecutableFile(atPath: candidate) {
            return candidate
        }
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for directory in path.split(separator: ":") {
                let candidate = String(directory) + "/docker"
                if fileManager.isExecutableFile(atPath: candidate) { return candidate }
            }
        }
        return nil
    }

    /// Parses agy `history.jsonl` content (one JSON object per prompt line)
    /// into usage counts, grouping lines by `conversationId`.
    ///
    /// Only `conversationId` and `timestamp` are read; a line's other fields
    /// (prompt text, workspace path) are deliberately ignored. A session's
    /// `startedAt` is its earliest prompt timestamp.
    static func parseHistory(data: Data, now: Date) throws -> ProviderUsage {
        guard let text = String(data: data, encoding: .utf8) else {
            throw SourceUnavailable.failed(.antigravity)
        }
        struct Record {
            var messages: Int
            var startedAt: Date?
        }
        var byID: [String: Record] = [:]
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = String(rawLine).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let id = object["conversationId"] as? String, !id.isEmpty,
                  let timestamp = object["timestamp"] else { continue }
            var record = byID[id] ?? Record(messages: 0, startedAt: nil)
            record.messages += 1
            if let date = date(from: timestamp) {
                if let current = record.startedAt {
                    if date < current { record.startedAt = date }
                } else {
                    record.startedAt = date
                }
            }
            byID[id] = record
        }
        let sessions: [[String: Any]] = byID.compactMap { _, record in
            guard let startedAt = record.startedAt else { return nil }
            return ["started_at": startedAt.timeIntervalSince1970, "messages": record.messages]
        }
        guard !sessions.isEmpty else { throw SourceUnavailable.noData }
        let root: [String: Any] = ["sessions": sessions]
        let data = try JSONSerialization.data(withJSONObject: root)
        return try parse(data: data, now: now)
    }
}

// MARK: - Grok

/// Reads Grok's local session summaries.
///
/// Grok's persisted summary contains reliable session/message counts. Token
/// usage is intentionally left unknown here; the session signals file is not a
/// billable input/output ledger, so using its context-window counters would be
/// misleading.
public struct GrokUsageSource: UsageSource {
    public let provider: Provider = .grok
    private let root: URL

    public init(root: URL? = nil) {
        if let root {
            self.root = root
        } else if let configured = ProcessInfo.processInfo.environment["GROK_HOME"], !configured.isEmpty {
            let url = URL(fileURLWithPath: configured)
            self.root = url.path.hasPrefix("/")
                ? url
                : HomeDirectory.real.appendingPathComponent(configured, isDirectory: true)
        } else {
            self.root = HomeDirectory.real.appendingPathComponent(".grok", isDirectory: true)
        }
    }

    public func fetchUsage() async throws -> ProviderUsage {
        let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
        guard FileManager.default.fileExists(atPath: sessionsRoot.path) else {
            throw SourceUnavailable.dataNotFound("Grok session history")
        }

        var summaries: [[String: Any]] = []
        for url in Self.summaryURLs(in: sessionsRoot) {
            guard let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let messageCount = Self.messageCount(in: object),
                  messageCount > 0 else { continue }
            summaries.append(object)
        }

        return try Self.parse(summaries: summaries, now: Date())
    }

    private static func summaryURLs(in root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return enumerator.compactMap { $0 as? URL }
            .filter { $0.lastPathComponent == "summary.json" }
    }

    static func parse(summaries: [[String: Any]], now: Date) throws -> ProviderUsage {
        struct Record {
            let startedAt: Date
            let messages: Int
        }

        let records = summaries.compactMap { summary -> Record? in
            guard let date = date(in: summary), let messages = messageCount(in: summary) else { return nil }
            return Record(startedAt: date, messages: messages)
        }
        guard !records.isEmpty else { throw SourceUnavailable.noData }

        let today = Calendar.current.startOfDay(for: now)
        let todayRecords = records.filter { $0.startedAt >= today }
        let newest = records.map(\.startedAt).max() ?? now
        return ProviderUsage(
            provider: .grok,
            sessionCount: records.count,
            messageCount: records.reduce(0) { $0 + $1.messages },
            todaySessionCount: todayRecords.count,
            todayMessageCount: todayRecords.reduce(0) { $0 + $1.messages },
            capturedAt: newest
        )
    }

    private static func messageCount(in summary: [String: Any]) -> Int? {
        let keys = ["num_chat_messages", "num_messages", "message_count", "messageCount"]
        for key in keys {
            if let value = summary[key] as? NSNumber { return value.intValue }
        }
        return nil
    }

    private static func date(in summary: [String: Any]) -> Date? {
        let keys = ["created_at", "createdAt", "last_active_at", "updated_at", "updatedAt"]
        for key in keys {
            if let value = summary[key] as? String, let date = parseTimestamp(value) {
                return date
            }
            if let value = summary[key] as? NSNumber {
                let raw = value.doubleValue
                return Date(timeIntervalSince1970: raw > 100_000_000_000 ? raw / 1000 : raw)
            }
        }
        return nil
    }

    /// Grok writes timestamps with fractional seconds (e.g.
    /// `2026-08-15T17:57:15.877925Z`). The default `ISO8601DateFormatter`
    /// rejects those, which silently emptied every summary. Parse fractional
    /// first, then fall back to whole-second timestamps.
    private static func parseTimestamp(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }

        let whole = ISO8601DateFormatter()
        whole.formatOptions = [.withInternetDateTime]
        return whole.date(from: raw)
    }
}

// MARK: - OpenCode Go

/// Reads OpenCode Go's aggregate session rows through its supported, read-only
/// database command. The SQL selects only numeric usage fields and timestamps;
/// prompts, tool arguments, paths, and message bodies are never queried.
public struct OpenCodeGoUsageSource: UsageSource {
    public let provider: Provider = .openCodeGo
    private let executableURL: URL?

    public init(executableURL: URL? = nil) {
        self.executableURL = executableURL
    }

    public func fetchUsage() async throws -> ProviderUsage {
        let executable = try Self.resolveExecutable(explicit: executableURL)
        let data: Data
        do {
            data = try Self.run(executable: executable)
        } catch let error as SourceUnavailable {
            throw error
        } catch {
            throw SourceUnavailable.failed(provider)
        }

        let records = try Self.parse(data: data)
        guard !records.isEmpty else {
            throw SourceUnavailable.dataNotFound("OpenCode Go usage")
        }

        let now = Date()
        let today = Calendar.current.startOfDay(for: now)
        let todayRecords = records.filter { $0.createdAt >= today }
        let tokens = records.reduce(TokenTotals()) { total, record in
            total + TokenTotals(
                input: record.input,
                output: record.output,
                reasoning: record.reasoning,
                cacheRead: record.cacheRead,
                cacheWrite: record.cacheWrite
            )
        }
        let cost = records.reduce(0) { $0 + $1.cost }
        return ProviderUsage(
            provider: .openCodeGo,
            sessionCount: records.count,
            messageCount: records.reduce(0) { $0 + $1.messages },
            tokens: tokens,
            estimatedCostUSD: cost,
            todaySessionCount: todayRecords.count,
            todayMessageCount: todayRecords.reduce(0) { $0 + $1.messages },
            usageWindows: Self.windows(from: records, now: now),
            capturedAt: records.map(\.updatedAt).max() ?? now
        )
    }

    /// Rolling usage slices over the records a fetch already read.
    ///
    /// Windows use `updatedAt` (the session's last activity), matching how
    /// `opencode stats --days N` buckets sessions: a session started before a
    /// window but still being worked on inside it counts, and all of its
    /// messages count. Filtering by `createdAt` under-counted the 24h window —
    /// a session started two days ago and touched today contributed nothing.
    static func windows(from records: [Record], now: Date) -> [UsageWindow] {
        [("last 24h", 86_400.0), ("last 7d", 7 * 86_400.0), ("last 30d", 30 * 86_400.0)]
            .map { label, seconds in
                let inWindow = records.filter { $0.updatedAt >= now.addingTimeInterval(-seconds) }
                return UsageWindow(
                    label: label,
                    sessionCount: inWindow.count,
                    messageCount: inWindow.reduce(0) { $0 + $1.messages },
                    tokens: inWindow.reduce(TokenTotals()) { total, record in
                        total + TokenTotals(
                            input: record.input,
                            output: record.output,
                            reasoning: record.reasoning,
                            cacheRead: record.cacheRead,
                            cacheWrite: record.cacheWrite
                        )
                    },
                    estimatedCostUSD: inWindow.reduce(0) { $0 + $1.cost }
                )
            }
    }

    struct Record: Equatable {
        let input: Int
        let output: Int
        let reasoning: Int
        let cacheRead: Int
        let cacheWrite: Int
        let cost: Double
        let messages: Int
        let createdAt: Date
        let updatedAt: Date
    }

    static func parse(data: Data) throws -> [Record] {
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw SourceUnavailable.failed(.openCodeGo)
        }
        return rows.compactMap { row in
            guard let created = date(row["created"]), let updated = date(row["updated"]) else { return nil }
            return Record(
                input: int(row["input"]),
                output: int(row["output"]),
                reasoning: int(row["reasoning"]),
                cacheRead: int(row["cache_read"]),
                cacheWrite: int(row["cache_write"]),
                cost: double(row["cost"]),
                messages: int(row["messages"]),
                createdAt: created,
                updatedAt: updated
            )
        }
    }

    private static let query = """
    SELECT tokens_input AS input,
           tokens_output AS output,
           tokens_reasoning AS reasoning,
           tokens_cache_read AS cache_read,
           tokens_cache_write AS cache_write,
           cost,
           (SELECT COUNT(*) FROM message WHERE message.session_id = session.id) AS messages,
           time_created AS created,
           time_updated AS updated
    FROM session
    WHERE json_extract(model, '$.providerID') = 'opencode-go'
    """

    private static func run(executable: String) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["db", "--format", "json", query]

        // `opencode db --format json` stops at the 64KB pipe boundary when its
        // stdout is a pipe (the trailing rows are silently dropped), but writes
        // complete output to a regular file. Route stdout to a temporary file so
        // large result sets survive. Stderr goes to /dev/null so a chatty CLI
        // cannot fill a pipe buffer and stall the child mid-write.
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("meterusage-opencode-\(UUID().uuidString).json")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil),
              let outputHandle = try? FileHandle(forWritingTo: outputURL) else {
            throw SourceUnavailable.failed(.openCodeGo)
        }
        defer {
            outputHandle.closeFile()
            try? FileManager.default.removeItem(at: outputURL)
        }
        process.standardOutput = outputHandle
        if let devNull = FileHandle(forWritingAtPath: "/dev/null") {
            process.standardError = devNull
        }

        do {
            try process.run()
        } catch {
            throw SourceUnavailable.cliNotFound("OpenCode")
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw SourceUnavailable.failed(.openCodeGo)
        }
        guard let data = try? Data(contentsOf: outputURL) else {
            throw SourceUnavailable.failed(.openCodeGo)
        }
        return data
    }

    private static func resolveExecutable(explicit: URL?) throws -> String {
        let fileManager = FileManager.default
        let candidates: [String] = [
            explicit?.path,
            "/opt/homebrew/bin/opencode",
            "/usr/local/bin/opencode",
            HomeDirectory.real.appendingPathComponent(".bun/bin/opencode").path,
            HomeDirectory.real.appendingPathComponent(".local/bin/opencode").path
        ].compactMap { $0 }

        for candidate in candidates where fileManager.isExecutableFile(atPath: candidate) {
            return candidate
        }
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for directory in path.split(separator: ":") {
                let candidate = String(directory) + "/opencode"
                if fileManager.isExecutableFile(atPath: candidate) { return candidate }
            }
        }
        throw SourceUnavailable.cliNotFound("OpenCode")
    }

    private static func int(_ value: Any?) -> Int {
        (value as? NSNumber)?.intValue ?? 0
    }

    private static func double(_ value: Any?) -> Double {
        (value as? NSNumber)?.doubleValue ?? 0
    }

    private static func date(_ value: Any?) -> Date? {
        guard let number = value as? NSNumber else { return nil }
        let raw = number.doubleValue
        return Date(timeIntervalSince1970: raw > 100_000_000_000 ? raw / 1000 : raw)
    }
}
