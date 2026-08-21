import XCTest
@testable import MeterUsage

final class QuotaAlertsTests: XCTestCase {

    // MARK: - Threshold crossings

    @MainActor
    func testCrossingWarningFiresOnce() {
        var evaluator = QuotaAlertEvaluator()
        let now = Date()

        let at79 = quota(percent: 79)
        XCTAssertTrue(evaluator.events(for: [.codex: .value(at79)], now: now).isEmpty)

        let at82 = quota(percent: 82)
        let first = evaluator.events(for: [.codex: .value(at82)], now: now)
        XCTAssertEqual(first.count, 1)
        guard case .threshold(let provider, let label, let percent, let threshold) = first[0] else {
            return XCTFail("expected a threshold event")
        }
        XCTAssertEqual(provider, .codex)
        XCTAssertEqual(label, "Weekly")
        XCTAssertEqual(percent, 82)
        XCTAssertEqual(threshold, .warning)

        // Staying above the threshold must not re-fire.
        XCTAssertTrue(evaluator.events(for: [.codex: .value(quota(percent: 90))], now: now).isEmpty)
    }

    @MainActor
    func testJumpPastBothThresholdsFiresOnlyTheCritical() {
        var evaluator = QuotaAlertEvaluator()
        let now = Date()

        let events = evaluator.events(for: [.codex: .value(quota(percent: 96))], now: now)
        XCTAssertEqual(events.count, 1)
        guard case .threshold(_, _, _, let threshold) = events[0] else {
            return XCTFail("expected a threshold event")
        }
        XCTAssertEqual(threshold, .critical)
    }

    @MainActor
    func testDropBelowReArmsTheLadder() {
        var evaluator = QuotaAlertEvaluator()
        let now = Date()

        _ = evaluator.events(for: [.codex: .value(quota(percent: 82))], now: now)
        // Window resets back to near zero; the ladder re-arms.
        XCTAssertTrue(evaluator.events(for: [.codex: .value(quota(percent: 10))], now: now).isEmpty)
        // A fresh climb past a threshold fires again.
        let afterReset = evaluator.events(for: [.codex: .value(quota(percent: 85))], now: now)
        XCTAssertEqual(afterReset.count, 1)
    }

    @MainActor
    func testMissingProviderKeepsHighWaterMark() {
        var evaluator = QuotaAlertEvaluator()
        let now = Date()
        _ = evaluator.events(for: [.codex: .value(quota(percent: 82))], now: now)
        // Next sweep the provider is absent (backed off); must not clear state.
        let events = evaluator.events(for: [:], now: now)
        XCTAssertTrue(events.isEmpty)
    }

    // MARK: - Expiring reset credits

    @MainActor
    func testExpiringCreditFiresOnce() {
        var evaluator = QuotaAlertEvaluator()
        let now = Date()
        let credit = QuotaResetCredit(
            id: "credit-1",
            title: "Weekly reset",
            status: "available",
            expiresAt: now.addingTimeInterval(12 * 3600)
        )

        let state = Loaded<ProviderQuota>.value(
            ProviderQuota(provider: .codex, windows: [], resetCreditCount: 1, resetCredits: [credit], capturedAt: now)
        )
        let first = evaluator.events(for: [.codex: state], now: now)
        XCTAssertEqual(first.count, 1)
        guard case .expiringCredit = first[0] else {
            return XCTFail("expected an expiring-credit event")
        }
        XCTAssertTrue(evaluator.events(for: [.codex: state], now: now).isEmpty)
    }

    @MainActor
    func testCreditExpiringOutsideWindowIsSilent() {
        var evaluator = QuotaAlertEvaluator()
        let now = Date()
        let credit = QuotaResetCredit(id: "c", title: "Weekly reset", expiresAt: now.addingTimeInterval(72 * 3600))
        let state = Loaded<ProviderQuota>.value(
            ProviderQuota(provider: .codex, windows: [], resetCreditCount: 1, resetCredits: [credit], capturedAt: now)
        )
        XCTAssertTrue(evaluator.events(for: [.codex: state], now: now).isEmpty)
    }

    // MARK: - Backoff delay

    func testBackoffDelayDoublesAndCaps() {
        XCTAssertEqual(AppCoordinator.backoffDelay(afterFailures: 1), 60)
        XCTAssertEqual(AppCoordinator.backoffDelay(afterFailures: 2), 120)
        XCTAssertEqual(AppCoordinator.backoffDelay(afterFailures: 3), 240)
        XCTAssertEqual(AppCoordinator.backoffDelay(afterFailures: 10), 1800)
        XCTAssertEqual(AppCoordinator.backoffDelay(afterFailures: 100), 1800)
    }

    // MARK: - Pricing snapshot

    func testPricingSnapshotLabel() {
        XCTAssertEqual(Pricing.snapshotYearMonth, "2026-07")
        XCTAssertEqual(Pricing.snapshotLabel, "Jul 2026")
    }

    // MARK: - Sparkline model

    func testSparklineBucketsLastSevenDays() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let today = calendar.startOfDay(for: Date())
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let eightDaysAgo = calendar.date(byAdding: .day, value: -8, to: today)!

        let daily = [
            DailyActivity(day: today, tokens: .init(input: 500), estimatedCostUSD: 0, sessionCount: 5),
            DailyActivity(day: yesterday, tokens: .init(input: 200), estimatedCostUSD: 0, sessionCount: 2),
            // Outside the window; must not appear.
            DailyActivity(day: eightDaysAgo, tokens: .init(input: 9000), estimatedCostUSD: 0, sessionCount: 90)
        ]
        let model = SparklineView.Model(daily: daily, today: today, intensity: .tokens)
        XCTAssertEqual(model.bars.count, 7)
        XCTAssertEqual(model.peak, 500)
        XCTAssertEqual(model.windowTokens, 700)
        XCTAssertEqual(model.windowSessions, 7)
        XCTAssertEqual(model.bars.map(\.value).sorted(), [0, 0, 0, 0, 0, 200, 500])
    }

    func testSparklineSessionsIntensity() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let today = calendar.startOfDay(for: Date())
        let daily = [DailyActivity(day: today, tokens: .init(), estimatedCostUSD: 0, sessionCount: 12)]
        let model = SparklineView.Model(daily: daily, today: today, intensity: .sessions)
        XCTAssertEqual(model.peak, 12)
        XCTAssertEqual(model.bars.map(\.value), [0, 0, 0, 0, 0, 0, 12])
    }

    // MARK: - Diagnostics

    func testDiagnosticsReportShapeAndRedaction() {
        let report = DiagnosticsReport.build(
            appName: "MeterUsage",
            appVersion: "0.2.0",
            isDemoMode: false,
            refreshInterval: 60,
            lastRefreshedAt: Date(),
            now: Date(),
            enabledProviders: [.codex, .grok],
            quotas: [.codex: .missing(.failed(.codex))],
            activities: [:],
            usages: [:],
            statuses: [:],
            plans: [:]
        )

        XCTAssertTrue(report.contains("MeterUsage 0.2.0"))
        XCTAssertTrue(report.contains("mode: live"))
        XCTAssertTrue(report.contains("[codex]"))
        XCTAssertTrue(report.contains("quota: unavailable (failed)"))
        XCTAssertTrue(report.contains("[grok]"))
        // The privacy contract: no paths, no home directories, no slashes that
        // could smuggle a filesystem fragment into a pasted issue.
        XCTAssertFalse(report.contains("/Users"))
        XCTAssertFalse(report.contains(".."))
        XCTAssertFalse(report.contains("\n/"), report)
    }

    func testDiagnosticsReportMarksDemoMode() {
        let report = DiagnosticsReport.build(
            appName: "MeterUsage", appVersion: "0.2.0", isDemoMode: true,
            refreshInterval: 60, lastRefreshedAt: nil, now: Date(),
            enabledProviders: [.codex], quotas: [:], activities: [:],
            usages: [:], statuses: [:], plans: [:]
        )
        XCTAssertTrue(report.contains("mode: demo"))
        XCTAssertTrue(report.contains("last refresh: never"))
    }

    // MARK: - Helper

    private func quota(percent: Double) -> ProviderQuota {
        ProviderQuota(
            provider: .codex,
            windows: [QuotaWindow(label: "Weekly", usedPercent: percent, resetsAt: nil)],
            capturedAt: Date()
        )
    }
}