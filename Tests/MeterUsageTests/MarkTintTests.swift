import XCTest
import SwiftUI
@testable import MeterUsage

final class MarkTintTests: XCTestCase {
    /// An operational check must recolour nothing: the mark keeps the
    /// provider's identity colour. A healthy logo painted amber reads as an
    /// alert that never ends.
    func testOperationalKeepsProviderIdentityColour() {
        XCTAssertEqual(
            MenuBarLabel.statusTint(.operational, for: .codex),
            providerColor(.codex)
        )
        XCTAssertEqual(
            MenuBarLabel.statusTint(.operational, for: .claude),
            providerColor(.claude)
        )
    }

    func testDegradedRecoloursMarkAmber() {
        XCTAssertEqual(
            MenuBarLabel.statusTint(.degraded, for: .codex),
            MU.warn
        )
        XCTAssertEqual(
            MenuBarLabel.statusTint(.degraded, for: .grok),
            MU.warn
        )
    }

    func testAnyOutageRecoloursMarkRed() {
        XCTAssertEqual(
            MenuBarLabel.statusTint(.partialOutage, for: .codex),
            MU.alert
        )
        XCTAssertEqual(
            MenuBarLabel.statusTint(.majorOutage, for: .claude),
            MU.alert
        )
    }

    func testUnreadableCheckGoesNeutral() {
        XCTAssertEqual(
            MenuBarLabel.statusTint(.unknown, for: .codex),
            MU.neutral
        )
    }

    @MainActor
    func testSideNotchEntriesKeepIdentityMarkWhenHealthy() async throws {
        // A healthy check recolours nothing in the strip either: the mark's
        // tint must come from identity, not from the quota headroom scale.
        let coordinator = try await Self.coordinator(
            quotas: [(Provider.codex, [("Weekly", 60.0, 3600)])],
            statuses: [(Provider.codex, .operational)]
        )

        let entries = SideNotchPanelView.entries(
            menuBarProviders: coordinator.menuBarProviders,
            quotas: coordinator.quotas,
            statuses: coordinator.statuses
        )

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].markTint, providerColor(.codex))
        // Headroom evidence stays on the ring, exactly one place per signal.
        XCTAssertEqual(entries[0].ringTint, Notch.color(usedPercent: 60))
    }

    @MainActor
    func testSideNotchEntriesRecolourMarkOnlyWhenServiceStrays() async throws {
        let coordinator = try await Self.coordinator(
            quotas: [(Provider.codex, [("Weekly", 60.0, 3600)])],
            statuses: [(Provider.codex, .majorOutage)]
        )

        let entries = SideNotchPanelView.entries(
            menuBarProviders: coordinator.menuBarProviders,
            quotas: coordinator.quotas,
            statuses: coordinator.statuses
        )

        XCTAssertEqual(entries[0].markTint, MU.alert)
        XCTAssertEqual(entries[0].ringTint, Notch.color(usedPercent: 60))
    }

    @MainActor
    func testSideNotchEntriesWithoutStatusKeepIdentityMark() async throws {
        // No status source: the mark keeps identity, never borrows the ring's
        // headroom tint, so quota pressure cannot impersonate a service check.
        let coordinator = try await Self.coordinator(
            quotas: [(Provider.codex, [("Weekly", 60.0, 3600)])]
        )

        let entries = SideNotchPanelView.entries(
            menuBarProviders: coordinator.menuBarProviders,
            quotas: coordinator.quotas,
            statuses: coordinator.statuses
        )

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].markTint, providerColor(.codex))
    }

    @MainActor
    private static func coordinator(
        quotas: [(Provider, [(String, Double, TimeInterval?)])],
        statuses: [(Provider, Severity)] = []
    ) async throws -> AppCoordinator {
        let suiteName = "MeterUsageTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: PrefKey.showClaude)
        defaults.set(true, forKey: PrefKey.showAntigravity)
        defaults.set(true, forKey: PrefKey.showGrok)

        let preferences = Preferences(defaults: defaults)
        let coordinator = AppCoordinator(
            preferences: preferences,
            quotaSources: quotas.map { provider, windows in
                StubQuotaSource(
                    provider: provider,
                    windows: windows.map { label, percent, reset in
                        QuotaWindow(label: label, usedPercent: percent, resetsAt: reset.map { Date().addingTimeInterval($0) })
                    }
                )
            },
            statusSources: statuses.map { StubStatusSource(provider: $0.0, severity: $0.1) },
            quotaArchiveURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("meterusage-tests-" + UUID().uuidString + ".json")
        )

        coordinator.refresh()
        for _ in 0..<200 {
            if coordinator.lastRefreshedAt != nil { return coordinator }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        throw NSError(domain: "MarkTintTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "refresh did not complete"])
    }
}

private struct StubQuotaSource: QuotaSource {
    let provider: Provider
    let windows: [QuotaWindow]

    func fetchQuota() async throws -> ProviderQuota {
        ProviderQuota(provider: provider, windows: windows, capturedAt: Date())
    }
}

private struct StubStatusSource: StatusSource {
    let provider: Provider
    let severity: Severity

    func fetchStatus() async throws -> ServiceStatus {
        ServiceStatus(provider: provider, severity: severity, description: "", checkedAt: Date())
    }
}
