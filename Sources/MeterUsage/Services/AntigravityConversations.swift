import Foundation
import SQLite3

// MARK: - Antigravity conversation stores

/// Reads token usage out of agy's per-conversation SQLite stores.
///
/// Modern Antigravity CLI builds persist each conversation as
/// `~/.gemini/antigravity-cli/conversations/<uuid>.db`. The `gen_metadata`
/// table holds one protobuf-encoded `GeneratorMetadata` blob per generation
/// turn, and the `steps` table holds one protobuf-encoded step blob per turn
/// with its timestamp. Both are plain protobuf, so token counts can be read
/// straight from disk with no running process and no network call.
///
/// The wire-format field numbers were cross-verified against two independent
/// open-source readers of the same stores (vibe-usage's `antigravity-db.js`,
/// cross-checked by its author against the language server's
/// GetCascadeTrajectory JSON, and tokenprinter) and against live blobs from a
/// local agy install:
///
///   gen_metadata blob:
///     1 = chatModel
///       4 = usage
///         4.2 = inputTokens          4.3 = outputTokens
///         4.5 = cacheReadTokens      4.9 = thinkingOutputTokens
///   steps blob:
///     1 = createdAt (Timestamp: seconds at 1.1)
///     3 = source enum (4 = user turn, 2 = model turn)
///
/// Only numeric usage fields and step timestamps are decoded. Prompt text,
/// tool payloads, workspace paths, and identifiers inside the blobs are never
/// touched: the decoder walks the wire format but the caller reads exactly
/// the fields listed above.
enum AntigravityConversations {
    /// Token usage decoded from one generation-turn blob.
    struct TurnUsage: Equatable {
        var input = 0
        var output = 0
        var cacheRead = 0
        var thinking = 0
    }

    /// One decoded turn event from the steps table.
    struct StepEvent: Equatable {
        enum Role: Equatable { case user, model }
        var role: Role
        var timestamp: Date
    }

    /// The decoded content of one conversation `.db` file.
    struct Database {
        var genMetadataBlobs: [Data] = []
        var stepBlobs: [Data] = []
    }

    // MARK: Aggregation

    /// Flat per-session totals the aggregation and windows both use.
    struct SessionAggregate {
        var tokens: TokenTotals
        var userTurns: [Date]
        var lastActivity: Date?

        var messageCount: Int { userTurns.count }
    }

    /// Aggregates decoded conversation databases into a `ProviderUsage`.
    ///
    /// Sessions are conversation databases; a database counts as a session
    /// when it carries token usage or user turns. Messages are user turns
    /// (the same signal `history.jsonl`'s prompt lines represent), never
    /// model or tool steps. `tokens` stays nil when no database carries a
    /// nonzero usage blob, so an empty store never reads as measured zero.
    static func parse(databases: [Database], now: Date) throws -> ProviderUsage {
        let today = Calendar.current.startOfDay(for: now)
        var sessions: [SessionAggregate] = []

        for database in databases {
            var tokens = TokenTotals()
            for blob in database.genMetadataBlobs {
                guard let turn = parseGenMetadataBlob(blob) else { continue }
                tokens = tokens + TokenTotals(
                    input: turn.input,
                    output: turn.output,
                    reasoning: turn.thinking,
                    cacheRead: turn.cacheRead
                )
            }
            var userTurns: [Date] = []
            var lastActivity: Date?
            for blob in database.stepBlobs {
                guard let event = parseStepMetadata(blob) else { continue }
                if event.role == .user { userTurns.append(event.timestamp) }
                if lastActivity == nil || event.timestamp > lastActivity! {
                    lastActivity = event.timestamp
                }
            }
            guard tokens.total > 0 || !userTurns.isEmpty else { continue }
            sessions.append(SessionAggregate(tokens: tokens, userTurns: userTurns, lastActivity: lastActivity))
        }

        guard !sessions.isEmpty else { throw SourceUnavailable.noData }

        let todayTurns = sessions.flatMap(\.userTurns).filter { $0 >= today }
        let tokens = sessions.reduce(TokenTotals()) { $0 + $1.tokens }
        return ProviderUsage(
            provider: .antigravity,
            sessionCount: sessions.count,
            messageCount: sessions.reduce(0) { $0 + $1.messageCount },
            tokens: tokens.total > 0 ? tokens : nil,
            todaySessionCount: sessions.filter { session in
                session.userTurns.first.map { $0 >= today } == true
            }.count,
            todayMessageCount: todayTurns.count,
            usageWindows: windows(from: sessions, now: now),
            capturedAt: sessions.compactMap(\.lastActivity).max() ?? now
        )
    }

    /// Rolling usage slices over sessions a fetch already decoded. A session
    /// falls in a window when its last recorded activity (user or model turn)
    /// is inside the window, matching how OpenCode Go's windows bucket by the
    /// session's `updatedAt`.
    static func windows(from sessions: [SessionAggregate], now: Date) -> [UsageWindow] {
        [("last 24h", 86_400.0), ("last 7d", 7 * 86_400.0), ("last 30d", 30 * 86_400.0)]
            .map { label, seconds in
                let inWindow = sessions.filter { ($0.lastActivity ?? .distantPast) >= now.addingTimeInterval(-seconds) }
                return UsageWindow(
                    label: label,
                    sessionCount: inWindow.count,
                    messageCount: inWindow.reduce(0) { $0 + $1.messageCount },
                    tokens: inWindow.reduce(TokenTotals()) { $0 + $1.tokens },
                    estimatedCostUSD: 0
                )
            }
    }

    // MARK: SQLite reading

    /// Reads every `*.db` conversation store in `directory`.
    ///
    /// Each file is copied next to its sidecar WAL files before being opened,
    /// so a live agy process writing its database can never block or corrupt
    /// the read; the copy is a private snapshot. A database that cannot be
    /// read or parsed is skipped rather than failing the whole source.
    static func readDatabases(in directory: URL) throws -> [Database] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ))?.filter { $0.pathExtension == "db" } ?? []
        guard !files.isEmpty else { throw SourceUnavailable.noData }

        var databases: [Database] = []
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            if let database = readDatabase(at: file) {
                databases.append(database)
            }
        }
        return databases
    }

    /// Convenience used by `AntigravityUsageSource`: read a directory of
    /// conversation stores straight into aggregated usage.
    static func readUsage(in directory: URL, now: Date) throws -> ProviderUsage {
        try parse(databases: readDatabases(in: directory), now: now)
    }

    private static func readDatabase(at url: URL) -> Database? {
        let snapshot = copySnapshot(of: url)
        defer {
            if let snapshot {
                try? FileManager.default.removeItem(at: snapshot.directory)
            }
        }
        guard let snapshot else { return nil }
        return openSnapshot(snapshot)
    }

    private struct Snapshot {
        var directory: URL
        var file: URL
    }

    /// Copies a database and its `-wal`/`-shm` sidecars into a fresh
    /// temporary directory so the read works from a consistent snapshot.
    private static func copySnapshot(of url: URL) -> Snapshot? {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("meterusage-agy-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.copyItem(at: url, to: file)
            for suffix in ["-wal", "-shm"] {
                let source = URL(fileURLWithPath: url.path + suffix)
                if FileManager.default.fileExists(atPath: source.path) {
                    try FileManager.default.copyItem(
                        at: source,
                        to: URL(fileURLWithPath: file.path + suffix)
                    )
                }
            }
            return Snapshot(directory: directory, file: file)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            return nil
        }
    }

    private static func openSnapshot(_ snapshot: Snapshot) -> Database? {
        var database: OpaquePointer?
        // The snapshot lives in a private temp directory we own, so opening
        // read-write is safe: SQLite may recover the copied WAL file, and the
        // copy is deleted afterwards.
        guard sqlite3_open_v2(snapshot.file.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let database else {
            sqlite3_close_v2(database)
            return nil
        }
        defer { sqlite3_close_v2(database) }

        var result = Database()
        result.genMetadataBlobs = blobRows(in: database, sql: "SELECT hex(data) FROM gen_metadata ORDER BY idx")
        result.stepBlobs = blobRows(
            in: database,
            sql: "SELECT hex(metadata) FROM steps WHERE metadata IS NOT NULL ORDER BY idx"
        )
        return result
    }

    private static func blobRows(in database: OpaquePointer, sql: String) -> [Data] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }

        var rows: [Data] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let cString = sqlite3_column_text(statement, 0) else { continue }
            let hex = String(cString: cString)
            if let data = Data(hexString: hex), !data.isEmpty {
                rows.append(data)
            }
        }
        return rows
    }

    // MARK: Protobuf wire format

    /// One decoded protobuf field.
    struct WireField {
        var number: Int
        var wireType: Int
        var varint: UInt64 = 0
        var bytes: Data = Data()
    }

    /// Decodes one protobuf message into its fields. Unknown wire types stop
    /// the walk; the caller only relies on messages that parse cleanly.
    static func decodeFields(_ data: Data) -> [WireField] {
        var fields: [WireField] = []
        var offset = 0
        let bytes = [UInt8](data)

        func readVarint(_ position: inout Int) -> UInt64? {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            while position < bytes.count {
                let byte = bytes[position]
                position += 1
                value |= UInt64(byte & 0x7f) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
                if shift >= 64 { return nil }
            }
            return nil
        }

        while offset < bytes.count {
            guard let tag = readVarint(&offset) else { break }
            let number = Int(tag >> 3)
            let wireType = Int(tag & 0x7)
            guard number > 0 else { break }
            switch wireType {
            case 0:
                guard let value = readVarint(&offset) else { return fields }
                fields.append(WireField(number: number, wireType: 0, varint: value))
            case 2:
                guard let length = readVarint(&offset), Int(length) <= bytes.count - offset else { return fields }
                let start = bytes.index(bytes.startIndex, offsetBy: offset)
                let end = bytes.index(start, offsetBy: Int(length))
                fields.append(WireField(number: number, wireType: 2, bytes: Data(bytes[start..<end])))
                offset += Int(length)
            case 5:
                guard bytes.count - offset >= 4 else { return fields }
                let start = bytes.index(bytes.startIndex, offsetBy: offset)
                fields.append(WireField(number: number, wireType: 5, bytes: Data(bytes[start..<bytes.index(start, offsetBy: 4)])))
                offset += 4
            case 1:
                guard bytes.count - offset >= 8 else { return fields }
                let start = bytes.index(bytes.startIndex, offsetBy: offset)
                fields.append(WireField(number: number, wireType: 1, bytes: Data(bytes[start..<bytes.index(start, offsetBy: 8)])))
                offset += 8
            default:
                return fields
            }
        }
        return fields
    }

    private static func firstVarint(_ fields: [WireField], _ number: Int) -> UInt64? {
        fields.first { $0.number == number && $0.wireType == 0 }?.varint
    }

    private static func firstBytes(_ fields: [WireField], _ number: Int) -> Data? {
        fields.first { $0.number == number && $0.wireType == 2 }?.bytes
    }

    private static func firstMessage(_ fields: [WireField], _ number: Int) -> [WireField]? {
        firstBytes(fields, number).map(decodeFields)
    }

    /// Decodes one `gen_metadata` blob into its token usage, or nil when the
    /// blob carries no real usage (error or planning-only turns).
    static func parseGenMetadataBlob(_ data: Data) -> TurnUsage? {
        guard let chatModel = firstMessage(decodeFields(data), 1),
              let usage = firstMessage(chatModel, 4) else { return nil }
        var turn = TurnUsage()
        turn.input = Int(clamping: firstVarint(usage, 2) ?? 0)
        turn.output = Int(clamping: firstVarint(usage, 3) ?? 0)
        turn.cacheRead = Int(clamping: firstVarint(usage, 5) ?? 0)
        turn.thinking = Int(clamping: firstVarint(usage, 9) ?? 0)
        guard turn.input > 0 || turn.output > 0 || turn.cacheRead > 0 || turn.thinking > 0 else {
            return nil
        }
        return turn
    }

    /// Decodes one `steps.metadata` blob into a turn event, or nil for
    /// system/tool steps and blobs without a usable timestamp.
    static func parseStepMetadata(_ data: Data) -> StepEvent? {
        let fields = decodeFields(data)
        guard let source = firstVarint(fields, 3) else { return nil }
        let role: StepEvent.Role
        switch source {
        case 4: role = .user
        case 2: role = .model
        default: return nil
        }
        guard let createdAt = firstMessage(fields, 1),
              let seconds = firstVarint(createdAt, 1),
              seconds > 1_000_000_000, seconds < 4_102_444_800 else { return nil }
        return StepEvent(role: role, timestamp: Date(timeIntervalSince1970: TimeInterval(seconds)))
    }
}

extension Data {
    /// Hex-decodes a string such as SQLite's `hex()` output. Returns nil when
    /// the string is not valid hex.
    init?(hexString: String) {
        let characters = Array(hexString.utf8)
        guard characters.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(characters.count / 2)
        func nibble(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 0x30...0x39: return byte - 0x30
            case 0x61...0x66: return byte - 0x61 + 10
            case 0x41...0x46: return byte - 0x41 + 10
            default: return nil
            }
        }
        var index = 0
        while index < characters.count {
            guard let high = nibble(characters[index]), let low = nibble(characters[index + 1]) else {
                return nil
            }
            bytes.append(high << 4 | low)
            index += 2
        }
        self.init(bytes)
    }
}
