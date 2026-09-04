import XCTest
@testable import MeterUsage

final class SideNotchPanelTests: XCTestCase {

    // MARK: - Layout

    func testFrameHugsRightEdgeBelowMenuBar() {
        let screen = NSRect(x: 0, y: 0, width: 1512, height: 982)
        let frame = SideNotchPanelLayout.frame(
            contentSize: CGSize(width: 58, height: 200),
            screenFrame: screen,
            topInset: 32
        )

        XCTAssertEqual(frame.maxX, screen.maxX - SideNotchPanelLayout.rightInset)
        XCTAssertEqual(frame.maxY, screen.maxY - 32)
        XCTAssertEqual(frame.width, 58)
        XCTAssertEqual(frame.height, 200)
    }

    func testFrameAnchorsTopRightCornerAcrossSizes() {
        // The expanded card must grow leftward and downward while the strip
        // stays where the user learned to find it.
        let screen = NSRect(x: 0, y: 0, width: 1728, height: 1117)
        let collapsed = SideNotchPanelLayout.frame(
            contentSize: CGSize(width: 58, height: 150),
            screenFrame: screen,
            topInset: 25
        )
        let expanded = SideNotchPanelLayout.frame(
            contentSize: CGSize(width: 300, height: 420),
            screenFrame: screen,
            topInset: 25
        )

        XCTAssertEqual(collapsed.maxX, expanded.maxX)
        XCTAssertEqual(collapsed.maxY, expanded.maxY)
        // AppKit y rises upward, so "grows downward" means a smaller bottom edge.
        XCTAssertGreaterThan(collapsed.minX, expanded.minX)
        XCTAssertLessThan(expanded.minY, collapsed.minY)
    }

    // MARK: - Entries

    @MainActor
    func testEntriesTakeTightestWindowInMenuBarOrder() async throws {
        let coordinator = try await Self.coordinator(quotas: [
            // Grok listed first in the fixtures but Codex must lead: ordering
            // follows the stable display order, not the sweep order.
            (Provider.grok, [("Weekly", 40.0, nil)]),
            (Provider.codex, [("Weekly", 30.0, nil), ("5-hour", 80.0, 3600)]),
        ])

        let entries = SideNotchPanelView.entries(
            menuBarProviders: coordinator.menuBarProviders,
            quotas: coordinator.quotas,
            statuses: coordinator.statuses
        )

        XCTAssertEqual(entries.map(\.provider), [.codex, .grok])
        XCTAssertEqual(entries[0].usedPercent, 80)
        XCTAssertEqual(entries[1].usedPercent, 40)
    }

    @MainActor
    func testEntriesSkipProvidersWithoutQuotaData() async throws {
        // Grok is enabled but has no source, so it must not render an empty ring.
        let coordinator = try await Self.coordinator(quotas: [
            (Provider.codex, [("Weekly", 30.0, nil)]),
        ])

        let entries = SideNotchPanelView.entries(
            menuBarProviders: coordinator.menuBarProviders,
            quotas: coordinator.quotas,
            statuses: coordinator.statuses
        )

        XCTAssertEqual(entries.map(\.provider), [.codex])
    }

    @MainActor
    func testEntriesCarryResetDate() async throws {
        let coordinator = try await Self.coordinator(quotas: [
            (Provider.codex, [("5-hour", 80.0, 3600)]),
        ])

        let entries = SideNotchPanelView.entries(
            menuBarProviders: coordinator.menuBarProviders,
            quotas: coordinator.quotas,
            statuses: coordinator.statuses
        )

        XCTAssertEqual(entries.count, 1)
        XCTAssertNotNil(entries[0].resetsAt)
    }

    // MARK: - Dragged position

    func testCornerFrameKeepsTopRightCorner() {
        let screen = NSRect(x: 0, y: 0, width: 1728, height: 1117)
        let frame = SideNotchPanelLayout.frame(
            corner: CGPoint(x: 800, y: 600),
            contentSize: CGSize(width: 58, height: 150),
            screenFrame: screen
        )

        XCTAssertEqual(frame.maxX, 800)
        XCTAssertEqual(frame.maxY, 600)
        XCTAssertEqual(frame.width, 58)
        XCTAssertEqual(frame.height, 150)
    }

    func testCornerFrameClampsIntoScreen() {
        let screen = NSRect(x: 0, y: 0, width: 1728, height: 1117)
        // Corner parked past the right edge and above the top: the panel must
        // be pulled back inside rather than rendered off-screen.
        let frame = SideNotchPanelLayout.frame(
            corner: CGPoint(x: 5000, y: 3000),
            contentSize: CGSize(width: 58, height: 150),
            screenFrame: screen
        )

        XCTAssertEqual(frame.maxX, screen.maxX - SideNotchPanelLayout.rightInset)
        XCTAssertEqual(frame.maxY, screen.maxY)
        XCTAssertGreaterThanOrEqual(frame.minX, screen.minX)
        XCTAssertGreaterThanOrEqual(frame.minY, screen.minY)
    }

    func testCornerRoundTripsAndRejectsGarbage() {
        let corner = CGPoint(x: 1648.5, y: 38)
        let restored = SideNotchPanelLayout.restoredCorner(
            SideNotchPanelLayout.cornerString(corner)
        )
        XCTAssertEqual(restored?.x, corner.x)
        XCTAssertEqual(restored?.y, corner.y)

        XCTAssertNil(SideNotchPanelLayout.restoredCorner(nil))
        XCTAssertNil(SideNotchPanelLayout.restoredCorner(""))
        XCTAssertNil(SideNotchPanelLayout.restoredCorner("12"))
        XCTAssertNil(SideNotchPanelLayout.restoredCorner("a,b"))
        XCTAssertNil(SideNotchPanelLayout.restoredCorner("1,2,3"))
    }

    // MARK: - Preference

    @MainActor
    func testSideNotchPanelDefaultsOffAndPersists() throws {
        let suiteName = "MeterUsageTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = Preferences(defaults: defaults)
        XCTAssertFalse(first.sideNotchPanelEnabled)

        defaults.set(true, forKey: PrefKey.sideNotchPanel)
        let second = Preferences(defaults: defaults)
        XCTAssertTrue(second.sideNotchPanelEnabled)
    }

    @MainActor
    func testMenuBarCompactDefaultsOnAndPersists() throws {
        // Compact is the default: the side notch panel carries the usage and
        // the tray stays one mark. The two switches stay independent either
        // way — enabling the notch must not force compact, and dismissing
        // compact must stick.
        let suiteName = "MeterUsageTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = Preferences(defaults: defaults)
        XCTAssertTrue(first.menuBarCompactEnabled)

        defaults.set(true, forKey: PrefKey.sideNotchPanel)
        let mid = Preferences(defaults: defaults)
        XCTAssertTrue(mid.menuBarCompactEnabled, "the notch toggle must not empty or fill the tray by itself")

        defaults.set(false, forKey: PrefKey.menuBarCompact)
        let last = Preferences(defaults: defaults)
        XCTAssertFalse(last.menuBarCompactEnabled)
        XCTAssertTrue(last.sideNotchPanelEnabled)
    }

    @MainActor
    func testOnboardingFlagStartsAbsentAndPersists() throws {
        // Absent is what shows the welcome page; either button writes it
        // through and the page never returns. The flag flows through
        // UserDefaults alone — no `Preferences` property is wanted.
        let suiteName = "MeterUsageTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(defaults.bool(forKey: PrefKey.onboardingDone), "the welcome page must show on first run")

        defaults.set(true, forKey: PrefKey.onboardingDone)
        XCTAssertTrue(defaults.bool(forKey: PrefKey.onboardingDone))
    }

    // MARK: - Helpers

    /// Builds a coordinator with stub quota sources and lets one refresh sweep
    /// run to completion. Same pattern as `MenuBarTests`.
    @MainActor
    private static func coordinator(
        quotas: [(Provider, [(String, Double, TimeInterval?)])]
    ) async throws -> AppCoordinator {
        let suiteName = "MeterUsageTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
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
            }
        )

        coordinator.refresh()
        for _ in 0..<200 {
            if coordinator.lastRefreshedAt != nil { return coordinator }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        throw NSError(domain: "SideNotchPanelTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "refresh did not complete"])
    }
}

private struct StubQuotaSource: QuotaSource {
    let provider: Provider
    let windows: [QuotaWindow]

    func fetchQuota() async throws -> ProviderQuota {
        ProviderQuota(provider: provider, windows: windows, capturedAt: Date())
    }
}
