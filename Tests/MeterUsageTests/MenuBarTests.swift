import XCTest
@testable import MeterUsage

final class MenuBarTests: XCTestCase {

    // MARK: - Menu bar provider selection

    @MainActor
    func testMenuBarProvidersDefaultToAllEnabled() throws {
        let suiteName = "MeterUsageTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = Preferences(defaults: defaults)
        XCTAssertEqual(preferences.menuBarProviders, Set(Provider.allCases))
        XCTAssertTrue(preferences.showsInMenuBar(.codex))
        XCTAssertTrue(preferences.showsInMenuBar(.grok))
    }

    @MainActor
    func testMenuBarProvidersPersistAcrossReinitialization() throws {
        let suiteName = "MeterUsageTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(false, forKey: PrefKey.menuBarGrok)
        defaults.set(true, forKey: PrefKey.showGrok)

        let first = Preferences(defaults: defaults)
        let second = Preferences(defaults: defaults)

        XCTAssertEqual(first.menuBarProviders, Set([.codex, .antigravity, .openCodeGo, .openRouter, .claude]))
        XCTAssertEqual(second.menuBarProviders, first.menuBarProviders)
        XCTAssertFalse(first.showsInMenuBar(.grok))
    }

    // MARK: - Tooltip

    @MainActor
    func testTooltipListsEachProviderWithResetsAndStatus() async throws {
        let coordinator = try await Self.coordinator(
            quotaWindows: [
                (Provider.codex, "Weekly", 82, 7200),
                (Provider.grok, "Monthly", 40, nil),
            ],
            statuses: [(Provider.codex, Severity.degraded)]
        )

        let tooltip = AppDelegate.tooltip(for: coordinator)
        XCTAssertTrue(tooltip.contains("Codex: 82% used"), tooltip)
        XCTAssertTrue(tooltip.contains("Degraded"), tooltip)
        XCTAssertTrue(tooltip.contains("resets in"), tooltip)
        // 7200s is "2h" but a refresh a moment later rounds to "1h 59m".
        XCTAssertNotNil(
            tooltip.range(of: #"resets in \d+h"#, options: .regularExpression),
            tooltip
        )
        XCTAssertTrue(tooltip.contains("Grok: 40% used"), tooltip)
        XCTAssertTrue(tooltip.contains("Updated"), tooltip)
    }

    @MainActor
    func testTooltipFlagsProviderWithNoQuotaButBadService() async throws {
        let coordinator = try await Self.coordinator(
            quotaWindows: [(Provider.codex, "Weekly", 82, nil)],
            statuses: [(Provider.grok, Severity.majorOutage)]
        )

        let tooltip = AppDelegate.tooltip(for: coordinator)
        XCTAssertTrue(tooltip.contains("Grok: Major Outage"), tooltip)
    }

    @MainActor
    func testTooltipShowsNoDataWhenNothingHasLoaded() throws {
        let suiteName = "MeterUsageTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let coordinator = AppCoordinator(preferences: Preferences(defaults: defaults))
        let tooltip = AppDelegate.tooltip(for: coordinator)
        XCTAssertEqual(tooltip, "No usage data yet")
    }

    // MARK: - Helpers

    /// Builds a coordinator with stub quota and status sources and lets one
    /// refresh sweep run to completion.
    @MainActor
    private static func coordinator(
        quotaWindows: [(Provider, String, Double, TimeInterval?)],
        statuses: [(Provider, Severity)] = []
    ) async throws -> AppCoordinator {
        let suiteName = "MeterUsageTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: PrefKey.showGrok)
        defaults.set(true, forKey: PrefKey.showOpenCodeGo)
        defaults.set(true, forKey: PrefKey.showOpenRouter)

        let preferences = Preferences(defaults: defaults)
        let coordinator = AppCoordinator(
            preferences: preferences,
            quotaSources: quotaWindows.map {
                StubQuotaSource(provider: $0.0, label: $0.1, percent: $0.2, resetsAt: $0.3.map { Date().addingTimeInterval($0) })
            },
            statusSources: statuses.map { StubStatusSource(provider: $0.0, severity: $0.1) }
        )

        coordinator.refresh()
        for _ in 0..<200 {
            if coordinator.lastRefreshedAt != nil { return coordinator }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        throw NSError(domain: "MenuBarTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "refresh did not complete"])
    }
}

private struct StubQuotaSource: QuotaSource {
    let provider: Provider
    let label: String
    let percent: Double
    let resetsAt: Date?

    func fetchQuota() async throws -> ProviderQuota {
        ProviderQuota(
            provider: provider,
            windows: [QuotaWindow(label: label, usedPercent: percent, resetsAt: resetsAt)],
            capturedAt: Date()
        )
    }
}

private struct StubStatusSource: StatusSource {
    let provider: Provider
    let severity: Severity

    func fetchStatus() async throws -> ServiceStatus {
        ServiceStatus(provider: provider, severity: severity, description: "", checkedAt: Date())
    }
}