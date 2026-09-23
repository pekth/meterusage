import XCTest
@testable import MeterUsage

final class DurableHistoryStoreTests: XCTestCase {
    func testMissingFilePersistsAndReloads() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("durable-history-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let daily = [DailyActivity(day: Date(), tokens: TokenTotals(input: 10, output: 2), estimatedCostUSD: 0.01, sessionCount: 1)]
        let store = DurableHistoryStore(storeURL: url)
        XCTAssertNil(store.error)
        store.record(provider: .codex, daily: daily)

        let reloaded = DurableHistoryStore(storeURL: url)
        XCTAssertNil(reloaded.error)
        XCTAssertEqual(reloaded.records(for: .codex).first?.tokens.input, 10)
    }

    func testSaveFailureRecoversAndDiagnosticsExposeState() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("durable-history-\(UUID().uuidString)")
        let url = root.appendingPathComponent("history.json")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let store = DurableHistoryStore(storeURL: url)
        try FileManager.default.removeItem(at: root)
        try Data("blocked".utf8).write(to: root)
        store.record(provider: .codex, daily: [DailyActivity(day: Date(), tokens: TokenTotals(input: 1, output: 1), estimatedCostUSD: 0, sessionCount: 1)])
        XCTAssertEqual(store.error, .writeFailed)
        XCTAssertTrue(DiagnosticsReport.build(
            appName: "MeterUsage", appVersion: "1", isDemoMode: false, refreshInterval: 60,
            lastRefreshedAt: nil, now: Date(), enabledProviders: [], quotas: [:], activities: [:],
            usages: [:], statuses: [:], plans: [:], historyError: store.error
        ).contains("history: writeFailed"))

        try FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store.record(provider: .codex, daily: [DailyActivity(day: Date(), tokens: TokenTotals(input: 2, output: 1), estimatedCostUSD: 0, sessionCount: 1)])
        XCTAssertNil(store.error)
        XCTAssertEqual(DurableHistoryStore(storeURL: url).records(for: .codex).first?.tokens.input, 2)
    }

    func testLoadFailureStaysLatchedWhileLiveRecordsUpdate() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("durable-history-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let original = Data("unreadable history".utf8)
        try original.write(to: url)

        let store = DurableHistoryStore(storeURL: url)
        for input in [10, 20] {
            store.record(provider: .codex, daily: [DailyActivity(day: Date(), tokens: TokenTotals(input: input, output: 0), estimatedCostUSD: 0, sessionCount: 1)])
            XCTAssertEqual(store.error, .loadFailed)
            XCTAssertEqual(store.records(for: .codex).first?.tokens.input, input)
            XCTAssertEqual(try Data(contentsOf: url), original)
        }
        let report = DiagnosticsReport.build(
            appName: "MeterUsage", appVersion: "1", isDemoMode: false, refreshInterval: 60,
            lastRefreshedAt: nil, now: Date(), enabledProviders: [], quotas: [:], activities: [:],
            usages: [:], statuses: [:], plans: [:], historyError: store.error
        )
        XCTAssertTrue(report.contains("history: loadFailed"))
        XCTAssertFalse(report.contains(url.path))
        XCTAssertFalse(report.contains("unreadable history"))
    }
}
