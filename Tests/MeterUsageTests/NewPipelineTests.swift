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
