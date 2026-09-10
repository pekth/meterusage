import XCTest
@testable import MeterUsage

final class QuotaArchiveTests: XCTestCase {

    // MARK: - Round trip

    func testSaveAndLoadPreservesWindows() throws {
        let url = Self.tempURL()
        let reset = Date().addingTimeInterval(3600)
        let captured = Date()
        QuotaArchive.save(
            [
                .codex: ProviderQuota(
                    provider: .codex,
                    windows: [
                        QuotaWindow(label: "5-hour", usedPercent: 82, resetsAt: reset),
                        QuotaWindow(label: "Weekly", usedPercent: 31, resetsAt: nil),
                    ],
                    capturedAt: captured
                ),
            ],
            to: url
        )

        let loaded = QuotaArchive.load(from: url)
        let quota = try XCTUnwrap(loaded[.codex])
        XCTAssertEqual(quota.windows.count, 2)
        XCTAssertEqual(quota.windows[0].label, "5-hour")
        XCTAssertEqual(quota.windows[0].usedPercent, 82)
        XCTAssertEqual(quota.windows[0].resetsAt?.timeIntervalSince1970 ?? 0, reset.timeIntervalSince1970, accuracy: 1)
        XCTAssertNil(quota.windows[1].resetsAt)
        XCTAssertEqual(quota.capturedAt.timeIntervalSince1970, captured.timeIntervalSince1970, accuracy: 1)
    }

    func testLoadTreatsMissingOrMalformedFilesAsEmpty() throws {
        XCTAssertTrue(QuotaArchive.load(from: Self.tempURL()).isEmpty)

        let url = Self.tempURL()
        try XCTUnwrap("not json".data(using: .utf8)).write(to: url)
        XCTAssertTrue(QuotaArchive.load(from: url).isEmpty)
    }

    // MARK: - Coordinator restore

    @MainActor
    func testCoordinatorRestoresArchiveAsStaleDisplay() async throws {
        let url = Self.tempURL()
        QuotaArchive.save(
            [.codex: ProviderQuota(
                provider: .codex,
                windows: [QuotaWindow(label: "5-hour", usedPercent: 55, resetsAt: nil)],
                capturedAt: Date().addingTimeInterval(-3600)
            )],
            to: url
        )

        let coordinator = try Self.coordinator(archiveURL: url, quotaSources: [])
        let display = try XCTUnwrap(
            coordinator.displayQuota(for: .codex),
            "a remembered reading must surface when live data is absent"
        )
        XCTAssertTrue(display.isStale)
        XCTAssertEqual(display.quota.windows.first?.usedPercent, 55)
        XCTAssertNil(
            coordinator.displayQuota(for: .grok),
            "no live reading and no memory means no number at all"
        )
    }

    @MainActor
    func testLiveReadingBeatsArchiveAndRefreshPersistsIt() async throws {
        let url = Self.tempURL()
        QuotaArchive.save(
            [.codex: ProviderQuota(
                provider: .codex,
                windows: [QuotaWindow(label: "5-hour", usedPercent: 55, resetsAt: nil)],
                capturedAt: Date().addingTimeInterval(-3600)
            )],
            to: url
        )

        let coordinator = try Self.coordinator(
            archiveURL: url,
            quotaSources: [StubQuotaSource(
                provider: .codex,
                windows: [QuotaWindow(label: "5-hour", usedPercent: 80, resetsAt: nil)]
            )]
        )
        coordinator.refresh()
        for _ in 0..<200 {
            if coordinator.lastRefreshedAt != nil { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        let display = try XCTUnwrap(coordinator.displayQuota(for: .codex))
        XCTAssertFalse(display.isStale)
        XCTAssertEqual(display.quota.windows.first?.usedPercent, 80)

        let reloaded = QuotaArchive.load(from: url)
        XCTAssertEqual(
            reloaded[.codex]?.windows.first?.usedPercent, 80,
            "a successful sweep must persist the new last-good reading"
        )
    }

    // MARK: - Entries stale fallback

    func testEntriesFallBackToArchivedReadingAsStale() {
        let archived: [Provider: ProviderQuota] = [
            .codex: ProviderQuota(
                provider: .codex,
                windows: [QuotaWindow(label: "5-hour", usedPercent: 55, resetsAt: nil)],
                capturedAt: Date()
            ),
        ]

        let stale = SideNotchPanelView.entries(
            providers: [.codex],
            quotas: [:],
            statuses: [:],
            archivedQuotas: archived
        )
        XCTAssertEqual(stale.count, 1)
        XCTAssertEqual(stale[0].usedPercent, 55)
        XCTAssertTrue(stale[0].isStale)

        let live: [Provider: Loaded<ProviderQuota>] = [
            .codex: .value(ProviderQuota(
                provider: .codex,
                windows: [QuotaWindow(label: "5-hour", usedPercent: 80, resetsAt: nil)],
                capturedAt: Date()
            )),
        ]
        let fresh = SideNotchPanelView.entries(
            providers: [.codex],
            quotas: live,
            statuses: [:],
            archivedQuotas: archived
        )
        XCTAssertEqual(fresh.count, 1)
        XCTAssertEqual(fresh[0].usedPercent, 80)
        XCTAssertFalse(fresh[0].isStale)
    }

    // MARK: - Helpers

    private static func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("meterusage-tests-" + UUID().uuidString + ".json")
    }

    @MainActor
    private static func coordinator(
        archiveURL: URL,
        quotaSources: [QuotaSource]
    ) throws -> AppCoordinator {
        let suiteName = "MeterUsageTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        return AppCoordinator(
            preferences: Preferences(defaults: defaults),
            quotaSources: quotaSources,
            quotaArchiveURL: archiveURL
        )
    }
}

private struct StubQuotaSource: QuotaSource {
    let provider: Provider
    let windows: [QuotaWindow]

    func fetchQuota() async throws -> ProviderQuota {
        ProviderQuota(provider: provider, windows: windows, capturedAt: Date())
    }
}
