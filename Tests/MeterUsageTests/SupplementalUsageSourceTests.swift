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

    func testAntigravityParsesFractionalSecondTimestamps() throws {
        let now = Date()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let object: [String: Any] = [
            "updated_at": formatter.string(from: now),
            "sessions": [
                ["started_at": formatter.string(from: now.addingTimeInterval(-3_600)), "num_messages": 4]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: object)

        let usage = try AntigravityUsageSource.parse(data: data, now: now)

        XCTAssertEqual(usage.sessionCount, 1)
        XCTAssertEqual(usage.messageCount, 4)
        XCTAssertEqual(usage.capturedAt.timeIntervalSince1970, now.timeIntervalSince1970, accuracy: 1)
    }

    func testAntigravityParsesContainerHistoryIntoSessions() throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let lines = [
            ["conversationId": "conv-a", "timestamp": now.addingTimeInterval(-1_800).timeIntervalSince1970 * 1000, "workspace": "/Users/testuser/code", "display": "prompt one"],
            ["conversationId": "conv-a", "timestamp": now.addingTimeInterval(-1_700).timeIntervalSince1970 * 1000, "workspace": "/Users/testuser/code", "display": "prompt two"],
            ["conversationId": "conv-b", "timestamp": now.addingTimeInterval(-100_000).timeIntervalSince1970 * 1000, "workspace": "/Users/testuser/other", "display": "prompt three"]
        ]
        let data = try Self.jsonl(lines)

        let usage = try AntigravityUsageSource.parseHistory(data: data, now: now)

        XCTAssertEqual(usage.provider, .antigravity)
        XCTAssertEqual(usage.sessionCount, 2)
        XCTAssertEqual(usage.messageCount, 3)
        XCTAssertEqual(usage.todaySessionCount, 1)
        XCTAssertEqual(usage.todayMessageCount, 2)
        XCTAssertNil(usage.tokens)
        XCTAssertNil(usage.estimatedCostUSD)
    }

    func testAntigravityHistoryUsesEarliestPromptPerSession() throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let todayStart = Calendar.current.startOfDay(for: now)
        // The session started yesterday but has a prompt today. Its session
        // date must be the earliest prompt, so it does not count as today.
        let lines = [
            ["conversationId": "conv-a", "timestamp": todayStart.addingTimeInterval(-3_600).timeIntervalSince1970 * 1000],
            ["conversationId": "conv-a", "timestamp": now.timeIntervalSince1970 * 1000]
        ]
        let data = try Self.jsonl(lines)

        let usage = try AntigravityUsageSource.parseHistory(data: data, now: now)

        XCTAssertEqual(usage.sessionCount, 1)
        XCTAssertEqual(usage.messageCount, 2)
        XCTAssertEqual(usage.todaySessionCount, 0)
        XCTAssertEqual(usage.todayMessageCount, 0)
    }

    func testAntigravityHistorySkipsMalformedAndMissingTimestampLines() throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let text = """
        not json
        {"conversationId":"ok","timestamp":\(now.addingTimeInterval(-300).timeIntervalSince1970 * 1000)}
        {"conversationId":"no-ts","display":"no timestamp here"}
        {"timestamp":1700000000000,"display":"no conversation id"}
        """
        let data = Data(text.utf8)

        let usage = try AntigravityUsageSource.parseHistory(data: data, now: now)

        XCTAssertEqual(usage.sessionCount, 1)
        XCTAssertEqual(usage.messageCount, 1)
        XCTAssertEqual(usage.todaySessionCount, 1)
    }

    func testAntigravityHistoryEmptyThrowsNoData() throws {
        let data = Data("".utf8)
        XCTAssertThrowsError(try AntigravityUsageSource.parseHistory(data: data, now: Date())) { error in
            XCTAssertEqual(error as? SourceUnavailable, .noData)
        }
    }

    func testAntigravityFetchReadsNativeHistoryFile() async throws {
        let now = Date()
        let lines = [
            ["conversationId": "conv-a", "timestamp": now.addingTimeInterval(-300).timeIntervalSince1970 * 1000],
            ["conversationId": "conv-a", "timestamp": now.addingTimeInterval(-200).timeIntervalSince1970 * 1000],
            ["conversationId": "conv-b", "timestamp": now.addingTimeInterval(-100_000).timeIntervalSince1970 * 1000]
        ]
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeterUsageTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let historyURL = directory.appendingPathComponent("history.jsonl")
        try Self.jsonl(lines).write(to: historyURL)

        let source = AntigravityUsageSource(
            cacheURL: directory.appendingPathComponent("absent-cache.json"),
            historyURL: historyURL
        )

        let usage = try await source.fetchUsage()

        XCTAssertEqual(usage.provider, .antigravity)
        XCTAssertEqual(usage.sessionCount, 2)
        XCTAssertEqual(usage.messageCount, 3)
        XCTAssertEqual(usage.todaySessionCount, 1)
        XCTAssertEqual(usage.todayMessageCount, 2)
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

    func testGrokParsesFractionalSecondSummaryTimestamps() throws {
        let now = Date()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let todayStart = Calendar.current.startOfDay(for: now)
        let summaries: [[String: Any]] = [
            [
                "created_at": formatter.string(from: now.addingTimeInterval(-300)),
                "num_chat_messages": 8
            ],
            [
                "created_at": formatter.string(from: todayStart.addingTimeInterval(-86_400)),
                "num_messages": 3
            ]
        ]

        let usage = try GrokUsageSource.parse(summaries: summaries, now: now)

        XCTAssertEqual(usage.sessionCount, 2)
        XCTAssertEqual(usage.messageCount, 11)
        XCTAssertEqual(usage.todaySessionCount, 1)
        XCTAssertEqual(usage.todayMessageCount, 8)
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

    /// Records are bucketed into rolling windows by `createdAt`, with each
    /// window's own session/message/token/cost sums. A record aged past a
    /// boundary contributes only to the windows that still contain it.
    func testOpenCodeGoComputesRollingUsageWindows() throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let hour: TimeInterval = 3_600
        let day: TimeInterval = 86_400

        func record(_ createdAgo: TimeInterval, _ cost: Double) -> OpenCodeGoUsageSource.Record {
            let created = now.addingTimeInterval(-createdAgo)
            return OpenCodeGoUsageSource.Record(
                input: 100,
                output: 20,
                reasoning: 5,
                cacheRead: 50,
                cacheWrite: 1,
                cost: cost,
                messages: 4,
                createdAt: created,
                updatedAt: created
            )
        }

        let records = [
            record(1 * hour, 1.00),      // in 24h, 7d, 30d
            record(3 * day, 2.00),       // in 7d, 30d (past 24h)
            record(20 * day, 3.00),      // in 30d only (past 7d)
            record(60 * day, 4.00)       // past all windows
        ]

        let windows = OpenCodeGoUsageSource.windows(from: records, now: now)

        XCTAssertEqual(windows.count, 3)
        XCTAssertEqual(windows.map(\.label), ["last 24h", "last 7d", "last 30d"])

        let oneDay = try XCTUnwrap(windows.first { $0.label == "last 24h" })
        XCTAssertEqual(oneDay.sessionCount, 1)
        XCTAssertEqual(oneDay.messageCount, 4)
        XCTAssertEqual(oneDay.tokens.total, 176)
        XCTAssertEqual(oneDay.estimatedCostUSD, 1.00, accuracy: 0.0001)

        let sevenDay = try XCTUnwrap(windows.first { $0.label == "last 7d" })
        XCTAssertEqual(sevenDay.sessionCount, 2)
        XCTAssertEqual(sevenDay.messageCount, 8)
        XCTAssertEqual(sevenDay.tokens.total, 352)
        XCTAssertEqual(sevenDay.estimatedCostUSD, 3.00, accuracy: 0.0001)

        let thirtyDay = try XCTUnwrap(windows.first { $0.label == "last 30d" })
        XCTAssertEqual(thirtyDay.sessionCount, 3)
        XCTAssertEqual(thirtyDay.messageCount, 12)
        XCTAssertEqual(thirtyDay.tokens.total, 528)
        XCTAssertEqual(thirtyDay.estimatedCostUSD, 6.00, accuracy: 0.0001)
    }

    /// Windows bucket by last activity (`updatedAt`), matching opencode's own
    /// `stats --days N`: a session created before the window but worked on
    /// inside it counts, and all of its messages count.
    func testOpenCodeGoWindowUsesLastActivityNotCreationTime() throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let hour: TimeInterval = 3_600
        let day: TimeInterval = 86_400

        let oldButActive = OpenCodeGoUsageSource.Record(
            input: 100, output: 20, reasoning: 5, cacheRead: 50, cacheWrite: 1,
            cost: 1.00, messages: 100,
            createdAt: now.addingTimeInterval(-3 * day),  // started 3 days ago…
            updatedAt: now.addingTimeInterval(-2 * hour)  // …touched 2h ago
        )
        let genuinelyOld = OpenCodeGoUsageSource.Record(
            input: 10, output: 5, reasoning: 0, cacheRead: 0, cacheWrite: 0,
            cost: 0.50, messages: 5,
            createdAt: now.addingTimeInterval(-40 * day),
            updatedAt: now.addingTimeInterval(-40 * day)
        )

        let windows = OpenCodeGoUsageSource.windows(from: [oldButActive, genuinelyOld], now: now)

        let oneDay = try XCTUnwrap(windows.first { $0.label == "last 24h" })
        XCTAssertEqual(oneDay.sessionCount, 1, "the old-but-active session counts")
        XCTAssertEqual(oneDay.messageCount, 100, "all of its messages count")

        let sevenDay = try XCTUnwrap(windows.first { $0.label == "last 7d" })
        XCTAssertEqual(sevenDay.sessionCount, 1)

        let thirtyDay = try XCTUnwrap(windows.first { $0.label == "last 30d" })
        XCTAssertEqual(thirtyDay.sessionCount, 1)
    }

    /// An empty record set must not fabricate a zero-usage window set — callers
    /// that gate on the window list staying nil/empty rely on that.
    func testOpenCodeGoEmptyRecordsProduceEmptyWindows() {
        let windows = OpenCodeGoUsageSource.windows(from: [], now: Date())
        XCTAssertEqual(windows.count, 3)
        XCTAssertTrue(windows.allSatisfy { $0.sessionCount == 0 && $0.messageCount == 0 })
    }

    /// Each window's bar is its share of the 30-day cost: the 30d window is the
    /// reference (always 1.0), and a zero reference must not divide by zero.
    func testOpenCodeGoWindowShareOfLast30Days() {
        let windows = [
            UsageWindow(label: "last 24h", sessionCount: 3, messageCount: 71,
                        tokens: TokenTotals(input: 260_000), estimatedCostUSD: 2.10),
            UsageWindow(label: "last 7d", sessionCount: 21, messageCount: 390,
                        tokens: TokenTotals(input: 980_000), estimatedCostUSD: 12.00),
            UsageWindow(label: "last 30d", sessionCount: 26, messageCount: 492,
                        tokens: TokenTotals(input: 1_420_000), estimatedCostUSD: 16.33)
        ]
        let reference = windows.first { $0.label == "last 30d" }!.estimatedCostUSD

        XCTAssertEqual(
            windows[0].shareOf30Days(referenceCost: reference),
            2.10 / 16.33, accuracy: 0.0001
        )
        XCTAssertEqual(
            windows[1].shareOf30Days(referenceCost: reference),
            12.00 / 16.33, accuracy: 0.0001
        )
        XCTAssertEqual(
            windows[2].shareOf30Days(referenceCost: reference),
            1.0, accuracy: 0.0001
        )

        // Zero reference (no 30d window) must read 0, never NaN.
        XCTAssertEqual(windows[0].shareOf30Days(referenceCost: 0), 0)
    }

    /// Guards against the 64KB pipe-truncation failure mode: the real
    /// `opencode db` output for a busy account exceeds one 64KB pipe buffer, and
    /// a truncated payload must never be accepted as valid usage.
    func testOpenCodeGoParsesPayloadLargerThanOnePipeBuffer() throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        var rows: [[String: Any]] = []
        for index in 0..<2_000 {
            rows.append([
                "input": 1000,
                "output": 100,
                "reasoning": 10,
                "cache_read": 50,
                "cache_write": 1,
                "cost": 0.01,
                "messages": 3,
                "created": now.addingTimeInterval(-Double(index) * 60).timeIntervalSince1970,
                "updated": now.addingTimeInterval(-Double(index) * 60 + 30).timeIntervalSince1970
            ])
        }
        let data = try JSONSerialization.data(withJSONObject: rows)
        XCTAssertGreaterThan(data.count, 65_536, "fixture must exceed one 64KB pipe buffer")

        let records = try OpenCodeGoUsageSource.parse(data: data)

        XCTAssertEqual(records.count, 2_000)
        XCTAssertEqual(records.reduce(0) { $0 + $1.messages }, 6_000)
    }

    /// Serializes each object as its own JSONL line, matching agy's
    /// line-delimited `history.jsonl` (one JSON object per prompt).
    private static func jsonl(_ objects: [[String: Any]]) throws -> Data {
        let lines = try objects.map { object -> String in
            let data = try JSONSerialization.data(withJSONObject: object)
            return String(data: data, encoding: .utf8)!
        }
        return Data(lines.joined(separator: "\n").utf8)
    }
}
