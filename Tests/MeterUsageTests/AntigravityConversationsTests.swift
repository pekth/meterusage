import XCTest
import SQLite3
@testable import MeterUsage

final class AntigravityConversationsTests: XCTestCase {
    // MARK: Synthetic protobuf encoding

    /// Encodes a base-128 varint.
    private func varintBytes(_ value: UInt64) -> [UInt8] {
        var value = value
        var bytes: [UInt8] = []
        repeat {
            var byte = UInt8(value & 0x7f)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            bytes.append(byte)
        } while value != 0
        return bytes
    }

    /// Encodes a varint field (wire type 0).
    private func field(_ number: Int, _ value: UInt64) -> Data {
        Data(varintBytes(UInt64(number) << 3) + varintBytes(value))
    }

    /// Encodes a length-delimited field (wire type 2) from nested bytes.
    private func field(_ number: Int, bytes: [UInt8]) -> Data {
        Data(varintBytes(UInt64(number) << 3 | 2) + varintBytes(UInt64(bytes.count)) + bytes)
    }

    private func field(_ number: Int, bytes: Data...) -> Data {
        field(number, bytes: bytes.flatMap(Array.init))
    }

    /// A gen_metadata blob with one chatModel carrying one usage record.
    private func usageBlob(input: UInt64, output: UInt64, cacheRead: UInt64 = 0, thinking: UInt64 = 0) -> Data {
        let usage = field(2, input) + field(3, output) + field(5, cacheRead) + field(9, thinking)
        let chatModel = field(4, bytes: [UInt8](usage))
        return field(1, bytes: [UInt8](chatModel))
    }

    /// A steps.metadata blob with a source enum and a Timestamp.
    private func stepBlob(source: UInt64, seconds: UInt64) -> Data {
        let createdAt = field(1, seconds)
        let step = field(1, bytes: [UInt8](createdAt)) + field(3, source)
        return Data([UInt8](step))
    }

    // MARK: Blob parsing

    func testGenMetadataBlobDecodesTokenFields() {
        let blob = usageBlob(input: 13_812, output: 1_147, cacheRead: 65_536, thinking: 644)
        let turn = AntigravityConversations.parseGenMetadataBlob(blob)
        XCTAssertEqual(
            turn,
            AntigravityConversations.TurnUsage(input: 13_812, output: 1_147, cacheRead: 65_536, thinking: 644)
        )
    }

    func testGenMetadataBlobWithoutUsageIsSkipped() {
        XCTAssertNil(AntigravityConversations.parseGenMetadataBlob(field(1, bytes: [UInt8](field(4, bytes: [])))))
        XCTAssertNil(AntigravityConversations.parseGenMetadataBlob(field(1, bytes: [UInt8](field(2, 1)))))
        XCTAssertNil(AntigravityConversations.parseGenMetadataBlob(Data([0xff, 0xff, 0xff])))
        XCTAssertNil(AntigravityConversations.parseGenMetadataBlob(Data()))
    }

    func testStepBlobDecodesRolesAndTimestamps() {
        let seconds = UInt64(Date(timeIntervalSince1970: 1_725_268_477).timeIntervalSince1970)
        let user = AntigravityConversations.parseStepMetadata(stepBlob(source: 4, seconds: seconds))
        XCTAssertEqual(user, AntigravityConversations.StepEvent(role: .user, timestamp: Date(timeIntervalSince1970: 1_725_268_477)))

        let model = AntigravityConversations.parseStepMetadata(stepBlob(source: 2, seconds: seconds))
        XCTAssertEqual(model?.role, .model)

        XCTAssertNil(AntigravityConversations.parseStepMetadata(stepBlob(source: 7, seconds: seconds)))
        XCTAssertNil(AntigravityConversations.parseStepMetadata(stepBlob(source: 4, seconds: 42)))
    }

    // MARK: Aggregation

    func testAggregationSumsTokensAndCountsUserTurns() throws {
        let now = Date()
        let today = Calendar.current.startOfDay(for: now)
        let twoDaysAgo = today.addingTimeInterval(-2 * 86_400 + 3_600)

        let current = AntigravityConversations.Database(
            genMetadataBlobs: [usageBlob(input: 100, output: 50), usageBlob(input: 30, output: 20, thinking: 10)],
            stepBlobs: [
                stepBlob(source: 4, seconds: UInt64(now.addingTimeInterval(-3_600).timeIntervalSince1970)),
                stepBlob(source: 2, seconds: UInt64(now.addingTimeInterval(-3_500).timeIntervalSince1970)),
                stepBlob(source: 7, seconds: UInt64(now.addingTimeInterval(-3_400).timeIntervalSince1970))
            ]
        )
        let stale = AntigravityConversations.Database(
            genMetadataBlobs: [],
            stepBlobs: [stepBlob(source: 4, seconds: UInt64(twoDaysAgo.timeIntervalSince1970))]
        )
        let empty = AntigravityConversations.Database()

        let usage = try AntigravityConversations.parse(databases: [current, stale, empty], now: now)

        XCTAssertEqual(usage.provider, .antigravity)
        XCTAssertEqual(usage.sessionCount, 2)
        XCTAssertEqual(usage.messageCount, 2)
        XCTAssertEqual(usage.tokens, TokenTotals(input: 130, output: 70, reasoning: 10))
        XCTAssertEqual(usage.todaySessionCount, 1)
        XCTAssertEqual(usage.todayMessageCount, 1)
        // CapturedAt round-trips through whole-second protobuf timestamps, so
        // compare with sub-second tolerance.
        XCTAssertEqual(
            usage.capturedAt.timeIntervalSince1970,
            now.addingTimeInterval(-3_500).timeIntervalSince1970,
            accuracy: 1.0
        )

        let windows = try XCTUnwrap(usage.usageWindows)
        XCTAssertEqual(windows.map(\.label), ["last 24h", "last 7d", "last 30d"])
        XCTAssertEqual(windows[0].sessionCount, 1)
        XCTAssertEqual(windows[0].tokens, TokenTotals(input: 130, output: 70, reasoning: 10))
        XCTAssertEqual(windows[1].sessionCount, 2)
        XCTAssertEqual(windows[2].sessionCount, 2)
    }

    func testAggregationWithoutAnyTokenLeavesTokensNil() throws {
        let now = Date()
        let database = AntigravityConversations.Database(
            stepBlobs: [stepBlob(source: 4, seconds: UInt64(now.addingTimeInterval(-60).timeIntervalSince1970))]
        )
        let usage = try AntigravityConversations.parse(databases: [database], now: now)
        XCTAssertEqual(usage.sessionCount, 1)
        XCTAssertNil(usage.tokens)
    }

    func testAggregationThrowsWhenNothingDecodes() {
        XCTAssertThrowsError(
            try AntigravityConversations.parse(databases: [AntigravityConversations.Database()], now: Date())
        )
    }

    // MARK: SQLite store reading

    /// Writes a real conversation store with synthetic blob rows so the
    /// SQLite path is exercised end to end.
    private func writeConversationStore(
        at url: URL,
        genMetadataBlobs: [Data],
        stepBlobs: [Data]
    ) throws {
        var database: OpaquePointer?
        defer { sqlite3_close_v2(database) }
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            return XCTFail("could not create \(url.path)")
        }
        try execute("CREATE TABLE gen_metadata (idx integer, data blob, size integer NOT NULL DEFAULT 0)", database)
        try execute("""
        CREATE TABLE steps (idx integer, step_type integer NOT NULL DEFAULT 0, \
        status integer NOT NULL DEFAULT 0, metadata blob)
        """, database)
        for (index, blob) in genMetadataBlobs.enumerated() {
            try bind(
                "INSERT INTO gen_metadata (idx, data) VALUES (?, ?)",
                index: Int32(index),
                blob: blob,
                database
            )
        }
        for (index, blob) in stepBlobs.enumerated() {
            try bind(
                "INSERT INTO steps (idx, metadata) VALUES (?, ?)",
                index: Int32(index),
                blob: blob,
                database
            )
        }
    }

    private func execute(_ sql: String, _ database: OpaquePointer?) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            return XCTFail(message)
        }
    }

    private func bind(_ sql: String, index: Int32, blob: Data, _ database: OpaquePointer?) throws {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            return XCTFail("could not prepare \(sql)")
        }
        blob.withUnsafeBytes { raw in
            // SQLITE_TRANSIENT is a C macro the SQLite3 module does not
            // expose; its value is the -1 pointer.
            let transient = unsafeBitCast(Int(-1), to: sqlite3_destructor_type.self)
            _ = sqlite3_bind_blob(statement, 2, raw.baseAddress, Int32(blob.count), transient)
        }
        sqlite3_bind_int(statement, 1, index)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            return XCTFail("could not insert row")
        }
    }

    func testReadUsageFromSQLiteStore() throws {
        let now = Date()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("meterusage-agy-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try writeConversationStore(
            at: directory.appendingPathComponent("conversation-a.db"),
            genMetadataBlobs: [usageBlob(input: 5_000, output: 400), usageBlob(input: 6_000, output: 500, cacheRead: 7_000)],
            stepBlobs: [
                stepBlob(source: 4, seconds: UInt64(now.addingTimeInterval(-1_200).timeIntervalSince1970)),
                stepBlob(source: 2, seconds: UInt64(now.addingTimeInterval(-1_100).timeIntervalSince1970)),
                stepBlob(source: 4, seconds: UInt64(now.addingTimeInterval(-1_000).timeIntervalSince1970))
            ]
        )
        // An unreadable store must be skipped, not fail the source.
        try Data([0xde, 0xad, 0xbe, 0xef]).write(to: directory.appendingPathComponent("broken.db"))

        let usage = try AntigravityConversations.readUsage(in: directory, now: now)

        XCTAssertEqual(usage.sessionCount, 1)
        XCTAssertEqual(usage.messageCount, 2)
        XCTAssertEqual(usage.tokens, TokenTotals(input: 11_000, output: 900, cacheRead: 7_000))
        XCTAssertEqual(usage.todaySessionCount, 1)
        XCTAssertEqual(usage.todayMessageCount, 2)
    }

    func testReadUsageThrowsWhenDirectoryHasNoStores() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("meterusage-agy-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertThrowsError(try AntigravityConversations.readUsage(in: directory, now: Date()))
    }
}
