import XCTest
@testable import MeterUsage

/// Regression tests for the "ALL AI CODING TODAY" strip's day-boundary math.
///
/// `LocalActivity.daily` buckets are UTC-midnight days (Codex and Claude
/// group by UTC for determinism). The strip must compare those buckets in
/// UTC: comparing them with the local calendar shifts every bucket that
/// falls before the local UTC offset onto the previous local day, so a day
/// with real activity renders as "0 / no sessions today" while "last 7
/// days" still shows the tokens.
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

    /// 2026-09-16 15:32 EDT == 19:32 UTC, mirroring the reported screenshot:
    /// Codex sessions ran that afternoon, all inside UTC Sep 16.
    private static var afternoonNow: Date {
        utc.date(from: DateComponents(year: 2026, month: 9, day: 16, hour: 19, minute: 32))!
    }

    private static func utcDay(_ year: Int, _ month: Int, _ day: Int) -> Date {
        utc.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func activity(days: [DailyActivity]) -> [LocalActivity] {
        [LocalActivity(provider: .codex, sessions: [], daily: days, scannedAt: Self.afternoonNow)]
    }

    /// A UTC Sep-16 bucket holding the day's Codex burn must count toward
    /// "today" when the local clock is the afternoon of Sep 16.
    func testUTCDayBucketCountsTowardLocalToday() {
        let bucket = DailyActivity(
            day: Self.utcDay(2026, 9, 16),
            tokens: TokenTotals(input: 50_000, output: 1_000, reasoning: 500, cacheRead: 100_000),
            estimatedCostUSD: 0,
            sessionCount: 4
        )

        let totals = StripTotals.calculate(
            activities: activity(days: [bucket]),
            usages: [],
            now: Self.afternoonNow,
            calendar: Self.newYork
        )

        XCTAssertEqual(totals.todayTokens, 151_500)
        XCTAssertEqual(totals.weekTokens, 151_500)
    }

    /// A bucket 8 UTC days back is outside the 7-day window and must stay
    /// out after the fix — the repair must not turn into "count everything".
    func testStaleBucketStaysOutOfWeekWindow() {
        let stale = DailyActivity(
            day: Self.utcDay(2026, 9, 8),
            tokens: TokenTotals(input: 10_000, output: 1_000),
            estimatedCostUSD: 0,
            sessionCount: 1
        )
        let fresh = DailyActivity(
            day: Self.utcDay(2026, 9, 16),
            tokens: TokenTotals(input: 5_000, output: 500),
            estimatedCostUSD: 0,
            sessionCount: 1
        )

        let totals = StripTotals.calculate(
            activities: activity(days: [stale, fresh]),
            usages: [],
            now: Self.afternoonNow,
            calendar: Self.newYork
        )

        XCTAssertEqual(totals.todayTokens, 5_500)
        XCTAssertEqual(totals.weekTokens, 5_500)
    }
}
