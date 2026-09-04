import XCTest
@testable import MeterUsage

/// Demo mode exists to make screenshots safe. These tests hold the two
/// properties that makes true: it is off unless explicitly asked for, and the
/// data it produces is invented rather than read from anywhere.
final class DemoSourcesTests: XCTestCase {

    // MARK: - Activation

    /// The single most important assertion in this file. A user who never sets
    /// the variable must never see a fake number.
    func testDemoModeIsOffByDefault() {
        XCTAssertFalse(DemoMode.isEnabled([:]))
    }

    func testDemoModeIsOffForAnythingOtherThanExactlyOne() {
        for value in ["0", "", "true", "yes", "on", "2", " 1", "1 ", "TRUE"] {
            XCTAssertFalse(
                DemoMode.isEnabled([DemoMode.environmentKey: value]),
                "\(value.debugDescription) must not enable demo mode"
            )
        }
    }

    func testDemoModeIsOnForExactlyOne() {
        XCTAssertTrue(DemoMode.isEnabled([DemoMode.environmentKey: "1"]))
    }

    /// An unrelated variable must not switch the app over.
    func testUnrelatedEnvironmentDoesNotEnableDemoMode() {
        XCTAssertFalse(DemoMode.isEnabled(["DEMO": "1", "METERUSAGE": "1"]))
    }

    /// The composition root resolves to "off" in an ordinary process. If this
    /// ever fails, the test runner itself was launched in demo mode.
    func testCompositionDefaultsToRealSourcesInThisProcess() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment[DemoMode.environmentKey] == nil,
            "\(DemoMode.environmentKey) is set in this process"
        )
        XCTAssertFalse(Composition.isDemoMode)
    }

    func testLiveCompositionExposesCodexResetConsumer() throws {
        try XCTSkipUnless(!Composition.isDemoMode, "reset actions are disabled in demo mode")

        let codexSource = try XCTUnwrap(
            Composition.quotaSources().first { $0.provider == .codex }
        )
        XCTAssertTrue(codexSource is any QuotaResetConsumer)
    }

    /// The coordinator's flag is additive and defaults to off, so nothing that
    /// constructs one without opting in can render the badge.
    @MainActor
    func testCoordinatorIsNotInDemoModeByDefault() {
        XCTAssertFalse(AppCoordinator(preferences: Preferences()).isDemoMode)
    }

    // MARK: - Sources produce data

    func testClaudeQuotaIsPlausibleAndRelativeToNow() async throws {
        let before = Date()
        let quota = try await DemoClaudeQuotaSource().fetchQuota()
        XCTAssertEqual(quota.provider, .claude)
        XCTAssertEqual(quota.windows.count, 2)

        let five = try XCTUnwrap(quota.windows.first { $0.label == "5-hour" })
        let week = try XCTUnwrap(quota.windows.first { $0.label == "7-day" })
        XCTAssertEqual(five.usedPercent, 34, accuracy: 0.001)
        XCTAssertEqual(week.usedPercent, 61, accuracy: 0.001)

        // Resets must be computed from `now`, never hardcoded, so a screenshot
        // retaken later still shows a sensible countdown.
        let fiveReset = try XCTUnwrap(five.resetsAt)
        let weekReset = try XCTUnwrap(week.resetsAt)
        XCTAssertGreaterThan(fiveReset, before)
        XCTAssertLessThan(fiveReset.timeIntervalSince(before), 6 * 3600)
        XCTAssertGreaterThan(weekReset.timeIntervalSince(before), 86_400)
        XCTAssertLessThan(weekReset.timeIntervalSince(before), 4 * 86_400)
    }

    func testCodexQuotaCarriesPlanAndModestCredits() async throws {
        let quota = try await DemoCodexQuotaSource().fetchQuota()
        XCTAssertEqual(quota.provider, .codex)
        XCTAssertEqual(quota.planType, "plus")

        let credits = try XCTUnwrap(quota.credits)
        XCTAssertTrue(credits.hasCredits)
        XCTAssertFalse(credits.unlimited)
        XCTAssertEqual(credits.unit, .credits)
        let displayedCredits = Fmt.credits(1843)
        XCTAssertFalse(displayedCredits.contains("$"))
        XCTAssertFalse(displayedCredits.contains("K"))
        XCTAssertEqual(displayedCredits.filter { $0.isNumber }.map(String.init).joined(), "1843")
        // Modest on purpose: a large balance in a public screenshot reads as
        // somebody's real account.
        XCTAssertGreaterThan(credits.balance, 1)
        XCTAssertLessThan(credits.balance, 100)

        let weekly = try XCTUnwrap(quota.windows.first { $0.label == "Weekly" })
        XCTAssertEqual(weekly.usedPercent, 72, accuracy: 0.001)
        XCTAssertEqual(quota.groups.map(\.title), [
            "General usage limits",
            "GPT-5.3-Codex-Spark usage limits"
        ])
        XCTAssertEqual(quota.resetCreditCount, 2)
        XCTAssertEqual(quota.resetCredits.count, 2)
    }

    /// The colour scale is only legible in a screenshot if more than one band
    /// is represented. Asserted against the app's own thresholds rather than
    /// against the literal numbers, so a retune of either stays honest.
    func testQuotaWindowsSpanACalmAndAnAmberBand() async throws {
        let windows = try await DemoClaudeQuotaSource().fetchQuota().windows
            + DemoCodexQuotaSource().fetchQuota().windows
        XCTAssertTrue(windows.contains { $0.usedPercent < 75 }, "expected a calm window")
        XCTAssertTrue(windows.contains { (75..<90).contains($0.usedPercent) }, "expected an amber window")
        XCTAssertFalse(windows.contains { $0.usedPercent >= 90 }, "nothing should read as an emergency")
    }

    func testPlanSourceReportsMax5x() async throws {
        let tier = try await DemoPlanSource().fetchPlan()
        XCTAssertEqual(tier, .max5x)
    }

    func testStatusSourceReportsOperational() async throws {
        let status = try await DemoStatusSource().fetchStatus()
        XCTAssertEqual(status.severity, .operational)
        XCTAssertFalse(status.description.isEmpty)
        XCTAssertLessThanOrEqual(status.checkedAt, Date())
    }

    func testServiceStatusIsCodexFirstClassData() {
        XCTAssertEqual(StatusPageSource().provider, .codex)
        XCTAssertEqual(
            Composition.statusSources().map(\.provider),
            [.codex, .claude]
        )
    }

    func testSupplementalDemoUsageCoversAllNewProviders() async throws {
        let sources: [UsageSource] = [
            DemoAntigravityUsageSource(),
            DemoGrokUsageSource(),
            DemoOpenCodeGoUsageSource()
        ]

        let usage = try await withThrowingTaskGroup(of: ProviderUsage.self, returning: [ProviderUsage].self) { group in
            for source in sources {
                group.addTask { try await source.fetchUsage() }
            }
            var values: [ProviderUsage] = []
            for try await value in group { values.append(value) }
            return values
        }

        XCTAssertEqual(Set(usage.map(\.provider)), [.antigravity, .grok, .openCodeGo])
        XCTAssertTrue(usage.allSatisfy { $0.sessionCount > 0 && $0.messageCount > 0 })
        // Antigravity mirrors its conversation-store reader: token totals
        // with no cost estimate. Grok stays count-only.
        let antigravity = try XCTUnwrap(usage.first { $0.provider == .antigravity })
        XCTAssertNotNil(antigravity.tokens)
        XCTAssertNil(antigravity.estimatedCostUSD)
        XCTAssertNil(try XCTUnwrap(usage.first { $0.provider == .grok }).tokens)
        XCTAssertNil(try XCTUnwrap(usage.first { $0.provider == .grok }).estimatedCostUSD)
        let openCode = try XCTUnwrap(usage.first { $0.provider == .openCodeGo })
        XCTAssertNotNil(openCode.tokens)
        XCTAssertEqual(openCode.usageWindows?.map(\.label), ["last 24h", "last 7d", "last 30d"])
    }

    // MARK: - Local activity shape

    func testLocalActivityIsIndieScale() async throws {
        let activity = try await DemoLocalActivitySource().scan()

        XCTAssertEqual(activity.sessions.count, DemoActivityData.sessionCount)
        XCTAssertTrue((40...80).contains(activity.sessions.count))

        // Tens of millions, not billions.
        let tokens = activity.totalTokens.total
        XCTAssertGreaterThan(tokens, 10_000_000)
        XCTAssertLessThan(tokens, 200_000_000)

        // Low hundreds of dollars.
        XCTAssertGreaterThan(activity.totalCostUSD, 100)
        XCTAssertLessThan(activity.totalCostUSD, 400)
    }

    /// Every model in the demo mix has a published per-token rate, so the
    /// screenshot's total is a plain priced sum: no em-dash cost cell, no
    /// "understates real spend" footnote, no "+" qualifier on the total.
    /// The `.knownUnpriced` mechanism itself stays in the app for a future
    /// model with no published rate — this just asserts the demo doesn't
    /// (currently) exercise it, so a screenshot never shows a stray em-dash.
    func testLocalActivityIsFullyPriced() async throws {
        let sessions = try await DemoLocalActivitySource().scan().sessions
        XCTAssertFalse(sessions.isEmpty)
        for session in sessions {
            XCTAssertEqual(
                Pricing.availability(forModel: session.model), .priced,
                "\(session.model) should resolve to a priced rate, not knownUnpriced or a fallback guess"
            )
            XCTAssertGreaterThan(session.tokens.total, 0)
        }
        XCTAssertFalse(sessions.contains { Pricing.availability(forModel: $0.model) == .knownUnpriced })
    }

    /// Costs are derived from the app's own pricing table, so the demo can
    /// never display a figure the real code wouldn't have computed.
    func testSessionCostsMatchTheAppsOwnPricingTable() async throws {
        for session in try await DemoLocalActivitySource().scan().sessions {
            let expected = Pricing.estimate(model: session.model, tokens: session.tokens).costUSD
            XCTAssertEqual(session.estimatedCostUSD, expected, accuracy: 0.0001)
        }
    }

    func testHeatmapCoversAboutTwentyOfTwentySixWeeksWithVariedIntensity() async throws {
        let now = Date()
        let daily = try await DemoLocalActivitySource().scan().daily
        XCTAssertFalse(daily.isEmpty)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let today = calendar.startOfDay(for: now)

        // Nothing in the future, nothing off the left edge of the grid.
        let oldest = try XCTUnwrap(daily.map(\.day).min())
        XCTAssertLessThanOrEqual(try XCTUnwrap(daily.map(\.day).max()), today)
        XCTAssertLessThanOrEqual(today.timeIntervalSince(oldest), 190 * 86_400)

        // Counted off the grid the view actually draws — a column is a week.
        let model = HeatmapView.Model(daily: daily, today: now, weeks: DemoActivityData.heatmapWeeks)
        XCTAssertEqual(model.columns.count, DemoActivityData.heatmapWeeks)
        let activeColumns = model.columns.filter { column in
            column.contains { ($0?.tokens ?? 0) > 0 }
        }
        XCTAssertTrue((18...22).contains(activeColumns.count), "got \(activeColumns.count) active weeks")

        // Light, medium and dark cells all need to appear, which means values
        // must land in every quarter of the range up to the period's peak.
        let buckets = Set(model.columns.flatMap { $0 }.compactMap { cell -> Int? in
            guard let cell, cell.intensity > 0 else { return nil }
            return min(4, max(1, Int(ceil(cell.intensity * 4))))
        })
        XCTAssertEqual(buckets, [1, 2, 3, 4], "heatmap should use every intensity step")
    }

    // MARK: - Privacy

    /// The whole reason demo mode exists. Nothing it produces may look like it
    /// came off a real machine.
    func testDemoSessionsCarryNoPathOrUsername() async throws {
        let sessions = try await DemoLocalActivitySource().scan().sessions
        for session in sessions {
            let name = session.projectName
            XCTAssertFalse(name.contains("/"), "\(name) contains a path separator")
            XCTAssertFalse(name.contains("\\"), "\(name) contains a path separator")
            XCTAssertFalse(name.lowercased().contains("users"), "\(name) contains \"Users\"")
            XCTAssertFalse(name.isEmpty)
            XCTAssertTrue(
                DemoActivityData.projectNames.contains(name),
                "\(name) is not one of the invented demo project names"
            )
        }
        // Ids are opaque hashes, not anything reversible.
        for session in sessions {
            XCTAssertEqual(session.id.count, 16)
            XCTAssertFalse(session.id.contains("demo-session"))
        }
    }

    func testDemoProjectNamesAreGeneric() {
        for name in DemoActivityData.projectNames {
            XCTAssertFalse(name.contains("/"))
            XCTAssertFalse(name.lowercased().contains("users"))
            XCTAssertFalse(name.contains("."))
        }
    }

    // MARK: - Purity

    /// Demo sources are pure functions of `now` plus a fixed seed: no network,
    /// no filesystem, no environment. Two scans taken microseconds apart must
    /// therefore agree on everything except their timestamps, and must never
    /// fail — a source that touched the disk could fail on a machine with no
    /// `~/.claude` tree, and one that touched the network could fail offline.
    func testScanningTwiceProducesTheSameSyntheticData() async throws {
        let first = try await DemoLocalActivitySource().scan()
        let second = try await DemoLocalActivitySource().scan()

        XCTAssertEqual(first.sessions.map(\.id), second.sessions.map(\.id))
        XCTAssertEqual(first.sessions.map(\.projectName), second.sessions.map(\.projectName))
        XCTAssertEqual(first.sessions.map(\.model), second.sessions.map(\.model))
        XCTAssertEqual(first.sessions.map(\.tokens), second.sessions.map(\.tokens))
        XCTAssertEqual(first.daily.map(\.tokens), second.daily.map(\.tokens))
        XCTAssertEqual(first.daily.count, second.daily.count)
    }

    /// Every source must return without throwing, including the ones whose real
    /// counterparts need a CLI or a connection.
    func testEverySourceReturnsWithoutError() async throws {
        _ = try await DemoClaudeQuotaSource().fetchQuota()
        _ = try await DemoCodexQuotaSource().fetchQuota()
        _ = try await DemoPlanSource().fetchPlan()
        _ = try await DemoStatusSource().fetchStatus()
        _ = try await DemoLocalActivitySource().scan()
        _ = try await DemoAntigravityUsageSource().fetchUsage()
        _ = try await DemoGrokUsageSource().fetchUsage()
        _ = try await DemoOpenCodeGoUsageSource().fetchUsage()
    }
}
