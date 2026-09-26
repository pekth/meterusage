import XCTest
@testable import MeterUsage

final class StatusPageSourceTests: XCTestCase {
    private let codexFragments = ["codex", "cli", "login"]

    private let openAIFixture: [StatusPageSource.Component] = [
        .init(name: "Codex Web", status: "full_outage", group: nil),
        .init(name: "CLI", status: "full_outage", group: nil),
        .init(name: "Login", status: "operational", group: nil),
        .init(name: "Codex API", status: "full_outage", group: nil),
        .init(name: "Responses", status: "operational", group: nil)
    ]

    func testSeverityMapsIncidentIoFullOutageToMajorOutage() {
        XCTAssertEqual(StatusPageSource.severity(for: "full_outage"), .majorOutage)
    }

    func testSeverityMapsDocumentedVocabulary() {
        XCTAssertEqual(StatusPageSource.severity(for: "operational"), .operational)
        XCTAssertEqual(StatusPageSource.severity(for: "degraded_performance"), .degraded)
        XCTAssertEqual(StatusPageSource.severity(for: "partial_outage"), .partialOutage)
        XCTAssertEqual(StatusPageSource.severity(for: "major_outage"), .majorOutage)
        XCTAssertEqual(StatusPageSource.severity(for: "under_maintenance"), .degraded)
        XCTAssertEqual(StatusPageSource.severity(for: "something_new"), .unknown)
    }

    func testFullOutageSurfacesAsOutageNotUnknown() {
        let status = StatusPageSource.summarise(openAIFixture, for: .codex, matching: codexFragments)
        XCTAssertEqual(status.severity, .majorOutage)
        XCTAssertTrue(status.description.hasPrefix("Codex Web:"), status.description)
    }

    func testMixedOutageReportsTheWorstComponent() {
        let mixed = [
            StatusPageSource.Component(name: "CLI", status: "degraded_performance", group: nil),
            StatusPageSource.Component(name: "Codex API", status: "full_outage", group: nil),
            StatusPageSource.Component(name: "Login", status: "operational", group: nil)
        ]
        let status = StatusPageSource.summarise(mixed, for: .codex, matching: codexFragments)
        XCTAssertEqual(status.severity, .majorOutage)
        XCTAssertEqual(status.description, "Codex API: major outage")
    }

    func testOperationalComponentsReportAllClear() {
        let status = StatusPageSource.summarise(
            [StatusPageSource.Component(name: "Codex Web", status: "operational", group: nil)],
            for: .codex,
            matching: codexFragments
        )
        XCTAssertEqual(status.severity, .operational)
        XCTAssertEqual(status.description, "All systems operational")
    }

    func testUnmatchedNamesFallBackToEveryComponent() {
        let status = StatusPageSource.summarise(
            [
                .init(name: "Answers", status: "operational", group: nil),
                .init(name: "Queries", status: "partial_outage", group: nil)
            ],
            for: .codex,
            matching: codexFragments
        )
        XCTAssertEqual(status.severity, .partialOutage)
    }

    func testGroupsDoNotDuplicateTheirChildren() {
        let status = StatusPageSource.summarise(
            [
                .init(name: "API", status: "major_outage", group: true),
                .init(name: "Login", status: "operational", group: nil)
            ],
            for: .codex,
            matching: codexFragments
        )
        XCTAssertEqual(status.severity, .operational)
    }
}
