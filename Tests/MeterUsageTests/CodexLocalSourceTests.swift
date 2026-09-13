import XCTest
@testable import MeterUsage

final class CodexLocalSourceTests: XCTestCase {

    private static var utc: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    private static func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Self.utc.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func makeRoot() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexLocalSourceTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Writes a Codex-shaped rollout file whose first line carries the given
    /// session start timestamp and working directory, optionally ending with
    /// a cumulative `token_count` event.
    @discardableResult
    private func writeRollout(
        _ root: URL,
        name: String,
        timestamp: String,
        cwd: String? = nil,
        tokens: (input: Int, cached: Int, output: Int, reasoning: Int)? = nil
    ) throws -> URL {
        let dir = root
            .appendingPathComponent("2026", isDirectory: true)
            .appendingPathComponent("08", isDirectory: true)
            .appendingPathComponent("11", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var payload = ""
        if let cwd {
            payload = #","payload":{"cwd":"\#(cwd)"}"#
        }
        var lines = #"{"timestamp":"\#(timestamp)","type":"session_meta"\#(payload)}"#
        if let tokens {
            lines += "\n" + #"{"timestamp":"\#(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(tokens.input),"cached_input_tokens":\#(tokens.cached),"output_tokens":\#(tokens.output),"reasoning_output_tokens":\#(tokens.reasoning),"total_tokens":\#(tokens.input + tokens.output)}}}}"#
        }
        let url = dir.appendingPathComponent(name + ".jsonl")
        try Data((lines + "\n").utf8).write(to: url)
        return url
    }

    func testScanCountsSessionsPerDay() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeRollout(root, name: "rollout-2026-08-11T12-00-00-a", timestamp: "2026-08-11T12:00:00.000Z")
        try writeRollout(root, name: "rollout-2026-08-11T13-00-00-b", timestamp: "2026-08-11T13:00:00.000Z")
        try writeRollout(root, name: "rollout-2026-08-10T09-00-00-c", timestamp: "2026-08-10T09:00:00.000Z")

        let activity = try await CodexLocalSource(root: root).scan()

        XCTAssertEqual(activity.provider, .codex)
        XCTAssertEqual(activity.sessions.count, 3)
        XCTAssertEqual(activity.daily.count, 2)

        let day11 = try XCTUnwrap(activity.daily.first { $0.day == Self.day(2026, 8, 11) })
        XCTAssertEqual(day11.sessionCount, 2)
        XCTAssertEqual(day11.tokens.total, 0, "rollouts without a token ledger contribute no tokens")
        XCTAssertEqual(day11.estimatedCostUSD, 0)

        let day10 = try XCTUnwrap(activity.daily.first { $0.day == Self.day(2026, 8, 10) })
        XCTAssertEqual(day10.sessionCount, 1)
    }

    /// The last `token_count` event in a rollout carries the session's
    /// cumulative ledger, and its tokens land on the session's UTC day so the
    /// unified "AI coding today" strip can sum them.
    func testScanParsesCumulativeTokensFromLastTokenCountEvent() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // cached sits inside input, reasoning inside output: the totals must
        // still sum to Codex's own total_tokens (1_000_000 + 2_000).
        try writeRollout(
            root,
            name: "rollout-2026-08-11T12-00-00-a",
            timestamp: "2026-08-11T12:00:00.000Z",
            cwd: "/testuser/example/meterusage",
            tokens: (input: 1_000_000, cached: 900_000, output: 2_000, reasoning: 500)
        )
        try writeRollout(
            root,
            name: "rollout-2026-08-10T09-00-00-b",
            timestamp: "2026-08-10T09:00:00.000Z",
            tokens: (input: 10, cached: 0, output: 5, reasoning: 0)
        )

        let activity = try await CodexLocalSource(root: root).scan()

        let session = try XCTUnwrap(activity.sessions.first { $0.startedAt == Self.day(2026, 8, 11).addingTimeInterval(12 * 3600) })
        XCTAssertEqual(session.projectName, "meterusage")
        XCTAssertEqual(session.tokens.input, 100_000)
        XCTAssertEqual(session.tokens.cacheRead, 900_000)
        XCTAssertEqual(session.tokens.output, 1_500)
        XCTAssertEqual(session.tokens.reasoning, 500)
        XCTAssertEqual(session.tokens.total, 1_002_000)

        let day11 = try XCTUnwrap(activity.daily.first { $0.day == Self.day(2026, 8, 11) })
        XCTAssertEqual(day11.tokens.total, 1_002_000)
        XCTAssertEqual(day11.sessionCount, 1)

        let day10 = try XCTUnwrap(activity.daily.first { $0.day == Self.day(2026, 8, 10) })
        XCTAssertEqual(day10.tokens.total, 15)
    }

    /// The final events after the last `token_count` can be large (tool
    /// output), so the backward search must keep reading earlier chunks until
    /// it finds the ledger instead of stopping at the first megabyte.
    func testTokenSearchReadsBackwardPastLargeTrailingEvents() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try writeRollout(
            root,
            name: "rollout-2026-08-11T12-00-00-a",
            timestamp: "2026-08-11T12:00:00.000Z",
            tokens: (input: 500, cached: 100, output: 50, reasoning: 10)
        )
        // A multi-megabyte tool-output event after the token_count event.
        var data = try Data(contentsOf: url)
        data.append(Data(String(repeating: "x", count: 3 << 20).utf8))
        data.append(Data("\n".utf8))
        try data.write(to: url)

        let totals = try XCTUnwrap(CodexLocalSource.lastTokenUsage(for: url))
        XCTAssertEqual(totals.total, 550)

        let activity = try await CodexLocalSource(root: root).scan()
        XCTAssertEqual(try XCTUnwrap(activity.sessions.first).tokens.total, 550)
    }

    /// A token_count event with an empty ledger (info present but zeroed) is
    /// not a reading; the session reports no tokens rather than zero-as-data.
    func testZeroedTokenCountIsIgnored() {
        let line = Data(#"{"timestamp":"2026-08-11T12:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":0,"cached_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0,"total_tokens":0}}}}"#.utf8)
        XCTAssertNil(CodexLocalSource.parseTokenCountLine(line))
    }

    func testParseTokenCountLineRejectsOtherEvents() {
        let line = Data(#"{"timestamp":"2026-08-11T12:00:00.000Z","type":"event_msg","payload":{"type":"agent_message"}}"#.utf8)
        XCTAssertNil(CodexLocalSource.parseTokenCountLine(line))
        XCTAssertNil(CodexLocalSource.parseTokenCountLine(Data("not json\n".utf8)))
    }

    func testScanEmptyTreeThrowsNoData() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            _ = try await CodexLocalSource(root: root).scan()
            XCTFail("expected noData")
        } catch {
            XCTAssertEqual(error as? SourceUnavailable, .noData)
        }
    }

    func testScanMissingRootThrowsNoData() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-" + UUID().uuidString)

        do {
            _ = try await CodexLocalSource(root: missing).scan()
            XCTFail("expected noData")
        } catch {
            XCTAssertEqual(error as? SourceUnavailable, .noData)
        }
    }

    /// A file whose first line cannot be parsed falls back to its modification
    /// date, so a malformed rollout never silently drops a session.
    func testUnparseableFirstLineFallsBackToModificationDate() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("rollout-unreadable.jsonl")
        try Data("not json at all\n".utf8).write(to: fileURL)
        let mtime = Self.day(2026, 8, 15).addingTimeInterval(12 * 3600)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: fileURL.path)

        let day = try XCTUnwrap(CodexLocalSource.sessionDay(for: fileURL))
        XCTAssertEqual(day, Self.day(2026, 8, 15))
    }

    // MARK: - Heatmap intensity

    /// The heatmap shades by sessions so a session-only metric renders even
    /// when every token figure is zero — the generic model property this
    /// asserts, independent of what any one source reports today.
    func testHeatmapShadesBySessionsWhenTokensAbsent() {
        let now = Date()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let daily = [
            DailyActivity(day: yesterday, tokens: TokenTotals(), estimatedCostUSD: 0, sessionCount: 5),
            DailyActivity(day: today, tokens: TokenTotals(), estimatedCostUSD: 0, sessionCount: 1)
        ]

        let tokenScaled = HeatmapView.Model(daily: daily, today: now, weeks: 26)
        let tokenPeak = tokenScaled.columns.flatMap { $0 }.compactMap { $0?.intensity }.max() ?? 0
        XCTAssertEqual(tokenPeak, 0, "zero tokens everywhere must not shade any cell")

        let sessionScaled = HeatmapView.Model(daily: daily, today: now, weeks: 26, intensity: .sessions)
        let intensities = sessionScaled.columns.flatMap { $0 }.compactMap { $0?.intensity }
        XCTAssertEqual(intensities.max() ?? 0, 1, accuracy: 0.0001, "busiest day is the peak")
        XCTAssertTrue(intensities.contains { $0 > 0 }, "session metric must produce shaded cells")
    }

    // MARK: - Aggregation modes

    private func cell(_ date: Date, in model: HeatmapView.Model) -> HeatmapView.Model.Cell? {
        model.columns.flatMap { $0 }.compactMap { $0 }.first { $0.date == date }
    }

    /// A fixed mid-week anchor instead of the real clock. The model nils out
    /// cells after `today`, so a live `Date()` made these tests fail every
    /// Monday and Sunday: the "tuesday" cell was genuinely in the future and
    /// therefore absent from the grid.
    private func anchorWeekday(_ offsetFromMonday: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        // Wednesday, Aug 12 2026 at noon local — mid-week and mid-day, so
        // neither the DST edge nor the week start can move it.
        let anchor = calendar.date(from: DateComponents(year: 2026, month: 8, day: 12, hour: 12))!
        let daysBackToMonday = (calendar.component(.weekday, from: anchor) - 2 + 7) % 7
        let monday = calendar.date(byAdding: .day, value: -daysBackToMonday, to: anchor)!
        // The model's cells sit at local midnight; noon must not leak in.
        return calendar.startOfDay(for: calendar.date(byAdding: .day, value: offsetFromMonday, to: monday)!)
    }

    func testWeeklyModeShadesWholeWeekWithWeekTotal() {
        let monday = anchorWeekday(0)
        let tuesday = anchorWeekday(1)
        let daily = [
            DailyActivity(day: monday, tokens: TokenTotals(input: 100), estimatedCostUSD: 0, sessionCount: 1),
            DailyActivity(day: tuesday, tokens: TokenTotals(input: 200), estimatedCostUSD: 0, sessionCount: 1)
        ]

        let model = HeatmapView.Model(daily: daily, today: anchorWeekday(6), weeks: 26, mode: .weekly)

        let mondayCell = try! XCTUnwrap(cell(monday, in: model))
        let tuesdayCell = try! XCTUnwrap(cell(tuesday, in: model))
        XCTAssertEqual(mondayCell.tokens, 300, "Monday carries the week's combined total")
        XCTAssertEqual(tuesdayCell.tokens, 300)
        XCTAssertEqual(
            mondayCell.intensity, tuesdayCell.intensity, accuracy: 0.0001,
            "every day in a week is shaded by the same weekly total"
        )
        XCTAssertGreaterThan(mondayCell.intensity, 0)
    }

    func testCumulativeModeAccumulatesToPeak() {
        let monday = anchorWeekday(0)
        let tuesday = anchorWeekday(1)
        let daily = [
            DailyActivity(day: monday, tokens: TokenTotals(input: 100), estimatedCostUSD: 0, sessionCount: 1),
            DailyActivity(day: tuesday, tokens: TokenTotals(input: 200), estimatedCostUSD: 0, sessionCount: 1)
        ]

        let model = HeatmapView.Model(daily: daily, today: anchorWeekday(6), weeks: 26, mode: .cumulative)

        let mondayCell = try! XCTUnwrap(cell(monday, in: model))
        let tuesdayCell = try! XCTUnwrap(cell(tuesday, in: model))
        XCTAssertEqual(mondayCell.tokens, 100)
        XCTAssertEqual(tuesdayCell.tokens, 300, "running total up to and including the day")
        XCTAssertEqual(mondayCell.intensity, 100.0 / 300.0, accuracy: 0.0001)
        XCTAssertEqual(tuesdayCell.intensity, 1.0, accuracy: 0.0001, "the final day is the cumulative peak")
    }
}
