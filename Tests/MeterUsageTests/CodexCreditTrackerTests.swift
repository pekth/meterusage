import XCTest
@testable import MeterUsage

final class CodexCreditTrackerTests: XCTestCase {
    private func credits(_ balance: Double, unlimited: Bool = false) -> CreditBalance {
        CreditBalance(balance: balance, hasCredits: balance > 0, unlimited: unlimited, unit: .credits)
    }

    func testBalancesTopUpsDuplicateReadsAndAccounts() throws {
        var tracker = CodexCreditTracker()
        let work = ProviderSlot(provider: .codex, slotID: "work", label: "Work")
        let start = Date(timeIntervalSince1970: 1_000)
        tracker.record(credits(100), for: .codex, at: start)
        tracker.record(credits(50), for: work, at: start)
        tracker.record(credits(90), for: .codex, at: start.addingTimeInterval(1))
        tracker.record(credits(10), for: .codex, at: start) // Older response.
        tracker.record(credits(10), for: .codex, at: start.addingTimeInterval(1)) // Duplicate.
        tracker.record(credits(190), for: .codex, at: start.addingTimeInterval(2)) // Top-up.
        tracker.record(credits(170), for: .codex, at: start.addingTimeInterval(3))
        tracker.record(credits(40), for: work, at: start.addingTimeInterval(1))
        XCTAssertEqual(tracker.accounts[ProviderSlot.codex.key]?.usedCredits, 30)
        XCTAssertEqual(tracker.accounts[work.key]?.usedCredits, 10)
        XCTAssertEqual(tracker.accounts[work.key]?.since, start)
        XCTAssertEqual(tracker, try JSONDecoder().decode(CodexCreditTracker.self, from: JSONEncoder().encode(tracker)))
    }

    func testUnavailableUnlimitedInvalidAndPausedReadingsBreakTheBaseline() {
        let start = Date(timeIntervalSince1970: 1_000)
        for unavailable in [nil, credits(100, unlimited: true), credits(-1), credits(.nan), credits(.infinity)] {
            var tracker = CodexCreditTracker()
            tracker.record(credits(100), for: .codex, at: start)
            tracker.record(credits(90), for: .codex, at: start.addingTimeInterval(1))
            tracker.record(unavailable, for: .codex, at: start.addingTimeInterval(2))
            tracker.record(credits(60), for: .codex, at: start.addingTimeInterval(3))
            XCTAssertEqual(tracker.accounts[ProviderSlot.codex.key]?.usedCredits, 10)
            tracker.pause()
            tracker.record(credits(30), for: .codex, at: start.addingTimeInterval(4))
            tracker.record(credits(0), for: .codex, at: start.addingTimeInterval(5))
            XCTAssertEqual(tracker.accounts[ProviderSlot.codex.key]?.usedCredits, 40)
        }
    }

    @MainActor
    func testRefreshToggleAndRelaunchKeepMeasuredUsageAndQuotaIndependent() async throws {
        let suite = "MeterUsageTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let archive = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: archive) }
        var preferences = Preferences(defaults: defaults)
        let source = CreditQuotaSource()
        var coordinator = AppCoordinator(preferences: preferences, quotaSources: [source], quotaArchiveURL: archive)

        func refresh(_ coordinator: AppCoordinator) async throws {
            coordinator.refresh()
            for _ in 0..<200 {
                if !coordinator.isRefreshing { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTFail("refresh did not finish")
        }

        XCTAssertTrue(preferences.codexCreditTrackingEnabled)
        try await refresh(coordinator)
        await source.setBalance(90)
        try await refresh(coordinator)
        XCTAssertEqual(preferences.codexCreditUsage(for: .codex)?.usedCredits, 10)
        preferences.setCodexCreditTracking(false)
        let saved = defaults.data(forKey: PrefKey.codexCreditUsage)
        await source.setBalance(60)
        try await refresh(coordinator)
        XCTAssertNil(preferences.codexCreditUsage(for: .codex))
        XCTAssertEqual(defaults.data(forKey: PrefKey.codexCreditUsage), saved)
        XCTAssertEqual(coordinator.quotas[.codex]?.value?.windows.first?.usedPercent, 25)

        preferences = Preferences(defaults: defaults)
        XCTAssertFalse(preferences.codexCreditTrackingEnabled)
        preferences.setCodexCreditTracking(true)
        coordinator = AppCoordinator(preferences: preferences, quotaSources: [source], quotaArchiveURL: archive)
        try await refresh(coordinator) // 90 -> 60 happened while paused.
        await source.setBalance(50)
        try await refresh(coordinator)
        XCTAssertEqual(preferences.codexCreditUsage(for: .codex)?.usedCredits, 20)
        XCTAssertEqual(Preferences(defaults: defaults).codexCreditUsage(for: .codex)?.usedCredits, 20)

        let beforeDemo = defaults.data(forKey: PrefKey.codexCreditUsage)
        let demo = AppCoordinator(preferences: preferences, isDemoMode: true,
                                  quotaSources: [source], quotaArchiveURL: archive)
        await source.setBalance(0)
        try await refresh(demo)
        XCTAssertEqual(defaults.data(forKey: PrefKey.codexCreditUsage), beforeDemo)
        XCTAssertEqual(demo.codexCreditUsage(for: .codex)?.usedCredits, 12.4)

        let corrupt = Data("unreadable credit history".utf8)
        defaults.set(corrupt, forKey: PrefKey.codexCreditUsage)
        let unreadable = Preferences(defaults: defaults)
        unreadable.recordCodexCredits(try await source.fetchQuota(), for: .codex)
        XCTAssertNil(unreadable.codexCreditUsage(for: .codex))
        XCTAssertEqual(defaults.data(forKey: PrefKey.codexCreditUsage), corrupt)
    }
}

private actor CreditQuotaSource: QuotaSource {
    let provider: Provider = .codex
    var balance = 100.0

    func setBalance(_ value: Double) { balance = value }

    func fetchQuota() async throws -> ProviderQuota {
        ProviderQuota(provider: .codex,
                      windows: [QuotaWindow(label: "5-hour", usedPercent: 25, resetsAt: nil)],
                      credits: CreditBalance(balance: balance, hasCredits: balance > 0,
                                             unlimited: false, unit: .credits),
                      capturedAt: Date())
    }
}
