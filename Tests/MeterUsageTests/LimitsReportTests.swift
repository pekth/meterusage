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
}
