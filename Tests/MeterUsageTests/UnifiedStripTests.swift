import XCTest
@testable import MeterUsage

/// Contract for the "ALL AI CODING TODAY" strip.
///
/// `LocalActivity.daily` buckets are UTC-midnight days, so no UTC/local day
/// comparison can define "today" correctly at all hours: a local compare
/// misses the whole day west of UTC, and a UTC compare misses every evening
/// after 20:00 EDT (00:00 UTC). The strip therefore derives TODAY from
/// session start instants against local midnight, which is unambiguous in
/// any time zone. The 7-day WEEK still sums the UTC day buckets, where an
/// hour-scale boundary difference is immaterial.
final class UnifiedStripTests: XCTestCase {

    private static var newYork: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        return cal
    }

    private static var utc: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal
    }

    private static func utcInstant(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        utc.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private static func utcDay(_ year: Int, _ month: Int, _ day: Int) -> Date {
        utc.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private static let sessionTokens = TokenTotals(input: 50_000, output: 1_000, reasoning: 500, cacheRead: 100_000)

    /// A Codex-shaped afternoon: sessions started 15:17 EDT Sep 16 carrying
    /// 151,500 tokens, plus the UTC Sep-16 day bucket holding the same burn.
    /// The bucket alone must never zero out the day the sessions prove.
    private func afternoonActivity() -> [LocalActivity] {
        let session = SessionSummary(
            id: "synthetic-session",
            projectName: "synthetic",
            model: "codex",
            tokens: Self.sessionTokens,
            estimatedCostUSD: 0,
            startedAt: Self.utcInstant(2026, 9, 16, 19, 17),
            messageCount: 12
        )
        let bucket = DailyActivity(
            day: Self.utcDay(2026, 9, 16),
            tokens: Self.sessionTokens,
            estimatedCostUSD: 0,
            sessionCount: 1
        )
        return [LocalActivity(provider: .codex, sessions: [session], daily: [bucket], scannedAt: Self.utcInstant(2026, 9, 16, 19, 32))]
    }

    /// Afternoon case from the original report: 15:32 EDT Sep 16. The old
    /// local-day bucket compare read 0 here; the sessions prove 151,500.
    func testAfternoonSessionsCountTowardToday() {
        let totals = StripTotals.calculate(
            activities: afternoonActivity(),
            usages: [],
            now: Self.utcInstant(2026, 9, 16, 19, 32),
            calendar: Self.newYork
        )

        XCTAssertEqual(totals.todayTokens, 151_500)
        XCTAssertEqual(totals.weekTokens, 151_500)
    }

    /// Evening case that defeated the UTC-bucket comparison: 22:12 EDT Sep
    /// 16 is already Sep 17 in UTC, so no UTC-day compare can match. The
    /// sessions started that local evening and must still count.
    func testEveningSessionsCountTowardToday() {
        let totals = StripTotals.calculate(
            activities: afternoonActivity(),
            usages: [],
            now: Self.utcInstant(2026, 9, 17, 2, 12),
            calendar: Self.newYork
        )

        XCTAssertEqual(totals.todayTokens, 151_500)
        XCTAssertEqual(totals.weekTokens, 151_500)
    }

    /// Sessions from 8 days ago stay out of both windows: the repair must
    /// count today's sessions, not every session.
    func testStaleSessionsStayOutOfBothWindows() {
        let stale = SessionSummary(
            id: "synthetic-stale",
            projectName: "synthetic",
            model: "codex",
            tokens: TokenTotals(input: 10_000, output: 1_000),
            estimatedCostUSD: 0,
            startedAt: Self.utcInstant(2026, 9, 8, 19, 0),
            messageCount: 5
        )
        let staleBucket = DailyActivity(
            day: Self.utcDay(2026, 9, 8),
            tokens: TokenTotals(input: 10_000, output: 1_000),
            estimatedCostUSD: 0,
            sessionCount: 1
        )
        let activities = [LocalActivity(
            provider: .codex,
            sessions: [stale],
            daily: [staleBucket],
            scannedAt: Self.utcInstant(2026, 9, 16, 19, 32)
        )]

        let totals = StripTotals.calculate(
            activities: activities,
            usages: [],
            now: Self.utcInstant(2026, 9, 16, 19, 32),
            calendar: Self.newYork
        )

        XCTAssertEqual(totals.todayTokens, 0)
        XCTAssertEqual(totals.weekTokens, 0)
    }

    // MARK: - Time-zone matrix

    private static var sydney: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Australia/Sydney")!
        return cal
    }

    /// East of UTC: 00:30 local Sep 17 in Sydney is still Sep 16 in UTC, so
    /// the UTC bucket names the wrong day. Session instants count it anyway.
    func testSydneyEarlyMorningSessionCountsTowardLocalToday() {
        let session = SessionSummary(
            id: "synthetic-sydney",
            projectName: "synthetic",
            model: "codex",
            tokens: Self.sessionTokens,
            estimatedCostUSD: 0,
            startedAt: Self.utcInstant(2026, 9, 16, 14, 30),
            messageCount: 8
        )
        let bucket = DailyActivity(
            day: Self.utcDay(2026, 9, 16),
            tokens: Self.sessionTokens,
            estimatedCostUSD: 0,
            sessionCount: 1
        )
        let activities = [LocalActivity(
            provider: .codex,
            sessions: [session],
            daily: [bucket],
            scannedAt: Self.utcInstant(2026, 9, 16, 15, 0)
        )]

        let totals = StripTotals.calculate(
            activities: activities,
            usages: [],
            now: Self.utcInstant(2026, 9, 16, 15, 0),
            calendar: Self.sydney
        )

        XCTAssertEqual(totals.todayTokens, 151_500)
    }

    /// On UTC itself the session instant and the bucket agree; both windows
    /// count the session.
    func testUTCMidnightHourSessionCountsTowardToday() {
        let session = SessionSummary(
            id: "synthetic-utc",
            projectName: "synthetic",
            model: "codex",
            tokens: Self.sessionTokens,
            estimatedCostUSD: 0,
            startedAt: Self.utcInstant(2026, 9, 16, 0, 30),
            messageCount: 8
        )
        let activities = [LocalActivity(
            provider: .codex,
            sessions: [session],
            daily: [],
            scannedAt: Self.utcInstant(2026, 9, 16, 23, 0)
        )]

        let totals = StripTotals.calculate(
            activities: activities,
            usages: [],
            now: Self.utcInstant(2026, 9, 16, 23, 0),
            calendar: Self.utc
        )

        XCTAssertEqual(totals.todayTokens, 151_500)
        XCTAssertEqual(totals.weekTokens, 151_500)
    }

    /// Pinned approximation: today means started-today. A session started at
    /// 23:50 yesterday and worked past midnight belongs to yesterday, even
    /// when read after midnight.
    func testSessionStartedYesterdayStaysYesterday() {
        let session = SessionSummary(
            id: "synthetic-crossover",
            projectName: "synthetic",
            model: "codex",
            tokens: Self.sessionTokens,
            estimatedCostUSD: 0,
            startedAt: Self.utcInstant(2026, 9, 16, 3, 50),
            messageCount: 8
        )
        let activities = [LocalActivity(
            provider: .codex,
            sessions: [session],
            daily: [],
            scannedAt: Self.utcInstant(2026, 9, 16, 4, 10)
        )]

        let totals = StripTotals.calculate(
            activities: activities,
            usages: [],
            now: Self.utcInstant(2026, 9, 16, 4, 10),
            calendar: Self.newYork
        )

        XCTAssertEqual(totals.todayTokens, 0)
        XCTAssertEqual(totals.weekTokens, 151_500)
    }
}
