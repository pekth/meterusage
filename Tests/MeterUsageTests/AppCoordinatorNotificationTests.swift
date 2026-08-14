import Combine
import XCTest
@testable import MeterUsage

@MainActor
final class AppCoordinatorNotificationTests: XCTestCase {

    func testLaterServerRefreshWithNewResetEmitsNotificationEvent() async {
        let source = SequenceQuotaSource([
            quota(availableCount: 0),
            quota(
                availableCount: 1,
                credits: [QuotaResetCredit(id: "reset-new", title: "Full reset", status: "available")]
            )
        ])
        var events: [QuotaResetAvailabilityEvent] = []
        let coordinator = AppCoordinator(
            preferences: Preferences(),
            quotaSources: [source],
            onQuotaResetAvailable: { events.append($0) }
        )

        await refreshAndWait(coordinator)
        XCTAssertTrue(events.isEmpty)

        await refreshAndWait(coordinator)
        XCTAssertEqual(
            events,
            [QuotaResetAvailabilityEvent(provider: .codex, newResetCount: 1)]
        )
    }

    func testLaterServerRefreshWithWindowResetEmitsNotificationEvent() async {
        let firstReset = Date(timeIntervalSince1970: 1_900_000_000)
        let source = SequenceQuotaSource([
            quota(
                availableCount: 0,
                windows: [QuotaWindow(label: "Weekly", usedPercent: 82, resetsAt: firstReset)]
            ),
            quota(
                availableCount: 0,
                windows: [QuotaWindow(label: "Weekly", usedPercent: 0, resetsAt: firstReset.addingTimeInterval(300))]
            )
        ])
        var events: [QuotaResetAvailabilityEvent] = []
        let coordinator = AppCoordinator(
            preferences: Preferences(),
            quotaSources: [source],
            onQuotaResetAvailable: { events.append($0) }
        )

        await refreshAndWait(coordinator)
        XCTAssertTrue(events.isEmpty)

        await refreshAndWait(coordinator)
        XCTAssertEqual(
            events,
            [QuotaResetAvailabilityEvent(provider: .codex, newResetCount: 1)]
        )
    }

    func testDemoSnapshotsNeverEmitRealResetNotifications() async {
        let source = SequenceQuotaSource([
            quota(availableCount: 0),
            quota(
                availableCount: 1,
                credits: [QuotaResetCredit(id: "demo-reset", title: "Full reset", status: "available")]
            )
        ])
        var events: [QuotaResetAvailabilityEvent] = []
        let coordinator = AppCoordinator(
            preferences: Preferences(),
            isDemoMode: true,
            quotaSources: [source],
            onQuotaResetAvailable: { events.append($0) }
        )

        await refreshAndWait(coordinator)
        await refreshAndWait(coordinator)

        XCTAssertTrue(events.isEmpty)
    }

    private func refreshAndWait(_ coordinator: AppCoordinator) async {
        let refreshed = expectation(description: "quota refresh completed")
        let cancellable = coordinator.$lastRefreshedAt
            .dropFirst()
            .sink { _ in refreshed.fulfill() }

        coordinator.refresh()
        await fulfillment(of: [refreshed], timeout: 2)
        withExtendedLifetime(cancellable) {}
    }

    private func quota(
        availableCount: Int?,
        credits: [QuotaResetCredit] = [],
        windows: [QuotaWindow] = []
    ) -> ProviderQuota {
        ProviderQuota(
            provider: .codex,
            windows: windows,
            resetCreditCount: availableCount,
            resetCredits: credits,
            capturedAt: Date()
        )
    }
}

private actor SequenceQuotaSource: QuotaSource {
    nonisolated let provider: Provider = .codex
    private var quotas: [ProviderQuota]

    init(_ quotas: [ProviderQuota]) {
        self.quotas = quotas
    }

    func fetchQuota() async throws -> ProviderQuota {
        guard !quotas.isEmpty else { throw SourceUnavailable.noData }
        return quotas.removeFirst()
    }
}
