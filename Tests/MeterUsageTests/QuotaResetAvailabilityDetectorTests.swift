import XCTest
@testable import MeterUsage

final class QuotaResetAvailabilityDetectorTests: XCTestCase {

    func testNewlyAvailableResetAfterBaselineEmitsOneEvent() throws {
        var detector = QuotaResetAvailabilityDetector()
        XCTAssertNil(detector.observe(quota(availableCount: 0)))
        let newlyAvailable = quota(
            availableCount: 1,
            credits: [QuotaResetCredit(id: "reset-1", title: "Full reset", status: "available")]
        )

        let event = try XCTUnwrap(
            detector.observe(newlyAvailable)
        )

        XCTAssertEqual(event.provider, .codex)
        XCTAssertEqual(event.newResetCount, 1)
        XCTAssertNil(detector.observe(newlyAvailable))
    }

    func testNewResetIDEmitsWhenAvailableCountStaysTheSame() throws {
        var detector = QuotaResetAvailabilityDetector()
        XCTAssertNil(
            detector.observe(
                quota(
                    availableCount: 1,
                    credits: [QuotaResetCredit(id: "reset-old", title: "Full reset", status: "available")]
                )
            )
        )

        let event = try XCTUnwrap(
            detector.observe(
                quota(
                    availableCount: 1,
                    credits: [QuotaResetCredit(id: "reset-new", title: "Full reset", status: "available")]
                )
            )
        )

        XCTAssertEqual(event.newResetCount, 1)
    }

    func testNonAvailableResetCreditDoesNotEmit() {
        var detector = QuotaResetAvailabilityDetector()
        XCTAssertNil(detector.observe(quota(availableCount: 0)))

        XCTAssertNil(
            detector.observe(
                quota(
                    availableCount: 0,
                    credits: [QuotaResetCredit(id: "reset-used", title: "Full reset", status: "used")]
                )
            )
        )
    }

    func testExistingResetOnInitialSnapshotDoesNotEmitAgain() {
        var detector = QuotaResetAvailabilityDetector()
        let existing = quota(
            availableCount: 1,
            credits: [QuotaResetCredit(id: "reset-existing", title: "Full reset", status: "available")]
        )

        XCTAssertNil(detector.observe(existing))
        XCTAssertNil(detector.observe(existing))
    }

    func testLaterCreditDetailsDoNotLookLikeANewResetWhenCountIsUnchanged() {
        var detector = QuotaResetAvailabilityDetector()
        XCTAssertNil(detector.observe(quota(availableCount: 1)))

        XCTAssertNil(
            detector.observe(
                quota(
                    availableCount: 1,
                    credits: [QuotaResetCredit(id: "reset-existing", title: "Full reset", status: "available")]
                )
            )
        )
    }

    func testUsageWindowResetEmitsWhenServerMovesWindowForward() throws {
        var detector = QuotaResetAvailabilityDetector()
        let firstReset = Date(timeIntervalSince1970: 1_900_000_000)
        let secondReset = firstReset.addingTimeInterval(300)

        XCTAssertNil(
            detector.observe(
                quota(
                    availableCount: 0,
                    windows: [QuotaWindow(label: "Weekly", usedPercent: 82, resetsAt: firstReset)],
                    capturedAt: Date(timeIntervalSince1970: 1_899_999_000)
                )
            )
        )

        let event = try XCTUnwrap(
            detector.observe(
                quota(
                    availableCount: 0,
                    windows: [QuotaWindow(label: "Weekly", usedPercent: 0, resetsAt: secondReset)],
                    capturedAt: Date(timeIntervalSince1970: 1_899_999_100)
                )
            )
        )

        XCTAssertEqual(event, QuotaResetAvailabilityEvent(provider: .codex, newResetCount: 1))
    }

    func testMovingResetTimeWithoutUsageDropDoesNotEmit() {
        var detector = QuotaResetAvailabilityDetector()
        let firstReset = Date(timeIntervalSince1970: 1_900_000_000)

        XCTAssertNil(
            detector.observe(
                quota(
                    availableCount: 0,
                    windows: [QuotaWindow(label: "Weekly", usedPercent: 25, resetsAt: firstReset)],
                    capturedAt: Date(timeIntervalSince1970: 1_899_999_000)
                )
            )
        )

        XCTAssertNil(
            detector.observe(
                quota(
                    availableCount: 0,
                    windows: [QuotaWindow(label: "Weekly", usedPercent: 25, resetsAt: firstReset.addingTimeInterval(300))],
                    capturedAt: Date(timeIntervalSince1970: 1_899_999_100)
                )
            )
        )
    }

    private func quota(
        availableCount: Int?,
        credits: [QuotaResetCredit] = [],
        windows: [QuotaWindow] = [],
        capturedAt: Date = Date()
    ) -> ProviderQuota {
        ProviderQuota(
            provider: .codex,
            windows: windows,
            resetCreditCount: availableCount,
            resetCredits: credits,
            capturedAt: capturedAt
        )
    }
}
