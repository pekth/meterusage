import XCTest
@testable import MeterUsage

final class SupplementalUsageSourceTests: XCTestCase {

    func testProviderOrderIsCodexFirst() {
        XCTAssertEqual(
            Provider.allCases,
            [.codex, .antigravity, .grok, .openCodeGo, .openRouter, .claude]
        )
    }

    @MainActor
    func testNewPreferencesShowCodexAndOpenCodeByDefaultButHideOptionalProviders() throws {
        let suiteName = "MeterUsageTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = Preferences(defaults: defaults)

        XCTAssertEqual(
            preferences.enabledProviders,
            Set([.codex, .openCodeGo, .openRouter])
        )
        XCTAssertFalse(preferences.isEnabled(.claude))
        XCTAssertFalse(preferences.isEnabled(.antigravity))
        XCTAssertFalse(preferences.isEnabled(.grok))
    }

    @MainActor
    func testPreferencesPreserveSavedSettingsAcrossReinitialization() throws {
        let suiteName = "MeterUsageTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(300.0, forKey: PrefKey.refreshInterval)
        defaults.set(false, forKey: PrefKey.showCodex)
        defaults.set(true, forKey: PrefKey.showClaude)
        defaults.set(true, forKey: PrefKey.showAntigravity)
        defaults.set(false, forKey: PrefKey.showGrok)
        defaults.set(false, forKey: PrefKey.showOpenCodeGo)
        defaults.set(true, forKey: PrefKey.showOpenRouter)
        defaults.set(AppTheme.dark.rawValue, forKey: PrefKey.theme)
        defaults.set(true, forKey: PrefKey.launchAtLogin)

        let first = Preferences(defaults: defaults)
        let second = Preferences(defaults: defaults)

        XCTAssertEqual(first.refreshInterval, 300)
        XCTAssertEqual(second.refreshInterval, 300)
        XCTAssertEqual(first.theme, .dark)
        XCTAssertEqual(second.theme, .dark)
        XCTAssertEqual(first.enabledProviders, Set([.claude, .antigravity, .openRouter]))
        XCTAssertEqual(second.enabledProviders, first.enabledProviders)
        XCTAssertTrue(defaults.bool(forKey: PrefKey.launchAtLogin))
    }

    func testAntigravityParsesCountOnlySessionHistory() throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let object: [String: Any] = [
            "updated_at": now.timeIntervalSince1970,
            "sessions": [
                ["started_at": now.addingTimeInterval(-3_600).timeIntervalSince1970, "num_messages": 4],
                ["started_at": now.addingTimeInterval(-90_000).timeIntervalSince1970, "messages": 7]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: object)

        let usage = try AntigravityUsageSource.parse(data: data, now: now)

        XCTAssertEqual(usage.provider, .antigravity)
        XCTAssertEqual(usage.sessionCount, 2)
        XCTAssertEqual(usage.messageCount, 11)
        XCTAssertEqual(usage.todaySessionCount, 1)
        XCTAssertEqual(usage.todayMessageCount, 4)
        XCTAssertNil(usage.tokens)
        XCTAssertNil(usage.estimatedCostUSD)
        XCTAssertEqual(usage.capturedAt, now)
    }

    func testGrokParsesSummaryCountsWithoutInventingTokens() throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let summaries: [[String: Any]] = [
            [
                "created_at": now.addingTimeInterval(-1_800).timeIntervalSince1970,
                "num_chat_messages": 8
            ],
            [
                "created_at": now.addingTimeInterval(-100_000).timeIntervalSince1970,
                "num_messages": 3
            ]
        ]

        let usage = try GrokUsageSource.parse(summaries: summaries, now: now)

        XCTAssertEqual(usage.provider, .grok)
        XCTAssertEqual(usage.sessionCount, 2)
        XCTAssertEqual(usage.messageCount, 11)
        XCTAssertEqual(usage.todaySessionCount, 1)
        XCTAssertEqual(usage.todayMessageCount, 8)
        XCTAssertNil(usage.tokens)
        XCTAssertNil(usage.estimatedCostUSD)
    }

    func testOpenCodeGoParsesNumericUsageRows() throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let rows: [[String: Any]] = [
            [
                "input": 120,
                "output": 30,
                "reasoning": 7,
                "cache_read": 50,
                "cache_write": 4,
                "cost": 1.25,
                "messages": 3,
                "created": now.addingTimeInterval(-1_800).timeIntervalSince1970,
                "updated": now.addingTimeInterval(-900).timeIntervalSince1970
            ],
            [
                "input": 10,
                "output": 5,
                "reasoning": 2,
                "cache_read": 0,
                "cache_write": 1,
                "cost": 0.75,
                "messages": 2,
                "created": now.addingTimeInterval(-100_000).timeIntervalSince1970,
                "updated": now.addingTimeInterval(-99_000).timeIntervalSince1970
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: rows)

        let records = try OpenCodeGoUsageSource.parse(data: data)

        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].input, 120)
        XCTAssertEqual(records[0].reasoning, 7)
        XCTAssertEqual(records[0].messages, 3)
        XCTAssertEqual(records[0].cost, 1.25, accuracy: 0.0001)

        let totals = records.reduce(TokenTotals()) { total, record in
            total + TokenTotals(
                input: record.input,
                output: record.output,
                reasoning: record.reasoning,
                cacheRead: record.cacheRead,
                cacheWrite: record.cacheWrite
            )
        }
        XCTAssertEqual(totals, TokenTotals(input: 130, output: 35, reasoning: 9, cacheRead: 50, cacheWrite: 5))
        XCTAssertEqual(records.reduce(0) { $0 + $1.messages }, 5)
        XCTAssertEqual(records.reduce(0) { $0 + $1.cost }, 2.0, accuracy: 0.0001)
    }
}
