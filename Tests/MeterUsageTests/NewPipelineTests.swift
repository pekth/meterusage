import XCTest
@testable import MeterUsage

final class NewPipelineTests: XCTestCase {

    func testBurnAttributionAndWasteHints() {
        let now = Date()
        let sessions = [
            SessionSummary(
                id: "sess-1",
                projectName: "meterusage",
                model: "claude-3-7-sonnet",
                tokens: TokenTotals(input: 10000, output: 2000, reasoning: 0, cacheRead: 30000, cacheWrite: 5000),
                estimatedCostUSD: 0.15,
                startedAt: now.addingTimeInterval(-1800),
                messageCount: 25
            ),
            SessionSummary(
                id: "sess-2",
                projectName: "web-ui",
                model: "claude-3-5-haiku",
                tokens: TokenTotals(input: 5000, output: 1000, reasoning: 0, cacheRead: 5000, cacheWrite: 1000),
                estimatedCostUSD: 0.03,
                startedAt: now.addingTimeInterval(-3600),
                messageCount: 10
            )
        ]

        let window = QuotaWindow(
            label: "5-hour",
            usedPercent: 80.0,
            resetsAt: now.addingTimeInterval(3600),
            windowDurationMins: 300
        )

        let breakdown = BurnAttributionCalculator.calculate(sessions: sessions, window: window, now: now)
        XCTAssertNotNil(breakdown)

        if let b = breakdown {
            XCTAssertEqual(b.totalTokens, 59000)
            XCTAssertEqual(b.contributors.count, 2)

            // Top contributor should be meterusage
            XCTAssertEqual(b.contributors.first?.projectName, "meterusage")
            XCTAssertEqual(b.contributors.first?.model, "claude-3-7-sonnet")

            // Waste hints
            XCTAssertNotNil(b.cacheHitRate)
            XCTAssertGreaterThan(b.cacheHitRate ?? 0, 50.0)
            XCTAssertEqual(b.longChatCount, 2) // sess-1 has 25 turns (>= 10)
        }
    }

    func testDurableHistoryStorePreservesDailyRecords() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("durable-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let store = DurableHistoryStore(storeURL: tempURL)
        let today = Calendar.current.startOfDay(for: Date())
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today)!

        let daily1 = [
            DailyActivity(day: yesterday, tokens: TokenTotals(input: 1000, output: 500), estimatedCostUSD: 0.05, sessionCount: 2),
            DailyActivity(day: today, tokens: TokenTotals(input: 2000, output: 1000), estimatedCostUSD: 0.10, sessionCount: 4)
        ]

        store.record(provider: .codex, daily: daily1, peakUsedPercent: 45.0)
        let loaded = store.records(for: .codex)
        XCTAssertEqual(loaded.count, 2)

        // Simulate CLI transcript purge where yesterday is gone from CLI:
        let dailyAfterPurge = [
            DailyActivity(day: today, tokens: TokenTotals(input: 2500, output: 1200), estimatedCostUSD: 0.12, sessionCount: 5)
        ]
        store.record(provider: .codex, daily: dailyAfterPurge, peakUsedPercent: 50.0)

        // Store should still have 2 days!
        let loadedAfterPurge = store.records(for: .codex)
        XCTAssertEqual(loadedAfterPurge.count, 2)
        XCTAssertEqual(loadedAfterPurge.first?.tokens.input, 1000) // yesterday preserved
    }

    func testBurnShareIsPercentNotFraction() {
        let now = Date()
        let sessions = [
            SessionSummary(
                id: "big",
                projectName: "intent-trade",
                model: "codex",
                tokens: TokenTotals(input: 193_600_000, output: 0),
                estimatedCostUSD: 0,
                startedAt: now.addingTimeInterval(-3600),
                messageCount: 12
            ),
            SessionSummary(
                id: "small",
                projectName: "review",
                model: "codex",
                tokens: TokenTotals(input: 31_000, output: 0),
                estimatedCostUSD: 0,
                startedAt: now.addingTimeInterval(-1800),
                messageCount: 3
            )
        ]
        let breakdown = BurnAttributionCalculator.calculate(sessions: sessions, window: nil, now: now)
        XCTAssertNotNil(breakdown)
        guard let b = breakdown else { return }
        // Regression: shareOfWindow is 0...100. Rendering must not multiply
        // by 100 again (193.6m at ~100% rendered as 9,998%).
        for c in b.contributors {
            XCTAssertGreaterThanOrEqual(c.shareOfWindow, 0)
            XCTAssertLessThanOrEqual(c.shareOfWindow, 100)
        }
        XCTAssertEqual(Fmt.share(b.contributors.first?.shareOfWindow ?? -1), "100%")
        XCTAssertEqual(Fmt.share(0.016), "<1%")
        XCTAssertEqual(Fmt.share(0), "0%")
        XCTAssertEqual(Fmt.share(150), "100%")
    }

    func testBurnAttributionSinceScopeHidesStaleBurnWithoutFallback() {
        let now = Date()
        let old = SessionSummary(
            id: "old",
            projectName: "intent-trade",
            model: "codex",
            tokens: TokenTotals(input: 193_600_000, output: 0),
            estimatedCostUSD: 0,
            startedAt: now.addingTimeInterval(-10 * 86_400),
            messageCount: 12
        )
        let weekStart = now.addingTimeInterval(-6 * 86_400)

        // Scoped to the week with no fallback: stale sessions hide the section.
        XCTAssertNil(
            BurnAttributionCalculator.calculate(
                sessions: [old], window: nil, since: weekStart, fallbackToRecent: false, now: now
            )
        )
        // Default behavior keeps the recent-burn fallback for quota windows.
        XCTAssertNotNil(
            BurnAttributionCalculator.calculate(sessions: [old], window: nil, now: now)
        )
    }

    func testAttributionSessionsAddsProviderAggregates() {
        let now = Date()
        let activities: [Provider: Loaded<LocalActivity>] = [
            .codex: .value(LocalActivity(
                provider: .codex,
                sessions: [SessionSummary(
                    id: "s1", projectName: "meterusage", model: "codex",
                    tokens: TokenTotals(input: 1_000, output: 0),
                    estimatedCostUSD: 0,
                    startedAt: now.addingTimeInterval(-3_600), messageCount: 3
                )],
                daily: [], scannedAt: now
            ))
        ]
        let usages: [Provider: Loaded<ProviderUsage>] = [
            .openCodeGo: .value(ProviderUsage(
                provider: .openCodeGo, sessionCount: 5, messageCount: 50,
                todaySessionCount: 1, todayMessageCount: 9,
                todayTokens: TokenTotals(input: 38_000_000, output: 0),
                weekTokens: TokenTotals(input: 249_000_000, output: 0),
                capturedAt: now
            )),
            // Count-only providers contribute no aggregate.
            .grok: .value(ProviderUsage(
                provider: .grok, sessionCount: 4, messageCount: 40,
                todaySessionCount: 1, todayMessageCount: 8, capturedAt: now
            ))
        ]

        let sessions = BurnAttributionCalculator.attributionSessions(activities: activities, usages: usages, now: now)
        XCTAssertEqual(sessions.count, 2)
        let aggregate = try? XCTUnwrap(sessions.first { $0.isAggregate })
        XCTAssertEqual(aggregate?.projectName, "OpenCode Go")
        XCTAssertEqual(aggregate?.model, "")
        XCTAssertEqual(aggregate?.tokens.total, 249_000_000)

        // A whole provider's week is real burn but never one long chat.
        let breakdown = try? XCTUnwrap(BurnAttributionCalculator.calculate(
            sessions: [SessionSummary(
                id: "aggregate-openCodeGo", projectName: "OpenCode Go", model: "",
                tokens: TokenTotals(input: 38_000_000, output: 0),
                estimatedCostUSD: 0, startedAt: now, messageCount: 0, isAggregate: true
            )],
            window: nil, since: now.addingTimeInterval(-6 * 86_400),
            fallbackToRecent: false, now: now
        ))
        XCTAssertEqual(breakdown?.longChatCount, 0)
        XCTAssertEqual(breakdown?.contributors.first?.isLongChat, false)
    }

    /// When a usage provider splits its week by project, attribution shows
    /// one row per project instead of a single provider row. The rows stay
    /// synthetic aggregates, so project weeks never pose as one long chat.
    func testAttributionSessionsPrefersProjectBreakdown() {
        let now = Date()
        let usages: [Provider: Loaded<ProviderUsage>] = [
            .openCodeGo: .value(ProviderUsage(
                provider: .openCodeGo, sessionCount: 5, messageCount: 50,
                todaySessionCount: 1, todayMessageCount: 9,
                todayTokens: TokenTotals(input: 38_000_000, output: 0),
                weekTokens: TokenTotals(input: 249_000_000, output: 0),
                projectBreakdown: [
                    ProjectTokens(project: "meterusage", tokens: TokenTotals(input: 200_000_000, output: 0)),
                    ProjectTokens(project: "tivox", tokens: TokenTotals(input: 49_000_000, output: 0))
                ],
                capturedAt: now
            ))
        ]

        let sessions = BurnAttributionCalculator.attributionSessions(activities: [:], usages: usages, now: now)

        XCTAssertEqual(sessions.count, 2)
        XCTAssertNil(sessions.first { $0.projectName == "OpenCode Go" })
        let meter = try? XCTUnwrap(sessions.first { $0.projectName == "meterusage" })
        XCTAssertEqual(meter?.model, "")
        XCTAssertEqual(meter?.tokens.total, 200_000_000)
        XCTAssertEqual(meter?.isAggregate, true)

        let breakdown = try? XCTUnwrap(BurnAttributionCalculator.calculate(
            sessions: sessions,
            window: nil, since: now.addingTimeInterval(-6 * 86_400),
            fallbackToRecent: false, now: now
        ))
        XCTAssertEqual(breakdown?.longChatCount, 0)
        XCTAssertEqual(breakdown?.contributors.map(\.projectName).sorted(), ["meterusage", "tivox"])
    }

    /// Sessions without a token ledger carry no burn evidence. A scope whose
    /// every session is token-less must return nil (the section hides) instead
    /// of surfacing an all-zero card ("0 tokens", "0%", "Avg/turn: 0") — the
    /// codebase only renders a breakdown that measured something.
    func testBurnAttributionHidesScopesWithoutTokenEvidence() {
        let now = Date()
        let window = QuotaWindow(
            label: "Weekly",
            usedPercent: 11.0,
            resetsAt: now.addingTimeInterval(6 * 86_400),
            windowDurationMins: 10_080
        )
        let ledgerless = [
            SessionSummary(
                id: "voice",
                projectName: "realtime-voice-chat",
                model: "codex",
                tokens: TokenTotals(),
                estimatedCostUSD: 0,
                startedAt: now.addingTimeInterval(-3_600),
                messageCount: 0
            )
        ]

        // Nothing measurable in scope: no contributors, no zero-token card.
        XCTAssertNil(
            BurnAttributionCalculator.calculate(sessions: ledgerless, window: window, now: now)
        )

        // One measured session nearby outweighs the ledger-less one: the
        // zero-token session is excluded rather than shown as a 0% row.
        let measured = SessionSummary(
            id: "work",
            projectName: "meterusage",
            model: "codex",
            tokens: TokenTotals(input: 42_000, output: 188),
            estimatedCostUSD: 0,
            startedAt: now.addingTimeInterval(-1_800),
            messageCount: 2
        )
        let breakdown = try? XCTUnwrap(
            BurnAttributionCalculator.calculate(sessions: ledgerless + [measured], window: window, now: now)
        )
        XCTAssertEqual(breakdown?.totalTokens, 42_188)
        XCTAssertEqual(breakdown?.contributors.map(\.projectName), ["meterusage"])
    }

    func testQuotaPaceAmbientETA() {
        let now = Date()
        let resetsAt = now.addingTimeInterval(3600) // 1h remaining
        // Window 5h (300 mins). 90% consumed with 1h remaining = heavy deficit / burning fast.
        let window = QuotaWindow(label: "5-hour", usedPercent: 90.0, resetsAt: resetsAt, windowDurationMins: 300)
        let pace = window.pace(now: now)
        XCTAssertNotNil(pace)
        XCTAssertTrue(pace?.status.isDeficit ?? false)

        let etaSeconds = pace?.etaInterval(resetsAt: resetsAt, now: now)
        XCTAssertNotNil(etaSeconds)
        if let eta = etaSeconds {
            XCTAssertLessThan(eta, 3600) // empties before reset
            let etaText = pace?.etaText(resetsAt: resetsAt, now: now, short: true)
            XCTAssertNotNil(etaText)
            XCTAssertTrue(etaText?.contains("m") ?? false)
        }
    }
}
