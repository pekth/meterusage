import XCTest
@testable import MeterUsage

// MARK: - Multi-account (additional account slots)
//
// An additional Claude or Codex account is a user-configured config
// directory, stored as a `ManagedAccount` and surfaced as its own
// `ProviderSlot` meter. These tests pin the seams that make that honest:
// slot identity and keying, presence gating, per-slot polling and reset
// routing, and the persistence/report formats.

final class MultiAccountTests: XCTestCase {

    // MARK: Slot identity

    func testSlotNamingCarriesNoAccountIdentity() {
        // A slot is named by the user's own label, never by any account
        // attribute: no email, no id, no org name can be derived from it.
        let work = ProviderSlot(provider: .codex, slotID: "abc", label: "Work")
        XCTAssertEqual(work.displayName, "Codex · Work")
        XCTAssertEqual(ProviderSlot(provider: .claude, slotID: "abc").displayName, "Claude · Account")
        XCTAssertEqual(ProviderSlot.primary(.codex).displayName, "Codex")
    }

    func testSlotKeyIsStableAcrossLabelRenames() {
        // Identity is provider + generated id; the label is display-only.
        // Renaming must not orphan history, archive, or alert state.
        let before = ProviderSlot(provider: .codex, slotID: "abc", label: "Work")
        let after = ProviderSlot(provider: .codex, slotID: "abc", label: "Job")
        XCTAssertEqual(before.key, after.key)
        XCTAssertEqual(before, after)
    }

    func testPrimarySlotKeyMatchesTheProviderRawValue() {
        // Pre-slot persistence formats keyed by provider.rawValue keep working.
        XCTAssertEqual(ProviderSlot.primary(.codex).key, "codex")
        XCTAssertEqual(ProviderSlot.primary(.claude).key, "claude")
    }

    func testPrimarySlotsSortBeforeAdditionalSlotsOfOneTool() {
        let a = ProviderSlot(provider: .codex, slotID: "b", label: "B")
        let b = ProviderSlot(provider: .codex, slotID: "c", label: "C")
        let primary = ProviderSlot.primary(.codex)
        XCTAssertTrue(primary < a)
        XCTAssertTrue(a < b)
        XCTAssertTrue(a < .primary(.claude))
    }

    // MARK: Managed account persistence

    @MainActor
    func testManagedAccountsRoundTripThroughPreferences() throws {
        let suiteName = "MeterUsageTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = Preferences(defaults: defaults)
        XCTAssertTrue(preferences.managedAccounts.isEmpty)

        preferences.add(account: ManagedAccount(provider: .codex, label: "Work", path: "~/.codex-work"))
        preferences.add(account: ManagedAccount(provider: .claude, label: "Personal", path: "~/.claude-alt", enabled: false))

        let reloaded = Preferences(defaults: defaults)
        XCTAssertEqual(reloaded.managedAccounts.count, 2)
        XCTAssertEqual(reloaded.managedAccounts[0].label, "Work")
        XCTAssertEqual(reloaded.managedAccounts[0].slot.provider, .codex)
        XCTAssertFalse(reloaded.managedAccounts[1].enabled)

        var edited = reloaded.managedAccounts[0]
        edited.label = "Job"
        reloaded.update(account: edited)
        XCTAssertEqual(Preferences(defaults: defaults).managedAccounts[0].label, "Job")

        reloaded.remove(accountID: edited.id)
        XCTAssertEqual(Preferences(defaults: defaults).managedAccounts.count, 1)
        XCTAssertFalse(Preferences(defaults: defaults).managedAccounts.contains { $0.id == edited.id })
    }

    // MARK: Path resolution

    func testManagedAccountPathResolution() {
        let home = URL(fileURLWithPath: "/home/testuser")
        XCTAssertEqual(
            ManagedAccountPaths.home(for: ManagedAccount(provider: .codex, label: "w", path: "~/.codex-work"), home: home)?.path,
            "/home/testuser/.codex-work"
        )
        XCTAssertEqual(
            ManagedAccountPaths.home(for: ManagedAccount(provider: .codex, label: "w", path: "/absolute/dir"), home: home)?.path,
            "/absolute/dir"
        )
        XCTAssertNil(ManagedAccountPaths.home(for: ManagedAccount(provider: .codex, label: "w", path: ""), home: home))
        XCTAssertNil(ManagedAccountPaths.home(for: ManagedAccount(provider: .codex, label: "w", path: "   "), home: home))
    }

    // MARK: Presence gating

    @MainActor
    func testAdditionalSlotOnlyVisibleWhenEnabledAndDirectoryExists() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("meterusage-slots-\(UUID().uuidString)", isDirectory: true)
        let codexHome = base.appendingPathComponent("codex-work", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let suiteName = "MeterUsageTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: PrefKey.showCodex)

        let preferences = Preferences(defaults: defaults)
        preferences.add(account: ManagedAccount(provider: .codex, label: "Work", path: codexHome.path))
        preferences.add(account: ManagedAccount(provider: .claude, label: "Missing", path: base.appendingPathComponent("no-such-dir").path))

        let coordinator = AppCoordinator(preferences: preferences)

        XCTAssertTrue(coordinator.visibleSlots.contains { $0.provider == .codex && !$0.isPrimary })
        XCTAssertFalse(coordinator.visibleSlots.contains { $0.provider == .claude && !$0.isPrimary })
        XCTAssertTrue(coordinator.visibleSlots.contains { $0 == .primary(.codex) })

        // A disabled account is not an account the app reads.
        var disabled = preferences.managedAccounts[0]
        disabled.enabled = false
        preferences.update(account: disabled)
        XCTAssertFalse(coordinator.visibleSlots.contains { $0.provider == .codex && !$0.isPrimary })
    }

    @MainActor
    func testPrimarySlotsNeverGatedByAccountPresence() throws {
        let suiteName = "MeterUsageTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: PrefKey.showCodex)

        let coordinator = AppCoordinator(preferences: Preferences(defaults: defaults))
        XCTAssertTrue(coordinator.visibleSlots.contains(.primary(.codex)))
    }

    // MARK: Per-slot polling and readings

    @MainActor
    func testBothCodexAccountsLoadIntoTheirOwnRows() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("meterusage-slots-\(UUID().uuidString)", isDirectory: true)
        let codexHome = base.appendingPathComponent("codex-work", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let suiteName = "MeterUsageTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = Preferences(defaults: defaults)
        let account = ManagedAccount(provider: .codex, label: "Work", path: codexHome.path)
        preferences.add(account: account)

        let coordinator = AppCoordinator(
            preferences: preferences,
            quotaSources: [
                StubQuotaSource(
                    slot: .primary(.codex),
                    windows: [QuotaWindow(label: "5-hour", usedPercent: 10, resetsAt: nil)]
                ),
                StubQuotaSource(
                    slot: account.slot,
                    windows: [QuotaWindow(label: "5-hour", usedPercent: 90, resetsAt: nil)]
                ),
            ]
        )

        coordinator.refresh()
        for _ in 0..<200 {
            if coordinator.quotas[.primary(.codex)]?.value != nil,
               coordinator.quotas[account.slot]?.value != nil { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        // Two slots, two readings, never merged or overwritten.
        XCTAssertEqual(coordinator.quotas[.primary(.codex)]?.value?.windows.first?.usedPercent, 10)
        XCTAssertEqual(coordinator.quotas[account.slot]?.value?.windows.first?.usedPercent, 90)
        XCTAssertTrue(coordinator.visibleQuotaSlots.contains(account.slot))
    }

    // MARK: Reset routing

    private final class ResetBox: @unchecked Sendable {
        var consumed: [String: [String]] = [:] // slot key -> credit ids
    }

    private struct SlotResetSource: QuotaSource, QuotaResetConsumer {
        let slot: ProviderSlot
        var provider: Provider { slot.provider }
        let box: ResetBox

        func fetchQuota() async throws -> ProviderQuota {
            ProviderQuota(
                provider: slot.provider,
                windows: [],
                resetCreditCount: 1,
                resetCredits: [QuotaResetCredit(id: "credit-\(slot.key)", title: "Full reset", status: "available")],
                capturedAt: Date()
            )
        }

        func consumeReset(creditID: String) async throws -> Bool {
            box.consumed[slot.key, default: []].append(creditID)
            return true
        }
    }

    @MainActor
    func testResetRoutesToTheSlotThatOwnsTheCredit() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("meterusage-slots-\(UUID().uuidString)", isDirectory: true)
        let codexHome = base.appendingPathComponent("codex-work", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let suiteName = "MeterUsageTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = Preferences(defaults: defaults)
        let account = ManagedAccount(provider: .codex, label: "Work", path: codexHome.path)
        preferences.add(account: account)

        let box = ResetBox()
        let coordinator = AppCoordinator(
            preferences: preferences,
            quotaSources: [
                SlotResetSource(slot: .primary(.codex), box: box),
                SlotResetSource(slot: account.slot, box: box),
            ]
        )

        // Both slots' credits are redeemable; a non-Codex slot is not.
        XCTAssertTrue(coordinator.canUseCodexReset(for: .primary(.codex)))
        XCTAssertTrue(coordinator.canUseCodexReset(for: account.slot))
        XCTAssertFalse(coordinator.canUseCodexReset(for: .primary(.claude)))

        coordinator.refresh()
        for _ in 0..<200 {
            if coordinator.quotas[.primary(.codex)]?.value != nil,
               coordinator.quotas[account.slot]?.value != nil { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        // The credit id routes to the slot whose quota reported it.
        try await coordinator.consumeCodexReset(creditID: "credit-\(account.slot.key)")
        XCTAssertEqual(box.consumed[account.slot.key], ["credit-\(account.slot.key)"])
        XCTAssertNil(box.consumed["codex"])
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

        let account = ManagedAccount(provider: .codex, label: "Work", path: "~/.codex-work")
        let alt = CodexQuotaSource(slot: account.slot, client: NotSignedInClient())
        do {
            _ = try await alt.fetchQuota()
            XCTFail("expected notSignedIn")
        } catch let reason as SourceUnavailable {
            // The error names the account, so the calm empty state says which
            // account to sign in rather than ambiguously "Codex".
            XCTAssertEqual(reason, .notSignedIn(.codex))
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

        let account = ManagedAccount(provider: .claude, label: "Work", path: base.path)
        let altSource = ClaudeLocalSource(
            slot: account.slot,
            root: projects,
            cacheFileURL: base.appendingPathComponent("cache-alt.json")
        )
        let activity = try await altSource.scan()
        XCTAssertEqual(activity.provider, .claude)
    }

    // MARK: Persistence and report formats

    func testQuotaArchiveRoundTripsAdditionalSlots() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("meterusage-tests-archive-\(UUID().uuidString).json")
        let account = ManagedAccount(provider: .codex, label: "Work", path: "~/.codex-work")
        let quotas: [ProviderSlot: ProviderQuota] = [
            .primary(.codex): ProviderQuota(
                provider: .codex,
                windows: [QuotaWindow(label: "5-hour", usedPercent: 10, resetsAt: nil)],
                capturedAt: Date(timeIntervalSince1970: 1_785_000_000)
            ),
            account.slot: ProviderQuota(
                provider: .codex,
                windows: [QuotaWindow(label: "5-hour", usedPercent: 33, resetsAt: nil)],
                capturedAt: Date(timeIntervalSince1970: 1_785_000_000)
            ),
        ]
        QuotaArchive.save(quotas, to: url)
        let loaded = QuotaArchive.load(from: url)
        XCTAssertEqual(loaded[.primary(.codex)]?.windows.first?.usedPercent, 10)
        XCTAssertEqual(loaded[account.slot]?.windows.first?.usedPercent, 33)
        XCTAssertEqual(loaded[account.slot]?.provider, .codex)
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
        let account = ManagedAccount(provider: .claude, label: "Work", path: "~/.claude-alt")
        store.record(key: account.slot.key, daily: [day])
        XCTAssertEqual(store.records(forKey: account.slot.key).first?.tokens.input, 100)
        XCTAssertNil(store.records(forKey: "claude").first, "second-account history must not leak into the primary slot")
        try? FileManager.default.removeItem(at: url)
    }

    func testLimitsReportEmitsDistinctSlotEntries() {
        let now = Date()
        let account = ManagedAccount(provider: .codex, label: "Work", path: "~/.codex-work")
        let report = LimitsReporter.build(
            quotas: [
                .primary(.codex): .value(ProviderQuota(
                    provider: .codex,
                    windows: [QuotaWindow(label: "5-hour", usedPercent: 10, resetsAt: nil)],
                    capturedAt: now
                )),
                account.slot: .value(ProviderQuota(
                    provider: .codex,
                    windows: [QuotaWindow(label: "5-hour", usedPercent: 80, resetsAt: nil)],
                    capturedAt: now
                )),
            ],
            order: [.primary(.codex), account.slot],
            now: now
        )

        XCTAssertEqual(report.providers.map(\.provider), ["codex", "codex"])
        XCTAssertEqual(report.providers.map(\.account), [nil, "Work"])
        XCTAssertEqual(report.providers.map(\.windows.first?.usedPercent), [10, 80])
    }
}

private struct StubQuotaSource: QuotaSource {
    let slot: ProviderSlot
    var provider: Provider { slot.provider }
    let windows: [QuotaWindow]

    func fetchQuota() async throws -> ProviderQuota {
        ProviderQuota(provider: slot.provider, windows: windows, capturedAt: Date())
    }
}
