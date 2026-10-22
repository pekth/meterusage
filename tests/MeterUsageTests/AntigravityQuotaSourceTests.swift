import XCTest
@testable import MeterUsage

final class AntigravityQuotaSourceTests: XCTestCase {
    /// The TSV shape `agy -p "/usage"` prints: group, window label, percent
    /// remaining, reset timestamp.
    private let sampleUsage = """
    Gemini Models\tWeekly Limit Remaining\t98.89%\t2026-09-10T03:14:38Z
    Gemini Models\tFive Hour Limit Remaining\t100%\t2026-09-03T18:00:12Z
    Claude and GPT models\tWeekly Limit Remaining\t100%\t2026-09-10T13:00:12Z
    Claude and GPT models\tFive Hour Limit Remaining\t100%\t2026-09-03T18:00:12Z
    """

    func testParseMapsRowsToWindowsAndGroups() throws {
        let quota = try AntigravityQuotaSource.parse(sampleUsage, now: Date())

        XCTAssertEqual(quota.provider, .antigravity)
        XCTAssertEqual(quota.windows.count, 4)
        XCTAssertEqual(quota.groups.map(\.title), ["Gemini Models", "Claude and GPT models"])
        XCTAssertEqual(quota.groups[0].windows.count, 2)
        XCTAssertEqual(quota.groups[1].windows.count, 2)

        // Percent remaining becomes percent used.
        XCTAssertEqual(quota.windows[0].label, "Gemini Weekly")
        XCTAssertEqual(quota.windows[0].usedPercent, 1.11, accuracy: 0.001)
        XCTAssertEqual(quota.windows[1].label, "Gemini 5-hour")
        XCTAssertEqual(quota.windows[1].usedPercent, 0)
        XCTAssertEqual(quota.windows[2].label, "Claude/GPT Weekly")
        XCTAssertEqual(quota.windows[3].label, "Claude/GPT 5-hour")

        // Grouped windows drop redundant model names and specify limit
        XCTAssertEqual(quota.groups[0].windows[0].label, "Weekly limit")
        XCTAssertEqual(quota.groups[0].windows[1].label, "5-hour limit")
        XCTAssertEqual(quota.groups[1].windows[0].label, "Weekly limit")
        XCTAssertEqual(quota.groups[1].windows[1].label, "5-hour limit")
    }

    func testParseDecodesResetTimestamps() throws {
        let quota = try AntigravityQuotaSource.parse(sampleUsage, now: Date())
        let formatter = ISO8601DateFormatter()
        XCTAssertEqual(
            quota.windows[0].resetsAt,
            formatter.date(from: "2026-09-10T03:14:38Z")
        )
        XCTAssertNotNil(quota.windows[1].resetsAt)
    }

    func testParseAcceptsFractionalTimestamps() throws {
        let quota = try AntigravityQuotaSource.parse(
            "Gemini Models\tWeekly Limit Remaining\t50%\t2026-09-10T03:14:38.521Z\n",
            now: Date()
        )
        XCTAssertNotNil(quota.windows.first?.resetsAt)
    }

    func testParseSkipsMalformedRows() throws {
        let messy = """
        not a usage row
        Gemini Models\tWeekly\t98%\t2026-09-10T03:14:38Z
        Gemini Models\tWeekly Limit Remaining\tnot-a-percent\t2026-09-10T03:14:38Z
        """
        let quota = try AntigravityQuotaSource.parse(messy, now: Date())
        XCTAssertEqual(quota.windows.count, 1)
        XCTAssertEqual(quota.windows[0].usedPercent, 2, accuracy: 0.001)
    }

    func testParseThrowsOnNoUsableRows() {
        XCTAssertThrowsError(try AntigravityQuotaSource.parse("garbage\n", now: Date()))
        XCTAssertThrowsError(try AntigravityQuotaSource.parse("", now: Date()))
    }

    func testParseKeepsUnknownWindowLabelsVerbatim() throws {
        let quota = try AntigravityQuotaSource.parse(
            "Gemini Models\tFortnight Limit Remaining\t40%\t2026-09-10T03:14:38Z",
            now: Date()
        )
        XCTAssertEqual(quota.windows[0].label, "Gemini Fortnight")
        XCTAssertEqual(quota.groups[0].windows[0].label, "Fortnight limit")
    }

    func testContainerInvocationTargetsTheWrapperVolumes() {
        // The command must mount the same state the user's own agy wrapper
        // mounts, and never reach into the volume by hand.
        XCTAssertEqual(AntigravityQuotaSource.imageName, "antigravity-cli:local")
        XCTAssertEqual(AntigravityQuotaSource.volumeName, "antigravity-config")
        XCTAssertEqual(AntigravityQuotaSource.binVolumeName, "antigravity-bin")
    }
}
