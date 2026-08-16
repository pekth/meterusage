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
    /// session start timestamp, the field the source actually reads.
    private func writeRollout(_ root: URL, name: String, timestamp: String) throws {
        let dir = root
            .appendingPathComponent("2026", isDirectory: true)
            .appendingPathComponent("08", isDirectory: true)
            .appendingPathComponent("11", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let line = #"{"timestamp":"\#(timestamp)","type":"session_meta"}"#
        try Data((line + "\n").utf8).write(to: dir.appendingPathComponent(name + ".jsonl"))
    }

    func testScanCountsSessionsPerDay() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeRollout(root, name: "rollout-2026-08-11T12-00-00-a", timestamp: "2026-08-11T12:00:00.000Z")
        try writeRollout(root, name: "rollout-2026-08-11T13-00-00-b", timestamp: "2026-08-11T13:00:00.000Z")
        try writeRollout(root, name: "rollout-2026-08-10T09-00-00-c", timestamp: "2026-08-10T09:00:00.000Z")

        let activity = try await CodexLocalSource(root: root).scan()

        XCTAssertEqual(activity.provider, .codex)
        XCTAssertEqual(activity.sessions.isEmpty, true, "session payloads are never read")
        XCTAssertEqual(activity.daily.count, 2)

        let day11 = try XCTUnwrap(activity.daily.first { $0.day == Self.day(2026, 8, 11) })
        XCTAssertEqual(day11.sessionCount, 2)
        XCTAssertEqual(day11.tokens.total, 0, "Codex sessions carry no token ledger")
        XCTAssertEqual(day11.estimatedCostUSD, 0)

        let day10 = try XCTUnwrap(activity.daily.first { $0.day == Self.day(2026, 8, 10) })
        XCTAssertEqual(day10.sessionCount, 1)
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

    /// Codex has no tokens anywhere; the heatmap must shade by sessions so a
    /// session-only source renders, rather than the token metric flattening
    /// every cell to empty.
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

    /// Two dates in the same week. Weekly mode shades every day of that week
    /// with the week's combined total.
    private func thisWeek(_ offsetFromMonday: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let today = calendar.startOfDay(for: Date())
        // Gregorian weekdays run Sunday(1)...Saturday(7); walk back to Monday.
        let daysBackToMonday = (calendar.component(.weekday, from: today) - 2 + 7) % 7
        let monday = calendar.date(byAdding: .day, value: -daysBackToMonday, to: today)!
        return calendar.date(byAdding: .day, value: offsetFromMonday, to: monday)!
    }

    private func cell(_ date: Date, in model: HeatmapView.Model) -> HeatmapView.Model.Cell? {
        model.columns.flatMap { $0 }.compactMap { $0 }.first { $0.date == date }
    }

    func testWeeklyModeShadesWholeWeekWithWeekTotal() {
        let monday = thisWeek(0)
        let tuesday = thisWeek(1)
        let daily = [
            DailyActivity(day: monday, tokens: TokenTotals(input: 100), estimatedCostUSD: 0, sessionCount: 1),
            DailyActivity(day: tuesday, tokens: TokenTotals(input: 200), estimatedCostUSD: 0, sessionCount: 1)
        ]

        let model = HeatmapView.Model(daily: daily, today: Date(), weeks: 26, mode: .weekly)

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
        let monday = thisWeek(0)
        let tuesday = thisWeek(1)
        let daily = [
            DailyActivity(day: monday, tokens: TokenTotals(input: 100), estimatedCostUSD: 0, sessionCount: 1),
            DailyActivity(day: tuesday, tokens: TokenTotals(input: 200), estimatedCostUSD: 0, sessionCount: 1)
        ]

        let model = HeatmapView.Model(daily: daily, today: Date(), weeks: 26, mode: .cumulative)

        let mondayCell = try! XCTUnwrap(cell(monday, in: model))
        let tuesdayCell = try! XCTUnwrap(cell(tuesday, in: model))
        XCTAssertEqual(mondayCell.tokens, 100)
        XCTAssertEqual(tuesdayCell.tokens, 300, "running total up to and including the day")
        XCTAssertEqual(mondayCell.intensity, 100.0 / 300.0, accuracy: 0.0001)
        XCTAssertEqual(tuesdayCell.intensity, 1.0, accuracy: 0.0001, "the final day is the cumulative peak")
    }
}
