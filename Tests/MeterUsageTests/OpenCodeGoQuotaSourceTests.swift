import XCTest
@testable import MeterUsage

final class OpenCodeGoQuotaSourceTests: XCTestCase {

    /// The real Zen payload: three windows, each with status, percent, and a
    /// reset time. The status field is carried but not required to be "ok" —
    /// a window at its limit must still render, not error.
    func testParseUsagePayloadIntoThreeWindows() throws {
        let json = """
        {"usage":{
          "rolling":{"status":"ok","percent":1,"resetsAt":"2026-08-15T23:00:20.504Z"},
          "weekly": {"status":"ok","percent":77,"resetsAt":"2026-08-17T00:00:00.504Z"},
          "monthly":{"status":"ok","percent":44,"resetsAt":"2026-09-07T07:15:09.504Z"}
        }}
        """

        let quota = try OpenCodeGoQuotaSource.parse(data: Data(json.utf8), now: Date())

        XCTAssertEqual(quota.provider, .openCodeGo)
        XCTAssertEqual(quota.windows.map(\.label), ["Rolling", "Weekly", "Monthly"])

        let rolling = try XCTUnwrap(quota.windows.first { $0.label == "Rolling" })
        XCTAssertEqual(rolling.usedPercent, 1, accuracy: 0.0001)
        XCTAssertNotNil(rolling.resetsAt)

        let weekly = try XCTUnwrap(quota.windows.first { $0.label == "Weekly" })
        XCTAssertEqual(weekly.usedPercent, 77, accuracy: 0.0001)
        XCTAssertNotNil(weekly.resetsAt)

        let monthly = try XCTUnwrap(quota.windows.first { $0.label == "Monthly" })
        XCTAssertEqual(monthly.usedPercent, 44, accuracy: 0.0001)
        XCTAssertNotNil(monthly.resetsAt)

        XCTAssertEqual(quota.planType, "go")
    }

    /// A window at its limit still reports a percentage and reset — that is
    /// exactly the moment the user needs the number, so it must never throw.
    func testParseWindowAtLimitStillReportsPercent() throws {
        let json = """
        {"usage":{
          "rolling":{"status":"over_limit","percent":100,"resetsAt":"2026-08-15T23:00:00Z"},
          "weekly": {"status":"ok","percent":77,"resetsAt":"2026-08-17T00:00:00Z"},
          "monthly":{"status":"ok","percent":44,"resetsAt":"2026-09-07T07:15:09Z"}
        }}
        """

        let quota = try OpenCodeGoQuotaSource.parse(data: Data(json.utf8), now: Date())

        let rolling = try XCTUnwrap(quota.windows.first { $0.label == "Rolling" })
        XCTAssertEqual(rolling.usedPercent, 100, accuracy: 0.0001)
    }

    /// The endpoint returns an auth-shaped error body when the key is invalid.
    /// That must map to "not signed in", not a generic failure.
    func testParseAuthErrorIsNotSignedIn() throws {
        let json = """
        {"type":"error","error":{"type":"AuthError","message":"Missing API key."}}
        """

        XCTAssertThrowsError(
            try OpenCodeGoQuotaSource.parse(data: Data(json.utf8), now: Date())
        ) { error in
            XCTAssertEqual(error as? SourceUnavailable, .notSignedIn(.openCodeGo))
        }
    }

    /// Garbage that is neither a usage payload nor an error body is a generic
    /// failure, not a crash.
    func testParseGarbageFails() throws {
        XCTAssertThrowsError(
            try OpenCodeGoQuotaSource.parse(data: Data("not json".utf8), now: Date())
        ) { error in
            XCTAssertEqual(error as? SourceUnavailable, .failed(.openCodeGo))
        }
    }

    /// The discovery reads opencode's own `auth.json`, keyed by provider, and
    /// trims whitespace. Environment takes no part — opencode's CLI owns this
    /// key.
    func testDiscoverAPIKeyReadsAuthJSON() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenCodeGoQuotaTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let authURL = directory.appendingPathComponent("auth.json")
        let object: [String: Any] = [
            "opencode-go": ["type": "api", "key": "  sk-test-123  "],
            "xai": ["type": "oauth"]
        ]
        try JSONSerialization.data(withJSONObject: object).write(to: authURL)

        let key = OpenCodeGoQuotaSource.discoverAPIKey(from: authURL)
        XCTAssertEqual(key, "sk-test-123")
    }

    func testDiscoverAPIKeyMissingAuthReturnsNil() {
        let missing = URL(fileURLWithPath: "/nonexistent/opencode/auth.json")
        XCTAssertNil(OpenCodeGoQuotaSource.discoverAPIKey(from: missing))
    }
}
