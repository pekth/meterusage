import UserNotifications
import XCTest
@testable import MeterUsage

@MainActor
final class ResetAvailabilityNotifierTests: XCTestCase {

    func testNotificationSaysAnEarlyCodexResetIsAvailableAndIncludesADing() {
        let content = ResetAvailabilityNotifier.notificationContent(
            for: QuotaResetAvailabilityEvent(provider: .codex, newResetCount: 1)
        )

        XCTAssertEqual(content.title, "Codex reset available")
        XCTAssertEqual(content.body, "An early usage reset is ready to use.")
        XCTAssertNotNil(content.sound)
    }
}
