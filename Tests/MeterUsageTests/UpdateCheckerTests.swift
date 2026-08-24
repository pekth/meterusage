import XCTest
@testable import MeterUsage

/// Version comparison, release parsing, and dismissal behavior for the
/// GitHub Releases update check. Network is never touched: `fetch`'s
/// transport path is a one-line URLSession call, while every decision the
/// app makes lives in the pure functions tested here.
@MainActor
final class UpdateCheckerTests: XCTestCase {

    // MARK: Version comparison

    func testNewerPatchVersion() {
        XCTAssertTrue(UpdateChecker.isNewer("0.2.2", than: "0.2.1"))
        XCTAssertTrue(UpdateChecker.isNewer("v0.2.2", than: "0.2.1"))
    }

    func testNewerMinorAndMajor() {
        XCTAssertTrue(UpdateChecker.isNewer("0.3.0", than: "0.2.9"))
        XCTAssertTrue(UpdateChecker.isNewer("1.0.0", than: "0.99.99"))
    }

    func testNumericNotLexicographicOrdering() {
        // "0.10.0" sorts before "0.9.9" as text; numerically it is newer.
        XCTAssertTrue(UpdateChecker.isNewer("0.10.0", than: "0.9.9"))
        XCTAssertFalse(UpdateChecker.isNewer("0.9.9", than: "0.10.0"))
    }

    func testEqualAndOlderAreNotNewer() {
        XCTAssertFalse(UpdateChecker.isNewer("0.2.1", than: "0.2.1"))
        XCTAssertFalse(UpdateChecker.isNewer("0.2.0", than: "0.2.1"))
    }

    func testMissingComponentsCountAsZero() {
        XCTAssertTrue(UpdateChecker.isNewer("1", than: "0.2.1"))
        XCTAssertFalse(UpdateChecker.isNewer("0.2", than: "0.2.1"))
        XCTAssertFalse(UpdateChecker.isNewer("0.2.1", than: "0.2.1.0"))
    }

    func testLeadingVIsIgnoredOnBothSides() {
        XCTAssertTrue(UpdateChecker.isNewer("v1.0", than: "v0.2.1"))
        XCTAssertFalse(UpdateChecker.isNewer("v0.2.1", than: "0.2.1"))
    }

    func testGarbageReadsAsZeroNotNewer() {
        XCTAssertFalse(UpdateChecker.isNewer("not-a-version", than: "0.2.1"))
        XCTAssertFalse(UpdateChecker.isNewer("", than: "0.2.1"))
    }

    // MARK: Payload parsing

    func testParseStripsTagPrefixAndKeepsURL() throws {
        let json = #"{"tag_name":"v0.2.2","name":"v0.2.2","html_url":"https://github.com/pekth/meterusage/releases/tag/v0.2.2"}"#
        let release = try UpdateChecker.parse(data: Data(json.utf8))
        XCTAssertEqual(release.version, "0.2.2")
        XCTAssertEqual(release.tagName, "v0.2.2")
        XCTAssertEqual(release.url?.absoluteString, "https://github.com/pekth/meterusage/releases/tag/v0.2.2")
    }

    func testParseWithoutURL() throws {
        let json = #"{"tag_name":"0.3.0"}"#
        let release = try UpdateChecker.parse(data: Data(json.utf8))
        XCTAssertEqual(release.version, "0.3.0")
        XCTAssertNil(release.url)
    }

    func testParseRejectsEmptyTag() {
        let json = #"{"tag_name":""}"#
        XCTAssertThrowsError(try UpdateChecker.parse(data: Data(json.utf8)))
    }

    // MARK: Dismissal

    func testDismissedVersionStaysHiddenButAvailableKeepsValue() {
        let defaults = UserDefaults(suiteName: "UpdateCheckerTests")!
        defaults.removePersistentDomain(forName: "UpdateCheckerTests")
        let checker = UpdateChecker(defaults: defaults)

        // Simulate a discovered release by writing the published state
        // through the same path a real check would take.
        checker.testOnly_setAvailable(UpdateChecker.Release(
            version: "0.2.2",
            tagName: "v0.2.2",
            url: URL(string: "https://github.com/pekth/meterusage/releases/tag/v0.2.2")
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
