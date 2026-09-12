import XCTest
@testable import MeterUsage

final class UpdateCheckerTests: XCTestCase {

    // MARK: Version comparison

    func testNewerRecognizesSemverOrdering() {
        XCTAssertTrue(UpdateChecker.isNewer("0.2.2", than: "0.2.1"))
        XCTAssertTrue(UpdateChecker.isNewer("v0.2.2", than: "0.2.1"))
        XCTAssertTrue(UpdateChecker.isNewer("0.2.10", than: "0.2.9"))
        XCTAssertTrue(UpdateChecker.isNewer("0.3.0", than: "0.2.9"))
        XCTAssertTrue(UpdateChecker.isNewer("1.0.0", than: "0.99.99"))
    }

    func testNewerHandlesUnequalComponentCounts() {
        XCTAssertTrue(UpdateChecker.isNewer("0.10.0", than: "0.9.9"))
        XCTAssertFalse(UpdateChecker.isNewer("0.9.9", than: "0.10.0"))
    }

    func testSameOrOlderIsNeverNewer() {
        XCTAssertFalse(UpdateChecker.isNewer("0.2.1", than: "0.2.1"))
        XCTAssertFalse(UpdateChecker.isNewer("0.2.0", than: "0.2.1"))
    }

    func testPrefixMatchesDoNotFalselyTrigger() {
        XCTAssertTrue(UpdateChecker.isNewer("1", than: "0.2.1"))
        XCTAssertFalse(UpdateChecker.isNewer("0.2", than: "0.2.1"))
        XCTAssertFalse(UpdateChecker.isNewer("0.2.1", than: "0.2.1.0"))
    }

    func testLeadingVIsStrippedTransparently() {
        XCTAssertTrue(UpdateChecker.isNewer("v1.0", than: "v0.2.1"))
        XCTAssertFalse(UpdateChecker.isNewer("v0.2.1", than: "0.2.1"))
    }

    func testGarbageIsNeverNewer() {
        XCTAssertFalse(UpdateChecker.isNewer("not-a-version", than: "0.2.1"))
        XCTAssertFalse(UpdateChecker.isNewer("", than: "0.2.1"))
    }

    // MARK: Parsing

    func testParsesValidGitHubReleasePayload() throws {
        let json = """
        {
            "tag_name": "v0.2.2",
            "html_url": "https://github.com/pekth/meterusage/releases/tag/v0.2.2",
            "assets": [
                {
                    "name": "MeterUsage-0.2.2.zip",
                    "browser_download_url": "https://github.com/pekth/meterusage/releases/download/v0.2.2/MeterUsage-0.2.2.zip",
                    "digest": "sha256:abc123def456"
                }
            ]
        }
        """
        let release = try UpdateChecker.parse(data: Data(json.utf8))
        XCTAssertEqual(release.version, "0.2.2")
        XCTAssertEqual(release.tagName, "v0.2.2")
        XCTAssertEqual(release.appZip?.name, "MeterUsage-0.2.2.zip")
        XCTAssertEqual(release.appZip?.digest, "sha256:abc123def456")
    }

    func testParsesReleaseWithoutAssets() throws {
        let json = """
        {
            "tag_name": "0.3.0",
            "html_url": "https://github.com/pekth/meterusage/releases/tag/0.3.0"
        }
        """
        let release = try UpdateChecker.parse(data: Data(json.utf8))
        XCTAssertEqual(release.version, "0.3.0")
        XCTAssertNil(release.appZip)
    }

    func testParseRejectsEmptyTagName() {
        let json = #"{"tag_name": ""}"#
        XCTAssertThrowsError(try UpdateChecker.parse(data: Data(json.utf8)))
    }

    // MARK: Digest verification

    func testDigestVerificationAcceptsMatchingSha256() {
        let data = Data("meterusage".utf8)
        let digest = "8ea7b7eef200ff3e4ecab9f9064c243bcbe3d151c70e7e1c8d0e74f1797c0f1b"
        XCTAssertNoThrow(try UpdateChecker.verifyDigest(data, expected: "sha256:\(digest)"))
        // Case-insensitive hex matching:
        XCTAssertNoThrow(try UpdateChecker.verifyDigest(data, expected: "sha256:\(digest.uppercased())"))
    }

    func testDigestVerificationRejectsMismatchAndMissingDigest() {
        let data = Data("meterusage".utf8)
        XCTAssertThrowsError(try UpdateChecker.verifyDigest(data, expected: "sha256:deadbeef"))
        XCTAssertThrowsError(try UpdateChecker.verifyDigest(data, expected: nil))
        XCTAssertThrowsError(try UpdateChecker.verifyDigest(data, expected: "md5:whatever"))
    }

    func testInstallScriptCopiesBeforeMovingCurrentBundle() {
        let script = UpdateChecker.installScript(
            current: URL(fileURLWithPath: "/Applications/Meter's.app"),
            stagedApp: URL(fileURLWithPath: "/tmp/MeterUsage.app")
        )

        XCTAssertTrue(script.contains("cp -R '/tmp/MeterUsage.app' \"$replacement\""))
        XCTAssertTrue(script.contains("xattr -cr \"$replacement\""))
        XCTAssertTrue(script.contains("mv '/Applications/Meter'\\''s.app' \"$backup\""))
        XCTAssertTrue(script.contains("if ! mv \"$replacement\" '/Applications/Meter'\\''s.app'; then"))
        XCTAssertTrue(script.contains("mv \"$backup\" '/Applications/Meter'\\''s.app' || true"))
    }

    // MARK: Dismissal

    func testDismissedVersionStaysHiddenButAvailableKeepsValue() {
        let defaults = UserDefaults(suiteName: "UpdateCheckerTests")!\
        defaults.removePersistentDomain(forName: "UpdateCheckerTests")
        let checker = UpdateChecker(defaults: defaults)

        // Simulate a discovered release by writing the published state
        // through the same path a real check would take.
        checker.testOnly_setAvailable(UpdateChecker.Release(
            version: "0.2.2",
            tagName: "v0.2.2",
            url: URL(string: "https://github.com/pekth/meterusage/releases/tag/v0.2.2"),
            assets: []
        ))
        XCTAssertEqual(checker.visibleRelease?.version, "0.2.2")

        checker.dismiss()
        XCTAssertNil(checker.visibleRelease)
        // The underlying discovery is untouched, so a newer release later
        // re-arms the banner without any special handling.
        XCTAssertEqual(checker.available?.version, "0.2.2")
    }

    // MARK: Daily interval

    func testCheckIsSkippedInsideInterval() {
        let defaults = UserDefaults(suiteName: "UpdateCheckerTests")!
        defaults.removePersistentDomain(forName: "UpdateCheckerTests")
        let checker = UpdateChecker(defaults: defaults)

        let now = Date()
        checker.checkIfDue(now: now)
        // Second call moments later must be a no-op — the persisted
        // last-check date gates it, not in-memory state.
        checker.checkIfDue(now: now.addingTimeInterval(60))

        XCTAssertEqual(
            defaults.object(forKey: PrefKey.updateLastCheck) as? Date,
            now
        )
    }
}
