import XCTest
@testable import MeterUsage

final class TriageDiagnosticsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let secret = "synthetic-private-host@example.invalid/private-path"

    private func report(
        slots: [ProviderSlot] = [.codex],
        quotas: [ProviderSlot: Loaded<ProviderQuota>] = [:],
        activities: [ProviderSlot: Loaded<LocalActivity>] = [:],
        usages: [ProviderSlot: Loaded<ProviderUsage>] = [:],
        outcomes: [DiagnosticsReport.RefreshOutcome] = []
    ) -> String {
        DiagnosticsReport.build(
            appName: "MeterUsage", appVersion: "0.2.41", isDemoMode: false,
            refreshInterval: 60, lastRefreshedAt: now.addingTimeInterval(-15), now: now,
            enabledSlots: slots, quotas: quotas, activities: activities, usages: usages,
            statuses: [.codex: .value(ServiceStatus(provider: .codex, severity: .degraded,
                                                   description: secret, checkedAt: now.addingTimeInterval(-20)))],
            plans: [.codex: .value(.other(secret))], appBuild: "41",
            osVersion: OperatingSystemVersion(majorVersion: 13, minorVersion: 6, patchVersion: 1),
            architecture: .arm64, recentOutcomes: outcomes)
    }

    func testNumericContextAndExplicitOmissionsAreDeterministic() {
        let text = report()
        XCTAssertEqual(text, report())
        for expected in ["MeterUsage 0.2.41", "diagnostics schema: 2", "app build: 41",
                         "os version: 13.6.1", "architecture: arm64", "last refresh: 15.000s ago",
                         "cache directory: unknown", "source configured: unknown",
                         "local source availability: unknown", "status severity: 1",
                         "status age: 20.000s ago", "CLI version and source paths",
                         "omitted refresh outcomes: 0; earlier outcomes are not retained"] {
            XCTAssertTrue(text.contains(expected), expected)
        }
        XCTAssertFalse(text.contains(secret))
    }

    func testQuotaAndAdditionalSlotNeverExportLabelsOrPersistentIDs() {
        let slot = ProviderSlot(provider: .codex, slotID: secret, label: secret)
        let quota = ProviderQuota(
            provider: .codex,
            windows: [QuotaWindow(label: secret, usedPercent: 42.5, resetsAt: now.addingTimeInterval(100), windowDurationMins: 300)],
            groups: [QuotaGroup(id: secret, title: secret, windows: [QuotaWindow(label: secret, usedPercent: 99)])],
            credits: CreditBalance(balance: 2.5, hasCredits: true, unlimited: false, usedDollars: 1, limitDollars: 5),
            resetCredits: [QuotaResetCredit(id: secret, title: secret, status: secret)],
            planType: secret, capturedAt: now.addingTimeInterval(-10))
        let text = report(slots: [.codex, slot], quotas: [slot: .value(quota)])
        XCTAssertTrue(text.contains("[codex#2]"))
        XCTAssertTrue(text.contains("quota age: 10.000s ago"))
        XCTAssertTrue(text.contains("used percent=42.500; duration minutes=300; reset in seconds=100.000"))
        XCTAssertTrue(text.contains("quota groups: 1; omitted groups: 0"))
        XCTAssertTrue(text.contains("reset credits: 1"))
        XCTAssertTrue(text.contains("balance: 2.500 dollars"))
        XCTAssertFalse(text.contains(secret))
        XCTAssertFalse(text.contains(slot.key))
    }

    func testActivityAndUsageExportOnlyAggregatesWithUnknownsPreserved() {
        let tokens = TokenTotals(input: 10, output: 2, reasoning: 3, cacheRead: 4, cacheWrite: 5)
        let activity = LocalActivity(provider: .codex, sessions: [
            SessionSummary(id: secret, projectName: secret, model: secret, tokens: tokens,
                           estimatedCostUSD: 1, startedAt: now, messageCount: 6)
        ], daily: [DailyActivity(day: now, tokens: tokens, estimatedCostUSD: 1, sessionCount: 1)],
        scannedAt: now.addingTimeInterval(-30))
        let usage = ProviderUsage(provider: .codex, sessionCount: 7, messageCount: 8,
                                  todayTokens: tokens, projectBreakdown: [ProjectTokens(project: secret, tokens: tokens)],
                                  usageWindows: [UsageWindow(label: secret, sessionCount: 7, messageCount: 8, tokens: tokens, estimatedCostUSD: 1)],
                                  capturedAt: now.addingTimeInterval(-40))
        let text = report(activities: [.codex: .value(activity)], usages: [.codex: .value(usage)])
        XCTAssertTrue(text.contains("activity aggregates: sessions=1; daily buckets=1; messages=6"))
        XCTAssertTrue(text.contains("activity age: 30.000s ago"))
        XCTAssertTrue(text.contains("input=10; output=2; reasoning=3; cache read=4; cache write=5"))
        XCTAssertTrue(text.contains("local source availability: activity source returned data"))
        XCTAssertTrue(text.contains("usage aggregates: sessions=7; messages=8"))
        XCTAssertTrue(text.contains("usage age: 40.000s ago"))
        XCTAssertTrue(text.contains("usage tokens: unknown"))
        XCTAssertTrue(text.contains("estimated cost USD: unknown"))
        XCTAssertTrue(text.contains("omitted usage windows: 0"))
        XCTAssertFalse(text.contains(secret))
    }

    func testDisabledAndUnconfiguredSlotsArchiveAndMissingStatesStayDistinct() {
        let alternate = ProviderSlot(provider: .codex, slotID: secret, label: secret)
        let text = DiagnosticsReport.build(
            appName: "MeterUsage", appVersion: "1", isDemoMode: false,
            refreshInterval: 60, lastRefreshedAt: nil, now: now, enabledSlots: [],
            quotas: [.codex: .idle, alternate: .missing(.cliNotFound(secret))], activities: [:],
            usages: [alternate: .missing(.dataNotFound(secret))], statuses: [:], plans: [:],
            historyError: .loadFailed,
            slotStates: [.init(slot: .codex, configured: true, enabled: false, visible: false),
                         .init(slot: alternate, configured: false, enabled: true, visible: false)],
            archivedQuotas: [.codex: ProviderQuota(provider: .codex, windows: [], capturedAt: now.addingTimeInterval(-90))],
            recentOutcomes: [.init(slot: .claude, stage: .quota, finishedAt: now, duration: 0,
                                   unavailable: nil, error: nil)])
        for expected in ["source configured: true; enabled: false; visible: false",
                         "source configured: false; enabled: true; visible: false",
                         "enabled: codex#2", "quota: not checked yet", "quota: unavailable (cliNotFound)",
                         "local source availability: usage source dataNotFound",
                         "archived quota age: 90.000s ago", "history: loadFailed",
                         "omitted refresh outcomes: 1"] {
            XCTAssertTrue(text.contains(expected), expected)
        }
        XCTAssertFalse(text.contains(secret))
    }

    func testReportBoundsListEveryTruncation() {
        let slots = (0..<100).map { ProviderSlot(provider: .codex, slotID: "synthetic-id-\($0)", label: secret) }
        let windows = (0..<100).map { _ in QuotaWindow(label: secret, usedPercent: 50) }
        let quota = ProviderQuota(provider: .codex, windows: windows, capturedAt: now)
        let outcomes = (0..<100).map { _ in
            DiagnosticsReport.RefreshOutcome(slot: slots[0], stage: .quota, finishedAt: now,
                                            duration: 0.125, unavailable: nil, error: nil)
        }
        let text = report(slots: slots, quotas: [slots[0]: .value(quota)], outcomes: outcomes)
        XCTAssertTrue(text.contains("slots: 100; omitted slots: 88"))
        XCTAssertTrue(text.contains("windows: 100; omitted windows: 92"))
        XCTAssertTrue(text.contains("recent refresh outcomes: 24"))
        XCTAssertTrue(text.contains("omitted refresh outcomes: 76"))
        XCTAssertFalse(text.contains("[codex#14]"))
        XCTAssertFalse(text.contains("window 9:"))
        XCTAssertFalse(text.contains("synthetic-id-"))
        XCTAssertLessThan(text.utf8.count, 32_000)
    }

    func testSafeErrorsAllowOnlyKnownDomainsAndNumericCodes() {
        let urlError = NSError(domain: NSURLErrorDomain, code: -1001,
                               userInfo: [NSLocalizedDescriptionKey: secret, NSFilePathErrorKey: secret])
        let safe = DiagnosticsReport.SafeError(error: urlError)
        XCTAssertEqual(safe?.domain, .url)
        XCTAssertEqual(safe?.code, -1001)
        XCTAssertEqual(DiagnosticsReport.SafeError(error: NSError(domain: NSCocoaErrorDomain, code: 256))?.domain, .cocoa)
        XCTAssertEqual(DiagnosticsReport.SafeError(error: NSError(domain: NSPOSIXErrorDomain, code: 13))?.domain, .posix)
        XCTAssertNil(DiagnosticsReport.SafeError(error: NSError(domain: secret, code: 7)))
        XCTAssertNil(DiagnosticsReport.SafeError(error: SourceUnavailable.cliNotFound(secret)))
        XCTAssertNil(DiagnosticsReport.SafeError(error: JSONRPCTransportError.timeout))
        let exit = DiagnosticsReport.SafeError(error: JSONRPCTransportError.processExited(status: 9, stderrTail: secret))
        XCTAssertEqual(exit?.domain, .processExit)
        XCTAssertEqual(exit?.code, 9)
        let text = report(outcomes: [DiagnosticsReport.RefreshOutcome(
            slot: .codex, stage: .usage, finishedAt: now, duration: 0.125,
            unavailable: .dataNotFound(secret), error: safe)])
        XCTAssertTrue(text.contains("codex usage: dataNotFound"))
        XCTAssertTrue(text.contains("duration seconds=0.125; error=url code=-1001"))
        XCTAssertFalse(text.contains(secret))
    }

    func testNonfiniteNumbersOverflowAndUntrustedAppStringsStayBounded() {
        let quota = ProviderQuota(provider: .codex, windows: [], credits: CreditBalance(
            balance: .infinity, hasCredits: true, unlimited: false), capturedAt: now)
        let activity = LocalActivity(provider: .codex, sessions: [Int.max, 1].map {
            SessionSummary(id: secret, projectName: secret, model: secret,
                           tokens: TokenTotals(input: $0), estimatedCostUSD: 0, startedAt: now, messageCount: $0)
        }, daily: [], scannedAt: now)
        let text = DiagnosticsReport.build(
            appName: secret, appVersion: secret, isDemoMode: false,
            refreshInterval: .nan, lastRefreshedAt: Date(timeIntervalSince1970: .nan), now: now,
            enabledSlots: [.codex], quotas: [.codex: .value(quota)], activities: [.codex: .value(activity)],
            usages: [:], statuses: [:], plans: [:], appBuild: String(repeating: "1", count: 100))
        XCTAssertTrue(text.contains("MeterUsage unknown"))
        XCTAssertTrue(text.contains("app build: unknown"))
        XCTAssertTrue(text.contains("refresh interval: invalid"))
        XCTAssertTrue(text.contains("last refresh: invalid"))
        XCTAssertTrue(text.contains("balance: invalid"))
        XCTAssertTrue(text.contains("messages=invalid"))
        XCTAssertTrue(text.contains("input=invalid"))
        XCTAssertFalse(text.contains(secret))
    }

    func testSourceMetadataUsesInjectedLocationsWithoutReadingTheirContents() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("synthetic-quota.json")
        let data = Data("not valid quota JSON".utf8)
        try data.write(to: file)
        let quotaSource = OptionalQuotaFileSource(candidatePaths: [file, root.appendingPathComponent("absent.json")])
        let observations = quotaSource.diagnosticFiles
        XCTAssertEqual(observations.map(\.kind), [.file, .missing])
        XCTAssertEqual(observations[0].bytes, Int64(data.count))
        let claudeFiles = await ClaudeLocalSource(root: root).diagnosticFiles
        let codexFiles = await CodexLocalSource(root: root).diagnosticFiles
        XCTAssertEqual(claudeFiles[0].kind, .directory)
        XCTAssertEqual(codexFiles[0].kind, .directory)
        let text = DiagnosticsReport.build(
            appName: "MeterUsage", appVersion: "1", isDemoMode: false,
            refreshInterval: 60, lastRefreshedAt: nil, now: now, enabledSlots: [.claude, .codex],
            quotas: [.claude: .missing(.noData)], activities: [:], usages: [:], statuses: [:], plans: [:],
            sourceFiles: [.claude: observations], codexCLIAvailable: [.codex: false])
        XCTAssertTrue(text.contains("quotaCandidate: file; readable=true; bytes=20"))
        XCTAssertTrue(text.contains("quotaCandidate: missing; readable=false"))
        XCTAssertTrue(text.contains("CLI executable discoverable: false"))
        XCTAssertFalse(text.contains(root.path))
        XCTAssertFalse(text.contains("synthetic-quota"))
        XCTAssertFalse(text.contains("not valid quota JSON"))
    }

    private struct SyntheticSource: QuotaSource, LocalActivitySource, UsageSource, StatusSource, PlanSource {
        let provider = Provider.codex
        let slot = ProviderSlot.codex
        func fetchQuota() async throws -> ProviderQuota {
            ProviderQuota(provider: provider, windows: [QuotaWindow(label: "synthetic-private-label", usedPercent: 25)], capturedAt: Date())
        }
        func scan() async throws -> LocalActivity { throw SourceUnavailable.dataNotFound("synthetic-private-path") }
        func fetchUsage() async throws -> ProviderUsage {
            throw NSError(domain: NSURLErrorDomain, code: -1009, userInfo: [NSLocalizedDescriptionKey: "synthetic-private-error"])
        }
        func fetchStatus() async throws -> ServiceStatus {
            ServiceStatus(provider: provider, severity: .operational, description: "synthetic-private-description", checkedAt: Date())
        }
        func fetchPlan() async throws -> PlanTier { .other("synthetic-private-plan") }
    }

    @MainActor
    func testCoordinatorCapturesAllFiveStagesWithoutChangingLoadedStates() async throws {
        let suite = "TriageDiagnosticsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let archive = FileManager.default.temporaryDirectory.appendingPathComponent("triage-\(UUID().uuidString).json")
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: archive) }
        let source = SyntheticSource()
        // Demo mode avoids the shared history store and all fixture sources are synthetic.
        let coordinator = AppCoordinator(preferences: Preferences(defaults: defaults), isDemoMode: true,
                                         quotaSources: [source], activitySources: [source], usageSources: [source],
                                         statusSources: [source], planSources: [source], quotaArchiveURL: archive)
        coordinator.refresh()
        for _ in 0..<200 {
            if !coordinator.isRefreshing { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(coordinator.isRefreshing)
        XCTAssertEqual(coordinator.quotas[.codex]?.value?.windows.first?.usedPercent, 25)
        XCTAssertEqual(coordinator.activities[.codex]?.unavailable, .dataNotFound("synthetic-private-path"))
        XCTAssertEqual(coordinator.usages[.codex]?.unavailable, .failed(.codex))
        XCTAssertEqual(coordinator.plans[.codex]?.value, .other("synthetic-private-plan"))
        let text = await coordinator.diagnosticsText()
        for expected in ["source configured: true; enabled: true; visible: true", "codex quota: ok",
                         "codex activity: dataNotFound", "codex usage: failed", "codex status: ok",
                         "codex plan: ok", "error=url code=-1009", "duration seconds=", "cache directory: notUsed"] {
            XCTAssertTrue(text.contains(expected), expected)
        }
        XCTAssertFalse(text.contains("synthetic-private-"))
        XCTAssertFalse(text.contains("age=-"), "Completed refreshes must use the report time, not the cached UI clock")
    }
}
