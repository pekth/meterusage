import XCTest
@testable import MeterUsage

final class OpenRouterUsageTests: XCTestCase {

    func testParseActivityResponse() throws {
        let json = """
        {
          "data": [
            {
              "date": "2026-09-08",
              "endpoint_id": "ep-1",
              "model": "anthropic/claude-3.5-sonnet",
              "prompt_tokens": 10000,
              "completion_tokens": 2500,
              "reasoning_tokens": 500,
              "requests": 15,
              "usage": 0.085
            },
            {
              "date": "2026-09-08",
              "endpoint_id": "ep-2",
              "model": "openai/gpt-4o",
              "prompt_tokens": 5000,
              "completion_tokens": 1000,
              "reasoning_tokens": 0,
              "requests": 5,
              "usage": 0.035
            },
            {
              "date": "2026-09-09",
              "endpoint_id": "ep-1",
              "model": "anthropic/claude-3.5-sonnet",
              "prompt_tokens": 20000,
              "completion_tokens": 4000,
              "reasoning_tokens": 1000,
              "requests": 20,
              "usage": 0.160
            }
          ]
        }
        """

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        let testNow = try XCTUnwrap(dateFormatter.date(from: "2026-09-09"))

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let usage = try OpenRouterUsageSource.parse(
            data: Data(json.utf8),
            now: testNow,
            calendar: calendar
        )

        XCTAssertEqual(usage.provider, .openRouter)
        XCTAssertEqual(usage.sessionCount, 40) // 15 + 5 + 20
        XCTAssertEqual(usage.messageCount, 40)
        let tokens = try XCTUnwrap(usage.tokens)
        XCTAssertEqual(tokens.input, 35000)
        XCTAssertEqual(tokens.output, 7500)
        XCTAssertEqual(tokens.reasoning, 1500)
        XCTAssertEqual(tokens.total, 44000)
        XCTAssertEqual(try XCTUnwrap(usage.estimatedCostUSD), 0.28, accuracy: 0.001)

        // Today stats (2026-09-09)
        XCTAssertEqual(usage.todaySessionCount, 20)
        XCTAssertEqual(usage.todayMessageCount, 20)

        // Telemetry
        let tel = try XCTUnwrap(usage.telemetry)
        XCTAssertEqual(tel.dailyHistory.count, 30)
        XCTAssertEqual(tel.lifetimeTokens, 44000)
        XCTAssertEqual(tel.todayTokens, 25000) // 20000 + 4000 + 1000
        XCTAssertEqual(tel.last30DaysTokens, 44000)

        // Verify that dailyHistory has activity points
        let activeDays = tel.dailyHistory.filter { $0.tokens > 0 }
        XCTAssertEqual(activeDays.count, 2)
    }

    func testParseEmptyDataProducesValidEmptyHistory() throws {
        let json = "{\"data\":[]}"
        let usage = try OpenRouterUsageSource.parse(data: Data(json.utf8), now: Date())
        XCTAssertEqual(usage.provider, .openRouter)
        XCTAssertEqual(usage.sessionCount, 0)
        XCTAssertEqual(usage.tokens?.total, 0)
        let tel = try XCTUnwrap(usage.telemetry)
        XCTAssertEqual(tel.dailyHistory.count, 30)
        XCTAssertEqual(tel.lifetimeTokens, 0)
        XCTAssertEqual(tel.todayTokens, 0)
    }
}
