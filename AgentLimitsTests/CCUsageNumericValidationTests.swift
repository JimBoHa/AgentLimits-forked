import XCTest
@testable import AgentLimits

@MainActor
final class CCUsageNumericValidationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_752_921_600)

    func testClaudeTokenAggregateOverflowIsRejected() throws {
        let response = CCUsageClaudeResponse(
            daily: [
                .init(
                    date: "2025-07-18",
                    totalTokens: Int.max,
                    totalCost: 1
                ),
                .init(date: "2025-07-19", totalTokens: 1, totalCost: 1)
            ],
            totals: .init(totalTokens: Int.max, totalCost: 2)
        )

        XCTAssertThrowsError(
            try parse(response, provider: .claude)
        ) { error in
            assertParseError(error, contains: "numeric bounds")
        }
    }

    func testCodexCostAggregateOverflowIsRejected() throws {
        let response = CCUsageCodexResponse(
            daily: [
                .init(
                    date: "2025-07-18",
                    totalTokens: 1,
                    costUSD: Double.greatestFiniteMagnitude
                ),
                .init(
                    date: "2025-07-19",
                    totalTokens: 1,
                    costUSD: Double.greatestFiniteMagnitude
                )
            ],
            totals: .init(
                totalTokens: 2,
                costUSD: Double.greatestFiniteMagnitude
            )
        )

        XCTAssertThrowsError(
            try parse(response, provider: .codex)
        ) { error in
            assertParseError(error, contains: "numeric bounds")
        }
    }

    func testNegativeDailyValuesAreRejected() throws {
        let negativeTokens = CCUsageClaudeResponse(
            daily: [
                .init(date: "2025-07-19", totalTokens: -1, totalCost: 1)
            ],
            totals: .init(totalTokens: -1, totalCost: 1)
        )
        let negativeCost = CCUsageCodexResponse(
            daily: [
                .init(date: "2025-07-19", totalTokens: 1, costUSD: -1)
            ],
            totals: .init(totalTokens: 1, costUSD: -1)
        )

        for operation in [
            { try self.parse(negativeTokens, provider: .claude) },
            { try self.parse(negativeCost, provider: .codex) }
        ] {
            XCTAssertThrowsError(try operation()) { error in
                self.assertParseError(error, contains: "invalid numeric")
            }
        }
    }

    func testFilteredDatesCannotHideInvalidNumericValues() throws {
        let malformedDate = CCUsageClaudeResponse(
            daily: [
                .init(date: "not-a-date", totalTokens: -1, totalCost: 1)
            ],
            totals: .init(totalTokens: 0, totalCost: 0)
        )
        let futureDate = CCUsageCodexResponse(
            daily: [
                .init(date: "2099-01-01", totalTokens: 1, costUSD: -1)
            ],
            totals: .init(totalTokens: 0, costUSD: 0)
        )

        for operation in [
            { try self.parse(malformedDate, provider: .claude) },
            { try self.parse(futureDate, provider: .codex) }
        ] {
            XCTAssertThrowsError(try operation()) { error in
                self.assertParseError(error, contains: "invalid numeric")
            }
        }
    }

    func testNormalDailyValuesStillAggregate() throws {
        let response = CCUsageClaudeResponse(
            daily: [
                .init(date: "2025-07-18", totalTokens: 20, totalCost: 2),
                .init(date: "2025-07-19", totalTokens: 10, totalCost: 1)
            ],
            totals: .init(totalTokens: 30, totalCost: 3)
        )

        let snapshot = try parse(response, provider: .claude)

        XCTAssertEqual(snapshot.today.totalTokens, 10)
        XCTAssertEqual(snapshot.thisWeek.totalTokens, 30)
        XCTAssertEqual(snapshot.thisMonth.totalTokens, 30)
        XCTAssertEqual(snapshot.thisMonth.costUSD, 3)
    }

    private func parse<T: Encodable>(
        _ response: T,
        provider: TokenUsageProvider
    ) throws -> TokenUsageSnapshot {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return try CCUsageFetcher().parseResponse(
            jsonData: JSONEncoder().encode(response),
            provider: provider,
            now: now,
            calendar: calendar
        )
    }

    private func assertParseError(
        _ error: Error,
        contains expectedText: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case CCUsageFetcherError.parseError(let message) = error else {
            return XCTFail("Expected parseError, got \(error)", file: file, line: line)
        }
        XCTAssertTrue(
            message.contains(expectedText),
            "Unexpected message: \(message)",
            file: file,
            line: line
        )
    }
}
