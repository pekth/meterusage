import XCTest
@testable import MeterUsage

final class LimitsReportTests: XCTestCase {

    // MARK: Building

    func testBuildCoversValueMissingAndIdle() {
        let quota = ProviderQuota(
            provider: .codex,
            windows: [QuotaWindow(label: "Weekly", usedPercent: 42, resetsAt: nil)],
            planType: "plus",
            capturedAt: Date())
        let report = LimitsReporter.build(
            quotas: [
                .codex: .value(quota),
                .grok: .missing(.cliNotFound("grok")),
            ],
            order: [.codex, .grok, .claude])

        XCTAssertEqual(report.providers.count, 3)
        XCTAssertEqual(report.providers[0].status, "ok")
        XCTAssertEqual(report.providers[0].plan, "plus")
        XCTAssertEqual(report.providers[0].windows.first?.usedPercent ?? 0, 42)

        XCTAssertEqual(report.providers[1].status, "unavailable")
        XCTAssertEqual(report.providers[1].reason, "grok CLI not found")

        XCTAssertEqual(report.providers[2].provider, "claude")
        XCTAssertNil(report.providers[2].reason, "an idle source has no failure to report")
    }

    func testBuild_carriesRegularWindowsOnly_notGroupWindows() {
        // Codex nests its general allowance in a "General usage limits"
        // group that mirrors the top-level `windows`, plus model-specific
        // groups (e.g. GPT-5.3-Codex-Spark). The report is the glance view
        // for the tray, widget, and CLI, so it must carry the regular
        // allowance windows and never leak model-specific ones into the
        // widget headline.
        let general = QuotaWindow(label: "Weekly", usedPercent: 15, resetsAt: nil)
        let quota = ProviderQuota(
            provider: .codex,
            windows: [general],
            groups: [
                QuotaGroup(id: "codex", title: "General usage limits", windows: [general]),
                QuotaGroup(
                    id: "codex_bengalfox",
                    title: "GPT-5.3-Codex-Spark",
                    windows: [
                        QuotaWindow(label: "5-hour", usedPercent: 0, resetsAt: nil),
                        QuotaWindow(label: "Weekly", usedPercent: 37, resetsAt: nil),
                    ]
                ),
            ],
            capturedAt: Date())

        let report = LimitsReporter.build(
            quotas: [.codex: .value(quota)],
            order: [.codex])

        let labels = report.providers.first?.windows.map { "\($0.label):\(Int($0.usedPercent))" } ?? []
        XCTAssertEqual(labels, ["Weekly:15"],
                       "only the regular allowance window belongs in the report")
    }

    func testPrivacyContractNoCredentialsInShape() {
        // The report type is the whole machine surface; this pins its fields
        // so a future credential-bearing field cannot slip in silently.
        let row = ProviderReport(provider: "codex", status: "ok")
        XCTAssertEqual(Set(Mirror(reflecting: row).children.compactMap(\.label)),
                       ["provider", "status", "reason", "plan", "windows", "credits"])
    }

    // MARK: Encoding round-trip

    func testJSONRoundTripPreservesDatesAndProjections() throws {
        let resets = Date(timeIntervalSince1970: 1_785_585_600)
        var report = LimitsReport(generatedAt: Date(timeIntervalSince1970: 1_785_000_000),
                                  providers: [])
        report.providers = [
            ProviderReport(
                provider: "codex",
                status: "ok",
                plan: "plus",
                windows: [WindowReport(label: "Weekly", usedPercent: 42.5,
                                       resetsAt: resets)]
            )
        ]
        let data = try report.jsonData()
        let decoded = LimitsReport.decode(data)
        XCTAssertEqual(decoded?.providers.first?.windows.first?.resetsAt, resets)

        // Stable machine output: sorted keys, no timestamps as locale strings.
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"generated_at\""))
        XCTAssertTrue(json.contains("\"used_percent\""))
    }

    func testDecodeSurvivesUnknownFieldsAndOlderWriters() throws {
        let legacy = """
        {"schema":1,"extra_field":"ignored","generated_at":"2026-08-23T00:00:00Z","providers":[
          {"provider":"codex","status":"ok","future_field":7,"windows":[
            {"label":"Weekly","used_percent":10}]}
        ]}
        """
        let decoded = LimitsReport.decode(Data(legacy.utf8))
        XCTAssertEqual(decoded?.providers.first?.windows.first?.label, "Weekly")
        XCTAssertNil(decoded?.providers.first?.windows.first?.resetsAt)
    }

    func testAgentBudgetFieldsIncludedInReport() throws {
        let resets = Date(timeIntervalSince1970: 1_785_585_600)
        let quota = ProviderQuota(
            provider: .codex,
            windows: [QuotaWindow(label: "Weekly", usedPercent: 40, resetsAt: resets)],
            planType: "plus",
            capturedAt: Date(timeIntervalSince1970: 1_785_000_000)
        )
        let report = LimitsReporter.build(
            quotas: [.codex: .value(quota)],
            order: [.codex],
            now: Date(timeIntervalSince1970: 1_785_200_000)
        )
        guard let win = report.providers.first?.windows.first else {
            return XCTFail("expected window")
        }
        XCTAssertEqual(win.remainingPercent, 60)
        let data = try report.jsonData()
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("remaining_percent"))
    }

    func testQuietDeficitReportsOnPaceInMachineReport() {
        // The machine surface mirrors the UI's honesty: a window-shape
        // deficit without a current burn reports on-pace, and only a fresh
        // burn earns "burning fast".
        let now = Date(timeIntervalSince1970: 1_785_200_000)
        // Weekly window: 1 of 7 days elapsed (~14%), 40% used → raw deficit.
        let quota = ProviderQuota(
            provider: .codex,
            windows: [QuotaWindow(
                label: "Weekly",
                usedPercent: 40,
                resetsAt: now.addingTimeInterval(6 * 86_400),
                windowDurationMins: 10_080)],
            planType: "plus",
            capturedAt: now.addingTimeInterval(-60)
        )

        let quiet = LimitsReporter.build(quotas: [.codex: .value(quota)], order: [.codex], now: now)
        XCTAssertEqual(quiet.providers[0].windows[0].pacing, "on pace")

        let fresh = LimitsReporter.build(
            quotas: [.codex: .value(quota)],
            order: [.codex],
            lastBurn: [.codex: now.addingTimeInterval(-120)],
            now: now)
        XCTAssertEqual(fresh.providers[0].windows[0].pacing, "burning fast")
    }
}
