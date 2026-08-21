import XCTest
@testable import MeterUsageCore

final class OpenRouterQuotaSourceTests: XCTestCase {

    func testParseKeyUsageAndMonthlyLimit() throws {
        let json = """
        {"data":{"usage":25.5,"limit":100,"limit_remaining":74.5,"limit_reset":"monthly"}}
        """

        let quota = try OpenRouterQuotaSource.parse(data: Data(json.utf8), now: Date(timeIntervalSince1970: 100))

        XCTAssertEqual(quota.provider, .openRouter)
        let window = try XCTUnwrap(quota.windows.first)
        XCTAssertEqual(window.label, "Monthly")
        XCTAssertEqual(window.usedPercent, 25.5, accuracy: 0.0001)

        let credits = try XCTUnwrap(quota.credits)
        XCTAssertEqual(credits.unit, .dollars)
        XCTAssertEqual(credits.balance, 74.5, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(credits.usedDollars), 25.5, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(credits.limitDollars), 100, accuracy: 0.0001)
    }

    func testParseAcceptsNumericStrings() throws {
        let json = """
        {"data":{"usage":"3.25","limit":"10","limit_remaining":"6.75","limit_reset":"daily"}}
        """

        let quota = try OpenRouterQuotaSource.parse(data: Data(json.utf8), now: Date())

        XCTAssertEqual(quota.windows.first?.label, "Daily")
        XCTAssertEqual(try XCTUnwrap(quota.windows.first?.usedPercent), 32.5, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(quota.credits?.balance), 6.75, accuracy: 0.0001)
    }

    func testParseNoLimitStillShowsSpendWithoutInventingRemainingBalance() throws {
        let json = """
        {"data":{"usage":4.75,"limit":null,"limit_remaining":null,"limit_reset":null}}
        """

        let quota = try OpenRouterQuotaSource.parse(data: Data(json.utf8), now: Date())

        XCTAssertTrue(quota.windows.isEmpty)
        XCTAssertEqual(try XCTUnwrap(quota.credits?.usedDollars), 4.75, accuracy: 0.0001)
        XCTAssertNil(quota.credits?.limitDollars)
        XCTAssertTrue(quota.credits?.unlimited == true)
    }

    func testParseCreditsSummaryShowsRemainingAccountBalance() throws {
        let keyJSON = """
        {"data":{"usage":0.3185378,"limit":null,"limit_remaining":null,"limit_reset":null}}
        """
        let creditsJSON = """
        {"data":{"total_credits":10,"total_usage":0.3185378}}
        """

        let quota = try OpenRouterQuotaSource.parse(
            data: Data(keyJSON.utf8),
            creditsData: Data(creditsJSON.utf8),
            now: Date()
        )

        let credits = try XCTUnwrap(quota.credits)
        XCTAssertEqual(credits.balance, 9.6814622, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(credits.usedDollars), 0.3185378, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(credits.limitDollars), 10, accuracy: 0.0001)
        XCTAssertFalse(credits.unlimited)
    }

    func testParseCreditsSummaryAcceptsNumericStrings() throws {
        let keyJSON = """
        {"data":{"usage":0,"limit":null,"limit_remaining":null,"limit_reset":null}}
        """
        let creditsJSON = """
        {"data":{"total_credits":"25","total_usage":"3.25"}}
        """

        let quota = try OpenRouterQuotaSource.parse(
            data: Data(keyJSON.utf8),
            creditsData: Data(creditsJSON.utf8),
            now: Date()
        )

        XCTAssertEqual(try XCTUnwrap(quota.credits?.balance), 21.75, accuracy: 0.0001)
    }
}
