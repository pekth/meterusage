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

    func testCardStaysLeftByDefault() {
        let screen = NSRect(x: 0, y: 0, width: 4270, height: 1112)
        XCTAssertFalse(SideNotchPanelLayout.cardOnRight(
            stripTopRightX: 4262, stripWidth: 50, screenFrame: screen, cardWidth: 250
        ))
    }

    func testCardFlipsRightWhenTheStripMovesLeft() {
        let screen = NSRect(x: 0, y: 0, width: 4270, height: 1112)
        XCTAssertTrue(SideNotchPanelLayout.cardOnRight(
            stripTopRightX: 200, stripWidth: 50, screenFrame: screen, cardWidth: 250
        ))
    }

    func testCardPicksTheRoomierSideWhenNeitherFits() {
        let screen = NSRect(x: 0, y: 0, width: 400, height: 1112)
        // 250pt card overflows on both sides here: left holds 140pt against
        // 210pt right, so right wins; mirrored, left wins 250pt to 100pt.
        XCTAssertTrue(SideNotchPanelLayout.cardOnRight(
            stripTopRightX: 190, stripWidth: 50, screenFrame: screen, cardWidth: 250
        ))
        XCTAssertFalse(SideNotchPanelLayout.cardOnRight(
            stripTopRightX: 300, stripWidth: 50, screenFrame: screen, cardWidth: 250
        ))
    }

    func testCardLeftGrowsAwayFromTheStrip() {
        let screen = NSRect(x: 0, y: 0, width: 4270, height: 1112)
        let corner = CGPoint(x: 4262, y: 1077)
        let withoutCard = SideNotchPanelLayout.notchFrame(
            stripTopRight: corner, totalSize: CGSize(width: 50, height: 220),
            stripWidth: 50, cardOnRight: false, screenFrame: screen
        )
        let withCard = SideNotchPanelLayout.notchFrame(
            stripTopRight: corner, totalSize: CGSize(width: 300, height: 340),
            stripWidth: 50, cardOnRight: false, screenFrame: screen
        )
        // Strip's top-right corner is identical: the card grows left and down.
        XCTAssertEqual(withoutCard.maxX, withCard.maxX)
        XCTAssertEqual(withoutCard.maxY, withCard.maxY)
        XCTAssertEqual(withCard.minX, 4262 - 300)
    }

    func testCardRightGrowsAwayFromTheStrip() {
        let screen = NSRect(x: 0, y: 0, width: 4270, height: 1112)
        let corner = CGPoint(x: 300, y: 1077)
        let withoutCard = SideNotchPanelLayout.notchFrame(
            stripTopRight: corner, totalSize: CGSize(width: 50, height: 220),
            stripWidth: 50, cardOnRight: true, screenFrame: screen
        )
        let withCard = SideNotchPanelLayout.notchFrame(
            stripTopRight: corner, totalSize: CGSize(width: 300, height: 340),
            stripWidth: 50, cardOnRight: true, screenFrame: screen
        )
        // Strip's left edge is identical: the card grows right and down.
        XCTAssertEqual(withoutCard.minX, withCard.minX)
        XCTAssertEqual(withoutCard.maxY, withCard.maxY)
        XCTAssertEqual(withCard.minX, 300 - 50)
        XCTAssertEqual(withCard.maxX, 300 - 50 + 300)
    }

    func testNotchFrameClampsIntoTheScreen() {
        let screen = NSRect(x: 0, y: 0, width: 800, height: 600)
        let frame = SideNotchPanelLayout.notchFrame(
            stripTopRight: CGPoint(x: 790, y: 100),
            totalSize: CGSize(width: 300, height: 400),
            stripWidth: 50, cardOnRight: false, screenFrame: screen
        )
        XCTAssertGreaterThanOrEqual(frame.minX, screen.minX)
        XCTAssertGreaterThanOrEqual(frame.minY, screen.minY)
        XCTAssertLessThanOrEqual(frame.maxX, screen.maxX)
        XCTAssertLessThanOrEqual(frame.maxY, screen.maxY)
    }

    // MARK: - Token formatting

    func testTokenCountStringFormatting() {
        XCTAssertEqual(Fmt.tokenCountString(1_250_000_000), "1.25b")
        XCTAssertEqual(Fmt.tokenCountString(20_300_000), "20.3m")
        XCTAssertEqual(Fmt.tokenCountString(450_000), "450k")
        XCTAssertEqual(Fmt.tokenCountString(2_500), "2.5k")
        XCTAssertEqual(Fmt.tokenCountString(500), "500")
        XCTAssertEqual(Fmt.tokenCountString(0), "0")
    }

    // MARK: - Entries

    @MainActor
    func testEntriesTakeHeadlineWindowInMenuBarOrder() async throws {
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
    func testEntriesKeepSessionSubjectAfterReset() async throws {
        // The 5-hour window just reset to ~0% while Weekly sits at 72: the
        // ring must read the fresh session, not promote the weekly into its
        // place at exactly the moment someone is looking at it.
        let coordinator = try await Self.coordinator(quotas: [
            (Provider.codex, [("Weekly", 72.0, 3600), ("5-hour", 12.0, 3600)]),
        ])

        let entries = SideNotchPanelView.entries(
            menuBarProviders: coordinator.menuBarProviders,
            quotas: coordinator.quotas,
            statuses: coordinator.statuses
        )

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].usedPercent, 12)
    }

    @MainActor
    func testEntriesShowLoneWindowForSingleAllowancePlans() async throws {
        // Plans reporting a single window (`secondary == null`) have no
        // session to name: the lone allowance is the headline as-is.
        let coordinator = try await Self.coordinator(quotas: [
            (Provider.codex, [("Weekly", 31.0, 3600)]),
        ])

        let entries = SideNotchPanelView.entries(
            menuBarProviders: coordinator.menuBarProviders,
            quotas: coordinator.quotas,
            statuses: coordinator.statuses
        )

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].usedPercent, 31)
    }

    @MainActor
    func testEntriesPreferRollingForOpenCodeGo() async throws {
        let coordinator = try await Self.coordinator(quotas: [
            (Provider.openCodeGo, [("Rolling", 20.0, 3600), ("Weekly", 77.0, 3600)]),
        ])

        let entries = SideNotchPanelView.entries(
            menuBarProviders: coordinator.menuBarProviders,
            quotas: coordinator.quotas,
            statuses: coordinator.statuses
        )

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].usedPercent, 20)
    }

    @MainActor
    func testEntriesKeepClaudeSessionAtZeroAfterReset() async throws {
        // Same reset-survival rule as Codex: a fresh 5-hour window reads 0%,
        // which is the truth — not the 61% weekly beside it.
        let coordinator = try await Self.coordinator(quotas: [
            (Provider.claude, [("5-hour", 0.0, 3600), ("Weekly · All models", 61.0, 3600)]),
        ])

        let entries = SideNotchPanelView.entries(
            menuBarProviders: coordinator.menuBarProviders,
            quotas: coordinator.quotas,
            statuses: coordinator.statuses
        )

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].usedPercent, 0)
    }

    @MainActor
    func testEntriesFallBackToLegacySevenDayForClaude() async throws {
        // Writers that never emit a session window still get a ring from the
        // bare legacy key — but a limits[]-shaped weekly is never promoted.
        let legacy = try await Self.coordinator(quotas: [
            (Provider.claude, [("7-day", 44.0, 3600)]),
        ])
        let legacyEntries = SideNotchPanelView.entries(
            menuBarProviders: legacy.menuBarProviders,
            quotas: legacy.quotas,
            statuses: legacy.statuses
        )
        XCTAssertEqual(legacyEntries.count, 1)
        XCTAssertEqual(legacyEntries[0].usedPercent, 44)

        let transient = try await Self.coordinator(quotas: [
            (Provider.claude, [("Weekly · All models", 61.0, 3600)]),
        ])
        let transientEntries = SideNotchPanelView.entries(
            menuBarProviders: transient.menuBarProviders,
            quotas: transient.quotas,
            statuses: transient.statuses
        )
        XCTAssertTrue(
            transientEntries.isEmpty,
            "a session-less limits[] snapshot must show no ring, not the weekly wearing its place"
        )
    }

    func testNotchBandThresholdsMatchHeadroomScale() {
        // The notch hues differ from the popover, but the thresholds must
        // not: severity can never disagree between the two surfaces.
        XCTAssertEqual(NotchBand.band(usedPercent: 0), .plenty)
        XCTAssertEqual(NotchBand.band(usedPercent: 49.9), .plenty)
        XCTAssertEqual(NotchBand.band(usedPercent: 50), .gettingClose)
        XCTAssertEqual(NotchBand.band(usedPercent: 79.9), .gettingClose)
        XCTAssertEqual(NotchBand.band(usedPercent: 80), .nearlyOut)
        XCTAssertEqual(NotchBand.band(usedPercent: 99.9), .nearlyOut)
        XCTAssertEqual(NotchBand.band(usedPercent: 100), .atLimit)
        XCTAssertEqual(NotchBand.band(usedPercent: 140), .atLimit)
    }

    @MainActor
    func testHeadlineWindowKeepsMaxForAntigravity() {        // Dynamic per-group labels carry no session concept: most-constrained
        // stays the honest figure there.
        let windows = [
            QuotaWindow(label: "Gemini 3h", usedPercent: 20, resetsAt: nil),
            QuotaWindow(label: "Claude 5h", usedPercent: 65, resetsAt: nil),
        ]
        XCTAssertEqual(Provider.antigravity.headlineWindow(from: windows)?.usedPercent, 65)
        XCTAssertNil(Provider.codex.headlineWindow(from: []))
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

    @MainActor
    func testBeakGeometryAndBoundsCheck() throws {
        let entry0 = SideNotchPanelView.Entry(
            provider: .claude,
            usedPercent: 20,
            fraction: 0.2,
            ringTint: .green,
            markTint: .green,
            resetsAt: nil,
            isStale: false
        )
        let entry1 = SideNotchPanelView.Entry(
            provider: .codex,
            usedPercent: 40,
            fraction: 0.4,
            ringTint: .green,
            markTint: .green,
            resetsAt: nil,
            isStale: false
        )
        let entry2 = SideNotchPanelView.Entry(
            provider: .openRouter,
            usedPercent: 32,
            fraction: 0.32,
            ringTint: .green,
            markTint: .green,
            resetsAt: nil,
            isStale: false
        )
        let entries = [entry0, entry1, entry2]

        // Index 0: 19 + 0 * 43 = 19
        XCTAssertEqual(SideNotchPanelView.ringCenterY(for: .claude, in: entries), 19)
        XCTAssertEqual(SideNotchPanelView.beakYOnCard(for: .claude, in: entries), 13)

        // Index 2 (OpenRouter): 19 + 2 * 43 = 105
        XCTAssertEqual(SideNotchPanelView.ringCenterY(for: .openRouter, in: entries), 105)
        XCTAssertEqual(SideNotchPanelView.beakYOnCard(for: .openRouter, in: entries), 99)

        // Unknown provider defaults to first index position (19, beak 13)
        XCTAssertEqual(SideNotchPanelView.ringCenterY(for: .antigravity, in: entries), 19)

        // Beak bounds checking: beak height is 12pt (beakY ... beakY + 12)
        // If card height is shorter than beak bottom, isBeakWithinBounds must be false.
        let beakY: CGFloat = 99
        XCTAssertFalse(SideNotchPanelView.isBeakWithinBounds(beakY: beakY, cardHeight: 100))
        XCTAssertFalse(SideNotchPanelView.isBeakWithinBounds(beakY: beakY, cardHeight: 110))
        XCTAssertTrue(SideNotchPanelView.isBeakWithinBounds(beakY: beakY, cardHeight: 111))
        XCTAssertTrue(SideNotchPanelView.isBeakWithinBounds(beakY: beakY, cardHeight: 200))

        // Negative beakY must not be rendered
        XCTAssertFalse(SideNotchPanelView.isBeakWithinBounds(beakY: -5, cardHeight: 200))
    }

    @MainActor
    func testOpenRouterEffectiveWindowsAndEntry() throws {
        // Case 1: OpenRouter with credits spend and total limit (pay-as-you-go configuration)
        let creditsQuota = ProviderQuota(
            provider: .openRouter,
            windows: [],
            credits: CreditBalance(
                balance: 6.78,
                hasCredits: true,
                unlimited: false,
                unit: .dollars,
                usedDollars: 3.22,
                limitDollars: 10.00
            ),
            capturedAt: Date()
        )
        let windows = SideNotchPanelView.effectiveWindows(for: .openRouter, quota: creditsQuota)
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].label, "Account balance")
        XCTAssertEqual(windows[0].usedPercent, 32.2, accuracy: 0.01)
        XCTAssertNil(windows[0].resetsAt)

        // Entry generation for OpenRouter
        let entries = SideNotchPanelView.entries(
            providers: [.openRouter],
            quotas: [.openRouter: .value(creditsQuota)],
            statuses: [:]
        )
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].provider, Provider.openRouter)
        XCTAssertEqual(entries[0].usedPercent, 32.2, accuracy: 0.01)

        // Case 2: OpenRouter with an explicit key limit window
        let keyWindowQuota = ProviderQuota(
            provider: .openRouter,
            windows: [QuotaWindow(label: "Monthly", usedPercent: 15, resetsAt: Date().addingTimeInterval(86400))],
            credits: CreditBalance(
                balance: 50.0,
                hasCredits: true,
                unlimited: false,
                unit: .dollars,
                usedDollars: 5.0,
                limitDollars: 100.0
            ),
            capturedAt: Date()
        )
        let keyWindows = SideNotchPanelView.effectiveWindows(for: .openRouter, quota: keyWindowQuota)
        XCTAssertEqual(keyWindows.count, 1)
        XCTAssertEqual(keyWindows[0].label, "Monthly")
        XCTAssertEqual(keyWindows[0].usedPercent, 15)

        // Case 3: Other providers (e.g. Claude) do not synthesize from credits
        let claudeQuota = ProviderQuota(
            provider: .claude,
            windows: [],
            credits: CreditBalance(
                balance: 20.0,
                hasCredits: true,
                unlimited: false,
                unit: .dollars,
                usedDollars: 5.0,
                limitDollars: 100.0
            ),
            capturedAt: Date()
        )
        XCTAssertTrue(SideNotchPanelView.effectiveWindows(for: .claude, quota: claudeQuota).isEmpty)
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
    func testSideNotchPanelPinnedDefaultsOffAndPersists() throws {
        let suiteName = "MeterUsageTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = Preferences(defaults: defaults)
        XCTAssertFalse(first.sideNotchPanelPinned)

        defaults.set(true, forKey: PrefKey.sideNotchPanelPinned)
        let second = Preferences(defaults: defaults)
        XCTAssertTrue(second.sideNotchPanelPinned)
    }

    @MainActor
    func testRefreshProviderOnlyLoadsThatProvider() async throws {
        let suiteName = "MeterUsageTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: PrefKey.showGrok)

        let preferences = Preferences(defaults: defaults)
        let coordinator = AppCoordinator(
            preferences: preferences,
            quotaSources: [
                StubQuotaSource(provider: .codex, windows: [
                    QuotaWindow(label: "Weekly", usedPercent: 30, resetsAt: nil),
                ]),
                StubQuotaSource(provider: .grok, windows: [
                    QuotaWindow(label: "Weekly", usedPercent: 40, resetsAt: nil),
                ]),
            ],
            quotaArchiveURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("meterusage-tests-" + UUID().uuidString + ".json")
        )

        // A single-provider refresh must load that provider without touching
        // the other: one cell never spends the others' rate-limit budget.
        coordinator.refresh(provider: .codex)
        for _ in 0..<200 {
            if coordinator.lastRefreshedAt != nil { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotNil(coordinator.quotas[.codex]?.value)
        XCTAssertNil(coordinator.quotas[.grok]?.value)
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

    @MainActor
    func testSideNotchResetButtonDefaultsOnAndPersists() throws {
        let suiteName = "MeterUsageTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = Preferences(defaults: defaults)
        XCTAssertTrue(first.showSideNotchResetButton)

        defaults.set(false, forKey: PrefKey.showSideNotchResetButton)
        let second = Preferences(defaults: defaults)
        XCTAssertFalse(second.showSideNotchResetButton)
    }

    private struct StubResetConsumer: QuotaResetConsumer {
        func consumeReset(creditID: String) async throws -> Bool { true }
    }

    @MainActor
    func testCoordinatorCanUseCodexResetReflectsConsumer() throws {
        let suiteName = "MeterUsageTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let prefs = Preferences(defaults: defaults)

        let withoutConsumer = AppCoordinator(preferences: prefs)
        XCTAssertFalse(withoutConsumer.canUseCodexReset)

        let withConsumer = AppCoordinator(
            preferences: prefs,
            resetConsumer: StubResetConsumer()
        )
        XCTAssertTrue(withConsumer.canUseCodexReset)
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
            // Never touch the real archive: a remembered reading on the
            // developer's own machine must not leak into fixture assertions.
            quotaArchiveURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("meterusage-tests-" + UUID().uuidString + ".json")
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
