import XCTest
@testable import MeterUsage

// MARK: - Multi-account (second-account slots)
//
// A second Claude or Codex account is a separately-configured config
// directory on this Mac, surfaced as its own provider slot (`.codexAlt` /
// `.claudeAlt`). These tests pin the three seams that make that honest:
// where the directory comes from (`AccountSlots`), when the slot exists
// (presence gating in `AppCoordinator`), and that per-slot readings and
// reset actions never leak across accounts.

final class MultiAccountTests: XCTestCase {

    // MARK: Provider identity

    func testAltSlotNamingCarriesNoAccountIdentity() {
        // The slots are labeled by position, never by any account attribute:
        // no email, no id, no org name can be derived from these strings.
        XCTAssertEqual(Provider.codexAlt.displayName, "Codex second account")
        XCTAssertEqual(Provider.claudeAlt.displayName, "Claude second account")
        XCTAssertEqual(Provider.codexAlt.sourceLabel, "Codex CLI · second account")
        XCTAssertEqual(Provider.claudeAlt.sourceLabel, "Claude Code · second account")
    }

    func testAltSlotsResolveToBaseProviderFacts() {
        XCTAssertEqual(Provider.codexAlt.baseProvider, .codex)
        XCTAssertEqual(Provider.claudeAlt.baseProvider, .claude)
        XCTAssertNil(Provider.codex.baseProvider)
        XCTAssertNil(Provider.claude.baseProvider)

        // Shared service page, shared glyph family.
        XCTAssertEqual(Provider.codexAlt.statusPageURL, Provider.codex.statusPageURL)
        XCTAssertEqual(Provider.claudeAlt.statusPageURL, Provider.claude.statusPageURL)
        XCTAssertEqual(Provider.codexAlt.markProvider, .codex)
        XCTAssertEqual(Provider.claudeAlt.markProvider, .claude)
        XCTAssertFalse(Provider.codex.isAltSlot)
        XCTAssertTrue(Provider.claudeAlt.isAltSlot)
    }

    func testAltSlotsFollowTheFamilyHeadlineRules() {
        // The slot is the same tool, so the headline-window contract —
        // the named session window, never positional — must hold identically.
        let codexWindows = [
            QuotaWindow(label: "Weekly", usedPercent: 10, resetsAt: nil),
            QuotaWindow(label: "5-hour", usedPercent: 20, resetsAt: nil),
        ]
        XCTAssertEqual(Provider.codexAlt.headlineWindow(from: codexWindows)?.label, "5-hour")

        let claudeWindows = [
            QuotaWindow(label: "Weekly · All models", usedPercent: 10, resetsAt: nil),
            QuotaWindow(label: "5-hour", usedPercent: 20, resetsAt: nil),
        ]
        XCTAssertEqual(Provider.claudeAlt.headlineWindow(from: claudeWindows)?.label, "5-hour")
    }

    // MARK: AccountSlots resolution

    private final class Overlay: AccountSlots.Environment, @unchecked Sendable {
        private let values: [String: String]
        init(_ values: [String: String]) { self.values = values }
        func string(forKey key: String) -> String? { values[key] }
    }

    func testResolutionPrefersEnvironmentOverDefaults() {
        let home = URL(fileURLWithPath: "/home/testuser")
        let defaults = Overlay([AccountSlots.codexAltHomeKey: "/stored/codex-alt"])
        let env = Overlay([AccountSlots.codexAltHomeKey: "/env/codex-alt"])

        let withEnv = AccountSlots.resolve(
            overlays: [env, defaults],
            home: home
        )
        XCTAssertEqual(withEnv.codexAltHome?.path, "/env/codex-alt")
    }

    func testResolutionFallsBackToStoredDefaults() {
        let home = URL(fileURLWithPath: "/home/testuser")
        let defaults = Overlay([AccountSlots.codexAltHomeKey: "/stored/codex-alt"])

        let resolved = AccountSlots.resolve(overlays: [defaults], home: home)
        XCTAssertEqual(resolved.codexAltHome?.path, "/stored/codex-alt")
        XCTAssertNil(resolved.claudeAltConfig)
    }

    func testResolutionExpandsTildeAgainstTheRealHome() {
        let home = URL(fileURLWithPath: "/home/testuser")
        let overlay = Overlay([
            AccountSlots.codexAltHomeKey: "~/codex-alt",
            AccountSlots.claudeAltConfigKey: "~",
        ])

        let resolved = AccountSlots.resolve(overlays: [overlay], home: home)
        XCTAssertEqual(resolved.codexAltHome?.path, "/home/testuser/codex-alt")
        XCTAssertEqual(resolved.claudeAltConfig?.path, "/home/testuser")
    }

    func testBlankOrMissingKeysMeanUnconfigured() {
        let home = URL(fileURLWithPath: "/home/testuser")
        let overlay = Overlay([
            AccountSlots.codexAltHomeKey: "   ",
            AccountSlots.claudeAltConfigKey: "",
        ])

        let resolved = AccountSlots.resolve(overlays: [overlay], home: home)
        XCTAssertNil(resolved.codexAltHome)
        XCTAssertNil(resolved.claudeAltConfig)
    }

    // MARK: Presence gating

    @MainActor
    func testAltSlotOnlyVisibleWhenItsDirectoryExists() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("meterusage-slots-\(UUID().uuidString)", isDirectory: true)
        let codexHome = base.appendingPathComponent("codex-alt", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let suiteName = "MeterUsageTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: PrefKey.showCodexAlt)
        defaults.set(true, forKey: PrefKey.showClaudeAlt)

        let homes = AccountSlots.Resolved(codexAltHome: codexHome, claudeAltConfig: nil)
        let coordinator = AppCoordinator(
            preferences: Preferences(defaults: defaults),
            slotHomes: homes
        )

        // The configured slot appears; the configured-but-missing one does not.
        XCTAssertTrue(coordinator.visibleProviders.contains(.codexAlt))
        XCTAssertFalse(coordinator.visibleProviders.contains(.claudeAlt))

        // Directory removed mid-session: the slot is no longer an account.
        try FileManager.default.removeItem(at: codexHome)
        XCTAssertFalse(coordinator.visibleProviders.contains(.codexAlt))
    }

    @MainActor
    func testPrimarySlotsAreNeverGatedBySlotPresence() throws {
        let suiteName = "MeterUsageTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: PrefKey.showCodex)

        let coordinator = AppCoordinator(
            preferences: Preferences(defaults: defaults),
            slotHomes: .none
        )
        XCTAssertTrue(coordinator.visibleProviders.contains(.codex))
    }

    // MARK: Per-slot polling and readings

    @MainActor
    func testBothCodexSlotsLoadIntoTheirOwnRows() async throws {
        let suiteName = "MeterUsageTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: PrefKey.showCodexAlt)

        let codexHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("meterusage-slots-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: codexHome) }

        let coordinator = AppCoordinator(
            preferences: Preferences(defaults: defaults),
            quotaSources: [
                StubQuotaSource(
                    provider: .codex,
                    windows: [QuotaWindow(label: "5-hour", usedPercent: 10, resetsAt: nil)]
                ),
                StubQuotaSource(
                    provider: .codexAlt,
                    windows: [QuotaWindow(label: "5-hour", usedPercent: 90, resetsAt: nil)]
                ),
            ],
            slotHomes: AccountSlots.Resolved(codexAltHome: codexHome, claudeAltConfig: nil)
        )

        coordinator.refresh()
        for _ in 0..<200 {
            if coordinator.quotas[.codex]?.value != nil, coordinator.quotas[.codexAlt]?.value != nil { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        // Two slots, two readings, never merged or overwritten.
        XCTAssertEqual(coordinator.quotas[.codex]?.value?.windows.first?.usedPercent, 10)
        XCTAssertEqual(coordinator.quotas[.codexAlt]?.value?.windows.first?.usedPercent, 90)
    }

    // MARK: Reset routing

    private final class ResetBox: @unchecked Sendable {
        var consumed: [Provider: [String]] = [:]
    }

    private struct SlotResetSource: QuotaSource, QuotaResetConsumer {
        let provider: Provider
        let windows: [QuotaWindow]
        let box: ResetBox

        func fetchQuota() async throws -> ProviderQuota {
            ProviderQuota(
                provider: provider,
                windows: windows,
                resetCreditCount: 1,
                resetCredits: [QuotaResetCredit(id: "credit-\(provider.rawValue)", title: "Full reset", status: "available")],
                capturedAt: Date()
            )
        }

        func consumeReset(creditID: String) async throws -> Bool {
            box.consumed[provider, default: []].append(creditID)
            return true
        }
    }

    @MainActor
    func testResetRoutesToTheSlotThatOwnsTheCredit() async throws {
        let suiteName = "MeterUsageTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: PrefKey.showCodexAlt)

        let codexHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("meterusage-slots-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: codexHome) }

        let box = ResetBox()
        let coordinator = AppCoordinator(
            preferences: Preferences(defaults: defaults),
            quotaSources: [
                SlotResetSource(provider: .codex, windows: [], box: box),
                SlotResetSource(provider: .codexAlt, windows: [], box: box),
            ],
            slotHomes: AccountSlots.Resolved(codexAltHome: codexHome, claudeAltConfig: nil)
        )

        // Both slots' credits are redeemable...
        XCTAssertTrue(coordinator.canUseCodexReset(for: .codex))
        XCTAssertTrue(coordinator.canUseCodexReset(for: .codexAlt))
        // ...a non-Codex slot is not...
        XCTAssertFalse(coordinator.canUseCodexReset(for: .claude))

        coordinator.refresh()
        for _ in 0..<200 {
            if coordinator.quotas[.codex]?.value != nil, coordinator.quotas[.codexAlt]?.value != nil { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        // ...and the credit id routes to the slot whose quota reported it.
        try await coordinator.consumeCodexReset(creditID: "credit-codexAlt")
        XCTAssertEqual(box.consumed[.codexAlt], ["credit-codexAlt"])
        XCTAssertNil(box.consumed[.codex])
    }

    // MARK: Source identity threading

    func testCodexQuotaSourceCarriesItsSlotThroughReadingsAndErrors() async throws {
        struct NotSignedInClient: JSONRPCClient {
            func requestCodexRateLimits() async throws -> Data {
                Data(#"{"id":2,"error":{"code":-32000,"message":"Not logged in"}}"#.utf8)
            }
            func consumeCodexRateLimitReset(creditID: String) async throws -> Data {
                Data("{}".utf8)
            }
        }

        let alt = CodexQuotaSource(provider: .codexAlt, client: NotSignedInClient())
        do {
            _ = try await alt.fetchQuota()
            XCTFail("expected notSignedIn")
        } catch let reason as SourceUnavailable {
            // The error names the slot, so the calm empty state says which
            // account to sign in rather than ambiguously "Codex".
            XCTAssertEqual(reason, .notSignedIn(.codexAlt))
        }
    }

    func testClaudeLocalSourceCarriesItsSlotThroughScans() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("meterusage-tests-\(UUID().uuidString)", isDirectory: true)
        let projects = base.appendingPathComponent("projects", isDirectory: true)
        let projectDir = projects.appendingPathComponent("-Users-testuser-Developer-samplerepo", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        guard let fixture = Bundle.module.url(forResource: "claude_session_sample", withExtension: "jsonl", subdirectory: "Fixtures") else {
            XCTFail("missing fixture claude_session_sample.jsonl")
            return
        }
        try FileManager.default.copyItem(at: fixture, to: projectDir.appendingPathComponent("session-one.jsonl"))
        defer { try? FileManager.default.removeItem(at: base) }

        let altSource = ClaudeLocalSource(
            provider: .claudeAlt,
            root: projects,
            cacheFileURL: base.appendingPathComponent("cache-alt.json")
        )
        let activity = try await altSource.scan()
        XCTAssertEqual(activity.provider, .claudeAlt)
    }

    func testQuotaArchiveRoundTripsAltSlots() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("meterusage-tests-archive-\(UUID().uuidString).json")
        let quotas: [Provider: ProviderQuota] = [
            .codexAlt: ProviderQuota(
                provider: .codexAlt,
                windows: [QuotaWindow(label: "5-hour", usedPercent: 33, resetsAt: nil)],
                capturedAt: Date(timeIntervalSince1970: 1_785_000_000)
            ),
        ]
        QuotaArchive.save(quotas, to: url)
        let loaded = QuotaArchive.load(from: url)
        XCTAssertEqual(loaded[.codexAlt]?.windows.first?.usedPercent, 33)
        try? FileManager.default.removeItem(at: url)
    }

    func testDurableHistoryKeysPerSlot() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("meterusage-tests-history-\(UUID().uuidString).json")
        let store = DurableHistoryStore(storeURL: url)
        let day = DailyActivity(
            day: Date(timeIntervalSince1970: 1_785_000_000),
            tokens: TokenTotals(input: 100, output: 10),
            estimatedCostUSD: 0,
            sessionCount: 2
        )
        store.record(provider: .codexAlt, daily: [day])
        XCTAssertEqual(store.records(for: .codexAlt).first?.tokens.input, 100)
        XCTAssertNil(store.records(for: .codex).first, "second-account history must not leak into the primary slot")
        try? FileManager.default.removeItem(at: url)
    }

    func testLimitsReportEmitsDistinctSlotEntries() {
        let now = Date()
        let report = LimitsReporter.build(
            quotas: [
                .codex: .value(ProviderQuota(
                    provider: .codex,
                    windows: [QuotaWindow(label: "5-hour", usedPercent: 10, resetsAt: nil)],
                    capturedAt: now
                )),
                .codexAlt: .value(ProviderQuota(
                    provider: .codexAlt,
                    windows: [QuotaWindow(label: "5-hour", usedPercent: 80, resetsAt: nil)],
                    capturedAt: now
                )),
            ],
            order: [.codex, .codexAlt],
            now: now
        )

        XCTAssertEqual(report.providers.map(\.provider), ["codex", "codexAlt"])
        XCTAssertEqual(report.providers.map(\.windows.first?.usedPercent), [10, 80])
    }
}

private struct StubQuotaSource: QuotaSource {
    let provider: Provider
    let windows: [QuotaWindow]

    func fetchQuota() async throws -> ProviderQuota {
        ProviderQuota(provider: provider, windows: windows, capturedAt: Date())
    }
}
