import XCTest
@testable import MeterUsage

final class AccountTests: XCTestCase {

    func testSourceLabelsNameOwningTool() {
        XCTAssertEqual(Provider.codex.sourceLabel, "Codex CLI")
        XCTAssertEqual(Provider.claude.sourceLabel, "Claude Code")
        XCTAssertEqual(Provider.antigravity.sourceLabel, "agy CLI")
        XCTAssertEqual(Provider.grok.sourceLabel, "Grok CLI")
        XCTAssertEqual(Provider.openCodeGo.sourceLabel, "OpenCode")
        XCTAssertEqual(Provider.openRouter.sourceLabel, "API key")
    }

    @MainActor
    func testAccountResolvesPlanAndSource() async throws {
        let coordinator = try await Self.coordinator()

        let codex = coordinator.account(for: .codex)
        XCTAssertEqual(codex.plan, "plus")
        XCTAssertEqual(codex.via, "Codex CLI")

        let claude = coordinator.account(for: .claude)
        XCTAssertEqual(claude.plan, PlanTier.pro.displayName)
        XCTAssertEqual(claude.via, "Claude Code")

        // No reading and no plan source: the row still names the tool rather
        // than disappearing — "via Grok CLI" with no plan is the truth.
        let grok = coordinator.account(for: .grok)
        XCTAssertNil(grok.plan)
        XCTAssertEqual(grok.via, "Grok CLI")
    }

    // MARK: - Helpers

    @MainActor
    private static func coordinator() async throws -> AppCoordinator {
        let suiteName = "MeterUsageTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: PrefKey.showClaude)
        defaults.set(true, forKey: PrefKey.showGrok)

        let coordinator = AppCoordinator(
            preferences: Preferences(defaults: defaults),
            quotaSources: [
                StubQuotaSource(
                    provider: .codex,
                    windows: [QuotaWindow(label: "5-hour", usedPercent: 20, resetsAt: nil)],
                    planType: "plus"
                ),
            ],
            planSources: [StubPlanSource(provider: .claude, tier: .pro)],
            quotaArchiveURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("meterusage-tests-" + UUID().uuidString + ".json")
        )
        coordinator.refresh()
        for _ in 0..<200 {
            if coordinator.lastRefreshedAt != nil { return coordinator }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        throw NSError(domain: "AccountTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "refresh did not complete"])
    }
}

private struct StubQuotaSource: QuotaSource {
    let provider: Provider
    let windows: [QuotaWindow]
    var planType: String? = nil

    func fetchQuota() async throws -> ProviderQuota {
        ProviderQuota(provider: provider, windows: windows, planType: planType, capturedAt: Date())
    }
}

private struct StubPlanSource: PlanSource {
    let provider: Provider
    let tier: PlanTier

    func fetchPlan() async throws -> PlanTier { tier }
}
