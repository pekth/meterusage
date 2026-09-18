import XCTest
@testable import MeterUsage

/// The pace-honesty rules: a deficit whose burn has gone quiet is the
/// window's past, not a present-tense "burning fast". Regression root: the
/// popover nudged "Codex burning fast. Switch to Grok, OpenCode Go for
/// headroom." while the same card read "no sessions today" — one burst early
/// in the weekly window held the deficit for days.
final class BurnRecencyTests: XCTestCase {

    // MARK: - BurnRecency

    func testLastBurnTakesTheMostRecentActivityClose() {
        let now = Date()
        let sessions = [
            session(start: now.addingTimeInterval(-7_200), last: now.addingTimeInterval(-5_400)),
            session(start: now.addingTimeInterval(-900), last: nil),
            session(start: now.addingTimeInterval(-3_600), last: now.addingTimeInterval(-60)),
        ]
        XCTAssertEqual(BurnRecency.lastBurn(of: sessions), now.addingTimeInterval(-60))
        XCTAssertNil(BurnRecency.lastBurn(of: []))
    }

    func testActiveBurnWindow() {
        let now = Date()
        XCTAssertTrue(BurnRecency.isActive(lastBurn: now.addingTimeInterval(-29 * 60), now: now))
        XCTAssertFalse(BurnRecency.isActive(lastBurn: now.addingTimeInterval(-31 * 60), now: now))
        // No session store, no burn evidence, no pace claims.
        XCTAssertFalse(BurnRecency.isActive(lastBurn: nil, now: now))
        // A future timestamp (clock skew, synthetic fixtures) cannot
        // evidence burning now.
        XCTAssertFalse(BurnRecency.isActive(lastBurn: now.addingTimeInterval(60), now: now))
    }

    func testLastBurnsMapSkipsProvidersWithoutSessions() {
        let now = Date()
        let activities: [Provider: Loaded<LocalActivity>] = [
            .codex: .value(LocalActivity(
                provider: .codex,
                sessions: [session(start: now.addingTimeInterval(-600), last: nil)],
                daily: [],
                scannedAt: now)),
            .claude: .value(LocalActivity(provider: .claude, sessions: [], daily: [], scannedAt: now)),
        ]
        XCTAssertEqual(Set(BurnRecency.lastBurns(from: activities).keys), [.codex])
    }

    // MARK: - Effective pace (the reported regression)

    func testStaleWeeklyDeficitDemotesToOnPace() throws {
        // A burst on day one holds usedPercent ahead of the elapsed fraction
        // until reset; with the burn a day gone, every surface must read the
        // demoted pace, and state figures must pass through untouched.
        let now = Date()
        let window = weekly(85, elapsedDays: 4, now: now)
        let raw = try XCTUnwrap(window.pace(now: now))
        XCTAssertTrue(raw.status.isDeficit, "the window shape alone still looks ahead of pace")

        let pace = raw.effective(lastBurn: now.addingTimeInterval(-86_400), now: now)
        XCTAssertFalse(pace.status.isDeficit)
        XCTAssertEqual(pace.status.text, "on pace")
        XCTAssertEqual(pace.burnRate, 1.0, accuracy: 0.001)
        XCTAssertNil(pace.projectedExhaustion)
        XCTAssertEqual(pace.usedPercent, 85)
        XCTAssertEqual(pace.remainingPercent, 15)
    }

    func testFreshBurnKeepsTheDeficit() throws {
        let now = Date()
        let window = weekly(30, elapsedDays: 1, now: now)
        let pace = try XCTUnwrap(window.pace(now: now))
            .effective(lastBurn: now.addingTimeInterval(-5 * 60), now: now)
        XCTAssertTrue(pace.status.isDeficit)
        XCTAssertEqual(pace.status.text, "burning fast")
    }

    func testSurplusPassesThroughWithoutBurnEvidence() throws {
        let now = Date()
        let window = weekly(20, elapsedDays: 5, now: now)
        let pace = try XCTUnwrap(window.pace(now: now)).effective(lastBurn: nil, now: now)
        XCTAssertTrue(pace.status.isSurplus)
        XCTAssertEqual(pace.status.text, "well paced")
    }

    func testExhaustedWindowKeepsResetCountdownWhenQuiet() throws {
        // Demotion must not silence the ambient surfaces exactly when the
        // limit is hit: the honest ETA is the reset countdown.
        let now = Date()
        let window = QuotaWindow(
            label: "5-hour limit",
            usedPercent: 100.0,
            resetsAt: now.addingTimeInterval(6_900),
            windowDurationMins: 300
        )
        let pace = try XCTUnwrap(window.pace(now: now))
            .effective(lastBurn: now.addingTimeInterval(-2 * 3_600), now: now)
        XCTAssertEqual(pace.statusText(usedPercent: window.usedPercent), "exhausted early")
        XCTAssertEqual(pace.etaInterval(resetsAt: window.resetsAt, now: now) ?? 0, 6_900, accuracy: 5)
        XCTAssertNotNil(pace.etaText(resetsAt: window.resetsAt, now: now))
    }

    // MARK: - FailoverNudge

    func testNudgeStaysSilentForStaleDeficitBelowNearLimit() {
        // The exact reported failure: a weekly deficit with no current burn
        // and no near-limit window must not nag the user to switch.
        let now = Date()
        let nudge = FailoverNudge.evaluate(
            providers: [.codex, .grok],
            headline: { p in
                p == .codex ? weekly(60, elapsedDays: 3, now: now) : weekly(10, elapsedDays: 3, now: now)
            },
            lastBurn: { $0 == .codex ? now.addingTimeInterval(-86_400) : nil },
            now: now
        )
        XCTAssertNil(nudge.message)
    }

    func testNudgeReportsNearLimitForHighUsageWithoutCurrentBurn() {
        let now = Date()
        let nudge = FailoverNudge.evaluate(
            providers: [.codex, .grok],
            headline: { p in
                p == .codex ? weekly(85, elapsedDays: 4, now: now) : weekly(10, elapsedDays: 3, now: now)
            },
            lastBurn: { $0 == .codex ? now.addingTimeInterval(-86_400) : nil },
            now: now
        )
        XCTAssertEqual(
            nudge.message,
            "Codex near its weekly limit. Switch to Grok for headroom.")
        XCTAssertEqual(
            nudge.accessibilityLabel,
            "Codex near its weekly limit. Headroom in Grok.")
    }

    func testNudgeKeepsBurningFastWhenBurnIsCurrent() {
        let now = Date()
        let nudge = FailoverNudge.evaluate(
            providers: [.codex, .grok],
            headline: { p in
                p == .codex ? weekly(30, elapsedDays: 1, now: now) : weekly(10, elapsedDays: 3, now: now)
            },
            lastBurn: { $0 == .codex ? now.addingTimeInterval(-5 * 60) : nil },
            now: now
        )
        XCTAssertEqual(
            nudge.message,
            "Codex burning fast. Switch to Grok for headroom.")
    }

    func testActivelyBurningOutranksNearLimit() {
        let now = Date()
        let nudge = FailoverNudge.evaluate(
            providers: [.codex, .claude, .grok],
            headline: { p in
                switch p {
                case .codex: return weekly(85, elapsedDays: 4, now: now)
                case .claude: return weekly(60, elapsedDays: 2, now: now)
                default: return weekly(10, elapsedDays: 3, now: now)
                }
            },
            lastBurn: { $0 == .claude ? now.addingTimeInterval(-5 * 60) : nil },
            now: now
        )
        XCTAssertEqual(
            nudge.message,
            "Claude burning fast. Switch to Grok for headroom.")
    }

    func testNudgeNeverSuggestsAHotProvider() {
        let now = Date()
        let nudge = FailoverNudge.evaluate(
            providers: [.codex, .grok],
            headline: { p in
                switch p {
                case .codex: return weekly(85, elapsedDays: 4, now: now)
                case .grok: return weekly(40, elapsedDays: 1, now: now)
                default: return nil
                }
            },
            lastBurn: { $0 == .grok ? now.addingTimeInterval(-5 * 60) : nil },
            now: now
        )
        // Codex is near its limit and Grok is actively burning; there is
        // nowhere honest to suggest switching to.
        XCTAssertNil(nudge.message)
    }

    // MARK: - Helpers

    private func weekly(_ percent: Double, elapsedDays: Double, now: Date) -> QuotaWindow {
        QuotaWindow(
            label: "Weekly",
            usedPercent: percent,
            resetsAt: now.addingTimeInterval((7 - elapsedDays) * 86_400),
            windowDurationMins: 10_080
        )
    }

    private func session(start: Date, last: Date?) -> SessionSummary {
        SessionSummary(
            id: UUID().uuidString,
            projectName: "project",
            model: "model",
            tokens: TokenTotals(),
            estimatedCostUSD: 0,
            startedAt: start,
            lastActivityAt: last,
            messageCount: 0
        )
    }
}
