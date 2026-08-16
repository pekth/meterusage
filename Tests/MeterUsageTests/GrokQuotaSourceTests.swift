import XCTest
@testable import MeterUsage

final class GrokQuotaSourceTests: XCTestCase {

    /// The real billing payload: one weekly period with the share used and a
    /// reset time carrying six-digit fractional seconds and a UTC offset.
    func testParseWeeklyPayloadIntoOneWindow() throws {
        let json = """
        {"config":{
          "currentPeriod":{
            "type":"USAGE_PERIOD_TYPE_WEEKLY",
            "start":"2026-08-11T04:06:19.522482+00:00",
            "end":"2026-08-18T04:06:19.522482+00:00"},
          "creditUsagePercent":31.0,
          "onDemandCap":{"val":0},
          "onDemandUsed":{"val":0},
          "prepaidBalance":{"val":0},
          "isUnifiedBillingUser":true,
          "billingPeriodStart":"2026-08-11T04:06:19.522482+00:00",
          "billingPeriodEnd":"2026-08-18T04:06:19.522482+00:00"}}
        """

        let quota = try GrokQuotaSource.parse(data: Data(json.utf8), now: Date())

        XCTAssertEqual(quota.provider, .grok)
        XCTAssertEqual(quota.windows.map(\.label), ["Weekly"])
        let window = try XCTUnwrap(quota.windows.first)
        XCTAssertEqual(window.usedPercent, 31, accuracy: 0.0001)
        let resetsAt = try XCTUnwrap(window.resetsAt)
        let utc = ISO8601DateFormatter()
        utc.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        XCTAssertEqual(
            resetsAt.timeIntervalSince1970,
            try XCTUnwrap(utc.date(from: "2026-08-18T04:06:19.522482+00:00")).timeIntervalSince1970,
            accuracy: 0.001
        )
    }

    /// The provider reports the period type; the window label must follow it.
    func testParseMonthlyPeriodLabelsMonthly() throws {
        let json = """
        {"config":{
          "currentPeriod":{"type":"USAGE_PERIOD_TYPE_MONTHLY",
            "start":"2026-08-01T00:00:00+00:00","end":"2026-09-01T00:00:00+00:00"},
          "creditUsagePercent":44.0,
          "billingPeriodEnd":"2026-09-01T00:00:00+00:00"}}
        """

        let quota = try GrokQuotaSource.parse(data: Data(json.utf8), now: Date())
        XCTAssertEqual(quota.windows.map(\.label), ["Monthly"])
    }

    /// `currentPeriod.end` backs up a missing `billingPeriodEnd`, so a provider
    /// schema drift in one field never loses the reset time.
    func testParseFallsBackToCurrentPeriodEnd() throws {
        let json = """
        {"config":{
          "currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY",
            "start":"2026-08-11T04:06:19.522482+00:00","end":"2026-08-18T04:06:19.522482+00:00"},
          "creditUsagePercent":9.0}}
        """

        let quota = try GrokQuotaSource.parse(data: Data(json.utf8), now: Date())
        let window = try XCTUnwrap(quota.windows.first)
        XCTAssertNotNil(window.resetsAt)
        XCTAssertEqual(window.usedPercent, 9, accuracy: 0.0001)
    }

    /// An endpoint that returns no period at all has nothing to render — that
    /// is a "no data" state, not a crash.
    func testParseEmptyConfigIsNoData() {
        let json = "{\"config\":{}}"
        XCTAssertThrowsError(
            try GrokQuotaSource.parse(data: Data(json.utf8), now: Date())
        ) { error in
            XCTAssertEqual(error as? SourceUnavailable, .noData)
        }
    }

    /// The billing service returns an auth-shaped error body when the cached
    /// token is stale. That must map to "not signed in", not a generic failure.
    func testParseAuthErrorIsNotSignedIn() throws {
        let json = """
        {"type":"error","error":{"type":"AuthError","message":"Invalid token"}}
        """

        XCTAssertThrowsError(
            try GrokQuotaSource.parse(data: Data(json.utf8), now: Date())
        ) { error in
            XCTAssertEqual(error as? SourceUnavailable, .notSignedIn(.grok))
        }
    }

    /// Garbage that is neither a billing payload nor an error body is a
    /// generic failure, not a crash.
    func testParseGarbageFails() throws {
        XCTAssertThrowsError(
            try GrokQuotaSource.parse(data: Data("not json".utf8), now: Date())
        ) { error in
            XCTAssertEqual(error as? SourceUnavailable, .failed(.grok))
        }
    }

    /// The token discovery reads grok's own `auth.json`, keyed by the
    /// auth.x.ai OIDC scope, and trims whitespace.
    func testDiscoverTokenReadsAuthJSON() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GrokQuotaTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let authURL = directory.appendingPathComponent("auth.json")
        let object: [String: Any] = [
            "https://auth.x.ai::some-uuid": [
                "key": "  eyJ.oidc.token  ",
                "auth_mode": "oauth"
            ],
            "other-scope": ["key": "not-this-one"]
        ]
        try JSONSerialization.data(withJSONObject: object).write(to: authURL)

        let token = GrokQuotaSource.discoverToken(from: authURL)
        XCTAssertEqual(token, "eyJ.oidc.token")
    }

    func testDiscoverTokenMissingAuthReturnsNil() {
        let missing = URL(fileURLWithPath: "/nonexistent/grok/auth.json")
        XCTAssertNil(GrokQuotaSource.discoverToken(from: missing))
    }
}
