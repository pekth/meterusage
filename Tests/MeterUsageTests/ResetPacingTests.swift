import XCTest
@testable import MeterUsage

final class ResetPacingTests: XCTestCase {
    private actor Source: QuotaSource, QuotaResetConsumer {
        nonisolated let slot: ProviderSlot
        nonisolated var provider: Provider { slot.provider }
        var percent: Double = 80
        var reset = Date().addingTimeInterval(6 * 86_400)
        var sampleTime: Date?
        var accepted = true
        var resetFails = false
        var offline = false
        var holdNextRead = false
        var heldRead: CheckedContinuation<Void, Never>?

        init(slot: ProviderSlot = .codex) { self.slot = slot }

        func fetchQuota() async throws -> ProviderQuota {
            if offline { throw SourceUnavailable.offline }
            let weekly = QuotaWindow(label: "Weekly", usedPercent: percent,
                                     resetsAt: reset, windowDurationMins: 10_080)
            let quota = ProviderQuota(
                provider: provider, windows: [weekly],
                groups: [QuotaGroup(id: "general", title: "General", windows: [weekly]),
                         QuotaGroup(id: "model", title: "Synthetic model", windows: [
                            QuotaWindow(label: "Weekly", usedPercent: min(100, percent + 10),
                                        resetsAt: reset, windowDurationMins: 10_080)
                         ])],
                credits: CreditBalance(balance: 125, hasCredits: true, unlimited: false,
                                       unit: .credits, usedDollars: 2, limitDollars: 10, dollarBalance: 5),
                resetCreditCount: 1,
                resetCredits: [QuotaResetCredit(id: creditID, title: "Reset", status: "available", expiresAt: reset)],
                planType: "synthetic", capturedAt: sampleTime ?? Date())
            if holdNextRead {
                holdNextRead = false
                await withCheckedContinuation { heldRead = $0 }
            }
            return quota
        }
        nonisolated var creditID: String { slot.isPrimary ? "synthetic-reset" : "synthetic-reset-\(slot.key)" }
        func consumeReset(creditID: String) async throws -> Bool {
            if resetFails { throw SourceUnavailable.failed(provider) }
            if accepted { percent = 5; sampleTime = nil }
            return accepted
        }
        func reject() { accepted = false }
        func failReset() { resetFails = true }
        func setOffline(_ value: Bool) { offline = value }
        func sample(_ percent: Double, at time: Date, reset: Date? = nil) {
            self.percent = percent
            sampleTime = time
            if let reset { self.reset = reset }
        }
        func holdRead() { holdNextRead = true }
        func isReadHeld() -> Bool { heldRead != nil }
        func releaseRead() { heldRead?.resume(); heldRead = nil }
    }

    @MainActor
    private func coordinator(_ source: Source, others: [QuotaSource] = []) throws -> (AppCoordinator, URL, UserDefaults, String) {
        let suite = "ResetPacingTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        if others.contains(where: { $0.provider == .claude }) { defaults.set(true, forKey: PrefKey.showClaude) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("reset-pacing-\(UUID().uuidString).json")
        return (AppCoordinator(preferences: Preferences(defaults: defaults), quotaSources: [source] + others,
                               quotaArchiveURL: url, accountHome: { _ in FileManager.default.temporaryDirectory }), url, defaults, suite)
    }

    @MainActor
    private func settle(_ coordinator: AppCoordinator) async throws {
        for _ in 0..<200 {
            if !coordinator.isRefreshing { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("synthetic refresh did not settle")
    }

    @MainActor
    func testAcceptedResetFirstFreshReadingHasNoPace() async throws {
        let source = Source()
        let (coordinator, url, defaults, suite) = try coordinator(source)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: url) }
        coordinator.refresh()
        try await settle(coordinator)
        XCTAssertNotNil(coordinator.quotas[.codex]?.value?.windows.first?.pace())
        try await coordinator.consumeCodexReset(creditID: "synthetic-reset")
        try await settle(coordinator)
        let window = try XCTUnwrap(coordinator.quotas[.codex]?.value?.windows.first)
        XCTAssertEqual(window.usedPercent, 5)
        XCTAssertNotNil(window.resetsAt)
        XCTAssertNil(window.pace(), "first post-reset sample cannot infer a rate from the old cycle start")
    }

    @MainActor
    func testRejectedResetPreservesForecastControl() async throws {
        let source = Source()
        let (coordinator, url, defaults, suite) = try coordinator(source)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: url) }
        coordinator.refresh()
        try await settle(coordinator)
        let before = coordinator.quotas[.codex]?.value
        await source.reject()
        do {
            try await coordinator.consumeCodexReset(creditID: "synthetic-reset")
            XCTFail("rejected reset must throw")
        } catch {}
        XCTAssertEqual(coordinator.quotas[.codex]?.value, before)
        XCTAssertNotNil(before?.windows.first?.pace())
    }
    @MainActor
    private func live(_ coordinator: AppCoordinator, slot: ProviderSlot = .codex) throws -> ProviderQuota {
        try XCTUnwrap(coordinator.quotas[slot]?.value)
    }

    @MainActor
    func testLaterGrowthUsesObservedDeltaAndPreservesMetadata() async throws {
        let source = Source()
        let (coordinator, url, defaults, suite) = try coordinator(source)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: url) }
        coordinator.refresh()
        try await settle(coordinator)
        try await coordinator.consumeCodexReset(creditID: source.creditID)
        try await settle(coordinator)
        let first = try live(coordinator)
        let later = first.capturedAt.addingTimeInterval(3600)
        await source.sample(25, at: later)
        coordinator.refresh()
        try await settle(coordinator)
        let quota = try live(coordinator)
        let window = try XCTUnwrap(quota.windows.first)
        let pace = try XCTUnwrap(window.pace(now: later))
        XCTAssertEqual(try XCTUnwrap(pace.projectedExhaustion).timeIntervalSince(later), 75 / (20.0 / 3600), accuracy: 0.001)
        XCTAssertEqual(pace.etaInterval(resetsAt: window.resetsAt, now: later.addingTimeInterval(60)) ?? 0,
                       75 / (20.0 / 3600) - 60, accuracy: 0.001)
        XCTAssertTrue(pace.status.isDeficit)
        XCTAssertEqual(window.windowDurationMins, 10_080)
        XCTAssertEqual(quota.credits, first.credits)
        XCTAssertEqual(quota.planType, first.planType)
        XCTAssertEqual(quota.resetCredits, first.resetCredits)
        XCTAssertEqual(quota.resetCreditCount, first.resetCreditCount)
        XCTAssertEqual(quota.groups[0].windows, quota.windows)
        let modelPace = try XCTUnwrap(quota.groups[1].windows[0].pace(now: later))
        XCTAssertEqual(try XCTUnwrap(modelPace.projectedExhaustion).timeIntervalSince(later), 65 / (20.0 / 3600), accuracy: 0.001)
        XCTAssertEqual(QuotaArchive.load(from: url)[.codex], quota)
    }

    @MainActor
    func testClaimedSlotIsolationAndOtherProviderControl() async throws {
        let account = ManagedAccount(provider: .codex, label: "Synthetic", path: "~/synthetic-codex")
        let primary = Source()
        let alternate = Source(slot: account.slot)
        let claude = Source(slot: .claude)
        let (coordinator, url, defaults, suite) = try coordinator(primary, others: [alternate, claude])
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: url) }
        coordinator.preferences.add(account: account)
        coordinator.refresh()
        try await settle(coordinator)
        let primaryBefore = try live(coordinator)
        let claudeBefore = try live(coordinator, slot: .claude)
        // The credit claims the alternate slot even though the call defaults to primary.
        try await coordinator.consumeCodexReset(creditID: alternate.creditID)
        try await settle(coordinator)
        let reset = try live(coordinator, slot: account.slot)
        XCTAssertNil(reset.windows[0].pace())
        XCTAssertNotNil(reset.resetPacingSince)
        XCTAssertEqual(try live(coordinator).windows, primaryBefore.windows)
        XCTAssertNil(try live(coordinator).resetPacingSince)
        XCTAssertEqual(try live(coordinator, slot: .claude).windows, claudeBefore.windows)
        XCTAssertNil(try live(coordinator, slot: .claude).resetPacingSince)
        XCTAssertNotNil(claudeBefore.windows[0].pace())
        let restored = QuotaArchive.load(from: url)
        XCTAssertEqual(restored[account.slot], reset)
        XCTAssertNil(restored[.codex]?.resetPacingSince)
    }

    @MainActor
    func testFallingUsageAndRolloverEstablishNewBaselines() async throws {
        let source = Source()
        let (coordinator, url, defaults, suite) = try coordinator(source)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: url) }
        coordinator.refresh()
        try await settle(coordinator)
        try await coordinator.consumeCodexReset(creditID: source.creditID)
        try await settle(coordinator)
        let first = try live(coordinator)
        let times = (1...4).map { first.capturedAt.addingTimeInterval(Double($0) * 3600) }
        await source.sample(25, at: times[0])
        coordinator.refresh()
        try await settle(coordinator)
        XCTAssertNotNil(try live(coordinator).windows[0].pace(now: times[0]))
        await source.sample(2, at: times[1])
        coordinator.refresh()
        try await settle(coordinator)
        XCTAssertNil(try live(coordinator).windows[0].pace(now: times[1]))
        XCTAssertEqual(try live(coordinator).windows[0].pacingBaseline?.usedPercent, 2)
        await source.sample(12, at: times[2])
        coordinator.refresh()
        try await settle(coordinator)
        let resumed = try XCTUnwrap(try live(coordinator).windows[0].pace(now: times[2]))
        XCTAssertEqual(try XCTUnwrap(resumed.projectedExhaustion).timeIntervalSince(times[2]), 88 / (10.0 / 3600), accuracy: 0.001)
        let newReset = try XCTUnwrap(first.windows[0].resetsAt).addingTimeInterval(7 * 86_400)
        await source.sample(15, at: times[3], reset: newReset)
        coordinator.refresh()
        try await settle(coordinator)
        let rolled = try live(coordinator)
        XCTAssertNil(rolled.windows[0].pace(now: times[3]))
        XCTAssertEqual(rolled.windows[0].pacingBaseline?.capturedAt, times[3])
        XCTAssertEqual(rolled.windows[0].resetsAt, newReset)
        XCTAssertNil(rolled.groups[1].windows[0].pace(now: times[3]))
    }

    @MainActor
    func testOfflineResetAndRelaunchDoNotSeedFromArchive() async throws {
        let source = Source()
        let (coordinator, url, defaults, suite) = try coordinator(source)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: url) }
        coordinator.refresh()
        try await settle(coordinator)
        let old = try live(coordinator)
        await source.setOffline(true)
        try await coordinator.consumeCodexReset(creditID: source.creditID)
        try await settle(coordinator)
        let offline = try XCTUnwrap(coordinator.displayQuota(for: .codex))
        XCTAssertTrue(offline.isStale)
        XCTAssertEqual(offline.quota.windows[0].usedPercent, old.windows[0].usedPercent)
        XCTAssertNil(offline.quota.windows[0].pacingBaseline?.capturedAt)
        XCTAssertNil(offline.quota.windows[0].pace())
        let relaunched = AppCoordinator(preferences: Preferences(defaults: defaults),
                                        quotaSources: [source], quotaArchiveURL: url)
        XCTAssertTrue(try XCTUnwrap(relaunched.displayQuota(for: .codex)).isStale)
        await source.setOffline(false)
        // A stale successful response is not a post-reset sample.
        await source.sample(80, at: old.capturedAt)
        relaunched.refresh()
        try await settle(relaunched)
        XCTAssertNil(relaunched.quotas[.codex]?.value)
        XCTAssertNil(relaunched.archivedQuotas[.codex]?.windows[0].pacingBaseline?.capturedAt)
        let freshTime = Date().addingTimeInterval(1)
        await source.sample(5, at: freshTime)
        relaunched.refresh()
        try await settle(relaunched)
        XCTAssertNil(try live(relaunched).windows[0].pace(now: freshTime))
        XCTAssertEqual(try live(relaunched).windows[0].pacingBaseline?.capturedAt, freshTime)
    }

    @MainActor
    func testEstablishedBaselineSurvivesRelaunchAndRepeatedStaleSample() async throws {
        let source = Source()
        let (coordinator, url, defaults, suite) = try coordinator(source)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: url) }
        coordinator.refresh()
        try await settle(coordinator)
        try await coordinator.consumeCodexReset(creditID: source.creditID)
        try await settle(coordinator)
        let first = try live(coordinator)
        let later = first.capturedAt.addingTimeInterval(3600)
        await source.sample(25, at: later)
        coordinator.refresh()
        try await settle(coordinator)
        let archived = try live(coordinator)
        let relaunched = AppCoordinator(preferences: Preferences(defaults: defaults),
                                        quotaSources: [source], quotaArchiveURL: url)
        XCTAssertEqual(relaunched.archivedQuotas[.codex], archived)
        XCTAssertTrue(try XCTUnwrap(relaunched.displayQuota(for: .codex)).isStale)
        // Replaying the archived timestamp cannot make it live or move the baseline.
        relaunched.refresh()
        try await settle(relaunched)
        XCTAssertNil(relaunched.quotas[.codex]?.value)
        XCTAssertEqual(relaunched.archivedQuotas[.codex], archived)
        let next = later.addingTimeInterval(3600)
        await source.sample(35, at: next)
        relaunched.refresh()
        try await settle(relaunched)
        let window = try live(relaunched).windows[0]
        XCTAssertEqual(window.pacingBaseline?.capturedAt, first.capturedAt)
        XCTAssertEqual(window.pacingBaseline?.usedPercent, 5)
        let pace = try XCTUnwrap(window.pace(now: next))
        XCTAssertEqual(try XCTUnwrap(pace.projectedExhaustion).timeIntervalSince(next), 65 / (30.0 / 7200), accuracy: 0.001)
    }

    @MainActor
    func testInFlightPreResetReadCannotRestoreForecastOrSeedBaseline() async throws {
        let source = Source()
        let (coordinator, url, defaults, suite) = try coordinator(source)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: url) }
        coordinator.refresh()
        try await settle(coordinator)
        await source.holdRead()
        coordinator.refresh()
        for _ in 0..<200 {
            if await source.isReadHeld() { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let held = await source.isReadHeld()
        XCTAssertTrue(held)
        try await coordinator.consumeCodexReset(creditID: source.creditID)
        let acceptedAt = try XCTUnwrap(coordinator.archivedQuotas[.codex]?.resetPacingSince)
        await source.setOffline(true)
        await source.releaseRead()
        try await settle(coordinator)
        XCTAssertNil(coordinator.quotas[.codex]?.value)
        let pending = try XCTUnwrap(QuotaArchive.load(from: url)[.codex])
        XCTAssertEqual(pending.resetPacingSince, acceptedAt)
        XCTAssertNil(pending.windows[0].pacingBaseline?.capturedAt)
        XCTAssertNil(pending.windows[0].pace())
        await source.setOffline(false)
        coordinator.refresh()
        try await settle(coordinator)
        let fresh = try live(coordinator)
        XCTAssertEqual(fresh.windows[0].usedPercent, 5)
        XCTAssertNil(fresh.windows[0].pace())
        XCTAssertNotNil(fresh.windows[0].pacingBaseline?.capturedAt)
    }

    @MainActor
    func testFailedResetPreservesLiveAndPersistedForecast() async throws {
        let source = Source()
        let (coordinator, url, defaults, suite) = try coordinator(source)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: url) }
        coordinator.refresh()
        try await settle(coordinator)
        let before = try live(coordinator)
        let stored = try Data(contentsOf: url)
        await source.failReset()
        do {
            try await coordinator.consumeCodexReset(creditID: source.creditID)
            XCTFail("failed reset must throw")
        } catch {}
        XCTAssertEqual(try live(coordinator), before)
        XCTAssertEqual(try Data(contentsOf: url), stored)
        XCTAssertNotNil(before.windows[0].pace())
    }

    func testLegacyArchiveDecodesWithoutInventingBaseline() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("reset-pacing-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let json = #"[{"provider":"codex","windows":[{"label":"Weekly","usedPercent":42,"resetsAt":100000}],"capturedAt":10}]"#
        try Data(json.utf8).write(to: url)
        let old = try XCTUnwrap(QuotaArchive.load(from: url)[.codex])
        XCTAssertEqual(old.windows[0].usedPercent, 42)
        XCTAssertNil(old.windows[0].windowDurationMins)
        XCTAssertNil(old.windows[0].pacingBaseline)
        XCTAssertNil(old.resetPacingSince)
        XCTAssertTrue(old.groups.isEmpty)
    }

    func testUnchangedUsageHasNoRateAndDurationChangeRebaselines() throws {
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let reset = start.addingTimeInterval(100_000)
        let original = QuotaWindow(label: "Weekly", usedPercent: 5, resetsAt: reset, windowDurationMins: 10_080)
        let baseline = original.recordingResetSample(previous: nil, capturedAt: start)
        let unchanged = original.recordingResetSample(previous: baseline, capturedAt: start.addingTimeInterval(3600))
        XCTAssertNil(unchanged.pace(now: start.addingTimeInterval(3600)))
        let changed = QuotaWindow(label: "Weekly", usedPercent: 10, resetsAt: reset, windowDurationMins: 1440)
            .recordingResetSample(previous: unchanged, capturedAt: start.addingTimeInterval(7200))
        XCTAssertNil(changed.pace(now: start.addingTimeInterval(7200)))
        XCTAssertEqual(changed.pacingBaseline?.usedPercent, 10)
    }

}
