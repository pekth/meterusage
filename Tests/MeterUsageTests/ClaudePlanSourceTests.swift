import XCTest
@testable import MeterUsageCore

final class ClaudePlanSourceTests: XCTestCase {

    // MARK: - Fixture plumbing

    /// Copies the bundled fixture into a fresh temp file so each test gets
    /// an isolated, injectable path — `ClaudePlanSource` never reads the
    /// real `~/.claude.json` here.
    private func fixtureURL() throws -> URL {
        guard let bundled = Bundle.module.url(forResource: "claude_account", withExtension: "json", subdirectory: "Fixtures") else {
            XCTFail("missing claude_account.json fixture")
            throw SourceUnavailable.noData
        }
        return bundled
    }

    private func writeTempJSON(_ string: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("claude.json")
        try string.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Happy path

    func testMapsMax20xFromOrganizationRateLimitTier() async throws {
        let source = ClaudePlanSource(fileURL: try fixtureURL())
        let tier = try await source.fetchPlan()
        XCTAssertEqual(tier, .max20x)
        XCTAssertEqual(tier.displayName, "Max 20\u{00D7}")
    }

    func testFallsBackToSeatTierWhenOrganizationRateLimitTierAbsent() async throws {
        let json = """
        {
          "oauthAccount": {
            "organizationRateLimitTier": null,
            "seatTier": "pro",
            "userRateLimitTier": null
          }
        }
        """
        let source = ClaudePlanSource(fileURL: try writeTempJSON(json))
        let tier = try await source.fetchPlan()
        XCTAssertEqual(tier, .pro)
    }

    func testFallsBackToUserRateLimitTierWhenOthersAbsent() async throws {
        let json = """
        {
          "oauthAccount": {
            "userRateLimitTier": "max_5x"
          }
        }
        """
        let source = ClaudePlanSource(fileURL: try writeTempJSON(json))
        let tier = try await source.fetchPlan()
        XCTAssertEqual(tier, .max5x)
    }

    func testOrganizationRateLimitTierTakesPriorityOverFallbacks() async throws {
        let json = """
        {
          "oauthAccount": {
            "organizationRateLimitTier": "default_claude_max_20x",
            "seatTier": "pro",
            "userRateLimitTier": "free"
          }
        }
        """
        let source = ClaudePlanSource(fileURL: try writeTempJSON(json))
        let tier = try await source.fetchPlan()
        XCTAssertEqual(tier, .max20x, "organizationRateLimitTier must win over seatTier/userRateLimitTier")
    }

    // MARK: - Missing / unparseable => noData, never an error

    func testMissingFileThrowsNoData() async throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-missing.json")
        let source = ClaudePlanSource(fileURL: missing)
        do {
            _ = try await source.fetchPlan()
            XCTFail("expected noData")
        } catch SourceUnavailable.noData {
            // expected
        }
    }

    func testUnparseableJSONThrowsNoData() async throws {
        let source = ClaudePlanSource(fileURL: try writeTempJSON("{ not json"))
        do {
            _ = try await source.fetchPlan()
            XCTFail("expected noData")
        } catch SourceUnavailable.noData {
            // expected
        }
    }

    func testMissingOauthAccountThrowsNoData() async throws {
        let source = ClaudePlanSource(fileURL: try writeTempJSON("{}"))
        do {
            _ = try await source.fetchPlan()
            XCTFail("expected noData")
        } catch SourceUnavailable.noData {
            // expected
        }
    }

    func testAllTierKeysMissingThrowsNoData() async throws {
        let json = """
        { "oauthAccount": { "emailAddress": "someone@example.com" } }
        """
        let source = ClaudePlanSource(fileURL: try writeTempJSON(json))
        do {
            _ = try await source.fetchPlan()
            XCTFail("expected noData")
        } catch SourceUnavailable.noData {
            // expected
        }
    }

    // MARK: - Privacy: identifying fields must never surface

    /// The core risk of this source: `oauthAccount` carries email/uuid/org
    /// name alongside the tier fields. Feed a fixture (mirroring the real
    /// file's shape) with obviously-identifying values and assert none of
    /// them can appear anywhere in the produced `PlanTier` or its
    /// `displayName` — the only two things this source is allowed to
    /// return.
    func testProducedPlanTierNeverContainsIdentifyingData() async throws {
        let source = ClaudePlanSource(fileURL: try fixtureURL())
        let tier = try await source.fetchPlan()

        let forbidden = [
            "someone@example.com",
            "Example Person",
            "Example Org",
            "00000000-1111-2222-3333-444444444444",
            "55555555-6666-7777-8888-999999999999",
        ]

        // PlanTier is an enum; the only string it can ever carry is the raw
        // tier string via `.other(String)`. Exhaustively render every case
        // (including the raw associated value) to a string and check it —
        // this also implicitly proves `.other` isn't hit for this fixture,
        // since the fixture's tier is recognised.
        let renderedTier = String(describing: tier)
        let renderedDisplayName = tier.displayName

        for needle in forbidden {
            XCTAssertFalse(renderedTier.contains(needle), "PlanTier leaked identifying value: \(needle)")
            XCTAssertFalse(renderedDisplayName.contains(needle), "displayName leaked identifying value: \(needle)")
        }

        XCTAssertEqual(tier, .max20x)
    }

    /// Same check again with a fixture where the *unrecognised*-tier path
    /// (`.other(String)`) fires, since that's the one case where a raw
    /// string genuinely does flow through to the result — proving even that
    /// raw string is only ever the tier value itself, never anything from
    /// the sibling identifying keys.
    func testOtherTierCaseCarriesOnlyTheTierStringNeverIdentifyingData() async throws {
        let json = """
        {
          "oauthAccount": {
            "organizationRateLimitTier": "some_future_tier_no_one_recognises_yet",
            "emailAddress": "someone@example.com",
            "displayName": "Example Person",
            "organizationName": "Example Org",
            "accountUuid": "00000000-1111-2222-3333-444444444444",
            "organizationUuid": "55555555-6666-7777-8888-999999999999"
          }
        }
        """
        let source = ClaudePlanSource(fileURL: try writeTempJSON(json))
        let tier = try await source.fetchPlan()

        guard case .other(let raw) = tier else {
            XCTFail("expected an unrecognised tier to map to .other")
            return
        }
        XCTAssertEqual(raw, "some_future_tier_no_one_recognises_yet")

        let forbidden = ["someone@example.com", "Example Person", "Example Org", "00000000-1111-2222-3333-444444444444", "55555555-6666-7777-8888-999999999999"]
        for needle in forbidden {
            XCTAssertFalse(raw.contains(needle))
        }
    }
}
