import XCTest
@testable import MeterUsage

final class TelemetryAndPacingTests: XCTestCase {

    func testQuotaPaceDeficit() {
        // Weekly window (10,080 mins = 604,800 sec)
        // Elapsed: 1 day out of 7 = 14.28% elapsed
        // Used: 30%
        // Expected usage: ~14.28%
        // Deficit: burning fast (amber)
        let now = Date()
        let resetsAt = now.addingTimeInterval(6 * 86_400) // 1 day elapsed
        let window = QuotaWindow(
            label: "Weekly",
            usedPercent: 30.0,
            resetsAt: resetsAt,
            windowDurationMins: 10_080
        )

        let pace = window.pace(now: now)
        XCTAssertNotNil(pace)
        guard let pace else { return }

        XCTAssertEqual(pace.usedPercent, 30.0, accuracy: 0.1)
        XCTAssertEqual(pace.remainingPercent, 70.0, accuracy: 0.1)
        XCTAssertTrue(pace.status.isDeficit)
        XCTAssertFalse(pace.status.isSurplus)
        XCTAssertEqual(pace.status.text, "burning fast")
        XCTAssertEqual(pace.statusText(usedPercent: window.usedPercent), "burning fast")
    }

    func testQuotaPaceSurplus() {
        // Weekly window
        // Elapsed: 5 days out of 7 = 71.4% elapsed
        // Used: 20%
        // Expected usage: ~71.4%
        // Surplus: well paced (green)
        let now = Date()
        let resetsAt = now.addingTimeInterval(2 * 86_400)
        let window = QuotaWindow(
            label: "Weekly",
            usedPercent: 20.0,
            resetsAt: resetsAt,
            windowDurationMins: 10_080
        )

        let pace = window.pace(now: now)
        XCTAssertNotNil(pace)
        guard let pace else { return }

        XCTAssertTrue(pace.status.isSurplus)
        XCTAssertFalse(pace.status.isDeficit)
        XCTAssertEqual(pace.status.text, "well paced")
        XCTAssertEqual(pace.statusText(usedPercent: window.usedPercent), "well paced")
    }

    func testQuotaPaceExhaustedEarly() {
        let now = Date()
        let resetsAt = now.addingTimeInterval(3.5 * 86_400)
        let window = QuotaWindow(
            label: "Weekly",
            usedPercent: 100.0,
            resetsAt: resetsAt,
            windowDurationMins: 10_080
        )

        let pace = window.pace(now: now)
        XCTAssertNotNil(pace)
        guard let pace else { return }

        XCTAssertEqual(pace.statusText(usedPercent: window.usedPercent), "exhausted early")
    }

    func testQuotaPaceOnPace() {
        // Window 50% elapsed, 51% used -> within 2% threshold
        let now = Date()
        let resetsAt = now.addingTimeInterval(3.5 * 86_400)
        let window = QuotaWindow(
            label: "Weekly",
            usedPercent: 51.0,
            resetsAt: resetsAt,
            windowDurationMins: 10_080
        )

        let pace = window.pace(now: now)
        XCTAssertNotNil(pace)
        guard let pace else { return }

        XCTAssertFalse(pace.status.isDeficit)
        XCTAssertFalse(pace.status.isSurplus)
        XCTAssertEqual(pace.status.text, "on pace")
        XCTAssertEqual(pace.statusText(usedPercent: window.usedPercent), "on pace")
    }

    func testInferredWindowDuration() {
        let weekly = QuotaWindow(label: "Weekly limit", usedPercent: 10)
        XCTAssertEqual(weekly.effectiveDurationMins, 10_080)

        let session = QuotaWindow(label: "5-hour session", usedPercent: 10)
        XCTAssertEqual(session.effectiveDurationMins, 300)

        let monthly = QuotaWindow(label: "Monthly quota", usedPercent: 10)
        XCTAssertEqual(monthly.effectiveDurationMins, 43_200)

        let rolling = QuotaWindow(label: "Rolling 24h", usedPercent: 10)
        XCTAssertEqual(rolling.effectiveDurationMins, 1_440)
    }

    func testTelemetryCalculatorStreaksAndHistory() {
        let calendar = Calendar.current
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)

        // Generate sessions for today, yesterday, and day before yesterday (3-day streak)
        let d0 = startOfToday.addingTimeInterval(3600) // today
        let d1 = calendar.date(byAdding: .day, value: -1, to: startOfToday)!.addingTimeInterval(3600) // yesterday
        let d2 = calendar.date(byAdding: .day, value: -2, to: startOfToday)!.addingTimeInterval(3600) // 2 days ago

        let sessions = [
            TelemetrySessionItem(startedAt: d0, endedAt: d0.addingTimeInterval(7200), tokens: 1_000_000, messageCount: 20),
            TelemetrySessionItem(startedAt: d1, endedAt: d1.addingTimeInterval(3600), tokens: 2_000_000, messageCount: 30),
            TelemetrySessionItem(startedAt: d2, endedAt: d2.addingTimeInterval(1800), tokens: 500_000, messageCount: 10)
        ]

        let telemetry = TelemetryCalculator.calculate(sessions: sessions, calendar: calendar, now: now)

        XCTAssertEqual(telemetry.lifetimeTokens, 3_500_000)
        XCTAssertEqual(telemetry.todayTokens, 1_000_000)
        XCTAssertEqual(telemetry.peakDailyTokens, 2_000_000)
        XCTAssertEqual(telemetry.longestChatSeconds, 7200)
        XCTAssertEqual(telemetry.currentStreakDays, 3)
        XCTAssertEqual(telemetry.longestStreakDays, 3)
        XCTAssertEqual(telemetry.totalSessions, 3)
        XCTAssertEqual(telemetry.totalMessages, 60)
        XCTAssertEqual(telemetry.todaySessions, 1)
        XCTAssertEqual(telemetry.todayMessages, 20)
        XCTAssertEqual(telemetry.dailyHistory.count, 30)

        // Today's point is the last element
        let todayPoint = telemetry.dailyHistory.last!
        XCTAssertEqual(todayPoint.tokens, 1_000_000)
        XCTAssertEqual(todayPoint.sessionCount, 1)
    }

    func testTelemetryTokensFormatting() {
        XCTAssertEqual(Fmt.telemetryTokens(60_000_000_000), "60.00B")
        XCTAssertEqual(Fmt.telemetryTokens(1_690_000_000), "1.69B")
        XCTAssertEqual(Fmt.telemetryTokens(399_300_000), "399.3M")
        XCTAssertEqual(Fmt.telemetryTokens(45_200), "45.2K")
        XCTAssertEqual(Fmt.telemetryTokens(500), "500")

        XCTAssertEqual(Fmt.durationHMin(24 * 3600 + 23 * 60), "24h 23m")
        XCTAssertEqual(Fmt.durationHMin(45 * 60), "45m")
        XCTAssertEqual(Fmt.durationHMin(30), "30s")

        XCTAssertEqual(Fmt.streakDays(3), "3d")
        XCTAssertEqual(Fmt.streakDays(132), "132d")
    }

    @MainActor func testPreferencesPacingAndTelemetryDefaults() {
        let suiteName = "test.telemetry.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let prefs = Preferences(defaults: defaults)

        XCTAssertTrue(prefs.showPacingBurnRate)
        XCTAssertTrue(prefs.showActivityTelemetry)
        XCTAssertTrue(prefs.showDailyActivityChart)
    }
}
