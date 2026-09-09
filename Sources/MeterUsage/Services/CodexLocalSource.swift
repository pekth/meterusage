import Foundation

// MARK: - CodexLocalSource
//
// Counts Codex sessions per day from the local session store, for the weekly
// heatmap. Codex persists one rollout file per session under
// `~/.codex/sessions/**/*.jsonl`.
//
// Codex exposes no stable per-session token ledger on disk, so this source
// measures activity in sessions per day only — the same count-based honesty
// as Antigravity and Grok. It never reads the files' payloads: only the first
// line of each rollout (which carries the session's start timestamp), falling
// back to the file's modification date for anything that cannot be parsed.
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

        // Day (UTC midnight) -> session count. Grouping by UTC keeps the
        // heatmap deterministic and matches the "Z"-suffixed timestamps in
        // the rollout files, so tests do not depend on the machine's zone.
        var dayCounts: [Date: Int] = [:]
        for url in Self.sessionFiles(in: root, fileManager: fileManager) {
            guard let day = Self.sessionDay(for: url, fileManager: fileManager) else { continue }
            dayCounts[day, default: 0] += 1
        }

        guard !dayCounts.isEmpty else {
            throw SourceUnavailable.noData
        }

        let daily = dayCounts
            .map { day, count in
                DailyActivity(day: day, tokens: TokenTotals(), estimatedCostUSD: 0, sessionCount: count)
            }
            .sorted { $0.day < $1.day }

        let now = Date()
        let telemetry = TelemetryCalculator.calculate(
            sessions: [],
            daily: daily,
            now: now
        )

        return LocalActivity(
            provider: .codex,
            sessions: [],
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
        guard let date = firstLineTimestamp(for: url) ?? modificationDate(for: url, fileManager: fileManager) else {
            return nil
        }
        return utcCalendar.startOfDay(for: date)
    }

    /// Reads only the first line of a rollout file and takes its top-level
    /// `timestamp` (the `session_meta` event). The rest of the file is never
    /// opened, so a multi-hundred-MB session costs one bounded read.
    private static func firstLineTimestamp(for url: URL) -> Date? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let chunk = handle.readData(ofLength: 64 * 1024)
        guard let newline = chunk.firstIndex(of: 0x0A),
              let object = try? JSONSerialization.jsonObject(with: chunk[..<newline]) as? [String: Any],
              let raw = object["timestamp"] as? String,
              let date = parseTimestamp(raw) else { return nil }
        return date
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
